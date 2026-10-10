import AppKit
import AVFoundation
import Carbon
import SwiftUI

/// One note in the editor. Ids only live while the editor is open (for selection and dragging).
struct EditNote: Identifiable, Equatable {
    var id: Int
    var start: Double
    var end: Double
    var pitch: Int
    var velocity: Double
    /// Sung text for OpenUtau / UTAU export ("" = none).
    var lyric = ""
}

/// The notes being edited for one track, with selection, undo and the view position.
@MainActor
final class NoteEditor: ObservableObject, Identifiable {
    enum Tool: String, CaseIterable { case select, draw }
    enum Listen: String, CaseIterable { case all, source, notes, both }
    enum Grid: Int, CaseIterable, Identifiable {
        case off = 0, quarter = 1, eighth = 2, sixteenth = 4, thirtySecond = 8
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .off: "격자 끄기"
            case .quarter: "1/4 (박)"
            case .eighth: "1/8"
            case .sixteenth: "1/16"
            case .thirtySecond: "1/32"
            }
        }
    }

    let id = UUID()
    /// The stem these notes belong to ("vocals", not "vocals_midi").
    let stem: String
    let duration: Double
    @Published var tempo: Double
    @Published var notes: [EditNote] = [] { didSet { canvas?.needsDisplay = true } }
    @Published var selection: Set<Int> = [] { didSet { canvas?.needsDisplay = true } }
    /// The notes as they were when the editor opened (or the AI's notes), drawn as faint outlines.
    @Published var ghost: [MidiNote]
    @Published var showGhost = true { didSet { canvas?.needsDisplay = true } }
    @Published var dirty = false
    @Published var saving = false
    /// The track exists on the server already (false = blank start or first import).
    var exists: Bool
    /// The file the notes came from, when imported.
    var origin: String?
    @Published var tool: Tool = .select
    @Published var grid: Grid = Grid(rawValue: UserDefaults.standard.integer(forKey: "editor.grid")) ?? .sixteenth {
        didSet { UserDefaults.standard.set(grid.rawValue, forKey: "editor.grid"); canvas?.needsDisplay = true }
    }
    @Published var listen: Listen = .both

    // The original voice's pitch, every `pitchHop` seconds (NaN = silent), drawn as a line behind the notes.
    enum PitchState: Equatable { case none, waiting, loading(Double), ready, failed(String) }
    @Published var pitchState: PitchState = .none
    private(set) var pitchCurve: [Float] = []
    private(set) var pitchHop: Double = 0.01
    @Published var showPitch = UserDefaults.standard.object(forKey: "editor.pitch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPitch, forKey: "editor.pitch"); canvas?.needsDisplay = true }
    }
    /// Only one-note-at-a-time parts have a single pitch to draw.
    var canShowPitch: Bool { stem == "vocals" || stem == "bass" }

    func setPitch(_ curve: Backend.PitchCurve) {
        pitchHop = curve.hop > 0 ? curve.hop : 0.01
        pitchCurve = curve.midi.map { $0.map(Float.init) ?? .nan }
        pitchState = .ready
        canvas?.needsDisplay = true
    }

    /// Opens the "가사 한꺼번에 넣기" sheet.
    @Published var lyricSheet = false {
        didSet { if lyricSheet { canvas?.endLyric() } }
    }

    // View position (not published: only the canvas draws from them).
    var viewStart: Double = 0
    var pxPerSec: CGFloat = 120
    var rowHeight: CGFloat = 14
    var topPitch: Double = 84
    weak var canvas: NoteCanvasView?

    private var undoStack: [[EditNote]] = []
    private var redoStack: [[EditNote]] = []
    private var nextID = 0
    private var clipboard: [EditNote] = []
    let preview = NotePreview()

    init(stem: String, tempo: Double, notes: [MidiNote], ghost: [MidiNote], exists: Bool, duration: Double) {
        self.stem = stem
        self.tempo = tempo
        self.ghost = ghost
        self.exists = exists
        self.duration = max(duration, 1)
        self.notes = notes.map(make)
    }

    private func make(_ n: MidiNote) -> EditNote {
        nextID += 1
        return EditNote(id: nextID, start: n.start, end: n.end, pitch: n.pitch, velocity: n.velocity, lyric: n.lyric ?? "")
    }

    func newNote(start: Double, end: Double, pitch: Int, velocity: Double = 0.8, lyric: String = "") -> EditNote {
        nextID += 1
        return EditNote(id: nextID, start: start, end: end, pitch: pitch, velocity: velocity, lyric: lyric)
    }

    /// A new note with the same pitch, length and lyric, moved by `offset` seconds.
    func copy(of n: EditNote, by offset: Double = 0) -> EditNote {
        newNote(start: n.start + offset, end: n.end + offset, pitch: n.pitch, velocity: n.velocity, lyric: n.lyric)
    }

    var midiNotes: [MidiNote] {
        notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
            .map { MidiNote(start: $0.start, end: $0.end, pitch: $0.pitch, velocity: $0.velocity,
                            lyric: $0.lyric.isEmpty ? nil : $0.lyric) }
    }

    /// Notes in singing order: by start, the top note first when several start together.
    var inOrder: [EditNote] { notes.sorted { ($0.start, -$0.pitch) < ($1.start, -$1.pitch) } }

    var selected: [EditNote] { notes.filter { selection.contains($0.id) } }

    // MARK: Grid

    var beat: Double { 60 / max(tempo, 20) }
    /// Seconds per grid step (0 = no grid).
    var step: Double { grid == .off ? 0 : beat / Double(grid.rawValue) }

    func snap(_ t: Double) -> Double { step > 0 ? (t / step).rounded() * step : t }
    func snapDown(_ t: Double) -> Double { step > 0 ? (t / step).rounded(.down) * step : t }
    /// Length for a new note: one grid step, or an eighth note without a grid.
    var newLength: Double { step > 0 ? step : beat / 2 }

    // MARK: Undo

    /// Call before changing notes; `commit` marks the editor dirty.
    func checkpoint(_ before: [EditNote]? = nil) {
        undoStack.append(before ?? notes)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        dirty = true
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(notes)
        notes = last
        selection = selection.intersection(Set(notes.map(\.id)))
        dirty = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(notes)
        notes = next
        selection = selection.intersection(Set(notes.map(\.id)))
        dirty = true
    }

    var canUndo: Bool { !undoStack.isEmpty }

    // MARK: Edits

    func setNotes(_ new: [MidiNote], add: Bool) {
        checkpoint()
        let made = new.map(make)
        notes = add ? notes + made : made
        selection = Set(made.map(\.id))
        reveal(at: made.map(\.start).min() ?? viewStart)
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        checkpoint()
        notes.removeAll { selection.contains($0.id) }
        selection = []
    }

    func selectAll() { selection = Set(notes.map(\.id)) }

    func transposeSelection(_ semitones: Int) {
        let ids = selection.isEmpty ? Set(notes.map(\.id)) : selection
        guard !ids.isEmpty else { return }
        checkpoint()
        for i in notes.indices where ids.contains(notes[i].id) {
            notes[i].pitch = max(0, min(127, notes[i].pitch + semitones))
        }
        if let first = notes.first(where: { ids.contains($0.id) }) { preview.play(first.pitch) }
    }

    func nudgeSelection(_ direction: Int) {
        guard !selection.isEmpty else { return }
        let by = (step > 0 ? step : 0.05) * Double(direction)
        let minStart = selected.map(\.start).min() ?? 0
        let d = max(by, -minStart)
        checkpoint()
        for i in notes.indices where selection.contains(notes[i].id) {
            notes[i].start += d
            notes[i].end += d
        }
    }

    /// Snaps starts and ends of the selected notes (all notes if none) to the grid.
    func quantize() {
        let s = step > 0 ? step : beat / 4
        let ids = selection.isEmpty ? Set(notes.map(\.id)) : selection
        guard !ids.isEmpty else { return }
        checkpoint()
        for i in notes.indices where ids.contains(notes[i].id) {
            let a = (notes[i].start / s).rounded() * s
            var b = (notes[i].end / s).rounded() * s
            if b <= a { b = a + s }
            notes[i].start = a
            notes[i].end = b
        }
    }

    func copySelection() {
        clipboard = selected
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    /// Pastes the copied notes so the first one starts at `time`.
    func paste(at time: Double) {
        guard let first = clipboard.map(\.start).min() else { return }
        checkpoint()
        let offset = snap(time) - first
        let made = clipboard.map { copy(of: $0, by: offset) }
        notes += made
        selection = Set(made.map(\.id))
    }

    /// Copies the selection right after itself.
    func duplicateSelection() {
        let sel = selected
        guard let a = sel.map(\.start).min(), let b = sel.map(\.end).max() else { return }
        checkpoint()
        var span = b - a
        if step > 0 { span = max(step, (span / step).rounded(.up) * step) }
        let made = sel.map { copy(of: $0, by: span) }
        notes += made
        selection = Set(made.map(\.id))
    }

    // MARK: Lyrics

    /// Which notes "가사 한꺼번에 넣기" fills.
    enum LyricTarget: Hashable { case selected, fromSelected, all }

    func lyricTargets(_ target: LyricTarget) -> [EditNote] {
        let ordered = inOrder
        switch target {
        case .all: return ordered
        case .selected: return ordered.filter { selection.contains($0.id) }
        case .fromSelected:
            guard let first = ordered.firstIndex(where: { selection.contains($0.id) }) else { return ordered }
            return Array(ordered[first...])
        }
    }

    /// Puts the syllables on the notes in singing order. Returns how many notes got one.
    @discardableResult
    func applyLyrics(_ syllables: [String], to target: LyricTarget) -> Int {
        canvas?.endLyric()
        let targets = lyricTargets(target)
        let count = min(targets.count, syllables.count)
        guard count > 0 else { return 0 }
        checkpoint()
        var byID: [Int: String] = [:]
        for i in 0..<count { byID[targets[i].id] = syllables[i] }
        for i in notes.indices { if let text = byID[notes[i].id] { notes[i].lyric = text } }
        return count
    }

    func setLyric(_ text: String, for id: Int) {
        let clean = String(text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).prefix(32))
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].lyric != clean else { return }
        checkpoint()
        notes[i].lyric = clean
    }

    /// Clears the lyrics of the selected notes (all notes if none).
    func clearLyrics() {
        canvas?.endLyric()
        let ids = selection.isEmpty ? Set(notes.map(\.id)) : selection
        guard notes.contains(where: { ids.contains($0.id) && !$0.lyric.isEmpty }) else { return }
        checkpoint()
        for i in notes.indices where ids.contains(notes[i].id) { notes[i].lyric = "" }
    }

    var hasLyrics: Bool { notes.contains { !$0.lyric.isEmpty } }

    // MARK: View

    /// Scrolls so `time` is near the left and the notes around it are in view vertically.
    func reveal(at time: Double) {
        let visible = Double((canvas?.bounds.width ?? 900) - NoteCanvasView.keyWidth) / Double(pxPerSec)
        if time < viewStart || time > viewStart + visible * 0.9 { viewStart = max(0, time - 1) }
        let near = notes.filter { $0.end > viewStart && $0.start < viewStart + visible }.map(\.pitch)
        let pitches = near.isEmpty ? notes.map(\.pitch) : near
        if let lo = pitches.min(), let hi = pitches.max() {
            let rows = Double((canvas?.bounds.height ?? 400) - NoteCanvasView.rulerHeight) / Double(rowHeight)
            topPitch = min(127, max(Double(hi) + 3, (Double(lo + hi) / 2 + rows / 2).rounded()))
        } else {
            topPitch = stem == "bass" ? 60 : 84
        }
        canvas?.needsDisplay = true
    }

    func zoom(_ factor: CGFloat, around x: CGFloat? = nil) {
        let anchorX = x ?? ((canvas?.bounds.width ?? 900) + NoteCanvasView.keyWidth) / 2
        let t = viewStart + Double((anchorX - NoteCanvasView.keyWidth) / pxPerSec)
        pxPerSec = max(8, min(1200, pxPerSec * factor))
        viewStart = max(0, t - Double((anchorX - NoteCanvasView.keyWidth) / pxPerSec))
        canvas?.needsDisplay = true
    }

    func zoomRows(_ factor: CGFloat) {
        rowHeight = max(6, min(36, rowHeight * factor))
        canvas?.needsDisplay = true
    }
}

