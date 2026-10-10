import AppKit
import AVFoundation
import Carbon
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

struct StemInfo {
    let label: String
    let color: Color

    static func of(_ name: String) -> StemInfo {
        if name.hasSuffix("_midi") {
            let base = of(String(name.dropLast(5)))
            return StemInfo(label: "\(base.label) 음정", color: base.color)
        }
        return switch name {
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
    /// Number key that applies it (0–5).
    var key: Int?
    var id: String { name }

    func volume(for stem: String) -> Int { values[stem] ?? rest }

    static let all: [Preset] = [
        Preset(name: "원곡", values: [:], key: 0),
        Preset(name: "노래방", values: ["vocals": 0]),
        Preset(name: "보컬만", values: ["vocals": 100], rest: 0, key: 1),
        Preset(name: "베이스만", values: ["bass": 100], rest: 0, key: 2),
        Preset(name: "드럼만", values: ["drums": 100], rest: 0, key: 3),
        Preset(name: "기타만", values: ["guitar": 100], rest: 0, requires: "guitar", key: 4),
        Preset(name: "피아노만", values: ["piano": 100], rest: 0, requires: "piano", key: 5),
        Preset(name: "베이스 연습", values: ["vocals": 40, "bass": 0, "drums": 100], rest: 60),
        Preset(name: "베이스 크게", values: ["vocals": 60, "bass": 180, "drums": 80], rest: 60),
        Preset(name: "기타 연습", values: ["guitar": 0], requires: "guitar"),
        Preset(name: "피아노 연습", values: ["piano": 0], requires: "piano"),
    ]

    static func available(for stems: [String]) -> [Preset] {
        all.filter { $0.requires.map(stems.contains) ?? true }
    }

    /// The preset on a number key, if this song has the stems for it (4 · 5 only in 6-track songs).
    static func forKey(_ key: Int, stems: [String]) -> Preset? {
        available(for: stems).first { $0.key == key }
    }
}

struct TrackState {
    var volume: Int = 100
    var muted = false
    var solo = false
}

enum SplitMode: String, CaseIterable, Identifiable {
    /// hq / hq6: vocals by MelBand RoFormer, instruments by Demucs (best quality).
    /// ai: Demucs only (fast). ai6 / eq: older modes, kept so earlier songs still show a label.
    case hq, hq6, ai, ai6, eq
    var id: String { rawValue }

    /// The modes offered for new separations.
    static let picker: [SplitMode] = [.hq, .hq6, .ai]

    var title: String {
        switch self {
        case .hq: "고음질 4트랙"
        case .hq6: "고음질 6트랙"
        case .ai: "빠르게"
        case .ai6: "6트랙 (이전)"
        case .eq: "필터 (이전)"
        }
    }
    var detail: String {
        switch self {
        case .hq: "보컬 · 베이스 · 드럼 · 나머지 악기 · 4분 곡에 약 6~8분"
        case .hq6: "보컬 · 베이스 · 드럼 · 기타 · 피아노 · 나머지 · 4분 곡에 약 8~10분"
        case .ai: "보컬이 조금 덜 깨끗해요 · 4분 곡에 약 20초"
        case .ai6: "기타 · 피아노까지 6개 (이전 방식)"
        case .eq: "주파수로만 자른 이전 방식이라 먹먹해요"
        }
    }

    static func label(_ raw: String) -> String { SplitMode(rawValue: raw)?.title ?? raw }
    static func icon(_ raw: String) -> String {
        switch raw {
        case "eq": "bolt.fill"
        case "ai": "hare.fill"
        default: "sparkles"
        }
    }
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
    @Published var mode: SplitMode = SplitMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "")
        .flatMap { SplitMode.picker.contains($0) ? $0 : nil } ?? .hq {
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

    /// Separates the song again with the same mode, so it gets the latest quality improvements.
    /// Your own recordings and MIDI tracks on it are kept.
    func redo(_ item: Song) {
        guard server == .ready, job == nil else { return }
        if song?.id == item.id { pause() }
        run(label: "\(item.title) → \(SplitMode.label(item.mode)) 다시") {
            try await self.backend.resplit(item.id, mode: item.mode)
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
                var misses = 0
                while true {
                    try await Task.sleep(for: .milliseconds(600))
                    guard let status = try? await backend.job(id) else {
                        misses += 1
                        if misses >= 20 { throw engineStopped() }
                        continue
                    }
                    misses = 0
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

    /// The server stopped answering in the middle of a job (killed, e.g. out of memory). Without this the
    /// job card would spin forever and nothing new could start. Starts it again and explains.
    private func engineStopped() -> BackendError {
        if !backend.isRunning, backend.isInstalled { try? backend.launch() }
        return BackendError(message: "분리 엔진이 멈췄어요 (메모리가 모자라면 그럴 수 있어요). 엔진을 다시 켰으니 한 번 더 시도해 주세요.")
    }

    // MARK: Library

    func open(_ id: String) {
        if editor != nil, song?.id != id {
            guard closeEditor() else { return }
        }
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
        if song?.id != meta.id { rollStem = nil }
        song = meta
        loadingSong = true
        let saved = UserDefaults.standard.dictionary(forKey: "mix.\(meta.id)") as? [String: Int] ?? [:]
        tracks = Dictionary(uniqueKeysWithValues: meta.allTracks.map { ($0, TrackState(volume: saved[$0] ?? 100)) })
        do {
            try mixer.load(meta.allTracks.map { ($0, backend.activeStemURL(meta, $0)) })
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
            if editor != nil { finishEditing() }
            mixer.unload()
            song = nil
            playing = false
        }
        Task {
            try? await backend.delete(item.id)
            withAnimation(.easeOut(duration: 0.2)) { songs.removeAll { $0.id == item.id } }
        }
    }

    // MARK: Storage

    @Published var showStorage = false
    @Published var storage: Backend.Storage?
    @Published var cacheSize: Int64 = 0

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    func refreshStorage() async {
        await refreshSongs()
        storage = try? await backend.storage()
        cacheSize = Int64(Self.folderSize(exportCache))
    }

    private static func folderSize(_ url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]) else { return 0 }
        var total = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink != true { total += v?.fileSize ?? 0 }
        }
        return total
    }

    func deleteSongs(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let names = songs.filter { ids.contains($0.id) }
        let total = names.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let alert = NSAlert()
        alert.messageText = "\(ids.count)곡을 지울까요?"
        alert.informativeText = "\(Self.bytes(total))가 비워져요. 분리한 트랙 · 내 녹음 · MIDI가 같이 지워지고 되돌릴 수 없어요."
        alert.addButton(withTitle: "지우기")
        alert.addButton(withTitle: "취소")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let id = song?.id, ids.contains(id) {
            if editor != nil { finishEditing() }
            mixer.unload()
            song = nil
            playing = false
        }
        Task {
            let freed = (try? await backend.deleteMany(Array(ids))) ?? 0
            await refreshStorage()
            show("\(ids.count)곡 지움 · \(Self.bytes(freed)) 비움")
        }
    }

    /// Left-over originals, temp files and the drag/copy cache (rebuilt when needed).
    func cleanUp() {
        Task {
            var freed = (try? await backend.cleanup()) ?? 0
            let cache = exportCache.deletingLastPathComponent()
            freed += Int64(Self.folderSize(exportCache))
            try? FileManager.default.removeItem(at: cache.appendingPathComponent("Export"))
            renderedMix = nil
            await refreshStorage()
            show("\(Self.bytes(freed)) 비웠어요")
        }
    }

    /// Progress of turning old wav tracks into FLAC (nil when not running).
    @Published var compacting: (step: String, progress: Double)?

    /// Converts every old wav track to FLAC: same sound, close to 40% less space.
    func compactLibrary() {
        guard compacting == nil else { return }
        compacting = ("시작하는 중", 0)
        Task {
            defer { compacting = nil }
            do {
                let id = try await backend.compact()
                var misses = 0
                while true {
                    try await Task.sleep(for: .milliseconds(500))
                    guard let status = try? await backend.job(id) else {
                        misses += 1
                        if misses >= 20 { throw engineStopped() }
                        continue
                    }
                    misses = 0
                    if status.status == "error" { throw BackendError(message: status.error ?? "바꾸지 못했어요") }
                    compacting = (status.step ?? "", status.progress ?? 0)
                    if status.status == "done" {
                        await refreshStorage()
                        show("\(Self.bytes(status.freed ?? 0)) 줄였어요")
                        return
                    }
                }
            } catch {
                show(error.localizedDescription, success: false)
            }
        }
    }

    func reveal(_ item: Song) {
        NSWorkspace.shared.activateFileViewerSelecting([backend.library.appendingPathComponent(item.id)])
    }

    // MARK: Playback

    func togglePlay() {
        guard song != nil else { return }
        leaveTextField()
        if recordingStem != nil { return stopRecording() }
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
            if recordingStem != nil {
                stopRecording()
                return
            }
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
        guard let t = tracks[name], recordingStem != name else { return false }
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
        for name in tracks.keys where !name.hasSuffix("_midi") {  // presets leave MIDI tracks as they are
            tracks[name] = TrackState(volume: preset.volume(for: name))
        }
        applyGains()
    }

    func isActive(_ preset: Preset) -> Bool {
        !tracks.isEmpty && tracks.allSatisfy { name, t in
            name.hasSuffix("_midi") || (!t.muted && !t.solo && t.volume == preset.volume(for: name))
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
        let desc = song.allTracks.map { "\(StemInfo.of($0).label)\(audible($0) ? tracks[$0]!.volume : 0)" }.joined(separator: "_")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(song.title)_\(desc).wav".replacingOccurrences(of: "/", with: "-")
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let inputs = song.allTracks.map { (backend.activeStemURL(song, $0), audible($0) ? Double(tracks[$0]!.volume) / 100 : 0) }
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

    // MARK: Your own tracks

    @Published var recordingStem: String?
    @Published var countdown: Int?
    @Published var recordStart: Double = 0
    @Published var busyStem: String?
    private let recorder = Recorder()

    /// Reloads the open song after its files changed, keeping the playhead.
    private func reload(_ meta: Song) {
        let at = mixer.currentTime, wasPlaying = mixer.isPlaying
        if let i = songs.firstIndex(where: { $0.id == meta.id }) { songs[i] = meta }
        let keep = tracks
        load(meta)
        for (k, v) in keep where tracks[k] != nil { tracks[k] = v }
        applyGains()
        seek(at)
        if wasPlaying { togglePlay() }
    }

    private func updateUserTrack(_ stem: String, _ label: String,
                                 _ call: @escaping () async throws -> Song) {
        guard song != nil else { return }
        busyStem = stem
        Task {
            do {
                let meta = try await call()
                if song?.id == meta.id { reload(meta) }
                if !label.isEmpty { show(label) }
            } catch {
                show(error.localizedDescription, success: false)
            }
            busyStem = nil
        }
    }

    func replace(_ stem: String, with file: URL) {
        guard let song else { return }
        updateUserTrack(stem, "\(StemInfo.of(stem).label)을 내 파일로 바꿨어요") {
            try await self.backend.setUserTrack(song.id, stem: stem, file: file, name: file.deletingPathExtension().lastPathComponent)
        }
    }

    func chooseReplacement(for stem: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "\(StemInfo.of(stem).label) 대신 넣을 오디오 파일을 고르세요"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        replace(stem, with: url)
    }

    func setNudge(_ stem: String, _ seconds: Double) {
        guard let song else { return }
        updateUserTrack(stem, "") { try await self.backend.setUserTrack(song.id, stem: stem, nudge: seconds) }
    }

    func setUseMine(_ stem: String, _ use: Bool) {
        guard let song else { return }
        updateUserTrack(stem, use ? "내 트랙으로 들어요" : "원래 트랙으로 들어요") {
            try await self.backend.setUserTrack(song.id, stem: stem, use: use)
        }
    }

    func removeMine(_ stem: String) {
        guard let song else { return }
        updateUserTrack(stem, "원래 트랙으로 되돌렸어요") { try await self.backend.removeUserTrack(song.id, stem: stem) }
    }

    /// Plays the song with this track muted and records the microphone in sync, after a 3-second count-in.
    func startRecording(_ stem: String) {
        guard song != nil, recordingStem == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording(stem)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in granted ? self.beginRecording(stem) : self.micDenied() }
            }
        default:
            micDenied()
        }
    }

    private func micDenied() {
        let alert = NSAlert()
        alert.messageText = "마이크를 쓸 수 없어요"
        alert.informativeText = "시스템 설정 → 개인정보 보호 및 보안 → 마이크에서 StemMixer를 켜 주세요."
        alert.addButton(withTitle: "설정 열기")
        alert.addButton(withTitle: "닫기")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private var recordingURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StemMixer/recording.caf")
    }

    private func beginRecording(_ stem: String) {
        guard let song else { return }
        if mixer.isPlaying { pause() }
        leaveTextField()
        do {
            try FileManager.default.createDirectory(at: recordingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try recorder.start(to: recordingURL)
        } catch {
            show("녹음을 시작하지 못했어요", success: false)
            return
        }
        recordingStem = stem
        recordStart = mixer.currentTime
        applyGains()  // mutes the track being recorded
        mixer.play(after: 3)
        playing = true
        countdown = 3
        Task {
            for n in [2, 1] {
                try? await Task.sleep(for: .seconds(1))
                guard recordingStem != nil else { return }
                countdown = n
            }
            try? await Task.sleep(for: .seconds(1))
            countdown = nil
        }
        _ = song
    }

    /// Stops and puts the take in place of the track (or throws it away).
    func stopRecording(keep: Bool = true) {
        guard let stem = recordingStem, let song else { return }
        mixer.pause()
        playing = false
        recorder.stop()
        recordingStem = nil
        countdown = nil
        applyGains()
        guard keep, let first = recorder.firstHostTime else {
            if keep { show("녹음된 소리가 없어요", success: false) }
            return
        }
        // Song time of the first recorded sample: where playback started, plus how long after the
        // song started the mic began, minus the time sound spends in the speakers and the mic.
        let lead = AVAudioTime.seconds(forHostTime: first) - AVAudioTime.seconds(forHostTime: mixer.startHostTime)
        let base = recordStart + lead - recorder.inputLatency - mixer.outputLatency
        let stamp = Date().formatted(.dateTime.month().day().hour().minute())
        let url = recordingURL
        updateUserTrack(stem, "녹음을 \(StemInfo.of(stem).label) 자리에 넣었어요") {
            try await self.backend.setUserTrack(song.id, stem: stem, file: url, name: "내 녹음 \(stamp)", base: base)
        }
    }

    // MARK: Notes (MIDI)

    static let midiSounds: [(id: String, title: String)] = [("piano", "피아노"), ("lead", "신스 리드"), ("sine", "사인"), ("strings", "스트링")]

    /// Which MIDI track's piano roll is open.
    @Published var rollStem: String?
    @Published var rollNotes: [MidiNote] = []

    func transcribe(_ stem: String, sound: String, thenEdit: Bool = false) {
        guard let song, server == .ready, job == nil else { return }
        if song.midi(for: stem)?.edited == true {
            let alert = NSAlert()
            alert.messageText = "음정을 다시 뽑을까요?"
            alert.informativeText = "직접 고치거나 가져온 \(StemInfo.of(stem).label) 음표가 AI가 새로 뽑은 음표로 바뀌어요."
            alert.addButton(withTitle: "다시 뽑기")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if editor?.stem == stem { finishEditing() }
        let id = song.id
        jobError = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            job = Job(label: "\(song.title) · \(StemInfo.of(stem).label) 음정")
        }
        Task {
            do {
                let jobID = try await backend.transcribe(id, stem: stem, sound: sound, snap: false)
                var misses = 0
                while true {
                    try await Task.sleep(for: .milliseconds(500))
                    guard let status = try? await backend.job(jobID) else {
                        misses += 1
                        if misses >= 20 { throw engineStopped() }
                        continue
                    }
                    misses = 0
                    if status.status == "error" { throw BackendError(message: status.error ?? "알 수 없는 오류") }
                    job?.step = status.step ?? ""
                    job?.progress = status.progress ?? 0
                    if status.status == "done" { break }
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { job = nil }
                let meta = try await backend.song(id)
                if self.song?.id == id {
                    reload(meta)
                    tracks["\(stem)_midi"] = TrackState()
                    applyGains()
                    if thenEdit { editNotes(stem) } else { openRoll("\(stem)_midi") }
                }
                show("\(StemInfo.of(stem).label) 음정을 뽑았어요 (음표 \(meta.midi(for: stem)?.notes ?? 0)개)")
            } catch {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    job = nil
                    jobError = error.localizedDescription
                }
            }
        }
    }

    func updateMidi(_ stem: String, sound: String? = nil, transpose: Int? = nil, snap: Bool? = nil, tempo: Double? = nil) {
        guard let song else { return }
        updateUserTrack("\(stem)_midi", "") {
            try await self.backend.updateMidi(song.id, stem: stem, sound: sound, transpose: transpose, snap: snap, tempo: tempo)
        }
        if rollStem == "\(stem)_midi" {
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                for _ in 0..<50 where busyStem != nil { try? await Task.sleep(for: .milliseconds(100)) }
                openRoll("\(stem)_midi")
            }
        }
    }

    func removeMidi(_ stem: String) {
        guard let song else { return }
        if rollStem == "\(stem)_midi" { rollStem = nil }
        tracks["\(stem)_midi"] = nil
        updateUserTrack(stem, "음정 트랙을 지웠어요") { try await self.backend.deleteMidi(song.id, stem: stem) }
    }

    /// Exports the melody as an OpenUtau / UTAU project to tune with a vocal synth (e.g. Kasane Teto),
    /// with the backing track inside, so the rendered vocal can be dropped back on the track at 0 s.
    func exportUtau(_ stem: String, quantize: Bool) {
        guard let song else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "여기에 내보내기"
        panel.message = "OpenUtau 프로젝트 폴더를 만들 곳을 고르세요"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        busyStem = "\(stem)_midi"
        Task {
            do {
                let folder = try await backend.utauExport(song.id, stem: stem, dest: dest, quantize: quantize)
                NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("project.ustx")])
                show("OpenUtau 프로젝트를 만들었어요")
            } catch {
                show(error.localizedDescription, success: false)
            }
            busyStem = nil
        }
    }

    func openRoll(_ extraID: String) {
        guard let song, let extra = song.midi(for: extraID) else { return }
        Task {
            if let notes = try? await backend.midiNotes(song.id, stem: extra.source) {
                rollNotes = notes
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { rollStem = extraID }
            }
        }
    }

    /// The .mid file under a readable name, for dragging into an editing app.
    func namedMidi(_ stem: String) -> URL? {
        guard let song else { return nil }
        let source = backend.midiURL(song: song.id, stem: stem)
        let url = exportCache.appendingPathComponent(song.id, isDirectory: true)
            .appendingPathComponent("\(safeName(song.title)) - \(StemInfo.of(stem).label) 음정.mid")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        do { try FileManager.default.copyItem(at: source, to: url) } catch { return nil }
        return url
    }

    func copyMidi(_ stem: String) {
        guard let url = namedMidi(stem) else { return }
        putOnPasteboard([url])
        show("MIDI 파일을 복사했어요")
    }

    // MARK: Note editor

    /// The open note editor (shown in place of the mixer).
    @Published var editor: NoteEditor?
    /// Solo switches from before the editor changed them for "들을 소리".
    private var soloBeforeEditing: [String: Bool] = [:]

    /// Opens the note editor for a stem: its MIDI notes, or a blank score when it has none yet.
    func editNotes(_ stem: String, then: ((NoteEditor) -> Void)? = nil) {
        guard let song else { return }
        if let ed = editor {
            if ed.stem == stem {
                then?(ed)
                return
            }
            guard closeEditor() else { return }
        }
        busyStem = song.midi(for: stem)?.id ?? stem
        Task {
            defer { busyStem = nil }
            let ed: NoteEditor
            do {
                if let midi = song.midi(for: stem) {
                    let d = try await backend.midiDetail(song.id, stem: stem)
                    ed = NoteEditor(stem: stem, tempo: midi.tempo ?? d.tempo, notes: d.notes, ghost: d.ai ?? d.notes,
                                    exists: true, duration: song.duration)
                    ed.origin = d.from
                } else {
                    let tempo = (try? await backend.tempo(song.id)) ?? 120
                    ed = NoteEditor(stem: stem, tempo: tempo, notes: [], ghost: [], exists: false, duration: song.duration)
                }
            } catch {
                show("음표를 열지 못했어요", success: false)
                return
            }
            guard self.song?.id == song.id else { return }
            leaveTextField()
            soloBeforeEditing = tracks.mapValues(\.solo)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { editor = ed }
            setEditorListen(.both)
            then?(ed)
            if ed.canShowPitch { loadPitch(ed, songID: song.id) }
        }
    }

    /// Draws the original voice's pitch behind the notes; reads it first when this track has none yet.
    func loadPitch(_ ed: NoteEditor, songID: String) {
        Task {
            do {
                if let curve = try await backend.pitchCurve(songID, stem: ed.stem) {
                    ed.setPitch(curve)
                    return
                }
                ed.pitchState = .loading(0)
                let id = try await backend.startPitch(songID, stem: ed.stem)
                var misses = 0
                while editor === ed {
                    try await Task.sleep(for: .milliseconds(700))
                    guard let status = try? await backend.job(id) else {
                        misses += 1
                        if misses >= 20 { throw engineStopped() }
                        continue
                    }
                    misses = 0
                    if status.status == "error" { throw BackendError(message: status.error ?? "음 높이를 읽지 못했어요") }
                    ed.pitchState = status.step == "대기 중" ? .waiting : .loading(status.progress ?? 0)
                    if status.status == "done" {
                        guard let curve = try await backend.pitchCurve(songID, stem: ed.stem) else {
                            throw BackendError(message: "음 높이를 읽지 못했어요")
                        }
                        ed.setPitch(curve)
                        return
                    }
                }
            } catch {
                ed.pitchState = .failed(error.localizedDescription)
            }
        }
    }

    /// Which tracks you hear while editing, by switching solos (put back when the editor closes).
    func setEditorListen(_ listen: NoteEditor.Listen) {
        guard let ed = editor else { return }
        ed.listen = listen
        let midi = "\(ed.stem)_midi"
        for name in Array(tracks.keys) {
            switch listen {
            case .all: tracks[name]?.solo = soloBeforeEditing[name] ?? false
            case .source: tracks[name]?.solo = name == ed.stem
            case .notes: tracks[name]?.solo = name == midi
            case .both: tracks[name]?.solo = name == ed.stem || name == midi
            }
        }
        applyGains()
    }

    /// Saves the notes and re-plays the MIDI track, so you hear the edit.
    func applyEditor(close: Bool) {
        guard let song, let ed = editor, !ed.saving else { return }
        ed.canvas?.endLyric()  // a lyric still being typed counts
        if !ed.dirty, ed.exists || ed.notes.isEmpty {
            if close { finishEditing() }
            return
        }
        ed.saving = true
        let stem = ed.stem
        Task {
            do {
                let meta = try await backend.saveNotes(song.id, stem: stem, notes: ed.midiNotes,
                                                       tempo: ed.exists ? nil : ed.tempo, origin: ed.origin)
                ed.exists = true
                ed.dirty = false
                ed.saving = false
                if self.song?.id == meta.id {
                    reload(meta)
                    if editor === ed { setEditorListen(ed.listen) }
                    if rollStem == "\(stem)_midi" { rollNotes = ed.midiNotes }
                }
                show(close ? "음표를 적용했어요" : "적용했어요 · 음표 \(ed.notes.count)개")
                if close, editor === ed { finishEditing() }
            } catch {
                ed.saving = false
                show(error.localizedDescription, success: false)
            }
        }
    }

    /// Closes the editor, asking first when there are edits that weren't applied.
    /// Returns false when it stays open (cancelled, or closing after applying).
    @discardableResult
    func closeEditor() -> Bool {
        guard let ed = editor else { return true }
        ed.canvas?.endLyric()
        if ed.dirty {
            let alert = NSAlert()
            alert.messageText = "고친 음표를 적용할까요?"
            alert.informativeText = "적용하지 않으면 이번에 고친 \(StemInfo.of(ed.stem).label) 음표가 사라져요."
            alert.addButton(withTitle: "적용하고 닫기")
            alert.addButton(withTitle: "버리기")
            alert.addButton(withTitle: "취소")
            alert.buttons[1].hasDestructiveAction = true
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                applyEditor(close: true)
                return false
            case .alertSecondButtonReturn:
                break
            default:
                return false
            }
        }
        finishEditing()
        return true
    }

    func finishEditing() {
        guard let ed = editor else { return }
        ed.preview.stop()
        for name in Array(tracks.keys) { tracks[name]?.solo = soloBeforeEditing[name] ?? false }
        applyGains()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { editor = nil }
    }

    func resetEditorNotes() {
        guard let song, let ed = editor else { return }
        ed.canvas?.endLyric()
        let alert = NSAlert()
        alert.messageText = "AI가 뽑은 음표로 되돌릴까요?"
        alert.informativeText = "직접 고치거나 가져온 \(StemInfo.of(ed.stem).label) 음표가 사라져요."
        alert.addButton(withTitle: "되돌리기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ed.saving = true
        Task {
            do {
                let meta = try await backend.resetNotes(song.id, stem: ed.stem)
                let d = try await backend.midiDetail(song.id, stem: ed.stem)
                reload(meta)
                ed.setNotes(d.notes, add: false)
                ed.selection = []
                ed.dirty = false
                ed.origin = nil
                if editor === ed { setEditorListen(ed.listen) }
                show("AI가 뽑은 음표로 되돌렸어요")
            } catch {
                show(error.localizedDescription, success: false)
            }
            ed.saving = false
        }
    }

    static let noteFileTypes: [UTType] = [.midi] + ["mid", "midi", "ustx", "ust"].compactMap { UTType(filenameExtension: $0) }

    static func isNoteFile(_ url: URL) -> Bool {
        ["mid", "midi", "smf", "kar", "ustx", "ust"].contains(url.pathExtension.lowercased())
    }

    /// Picks a MIDI / OpenUtau / UTAU file and opens its notes in the editor for this stem.
    func importNotes(for stem: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.noteFileTypes
        panel.message = "\(StemInfo.of(stem).label) 음표로 가져올 MIDI(.mid) · OpenUtau(.ustx) · UTAU(.ust) 파일을 고르세요"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importNotesFile(url, stem: stem)
    }

    /// Reads the file's notes and puts them in the editor (replacing or adding to what's there).
    /// Nothing is saved until you press 적용 / 완료. Time 0 in the file = the start of the song.
    func importNotesFile(_ url: URL, stem: String) {
        guard song != nil else { return }
        Task {
            do {
                let file = try await backend.readNotesFile(url)
                guard let notes = pickTrack(file) else { return }
                editNotes(stem) { ed in
                    ed.canvas?.endLyric()
                    var add = false
                    if !ed.notes.isEmpty {
                        let alert = NSAlert()
                        alert.messageText = "가져온 음표를 어떻게 넣을까요?"
                        alert.informativeText = "지금 음표 \(ed.notes.count)개가 있어요. \(file.name)의 음표 \(notes.count)개로 바꾸거나, 지금 음표에 더할 수 있어요. 적용하기 전까지는 저장되지 않아요."
                        alert.addButton(withTitle: "바꾸기")
                        alert.addButton(withTitle: "더하기")
                        alert.addButton(withTitle: "취소")
                        switch alert.runModal() {
                        case .alertFirstButtonReturn: add = false
                        case .alertSecondButtonReturn: add = true
                        default: return
                        }
                    } else if !ed.exists {
                        ed.tempo = file.tempo
                    }
                    ed.origin = file.name
                    ed.setNotes(notes, add: add)
                    self.show("\(file.name)에서 음표 \(notes.count)개를 불러왔어요 · 확인하고 적용하세요")
                }
            } catch {
                show(error.localizedDescription, success: false)
            }
        }
    }

    /// A file with several tracks (a band MIDI file): ask which one to use.
    private func pickTrack(_ file: Backend.NotesFile) -> [MidiNote]? {
        let tracks = file.tracks.filter { !$0.drum } + file.tracks.filter(\.drum)
        if tracks.count == 1 { return tracks[0].notes }
        let alert = NSAlert()
        alert.messageText = "어느 트랙을 가져올까요?"
        alert.informativeText = "\(file.name)에 음표가 있는 트랙이 \(tracks.count)개 있어요."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        for (i, t) in tracks.enumerated() {
            popup.addItem(withTitle: "\(i + 1). \(t.name)\(t.drum ? " (드럼)" : "") · 음표 \(t.notes.count)개")
        }
        popup.addItem(withTitle: "모든 트랙 합치기 (드럼 빼고)")
        alert.accessoryView = popup
        alert.addButton(withTitle: "가져오기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let i = popup.indexOfSelectedItem
        if i < tracks.count { return tracks[i].notes }
        return tracks.filter { !$0.drum }.flatMap(\.notes).sorted { $0.start < $1.start }
    }

    // MARK: Sending tracks to other apps

    private var exportCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StemMixer/Export", isDirectory: true)
    }

    private func safeName(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// Where a stem goes under a readable name ("곡 제목 - 보컬.wav"), so editing apps name the track sensibly.
    private func namedStemTarget(_ stem: String, of song: Song) -> (source: URL, url: URL) {
        let dir = exportCache.appendingPathComponent(song.id, isDirectory: true)
        let mine = song.replaced?[stem]?.use == true ? " (내 녹음)" : ""
        return (backend.activeStemURL(song, stem),
                dir.appendingPathComponent("\(safeName(song.title)) - \(StemInfo.of(stem).label)\(mine).wav"))
    }

    func namedStem(_ stem: String, of song: Song) -> URL? {
        let (source, url) = namedStemTarget(stem, of: song)
        return Self.materialize(source, at: url) ? url : nil
    }

    func namedStems() -> [URL] {
        guard let song else { return [] }
        return song.allTracks.compactMap { namedStem($0, of: song) }
    }

    /// Puts the track at `url` as wav: a hard link to an old wav track (costs no space), or the FLAC unpacked
    /// once (again only when the track changes: the copy carries the track's modification date).
    nonisolated private static func materialize(_ source: URL, at url: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if source.pathExtension == "flac" {
                func modified(_ u: URL) -> Date? { try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                guard let changed = modified(source) else { return false }
                // Same date as the track (within rounding of the stored time) = unpacked from this version.
                if let made = modified(url), abs(made.timeIntervalSince(changed)) < 0.01 { return true }
                try Mixer.writeWav(from: source, to: url)
                try? fm.setAttributes([.modificationDate: changed], ofItemAtPath: url.path)
                return true
            }
            try? fm.removeItem(at: url)  // the track may have been re-recorded since
            // A hard link costs no space; fall back to a copy on another volume.
            do { try fm.linkItem(at: source, to: url) } catch { try fm.copyItem(at: source, to: url) }
            return true
        } catch {
            return false
        }
    }

    /// Unpacks FLAC tracks in the background when the pointer reaches a drag handle, so the drag starts at once.
    func prepareNamedStems(_ stems: [String]) {
        guard let song else { return }
        let jobs = stems.map { namedStemTarget($0, of: song) }.filter { $0.source.pathExtension == "flac" }
        guard !jobs.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            for job in jobs { _ = AppModel.materialize(job.source, at: job.url) }
        }
    }

    /// The named stems, unpacked off the main thread (for copy / reveal, which don't need them at once).
    private func namedStemsLater(_ stems: [String], then done: @escaping ([URL]) -> Void) {
        guard let song else { return }
        let jobs = stems.map { namedStemTarget($0, of: song) }
        Task {
            let urls = await Task.detached(priority: .userInitiated) {
                jobs.compactMap { AppModel.materialize($0.source, at: $0.url) ? $0.url : nil }
            }.value
            done(urls)
        }
    }

    private func putOnPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    func copyStem(_ stem: String) {
        namedStemsLater([stem]) { urls in
            guard !urls.isEmpty else { return }
            self.putOnPasteboard(urls)
            self.show("\(StemInfo.of(stem).label) 트랙을 복사했어요")
        }
    }

    func copyAllStems() {
        guard let song else { return }
        namedStemsLater(song.allTracks) { urls in
            guard !urls.isEmpty else { return }
            self.putOnPasteboard(urls)
            self.show("트랙 \(urls.count)개를 복사했어요")
        }
    }

    func revealStem(_ stem: String) {
        namedStemsLater([stem]) { urls in
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }

    /// Identifies the current mix, so a rendered file is reused until a slider changes.
    var mixSignature: String {
        guard let song else { return "" }
        let user = song.replaced.map { r in r.keys.sorted().map { "\($0)\(r[$0]!.use)\(r[$0]!.nudge)\(r[$0]!.base)\(r[$0]!.name ?? "")" }.joined() } ?? ""
        return song.id + user + song.allTracks.map { "\($0)\(audible($0) ? tracks[$0]!.volume : 0)" }.joined()
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
        let desc = song.allTracks.map { "\(StemInfo.of($0).label)\(audible($0) ? tracks[$0]!.volume : 0)" }.joined(separator: " ")
        let dir = exportCache.appendingPathComponent(song.id, isDirectory: true)
        let url = dir.appendingPathComponent("\(safeName(song.title)) - 믹스 (\(desc)).wav")
        let inputs = song.allTracks.map { (backend.activeStemURL(song, $0), audible($0) ? Double(tracks[$0]!.volume) / 100 : 0) }
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
        let jobs = song.allTracks.map {
            (backend.activeStemURL(song, $0), dir.appendingPathComponent("\(safeName(song.title)) - \(StemInfo.of($0).label).wav"))
        }
        show("트랙 \(jobs.count)개를 wav로 저장하는 중…")
        Task {
            // FLAC tracks are unpacked to wav, off the main thread (a few seconds for a 6-track song).
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let fm = FileManager.default
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    for (source, target) in jobs {
                        if source.pathExtension == "flac" {
                            try Mixer.writeWav(from: source, to: target)
                        } else {
                            try? fm.removeItem(at: target)
                            try fm.copyItem(at: source, to: target)
                        }
                    }
                }
            }.value
            switch result {
            case .success:
                NSWorkspace.shared.activateFileViewerSelecting([dir])
                show("트랙 \(jobs.count)개를 저장했어요")
            case .failure:
                show("저장하지 못했어요", success: false)
            }
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
        // Sheets (가사 한꺼번에 넣기 …) and the lyric field keep their own keys.
        let sheet = window?.sheetParent != nil || window?.attachedSheet != nil
        let lyric = (window?.firstResponder as? NSTextView)?.delegate is LyricField
        if lyric, let ed = editor, flags == .command, event.keyCode == UInt16(kVK_ANSI_S) {
            ed.canvas?.endLyric()
            applyEditor(close: false)
            return true
        }
        // An empty, focused link field shouldn't swallow Space: leave the field and play instead.
        if typing, !sheet, !lyric, input.isEmpty, song != nil, event.keyCode == UInt16(kVK_Space), flags.isEmpty {
            leaveTextField(window)
            typing = false
        }
        if typing, !sheet, !lyric, event.keyCode == UInt16(kVK_Escape) {  // the lyric field (and its IME) handles Esc
            leaveTextField(window)
            return true
        }
        if let ed = editor, !typing, recordingStem == nil, !sheet {
            return handleEditorKey(event, ed)
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
        if recordingStem != nil, flags.isEmpty {
            if event.keyCode == UInt16(kVK_Space) { stopRecording(); return true }
            if event.keyCode == UInt16(kVK_Escape) { stopRecording(keep: false); return true }
        }
        guard !typing, flags.subtracting([.numericPad, .function]).isEmpty, song != nil else { return false }
        switch Int(event.keyCode) {
        case kVK_Space: togglePlay()
        case kVK_RightArrow: seek(mixer.currentTime + 5)
        case kVK_LeftArrow: seek(mixer.currentTime - 5)
        case kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5:
            let number = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].firstIndex(of: Int(event.keyCode))!
            guard let preset = Preset.forKey(number, stems: song?.stems ?? []) else { return false }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { apply(preset) }
        default: return false
        }
        return true
    }
}
