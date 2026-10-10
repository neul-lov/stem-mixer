import AppKit
import Carbon
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

struct StemInfo {
    let label: String
    let color: Color

    static func of(_ name: String) -> StemInfo {
        switch name {
        case "vocals": StemInfo(label: "보컬", color: Color(red: 0.90, green: 0.28, blue: 0.30))
        case "bass": StemInfo(label: "베이스", color: Color(red: 0.24, green: 0.39, blue: 0.87))
        case "drums": StemInfo(label: "드럼", color: Color(red: 0.96, green: 0.62, blue: 0.04))
        case "guitar": StemInfo(label: "기타", color: Color(red: 0.55, green: 0.36, blue: 0.96))
        case "piano": StemInfo(label: "피아노", color: Color(red: 0.07, green: 0.65, blue: 0.75))
        case "other": StemInfo(label: "나머지 악기", color: Color(red: 0.19, green: 0.64, blue: 0.42))
        default: StemInfo(label: name, color: .gray)
        }
    }
}

struct Preset: Identifiable {
    let name: String
    let values: [String: Int]
    /// Volume for every stem not named in `values`, so presets fit both 4- and 6-track songs.
    var rest = 100
    /// Only shown for songs that have this stem (guitar / piano presets).
    var requires: String?
    var id: String { name }

    func volume(for stem: String) -> Int { values[stem] ?? rest }

    static let all: [Preset] = [
        Preset(name: "원곡", values: [:]),
        Preset(name: "노래방", values: ["vocals": 0]),
        Preset(name: "보컬만", values: ["vocals": 100], rest: 0),
        Preset(name: "베이스만", values: ["bass": 100], rest: 0),
        Preset(name: "드럼만", values: ["drums": 100], rest: 0),
        Preset(name: "기타만", values: ["guitar": 100], rest: 0, requires: "guitar"),
        Preset(name: "피아노만", values: ["piano": 100], rest: 0, requires: "piano"),
        Preset(name: "베이스 연습", values: ["vocals": 40, "bass": 0, "drums": 100], rest: 60),
        Preset(name: "베이스 크게", values: ["vocals": 60, "bass": 180, "drums": 80], rest: 60),
        Preset(name: "기타 연습", values: ["guitar": 0], requires: "guitar"),
        Preset(name: "피아노 연습", values: ["piano": 0], requires: "piano"),
    ]

    static func available(for stems: [String]) -> [Preset] {
        all.filter { $0.requires.map(stems.contains) ?? true }
    }
}

struct TrackState {
    var volume: Int = 100
    var muted = false
    var solo = false
}

enum SplitMode: String, CaseIterable, Identifiable {
    case ai, ai6, eq
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ai: "AI 4트랙"
        case .ai6: "AI 6트랙"
        case .eq: "빠르게"
        }
    }
    var detail: String {
        switch self {
        case .ai: "보컬 · 베이스 · 드럼 · 나머지 악기"
        case .ai6: "보컬 · 베이스 · 드럼 · 기타 · 피아노 · 나머지"
        case .eq: "몇 초면 끝나지만 소리가 섞여요"
        }
    }

    static func label(_ raw: String) -> String { SplitMode(rawValue: raw)?.title ?? raw }
    static func icon(_ raw: String) -> String { raw == "eq" ? "bolt.fill" : "sparkles" }
}

struct Job {
    var label: String
    var step: String = "보내는 중"
    var progress: Double = 0
}

@MainActor
final class AppModel: ObservableObject {
    enum ServerState: Equatable { case starting, ready, missing, failed(String) }

    let backend = Backend()
    private let mixer = Mixer()

    @Published var server: ServerState = .starting
    @Published var songs: [Song] = []
    @Published var input = ""
    @Published var mode: SplitMode = SplitMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .ai {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mode") }
    }
    @Published var job: Job?
    @Published var jobError: String?
    @Published var toast: String?

    @Published var song: Song?
    @Published var loadingSong = false
    @Published var tracks: [String: TrackState] = [:]
    @Published var playing = false
    @Published var time: Double = 0
    @Published var levels: [String: Float] = [:]
    @Published var exporting = false
    @Published var master: Double = UserDefaults.standard.object(forKey: "master") as? Double ?? 0.8 {
        didSet {
            mixer.setMaster(master)
            UserDefaults.standard.set(master, forKey: "master")
        }
    }
    @Published var focusToken = 0

    private var ticker: Timer?
    private var toastTask: Task<Void, Never>?

    // MARK: Server