/// Plays a short tone when a note is placed, moved or clicked, so you hear the pitch while editing.
final class NotePreview {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    var volume: Float = 0.8

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ pitch: Int) {
        guard (0...127).contains(pitch) else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        let buffer = buffers[pitch] ?? tone(pitch)
        buffers[pitch] = buffer
        player.volume = volume
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    /// A soft piano-like tone: a few harmonics that fade, higher ones faster.
    private func tone(_ pitch: Int) -> AVAudioPCMBuffer {
        let sr = 44100.0, length = 0.45
        let frames = AVAudioFrameCount(sr * length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let out = buffer.floatChannelData![0]
        let f = 440 * pow(2, Double(pitch - 69) / 12)
        let harmonics = max(1, min(8, Int(8000 / f)))
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            var v = 0.0
            for k in 1...harmonics {
                v += sin(2 * .pi * f * Double(k) * t) / pow(Double(k), 1.4) * exp(-t * (3 + 2 * Double(k)))
            }
            let attack = min(1, t / 0.005), release = min(1, (length - t) / 0.05)
            out[i] = Float(v * attack * release * 0.3)
        }
        return buffer
    }
}

// MARK: - Canvas

/// The piano roll you can edit: keyboard on the left, bar ruler on top, notes in the grid.
/// Drawn by hand so a whole song (thousands of notes) stays fast.
final class NoteCanvasView: NSView {
    static let keyWidth: CGFloat = 46
    static let rulerHeight: CGFloat = 24

