import SwiftUI

/// 舞台页（原生版屏幕 9，r20 横竖屏两套布局，对照用户 01:34 两张截图）。
///
/// 分层：
/// - 底层：`StageWebView`（WKWebView，file:// 加载 `Resources/stages/*.html`）。
/// - 上层：原生 HUD——顶行（返回 + 播放胶囊 + 设置 / 形态）+ 左下角
///   （当前歌词小行 + 歌手名）。旧的底部迷你播放条（bottomHUD 整条）已撤，
///   播放控制全进顶部胶囊；形态名胶囊已撤（形态名只在形态选择器里显示）。
///
/// 中央大歌词是哪一层（r20 已查，不猜）：
/// - 截图里的形态是 519 棱镜阈限（prism-euphoria）：它自己画中央大歌词——
///   `Resources/stages/519-prism-euphoria.html` 的 `#lyricLayer`
///  （fixed inset:0，flex 居中）+ `.line`（clamp(25px, 4.3vw, 70px)，
///   600，#f5f9ff 带辉光阴影）+ `#lyricInner`（text-align:center）。
///   截图实测与该 CSS 一致：竖屏 3 字约 24pt/字（25px 下限），横屏 4 字
///   约 32–37pt/字（4.3vw）；上下还有淡淡的 ghostPrev/ghostNext。
///   所以原生不加中央大歌词，否则在 519 上双画。左下角同理有一点要注意：
///   519 自带 `#meta`（歌名 + 分隔线 + 歌手）在屏底 4.5vh 处；原生左下角
///   字块放在约 75% 高处（截图位置），与它错开不重叠。
/// - 其他形态各画各的（552 是黑色 3D 字、408 是底部歌词行等），原生不干预。
///
/// 横竖屏：`GeometryReader` 尺寸判断（宽 > 高为横屏），旋转时布局实时跟随；
/// 旋转不重建视图、不丢播放状态（@State / @StateObject / store 都保留）。
/// 分档尺寸见 `StageTokens`（窄边 = min(宽, 高)，三档 × 横竖屏）。
///
/// 保留的行为：
/// - 返回一律回首页；设置齿轮开形态设置 sheet（只有形态声明了
///   `__stagePanel` 才显示）；九宫格开形态选择器 sheet。
/// - HUD 闲置 2.6 秒自动藏起（桥里 `startHudTimer`），藏起后剩「显示控制」
///   小按钮唤醒；相机形态不盖全屏点按唤醒层，拖动镜头不受影响。
/// - 相机形态（552 烟雨江南）：播放胶囊默认收起成封面 + 播放键，点封面展开
///   （旧 bottomHUD 的收起态语义，原样搬进顶部胶囊）。
/// - 播放 / 暂停 / 切歌 / 进度 seek 接原来的 store 调用，一个不少；
///   无曲目时控制禁用，歌名「未播放」、副标题「—」，不编假数据。
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
    /// 相机形态下播放胶囊默认收起；普通形态默认展开。
    @State private var pillExpanded = true
    /// 进度条拖动态（拖动中显示拖动值、松手才 seek，与旧 Slider 的做法一致）。
    @State private var isDraggingProgress = false
    @State private var dragProgress: Double = 0

    private let initialFormId: String?

    init(initialFormId: String? = nil) {
        self.initialFormId = initialFormId
        _bridge = StateObject(wrappedValue: StageBridge(initialFormId: initialFormId))
    }

    var body: some View {
        GeometryReader { geo in
            let tokens = StageTokens.for(size: geo.size)
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
                        topRow(tokens: tokens, geo: geo)
                    }
                    Spacer()
                    if bridge.hudVisible {
                        bottomCaption(tokens: tokens, geo: geo)
                        // 左下角字块下方预留屏高约 18%：字块顶落在约 75% 高处，
                        // 与截图一致，且不压到 519 自带的屏底 #meta。
                        Spacer().frame(height: geo.size.height * tokens.captionBottomReserve)
                    } else {
                        wakeButton(safeArea: geo.safeAreaInsets)
                    }
                }
                .ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
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

    // MARK: - 顶行（返回 + 播放胶囊 + 设置 / 形态）

    @ViewBuilder
    private func topRow(tokens: StageTokens, geo: GeometryProxy) -> some View {
        if tokens.isLandscape {
            landscapeTopRow(tokens: tokens, geo: geo)
        } else {
            portraitTopRow(tokens: tokens, geo: geo)
        }
    }

    /// 竖屏顶行：左返回圆按钮（只有 < 箭头）+ 中间窄磨砂胶囊（自适应宽）+
    /// 右设置齿轮 + 九宫格两个圆按钮（只有图标）。
    private func portraitTopRow(tokens: StageTokens, geo: GeometryProxy) -> some View {
        HStack(spacing: tokens.topRowGap) {
            Button(action: {
                bridge.wakeHUD()
                navigation.show(.home)
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: tokens.roundButtonDiameter, height: tokens.roundButtonDiameter)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
            }
            .accessibilityLabel("返回首页")

            playerCapsule(tokens: tokens, width: nil)
                .frame(maxWidth: .infinity)

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
                        .frame(width: tokens.roundButtonDiameter, height: tokens.roundButtonDiameter)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
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
                    .frame(width: tokens.roundButtonDiameter, height: tokens.roundButtonDiameter)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
            }
            .accessibilityLabel("选择形态")
        }
        .padding(.leading, geo.safeAreaInsets.leading + tokens.sideMargin)
        .padding(.trailing, geo.safeAreaInsets.trailing + tokens.sideMargin)
        .padding(.top, geo.safeAreaInsets.top + tokens.topGap)
    }

    /// 横屏顶行：左「返回」胶囊 + 中间宽磨砂胶囊（居中，理想宽取
    /// min(档位理想宽, 可用宽)，居中放不下时按右端固定件收窄）+
    /// 右「设置」「形态」两个胶囊按钮。
    /// 左右边距按竖屏同款走 safeArea leading/trailing（r20 集成修：
    /// 之前只扣 sideMargin，灵动岛机横屏一侧 safeArea 约 59pt，
    /// 顶行会顶到传感器区；两种横屏方向都要真机验）。
    private func landscapeTopRow(tokens: StageTokens, geo: GeometryProxy) -> some View {
        let insets = geo.safeAreaInsets
        let contentW = geo.size.width - insets.leading - insets.trailing - tokens.sideMargin * 2
        let collapsed = bridge.isCamera && !pillExpanded
        // 右端固定件：设置（有 panelSpec 时）+ 形态 + 两者之间的间距。
        let rightFixed = (bridge.panelSpec != nil ? tokens.settingsCapsuleWidth + tokens.topRowGap : 0)
            + tokens.pickerCapsuleWidth
        let collapsedWidth = tokens.coverSize + 10 + tokens.playButtonFrame + tokens.capsuleHPadding * 2
        // 胶囊宽：收起态按内容宽；展开态取理想宽，但要同时满足
        // (a) 右端固定件放得下（居中时右侧余量 ≥ topRowGap）；
        // (b) 左侧余量 ≥ 0（居中时左侧余量 ≥ 0）。
        let capsuleW: CGFloat = collapsed
            ? collapsedWidth
            : min(tokens.idealCapsuleWidthLandscape,
                  contentW - 2 * rightFixed - 2 * tokens.topRowGap,
                  contentW - 2 * tokens.backCapsuleWidth - 2 * tokens.topRowGap)
        // 为居中，返回按钮与胶囊之间的留白；钳在 ≥0（capsuleW 的取法已保证
        // 居中可行：左侧余量 = contentW/2 - capsuleW/2 - backW - topRowGap ≥ 0）。
        let leftGap = max(0, contentW / 2 - capsuleW / 2 - tokens.backCapsuleWidth - tokens.topRowGap)
        return HStack(spacing: 0) {
            Button(action: {
                bridge.wakeHUD()
                navigation.show(.home)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 15))
                }
                .foregroundStyle(.white)
                .frame(width: tokens.backCapsuleWidth, height: 40)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
            }
            .accessibilityLabel("返回首页")

            Color.clear.frame(width: tokens.topRowGap + leftGap, height: 1)

            playerCapsule(tokens: tokens, width: capsuleW)

            Spacer(minLength: 0)

            if bridge.panelSpec != nil {
                Button(action: {
                    bridge.wakeHUD()
                    showSettings = true
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .medium))
                        Text("设置")
                            .font(.system(size: 15))
                    }
                    .foregroundStyle(.white)
                    .frame(width: tokens.settingsCapsuleWidth, height: 40)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                }
                .accessibilityLabel("本形态设置")

                Color.clear.frame(width: tokens.topRowGap, height: 1)
            }

            Button(action: {
                bridge.wakeHUD()
                showPicker = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 15, weight: .medium))
                    Text("形态")
                        .font(.system(size: 15))
                }
                .foregroundStyle(.white)
                .frame(width: tokens.pickerCapsuleWidth, height: 40)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
            }
            .accessibilityLabel("选择形态")
        }
        .padding(.leading, insets.leading + tokens.sideMargin)
        .padding(.trailing, insets.trailing + tokens.sideMargin)
        .padding(.top, insets.top + tokens.topGap)
    }

    // MARK: - 播放胶囊（封面 + 歌名/歌手 + 上一首/播放/下一首 + 进度条）

    /// 播放胶囊。`width` 为 nil 时自适应（竖屏顶行里撑满剩余宽）；
    /// 横屏传算好的固定宽。相机形态收起态只剩封面 + 播放键。
    private func playerCapsule(tokens: StageTokens, width: CGFloat?) -> some View {
        let collapsed = bridge.isCamera && !pillExpanded
        return HStack(spacing: 10) {
            // 封面（相机形态收起态：点封面展开完整胶囊）。
            Button(action: {
                bridge.wakeHUD()
                if bridge.isCamera { pillExpanded.toggle() }
            }) {
                CoverImageView(url: store.currentTrack?.coverURL, placeholderIconSize: 16)
                    .frame(width: tokens.coverSize, height: tokens.coverSize)
                    .clipShape(RoundedRectangle(cornerRadius: tokens.coverCornerRadius))
            }
            .accessibilityLabel(bridge.isCamera ? (pillExpanded ? "收起播放器" : "展开播放器") : "封面")

            if collapsed {
                Spacer()
                playButton(tokens: tokens)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.currentTrack?.title ?? "未播放")
                                .font(.system(size: tokens.titleFont, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(trackSubtitle)
                                .font(.system(size: tokens.artistFont))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                        .frame(minWidth: 20, alignment: .leading)

                        Spacer(minLength: 6)

                        transportButton(tokens: tokens,
                                        systemName: "backward.fill",
                                        iconSize: tokens.skipIconSize,
                                        frame: tokens.skipButtonFrame,
                                        label: "上一首") { store.previous() }
                        playButton(tokens: tokens)
                        transportButton(tokens: tokens,
                                        systemName: "forward.fill",
                                        iconSize: tokens.skipIconSize,
                                        frame: tokens.skipButtonFrame,
                                        label: "下一首") { store.next() }
                    }

                    progressRow(tokens: tokens)
                }
            }
        }
        .padding(.horizontal, tokens.capsuleHPadding)
        .padding(.vertical, tokens.capsuleVPadding)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: tokens.capsuleCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: tokens.capsuleCornerRadius).stroke(.white.opacity(0.28), lineWidth: 1))
        .frame(width: width)
    }

    private func playButton(tokens: StageTokens) -> some View {
        Button(action: { bridge.wakeHUD(); store.togglePlay() }) {
            Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: tokens.playIconSize))
                .foregroundStyle(.white)
                .frame(width: tokens.playButtonFrame, height: tokens.playButtonFrame)
        }
        .accessibilityLabel(store.isPlaying ? "暂停" : "播放")
        .disabled(store.currentTrack == nil)
    }

    private func transportButton(tokens: StageTokens,
                                 systemName: String,
                                 iconSize: CGFloat,
                                 frame: CGFloat,
                                 label: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: { bridge.wakeHUD(); action() }) {
            Image(systemName: systemName)
                .font(.system(size: iconSize))
                .foregroundStyle(.white)
                .frame(width: frame, height: frame)
        }
        .accessibilityLabel(label)
        .disabled(store.currentTrack == nil)
    }

    /// 进度行：当前时间 + 细进度条 + 总时间。
    /// 细进度条是原生 Slider 的等价实现：原生 Slider 约 28–31pt 高，会把
    /// 胶囊撑到约 80pt（截图胶囊横屏约 53pt、竖屏约 68pt），所以用
    /// DragGesture 细条实现，状态机与旧 Slider 的做法完全一致——拖动中
    /// 显示拖动值（sliderValue 取 dragProgress）、松手才 seek(to:)。
    /// 要换回 Slider 时只改这一处（isDraggingProgress / dragProgress /
    /// sliderValue 三个量原样复用）。
    private func progressRow(tokens: StageTokens) -> some View {
        HStack(spacing: 6) {
            Text(formatTime(sliderValue))
                .font(.system(size: tokens.timeFont, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()
            progressScrubber()
            Text(formatTime(store.duration))
                .font(.system(size: tokens.timeFont, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()
        }
    }

    private func progressScrubber() -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let ratio = store.duration > 0 ? sliderValue / max(store.duration, 1) : 0
            let clampedRatio = min(1, max(0, ratio))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(height: 3)
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, width * clampedRatio), height: 3)
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .offset(x: max(0, min(width - 10, width * clampedRatio - 5)))
            }
            .frame(height: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard store.duration > 0 else { return }
                        if !isDraggingProgress {
                            isDraggingProgress = true
                            dragProgress = store.progress
                        }
                        let r = min(1, max(0, value.location.x / max(width, 1)))
                        dragProgress = r * store.duration
                        bridge.wakeHUD()
                    }
                    .onEnded { _ in
                        guard isDraggingProgress else { return }
                        isDraggingProgress = false
                        store.seek(to: dragProgress)
                        bridge.wakeHUD()
                    }
            )
            .disabled(store.duration <= 0)
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(formatTime(sliderValue)) / \(formatTime(store.duration))")
        }
        .frame(height: 16)
    }

    // MARK: - 左下角（当前歌词小行 + 歌手名）

    private func bottomCaption(tokens: StageTokens, geo: GeometryProxy) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                // 当前歌词行（旧 bottomHUD 的 15pt 歌词小行，原样搬到左下角；
                // 无词时显示歌名，绝不用 ♪ 作假）。
                Text(currentLyricText)
                    .font(.system(size: tokens.captionLyricFont, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
                Rectangle()
                    .fill(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: tokens.captionDividerWidth, height: 1)
                Text(captionArtist)
                    .font(.system(size: tokens.captionArtistFont))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .frame(maxWidth: geo.size.width * 0.62, alignment: .leading)
            Spacer()
        }
        // 左边距横竖屏统一走 safeArea leading（r20 集成修：横屏之前只扣
        // sideMargin，灵动岛机一侧 safeArea 约 59pt，字块会顶到传感器区）。
        .padding(.leading, tokens.sideMargin + geo.safeAreaInsets.leading)
        .padding(.trailing, tokens.sideMargin)
    }

    /// HUD 藏起后屏幕底部剩的小按钮（点一下唤醒 HUD，不往形态里传）。
    private func wakeButton(safeArea: EdgeInsets) -> some View {
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
        .padding(.bottom, safeArea.bottom + 24)
    }

    // MARK: - 派生文案

    /// 歌手 · 专辑（壳版 `#stage-sub` 同款格式）。
    private var trackSubtitle: String {
        guard let track = store.currentTrack else { return "—" }
        if track.album.isEmpty { return track.artist.isEmpty ? "—" : track.artist }
        return track.artist.isEmpty ? track.album : track.artist + " · " + track.album
    }

    /// 左下角歌手名（只要歌手，不要专辑，与截图一致）。
    private var captionArtist: String {
        guard let track = store.currentTrack else { return "—" }
        return track.artist.isEmpty ? "—" : track.artist
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
