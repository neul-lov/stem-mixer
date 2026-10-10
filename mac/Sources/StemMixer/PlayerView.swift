import SwiftUI

struct PlayerView: View {
    @ObservedObject var model: AppModel
    @State private var scrub: Double?

    var body: some View {
        if let song = model.song {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        titleBlock(song)
                        transport
                        presets
                        if let stem = model.recordingStem { RecordingBar(stem: stem, model: model) }
                        VStack(spacing: 6) {
                            ForEach(song.allTracks, id: \.self) { TrackRow(name: $0, model: model) }
                        }
                        if let roll = model.rollStem, song.midi(for: roll) != nil {
                            PianoRoll(stem: roll, model: model)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        SendToApps(model: model)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 38)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.never)
                footer
            }
        } else {
            empty
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.18), .accentColor.opacity(0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.bottom, 6)
            Text("곡을 고르거나 새로 분리하세요")
                .font(.system(size: 17, weight: .semibold))
            Text("보컬 · 베이스 · 드럼 · 기타 · 피아노를 따로따로 0~200%로 조절할 수 있어요.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                KeyHint("Space", "재생")
                KeyHint("← →", "5초")
                KeyHint("1 2 3", "보컬·베이스·드럼만")
                KeyHint("0", "원곡")
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func titleBlock(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(song.title)
                .font(.system(size: 20, weight: .bold))
                .lineLimit(2)
            HStack(spacing: 6) {
                tag(song.sourceInfo.name, icon: song.sourceInfo.icon)
                tag(SplitMode.label(song.mode), icon: SplitMode.icon(song.mode))
                tag(formatTime(song.duration), icon: "clock")
                Menu {
                    ResplitItems(item: song, model: model)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("다른 방식으로 분리")
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if let matched = song.matched {
                // Spotify / Apple Music audio can't be downloaded, so we play the closest YouTube match.
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("유튜브에서 찾은 음원: ")
                        + Text(matched).fontWeight(.semibold)
                    if let link = song.link, let url = URL(string: link) {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.plain)
                        .help("영상 열기")
                    }
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                .padding(.top, 2)
            }
        }
    }

    private func tag(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: model.playing ? 0 : 1.5)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.8)],
                                                             startPoint: .top, endPoint: .bottom)))
                    .shadow(color: .accentColor.opacity(0.4), radius: 10, y: 4)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .help("재생 / 정지 (Space)")

            Text(formatTime(scrub ?? model.time))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            CapsuleSlider(
                value: Binding(get: { scrub ?? model.time }, set: { scrub = $0 }),
                range: 0...max(model.duration, 0.1),
                onCommit: { value in
                    model.seek(value)
                    scrub = nil
                })
            Text(formatTime(model.duration))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "프리셋", icon: "slider.horizontal.3").padding(.horizontal, -10)
            FlowLayout(spacing: 6) {
                ForEach(Preset.available(for: model.song?.stems ?? [])) { preset in
                    let on = model.isActive(preset)
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.apply(preset) }
                    } label: {
                        Text(preset.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? Color.accentColor : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(on ? 0.45 : 0), lineWidth: 1))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: model.master < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            CapsuleSlider(value: $model.master, height: 5)
                .frame(width: 140)
            Spacer()
            KeyHint("Space", "재생")
            KeyHint("← →", "5초")
            Spacer()
            Button { model.exportMix() } label: {
                PrimaryCapsule(title: model.exporting ? "저장 중…" : "이 믹스 저장",
                               icon: "square.and.arrow.down.fill", enabled: !model.exporting)
            }
            .buttonStyle(PressableStyle())
            .disabled(model.exporting)
            .help("지금 들리는 그대로 wav 파일로 저장")
        }
        .frame(height: 34)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }
}

struct TrackRow: View {
    let name: String
    @ObservedObject var model: AppModel
    @State private var hovering = false
    @State private var dropping = false
    @State private var showMine = false
    @State private var showMidi = false
    private var isMidi: Bool { name.hasSuffix("_midi") }