    weak var editor: NoteEditor?
    weak var model: AppModel?
    var color: NSColor = .systemPink

    private enum Drag {
        case none
        case scrub
        case move(anchor: Int, origin: [Int: EditNote], start: NSPoint, lastPitch: Int, copy: Bool)
        case resize(anchor: Int, origin: [Int: EditNote], start: NSPoint)
        case band(start: NSPoint, current: NSPoint, base: Set<Int>)
    }
    private var drag: Drag = .none
    private var before: [EditNote] = []
    private var heldKey: Int?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var keyW: CGFloat { Self.keyWidth }
    private var rulerH: CGFloat { Self.rulerHeight }

    // MARK: Coordinates

    private func x(_ t: Double) -> CGFloat {
        guard let e = editor else { return 0 }
        return keyW + CGFloat(t - e.viewStart) * e.pxPerSec
    }

    private func time(_ x: CGFloat) -> Double {
        guard let e = editor else { return 0 }
        return e.viewStart + Double((x - keyW) / e.pxPerSec)
    }

    /// Top edge of the row for this pitch.
    private func rowTop(_ p: Int) -> CGFloat {
        guard let e = editor else { return 0 }
        return rulerH + CGFloat(e.topPitch - Double(p)) * e.rowHeight
    }

    private func pitch(_ y: CGFloat) -> Int {
        guard let e = editor else { return 60 }
        return Int((e.topPitch - Double((y - rulerH) / e.rowHeight)).rounded(.up))
    }

    private func rect(_ n: EditNote) -> CGRect {
        let h = editor?.rowHeight ?? 14
        return CGRect(x: x(n.start), y: rowTop(n.pitch) + 1, width: max(3, x(n.end) - x(n.start)), height: max(2, h - 2))
    }

    /// The note under the point, and whether the point is on its right edge (resize).
    private func hit(_ p: NSPoint) -> (EditNote, Bool)? {
        guard let e = editor else { return nil }
        for n in e.notes.reversed() {
            let r = rect(n)
            if r.insetBy(dx: -1, dy: 0).contains(p) {
                return (n, p.x > r.maxX - min(7, r.width / 3))
            }
        }
        return nil
    }

    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static func name(_ p: Int) -> String { "\(names[((p % 12) + 12) % 12])\(p / 12 - 1)" }
    private func isBlack(_ p: Int) -> Bool { [1, 3, 6, 8, 10].contains(((p % 12) + 12) % 12) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let e = editor, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, h = bounds.height
        let t = model?.time ?? 0
        // Follow the playhead while playing.
        if model?.playing == true, case .none = drag, lyricNote == nil {
            let visible = Double((w - keyW) / e.pxPerSec)
            if t < e.viewStart || t > e.viewStart + visible * 0.92 { e.viewStart = max(0, t - visible * 0.08) }
        }
        e.topPitch = min(127.5, max(Double((h - rulerH) / e.rowHeight) - 0.5, e.topPitch))

        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let ink = NSColor.labelColor
        let lo = pitch(h) - 1, hi = pitch(rulerH) + 1

        // Rows: black keys darker, a line above every C.
        for p in stride(from: max(0, lo), through: min(127, hi), by: 1) {
            let y = rowTop(p)
            if isBlack(p) {
                ctx.setFillColor(ink.withAlphaComponent(0.045).cgColor)
                ctx.fill(CGRect(x: keyW, y: y, width: w - keyW, height: e.rowHeight))
            }
            if p % 12 == 0 {
                ctx.setFillColor(ink.withAlphaComponent(0.12).cgColor)
                ctx.fill(CGRect(x: keyW, y: y + e.rowHeight - 0.5, width: w - keyW, height: 0.5))
            }
        }

        // Bars, beats and grid lines.
        let t0 = time(keyW), t1 = time(w)
        let beat = e.beat
        let sub = e.step > 0 && Double(e.pxPerSec) * e.step > 7 ? e.step : beat
        var g = (max(0, t0) / sub).rounded(.down) * sub
        while g <= t1 {
            let beatIndex = (g / beat).rounded()
            let onBeat = abs(g / beat - beatIndex) < 1e-6
            let onBar = onBeat && Int(beatIndex) % 4 == 0
            let alpha: CGFloat = onBar ? 0.2 : onBeat ? 0.09 : 0.04
            if onBeat || Double(e.pxPerSec) * sub > 7 {
                ctx.setFillColor(ink.withAlphaComponent(alpha).cgColor)
                ctx.fill(CGRect(x: x(g), y: rulerH, width: onBar ? 1 : 0.5, height: h - rulerH))
            }
            g += sub
        }

        // The notes as they were, as outlines.
        if e.showGhost {
            ctx.setStrokeColor(ink.withAlphaComponent(0.28).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 2])
            for n in e.ghost where n.end > t0 && n.start < t1 {
                let r = CGRect(x: x(n.start), y: rowTop(n.pitch) + 1, width: max(3, x(n.end) - x(n.start)), height: max(2, e.rowHeight - 2))
                ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Notes.
        for n in e.notes where n.end > t0 && n.start < t1 {
            let r = rect(n)
            let sel = e.selection.contains(n.id)
            let playing = n.start <= t && t < n.end && model?.playing == true
            let path = CGPath(roundedRect: r, cornerWidth: min(3, r.height / 2), cornerHeight: min(3, r.height / 2), transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(color.withAlphaComponent(sel || playing ? 1 : 0.45 + 0.45 * n.velocity).cgColor)
            ctx.fillPath()
            if sel {
                ctx.addPath(path)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokePath()
                ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()
            }
        }

        // The pitch the original voice actually sings, over the notes so you see where they differ.
        if e.showPitch, e.pitchState == .ready, !e.pitchCurve.isEmpty {
            drawPitch(e, ctx, from: t0, to: t1)
        }

        // Lyrics (or the pitch name) on the notes.
        if e.rowHeight >= 10 {
            for n in e.notes where n.end > t0 && n.start < t1 && n.id != lyricNote {
                let r = rect(n)
                let text = n.lyric.isEmpty ? (r.width > 30 && e.rowHeight >= 12 ? Self.name(n.pitch) : nil) : n.lyric
                guard let text, r.width > 12 else { continue }
                let font = n.lyric.isEmpty ? NSFont.systemFont(ofSize: 9, weight: .bold)
                                           : NSFont.systemFont(ofSize: min(12, max(9, e.rowHeight - 3)), weight: .semibold)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.95)]
                let size = (text as NSString).size(withAttributes: attrs)
                ctx.saveGState()
                ctx.clip(to: r.insetBy(dx: 2, dy: 0))
                (text as NSString).draw(at: CGPoint(x: r.minX + 4, y: r.midY - size.height / 2), withAttributes: attrs)
                ctx.restoreGState()
            }
        }

        // Selection rectangle.
        if case let .band(a, b, _) = drag {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r)
        }

