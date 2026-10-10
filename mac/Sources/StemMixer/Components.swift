import SwiftUI

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// The accent capsule used for the main action, as in ClipStack's Copy button.
struct PrimaryCapsule: View {
    let title: String
    let icon: String
    var trailing: String?
    var enabled = true

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .bold))
                    .opacity(0.7)
            }
        }
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.8)],
                                          startPoint: .top, endPoint: .bottom))
        )
        .shadow(color: .accentColor.opacity(enabled ? 0.35 : 0), radius: 8, y: 3)
        .opacity(enabled ? 1 : 0.45)
    }
}

struct CircleIconButton: View {
    let icon: String
    let help: String
    var tint: Color = .primary
    var size: CGFloat = 28
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? tint : .secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0.06)))
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

struct RowAction: View {
    let icon: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? tint : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.1 : 0))
                )
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

struct KeyHint: View {
    let key: String
    let label: String

    init(_ key: String, _ label: String) {
        self.key = key
        self.label = label
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
    }
}

struct SectionTitle: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.system(size: 10, weight: .bold))
        .tracking(0.6)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// A rounded capsule slider: soft track, gradient fill, white knob.
struct CapsuleSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color = .accentColor
    var height: CGFloat = 6
    /// A tick drawn on the track, e.g. the 100% mark.
    var mark: Double?
    var onCommit: ((Double) -> Void)?
    var onDoubleClick: (() -> Void)?

    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let knob: CGFloat = dragging || hovering ? 16 : 14
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09)).frame(height: height)
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, w * f), height: height)
                if let mark {
                    let m = CGFloat((mark - range.lowerBound) / (range.upperBound - range.lowerBound))
                    Capsule().fill(Color.primary.opacity(0.25))
                        .frame(width: 2, height: height + 6)
                        .offset(x: w * m - 1)
                }
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: min(max(0, w * f - knob / 2), w - knob))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        let x = min(max(0, g.location.x / w), 1)
                        value = range.lowerBound + Double(x) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        dragging = false
                        onCommit?(value)
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick?() })
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 20)
    }
}

/// Lays out chips left to right and wraps them onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > maxWidth {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

func formatTime(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return "\(s / 60):" + String(format: "%02d", s % 60)
}

/// Lets you drag one or more files out of the app (to Finder, GarageBand, Logic, Ableton …).
/// `files` is asked for at drag start, so it can return files made just then.
struct FileDragSource<Label: View>: NSViewRepresentable {
    let files: () -> [URL]
    /// Called when the pointer reaches the handle, to get the files ready before a drag starts.
    var prepare: () -> Void = {}
    @ViewBuilder let label: () -> Label

    func makeNSView(context: Context) -> DragHostView {
        let view = DragHostView()
        view.files = files
        view.prepare = prepare
        let host = NSHostingView(rootView: AnyView(label()))
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return view
    }

    func updateNSView(_ view: DragHostView, context: Context) {
        view.files = files
        view.prepare = prepare
        (view.subviews.first as? NSHostingView<AnyView>)?.rootView = AnyView(label())
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DragHostView, context: Context) -> CGSize? {
        nsView.subviews.first?.fittingSize
    }

    final class DragHostView: NSView, NSDraggingSource {
        var files: () -> [URL] = { [] }
        var prepare: () -> Void = {}
        private var downEvent: NSEvent?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { prepare() }

        // Take the mouse ourselves instead of the hosted SwiftUI label.
        override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
        override func mouseDown(with event: NSEvent) { downEvent = event }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDragged(with event: NSEvent) {
            guard let down = downEvent else { return }
            downEvent = nil
            let urls = files()
            guard !urls.isEmpty else { return }
            let items = urls.enumerated().map { i, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let offset = CGFloat(i) * 6
                item.setDraggingFrame(NSRect(x: offset, y: -offset, width: 40, height: 40), contents: icon)
                return item
            }
            beginDraggingSession(with: items, event: down, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy] : []
        }
    }
}