    var body: some View {
        let info = StemInfo.of(name)
        let state = model.tracks[name] ?? TrackState()
        let audible = model.audible(name)
        HStack(spacing: 14) {
            FileDragSource(files: { model.song.flatMap { model.namedStem(name, of: $0) }.map { [$0] } ?? [] }) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 26)
                    .contentShape(Rectangle())
            }
            .frame(width: 14, height: 26)
            .help("끌어서 편집 앱이나 Finder에 놓기")
            .padding(.trailing, -6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(info.color.gradient)
                        .frame(width: 10, height: 10)
                        .shadow(color: info.color.opacity(0.5), radius: 3)
                    Text(info.label)
                        .font(.system(size: 13, weight: .semibold))
                    if model.busyStem == name { ProgressView().controlSize(.mini) }
                }
                if isMidi, let midi = model.song?.midi(for: name) {
                    Button { showMidi.toggle() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "pianokeys")
                            Text("MIDI")
                        }
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(info.color.gradient))
                    }
                    .buttonStyle(PressableStyle())
                    .help("음정 트랙 설정 (소리, 조옮김, MIDI 파일)")
                    .popover(isPresented: $showMidi, arrowEdge: .bottom) {
                        MidiSettings(stem: midi.source, midi: midi, model: model)
                    }
                }
                if let mine = model.song?.replaced?[name] {
                    Button { showMine.toggle() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: mine.use ? "person.wave.2.fill" : "arrow.uturn.backward")
                            Text(mine.use ? "내 녹음" : "원래 트랙")
                        }
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(mine.use ? .white : Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(mine.use ? AnyShapeStyle(Color.accentColor.gradient)
                                                            : AnyShapeStyle(Color.accentColor.opacity(0.14))))
                    }
                    .buttonStyle(PressableStyle())
                    .help("내 트랙 설정 (원래 트랙과 비교, 싱크 맞추기)")
                    .popover(isPresented: $showMine, arrowEdge: .bottom) {
                        MineSettings(stem: name, track: mine, model: model)
                    }
                }
            }
            .frame(width: 92, alignment: .leading)

            VStack(spacing: 3) {
                CapsuleSlider(
                    value: Binding(get: { Double(state.volume) },
                                   set: { model.setVolume(name, Int(($0 / 5).rounded() * 5)) }),
                    range: 0...200, tint: info.color, mark: 100,
                    onDoubleClick: { model.setVolume(name, 100) })
                GeometryReader { geo in
                    Capsule()
                        .fill(info.color.opacity(0.7))
                        .frame(width: geo.size.width * CGFloat(min(1, (model.levels[name] ?? 0) * 1.4)), height: 3)
                }
                .frame(height: 3)
            }

            Text("\(state.volume)%")
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(state.volume == 0 ? .secondary : .primary)
                .frame(width: 46, alignment: .trailing)
                .contentTransition(.numericText())

            HStack(spacing: 4) {
                Button { model.copyStem(name) } label: {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(PressableStyle())
                .help("이 트랙 파일 복사 (Finder 등에 ⌘V)")
                .opacity(hovering ? 1 : 0)
                toggle(icon: state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", on: state.muted,
                       tint: .red, help: "끄기") { model.toggleMute(name) }
                toggle(icon: "headphones", on: state.solo, tint: .orange, help: "이 트랙만 듣기 (솔로)") {
                    model.toggleSolo(name)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0.035))
        )
        .opacity(audible ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: audible)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(dropping ? 0.8 : 0), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        )
        .overlay {
            if dropping {
                Text("놓으면 \(info.label)을 이 파일로 바꿔요")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.regularMaterial))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard !isMidi, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.replace(name, with: url) }
            }
            return true
        }
        .contextMenu {
            if isMidi, let midi = model.song?.midi(for: name) {
                Button("피아노 롤 보기") { model.openRoll(name) }
                Button("MIDI 파일 복사") { model.copyMidi(midi.source) }
                if midi.source == "vocals" || midi.source == "bass" {
                    Button("OpenUtau · UTAU로 내보내기…") { model.exportUtau(midi.source, quantize: false) }
                }
                Button("음정 트랙 지우기", role: .destructive) { model.removeMidi(midi.source) }
            } else {
                Button("내 파일로 바꾸기…") { model.chooseReplacement(for: name) }
                Button("여기에 녹음하기 (헤드폰 추천)") { model.startRecording(name) }
                if let mine = model.song?.replaced?[name] {
                    Button(mine.use ? "원래 트랙으로 듣기" : "내 트랙으로 듣기") { model.setUseMine(name, !mine.use) }
                    Button("내 트랙 지우기", role: .destructive) { model.removeMine(name) }
                }
                if name != "drums" {
                    Menu(model.song?.midi(for: name) == nil ? "음정 뽑기 (MIDI)" : "음정 다시 뽑기 (MIDI)") {
                        ForEach(AppModel.midiSounds, id: \.id) { sound in
                            Button("\(sound.title) 소리로") { model.transcribe(name, sound: sound.id) }
                        }
                    }
                    .disabled(model.job != nil)
                }
            }
            Divider()
            Button("트랙 파일 복사") { model.copyStem(name) }
            Button("Finder에서 보기") { model.revealStem(name) }
            Divider()
            Button("100%로") { model.setVolume(name, 100) }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    private func toggle(icon: String, on: Bool, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? .white : .secondary)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
                )
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableStyle())
        .help(help)
    }
}