        // Keyboard.
        NSColor.windowBackgroundColor.setFill()
        CGRect(x: 0, y: rulerH, width: keyW, height: h - rulerH).fill()
        for p in stride(from: max(0, lo), through: min(127, hi), by: 1) {
            let y = rowTop(p)
            let key = CGRect(x: 0, y: y, width: keyW - 1, height: e.rowHeight)
            let black = isBlack(p)
            ctx.setFillColor((heldKey == p ? color : black ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.97, alpha: 1)).cgColor)
            ctx.fill(black ? CGRect(x: 0, y: y, width: keyW * 0.62, height: e.rowHeight) : key)
            if !black {
                ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
                if heldKey != p { ctx.fill(CGRect(x: keyW * 0.62, y: y, width: keyW * 0.38 - 1, height: e.rowHeight)) }
                ctx.setFillColor(NSColor(white: 0.75, alpha: 1).cgColor)
                ctx.fill(CGRect(x: 0, y: y + e.rowHeight - 0.5, width: keyW - 1, height: 0.5))
            } else {
                ctx.setFillColor(NSColor(white: 0.97, alpha: 1).cgColor)
                ctx.fill(CGRect(x: keyW * 0.62, y: y, width: keyW * 0.38 - 1, height: e.rowHeight))
            }
            if p % 12 == 0, e.rowHeight >= 8 {
                (Self.name(p) as NSString).draw(at: CGPoint(x: keyW - 22, y: y + (e.rowHeight - 11) / 2 - 1),
                                                withAttributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
                                                                 .foregroundColor: NSColor(white: 0.35, alpha: 1)])
            }
        }
        ctx.setFillColor(ink.withAlphaComponent(0.15).cgColor)
        ctx.fill(CGRect(x: keyW - 1, y: rulerH, width: 1, height: h - rulerH))

        // Ruler with bar numbers.
        NSColor.windowBackgroundColor.setFill()
        CGRect(x: 0, y: 0, width: w, height: rulerH).fill()
        let bar = beat * 4
        let barPx = Double(e.pxPerSec) * bar
        let every = barPx > 40 ? 1 : barPx > 16 ? 4 : 16
        var b = (max(0, t0) / bar).rounded(.down)
        while b * bar <= t1 {
            let bx = x(b * bar)
            if Int(b) % every == 0, bx >= keyW - 1 {
                ctx.setFillColor(ink.withAlphaComponent(0.3).cgColor)
                ctx.fill(CGRect(x: bx, y: rulerH - 8, width: 1, height: 8))
                ("\(Int(b) + 1)" as NSString).draw(at: CGPoint(x: bx + 3, y: 4),
                                                  withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
                                                                   .foregroundColor: NSColor.secondaryLabelColor])
            }
            b += 1
        }
        ctx.setFillColor(ink.withAlphaComponent(0.15).cgColor)
        ctx.fill(CGRect(x: 0, y: rulerH - 1, width: w, height: 1))
        ("마디" as NSString).draw(at: CGPoint(x: 8, y: 5),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
                                                  .foregroundColor: NSColor.tertiaryLabelColor])

        // Playhead.
        let px = x(t)
        if px >= keyW {
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.fill(CGRect(x: px - 0.75, y: 0, width: 1.5, height: h))
            let tri = CGMutablePath()
            tri.move(to: CGPoint(x: px - 5, y: 0))
            tri.addLine(to: CGPoint(x: px + 5, y: 0))
            tri.addLine(to: CGPoint(x: px, y: 7))
            tri.closeSubpath()
            ctx.addPath(tri)
            ctx.fillPath()
        }
    }

    private func drawPitch(_ e: NoteEditor, _ ctx: CGContext, from t0: Double, to t1: Double) {
        let curve = e.pitchCurve, hop = e.pitchHop
        let i0 = max(0, Int(t0 / hop) - 1), i1 = min(curve.count - 1, Int(t1 / hop) + 1)
        guard i0 < i1 else { return }
        // About one point per pixel when zoomed out.
        let stride = max(1, Int(1 / (Double(e.pxPerSec) * hop)))
        let path = CGMutablePath()
        var last: Float = .nan
        var i = i0
        while i <= i1 {
            let m = curve[i]
            if m.isNaN {
                last = .nan
            } else {
                let p = CGPoint(x: x(Double(i) * hop), y: rulerH + CGFloat(e.topPitch - Double(m)) * e.rowHeight + e.rowHeight / 2)
                // Jumps of more than 3 semitones are breaks (an octave slip, a new phrase), not slides.
                if last.isNaN || abs(m - last) > 3 { path.move(to: p) } else { path.addLine(to: p) }
                last = m
            }
            i += stride
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        // A light halo first so the line reads on top of the colored notes too.
        ctx.setStrokeColor(NSColor.textBackgroundColor.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.75).cgColor)
        ctx.setLineWidth(1.4)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Lyric typing

    private var lyricField: LyricField?
    /// The note whose lyric is being typed.
    private(set) var lyricNote: Int?
    private var lyricOpenedWith = ""
    private var movingLyric = false

    /// Starts typing the lyric of a note (the first selected one by default). Return / Tab go to the next note.
    func beginLyric(_ id: Int? = nil) {
        guard let e = editor, let target = id ?? e.inOrder.first(where: { e.selection.contains($0.id) })?.id else { return }
        showLyricField(for: target)
    }

    private func showLyricField(for id: Int) {
        if lyricNote != nil { commitLyric() }  // keep what was typed for the last note
        guard let e = editor, let n = e.notes.first(where: { $0.id == id }) else { return endLyric() }
        // Bring the note into view.
        let visible = Double((bounds.width - keyW) / e.pxPerSec)
        if n.start < e.viewStart || n.end > e.viewStart + visible * 0.9 { e.viewStart = max(0, n.start - visible * 0.15) }
        let rows = Double((bounds.height - rulerH) / e.rowHeight)
        if Double(n.pitch) > e.topPitch - 1 || Double(n.pitch) < e.topPitch - rows + 1 {
            e.topPitch = min(127.5, Double(n.pitch) + rows / 2)
        }
        let field = lyricField ?? makeLyricField()
        movingLyric = true
        if lyricNote != nil { window?.makeFirstResponder(self) }  // finish the field editor for the last note
        lyricNote = id
        lyricOpenedWith = n.lyric
        e.selection = [id]
        field.stringValue = n.lyric
        let r = rect(n)
        field.frame = CGRect(x: max(keyW, r.minX - 2), y: r.midY - 11, width: max(70, min(r.width + 4, 180)), height: 22)
        if field.superview == nil { addSubview(field) }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        movingLyric = false
        needsDisplay = true
    }

    private func makeLyricField() -> LyricField {
        let f = LyricField()
        f.font = .systemFont(ofSize: 12, weight: .semibold)
        f.placeholderString = "가사"
        f.alignment = .left
        f.bezelStyle = .roundedBezel
        f.cell?.usesSingleLineMode = true
        f.cell?.lineBreakMode = .byClipping
        f.delegate = self
        lyricField = f
        return f
    }

    private func commitLyric() {
        guard let e = editor, let id = lyricNote, let field = lyricField else { return }
        // Untouched: leave the note alone (a menu or the sheet may have changed its lyric meanwhile).
        guard field.stringValue != lyricOpenedWith else { return }
        e.setLyric(field.stringValue, for: id)
        lyricOpenedWith = field.stringValue
    }

    /// Next (or previous) note in singing order, with the field moved there; closes after the last one.
    private func moveLyric(_ direction: Int) {
        guard let e = editor, let id = lyricNote else { return }
        commitLyric()
        let ordered = e.inOrder
        if let i = ordered.firstIndex(where: { $0.id == id }), ordered.indices.contains(i + direction) {
            showLyricField(for: ordered[i + direction].id)
        } else {
            endLyric(commit: false)
        }
    }

    func endLyric(commit: Bool = true) {
        guard lyricNote != nil else { return }
        if commit { commitLyric() }
        lyricNote = nil
        lyricField?.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }

    private func updateCursor(_ p: NSPoint) {
        if p.y < rulerH || p.x < keyW { NSCursor.arrow.set(); return }
        if let (_, edge) = hit(p) {
            (edge ? NSCursor.resizeLeftRight : NSCursor.openHand).set()
        } else {
            (editor?.tool == .draw ? NSCursor.crosshair : NSCursor.arrow).set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let e = editor else { return }
        endLyric()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        before = e.notes
        if p.y < rulerH {
            model?.seek(max(0, time(max(p.x, keyW))))
            drag = .scrub
            needsDisplay = true
            return
        }
        if p.x < keyW {
            heldKey = pitch(p.y)
            e.preview.play(pitch(p.y))
            needsDisplay = true
            return
        }
        let hitNote = hit(p)
        if event.clickCount == 2 {
            if let (n, _) = hitNote {
                e.checkpoint()
                e.notes.removeAll { $0.id == n.id }
                e.selection.remove(n.id)
            } else {
                addNote(at: p)
            }
            drag = .none
            return
        }
        if hitNote == nil, e.tool == .draw {
            addNote(at: p, undoable: false)  // mouseUp records the add + length as one undo step
            if let id = e.selection.first, let n = e.notes.first(where: { $0.id == id }) {
                drag = .resize(anchor: id, origin: [id: n], start: p)
            }
            return
        }
        guard let (n, edge) = hitNote else {
            if !flags.contains(.shift) { e.selection = [] }
            drag = .band(start: p, current: p, base: flags.contains(.shift) ? e.selection : [])
            return
        }
        let anchor = n.id
        if flags.contains(.shift) || flags.contains(.command) {
            if e.selection.contains(n.id) {
                e.selection.remove(n.id)
                drag = .none
                return
            }
            e.selection.insert(n.id)
        } else if !e.selection.contains(n.id) {
            e.selection = [n.id]
        }
        let origin = Dictionary(uniqueKeysWithValues: e.selected.map { ($0.id, $0) })
        drag = edge ? .resize(anchor: anchor, origin: origin, start: p)
                    : .move(anchor: anchor, origin: origin, start: p, lastPitch: n.pitch,
                            copy: flags.contains(.option))  // ⌥-drag copies (once the mouse moves)
        e.preview.play(n.pitch)
    }

    private func addNote(at p: NSPoint, undoable: Bool = true) {
        guard let e = editor else { return }
        let start = max(0, e.snapDown(time(p.x)))
        let note = e.newNote(start: start, end: start + e.newLength, pitch: max(0, min(127, pitch(p.y))))
        if undoable { e.checkpoint() }
        e.notes.append(note)
        e.selection = [note.id]
        e.preview.play(note.pitch)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let e = editor else { return }
        let p = convert(event.locationInWindow, from: nil)
        let free = event.modifierFlags.contains(.command)  // ⌘ while dragging: ignore the grid
        func snap(_ t: Double) -> Double { free ? t : e.snap(t) }
        switch drag {
        case .none:
            break
        case .scrub:
            model?.seek(max(0, time(max(p.x, keyW))))
        case .move(let anchor0, var origin, let start, let lastPitch, let copy):
            var anchor = anchor0
            if copy {
                guard abs(p.x - start.x) > 2 || abs(p.y - start.y) > 2 else { return }
                var copies: [Int: EditNote] = [:]
                for o in origin.values {
                    let c = e.copy(of: o)
                    copies[c.id] = c
                    if o.id == anchor0 { anchor = c.id }
                }
                e.notes += copies.values.sorted { $0.start < $1.start }
                e.selection = Set(copies.keys)
                origin = copies
                drag = .move(anchor: anchor, origin: origin, start: start, lastPitch: lastPitch, copy: false)
            }
            guard let a = origin[anchor] else { return }
            var dt = snap(a.start + (time(p.x) - time(start.x))) - a.start
            dt = max(dt, -(origin.values.map(\.start).min() ?? 0))
            var dp = Int((-(p.y - start.y) / e.rowHeight).rounded())
            let pitches = origin.values.map(\.pitch)
            dp = max(dp, -(pitches.min() ?? 0))
            dp = min(dp, 127 - (pitches.max() ?? 127))
            for i in e.notes.indices {
                guard let o = origin[e.notes[i].id] else { continue }
                e.notes[i].start = o.start + dt
                e.notes[i].end = o.end + dt
                e.notes[i].pitch = o.pitch + dp
            }
            if a.pitch + dp != lastPitch {
                e.preview.play(a.pitch + dp)
                drag = .move(anchor: anchor, origin: origin, start: start, lastPitch: a.pitch + dp, copy: false)
            }
        case let .resize(anchor, origin, start):
            guard let a = origin[anchor] else { return }
            let minLen = free || e.step == 0 ? 0.03 : e.step
            let newEnd = max(a.start + minLen, snap(a.end + (time(p.x) - time(start.x))))
            let delta = newEnd - a.end
            for i in e.notes.indices {
                guard let o = origin[e.notes[i].id] else { continue }
                e.notes[i].end = max(o.start + minLen, o.end + delta)
            }
        case let .band(start, _, base):
            drag = .band(start: start, current: p, base: base)
            let r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(start.x - p.x), height: abs(start.y - p.y))
            e.selection = base.union(e.notes.filter { rect($0).intersects(r) }.map(\.id))
        }
        autoscroll(p)
        needsDisplay = true
    }

    /// Scrolls when dragging past the left or right edge.
    private func autoscroll(_ p: NSPoint) {
        guard let e = editor else { return }
        if p.x > bounds.width - 12 { e.viewStart += Double(20 / e.pxPerSec) }
        if p.x < keyW + 6, e.viewStart > 0 { e.viewStart = max(0, e.viewStart - Double(20 / e.pxPerSec)) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let e = editor else { return }
        switch drag {
        case .move, .resize:
            if e.notes != before {
                e.checkpoint(before)
            }
        default:
            break
        }
        drag = .none
        heldKey = nil
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let e = editor else { return }
        endLyric()
        let p = convert(event.locationInWindow, from: nil)
        if let (n, _) = hit(p), !e.selection.contains(n.id) { e.selection = [n.id] }
        let menu = NSMenu()
        func item(_ title: String, _ key: String = "", _ action: @escaping () -> Void) {
            let it = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
            menu.addItem(it)
        }
        let at = time(p.x)
        if !e.selection.isEmpty {
            item("가사 넣기 (Return)") { [weak self] in self?.beginLyric() }
            if e.selected.contains(where: { !$0.lyric.isEmpty }) {
                item("가사 지우기") { e.clearLyrics() }
            }
            menu.addItem(.separator())
            item("지우기") { e.deleteSelection() }
            item("복제 (바로 뒤에)") { e.duplicateSelection() }
            item("박자 맞추기") { e.quantize() }
            item("반음 올리기") { e.transposeSelection(1) }
            item("반음 내리기") { e.transposeSelection(-1) }
            item("옥타브 올리기") { e.transposeSelection(12) }
            item("옥타브 내리기") { e.transposeSelection(-12) }
            item("복사") { e.copySelection() }
            menu.addItem(.separator())
        }
        item("가사 한꺼번에 넣기…") { e.lyricSheet = true }
        item("여기에 붙여넣기") { e.paste(at: at) }
        item("여기서부터 재생") { [weak self] in
            self?.model?.seek(max(0, at))
            if self?.model?.playing == false { self?.model?.togglePlay() }
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let e = editor else { return }
        endLyric()
        let p = convert(event.locationInWindow, from: nil)
        var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { dx *= 12; dy *= 12 }
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) {
            e.zoom(exp(dy * 0.01), around: max(p.x, keyW))
            return
        }
        if flags.contains(.option) {
            e.zoomRows(exp(dy * 0.01))
            return
        }
        if flags.contains(.shift), dx == 0 { dx = dy; dy = 0 }
        e.viewStart = max(0, min(e.duration, e.viewStart - Double(dx / e.pxPerSec)))
        e.topPitch = max(0, min(127.5, e.topPitch + Double(dy / e.rowHeight)))
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        endLyric()
        let p = convert(event.locationInWindow, from: nil)
        editor?.zoom(1 + event.magnification, around: max(p.x, keyW))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }
}

extension NoteCanvasView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            moveLyric(1)
        case #selector(NSResponder.insertBacktab(_:)):
            moveLyric(-1)
        case #selector(NSResponder.cancelOperation(_:)):
            endLyric()
        default:
            return false
        }
        return true
    }

    /// Clicked somewhere else: keep what was typed.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !movingLyric, lyricNote != nil else { return }
        commitLyric()
        lyricNote = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lyricNote == nil else { return }
            self.lyricField?.removeFromSuperview()
            self.needsDisplay = true
        }
    }
}

