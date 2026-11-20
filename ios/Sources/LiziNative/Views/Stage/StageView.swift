import SwiftUI

/// 舞台页（原生版屏幕 9，r20 横竖屏两套布局，对照用户 01:34 两张截图）。
///
/// 分层：
/// - 底层：`StageWebView`（WKWebView，file:// 加载 `Resources/stages/*.html`）。
/// - 上层：原生 HUD——竖屏顶行（返回 + 设置 / 形态三个按钮）+ 竖直中央
///   叠加的播放胶囊（r28：胶囊移出顶行，浮在舞台画面/歌词上面，歌词仍在
///   后面正常显示）；横屏整条控制行（返回 + 胶囊 + 设置 + 形态）都叠在
///   竖直中央，返回贴左墙、设置/形态贴右墙、胶囊正中间。左下角（当前歌词
///   小行 + 歌手名）。旧的底部迷你播放条（bottomHUD 整条）已撤，播放控制
///   全进胶囊；形态名胶囊已撤（形态名只在形态选择器里显示）。
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
/// - 返回一律回首页；设置齿轮开本形态设置浮层（只有形态声明了
///   `__stagePanel` 才显示）；九宫格开形态下拉浮层（r26：两个都是盖在
///   当前舞台画面上的就地浮层，不跳页、不停歌，点外面收起，互斥）。
/// - HUD 闲置 2.6 秒自动藏起（桥里 `startHudTimer`），藏起后非相机形态
///   点一下屏幕就唤醒（全屏透明唤醒层，壳版 `#stage-tap` 同款）；相机形态
///   不盖点屏层（拖动镜头不受影响），所以只在相机形态下保留「显示控制」
///   小按钮作唤回入口（见 `wakeButton`），其余形态藏起后底部什么也不剩。
/// - 相机形态（552 烟雨江南）：播放胶囊默认收起成封面 + 播放键，点封面展开
///   （旧 bottomHUD 的收起态语义，原样搬进中央胶囊）。
/// - 播放 / 暂停 / 切歌 / 进度 seek 接原来的 store 调用，一个不少；
///   无曲目时控制禁用，歌名「未播放」、副标题「—」，不编假数据。
/// - 歌词行变化只读同一份 store（`PlaybackStore.currentLyricIndex`），
///   本页不另起链路；锁屏由 NowPlayingCoordinator 经 MPNowPlayingInfoCenter
///   供图/信息，r28 已移除灵动岛。
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

    /// 收起两个就地浮层（点外面 / 选完形态 / 关设置都走这里）。
    private func closePanels() {
        showPicker = false
        showSettings = false
    }

    /// 形态下拉与齿轮面板互斥：开一个就关另一个；再点一次收起。
    private func togglePicker() {
        bridge.wakeHUD()
        showSettings = false
        showPicker.toggle()
    }

    private func toggleSettings() {
        bridge.wakeHUD()
        showPicker = false
        showSettings.toggle()
    }

    /// 就地浮层本体（r26）：形态下拉 / 齿轮面板二选一，右上锚定、
    /// 顶行下方 10pt（壳版 `.smenu` / `.spnl` 的 `top: calc(100% + 10px)`）。
    /// r28：横屏触发按钮已移到竖直中央，浮层仍锚右上不跟按钮走——放中央行
    /// 下方会超屏底（行底约 223pt + 面板高 228pt > 393pt），右上锚定照常可用。
    /// 宽：下拉 min(560, 可用宽)，设置 min(340, 可用宽)（壳版 402 / 320，
    /// 设计图下拉更宽）；高：下拉 min(58% 屏高, 520)，设置 min(62% 屏高, 560)，
    /// 超出可滚。歌不停：浮层只盖画面，不动播放状态。
    @ViewBuilder
    private func floatingPanel(tokens: StageTokens, geo: GeometryProxy) -> some View {
        let topRowHeight: CGFloat = tokens.topCapsuleHeight
        let panelTop = geo.safeAreaInsets.top + tokens.topGap + topRowHeight + 10
        let horizontalSpace = geo.size.width
            - geo.safeAreaInsets.leading - geo.safeAreaInsets.trailing
            - tokens.sideMargin * 2
        if showPicker {
            StageFloatPanel(width: min(560, horizontalSpace),
                            maxHeight: min(geo.size.height * 0.58, 520)) {
                StagePickerView(bridge: bridge) { form in
                    closePanels()
                    if form.isClassic {
                        navigation.show(.player)
                    } else {
                        bridge.load(form: form)
                    }
                }
            }
            .transition(.scale(scale: 0.98, anchor: .topTrailing).combined(with: .opacity))
            .padding(.top, panelTop)
            .padding(.trailing, geo.safeAreaInsets.trailing + tokens.sideMargin)
        } else if let spec = bridge.panelSpec {
            StageFloatPanel(width: min(340, horizontalSpace),
                            maxHeight: min(geo.size.height * 0.62, 560)) {
                StageSettingsView(bridge: bridge, spec: spec) {
                    closePanels()
                }
            }
            .transition(.scale(scale: 0.98, anchor: .topTrailing).combined(with: .opacity))
            .padding(.top, panelTop)
            .padding(.trailing, geo.safeAreaInsets.trailing + tokens.sideMargin)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let tokens = StageTokens.for(size: geo.size)
            ZStack {
                StageWebView(bridge: bridge)
                    .ignoresSafeArea()

                // HUD 藏起时：全屏透明唤醒层（壳版 `#stage-tap` 同款——点一下只唤醒
                // 浮层，不往形态里传；相机形态不盖这层，拖动镜头不受影响，
                // 相机形态改走底部「显示控制」药丸唤回，见 wakeButton）。
                if !bridge.hudVisible, !bridge.isCamera {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { bridge.wakeHUD() }
                }

                // 浮层点按捕捉层（r26）：面板开着时盖住舞台画面（在 HUD
                // VStack 之下，所以顶行按钮仍可点、两个浮层可直接互切），
                // 面板外的任何一点都收起两个浮层；歌不停。
                if showPicker || showSettings {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { closePanels() }
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
                    } else if bridge.isCamera {
                        // r28：非相机形态 HUD 藏起后点屏唤醒，底部不再留
                        // 「显示控制」药丸；相机形态没有点屏唤醒层（拖镜头
                        // 不受影响），只在相机形态下保留药丸作唤回入口，
                        // 否则相机形态 HUD 藏起后回不来（见 wakeButton）。
                        wakeButton(safeArea: geo.safeAreaInsets)
                    }
                }
                .ignoresSafeArea()
            }
            // 控制行（r28）：竖屏只有播放胶囊叠在页面竖直中央；横屏整条
            // 控制行（返回 + 胶囊 + 设置 + 形态）都叠在页面竖直中央，返回
            // 贴左墙、设置/形态贴右墙、胶囊正中间（见 landscapeCenterRow）。
            // ZStack 默认居中对齐 + 本 overlay(alignment: .center) 双保险；
            // 只在 HUD 可见时出现，随 HUD 一起藏起。胶囊本体与尺寸一字不动，
            // 浮在舞台画面 / 中央歌词上面，歌词仍在后面正常显示、不改布局。
            .overlay(alignment: .center) {
                if bridge.hudVisible {
                    if tokens.isLandscape {
                        landscapeCenterRow(tokens: tokens, geo: geo)
                    } else {
                        centeredPlayerCapsule(tokens: tokens, geo: geo)
                    }
                }
            }
            // 两个就地浮层（r26，用户 22:35 设计图 + 22:36 齿轮同款）：
            // 挂在 ZStack 上才能拿到 geo；本体见 floatingPanel。
            .overlay(alignment: .topTrailing) {
                if showPicker || showSettings {
                    floatingPanel(tokens: tokens, geo: geo)
                }
            }
            .animation(.easeOut(duration: 0.18), value: showPicker)
            .animation(.easeOut(duration: 0.18), value: showSettings)
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
    }

    // MARK: - 顶行（仅竖屏：返回 + 设置 / 形态三个按钮；横屏整条控制行
    //   已移到页面竖直中央贴墙，见 landscapeCenterRow；播放胶囊竖屏叠在
    //   中央，见 centeredPlayerCapsule）

    @ViewBuilder
    private func topRow(tokens: StageTokens, geo: GeometryProxy) -> some View {
        if !tokens.isLandscape {
            portraitTopRow(tokens: tokens, geo: geo)
        }
    }

    /// 竖屏顶行（r28）：左返回圆按钮（只有 < 箭头）+ 右设置齿轮 + 九宫格
    /// 两个圆按钮（只有图标），中间 Spacer 撑开；播放胶囊不在顶行了。
    /// 圆钮直径见 tokens.roundButtonDiameter（36/40/42），图标 15pt
    /// （直径等比缩：17 × 40/44 ≈ 15.5 → 15）。
    private func portraitTopRow(tokens: StageTokens, geo: GeometryProxy) -> some View {
        HStack(spacing: tokens.topRowGap) {
            Button(action: {
                bridge.wakeHUD()
                navigation.show(.home)
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: tokens.roundButtonDiameter, height: tokens.roundButtonDiameter)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
            }
            .accessibilityLabel("返回首页")

            Spacer(minLength: 0)

            // 设置按钮：只有形态声明了 __stagePanel 才显示（壳版同款显隐规则；
            // 85 个已收录形态全有声明，所以实际常驻）。
            if bridge.panelSpec != nil {
                Button(action: { toggleSettings() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: tokens.roundButtonDiameter, height: tokens.roundButtonDiameter)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                }
                .accessibilityLabel("本形态设置")
            }

            Button(action: { togglePicker() }) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: tokens.roundButtonDiameter, height: tokens.roundButtonDiameter)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
            }
            .accessibilityLabel("选择形态")
        }
        .padding(.leading, geo.safeAreaInsets.leading + tokens.sideMargin)
        .padding(.trailing, geo.safeAreaInsets.trailing + tokens.sideMargin)
        // r26：竖屏顶边 = geo.safeAreaInsets.top + topGap；本页根 GeometryReader
        // 与 VStack 都 .ignoresSafeArea()，运行时 geo.safeAreaInsets.top 是 0，
        // 所以有效顶边就是 topGap（竖屏 48/52/56，标准档 52pt，脱开岛底 48pt；
        // r27：35/39/43 → 48/52/56）。
        // 别把这一项换成 key window 安全区——那会一下冲到约 91pt。
        .padding(.top, geo.safeAreaInsets.top + tokens.topGap)
    }

    /// 横屏控制行（r28）：整条移到页面竖直中央（挂在 body 的
    /// `.overlay(alignment: .center)` 里，ZStack 居中对齐），不再占顶行。
    /// 贴墙：返回贴左墙、设置/形态贴右墙——左右边距只留 safeArea，不再加
    /// sideMargin（横屏灵动岛机一侧 safeArea 约 59pt，传感器区仍避开）；
    /// 播放胶囊放 ZStack 中央，正中间。胶囊高 36、图标与文字 14pt
    /// （高 40 → 36 等比缩：15 × 36/40 = 13.5 → 14）。
    /// 左右两端宽度不等（左 76–84、右 164–190 含间距），胶囊不用 Spacer
    /// 顶——ZStack 居中放胶囊、HStack 贴墙放三按钮，两层叠加，胶囊严格居中。
    private func landscapeCenterRow(tokens: StageTokens, geo: GeometryProxy) -> some View {
        let insets = geo.safeAreaInsets
        return ZStack {
            centeredPlayerCapsule(tokens: tokens, geo: geo)

            HStack(spacing: 0) {
                Button(action: {
                    bridge.wakeHUD()
                    navigation.show(.home)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(.white)
                    .frame(width: tokens.backCapsuleWidth, height: tokens.topCapsuleHeight)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                }
                .accessibilityLabel("返回首页")

                Spacer(minLength: 0)

                if bridge.panelSpec != nil {
                    Button(action: { toggleSettings() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 14, weight: .medium))
                            Text("设置")
                                .font(.system(size: 14))
                        }
                        .foregroundStyle(.white)
                        .frame(width: tokens.settingsCapsuleWidth, height: tokens.topCapsuleHeight)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                    }
                    .accessibilityLabel("本形态设置")

                    Color.clear.frame(width: tokens.topRowGap, height: 1)
                }

                Button(action: { togglePicker() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 14, weight: .medium))
                        Text("形态")
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(.white)
                    .frame(width: tokens.pickerCapsuleWidth, height: tokens.topCapsuleHeight)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                }
                .accessibilityLabel("选择形态")
            }
            .frame(maxWidth: .infinity)
            // 贴墙：只留 safeArea，不加 sideMargin。
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
        }
    }

    /// 居中叠加的播放胶囊（r28）：竖屏自适应宽（顶行同款边距），横屏取
    /// min(档位理想宽, 内容宽)，相机收起态按内容宽；本体
    /// `playerCapsule` 一字不动，只换了挂载位置（顶行 → 页面竖直中央）。
    @ViewBuilder
    private func centeredPlayerCapsule(tokens: StageTokens, geo: GeometryProxy) -> some View {
        if tokens.isLandscape {
            let insets = geo.safeAreaInsets
            let contentW = geo.size.width - insets.leading - insets.trailing - tokens.sideMargin * 2
            let collapsed = bridge.isCamera && !pillExpanded
            let collapsedWidth = tokens.coverSize + 10 + tokens.playButtonFrame + tokens.capsuleHPadding * 2
            let capsuleW: CGFloat = collapsed
                ? collapsedWidth
                : min(tokens.idealCapsuleWidthLandscape, contentW)
            playerCapsule(tokens: tokens, width: capsuleW)
        } else {
            playerCapsule(tokens: tokens, width: nil)
                .frame(maxWidth: .infinity)
                .padding(.leading, geo.safeAreaInsets.leading + tokens.sideMargin)
                .padding(.trailing, geo.safeAreaInsets.trailing + tokens.sideMargin)
        }
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

    /// 「显示控制」药丸（r28：只在相机形态下保留）。非相机形态 HUD 藏起后
    /// 点一下屏幕就唤醒（全屏透明唤醒层），不再需要它；相机形态不盖点屏层
    /// （拖动镜头不受影响），且桥的 `activity` 回调在相机形态下不唤醒 HUD、
    /// `startHudTimer` 照常 2.6 秒藏 HUD，所以药丸是相机形态下唤回控制栏
    /// 的唯一入口——删了它，相机形态 HUD 藏起后就回不来了。点一下唤醒 HUD，
    /// 不往形态里传。
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
