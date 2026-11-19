import SwiftUI

/// 舞台页（原生版屏幕 9，对照壳版 `#view-stage` + `#stage-hud`）。
///
/// 分层（照壳版结构）：
/// - 底层：`StageWebView`（WKWebView，file:// 加载 `Resources/stages/*.html`）。
/// - 上层：原生 HUD——顶栏（返回 / 形态名 / 设置 / 形态）+ 底部迷你播放器
///   （封面 / 歌名 / 歌手·专辑 / 上一首 / 播放 / 下一首 / 进度条 / 当前歌词行）。
///   壳版 HUD 里没有歌词行（词在形态里），但任务书要求 HUD 含歌词行，所以
///   迷你播放器上方加一行当前歌词（无词时显示歌名，绝不用 ♪ 作假）。
/// - 返回键：壳版第 12 轮用户定夺——舞台点「返回」一律回首页，不按来源回播放页。
/// - HUD 闲置：2.6 秒无操作自动藏起（壳版 `armIdle` 同款）；藏起后屏幕上只剩
///   一个小的「显示控制」按钮，点它唤醒；形态内活动（`activity` 消息）按壳版
///   规则唤醒（相机形态触屏拖动除外，由桥里判断）。
/// - 相机形态（552 烟雨江南）：HUD 切极简——迷你播放器默认收起成封面 + 播放键，
///   点封面展开（壳版 `is-cinema` 的简化版；壳版那套 hover 展开在触屏上没有
///   对应物，不硬抄）。
/// - 歌词行变化同步岛 / 锁屏：本页不另起链路——`PlaybackStore.currentLyricIndex`
///   的变化本来就由 `NativeIslandCoordinator` 订阅推送（P1 已接好），舞台页
///   只读同一份 store。
/// - 禁缩放：本页无任何 MagnificationGesture；WKWebView 内形态页自带
///   `user-scalable=no`（见各形态 HTML 的 viewport），与壳版一致。
struct StageView: View {
    @EnvironmentObject private var store: PlaybackStore
    @EnvironmentObject private var navigation: AppNavigation
    @StateObject private var bridge: StageBridge

    @State private var showPicker = false
    @State private var showSettings = false
    /// 相机形态下迷你播放器默认收起；普通形态默认展开。
    @State private var pillExpanded = true
    /// 进度条拖动态（拖动时显示拖动值，松手才 seek）。
    @State private var isDraggingProgress = false
    @State private var dragProgress: Double = 0

    private let initialFormId: String?

    init(initialFormId: String? = nil) {
        self.initialFormId = initialFormId
        _bridge = StateObject(wrappedValue: StageBridge(initialFormId: initialFormId))
    }