    func start() {
        mixer.setMaster(master)
        setUpMediaKeys()
        guard backend.isInstalled else {
            server = .missing
            return
        }
        Task {
            // A server left over from an earlier run can be reused as is.
            if (try? await backend.songs()) == nil {
                do { try backend.launch() } catch {
                    server = .failed(error.localizedDescription)
                    return
                }
            }
            for _ in 0..<120 {
                if let list = try? await backend.songs() {
                    songs = list
                    server = .ready
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            server = .failed("서버가 응답하지 않아요. 로그를 확인해 주세요.")
        }
        // Pick up songs added or removed elsewhere (another window, the browser version) when coming back.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.server == .ready else { return }
                Task { await self.refreshSongs() }
            }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func shutdown() {
        mixer.unload()
        backend.stop()
    }

    func refreshSongs() async {
        if let list = try? await backend.songs() { songs = list }
    }

    // MARK: Separation

    var canSubmit: Bool { server == .ready && job == nil && !input.trimmingCharacters(in: .whitespaces).isEmpty }

    func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit, !text.isEmpty else { return }
        run(label: text) { try await self.backend.startJob(text: text, mode: self.mode.rawValue) }
    }

    func submit(file: URL) {
        guard server == .ready, job == nil else { return }
        run(label: file.deletingPathExtension().lastPathComponent) {
            try await self.backend.startJob(file: file, mode: self.mode.rawValue)
        }
    }

    /// The id of this song's version in another mode, if it has been made already.
    func version(of item: Song, mode: SplitMode) -> Song? {
        songs.first { $0.id == "\(item.key)-\(mode.rawValue)" }
    }

    func resplit(_ item: Song, mode: SplitMode) {
        if let existing = version(of: item, mode: mode) {
            open(existing.id)
            return
        }
        guard server == .ready, job == nil else { return }
        run(label: "\(item.title) → \(mode.title)") {
            try await self.backend.resplit(item.id, mode: mode.rawValue)
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        submit(file: url)
    }

    private func run(label: String, start: @escaping () async throws -> String) {
        jobError = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { job = Job(label: label) }
        Task {
            do {
                let id = try await start()
                while true {
                    try await Task.sleep(for: .milliseconds(600))
                    guard let status = try? await backend.job(id) else { continue }
                    if status.status == "error" { throw BackendError(message: status.error ?? "알 수 없는 오류") }
                    job?.step = status.step ?? ""
                    job?.progress = status.progress ?? 0
                    if status.status == "done", let songID = status.song_id {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { job = nil }
                        input = ""
                        await refreshSongs()
                        open(songID)
                        show("분리 완료")
                        return
                    }
                }
            } catch {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    job = nil
                    jobError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Library

    func open(_ id: String) {
        guard let meta = songs.first(where: { $0.id == id }) else {
            Task {
                if let meta = try? await backend.song(id) { load(meta) }
            }
            return
        }
        load(meta)
    }

    private func load(_ meta: Song) {
        pause()
        leaveTextField()
        song = meta
        loadingSong = true
        let saved = UserDefaults.standard.dictionary(forKey: "mix.\(meta.id)") as? [String: Int] ?? [:]
        tracks = Dictionary(uniqueKeysWithValues: meta.stems.map { ($0, TrackState(volume: saved[$0] ?? 100)) })
        do {
            try mixer.load(meta.stems.map { ($0, backend.stemURL(song: meta.id, stem: $0)) })
            applyGains()
            time = 0
        } catch {
            show("트랙을 열지 못했어요", success: false)
            song = nil
        }
        loadingSong = false
    }

    func delete(_ item: Song) {
        let alert = NSAlert()
        alert.messageText = "'\(item.title)'을(를) 지울까요?"
        alert.informativeText = "분리한 트랙 파일도 함께 지워져요."
        alert.addButton(withTitle: "지우기")
        alert.addButton(withTitle: "취소")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if song?.id == item.id {
            mixer.unload()
            song = nil
            playing = false
        }
        Task {
            try? await backend.delete(item.id)
            withAnimation(.easeOut(duration: 0.2)) { songs.removeAll { $0.id == item.id } }
        }
    }

    func reveal(_ item: Song) {
        NSWorkspace.shared.activateFileViewerSelecting([backend.library.appendingPathComponent(item.id)])
    }

    // MARK: Playback

    func togglePlay() {
        guard song != nil else { return }
        leaveTextField()
        if mixer.isPlaying { pause() } else {
            mixer.play()
            playing = true
        }
        updateNowPlaying()
    }

    func pause() {
        mixer.pause()
        playing = false
        time = mixer.currentTime
        updateNowPlaying()
    }

    func seek(_ seconds: Double) {
        mixer.seek(to: max(0, min(seconds, mixer.duration)))
        time = mixer.currentTime
    }

    var duration: Double { song == nil ? 0 : mixer.duration }

    private func tick() {
        guard song != nil, mixer.isPlaying else {
            if levels.values.contains(where: { $0 > 0 }) { levels = [:] }
            return
        }
        time = mixer.currentTime
        if time >= mixer.duration - 0.02 {
            pause()
            seek(0)
        }
        var next: [String: Float] = [:]
        for name in tracks.keys {
            // Ease the meters down instead of dropping straight to the new value.
            next[name] = max(mixer.level(name), (levels[name] ?? 0) * 0.85)
        }
        levels = next
    }

    // MARK: Media keys

    /// The keyboard's play/pause key, AirPods and Control Center control playback too.
    private func setUpMediaKeys() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlay() }
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if self?.playing == false { self?.togglePlay() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if self?.playing == true { self?.togglePlay() } }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let song else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyPlaybackDuration: mixer.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: mixer.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }

    // MARK: Mix

    func audible(_ name: String) -> Bool {
        guard let t = tracks[name] else { return false }
        let anySolo = tracks.values.contains { $0.solo }
        return !t.muted && (!anySolo || t.solo)
    }

    func setVolume(_ name: String, _ value: Int) {
        tracks[name]?.volume = value
        applyGains()
    }

    func toggleMute(_ name: String) {
        tracks[name]?.muted.toggle()
        applyGains()
    }

    func toggleSolo(_ name: String) {
        tracks[name]?.solo.toggle()
        applyGains()
    }

    func apply(_ preset: Preset) {
        for name in tracks.keys {
            tracks[name] = TrackState(volume: preset.volume(for: name))
        }
        applyGains()
    }

    func isActive(_ preset: Preset) -> Bool {
        !tracks.isEmpty && tracks.allSatisfy { name, t in
            !t.muted && !t.solo && t.volume == preset.volume(for: name)
        }
    }

    private func applyGains() {
        for name in tracks.keys {
            mixer.setGain(audible(name) ? Double(tracks[name]!.volume) / 100 : 0, for: name)
        }
        if let song {
            UserDefaults.standard.set(tracks.mapValues(\.volume), forKey: "mix.\(song.id)")
        }
    }

    func exportMix() {
        guard let song, !exporting else { return }
        let desc = song.stems.map { "\(StemInfo.of($0).label)\(audible($0) ? tracks[$0]!.volume : 0)" }.joined(separator: "_")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(song.title)_\(desc).wav".replacingOccurrences(of: "/", with: "-")
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let inputs = song.stems.map { (backend.stemURL(song: song.id, stem: $0), audible($0) ? Double(tracks[$0]!.volume) / 100 : 0) }
        exporting = true
        Task.detached {
            let result = Result { try Mixer.export(inputs, to: url) }
            await MainActor.run {
                self.exporting = false
                switch result {
                case .success: self.show("믹스를 저장했어요")
                case .failure: self.show("저장하지 못했어요", success: false)
                }
            }
        }
    }

    // MARK: Sending tracks to other apps

    private var exportCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StemMixer/Export", isDirectory: true)
    }

    private func safeName(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// The stem file under a readable name ("곡 제목 - 보컬.wav"), so editing apps name the track sensibly.
    func namedStem(_ stem: String, of song: Song) -> URL? {
        let dir = exportCache.appendingPathComponent(song.id, isDirectory: true)
        let url = dir.appendingPathComponent("\(safeName(song.title)) - \(StemInfo.of(stem).label).wav")
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let source = backend.stemURL(song: song.id, stem: stem)
            // A hard link costs no space; fall back to a copy on another volume.
            do { try fm.linkItem(at: source, to: url) } catch { try fm.copyItem(at: source, to: url) }
            return url
        } catch {
            return nil
        }
    }

    func namedStems() -> [URL] {
        guard let song else { return [] }
        return song.stems.compactMap { namedStem($0, of: song) }
    }

    private func putOnPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    func copyStem(_ stem: String) {
        guard let song, let url = namedStem(stem, of: song) else { return }
        putOnPasteboard([url])
        show("\(StemInfo.of(stem).label) 트랙을 복사했어요")
    }

    func copyAllStems() {
        let urls = namedStems()
        guard !urls.isEmpty else { return }
        putOnPasteboard(urls)
        show("트랙 \(urls.count)개를 복사했어요")
    }

    func revealStem(_ stem: String) {
        guard let song, let url = namedStem(stem, of: song) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Identifies the current mix, so a rendered file is reused until a slider changes.
    var mixSignature: String {
        guard let song else { return "" }
        return song.id + song.stems.map { "\($0)\(audible($0) ? tracks[$0]!.volume : 0)" }.joined()
    }

    @Published var renderedMix: (signature: String, url: URL)?
    @Published var renderingMix = false

    var currentMixFile: URL? {
        guard let rendered = renderedMix, rendered.signature == mixSignature,
              FileManager.default.fileExists(atPath: rendered.url.path) else { return nil }
        return rendered.url
    }

    /// Renders what you hear now into "곡 제목 - 믹스 (보컬0 베이스100 …).wav" in the cache.
    func renderMix(then done: @escaping (URL) -> Void) {
        guard let song, !renderingMix else { return }
        if let url = currentMixFile { return done(url) }
        let signature = mixSignature
        let desc = song.stems.map { "\(StemInfo.of($0).label)\(audible($0) ? tracks[$0]!.volume : 0)" }.joined(separator: " ")
        let dir = exportCache.appendingPathComponent(song.id, isDirectory: true)
        let url = dir.appendingPathComponent("\(safeName(song.title)) - 믹스 (\(desc)).wav")
        let inputs = song.stems.map { (backend.stemURL(song: song.id, stem: $0), audible($0) ? Double(tracks[$0]!.volume) / 100 : 0) }
        renderingMix = true
        Task.detached {
            let result = Result {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Mixer.export(inputs, to: url)
            }
            await MainActor.run {
                self.renderingMix = false
                switch result {
                case .success:
                    self.renderedMix = (signature, url)
                    done(url)
                case .failure:
                    self.show("믹스를 만들지 못했어요", success: false)
                }
            }
        }
    }

    func copyMix() {
        renderMix { url in
            self.putOnPasteboard([url])
            self.show("지금 믹스를 복사했어요")
        }
    }

    /// Saves every stem, named by song and instrument, into a folder you pick.
    func exportAllStems() {
        guard let song else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "여기에 저장"
        panel.message = "트랙 파일을 저장할 폴더를 고르세요"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let base = panel.url else { return }
        let dir = base.appendingPathComponent("\(safeName(song.title)) 트랙", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for stem in song.stems {
                let target = dir.appendingPathComponent("\(safeName(song.title)) - \(StemInfo.of(stem).label).wav")
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: backend.stemURL(song: song.id, stem: stem), to: target)
            }
            NSWorkspace.shared.activateFileViewerSelecting([dir])
            show("트랙 \(song.stems.count)개를 저장했어요")
        } catch {
            show("저장하지 못했어요", success: false)
        }
    }

    // MARK: Toast

    @Published var toastIsSuccess = true

    func show(_ message: String, success: Bool = true) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            toast = message
            toastIsSuccess = success
        }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    // MARK: Keyboard

    /// Shortcuts that work anywhere in the window except while typing in the link field.
    func leaveTextField(_ window: NSWindow? = nil) {
        (window ?? NSApp.keyWindow)?.makeFirstResponder(nil)
    }

    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let window = event.window ?? NSApp.keyWindow
        var typing = window?.firstResponder is NSTextView
        // An empty, focused link field shouldn't swallow Space: leave the field and play instead.
        if typing, input.isEmpty, song != nil, event.keyCode == UInt16(kVK_Space), flags.isEmpty {
            leaveTextField(window)
            typing = false
        }
        if typing, event.keyCode == UInt16(kVK_Escape) {
            leaveTextField(window)
            return true
        }
        if flags == .command, event.keyCode == UInt16(kVK_ANSI_C), !typing, song != nil {
            copyMix()
            return true
        }
        if flags == .command, event.keyCode == UInt16(kVK_ANSI_V), !typing,
           let text = NSPasteboard.general.string(forType: .string) {
            input = text.trimmingCharacters(in: .whitespacesAndNewlines)
            focusToken += 1
            return true
        }
        guard !typing, flags.subtracting([.numericPad, .function]).isEmpty, song != nil else { return false }
        switch Int(event.keyCode) {
        case kVK_Space: togglePlay()
        case kVK_RightArrow: seek(mixer.currentTime + 5)
        case kVK_LeftArrow: seek(mixer.currentTime - 5)
        case kVK_ANSI_0: apply(Preset.all[0])
        case kVK_ANSI_1: apply(Preset.all[2])
        case kVK_ANSI_2: apply(Preset.all[3])
        case kVK_ANSI_3: apply(Preset.all[4])
        default: return false
        }
        return true
    }
}