/// Getting tracks into GarageBand, Logic, Ableton …: drag, copy, or save to a folder.
struct SendToApps: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "편집 앱으로 보내기", icon: "arrow.up.forward.app").padding(.horizontal, -10)
            HStack(spacing: 8) {
                FileDragSource(files: { model.namedStems() }) {
                    chip(icon: "square.stack.3d.up.fill", title: "모든 트랙 끌어놓기", tint: .accentColor)
                }
                .help("편집 앱 타임라인에 끌어 놓으면 트랙이 한 번에 들어가요")

                if let mix = model.currentMixFile {
                    FileDragSource(files: { [mix] }) {
                        chip(icon: "waveform", title: "믹스 끌어놓기", tint: .green)
                    }
                    .help("지금 들리는 그대로 만든 파일이에요")
                } else {
                    Button { model.renderMix { _ in } } label: {
                        chip(icon: model.renderingMix ? "hourglass" : "waveform",
                             title: model.renderingMix ? "믹스 만드는 중…" : "지금 믹스 만들기", tint: .secondary)
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(model.renderingMix)
                    .help("지금 설정으로 믹스 파일을 만들면 끌어 놓을 수 있어요")
                }

                Menu {
                    Button("모든 트랙 복사") { model.copyAllStems() }
                    Button("지금 믹스 복사 (⌘C)") { model.copyMix() }
                    Divider()
                    Button("모든 트랙을 폴더로 저장…") { model.exportAllStems() }
                } label: {
                    chip(icon: "ellipsis", title: "복사 · 저장", tint: .secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Text("트랙 왼쪽 ≡ 를 끌면 그 트랙만 보낼 수 있어요. 복사한 파일은 Finder에 ⌘V로 붙여넣을 수 있어요.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func chip(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            Text(title)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(tint == .secondary ? Color.primary.opacity(0.06) : tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint == .secondary ? .clear : tint.opacity(0.35), lineWidth: 1))
        .contentShape(Capsule())
    }
}

/// Settings for a track replaced by your own file or recording.
struct MineSettings: View {
    let stem: String
    let track: UserTrack
    @ObservedObject var model: AppModel
    @State private var nudgeMs: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.wave.2.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(StemInfo.of(stem).label) · 내 트랙").font(.system(size: 13, weight: .bold))
                    Text(track.name ?? "").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Picker("", selection: Binding(get: { track.use }, set: { model.setUseMine(stem, $0) })) {
                Text("원래 트랙").tag(false)
                Text("내 트랙").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("싱크 맞추기").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%+.0f ms", nudgeMs))
                        .font(.system(size: 12, weight: .bold)).monospacedDigit()
                }
                CapsuleSlider(value: $nudgeMs, range: -500...500, mark: 0,
                              onCommit: { model.setNudge(stem, ($0 / 1000 * 1000).rounded() / 1000) },
                              onDoubleClick: { nudgeMs = 0; model.setNudge(stem, 0) })
                HStack(spacing: 6) {
                    ForEach([-50, -10, 10, 50], id: \.self) { step in
                        Button(step > 0 ? "+\(step)" : "\(step)") {
                            nudgeMs = max(-500, min(500, nudgeMs + Double(step)))
                            model.setNudge(stem, nudgeMs / 1000)
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    Spacer()
                    Button("0") { nudgeMs = 0; model.setNudge(stem, 0) }.font(.system(size: 11, weight: .semibold))
                }
                Text("−는 내 트랙을 앞으로, +는 뒤로 밀어요.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .disabled(!track.use)
            .opacity(track.use ? 1 : 0.5)

            Divider()
            HStack {
                Button("다시 녹음") { model.startRecording(stem) }
                Button("다른 파일…") { model.chooseReplacement(for: stem) }
                Spacer()
                Button("지우기", role: .destructive) { model.removeMine(stem) }
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .padding(14)
        .frame(width: 300)
        .fontDesign(.rounded)
        .onAppear { nudgeMs = (track.nudge * 1000).rounded() }
    }
}

/// Shown while recording: count-in, elapsed time, stop / cancel.
struct RecordingBar: View {
    let stem: String
    @ObservedObject var model: AppModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.red.gradient)
                .frame(width: 12, height: 12)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            VStack(alignment: .leading, spacing: 1) {
                if let n = model.countdown {
                    Text("\(n)…  곧 시작해요").font(.system(size: 13, weight: .bold)).contentTransition(.numericText())
                } else {
                    Text("\(StemInfo.of(stem).label) 녹음 중 · \(formatTime(max(0, model.time - model.recordStart)))")
                        .font(.system(size: 13, weight: .bold)).monospacedDigit()
                }
                Text("헤드폰을 끼면 스피커 소리가 녹음에 안 섞여요 · Space 정지 · esc 취소")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("취소") { model.stopRecording(keep: false) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Button { model.stopRecording() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text("정지하고 넣기")
                }
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(Color.red.gradient))
                .shadow(color: .red.opacity(0.35), radius: 6, y: 2)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.red.opacity(0.3), lineWidth: 1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Settings for a MIDI track: sound, transpose, key snap, tempo, and the .mid file.
struct MidiSettings: View {
    let stem: String
    let midi: MidiTrack
    @ObservedObject var model: AppModel
    @State private var tempo: Double = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "pianokeys").foregroundStyle(StemInfo.of(stem).color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(midi.label ?? "\(StemInfo.of(stem).label) 음정").font(.system(size: 13, weight: .bold))
                    Text("음표 \(midi.notes)개 · \(midi.key ?? "") · \(Int(midi.tempo ?? 120)) BPM")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            Picker("", selection: Binding(get: { midi.sound }, set: { model.updateMidi(stem, sound: $0) })) {
                ForEach(AppModel.midiSounds, id: \.id) { Text($0.title).tag($0.id) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Text("조옮김").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.updateMidi(stem, transpose: midi.transpose - 1) } label: { Image(systemName: "minus") }
                Text(midi.transpose == 0 ? "원래 음" : String(format: "%+d 반음", midi.transpose))
                    .font(.system(size: 12, weight: .bold)).monospacedDigit().frame(width: 64)
                Button { model.updateMidi(stem, transpose: midi.transpose + 1) } label: { Image(systemName: "plus") }
                Button("옥타브↑") { model.updateMidi(stem, transpose: midi.transpose + 12) }
            }
            .font(.system(size: 11, weight: .semibold))

            Toggle(isOn: Binding(get: { midi.snap }, set: { model.updateMidi(stem, snap: $0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("키에 맞추기 (\(midi.key ?? "?"))").font(.system(size: 12, weight: .semibold))
                    Text("조성에서 벗어난 음을 가까운 음으로 고쳐요").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack {
                Text("빠르기 (MIDI 마디선)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("½") { tempo = (tempo / 2).rounded(); model.updateMidi(stem, tempo: tempo) }
                Button("¾") { tempo = (tempo * 0.75).rounded(); model.updateMidi(stem, tempo: tempo) }
                TextField("", value: $tempo, format: .number)
                    .frame(width: 46).multilineTextAlignment(.trailing)
                    .onSubmit { model.updateMidi(stem, tempo: tempo) }
                Text("BPM").foregroundStyle(.secondary)
                Button("×2") { tempo = (tempo * 2).rounded(); model.updateMidi(stem, tempo: tempo) }
            }
            .font(.system(size: 11, weight: .semibold))

            Divider()
            HStack(spacing: 8) {
                FileDragSource(files: { model.namedMidi(stem).map { [$0] } ?? [] }) {
                    HStack(spacing: 5) {
                        Image(systemName: "music.note.list")
                        Text("MIDI 파일 끌어놓기")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
                }
                .help("GarageBand · Logic 같은 편집 앱에 끌어 놓으면 아무 악기로나 연주할 수 있어요")
                Button("복사") { model.copyMidi(stem) }.font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("지우기", role: .destructive) { model.removeMidi(stem) }.font(.system(size: 12, weight: .semibold))
            }
            Button("피아노 롤 보기") { model.openRoll("\(stem)_midi") }.font(.system(size: 12, weight: .semibold))
            if stem == "vocals" || stem == "bass" {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("보컬 신스로 다시 부르기").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("OpenUtau · UTAU로 내보내기…") { model.exportUtau(stem, quantize: false) }
                        Button("박자 맞춰서") { model.exportUtau(stem, quantize: true) }
                            .help("음표를 16분음표 격자에 맞춰서 내보내요 (빠르기가 맞을 때만 쓰세요)")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    Text("반주 트랙이 같이 들어가요. 조율해서 0초부터 wav로 내보낸 뒤 \(StemInfo.of(stem).label) 트랙에 끌어다 놓으면 싱크가 맞아요. 빠르기가 맞는지 먼저 확인하세요 (지금 \(Int(midi.tempo ?? 120)) BPM).")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 330)
        .fontDesign(.rounded)
        .onAppear { tempo = midi.tempo ?? 120 }
    }
}

/// The notes of a MIDI track scrolling past the playhead.
struct PianoRoll: View {
    let stem: String
    @ObservedObject var model: AppModel
    private let before = 2.0, after = 6.0

    var body: some View {
        let midi = model.song?.midi(for: stem)
        let info = StemInfo.of(stem)
        let notes = model.rollNotes
        let lo = (notes.map(\.pitch).min() ?? 48) - 2, hi = (notes.map(\.pitch).max() ?? 72) + 2
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionTitle(title: "피아노 롤 · \(info.label)", icon: "pianokeys").padding(.horizontal, -10)
                Text("\(midi?.key ?? "") · \(Int(midi?.tempo ?? 120)) BPM · 음표 \(notes.count)개")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    .fixedSize()
                Button { withAnimation { model.rollStem = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Canvas { ctx, size in
                let t = model.time, t0 = t - before, span = before + after
                let rows = CGFloat(max(1, hi - lo))
                func x(_ s: Double) -> CGFloat { CGFloat((s - t0) / span) * size.width }
                func y(_ p: Int) -> CGFloat { size.height - CGFloat(p - lo) / rows * size.height }
                // C rows and black keys as faint stripes.
                for p in lo...hi {
                    let black = [1, 3, 6, 8, 10].contains(p % 12)
                    if black {
                        ctx.fill(Path(CGRect(x: 0, y: y(p) - size.height / rows / 2, width: size.width, height: size.height / rows)),
                                 with: .color(.primary.opacity(0.035)))
                    }
                    if p % 12 == 0 {
                        ctx.draw(Text("C\(p / 12 - 1)").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary),
                                 at: CGPoint(x: 12, y: y(p)))
                    }
                }
                // Beat lines from the tempo.
                let beat = 60 / (midi?.tempo ?? 120)
                var b = (t0 / beat).rounded(.up) * beat
                while b < t0 + span {
                    let bar = Int((b / beat).rounded()) % 4 == 0
                    ctx.fill(Path(CGRect(x: x(b), y: 0, width: bar ? 1 : 0.5, height: size.height)),
                             with: .color(.primary.opacity(bar ? 0.12 : 0.05)))
                    b += beat
                }
                let h = max(3, size.height / rows - 1)
                for n in notes where n.end > t0 && n.start < t0 + span {
                    let rect = CGRect(x: x(n.start), y: y(n.pitch) - h / 2, width: max(2, x(n.end) - x(n.start)), height: h)
                    let on = n.start <= t && t < n.end
                    ctx.fill(Path(roundedRect: rect, cornerRadius: min(3, h / 2)),
                             with: .color(info.color.opacity(on ? 1 : 0.35 + 0.5 * n.velocity)))
                    if on { ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 3), with: .color(.white.opacity(0.8))) }
                }
                ctx.fill(Path(CGRect(x: x(t) - 1, y: 0, width: 2, height: size.height)), with: .color(.accentColor))
            }
            .frame(height: 170)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