    var body: some View {
        ZStack {
            StageWebView(bridge: bridge)
                .ignoresSafeArea()

            // HUD 藏起时：全屏透明唤醒层（壳版 `#stage-tap` 同款——点一下只唤醒
            // 浮层，不往形态里传；相机形态不盖这层，拖动镜头不受影响）。
            if !bridge.hudVisible, !bridge.isCamera {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { bridge.wakeHUD() }
            }

            VStack(spacing: 0) {
                if bridge.hudVisible {
                    topBar
                }
                Spacer()
                if bridge.hudVisible {
                    bottomHUD
                } else {
                    wakeButton
                }
            }
            .ignoresSafeArea()
        }
        .background(Color.black)
        .onAppear {
            bridge.attach(store: store)
            let playback = store
            bridge.onSpaceKey = { Task { @MainActor in playback.togglePlay() } }
            if bridge.isCamera { pillExpanded = false }
        }
        .onDisappear {
            bridge.detach()
        }
        .onChange(of: bridge.isCamera) { camera in
            if camera { pillExpanded = false }
        }
        .onChange(of: showPicker) { open in
            bridge.hudSuspended = open || showSettings
            if open { bridge.wakeHUD() }
        }
        .onChange(of: showSettings) { open in
            bridge.hudSuspended = open || showPicker
            if open { bridge.wakeHUD() }
        }
        .sheet(isPresented: $showPicker) {
            StagePickerView(bridge: bridge) { form in
                showPicker = false
                if form.isClassic {
                    navigation.show(.player)
                } else {
                    bridge.load(form: form)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            if let spec = bridge.panelSpec {
                StageSettingsView(bridge: bridge, spec: spec)
            } else {
                Text("该形态没有可调参数")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }

    // MARK: - 顶栏（壳版 #stage-hud 上半截：返回 + 形态 / 设置）

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: {
                bridge.wakeHUD()
                navigation.show(.home)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 17))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .accessibilityLabel("返回首页")

            Spacer()

            // 当前形态名（壳版长廊 / 下拉里显示的形态名，舞台页顶栏同步它）。
            Text(bridge.currentForm.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            // 设置按钮：只有形态声明了 __stagePanel 才显示（壳版同款显隐规则；
            // 69 个已收录形态全有声明，所以实际常驻）。
            if bridge.panelSpec != nil {
                Button(action: {
                    bridge.wakeHUD()
                    showSettings = true
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("本形态设置")
            }

            Button(action: {
                bridge.wakeHUD()
                showPicker = true
            }) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("选择形态")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - 底部迷你播放器（壳版 #stage-song 的雪球胶囊 + 进度条）

    private var bottomHUD: some View {
        VStack(spacing: 8) {
            // 当前歌词行（HUD 新增；无词时显示歌名，绝不用 ♪ 作假）。
            Text(currentLyricText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                // 封面（相机形态收起态：点封面展开完整胶囊）。
                Button(action: {
                    bridge.wakeHUD()
                    if bridge.isCamera { pillExpanded.toggle() }
                }) {
                    CoverImageView(url: store.currentTrack?.coverURL, placeholderIconSize: 16)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .accessibilityLabel(bridge.isCamera ? (pillExpanded ? "收起播放器" : "展开播放器") : "封面")

                if pillExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.currentTrack?.title ?? "未播放")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(trackSubtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(action: { bridge.wakeHUD(); store.previous() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("上一首")

                    Button(action: { bridge.wakeHUD(); store.togglePlay() }) {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel(store.isPlaying ? "暂停" : "播放")

                    Button(action: { bridge.wakeHUD(); store.next() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("下一首")
                } else {
                    Spacer()
                    Button(action: { bridge.wakeHUD(); store.togglePlay() }) {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel(store.isPlaying ? "暂停" : "播放")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))

            if pillExpanded {
                HStack(spacing: 8) {
                    Text(formatTime(sliderValue))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                    Slider(
                        value: Binding(
                            get: { isDraggingProgress ? dragProgress : store.progress },
                            set: { dragProgress = $0 }
                        ),
                        in: 0...max(store.duration, 1),
                        onEditingChanged: { editing in
                            isDraggingProgress = editing
                            if editing {
                                dragProgress = store.progress
                            } else {
                                store.seek(to: dragProgress)
                            }
                            bridge.wakeHUD()
                        }
                    )
                    .disabled(store.duration <= 0)
                    .tint(.white)
                    Text(formatTime(store.duration))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    /// HUD 藏起后屏幕底部剩的小按钮（点一下唤醒 HUD，不往形态里传）。
    private var wakeButton: some View {
        Button(action: { bridge.wakeHUD() }) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                Text("显示控制")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .accessibilityLabel("显示控制栏")
        .padding(.bottom, 24)
    }

    // MARK: - 派生文案

    /// 歌手 · 专辑（壳版 `#stage-sub` 同款格式）。
    private var trackSubtitle: String {
        guard let track = store.currentTrack else { return "—" }
        if track.album.isEmpty { return track.artist.isEmpty ? "—" : track.artist }
        return track.artist.isEmpty ? track.album : track.artist + " · " + track.album
    }

    /// 当前歌词行；无词 / 还没开始时显示歌名（壳版无词时形态里显示「这首没有歌词」，
    /// HUD 这里显示歌名，不编 ♪）。
    private var currentLyricText: String {
        if store.currentLyricIndex >= 0,
           store.lyrics.indices.contains(store.currentLyricIndex) {
            let text = store.lyrics[store.currentLyricIndex].text
            if !text.isEmpty { return text }
        }
        return store.currentTrack?.title ?? "未播放"
    }

    private var sliderValue: Double {
        isDraggingProgress ? dragProgress : store.progress
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
