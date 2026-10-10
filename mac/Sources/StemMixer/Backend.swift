import Foundation

/// A track replaced by the user's own file or recording.
struct UserTrack: Codable, Equatable {
    var name: String?
    /// Where the recording starts in the song (seconds); 0 for an imported file.
    var base: Double
    /// Manual sync adjustment in seconds (−2 … +2).
    var nudge: Double
    /// false = play the original track for comparison.
    var use: Bool
}

/// Notes read from a stem, played back by the built-in synth as an extra track ("vocals_midi").
struct MidiTrack: Codable, Equatable, Identifiable {
    let id: String
    let source: String
    var label: String?
    var sound: String
    var snap: Bool
    var transpose: Int
    var notes: Int
    var key: String?
    var tempo: Double?
    /// The notes were changed in the editor (or imported), so "AI 음표로 되돌리기" is possible.
    var edited: Bool?
}

/// [start, end, pitch, velocity] on the wire.
struct MidiNote: Codable, Equatable {
    var start: Double, end: Double, pitch: Int, velocity: Double
    init(start: Double, end: Double, pitch: Int, velocity: Double) {
        self.start = start; self.end = end; self.pitch = pitch; self.velocity = velocity
    }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        start = try c.decode(Double.self); end = try c.decode(Double.self)
        pitch = try c.decode(Int.self); velocity = try c.decode(Double.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        func r(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
        try c.encode(r(start)); try c.encode(r(end)); try c.encode(pitch); try c.encode(r(velocity))
    }
}

struct Song: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let mode: String
    let duration: Double
    let stems: [String]
    var source: String?
    var matched: String?
    var link: String?
    var input: String?
    var replaced: [String: UserTrack]?
    var extras: [MidiTrack]?
    var size: Int64?
    var created: Double?

    /// Stems plus any MIDI tracks made from them.
    var allTracks: [String] { stems + (extras ?? []).map(\.id) }
    func midi(for stem: String) -> MidiTrack? { extras?.first { $0.source == stem || $0.id == stem } }

    /// The part of the id shared by every mode's version of this song.
    var key: String { String(id[..<(id.lastIndex(of: "-") ?? id.endIndex)]) }

    var sourceInfo: (name: String, icon: String) {
        switch source {
        case "spotify": ("Spotify", "dot.radiowaves.left.and.right")
        case "apple": ("Apple Music", "music.note")
        case "youtube": ("YouTube", "play.rectangle.fill")
        case "soundcloud": ("SoundCloud", "cloud.fill")
        case "search": ("검색", "magnifyingglass")
        case "web": ("웹", "globe")
        default: ("파일", "doc.fill")
        }
    }
}

struct JobStatus: Decodable {
    let status: String
    let step: String?
    let progress: Double?
    let song_id: String?
    let error: String?
}

/// Runs the Python separation server (server.py) in the background and talks to it over HTTP.
final class Backend {
    static let port = 8765
    let folder: URL
    private var process: Process?
    private let base = URL(string: "http://127.0.0.1:\(Backend.port)")!
    private var base_: URL { base }

