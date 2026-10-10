import Foundation

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

    func job(_ id: String) async throws -> JobStatus {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("api/jobs/\(id)"))
        return try JSONDecoder().decode(JobStatus.self, from: data)
    }
}

struct BackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