/// The small text box for typing a note's lyric (the key handler leaves its keys alone).
final class LyricField: NSTextField {}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, keyEquivalent: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

struct NoteCanvas: NSViewRepresentable {
    @ObservedObject var editor: NoteEditor
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> NoteCanvasView {
        let view = NoteCanvasView()
        view.editor = editor
        view.model = model
        view.color = NSColor(StemInfo.of(editor.stem).color)
        editor.canvas = view
        DispatchQueue.main.async { editor.reveal(at: model.time) }
        return view
    }

    func updateNSView(_ view: NoteCanvasView, context: Context) {
        view.editor = editor
        view.model = model
        editor.canvas = view
        editor.preview.volume = Float(model.master)
        view.needsDisplay = true
    }
}

// MARK: - Screen

/// Full editor shown in place of the mixer: toolbar, the editable piano roll, and hints.
struct NoteEditorView: View {
    @ObservedObject var editor: NoteEditor
    @ObservedObject var model: AppModel

    private var info: StemInfo { StemInfo.of(editor.stem) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 34)
                .padding(.bottom, 10)
            toolbar
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            NoteCanvas(editor: editor, model: model)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .padding(.horizontal, 20)
            hints
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .sheet(isPresented: $editor.lyricSheet) { LyricsSheet(editor: editor) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { model.closeEditor() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("믹서로")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("편집 화면 닫기")

            Circle().fill(info.color.gradient).frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text("음표 편집 · \(info.label)")
                    .font(.system(size: 17, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button("MIDI · OpenUtau · UTAU 파일 가져오기…") { model.importNotes(for: editor.stem) }
                Divider()
                Button("가사 한꺼번에 넣기…") { editor.lyricSheet = true }
                    .disabled(editor.notes.isEmpty)
                Button(editor.selection.isEmpty ? "가사 모두 지우기" : "선택한 음표의 가사 지우기") { editor.clearLyrics() }
                    .disabled(!editor.hasLyrics)
                Divider()
                Button("모든 음표 지우기") {
                    editor.selectAll()
                    editor.deleteSelection()
                }
                .disabled(editor.notes.isEmpty)
                if model.song?.midi(for: editor.stem)?.edited == true {
                    Button("AI가 뽑은 음표로 되돌리기…") { model.resetEditorNotes() }
                }
            } label: {
                Label("가져오기 · 더보기", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                model.applyEditor(close: false)
            } label: {
                Text(editor.saving ? "적용 중…" : "적용해서 듣기")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(PressableStyle())
            .disabled(!editor.dirty || editor.saving)
            .opacity(editor.dirty ? 1 : 0.5)
            .help("고친 음표로 음정 트랙 소리를 다시 만들어요")

            Button { model.applyEditor(close: true) } label: {
                PrimaryCapsule(title: "완료", icon: "checkmark", enabled: !editor.saving)
            }
            .buttonStyle(PressableStyle())
            .disabled(editor.saving)
            .help("적용하고 믹서로 돌아가기")
        }
    }

    private var subtitle: String {
        var parts = ["음표 \(editor.notes.count)개"]
        if !editor.selection.isEmpty { parts.append("\(editor.selection.count)개 선택") }
        parts.append("\(Int(editor.tempo.rounded())) BPM")
        if let key = model.song?.midi(for: editor.stem)?.key { parts.append(key) }
        if let origin = editor.origin { parts.append("가져온 파일: \(origin)") }
        if editor.dirty { parts.append("아직 적용 안 함") }
        return parts.joined(separator: " · ")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.accentColor.gradient))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .help("재생 / 정지 (Space)")
            Text("\(formatTime(model.time)) / \(formatTime(model.duration))")
                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.secondary)

            divider

            Picker("", selection: $editor.tool) {
                Image(systemName: "cursorarrow").help("선택 · 옮기기").tag(NoteEditor.Tool.select)
                Image(systemName: "pencil").help("그리기: 빈 곳을 누르면 음표, 끌면 길이").tag(NoteEditor.Tool.draw)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 76)

            Picker("", selection: $editor.grid) {
                ForEach(NoteEditor.Grid.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 96)
            .help("음표를 놓고 옮길 때 맞출 격자 (끄는 중에 ⌘를 누르면 격자 무시)")

            toolButton("metronome", "박자 맞추기", help: "선택한 음표(없으면 전체)를 격자에 맞춰요 (Q)") { editor.quantize() }
            toolButton("arrow.down", "반음", help: "선택한 음표(없으면 전체)를 반음 내려요 (↓)") { editor.transposeSelection(-1) }
            toolButton("arrow.up", "반음", help: "선택한 음표(없으면 전체)를 반음 올려요 (↑)") { editor.transposeSelection(1) }

            divider

            Picker("", selection: Binding(get: { editor.listen }, set: { model.setEditorListen($0) })) {
                Text("전체 곡").tag(NoteEditor.Listen.all)
                Text("원래 \(info.label)").tag(NoteEditor.Listen.source)
                Text("음표").tag(NoteEditor.Listen.notes)
                Text("둘 다").tag(NoteEditor.Listen.both)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("편집하면서 들을 소리. '음표'는 적용한 뒤의 소리예요")

            Spacer(minLength: 0)

            if editor.canShowPitch {
                Toggle(isOn: $editor.showPitch) { Text(pitchLabel).font(.system(size: 11, weight: .semibold)).monospacedDigit() }
                    .toggleStyle(.checkbox)
                    .help(pitchHelp)
            }
            Toggle(isOn: $editor.showGhost) { Text("원래 윤곽").font(.system(size: 11, weight: .semibold)) }
                .toggleStyle(.checkbox)
                .help("처음 열었을 때(또는 AI가 뽑은) 음표를 점선으로 보여 줘요")
            toolButton("minus.magnifyingglass", nil, help: "좁게 보기 (⌘ + 스크롤)") { editor.zoom(1 / 1.4) }
            toolButton("plus.magnifyingglass", nil, help: "넓게 보기 (⌘ + 스크롤, 핀치)") { editor.zoom(1.4) }
        }
        .font(.system(size: 11.5, weight: .semibold))
    }

    private var pitchLabel: String {
        switch editor.pitchState {
        case .waiting: "음높이 선 (차례 기다리는 중)"
        case .loading(let p): "음높이 선 읽는 중 \(Int(p * 100))%"
        case .failed: "음높이 선 (못 읽음)"
        default: "음높이 선"
        }
    }

    private var pitchHelp: String {
        if case .failed(let message) = editor.pitchState { return message }
        return "원래 \(info.label)가 실제로 부르는 음높이를 선으로 보여 줘요. 음표가 선보다 높거나 낮은 곳을 고치면 돼요"
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 20)
    }

