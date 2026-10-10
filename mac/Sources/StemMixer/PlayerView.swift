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
                        VStack(spacing: 6) {
                            ForEach(song.stems, id: \.self) { TrackRow(name: $0, model: model) }
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

            HStack(spacing: 8) {
                Circle()
                    .fill(info.color.gradient)
                    .frame(width: 10, height: 10)
                    .shadow(color: info.color.opacity(0.5), radius: 3)
                Text(info.label)
                    .font(.system(size: 13, weight: .semibold))
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
        .contextMenu {
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
