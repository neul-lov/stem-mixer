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
                Task { @MainActor in
                    // MIDI · UST files are notes, not songs to separate.
                    if AppModel.isNoteFile(url) {
                        if let editor = model.editor {
                            model.importNotesFile(url, stem: editor.stem)
                        } else {
                            model.show("MIDI · UST 파일은 넣을 트랙 위에 놓아 주세요", success: false)
                        }
                    } else {
                        model.submit(file: url)
                    }
                }
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
        .sheet(isPresented: $model.showStorage) { StorageView(model: model) }
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
            Toggle("최고 음질 (보컬 더 깨끗하게 · 두 배 느림)", isOn: $model.best)
                .disabled(!model.mode.isHQ)
            Divider()
            Button("음악 파일 선택…") { model.chooseFile() }
            Button("저장 공간 관리…") { model.showStorage = true }
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

                if model.mode.isHQ {
                    Toggle("최고 음질", isOn: $model.best.animation(.easeOut(duration: 0.15)))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11, weight: .medium))
                        .help("보컬 모델을 하나 더 섞어 보컬이 더 깨끗해져요. 시간은 두 배쯤 걸려요.")
                }

                Spacer(minLength: 0)

                CircleIconButton(icon: "doc.badge.plus", help: "음악 파일 선택") { model.chooseFile() }
            }
            Text(model.splitMode.detail)
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
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let anyway = model.splitAnyway {
                    Button("노래 맞아요 · 그래도 나누기") { anyway() }
                        .font(.system(size: 11.5, weight: .semibold))
                        .help("노래인지 확인하지 않고 나눠요")
                }
            }
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
            LibraryList(items: model.songs, currentID: model.song?.id,
                        playing: model.playing, model: model)
                .equatable()
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

/// Keeps high-frequency playback updates from rebuilding the scrollable song list.
private struct LibraryList: View, Equatable {
    let items: [Song]
    let currentID: String?
    let playing: Bool
    let model: AppModel

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.currentID == rhs.currentID && lhs.playing == rhs.playing
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                SectionTitle(title: "최근 분리한 곡", icon: "clock")
                ForEach(items) { item in
                    LibraryRow(item: item, current: currentID == item.id,
                               playing: playing && currentID == item.id, model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
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
        if SplitMode(rawValue: item.mode)?.isHQ == true {
            Button("같은 방식으로 다시 분리 (최신 품질)") { model.redo(item) }
                .disabled(model.job != nil)
            Divider()
        }
        ForEach(SplitMode.resplit.filter { $0.rawValue != item.mode }) { mode in
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
    let model: AppModel

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
            if let size = item.size {
                Text("·")
                Text(AppModel.bytes(size))
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Which songs take how much space, and deleting several at once.
struct StorageView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()

    private var sorted: [Song] { model.songs.sorted { ($0.size ?? 0) > ($1.size ?? 0) } }
    private var selectedSize: Int64 { model.songs.filter { selected.contains($0.id) }.reduce(0) { $0 + ($1.size ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 26, height: 26)
                    Image(systemName: "internaldrive.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("저장 공간").font(.system(size: 15, weight: .bold))
                    Text(summary).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)

            if let s = model.storage {
                let leftovers = s.leftovers + model.cacheSize
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("정리할 수 있는 파일 \(AppModel.bytes(leftovers))").font(.system(size: 12.5, weight: .semibold))
                        Text("끌어놓기용 임시 파일, 지운 곡의 원본, 끝난 작업이 남긴 파일 (곡은 안 지워요)")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("정리하기") { model.cleanUp() }.disabled(leftovers == 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.08)))
                .padding(.horizontal, 12)

                if (s.wav ?? 0) > 0 || model.compacting != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").foregroundStyle(Color.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.compacting.map { "\($0.step) · \(Int($0.progress * 100))%" }
                                 ?? "예전 곡 트랙 \(AppModel.bytes(s.wav ?? 0)) → 40% 가까이 줄어요")
                                .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                            Text("소리 손실 없는 FLAC으로 바꿔요. 바꾼 뒤 샘플이 똑같은지 확인하고 원래 파일을 지워요. 새로 나누는 곡은 처음부터 FLAC이에요.")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if model.compacting != nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("공간 줄이기") { model.compactLibrary() }
                                .disabled(s.busy)
                                .help(s.busy ? "분리 · 음정 뽑기가 끝나면 할 수 있어요" : "곡 수에 따라 몇 분 걸릴 수 있어요. 그동안 앱은 그대로 쓸 수 있어요")
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.green.opacity(0.08)))
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
            }

            HStack(spacing: 6) {
                SectionTitle(title: "곡 (큰 순서)", icon: "music.note.list")
                Spacer()
                Menu("빠르게 고르기") {
                    Button("이전 방식으로 나눈 곡 (빠르게 · 필터 · 6트랙 이전)") {
                        selected = Set(model.songs.filter { ["ai", "ai6", "eq"].contains($0.mode) }.map(\.id))
                    }
                    Button("같은 곡의 다른 버전 (가장 최근 것만 남기기)") {
                        var seen = Set<String>()
                        selected = Set(model.songs.sorted { ($0.created ?? 0) > ($1.created ?? 0) }.compactMap { s in
                            seen.insert(s.key).inserted ? nil : s.id
                        })
                    }
                    Button("30일 넘은 곡") {
                        let cutoff = Date().timeIntervalSince1970 - 30 * 86400
                        selected = Set(model.songs.filter { ($0.created ?? .infinity) < cutoff }.map(\.id))
                    }
                    Divider()
                    Button("모두 선택") { selected = Set(model.songs.map(\.id)) }
                    Button("선택 해제") { selected = [] }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.trailing, 14)
            }
            .padding(.top, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(sorted) { item in row(item) }
                }
                .padding(.horizontal, 8)
            }
            .frame(minHeight: 260)

            HStack {
                Text(selected.isEmpty ? "지울 곡을 고르세요" : "\(selected.count)곡 선택 · \(AppModel.bytes(selectedSize))")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer()
                Button {
                    model.deleteSongs(selected)
                    selected = []
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash.fill")
                        Text("선택한 곡 지우기")
                    }
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color.red.gradient))
                    .opacity(selected.isEmpty ? 0.4 : 1)
                }
                .buttonStyle(PressableStyle())
                .disabled(selected.isEmpty)
            }
            .padding(14)
            .background(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
        }
        .frame(width: 520, height: 560)
        .fontDesign(.rounded)
        .task { await model.refreshStorage() }
    }

    private var summary: String {
        guard let s = model.storage else { return "계산 중…" }
        return "곡 \(model.songs.count)개 \(AppModel.bytes(s.songs)) · 원본 \(AppModel.bytes(s.sources)) · AI 모델 \(AppModel.bytes(s.models))"
    }

    private func row(_ item: Song) -> some View {
        let on = selected.contains(item.id)
        return HStack(spacing: 10) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(on ? Color.red : Color.secondary.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(SplitMode.label(item.mode))
                    if let c = item.created {
                        Text("·")
                        Text(Date(timeIntervalSince1970: c).formatted(.dateTime.month().day()))
                    }
                    if item.replaced?.isEmpty == false || item.extras?.isEmpty == false {
                        Text("·")
                        Text("내 녹음/MIDI 있음").foregroundStyle(Color.accentColor)
                    }
                }
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(AppModel.bytes(item.size ?? 0))
                .font(.system(size: 12, weight: .bold)).monospacedDigit()
                .foregroundStyle((item.size ?? 0) > 400_000_000 ? .primary : .secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Color.red.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { if on { selected.remove(item.id) } else { selected.insert(item.id) } }
    }
}
