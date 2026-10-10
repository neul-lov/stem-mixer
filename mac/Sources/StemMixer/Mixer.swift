import AVFoundation
import Foundation

/// Plays the separated stems in sync, each through its own gain stage (0–200%).
final class Mixer {
    private struct Track {
        let file: AVAudioFile
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 0)  // only used for its gain, which can go above 100%
    }

    private let engine = AVAudioEngine()
    private var tracks: [String: Track] = [:]
    private var order: [String] = []
    private var startFrame: AVAudioFramePosition = 0
    private(set) var length: AVAudioFramePosition = 0
    private(set) var sampleRate: Double = 44100
    private(set) var isPlaying = false

    /// Latest peak per stem (0...1), written from the audio thread.
    private let levelLock = NSLock()
    private var levels: [String: Float] = [:]

    init() {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in
            // The output device changed (headphones plugged in, etc.); restart where we were.
            guard let self else { return }
            let wasPlaying = self.isPlaying
            let now = self.currentFrame
            self.stopPlayers()
            self.startFrame = now
            try? self.engine.start()
            if wasPlaying { self.play() }
        }
    }

    var duration: Double { Double(length) / sampleRate }

    func load(_ urls: [(String, URL)]) throws {
        unload()
        for (name, url) in urls {
            let track = Track(file: try AVAudioFile(forReading: url))
            engine.attach(track.player)
            engine.attach(track.eq)
            engine.connect(track.player, to: track.eq, format: track.file.processingFormat)
            engine.connect(track.eq, to: engine.mainMixerNode, format: track.file.processingFormat)
            track.eq.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
                self?.measure(name, buffer)
            }
            tracks[name] = track
            order.append(name)
        }
        length = tracks.values.map(\.file.length).min() ?? 0
        sampleRate = tracks.values.first?.file.processingFormat.sampleRate ?? 44100
        startFrame = 0
        engine.prepare()
        try engine.start()
    }

    func unload() {
        stopPlayers()
        for track in tracks.values {
            track.eq.removeTap(onBus: 0)
            engine.detach(track.player)
            engine.detach(track.eq)
        }
        tracks = [:]
        order = []
        length = 0
        levelLock.withLock { levels = [:] }
    }

    func play() {
        guard !tracks.isEmpty else { return }
        if !engine.isRunning { try? engine.start() }
        if startFrame >= length - 1024 { startFrame = 0 }
        let count = AVAudioFrameCount(length - startFrame)
        for track in tracks.values {
            track.player.scheduleSegment(track.file, startingFrame: startFrame, frameCount: count, at: nil)
            track.player.prepare(withFrameCount: 8192)
        }
        // Start every stem on the same host time so they stay sample-aligned.
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        for track in tracks.values { track.player.play(at: start) }
        isPlaying = true
    }

    func pause() {
        let now = currentFrame
        stopPlayers()
        startFrame = now
    }

    private func stopPlayers() {
        for track in tracks.values { track.player.stop() }
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let wasPlaying = isPlaying
        stopPlayers()
        startFrame = max(0, min(AVAudioFramePosition(seconds * sampleRate), length))
        if wasPlaying { play() }
    }

    private var currentFrame: AVAudioFramePosition {
        guard isPlaying, let first = order.first.flatMap({ tracks[$0] }),
              let nodeTime = first.player.lastRenderTime,
              let playerTime = first.player.playerTime(forNodeTime: nodeTime) else { return startFrame }
        return min(length, startFrame + max(0, playerTime.sampleTime))
    }

    var currentTime: Double { Double(currentFrame) / sampleRate }

    /// gain is linear: 1 = 100%, 2 = 200%.
    func setGain(_ gain: Double, for name: String) {
        guard let track = tracks[name] else { return }
        // -96 dB is silence; the EQ's gain also lets a stem go above 100%.
        track.eq.globalGain = gain < 0.005 ? -96 : Float(max(-96, min(24, 20 * log10(gain))))
    }

    func setMaster(_ value: Double) {
        engine.mainMixerNode.outputVolume = Float(value * value)
    }

    func level(_ name: String) -> Float {
        levelLock.withLock { levels[name] ?? 0 }
    }

    private func measure(_ name: String, _ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        var peak: Float = 0
        let n = Int(buffer.frameLength)
        for c in 0..<Int(buffer.format.channelCount) {
            let ch = data[c]
            var i = 0
            while i < n { peak = max(peak, abs(ch[i])); i += 4 }
        }
        levelLock.withLock { levels[name] = peak }
    }

    /// Mixes the stems with the given gains into a 16-bit WAV file.
    static func export(_ inputs: [(URL, Double)], to output: URL) throws {
        let files = try inputs.map { (try AVAudioFile(forReading: $0.0), $0.1) }
        guard let format = files.first?.0.processingFormat else { return }
        let total = files.map(\.0.length).min() ?? 0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        try? FileManager.default.removeItem(at: output)
        let out = try AVAudioFile(forWriting: output, settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 65536
        let mix = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        let read = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        var done: AVAudioFramePosition = 0
        while done < total {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), total - done))
            mix.frameLength = n
            for c in 0..<Int(format.channelCount) { mix.floatChannelData![c].update(repeating: 0, count: Int(n)) }
            for (file, gain) in files where gain > 0 {
                file.framePosition = done
                try file.read(into: read, frameCount: n)
                for c in 0..<Int(format.channelCount) {
                    let dst = mix.floatChannelData![c], src = read.floatChannelData![c]
                    for i in 0..<Int(read.frameLength) { dst[i] += src[i] * Float(gain) }
                }
            }
            for c in 0..<Int(format.channelCount) {
                let dst = mix.floatChannelData![c]
                for i in 0..<Int(n) { dst[i] = max(-1, min(1, dst[i])) }
            }
            try out.write(from: mix)
            done += AVAudioFramePosition(n)
        }
    }
}
