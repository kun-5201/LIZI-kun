import SwiftUI

/// 舞台页（原生版屏幕 9，r20 横竖屏两套布局，对照用户 01:34 两张截图；
/// v5 胶囊改版：胶囊收进顶行，不再叠页面竖直中央）。
///
/// 分层：
/// - 底层：`StageWebView`（WKWebView，file:// 加载 `Resources/stages/*.html`）。
/// - 上层：原生 HUD——竖屏/横屏同一条顶行：返回 + 播放胶囊（居中）+
///   设置 / 形态，全部贴顶行；竖屏顶行顶 = topGap 52（标准档），岛底约
///   48，胶囊不盖灵动岛；横屏顶行贴屏幕顶边（topGap 20）。竖屏胶囊是
///   紧凑版（填返回与设置/形态之间的槽位，标准档 208pt，封面/字号/三键
///   各缩一档，进度条只留细条不带时间——槽位就这么宽，正常版歌名只剩两字）；
///   横屏胶囊沿用正常版理想宽 320/340/380 居中。左下角（当前歌词小行 +
///   歌手名）一字不动：位置、字号、内容都不改；歌词区里淡字的下一行歌词
///   （如「慌啥子嘛 / 赵本山」）是歌词本身，留着，不删。
///   胶囊副标题只写歌手（r29 task 8 已做，`trackSubtitle` 不含歌名），
///   歌名只在胶囊标题出现一次，本次只确认、不改。
///   旧的底部迷你播放条（bottomHUD 整条）已撤，播放控制全进胶囊；
///   形态名胶囊已撤（形态名只在形态选择器里显示）。
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
/// - HUD 闲置 2.6 秒自动藏起（桥里 `startHudTimer`），藏起后点一下屏幕
///   就唤醒：非相机形态是全屏透明唤醒层（壳版 `#stage-tap` 同款）；
///   相机形态（552 烟雨江南）不盖这层（会吃掉拖动手势），改走挂在 webView
///   上的轻点识别器（见 StageWebViewCoordinator：只认轻点，拖动照常进
///   形态）。r31 以前相机形态靠底部「显示控制」药丸唤回，药丸已删
///   （用户 06:18），HUD 藏起后底部什么也不剩，所有形态一致。
/// - 播放胶囊所有形态同一套：封面 + 歌名/歌手 + 上一首/播放/下一首 +
///   进度条，不再有相机形态默认收起（只剩封面 + 播放键）的特殊态——
///   r31 以前 552 默认收起，用户报控制行「只显示暂停」，与其它形态对齐
///   后删掉了收起态（`pillExpanded` / `wakeButton` 一并删）。
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
    /// 进度条拖动态（拖动中显示拖动值、松手才 seek，与旧 Slider 的做法一致）。
    @State private var isDraggingProgress = false
    @State private var dragProgress: Double = 0

    private let initialFormId: String?

    /// r35-7：openSettings 为真时进页即打开设置浮层（传统横屏「舞台控制」钮
    /// 直达 StageSettingsView，不新造面板；panelSpec 是异步取的，浮层在
    /// spec 到达后才出现，与页内齿轮点开同一条路；默认 false，旧行为不动）。
    init(initialFormId: String? = nil, openSettings: Bool = false) {
        self.initialFormId = initialFormId
        _showSettings = State(initialValue: openSettings)
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
    /// v5：顶行高 = 顶行胶囊实高（`topRowCapsuleHeight`：竖屏紧凑胶囊约
    /// 56、横屏正常胶囊约 60），不再是三按钮高 36/40——按旧值锚面板会
    /// 压住胶囊下沿。宽：下拉 min(560, 可用宽)，设置 min(340, 可用宽)（壳版 402 / 320，
    /// 设计图下拉更宽）；高：下拉 min(58% 屏高, 520)，设置 min(62% 屏高, 560)，
    /// 超出可滚。歌不停：浮层只盖画面，不动播放状态。
    @ViewBuilder
    private func floatingPanel(tokens: StageTokens, geo: GeometryProxy) -> some View {
        let topRowHeight: CGFloat = tokens.topRowCapsuleHeight
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
                        // r36-7：切形态只记本次播放器会话
                        // （AppNavigation.sessionStageFormId，内存），不写
                        // 持久化键——回首页后重置，下次进播放器是传统、
                        // 再点舞台也不会把这个形态带回来；写盘只剩画廊
                        // （StageFormStore.select）。`bridge.load` 本身也不
                        // 再写键（见 StageBridge.load 的 r36-7 注释）。
                        navigation.noteStageFormSelected(form.formId)
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
                // 相机形态改走 webView 上的轻点识别器唤醒，见
                // StageWebViewCoordinator；r31 以前相机形态靠底部药丸唤回，
                // 药丸已删，所有形态都不再有「显示控制」）。
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
                    }
                    // r31：HUD 藏起后底部什么也不剩（所有形态一致）。相机形态
                    // 的唤回靠 webView 上的轻点识别器，不再有底部药丸。
                }
                .ignoresSafeArea()
            }
            // 顶行（v5）：竖屏/横屏同一条顶行——返回 + 胶囊（居中）+ 设置 +
            // 形态，竖屏顶在岛下（topGap 52，岛底约 48，不盖岛），横屏贴屏幕
            // 顶边（topGap 20）。胶囊不再叠页面竖直中央（r28 旧挂载已删）；
            // 左下角歌词字块一字不动，位置、字号、内容都不改。
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
        }
        .onDisappear {
            bridge.detach()
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

    // MARK: - 顶行（v5：竖屏/横屏同一条顶行——返回 + 胶囊（居中）+
    //   设置 / 形态；竖屏顶在岛下，横屏贴屏幕顶边；左下角歌词不动）

    @ViewBuilder
    private func topRow(tokens: StageTokens, geo: GeometryProxy) -> some View {
        if tokens.isLandscape {
            landscapeTopRow(tokens: tokens, geo: geo)
        } else {
            portraitTopRow(tokens: tokens, geo: geo)
        }
    }

    /// 竖屏顶行圆按钮（只有图标）：返回 < / 设置齿轮 / 九宫格三枚，
    /// 直径见 tokens.roundButtonDiameter（36/40/42），图标 15pt。
    private func circleButton(tokens: StageTokens,
                              systemName: String,
                              label: String,
                              weight: Font.Weight = .medium,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: weight))
                .foregroundStyle(.white)
                .frame(width: tokens.roundButtonDiameter, height: tokens.roundButtonDiameter)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .accessibilityLabel(label)
    }

    /// 竖屏顶行（v5）：返回圆钮贴左 + 紧凑胶囊填中间槽位 + 设置齿轮 +
    /// 九宫格贴右，一排都在岛下面。胶囊不定宽（HStack 填槽，标准档 208pt），
    /// 内部是紧凑版（封面 36、歌名 14、三键 18/20/18、进度条只留细条
    /// 不带时间）——槽位就这么宽，用正常版歌名只剩两字，再大一档只剩 4 字。
    /// 圆钮在行内垂直居中（行高 = 胶囊高约 56，圆钮 40）。
    /// 顶边 = geo.safeAreaInsets.top + topGap；本页根 GeometryReader
    /// 与 VStack 都 .ignoresSafeArea()，运行时 geo.safeAreaInsets.top 是 0，
    /// 所以有效顶边就是 topGap（竖屏 48/52/56，标准档 52pt，岛底约 48pt，
    /// 胶囊顶露出 4pt 不盖岛；紧凑档 48pt 的机型没有灵动岛）。
    /// 别把这一项换成 key window 安全区——那会一下冲到约 91pt。
    private func portraitTopRow(tokens: StageTokens, geo: GeometryProxy) -> some View {
        HStack(spacing: tokens.topRowGap) {
            circleButton(tokens: tokens, systemName: "chevron.left", label: "返回首页", weight: .semibold) {
                bridge.wakeHUD()
                navigation.show(.home)
            }

            // 紧凑胶囊：填槽，歌名/歌手单行 + 三键 + 细进度条（无时间）。
            playerCapsule(tokens: tokens, width: nil, compact: true)
                .frame(maxWidth: .infinity)

            // 设置按钮：只有形态声明了 __stagePanel 才显示（壳版同款显隐规则；
            // 86 个已收录形态全有声明，所以实际常驻）。
            if bridge.panelSpec != nil {
                circleButton(tokens: tokens, systemName: "gearshape", label: "本形态设置") {
                    toggleSettings()
                }
            }

            circleButton(tokens: tokens, systemName: "square.grid.2x2", label: "选择形态") {
                togglePicker()
            }
        }
        .padding(.leading, geo.safeAreaInsets.leading + tokens.sideMargin)
        .padding(.trailing, geo.safeAreaInsets.trailing + tokens.sideMargin)
        .padding(.top, geo.safeAreaInsets.top + tokens.topGap)
    }

    /// 横屏顶行（v5，取代 r28 的竖直中央行）：整条贴屏幕顶边（顶 = topGap
    ///   16/20/24，横屏灵动岛在左右边中段，纵向不相交），返回贴左墙、
    ///   设置/形态贴右墙——左右边距只留 safeArea，不再加 sideMargin
    ///   （横屏灵动岛机一侧 safeArea 约 59pt，传感器区仍避开）；
    ///   播放胶囊放 ZStack 中央，正中间，理想宽 320/340/380 一字不动。
    ///   胶囊高 36 的说法是旧三按钮高，现胶囊实高约 55–64（见
    ///   `topRowCapsuleHeight`，浮层锚定走它）；图标与文字 14pt。
    /// 左右两端宽度不等（左 76–84、右 164–190 含间距），胶囊不用 Spacer
    /// 顶——ZStack 居中放胶囊、HStack 贴墙放三按钮，两层叠加，胶囊严格居中。
    private func landscapeTopRow(tokens: StageTokens, geo: GeometryProxy) -> some View {
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
        // v5：整条贴屏幕顶边（竖屏同款公式，横屏 topGap 16/20/24）。
        .padding(.top, geo.safeAreaInsets.top + tokens.topGap)
    }

    /// 横屏居中播放胶囊（v5：只横屏用，竖屏改走顶行紧凑胶囊）：
    /// 取 min(档位理想宽, 内容宽)；本体 `playerCapsule` 一字不动，只换了
    /// 挂载位置（r28 竖直中央 → v5 顶行）。r31：删掉了相机收起态的按内容
    /// 宽（胶囊不再收起，所有形态同一宽）。
    @ViewBuilder
    private func centeredPlayerCapsule(tokens: StageTokens, geo: GeometryProxy) -> some View {
        // 只横屏调用（topRow 已按横竖屏分流）；竖屏走顶行紧凑胶囊。
        let insets = geo.safeAreaInsets
        let contentW = geo.size.width - insets.leading - insets.trailing - tokens.sideMargin * 2
        let capsuleW: CGFloat = min(tokens.idealCapsuleWidthLandscape, contentW)
        playerCapsule(tokens: tokens, width: capsuleW)
    }

    // MARK: - 播放胶囊（封面 + 歌名/歌手 + 上一首/播放/下一首 + 进度条）

    /// 播放胶囊。`width` 为 nil 时自适应（竖屏顶行里撑满剩余宽）；
    /// 横屏传算好的固定宽。r31：所有形态同一套完整胶囊——相机形态
    /// 默认收起（只剩封面 + 播放键）已删，控制行永远是上一首/播放/
    /// 下一首 + 进度条（用户报 552「只显示暂停」，就是收起态）。
    /// `compact`（v5 竖屏顶行）：内部尺寸走 `top*` 紧凑档（封面/字号/
    /// 三键各缩一档），进度条只留细条不带时间——与 v5 图一致，也是不带
    /// 时间才能在 208pt 槽位里放下 5 字歌名的原因；拖动 seek 不变。
    /// 副标题只写歌手（r29 task 8），歌名只在标题出现一次，这里不改。
    private func playerCapsule(tokens: StageTokens, width: CGFloat?, compact: Bool = false) -> some View {
        let cover = compact ? tokens.topCoverSize : tokens.coverSize
        let titleF = compact ? tokens.topTitleFont : tokens.titleFont
        let artistF = compact ? tokens.topArtistFont : tokens.artistFont
        let skipF = compact ? tokens.topSkipButtonFrame : tokens.skipButtonFrame
        let playF = compact ? tokens.topPlayButtonFrame : tokens.playButtonFrame
        let skipI = compact ? tokens.topSkipIconSize : tokens.skipIconSize
        let playI = compact ? tokens.topPlayIconSize : tokens.playIconSize
        let hPad = compact ? tokens.topCapsuleHPadding : tokens.capsuleHPadding
        let vPad = compact ? tokens.topCapsuleVPadding : tokens.capsuleVPadding
        return HStack(spacing: compact ? 8 : 10) {
            // 封面（r31：只是封面，不再是按钮——原来相机形态点封面展开/
            // 收起胶囊，收起态已删，封面不再承担开关）。
            CoverImageView(url: store.currentTrack?.coverURL, placeholderIconSize: 16)
                .frame(width: cover, height: cover)
                .clipShape(RoundedRectangle(cornerRadius: tokens.coverCornerRadius))
                .accessibilityLabel("封面")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.currentTrack?.title ?? "未播放")
                            .font(.system(size: titleF, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(trackSubtitle)
                            .font(.system(size: artistF))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    .frame(minWidth: 20, alignment: .leading)

                    Spacer(minLength: 6)

                    transportButton(tokens: tokens,
                                    systemName: "backward.fill",
                                    iconSize: skipI,
                                    frame: skipF,
                                    label: "上一首") { store.previous() }
                    playButton(tokens: tokens, frame: playF, iconSize: playI)
                    transportButton(tokens: tokens,
                                    systemName: "forward.fill",
                                    iconSize: skipI,
                                    frame: skipF,
                                    label: "下一首") { store.next() }
                }

                if compact {
                    progressScrubber()
                } else {
                    progressRow(tokens: tokens)
                }
            }
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: tokens.capsuleCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: tokens.capsuleCornerRadius).stroke(.white.opacity(0.28), lineWidth: 1))
        .frame(width: width)
    }

    private func playButton(tokens: StageTokens, frame: CGFloat, iconSize: CGFloat) -> some View {
        Button(action: { bridge.wakeHUD(); store.togglePlay() }) {
            Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: iconSize))
                .foregroundStyle(.white)
                .frame(width: frame, height: frame)
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

    // r31：「显示控制」药丸已删（用户 06:18）。相机形态 HUD 藏起后的唤回
    // 改走 webView 上的轻点识别器（见 StageWebViewCoordinator），不再有
    // 底部药丸；`wakeButton` 整个函数随药丸一起删掉了。

    // MARK: - 派生文案

    /// 只写歌手（r29 task 8：副标题不再拼专辑，歌名只在胶囊标题出现一次）。
    private var trackSubtitle: String {
        guard let track = store.currentTrack else { return "—" }
        if track.artist.isEmpty { return track.album.isEmpty ? "—" : track.album }
        return track.artist
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
