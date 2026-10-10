import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var dropping = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 330)
                .background(Color.primary.opacity(0.03))
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
            PlayerView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fontDesign(.rounded)
        .ignoresSafeArea()
        .overlay { if dropping { dropOverlay } }
        .overlay(alignment: .bottom) { toast }
        .onDrop(of: [.fileURL], isTargeted: $dropping.animation(.easeOut(duration: 0.15))) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.submit(file: url) }
            }
            return true
        }
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            VStack(spacing: 10) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 38, weight: .light))
                Text("놓으면 분리를 시작해요")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var toast: some View {
        if let message = model.toast {
            HStack(spacing: 8) {
                Image(systemName: model.toastIsSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .symbolEffect(.bounce, value: message)
                Text(message)
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(model.toastIsSuccess ? Color.green.gradient : Color.red.gradient))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(.bottom, 70)
            .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: AppModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            inputField
            modeRow
            if let job = model.job { JobCard(job: job).padding(.horizontal, 12).padding(.bottom, 8) }
            if let error = model.jobError { errorCard(error) }
            library
            footer
        }
        .onChange(of: model.focusToken) { inputFocused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.7)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 26, height: 26)
                Image(systemName: "slider.vertical.3")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("StemMixer")
                    .font(.system(size: 15, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            settingsMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 38)  // clears the window's traffic lights
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        switch model.server {
        case .starting: "준비 중…"
        case .missing: "설치가 필요해요"
        case .failed: "서버를 시작하지 못했어요"
        case .ready: model.songs.isEmpty ? "첫 곡을 기다리는 중" : "\(model.songs.count)곡 분리됨"
        }
    }

    private var settingsMenu: some View {
        Menu {
            Picker("분리 방식", selection: $model.mode) {
                ForEach(SplitMode.picker) { Text($0.title).tag($0) }
            }
            Divider()
            Button("음악 파일 선택…") { model.chooseFile() }
            Button("분리한 곡 폴더 열기") { NSWorkspace.shared.open(model.backend.library) }
            Button("서버 로그 보기") { NSWorkspace.shared.open(model.backend.log) }
            Divider()
            Button("StemMixer 종료") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var inputField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("유튜브 · 스포티파이 · 애플뮤직 링크나 곡 제목", text: $model.input)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($inputFocused)
                .onSubmit { model.submit() }
            if !model.input.isEmpty {
                Button {
                    model.input = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
            Button { model.submit() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.8)],
                                                             startPoint: .top, endPoint: .bottom)))
                    .shadow(color: .accentColor.opacity(model.canSubmit ? 0.35 : 0), radius: 5, y: 2)
                    .opacity(model.canSubmit ? 1 : 0.4)
            }
            .buttonStyle(PressableStyle())
            .disabled(!model.canSubmit)
            .help("분리하기 (⏎)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(inputFocused ? 0.5 : 0), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.15), value: model.input.isEmpty)
        .animation(.easeOut(duration: 0.15), value: inputFocused)
    }

    private var modeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(SplitMode.picker) { m in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.mode = m }
                        } label: {
                            Text(m.title)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(model.mode == m ? .primary : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(model.mode == m ? Color(nsColor: .controlBackgroundColor) : .clear)
                                        .shadow(color: .black.opacity(model.mode == m ? 0.12 : 0), radius: 2, y: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Capsule().fill(Color.primary.opacity(0.06)))

                Spacer(minLength: 0)

                CircleIconButton(icon: "doc.badge.plus", help: "음악 파일 선택") { model.chooseFile() }
            }
            Text(model.mode.detail)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { withAnimation { model.jobError = nil } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.red.opacity(0.1)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var library: some View {
        switch model.server {
        case .starting:
            placeholder(icon: "hourglass", title: "준비 중", text: "분리 엔진을 켜고 있어요.")
        case .missing:
            placeholder(icon: "shippingbox", title: "설치가 필요해요",
                        text: "\(model.backend.folder.path) 에서 start-mac.command를 한 번 실행해 주세요.")
        case .failed(let message):
            placeholder(icon: "exclamationmark.triangle", title: "서버를 시작하지 못했어요", text: message)
        case .ready where model.songs.isEmpty:
            placeholder(icon: "music.note.list", title: "아직 분리한 곡이 없어요",
                        text: "링크를 붙여넣거나 음악 파일을 끌어다 놓으세요.")
        case .ready:
            ScrollView {
                LazyVStack(spacing: 4) {
                    SectionTitle(title: "최근 분리한 곡", icon: "clock")
                    ForEach(model.songs) { item in
                        LibraryRow(item: item, current: model.song?.id == item.id,
                                   playing: model.playing && model.song?.id == item.id, model: model)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
    }

    private func placeholder(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            KeyHint("⌘V", "링크 넣기")
            KeyHint("⏎", "분리")
            Spacer()
            KeyHint("끌어다 놓기", "파일")
        }
        .frame(height: 34)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }
}

struct JobCard: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.step)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    Text(job.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if job.progress > 0 {
                    Text("\(Int(job.progress * 100))%")
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                        .contentTransition(.numericText())
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [.accentColor.opacity(0.7), .accentColor],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * job.progress))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.4), value: job.progress)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// "AI 6트랙으로 다시 분리" etc. — opens the version if it already exists.
struct ResplitItems: View {
    let item: Song
    @ObservedObject var model: AppModel

    var body: some View {
        if item.mode == "hq" || item.mode == "hq6" {
            Button("같은 방식으로 다시 분리 (최신 품질)") { model.redo(item) }
                .disabled(model.job != nil)
            Divider()
        }
        ForEach(SplitMode.picker.filter { $0.rawValue != item.mode }) { mode in
            Button(model.version(of: item, mode: mode) == nil ? "\(mode.title)으로 다시 분리" : "\(mode.title) 버전 열기") {
                model.resplit(item, mode: mode)
            }
            .disabled(model.version(of: item, mode: mode) == nil && model.job != nil)
        }
    }
}

struct ResplitMenu: View {
    let item: Song
    @ObservedObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        Menu {
            ResplitItems(item: item, model: model)
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Color.accentColor : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.1 : 0))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("다른 방식으로 분리")
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

struct LibraryRow: View {
    let item: Song
    let current: Bool
    let playing: Bool
    @ObservedObject var model: AppModel

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                meta
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                HStack(spacing: 2) {
                    ResplitMenu(item: item, model: model)
                    RowAction(icon: "folder.fill", help: "Finder에서 보기") { model.reveal(item) }
                    RowAction(icon: "trash.fill", help: "지우기", tint: .red) { model.delete(item) }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(current ? 0.45 : 0), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { if !current { model.open(item.id) } }
        .contextMenu {
            Button("열기") { model.open(item.id) }
            Menu("다른 방식으로 분리") { ResplitItems(item: item, model: model) }
            Button("Finder에서 보기") { model.reveal(item) }
            if let link = item.link, let url = URL(string: link) {
                Button("원본 영상 열기") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("지우기", role: .destructive) { model.delete(item) }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    private var background: Color {
        if current { return Color.accentColor.opacity(0.14) }
        if hovering { return Color.primary.opacity(0.05) }
        return .clear
    }

    private var badge: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.secondary.opacity(current ? 0 : 0.45), lineWidth: 1.5)
            if current {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .shadow(color: .accentColor.opacity(0.4), radius: 4, y: 1)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                Image(systemName: playing ? "waveform" : "pause.fill")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: playing)
            }
        }
        .frame(width: 22, height: 22)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: current)
    }

    private var meta: some View {
        HStack(spacing: 5) {
            Image(systemName: item.sourceInfo.icon)
            Text(item.sourceInfo.name)
            Text("·")
            Text(SplitMode.label(item.mode))
            Text("·")
            Text(formatTime(item.duration))
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