    private func toolButton(_ icon: String, _ title: String?, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                if let title { Text(title) }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }

    private var hints: some View {
        HStack(spacing: 14) {
            KeyHint("더블클릭", "음표 추가 · 지우기")
            KeyHint("끌기", "옮기기")
            KeyHint("오른쪽 끝", "길이")
            KeyHint("⌥ 끌기", "복사")
            KeyHint("Delete", "지우기")
            KeyHint("Return", "가사")
            KeyHint("↑ ↓", "반음 (⇧ 옥타브)")
            KeyHint("⌘Z", "되돌리기")
            KeyHint("Space", "재생")
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

extension AppModel {
    /// Keys while the note editor is open. Returns true when handled.
    func handleEditorKey(_ event: NSEvent, _ e: NoteEditor) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = Int(event.keyCode)
        if flags.contains(.command) {
            switch key {
            case kVK_ANSI_Z: flags.contains(.shift) ? e.redo() : e.undo()
            case kVK_ANSI_A: e.selectAll()
            case kVK_ANSI_C: e.copySelection()
            case kVK_ANSI_X: e.cutSelection()
            case kVK_ANSI_V: e.paste(at: time)
            case kVK_ANSI_D: e.duplicateSelection()
            case kVK_ANSI_S: applyEditor(close: false)
            default: return false
            }
            return true
        }
        guard flags.subtracting(.shift).isEmpty else { return false }
        switch key {
        case kVK_Space: togglePlay()
        case kVK_Delete, kVK_ForwardDelete: e.deleteSelection()
        case kVK_UpArrow: e.transposeSelection(flags.contains(.shift) ? 12 : 1)
        case kVK_DownArrow: e.transposeSelection(flags.contains(.shift) ? -12 : -1)
        case kVK_LeftArrow, kVK_RightArrow:
            let dir = key == kVK_LeftArrow ? -1 : 1
            if e.selection.isEmpty { seek(time + Double(dir) * 5) } else { e.nudgeSelection(dir) }
        case kVK_ANSI_Q: e.quantize()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard !e.selection.isEmpty else { return false }
            e.canvas?.beginLyric()
        case kVK_Escape: e.selection = []
        default: return false
        }
        return true
    }
}

// MARK: - Lyrics

enum Lyrics {
    private static let small: Set<Character> = Set("ぁぃぅぇぉゃゅょゎゕゖァィゥェォャュョヮヵヶ")

    private static func isKana(_ c: Character?) -> Bool {
        guard let v = c?.unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(v) || (0xFF66...0xFF9D).contains(v)
    }

    /// Hangul, kana and CJK characters are one note each; other letters (café, niño) build words.
    private static func isSyllableScript(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return isKana(c) || (0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v)
            || (0x3400...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0x20000...0x2FFFF).contains(v)
    }

    /// Splits typed or pasted lyrics into one piece per note: a kana (きゃ keeps its small ゃ), a Hangul
    /// syllable, a CJK character, or a whole Latin word. Spaces and punctuation only separate.
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        func flush() { if !word.isEmpty { out.append(word); word = "" } }
        for c in text {
            if !isSyllableScript(c), c.isLetter || c.isNumber || "'’‘+-~".contains(c) {
                word.append(c)
                continue
            }
            flush()
            if c.isWhitespace || c.isPunctuation || (c.isSymbol && !isKana(c)) { continue }
            if small.contains(c), let last = out.last, isKana(last.last), !small.contains(last.last!) {
                out[out.count - 1].append(c)
            } else {
                out.append(String(c))
            }
        }
        flush()
        return out
    }
}

/// "가사 한꺼번에 넣기": paste a verse, and each syllable goes on the next note.
struct LyricsSheet: View {
    @ObservedObject var editor: NoteEditor
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var target: NoteEditor.LyricTarget = .all