    init() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "StemMixerBackend") as? String
        folder = URL(fileURLWithPath: configured ?? FileManager.default.currentDirectoryPath)
    }

    var python: URL { folder.appendingPathComponent(".venv/bin/python") }
    var library: URL { folder.appendingPathComponent("library") }
    var log: URL { folder.appendingPathComponent("server-app.log") }

    func stemURL(song: String, stem: String) -> URL {
        library.appendingPathComponent(song).appendingPathComponent("\(stem).wav")
    }

    func userStemURL(song: String, stem: String) -> URL {
        library.appendingPathComponent(song).appendingPathComponent("user/\(stem).wav")
    }

    /// The file that should play for a stem: the user's version when it's switched on.
    func activeStemURL(_ song: Song, _ stem: String) -> URL {
        song.replaced?[stem]?.use == true ? userStemURL(song: song.id, stem: stem) : stemURL(song: song.id, stem: stem)
    }

    /// Replaces a stem with a file, or changes the sync / on-off of an existing replacement.
    func setUserTrack(_ songID: String, stem: String, file: URL? = nil, name: String? = nil,
                      base: Double? = nil, nudge: Double? = nil, use: Bool? = nil) async throws -> Song {
        var form = URLComponents()
        var items = [URLQueryItem(name: "stem", value: stem)]
        if let file { items.append(URLQueryItem(name: "path", value: file.path)) }
        if let name { items.append(URLQueryItem(name: "name", value: name)) }
        if let base { items.append(URLQueryItem(name: "base", value: String(base))) }
        if let nudge { items.append(URLQueryItem(name: "nudge", value: String(nudge))) }
        if let use { items.append(URLQueryItem(name: "use", value: use ? "1" : "0")) }
        form.queryItems = items
        var req = URLRequest(url: base_.appendingPathComponent("api/songs/\(songID)/user-track"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw BackendError(message: json?["detail"] as? String ?? "바꾸지 못했어요")
        }
        return try JSONDecoder().decode(Song.self, from: data)
    }

    func midiURL(song: String, stem: String) -> URL {
        library.appendingPathComponent(song).appendingPathComponent("midi/\(stem).mid")
    }

    private func post(_ path: String, _ items: [URLQueryItem]) async throws -> Data {
        var form = URLComponents()
        form.queryItems = items
        var req = URLRequest(url: base_.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw BackendError(message: json?["detail"] as? String ?? "요청이 실패했어요")
        }
        return data
    }

    /// Reads a stem's notes into MIDI and a re-synthesized track. Returns the job id.
    func transcribe(_ songID: String, stem: String, sound: String, snap: Bool) async throws -> String {
        let data = try await post("api/songs/\(songID)/transcribe", [
            URLQueryItem(name: "stem", value: stem), URLQueryItem(name: "sound", value: sound),
            URLQueryItem(name: "snap", value: snap ? "1" : "0"),
        ])
        guard let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["job_id"] as? String else {
            throw BackendError(message: "요청이 실패했어요")
        }
        return id
    }

    func updateMidi(_ songID: String, stem: String, sound: String? = nil, transpose: Int? = nil,
                    snap: Bool? = nil, tempo: Double? = nil) async throws -> Song {
        var items: [URLQueryItem] = []
        if let sound { items.append(URLQueryItem(name: "sound", value: sound)) }
        if let transpose { items.append(URLQueryItem(name: "transpose", value: String(transpose))) }
        if let snap { items.append(URLQueryItem(name: "snap", value: snap ? "1" : "0")) }
        if let tempo { items.append(URLQueryItem(name: "tempo", value: String(tempo))) }
        return try JSONDecoder().decode(Song.self, from: try await post("api/songs/\(songID)/midi/\(stem)", items))
    }

    /// Writes an OpenUtau (.ustx) / UTAU (.ust) project with the backing track into `dest`. Returns the folder.
    func utauExport(_ songID: String, stem: String, dest: URL, quantize: Bool) async throws -> URL {
        let data = try await post("api/songs/\(songID)/utau-export", [
            URLQueryItem(name: "stem", value: stem), URLQueryItem(name: "dest", value: dest.path),
            URLQueryItem(name: "quantize", value: quantize ? "1" : "0"),
        ])
        guard let folder = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["folder"] as? String else {
            throw BackendError(message: "내보내지 못했어요")
        }
        return URL(fileURLWithPath: folder)
    }

    func deleteMidi(_ songID: String, stem: String) async throws -> Song {
        var req = URLRequest(url: base_.appendingPathComponent("api/songs/\(songID)/midi/\(stem)"))
        req.httpMethod = "DELETE"
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(Song.self, from: data)
    }

    func midiNotes(_ songID: String, stem: String) async throws -> [MidiNote] {
        struct R: Decodable { let notes: [MidiNote] }
        let (data, _) = try await URLSession.shared.data(from: base_.appendingPathComponent("api/songs/\(songID)/midi/\(stem).json"))
        return try JSONDecoder().decode(R.self, from: data).notes
    }

    struct NotesDetail: Decodable {
        let notes: [MidiNote]
        let tempo: Double
        let edited: Bool?
        /// The AI's notes when they were edited since.
        let ai: [MidiNote]?
        let from: String?
    }

    func midiDetail(_ songID: String, stem: String) async throws -> NotesDetail {
        let (data, _) = try await URLSession.shared.data(from: base_.appendingPathComponent("api/songs/\(songID)/midi/\(stem).json"))
        return try JSONDecoder().decode(NotesDetail.self, from: data)
    }

    struct NotesFile: Decodable {
        struct Track: Decodable { let name: String; let drum: Bool; let notes: [MidiNote] }
        let tracks: [Track]
        let tempo: Double
        let name: String
    }

    /// Reads the notes of a MIDI / OpenUtau (.ustx) / UTAU (.ust) file without saving anything.
    func readNotesFile(_ file: URL) async throws -> NotesFile {
        let data = try await post("api/notes-file", [URLQueryItem(name: "path", value: file.path)])
        return try JSONDecoder().decode(NotesFile.self, from: data)
    }

    /// Saves edited notes and re-plays the MIDI track (creates it when the stem has none yet).
    func saveNotes(_ songID: String, stem: String, notes: [MidiNote], tempo: Double?, origin: String?) async throws -> Song {
        let json = String(data: try JSONEncoder().encode(notes), encoding: .utf8) ?? "[]"
        var items = [URLQueryItem(name: "notes", value: json)]
        if let tempo { items.append(URLQueryItem(name: "tempo", value: String(tempo))) }
        if let origin { items.append(URLQueryItem(name: "origin", value: origin)) }
        return try JSONDecoder().decode(Song.self, from: try await post("api/songs/\(songID)/midi/\(stem)/notes", items))
    }

    /// Throws away edits and goes back to the notes the AI read (or the first import).
    func resetNotes(_ songID: String, stem: String) async throws -> Song {
        try JSONDecoder().decode(Song.self, from: try await post("api/songs/\(songID)/midi/\(stem)/reset", []))
    }

    /// The song's tempo, measured once (for the beat lines of a blank score).
    func tempo(_ songID: String) async throws -> Double {
        let (data, _) = try await URLSession.shared.data(from: base_.appendingPathComponent("api/songs/\(songID)/tempo"))
        return ((try JSONSerialization.jsonObject(with: data)) as? [String: Any])?["tempo"] as? Double ?? 120
    }

    func removeUserTrack(_ songID: String, stem: String) async throws -> Song {
        var req = URLRequest(url: base_.appendingPathComponent("api/songs/\(songID)/user-track/\(stem)"))
        req.httpMethod = "DELETE"
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(Song.self, from: data)
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("server.py").path)
    }

    func launch() throws {
        // Keep the YouTube downloader current; sites change often and old versions stop working.
        let update = Process()
        update.executableURL = python
        update.arguments = ["-m", "pip", "install", "-q", "--upgrade", "yt-dlp[default]"]
        update.standardOutput = FileHandle.nullDevice
        update.standardError = FileHandle.nullDevice
        try? update.run()

        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let p = Process()
        p.executableURL = python
        p.arguments = ["server.py", "--no-browser", "--port", "\(Backend.port)"]
        p.currentDirectoryURL = folder
        p.standardOutput = handle
        p.standardError = handle
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        try p.run()
        process = p
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func songs() async throws -> [Song] {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("api/songs"))
        return try JSONDecoder().decode([Song].self, from: data)
    }

    func song(_ id: String) async throws -> Song {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("api/songs/\(id)"))
        return try JSONDecoder().decode(Song.self, from: data)
    }

    func delete(_ id: String) async throws {
        var req = URLRequest(url: base.appendingPathComponent("api/songs/\(id)"))
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
    }

    /// Starts a separation job from a link, a search phrase, or a local file. Returns the job id.
    func startJob(text: String? = nil, file: URL? = nil, mode: String) async throws -> String {
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "mode", value: mode)]
        if let text { form.queryItems?.append(URLQueryItem(name: "url", value: text)) }
        if let file { form.queryItems?.append(URLQueryItem(name: "path", value: file.path)) }
        var req = URLRequest(url: base.appendingPathComponent("api/jobs"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let id = json?["job_id"] as? String else {
            throw BackendError(message: json?["detail"] as? String ?? "요청이 실패했어요")
        }
        return id
    }

    /// Separates a song already in the library again with another mode. Returns the job id.
    func resplit(_ songID: String, mode: String) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("api/songs/\(songID)/resplit"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "mode=\(mode)".data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let id = json?["job_id"] as? String else {
            throw BackendError(message: json?["detail"] as? String ?? "요청이 실패했어요")
        }
        return id
    }

    struct Storage: Decodable { let songs: Int64; let sources: Int64; let leftovers: Int64; let models: Int64; let busy: Bool }

    func storage() async throws -> Storage {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("api/storage"))
        return try JSONDecoder().decode(Storage.self, from: data)
    }

    /// Removes left-over originals and temp files. Returns bytes freed.
    func cleanup() async throws -> Int64 {
        var req = URLRequest(url: base.appendingPathComponent("api/cleanup"))
        req.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: req)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["freed"] as? Int64 ?? 0
    }

    func deleteMany(_ ids: [String]) async throws -> Int64 {
        let data = try await post("api/songs/delete-many", [URLQueryItem(name: "ids", value: ids.joined(separator: ","))])
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["freed"] as? Int64 ?? 0
    }

    func job(_ id: String) async throws -> JobStatus {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("api/jobs/\(id)"))
        return try JSONDecoder().decode(JobStatus.self, from: data)
    }
}

struct BackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