    private var syllables: [String] { Lyrics.split(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("가사 한꺼번에 넣기").font(.system(size: 15, weight: .bold))
            Text("가사를 붙여 넣으면 음절마다 음표에 차례로 들어가요. 일본어는 가나 한 글자(きゃ처럼 작은 글자는 앞 글자와 함께), 한국어는 한 글자, 영어는 띄어 쓴 단어 하나가 음표 하나예요.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            if !editor.selection.isEmpty {
                Picker("넣을 곳", selection: $target) {
                    if editor.selection.count > 1 { Text("선택한 음표 \(editor.selection.count)개에만").tag(NoteEditor.LyricTarget.selected) }
                    Text("선택한 첫 음표부터 끝까지").tag(NoteEditor.LyricTarget.fromSelected)
                    Text("처음 음표부터").tag(NoteEditor.LyricTarget.all)
                }
                .pickerStyle(.radioGroup)
                .font(.system(size: 12))
            }
            Text(summary)
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("넣기") {
                    editor.applyLyrics(syllables, to: target)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(syllables.isEmpty)
                .help("⌘Return")
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            target = editor.selection.count > 1 ? .selected : editor.selection.isEmpty ? .all : .fromSelected
        }
    }

    private var summary: String {
        let notes = editor.lyricTargets(target).count
        guard !syllables.isEmpty else { return "음표 \(notes)개에 넣을 수 있어요" }
        let shown = syllables.prefix(12).joined(separator: " · ") + (syllables.count > 12 ? " …" : "")
        let fit = syllables.count > notes ? " (남는 \(syllables.count - notes)개는 안 들어가요)" : ""
        return "음절 \(syllables.count)개 → 음표 \(min(notes, syllables.count))개\(fit): \(shown)"
    }
}
