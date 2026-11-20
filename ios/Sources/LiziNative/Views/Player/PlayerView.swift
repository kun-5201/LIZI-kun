import SwiftUI

/// 播放页（r20 截图布局 1:1，对照 01:14 播放页截图；r21b 只修布局锚定；
/// r22a：顶栏最终版（左返回 + 搜索 + 齿轮进舞台，位置上移到紧贴状态栏
/// 下方）+ 横屏宽度（屏宽 + key window 安全区，铺满 874）+ YRC 尖括号
/// 变体解析（新接口），竖屏其他部分不动。顶栏纠正（05:30 用户标注截图
/// 为准）：r22a 的「九宫格进舞台 + 齿轮开调节面板」做法作废，九宫格只在
/// 舞台页，播放页顶栏不再弹舞台调节面板；齿轮是控制舞台按钮，进舞台页。
/// r22k：按两张审计图核对——控制行竖屏是随机/爱心/上一首/播放/下一首/循环、
/// 横屏是爱心/三条杠/上一首/播放/下一首/循环（r28：横屏第 1 项随机换爱心），无 AirPlay（PlayerDockView.swift）；
/// 队列入口竖屏点歌名块、横屏点三条杠，副标题只留歌手；
/// 顶栏位置（顶边 59）、横屏铺满、YRC 解析一字未动；顶栏图标与接线
/// 按本次纠正改（返回 + 搜索 + 齿轮进舞台）。
/// r23i：顶栏再上移（竖屏圆钮顶边 120.7→39，横屏胶囊顶边 0→10；只改顶栏
/// padding，见 windowTopInset 下的 r23i 常量与文件底「r23i 根因」）。
/// r22 横屏重排：旧左右分栏作废（歌名在左列压到歌词上重叠，用户 05:32 截图）；
/// 新图纸横屏 5 条：歌名左上、歌词居中、横屏文字胶囊顶栏、封面流居中顶部、
/// 横屏铺满。竖屏布局只动控制行（爱心 + 去 AirPlay）这一件，其余一字未动。
///
/// r21b 改动（只动本文件 + CoverFlowView 的 isCompact + LyricsZoneView 的区宽，
/// 不动播放核心、岛、锁屏、音源链）：
/// - 恢复的几何：壳版窄屏 `.now`（纵向 flex 列：顶栏 → 封面流 → 弹性歌词区 →
///   歌名/传输排 → 底部进度条；每行 `min-width: 0 / max-width: 100%`、宽度由
///   视口定，不由内容定），用 r19 的 SwiftUI 结构实现（GeometryReader +
///   ZStack + VStack、固定分档尺寸、歌词区唯一弹性段）。段顺序与 r20 一致，
///   r20 的段顺序本身就是壳版窄屏顺序；r19 把歌名/传输排放在歌词面板之前，
///   是与壳版不同的一处，r21b 不采纳。
/// - 竖屏右移根因（实测钉死，见文件底「r21b 根因」）：r20 的内容 VStack 被
///   内容理想宽度撑到约 786pt（≈2 倍屏宽），再被默认居中的 ZStack 居中，
///   居中内容落在约 406pt（右移约 205pt）、整列下移约 65pt。修法：ZStack
///   .topLeading + 背景死宽高 + 每行死宽度，三处同时钉死。
/// - 横屏新分支：壳版宽屏 `.now__stage` 左右分栏（封面列 + 歌词列 1fr），按
///   手机横屏 874×402 收窄：左列 220（封面 + 歌名 + 控制行），右列歌词区；
///   灵动岛在左/在右都扣 leading/trailing 安全区。
///
/// 导航（P1-B 的 `AppNavigation`，已合入 `Sources/LiziNative/AppNavigation.swift`，
/// 本文件按约定引用，不新建导航、不改 `RootView.swift`）：`AppNavigation` 是
/// `@EnvironmentObject`，`enum AppView { case home, search, player, ... }`，
/// `show(_:)` 切页。`PlaybackStore` 与 `AppNavigation` 都已由 App / RootView
/// 经 environmentObject 下发，本页直接取用。
///
/// 纵向结构（从上到下，截图顺序）：
/// 顶栏（圆形毛玻璃按钮）→ 3D 封面流（上半部）→ 歌词区（`LyricsZoneView`）
/// → 歌名 / 歌手 → 底部三排
/// （`PlayerBottomDock`，r27 v4；02/04/06 变体与横屏仍是控制行 +
/// 最底部细进度条，见 portraitLayout 注释）。
///
/// 依赖（r20 三工人分工，本文件只引用、不定义）：
/// - `LyricsZoneView`：工人 B 在 `LyricsPanelView.swift` 里新建——截至交回时
///   仍未落地，本文件先按任务书给的名字引用，集成时等工人 B。
/// - `PlayerControlRow(tier:)` / `PlayerProgressBar(tier:)`：
///   工人 C 已在 `PlayerDockView.swift` 里落地（r22 定稿：控制行竖屏是
///   随机 / 爱心 / 上一首 / 播放 / 下一首 / 循环，横屏是爱心 / 三条杠 /
///   上一首 / 播放 / 下一首 / 循环（r28：横屏第 1 项随机换爱心），无 AirPlay；队列入口竖屏点歌名块
///   （见 titleBlock）、横屏点三条杠；细条无时间数字，拖动 seek，播放头是圆点）。
///   r27 v4：默认版式不再用它俩（改走 `PlayerBottomDock`，进度条在 dock
///   里复用 `PlayerProgressBar` + 两端时间）；02/04/06 变体与横屏仍用。
/// - 分档 API：工人 C 已在 `PlayerTokens.swift` 里落地，
///   `sizeTier(for:topInset:)` / `topBarButton(_:)` / `titleSize(_:)` /
///   `subtitleSize(_:)` / `coverItem(_:)` / `coverTrackHeight(_:)` /
///   `lyricsZoneHeight(_:)` / `playSize(_:)` / `progressHeight(_:)`，
///   `CoverFlowView` 也已改成 `CoverFlowView(tier:)`，这里全部只调用。
///   在 `LyricsZoneView` 落齐之前本文件单独编译不过，集成由协调员收齐后做。
///
/// - 禁缩放：本页没有任何 MagnificationGesture / 捏合手势（MEMORY：任何操作禁缩放）。
/// - 分档：尺寸全走 `PlayerTokens.sizeTier(for:topInset:)`；刘海 / 灵动岛两种
///   顶部形态都走 `geo.safeAreaInsets`，不写死顶部 padding、不写死型号数值。
/// - 歌词区是唯一弹性段（最小高 `lyricsZoneHeight(tier)`，其余空间全归它）：
///   固定段（顶栏 + 封面 + 歌名块 + 控制行 + 细进度条 + 安全区）之和小于
///   屏高，剩下的全给歌词区，所以结构上不会超高；各档总账见文件底注释
///   （与工人 C 在 `PlayerTokens.swift` 里算的总账同一套数）。
/// - 队列面板：只盖住歌词区（见 `lyricsZone`），绝不遮控制行和进度条。
/// - 无曲目时是空态（标题「未在播放」），不编假数据。
///
/// r25 #7：播放页排版接线（`SettingsStore.nowLayout`，键 `lizi.now.layout`，
/// 壳版 `public/player-layouts/player-layouts.js` + `player-layouts.css`，
/// 读完的结论，不是猜的）：
/// - 默认 `""`：壳版桌面是左右两栏（左封面 + 右歌词）；原生默认是竖屏纵向栈
///   （顶栏 → 封面流 → 歌词区 → 歌名 → 控制行 → 进度条）与横屏 5 条，
///   与壳版窄屏单列一致——默认版式一字不动。
/// - `02` 左右对半（壳版桌面：左列封面 + 歌名 + 控制 / 右列歌词，50/50 两列
///   通高）：横屏按桌面做（左列封面流 + 歌名 + 控制 / 右列歌词）；竖屏 390pt
///   做不了 50/50 两列，按壳版 ≤900px 窄屏兜底做（顶部一行 68pt 小封面 +
///   歌名，控制行在歌名行之下、歌词区之上，下方整幅歌词）。
/// - `04` 上下分屏（壳版桌面：上半 hero 封面 + 歌名 + 控制 / 下半整幅歌词）：
///   竖屏与横屏都按这个做（封面 → 歌名 → 控制 → 歌词区 → 进度条；
///   横屏 hero 行是封面流 + 右边歌名/控制上下叠）。
/// - `06` 极小封面（壳版桌面：96px 小封面左上 + 歌名在右 + 歌词居中大面积 +
///   控制浮底居中）：竖屏与横屏都按这个做（96pt 小封面行 → 歌词区弹性
///   → 控制行 → 进度条）。
/// 缺口（不编假版式）：
/// - 壳版 ≤900px 窄屏兜底把 02/04/06 三套收成同一套（顶部 68pt 小封面行 +
///   歌词），原生竖屏 04/06 未按这条收成与 02 同一套，而是按桌面结构分开做——
///   这是有意的（手机上三套仍有区分），与壳版 ≤900px 行为不完全相同。
/// - 壳版窄屏兜底把控制行并进顶行（按钮缩到 30/38pt）；原生
///   `PlayerControlRow` 最小一档也要 207pt 宽（compact：2×18 + 3×21 + 58 + 5×10，r28 壳版数），
///   塞不进 68pt 高的顶行，控制行只能单摆一行（02 在歌名行之下，
///   04 在歌词区之上、06 在歌词区之下），位置与壳版窄屏兜底差一行。
/// - 歌词对齐（壳版窄屏兜底歌词左对齐、06 居中）与字号/行距（壳版 04/06 改
///   `--ly-font` / `--ly-row`）由 `LyricsZoneView` 内部定，三套版式共用
///   一个歌词区，无法按版式改；本轮不碰 `LyricsPanelView.swift`。
/// - 壳版 02/04 的封面尺寸是 vw/vh 联动（02：min(32vw, 46vh)；
///   04：min(28vw, 32vh)），原生封面流只有 `CoverFlowView` 的三档固定尺寸，
///   版式里封面只按收小档（isCompact + 0.8）处理，不逐档复算 vw/vh。
/// - r27：歌词展开功能已删（见 LyricsPanelView.swift），封面不再随展开收小；
///   变体里封面本来就小或已在 hero 行，更不二次收小。
struct PlayerView: View {
    @EnvironmentObject private var store: PlaybackStore
    @EnvironmentObject private var navigation: AppNavigation

    /// 播放页版式（r25 #7）：读 `SettingsStore.nowLayout`（键
    /// `lizi.now.layout`，与设置页同一份）。PlayerView 每次进页新建，
    /// 初始化时已读到最新值；onAppear 再重读一道更稳。
    @StateObject private var settings = SettingsStore()

    /// 队列面板是否打开：控制行最左列表图标的回调切它（再点一次关上）。
    @State private var showQueue = false

    /// r28：登录弹窗目标（取链失败原因是登录时弹登录入口，目前只有酷狗）。
    /// 由 `store.loginPromptPlatform`（PlaybackStore，String?）或失败红字
    /// 点按置位；sheet 的 onDone 调 `store.dismissLoginPrompt()` 清信号。
    @State private var loginTarget: LoginSheetTarget?

    var body: some View {
        GeometryReader { geo in
            let tier = PlayerTokens.sizeTier(for: geo.size, topInset: geo.safeAreaInsets.top)
            let isLandscape = geo.size.width > geo.size.height
            // r21b：ZStack 必须顶左锚定（.topLeading），背景给死宽高。
            // r20 的教训（竖屏实测，见文件底「r21b 根因」）：默认居中的 ZStack +
            // 内容理想宽度撑大的 VStack，会把整页内容居中到约 406pt（右移约 205pt、
            // 下移约 65pt）。这里三处同时钉死：ZStack .topLeading、背景显式
            // frame(geo.size)、内容 VStack 显式 frame(geo.size, alignment: .topLeading)，
            // 之后任何一行内容再宽，也只能在 402 宽里截断，不会再把容器撑宽、居中。
            // r22a：宽高走 UIScreen.main.bounds（真屏尺寸，不取 geo.size——
            // geo 的安全区在真机上被垫高，见文件底「r22a 横屏根因」；屏尺寸本身
            // geo 与 UIScreen 一致，换源不换数，只是以后不再依赖 geo 的口径）。
            let screenSize = UIScreen.main.bounds.size
            ZStack(alignment: .topLeading) {
                background
                    .frame(width: screenSize.width, height: screenSize.height)
                if isLandscape {
                    landscapeLayoutFor(geo: geo, tier: tier)
                } else {
                    portraitLayoutFor(geo: geo, tier: tier)
                }
            }
            .frame(width: screenSize.width, height: screenSize.height, alignment: .topLeading)
            .onAppear { Self.logGeometry(geo) }
            .onChange(of: geo.size) { _ in Self.logGeometry(geo) }
        }
        // 禁缩放：SwiftUI 默认没有捏合缩放；这里明确不加任何缩放手势。
        .navigationBarHidden(true)
        .onAppear { settings.refreshNowLayout() }
        // r28：取链失败原因是登录时（目前只有酷狗）弹登录入口。
        // onChange 只在信号变化时触发；红字点按是另一条置位路径（见
        // statusCapsules），信号已立但本页后挂载时也能点红字补弹。
        .onChange(of: store.loginPromptPlatform) { platform in
            if let platform {
                loginTarget = LoginSheetTarget(platform: platform)
            }
        }
        .sheet(item: $loginTarget) { target in
            LoginSheetView(platform: target.platform, onDone: { store.dismissLoginPrompt() })
        }
    }

    /// r25 #7：按 `SettingsStore.nowLayout` 分发竖屏版式（"" 默认一字不动）。
    @ViewBuilder
    private func portraitLayoutFor(geo: GeometryProxy, tier: PlayerTokens.PlayerSizeTier) -> some View {
        switch settings.nowLayout {
        case "02": portraitLayout02(geo: geo, tier: tier)
        case "04": portraitLayout04(geo: geo, tier: tier)
        case "06": portraitLayout06(geo: geo, tier: tier)
        default: portraitLayout(geo: geo, tier: tier)
        }
    }

    /// r25 #7：按 `SettingsStore.nowLayout` 分发横屏版式（"" 默认一字不动）。
    @ViewBuilder
    private func landscapeLayoutFor(geo: GeometryProxy, tier: PlayerTokens.PlayerSizeTier) -> some View {
        switch settings.nowLayout {
        case "02": landscapeLayout02(geo: geo, tier: tier)
        case "04": landscapeLayout04(geo: geo, tier: tier)
        case "06": landscapeLayout06(geo: geo, tier: tier)
        default: landscapeLayout(geo: geo, tier: tier)
        }
    }

    /// r21b 诊断：真机确认用。打印 GeometryReader 实测尺寸 + 四边安全区，
    /// 供对照截图核对（竖屏应为 402×874、top 59；横屏 874×402、leading /
    /// trailing 一侧 59）。只记录，不改任何布局逻辑。
    private static func logGeometry(_ geo: GeometryProxy) {
        print("[r21-layout] geo=\(geo.size) safeArea top=\(geo.safeAreaInsets.top) leading=\(geo.safeAreaInsets.leading) trailing=\(geo.safeAreaInsets.trailing) bottom=\(geo.safeAreaInsets.bottom)")
    }

    // MARK: - 安全区真实值（r22a：不取 geo.safeAreaInsets，取 key window）

    /// key window 的安全区（真机实测：geo.safeAreaInsets 在用户机上被垫高到
    /// 124——顶栏顶边 124 而不是 59、横屏行宽 626 而不是 815，见文件底
    /// 「r22a 根因」；124 不是任何 iPhone 的真值。key window 的值是系统
    /// 自己的，不经过视图层级，不会被垫）。无窗口时回 .zero，调用方再兜底。
    private static var keyWindowSafeArea: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets ?? .zero
    }

    /// 顶部安全区真实值（竖屏顶栏顶边用它）：岛 59 / 刘海 47 / 无刘海 20，
    /// 夹到 ≤59（124 是被垫高的假值）；无窗口时按刘海机型 47 兜底
    /// （与 LyricsPanelView.keyWindowTopInset 同一口径）。
    private static var windowTopInset: CGFloat {
        let top = keyWindowSafeArea.top
        return top > 0 ? min(top, 59) : 47
    }

    /// r23i 顶栏再上移（只改顶栏 padding，不动图标与接线）：
    /// - 目标：竖屏返回圆钮顶边 39pt（圆钮 Ø48，视觉中心 63pt，对齐首页
    ///   图标中心线 63.2pt——07:09 首页图实测：齿轮顶 47.3pt、中心 63.2pt）。
    /// - 垫高实测：07:13 竖屏图（1206×2622 @3x）列扫描：圆钮顶边 px y=362
    ///   → 120.7pt，而当时 padding = windowTopInset = 59 → 容器上方还垫
    ///   了 120.7 − 59 = 61.7 ≈ 62pt（安全区被多扣了一层；r22a 文件底已记
    ///   geo.safeAreaInsets.top = 124 = 59 + 65，同一量级）。
    /// - 所以 padding 不再等于安全区，要按「目标顶边 − 垫高」给：
    ///   39 − 62 = −23（负 padding 把整列往上拉 82pt，省下的空间归弹性
    ///   歌词区，进度条仍贴底——与 r22a 同一机制）。
    private static let playerTopBarTargetTop: CGFloat = 39
    private static let topBarContainerOffset: CGFloat = 62
    private static var portraitTopPadding: CGFloat {
        playerTopBarTargetTop - topBarContainerOffset
    }

    /// r23i 横屏胶囊顶边目标 10pt（8–12pt 档中值，贴近屏顶留一线间距）。
    /// 横屏顶区原来没有顶部 padding（文件里唯一的 .padding(.top, 12) 是
    /// 底部进度条的）；07:15 横屏图实测胶囊灰区 y 0–60px（1206×555，
    /// 1.38px/pt）→ 顶边约 0pt——本次按任务书把目标值写成显式常量 10pt，
    /// 真机以 8–12pt 验收。歌词区是弹性段，吸收这 10pt（131.6 → 121.6，
    /// 仍 ≥ 最小高 100）。
    private static let landscapeTopPadding: CGFloat = 10

    /// 横屏左右安全区（灵动岛一侧 59，另一侧 0）。每侧夹到 ≤59；两侧都 >0
    /// 且相等时分不清岛在哪侧（124/124 被垫高的情况），用界面方向定：
    /// landscapeLeft 岛在左，landscapeRight 岛在右。
    private static var landscapeSideInsets: (leading: CGFloat, trailing: CGFloat) {
        let insets = keyWindowSafeArea
        let l = min(max(insets.left, 0), 59)
        let r = min(max(insets.right, 0), 59)
        if l > r { return (59, 0) }
        if r > l { return (0, 59) }
        if l > 0 { return islandSideFromOrientation() }
        return (0, 0)
    }

    /// 界面方向定岛侧：landscapeLeft（Home 键在右，机顶在左）→ 岛在左；
    /// landscapeRight → 岛在右；取不到方向时默认岛在左。
    private static func islandSideFromOrientation() -> (leading: CGFloat, trailing: CGFloat) {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .interfaceOrientation
        if orientation == .landscapeRight { return (0, 59) }
        return (59, 0)
    }

    // MARK: - 竖屏：壳版窄屏几何（封面 → 弹性歌词区 → 歌名 → 控制行 → 进度条）

    /// 竖屏布局：段顺序（r29 task 6：顶栏 → 封面流 → 歌名 → 歌词区 →
    /// 歌手 → 底部三排；歌名提到歌词区之上、歌手挪到歌词区之下，即原来
    /// titleBlock 的位置、原来药丸的位置）：
    /// - 每一行都给死宽度（内容宽 = 屏宽 − 2×16）：行的布局宽
    ///   由 frame 定，不由内容理想宽定——再长的单行歌名/副标题/歌词也只能在
    ///   行宽里截断，撑不大 VStack。
    /// - 外层 VStack 死宽高 + .topLeading：不居中、不下拉。
    /// - r27 v4：主控行 + 底部细进度条由 `PlayerBottomDock`（底部三排：
    ///   下载/喜欢/评论/音质 → 进度条+时间 → 模式/上一首/播放/下一首/队列）
    ///   替掉，只改默认版式；02/04/06 变体与横屏仍用旧控制行 + 细进度条。
    private func portraitLayout(geo: GeometryProxy, tier: PlayerTokens.PlayerSizeTier) -> some View {
        let contentWidth = geo.size.width - PlayerTokens.sp4 * 2
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar(tier: tier)
                    .frame(width: contentWidth)
                // r27：封面流不再随歌词展开收小（展开功能已删），固定全高。
                CoverFlowView(tier: tier)
                    .frame(width: contentWidth, height: PlayerTokens.coverTrackHeight(tier))
                    .clipped()
                    .padding(.top, 6)
                // r29 task 6：默认版式重排——歌名提到歌词区之上、歌手挪到
                // 歌词区之下（原来 titleBlock 的位置，原来药丸的位置）：
                // 顶栏 → 封面流 → 歌名 → 歌词区 → 歌手 → 底部三排。
                // titleBlock 本体不动（02/04/06 变体仍在调它），这里只拆
                // 它的两行：titleOnlyBlock（歌名，点按开队列）+ artistBlock
                // （歌手 + 试听/演示角标）。
                titleOnlyBlock(tier: tier)
                    .frame(width: contentWidth)
                lyricsZone(tier: tier, width: contentWidth)
                artistBlock(tier: tier)
                    .frame(width: contentWidth)
                // r27 v4 底部三排（见 PlayerBottomDock）：第 3 排下载/喜欢/
                // 评论/音质 → 第 2 排进度条+两端时间 → 最下面一排模式/
                // 上一首/播放/下一首/队列。进度条在 dock 里，不再单挂
                // 最底部细进度条；底部留 Home Indicator 安全区（有 34，无 0）。
                // r27 压缩：compact 档 dock 上间距 8 → 4（省 4pt，见文件底
                // r27 段落）；其余档 8 不动。dock 只在默认版式用，变体不动。
                PlayerBottomDock(tier: tier, width: contentWidth, onOpenQueue: { showQueue.toggle() })
                    .frame(width: contentWidth)
                    .padding(.top, tier == .compact ? 4 : 8)
            }
            .padding(.horizontal, PlayerTokens.sp4)
            // r23i：顶部不再走 windowTopInset（59）——07:13 竖屏图实测：
            // padding = 59 时圆钮顶边落在 120.7pt（列扫描 px y=362），容器
            // 上方还垫了约 62pt。改走 portraitTopPadding（39 − 62 = −23），
            // 顶边回 39、圆钮中心 63，对齐首页图标中心线；省下的 82pt 归
            // 弹性歌词区，进度条仍贴底。geo.safeAreaInsets 仍不用（会被垫高）。
            .padding(.top, Self.portraitTopPadding)
            .padding(.bottom, geo.safeAreaInsets.bottom)
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }

    // MARK: - r29 task 6：默认版式拆出来的歌名块 / 歌手块（只默认 portraitLayout 用）

    /// 歌名块（titleBlock 的歌名那行 1:1，不改字号/对齐/截断；点按开队列
    /// 的手势从 titleBlock 原样搬来）。上间距 8 = 旧「歌词区 → 歌名块 8」
    /// 段间距；歌名 → 歌词区 8 由 lyricsZone 自身的 .padding(.top, 8) 给，
    /// 不双倍。歌名行高 = titleSize × 1.25（35/40/45）。
    private func titleOnlyBlock(tier: PlayerTokens.PlayerSizeTier) -> some View {
        Text(store.currentTrack?.title ?? "未在播放")
            .font(.liziDisplay(size: PlayerTokens.titleSize(tier)))
            .foregroundStyle(PlayerTokens.playerForeground)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
            .contentShape(Rectangle())
            .onTapGesture { showQueue.toggle() }
            .accessibilityHint("点按打开播放队列")
    }

    /// 歌手块（titleBlock 的副标题 + 状态角标两行 1:1，字号/对齐/压缩逻辑
    /// 不动；放在 lyricsZone 之后、dock 之前，即原来 titleBlock 的位置）。
    /// 上间距 8（有状态行时 compact/large 收到 4，与旧 titleBlockTopPadding
    /// 同规则）；下间距 10（有状态行时 compact/large 收到 4，与旧
    /// titleBlockBottomPadding 同规则）。副标题行高 ≈ subtitleSize × 1.3
    /// （17/18/20），有状态行时再加角标行（试听/演示）。
    private func artistBlock(tier: PlayerTokens.PlayerSizeTier) -> some View {
        VStack(spacing: 2) {
            Text(subtitleText)
                .font(.system(size: PlayerTokens.subtitleSize(tier)))
                .foregroundStyle(PlayerTokens.playerSub)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
            statusCapsules(compactStyle: tier == .compact, largeStyle: tier == .large)
        }
        .padding(.top, artistBlockTopPadding(tier: tier))
        .padding(.bottom, artistBlockBottomPadding(tier: tier))
    }

    /// 歌手块上间距：与旧 titleBlockTopPadding 同规则——compact/large +
    /// 有状态行时 8 → 4，其余一律 8。
    private func artistBlockTopPadding(tier: PlayerTokens.PlayerSizeTier) -> CGFloat {
        ((tier == .compact || tier == .large) && hasStatusRow) ? 4 : 8
    }

    /// 歌手块下间距：与旧 titleBlockBottomPadding 同规则——compact/large +
    /// 有状态行时 10 → 4，其余一律 10。
    private func artistBlockBottomPadding(tier: PlayerTokens.PlayerSizeTier) -> CGFloat {
        ((tier == .compact || tier == .large) && hasStatusRow) ? 4 : 10
    }

    // MARK: - r25 #7：竖屏版式变体（02 / 04 / 06；默认走上面的 portraitLayout）

    /// 小封面行（02 用 68pt、06 用 96pt，壳版窄屏兜底 / 06 的 disc 尺寸）：
    /// 左边单张封面（当前曲目，无封面走 CoverImageView 白色占位），
    /// 右边歌名/歌手左对齐（复用横屏那套左对齐标题块；队列入口不在这里，
    /// 02/06 的控制行用三条杠开队列，见各变体）。
    private func smallCoverHeader(size: CGFloat, tier: PlayerTokens.PlayerSizeTier, width: CGFloat) -> some View {
        HStack(spacing: 12) {
            CoverImageView(url: store.currentTrack?.coverURL, placeholderIconSize: 24)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            landscapeTitleTexts(tier: tier)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width, alignment: .leading)
    }

    /// 02 竖屏（左右对半）：390pt 宽做不了 50/50 两列，按壳版 ≤900px
    /// 窄屏兜底做——顶部一行 68pt 小封面 + 歌名，控制行在歌名行之下、
    /// 歌词区之上，下方整幅歌词（歌词区是唯一弹性段）。控制行没并进顶行
    /// （缺口见文件头：PlayerControlRow 最小 207pt 宽，塞不进 68pt 高的顶行）。
    private func portraitLayout02(geo: GeometryProxy, tier: PlayerTokens.PlayerSizeTier) -> some View {
        let contentWidth = geo.size.width - PlayerTokens.sp4 * 2
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar(tier: tier)
                    .frame(width: contentWidth)
                smallCoverHeader(size: 68, tier: tier, width: contentWidth)
                    .padding(.top, 6)
                PlayerControlRow(tier: tier, showsQueueButton: true, onOpenQueue: { showQueue.toggle() })
                    .frame(width: contentWidth)
                    .padding(.top, 8)
                lyricsZone(tier: tier, width: contentWidth)
            }
            .padding(.horizontal, PlayerTokens.sp4)
            .padding(.top, Self.portraitTopPadding)
            PlayerProgressBar(tier: tier)
                .frame(width: geo.size.width)
                .padding(.top, 12)
                .padding(.bottom, geo.safeAreaInsets.bottom)
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }

    /// 04 竖屏（上下分屏）：上半 hero（封面流 → 歌名块 → 控制行），
    /// 下半整幅歌词（歌词区是唯一弹性段）。歌名块点按开队列与默认版式一致。
    private func portraitLayout04(geo: GeometryProxy, tier: PlayerTokens.PlayerSizeTier) -> some View {
        let contentWidth = geo.size.width - PlayerTokens.sp4 * 2
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar(tier: tier)
                    .frame(width: contentWidth)
                CoverFlowView(tier: tier)
                    .frame(width: contentWidth, height: PlayerTokens.coverTrackHeight(tier))
                    .clipped()
                    .padding(.top, 6)
                titleBlock(tier: tier)
                    .frame(width: contentWidth)
                PlayerControlRow(tier: tier)
                    .frame(width: contentWidth)
                lyricsZone(tier: tier, width: contentWidth)
            }
            .padding(.horizontal, PlayerTokens.sp4)
            .padding(.top, Self.portraitTopPadding)
            PlayerProgressBar(tier: tier)
                .frame(width: geo.size.width)
                .padding(.top, 12)
                .padding(.bottom, geo.safeAreaInsets.bottom)
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }

    /// 06 竖屏（极小封面）：顶部一行 96pt 小封面 + 歌名，歌词区弹性居中
    /// 占大面积，控制行在歌词区之下、进度条之上（壳版 06 控制浮底居中）。
    private func portraitLayout06(geo: GeometryProxy, tier: PlayerTokens.PlayerSizeTier) -> some View {
        let contentWidth = geo.size.width - PlayerTokens.sp4 * 2
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar(tier: tier)
                    .frame(width: contentWidth)
                smallCoverHeader(size: 96, tier: tier, width: contentWidth)
                    .padding(.top, 6)
                lyricsZone(tier: tier, width: contentWidth)
                PlayerControlRow(tier: tier, showsQueueButton: true, onOpenQueue: { showQueue.toggle() })
                    .frame(width: contentWidth)
                    .padding(.top, 8)
            }
            .padding(.horizontal, PlayerTokens.sp4)
            .padding(.top, Self.portraitTopPadding)
            PlayerProgressBar(tier: tier)
                .frame(width: geo.size.width)
                .padding(.top, 12)
                .padding(.bottom, geo.safeAreaInsets.bottom)
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }

    // MARK: - 横屏默认：顶行三圆钮 → 左列封面 + 标题 / 右列歌词 → 底部控制行 + 进度条

    /// 横屏默认布局（r29 task 7 重排，图纸 ~/workspace/lizi-landscape-diagram.png，
    /// r22 的「顶区一行 + 居中歌词」结构作废）：
    /// 1 顶行三钮都缩小：返回 / 搜索 / 舞台三个文字胶囊改 Ø38 小圆钮
    ///   （复用竖屏的 topBarCircleButton，图标因子同款 0.47；竖屏 Ø44，
    ///   横屏再小一档；只留图标不留文字，动作与 accessibilityLabel 不变）；
    /// 2 封面移到左边：左列 260 宽，CoverFlowView 不再放中间、也不再
    ///   scale 0.8 收小，中央张 148 × 1.04 ≈ 154pt 方形完整保留，
    ///   框高 162 只裁掉下面的倒影（见下高账）；标题 + 歌手放封面下面
    ///   （左列内，复用 landscapeTitleTexts），不再跟顶栏抢地方；
    /// 3 歌手在最下面（原杜比药丸位置）：无试听/演示/失败时角标行不渲染，
    ///   歌手就是左列最下面一行；实际音质角标 r29 task 4 已删
    ///   （statusCapsules 里无 actualQuality，见 verification/r29-task4.cjs）；
    /// 4 歌词放右边主区域：左列 260 + 间距 16 + 右列 539，两列布局；
    ///   右列是横屏专用的高对比歌词区 landscapeLyricsZone（不是竖屏共用的
    ///   lyricsZone / LyricsZoneView）：非当前行白 0.85（原 playerDim 0.52）、
    ///   不模糊、上一行实效 0.77（原 0.29），当前行红色 accent 不变；
    /// 5 控制行与进度条不动：PlayerControlRow（爱心|队列|上一首|播放|
    ///   下一首|循环，compact 58）与 PlayerProgressBar（触摸区 32 + 上间隙 12）
    ///   的位置与大小沿用旧值。
    /// 结构（纵向一段到底）：顶行三圆钮（38）→ 中段两列（左列定高 222、
    /// 右列歌词区弹性，最小高 100）→ 控制行 → 最底部细进度条
    /// （满 contentWidth，底部留 Home Indicator 安全区）。
    /// 高账（874×402）：顶 padding 10 + 顶行 38 + 中段上间隙 6 + 左列
    /// （封面框 162 + 间隙 6 + 标题块 54 = 222）+ 控制行 58（compact，
    /// playSize；旧账写的 60 是约数）+ 进度条上间隙 12 + 进度条 32
    /// + 底部安全区（0 或 21）= 399（安全区 21 时，余 3；安全区 0 时
    /// 378，余 24 归弹性歌词区）。右列歌词区实得：中段高 225（安全区
    /// 21）/ 246（安全区 0），减区顶 padding 8，内容 217 / 238，
    /// 均 ≥ 最小高 100。
    /// 宽度（r22a 根因，见文件底）：屏宽走 UIScreen.main.bounds.width（874），
    /// 两侧走 key window 安全区（landscapeSideInsets，岛侧 59、另一侧 0）；
    /// HStack = 左侧 spacer + 内容列 + 右侧 spacer，总宽恒 = 屏宽。
    /// 内容列内：顶行三圆钮（返回在左、搜索/舞台在右）；中段左列 260
    /// + 间距 16 + 右列 539 = 815；控制行 / 进度条满 815。
    /// 横屏分档按高取档：landscapeTier = 按高 402 取档 → standard；
    /// 封面 / 歌名 / 控制行再降一档用 compact，才塞得进 402 高。
    /// 残留（r29 task 7 如实记）：试听/演示/取链失败时状态行多约 20–22pt，
    /// 左列 222 → 约 244，底部安全区 21 时整列超约 19pt，进度条视觉细条
    /// 会被顶出屏底（触摸区仍有约 13pt 在屏内，控制行完整可见）；安全区 0
    /// 时不超（398 ≤ 402）。修法要么裁封面方形本身、要么横屏左列去掉
    /// 状态行（会丢取链失败点红字弹登录的入口），两害相权留了现状，
    /// 不在此轮硬塞。
    private func landscapeLayout(geo: GeometryProxy, tier: PlayerTokens.PlayerSizeTier) -> some View {
        let landscapeTier = PlayerTokens.sizeTier(
            for: CGSize(width: geo.size.height, height: geo.size.width),
            topInset: geo.safeAreaInsets.top)
        let compactTier = PlayerTokens.PlayerSizeTier.compact
        let lyricsMinHeight: CGFloat = 100
        // r22a：横屏宽度唯一口径。屏宽 + key window 两侧安全区（见文件底注释）；
        // 顶行 / 中段两列 / 控制行 / 进度条四行全用 contentWidth；HStack 三段
        // （左 spacer + 内容列 + 右 spacer）总宽恒 = 屏宽，行宽 = 容器宽，居中偏归零。
        let screenWidth = UIScreen.main.bounds.width
        let screenHeight = UIScreen.main.bounds.height
        let (leadingInset, trailingInset) = Self.landscapeSideInsets
        let contentWidth = screenWidth - leadingInset - trailingInset
        let lyricsColumnWidth = contentWidth - Self.landscapeLeftColumnWidth - Self.landscapeColumnSpacing
        return HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset)
            VStack(spacing: 0) {
                // 顶行：只剩三个小圆钮（返回在左、搜索 / 舞台在右；r29 task 7：
                // 文字胶囊改 Ø38 圆钮，只留图标不留文字，动作与竖屏圆钮一一对应）。
                HStack {
                    topBarCircleButton(
                        systemName: "chevron.left",
                        diameter: Self.landscapeTopBarButtonDiameter
                    ) {
                        navigation.show(.home)
                    }
                    .accessibilityLabel("返回首页")
                    Spacer()
                    HStack(spacing: 12) {
                        topBarCircleButton(
                            systemName: "magnifyingglass",
                            diameter: Self.landscapeTopBarButtonDiameter
                        ) {
                            // 搜索页走 App 现有的搜索导航路由，不新造。
                            navigation.show(.search)
                        }
                        .accessibilityLabel("搜索")
                        topBarCircleButton(
                            systemName: "gearshape",
                            diameter: Self.landscapeTopBarButtonDiameter
                        ) {
                            // 齿轮就是舞台控制按钮（点进舞台页），不进设置页、
                            // 不在播放页弹调节面板。
                            navigation.show(.stage())
                        }
                        .accessibilityLabel("控制舞台")
                    }
                }
                .frame(width: contentWidth)
                // 中段两列（左列封面 + 标题 / 右列歌词），弹性段：左列定高，
                // 右列歌词区吃掉剩余高度（底部安全区 0 时多出的 21pt 也归它）。
                HStack(alignment: .top, spacing: Self.landscapeColumnSpacing) {
                    VStack(spacing: 0) {
                        // 左列封面：CoverFlowView 不再放中间、改到左列，不再
                        // scale 0.8 收小；中央张 148 × 1.04 ≈ 154pt 方形完整
                        // 保留，框高 162 只裁掉下面的倒影（402 高装不下
                        // 198 轨道 + 标题块；框顶对齐，封面顶边不被裁）。
                        // 宽取左列满宽：两侧封面在列宽里露一半，仍是封面流。
                        CoverFlowView(tier: landscapeTier, isCompact: true)
                            .frame(width: Self.landscapeLeftColumnWidth, height: Self.landscapeCoverFrameHeight, alignment: .top)
                            .clipped()
                        // 标题 + 歌手放封面下面（左列内），复用
                        // landscapeTitleTexts（左对齐；02/04 变体同一函数，
                        // 不新建 statusCapsules 调用点——r29-task4 驱动断言
                        // 该函数恰好 3 处调用）。无试听/演示/失败时角标行
                        // 不渲染，歌手就是左列最下面一行（原杜比药丸位置；
                        // 实际音质角标 r29 task 4 已删，见 statusCapsules）。
                        landscapeTitleTexts(tier: compactTier)
                            .frame(width: Self.landscapeLeftColumnWidth)
                            .padding(.top, 6)
                    }
                    .frame(width: Self.landscapeLeftColumnWidth, alignment: .topLeading)
                    // 右列歌词：高对比专用区（见 landscapeLyricsZone），
                    // 不是竖屏共用的 lyricsZone；队列面板仍只盖住本区。
                    landscapeLyricsZone(tier: landscapeTier, width: lyricsColumnWidth, minHeight: lyricsMinHeight)
                }
                .frame(width: contentWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 6)
                // 控制行与进度条：r29 task 7 一字不动（位置与大小都沿用旧值）。
                PlayerControlRow(tier: compactTier, showsQueueButton: true, onOpenQueue: { showQueue.toggle() })
                    .frame(width: contentWidth)
                PlayerProgressBar(tier: tier)
                    .frame(width: contentWidth)
                    .padding(.top, 12)
                    .padding(.bottom, geo.safeAreaInsets.bottom)
            }
            // r23i：横屏顶区加显式顶部 padding（目标顶边 10pt，见
            // landscapeTopPadding；歌词区弹性段吸收这 10pt，仍 ≥ 最小高 100）。
            .padding(.top, Self.landscapeTopPadding)
            .frame(width: contentWidth, height: screenHeight, alignment: .topLeading)
            Color.clear.frame(width: trailingInset)
        }
        .frame(width: screenWidth, height: screenHeight, alignment: .topLeading)
    }

    // MARK: - r25 #7：横屏版式变体（02 / 04 / 06；默认走上面的 landscapeLayout）

    /// 横屏版式变体共用的顶行胶囊（返回 / 搜索 / 控制舞台，与默认横屏顶行
    /// 的三个圆钮同一套动作；r29 task 7 起默认横屏顶行是 Ø38 圆钮，歌名与
    /// 封面流改到下面的左列，变体里顶行只剩这三个胶囊，歌名/封面另排）。
    private func landscapeCapsuleRow(compactTier: PlayerTokens.PlayerSizeTier) -> some View {
        HStack(spacing: 12) {
            topBarCapsuleButton(
                systemName: "chevron.left",
                text: "返回",
                height: PlayerTokens.topBarButton(compactTier),
                iconSize: 18
            ) {
                navigation.show(.home)
            }
            .accessibilityLabel("返回首页")
            Spacer()
            topBarCapsuleButton(
                systemName: "magnifyingglass",
                text: "搜索",
                height: PlayerTokens.topBarButton(compactTier),
                iconSize: 16
            ) {
                navigation.show(.search)
            }
            .accessibilityLabel("搜索")
            topBarCapsuleButton(
                systemName: "gearshape",
                text: "控制",
                height: PlayerTokens.topBarButton(compactTier),
                iconSize: 18
            ) {
                navigation.show(.stage())
            }
            .accessibilityLabel("控制舞台")
        }
    }

    /// 02 横屏（左右对半）：左列封面流（收小档 ×0.8）+ 歌名 + 控制行，
    /// 右列整幅歌词；两列 50/50 通高（壳版桌面 02 原样）。进度条满宽在底。
    private func landscapeLayout02(geo: GeometryProxy, tier: PlayerTokens.PlayerSizeTier) -> some View {
        let landscapeTier = PlayerTokens.sizeTier(
            for: CGSize(width: geo.size.height, height: geo.size.width),
            topInset: geo.safeAreaInsets.top)
        let compactTier = PlayerTokens.PlayerSizeTier.compact
        let coverScale: CGFloat = 0.8
        let coverTrack = PlayerTokens.coverTrackHeight(landscapeTier) * 198 / 254 * coverScale
        let screenWidth = UIScreen.main.bounds.width
        let screenHeight = UIScreen.main.bounds.height
        let (leadingInset, trailingInset) = Self.landscapeSideInsets
        let contentWidth = screenWidth - leadingInset - trailingInset
        let columnWidth = (contentWidth - 16) / 2
        return HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset)
            VStack(spacing: 0) {
                landscapeCapsuleRow(compactTier: compactTier)
                    .frame(width: contentWidth)
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        CoverFlowView(tier: landscapeTier, isCompact: true)
                            .scaleEffect(coverScale, anchor: .top)
                            .frame(maxWidth: .infinity)
                            .frame(height: coverTrack)
                            .clipped()
                        landscapeTitleTexts(tier: compactTier)
                        PlayerControlRow(tier: compactTier, showsQueueButton: true, onOpenQueue: { showQueue.toggle() })
                    }
                    .frame(width: columnWidth, alignment: .topLeading)
                    lyricsZone(tier: landscapeTier, width: columnWidth, minHeight: 100)
                }
                .frame(width: contentWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                PlayerProgressBar(tier: tier)
                    .frame(width: contentWidth)
                    .padding(.top, 12)
                    .padding(.bottom, geo.safeAreaInsets.bottom)
            }
            .padding(.top, Self.landscapeTopPadding)
            .frame(width: contentWidth, height: screenHeight, alignment: .topLeading)
            Color.clear.frame(width: trailingInset)
        }
        .frame(width: screenWidth, height: screenHeight, alignment: .topLeading)
    }

    /// 04 横屏（上下分屏）：上半 hero 行（封面流收小档 + 右边歌名/控制上下叠），
    /// 下半整幅歌词（弹性段）。进度条满宽在底。
    private func landscapeLayout04(geo: GeometryProxy, tier: PlayerTokens.PlayerSizeTier) -> some View {
        let landscapeTier = PlayerTokens.sizeTier(
            for: CGSize(width: geo.size.height, height: geo.size.width),
            topInset: geo.safeAreaInsets.top)
        let compactTier = PlayerTokens.PlayerSizeTier.compact
        let coverScale: CGFloat = 0.8
        let coverTrack = PlayerTokens.coverTrackHeight(landscapeTier) * 198 / 254 * coverScale
        let screenWidth = UIScreen.main.bounds.width
        let screenHeight = UIScreen.main.bounds.height
        let (leadingInset, trailingInset) = Self.landscapeSideInsets
        let contentWidth = screenWidth - leadingInset - trailingInset
        return HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset)
            VStack(spacing: 0) {
                landscapeCapsuleRow(compactTier: compactTier)
                    .frame(width: contentWidth)
                HStack(alignment: .center, spacing: 16) {
                    CoverFlowView(tier: landscapeTier, isCompact: true)
                        .scaleEffect(coverScale, anchor: .top)
                        .frame(width: 280)
                        .frame(height: coverTrack)
                        .clipped()
                    VStack(alignment: .leading, spacing: 8) {
                        landscapeTitleTexts(tier: compactTier)
                        PlayerControlRow(tier: compactTier, showsQueueButton: true, onOpenQueue: { showQueue.toggle() })
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: contentWidth)
                .padding(.top, 8)
                lyricsZone(tier: landscapeTier, width: contentWidth, minHeight: 100)
                PlayerProgressBar(tier: tier)
                    .frame(width: contentWidth)
                    .padding(.top, 12)
                    .padding(.bottom, geo.safeAreaInsets.bottom)
            }
            .padding(.top, Self.landscapeTopPadding)
            .frame(width: contentWidth, height: screenHeight, alignment: .topLeading)
            Color.clear.frame(width: trailingInset)
        }
        .frame(width: screenWidth, height: screenHeight, alignment: .topLeading)
    }

    /// 06 横屏（极小封面）：顶部一行 96pt 小封面 + 歌名，歌词区弹性占大面积，
    /// 控制行在歌词区之下、进度条之上。
    private func landscapeLayout06(geo: GeometryProxy, tier: PlayerTokens.PlayerSizeTier) -> some View {
        let landscapeTier = PlayerTokens.sizeTier(
            for: CGSize(width: geo.size.height, height: geo.size.width),
            topInset: geo.safeAreaInsets.top)
        let compactTier = PlayerTokens.PlayerSizeTier.compact
        let screenWidth = UIScreen.main.bounds.width
        let screenHeight = UIScreen.main.bounds.height
        let (leadingInset, trailingInset) = Self.landscapeSideInsets
        let contentWidth = screenWidth - leadingInset - trailingInset
        return HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset)
            VStack(spacing: 0) {
                landscapeCapsuleRow(compactTier: compactTier)
                    .frame(width: contentWidth)
                smallCoverHeader(size: 96, tier: compactTier, width: contentWidth)
                    .padding(.top, 8)
                lyricsZone(tier: landscapeTier, width: contentWidth, minHeight: 100)
                PlayerControlRow(tier: compactTier, showsQueueButton: true, onOpenQueue: { showQueue.toggle() })
                    .frame(width: contentWidth)
                    .padding(.top, 8)
                PlayerProgressBar(tier: tier)
                    .frame(width: contentWidth)
                    .padding(.top, 12)
                    .padding(.bottom, geo.safeAreaInsets.bottom)
            }
            .padding(.top, Self.landscapeTopPadding)
            .frame(width: contentWidth, height: screenHeight, alignment: .topLeading)
            Color.clear.frame(width: trailingInset)
        }
        .frame(width: screenWidth, height: screenHeight, alignment: .topLeading)
    }

    // MARK: - 背景：模糊封面大图（blur 64px）+ 暗角；无封面用默认深色渐变

    private var background: some View {
        ZStack {
            if let url = store.currentTrack?.coverURL {
                CoverImageView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 64)
                    .scaleEffect(1.25)
            } else {
                LinearGradient(
                    colors: [PlayerTokens.ink, Color.black],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            // 压暗 + 暗角，保证白字可读（壳版 .now__bg 那层暗场）。
            // r20 按截图再压暗一点：底色 0.45 → 0.52，下沿 0.55 → 0.62。
            Color.black.opacity(0.52)
            LinearGradient(
                colors: [
                    Color.black.opacity(0.40),
                    Color.clear,
                    Color.clear,
                    Color.black.opacity(0.62),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.42), value: store.currentTrack?.id)
    }

    // MARK: - 顶栏：左圆形毛玻璃返回（只有 ⌄，无「返回」文字；r27 追加 v4
    // 已批，返回是向下 chevron）；右两个同样
    // 圆形毛玻璃按钮（搜索 + 齿轮）。顶栏纠正（05:30 用户标注截图为准，
    // r22a 的九宫格做法作废）：搜索 magnifyingglass 回到播放页顶栏，点开
    // 搜索页（走 App 里现有的搜索导航路由 navigation.show(.search)，不新造）；
    // 齿轮 gearshape 是「控制舞台」按钮，点进舞台页（走 AppNavigation .stage()，
    // 不带 formId，读用户保存的形态）；进了舞台页，舞台页自己的齿轮再调当前
    // 舞台效果。齿轮绝不进 App 设置页（设置页只从首页齿轮进），也不在播放页
    // 直接弹舞台调节面板（StageSettingsView 只在 StageView 里调）。
    // 九宫格 square.grid.2x2（选舞台）只在舞台页里，不在播放页顶栏。
    // 左返回 chevron.down（r27 追加 v4 已批）。竖屏顶栏正好 3 个圆形图标，不多加；
    // 横屏顶栏同源不同形：02/04/06 变体顶行调 topBarCapsuleButton
    // （文字胶囊：返回 / 搜索 / 控制），动作与竖屏圆按钮一一对应；
    // 默认横屏 r29 task 7 起改调 topBarCircleButton（Ø38 小圆钮，
    // 见 landscapeLayout）。顶栏位置见文件底
    // 「r22a 顶栏太靠下根因」：顶边走 key window 安全区真实值（59），
    // 紧贴状态栏下方，灵动岛同一行高度之下、只留一点点间距。
    //
    // r27 竖屏三钮 1:1（只改竖屏，横屏胶囊不动；不拿 App 现有的按钮尺寸）：
    // 参考图 3C9A94A6…（1206×2622 @3x，屏 402pt），PIL 实测（阈值 80/110
    // 两档行扫描 + 白字 bbox，见交回）：
    // - 三圆直径：左圆行 y=180/190 扫描 x 48–191、搜索圆 x 834–977、
    //   齿轮圆 x 1014–1157，弦拟合 Ø≈145–146px → 48.3–48.7pt，
    //   统一取整 49pt（r27 实测值；r29 task 5 改小一档 → 44pt，见下面常量，
    //   三档同一值，不再走 PlayerTokens.topBarButton 的 44/48/52；
    //   横屏胶囊仍走它，一字不动）。
    // - 圆心：左 (119.5, 186)px = (39.8, 62.0)pt；搜索 (905.5, 186)px
    //   = (301.8, 62.0)pt；齿轮 (1085.5, 186)px = (361.8, 62.0)pt。
    //   左缘 47px = 15.7pt、右缘 1158px = 386pt（离屏边 16pt），与内容宽
    //   （屏宽 − 2×16）左右各 16pt 的 HStack 自然对上，不另调边距；
    //   搜索→齿轮圆心距 180px = 60pt，减直径 48.5 → 圆间距 11.5pt，
    //   代码 HStack spacing 12 已对上，保留。
    // - 圆心 y 62pt：顶边目标 39pt + 半径 24.5 = 中心 63.5pt，实测 62pt，
    //   差 1.5pt，playerTopBarTargetTop = 39 不动。
    // - 图标（白字 bbox，阈值 >205）：左 "<" x100–130 × y163–215
    //   = 31×53px = 10.3×17.7pt；搜索放大镜 59×59px = 19.7pt；
    //   齿轮 65×65px = 21.7pt。图标字号因子 0.42 → 0.47（r27 Ø49 时 23pt；
    //   SF 图标字形高约 0.8–0.95em，正好落在实测 17.7–21.7pt 区间）。
    //   r29 task 5：直径 44pt 后图标字号 = 44 × 0.47 = 20.7pt，字形高约
    //   16.6–19.7pt（按原比例跟着缩，不只缩外框）；圆心 = 39 + 22 = 61pt，
    //   顶边 39 不动。
    // - 注意（r27 追加，v4 合成图已批）：任务二原图的左图标实测是向左
    //   尖角 "<"（31×53px），但用户批的 v4 合成图（build-player-v4-composite.py）
    //   把返回画成了向下 chevron ⌄（折线 [97,169]→[122,195]→[147,169]，
    //   线宽 7px，即 50×26px = 16.7×8.7pt），以 v4 为准：返回图标用
    //   chevron.down。任务书给的 Ø136px / 搜索圆心 960px 与实测（Ø≈146px /
    //   905.5px）不符，仍按实测落数（见上）。

    /// r29 task 5：竖屏顶栏三钮统一直径 44pt（r27 实测 49pt，改小一档；
    /// 见上面 topBar 注释；三档同一值，不走 PlayerTokens.topBarButton）。
    private static let portraitTopBarButtonDiameter: CGFloat = 44

    /// r29 task 7：横屏默认顶栏三钮直径 38pt（竖屏 44pt，再小一档；
    /// 胶囊旧高 compact 44 → 圆钮 38；图标字号 = 38 × 0.47 ≈ 17.9pt，
    /// 复用 topBarCircleButton，与竖屏同一套做法）。
    private static let landscapeTopBarButtonDiameter: CGFloat = 38

    /// r29 task 7：横屏默认左列宽 260pt（封面中央张 154 + 两侧封面各露约 50；
    /// 内容宽 815 − 260 − 间距 16 = 右列歌词 539）。
    private static let landscapeLeftColumnWidth: CGFloat = 260

    /// r29 task 7：横屏默认两列间距 16pt。
    private static let landscapeColumnSpacing: CGFloat = 16

    /// r29 task 7：横屏默认左列封面框高 162pt。CoverFlowView 轨道本身
    /// 198（中央张 148 × 1.04 ≈ 154 + 间距 8 + 倒影约 46）；框高 162
    /// = 方形 154 + 间距 8（+ 0.1pt 余量），方形完整保留、只裁倒影；
    /// 框顶对齐（.frame alignment: .top），封面顶边不被裁（r28 的顶裁
    /// 教训：框高小于内容高时必须顶对齐，默认居中会连顶边一起裁）。
    private static let landscapeCoverFrameHeight: CGFloat = 162

    private func topBar(tier: PlayerTokens.PlayerSizeTier) -> some View {
        _ = tier // r29 task 5：竖屏三钮直径固定 44pt（r27 实测 49pt，改小一档），不再按 tier 分档。
        return HStack {
            topBarCircleButton(
                systemName: "chevron.down",
                diameter: Self.portraitTopBarButtonDiameter
            ) {
                navigation.show(.home)
            }
            .accessibilityLabel("返回首页")

            Spacer()

            HStack(spacing: 12) {
                topBarCircleButton(
                    systemName: "magnifyingglass",
                    diameter: Self.portraitTopBarButtonDiameter
                ) {
                    // 搜索页走 App 现有的搜索导航路由，不新造。
                    navigation.show(.search)
                }
                .accessibilityLabel("搜索")

                topBarCircleButton(
                    systemName: "gearshape",
                    diameter: Self.portraitTopBarButtonDiameter
                ) {
                    // 控制舞台：进舞台页（.stage()，读保存的形态）；不进设置页，
                    // 不在播放页弹调节面板——面板只在舞台页里由它自己的齿轮开。
                    navigation.show(.stage())
                }
                .accessibilityLabel("控制舞台")
            }
        }
    }

    /// 顶栏圆形毛玻璃按钮：`.ultraThinMaterial` 圆形，直径 r29 task 5 起
    /// 固定 44pt（r27 实测 49pt，改小一档，见 topBar 注释）；图标字号 =
    /// 直径 × 0.47（Ø44 时 20.7pt；r27 Ø49 时 23pt，实测图标 17.7–21.7pt，
    /// 旧 0.42 偏小；SF 图标字形高约 0.8–0.95em）。
    private func topBarCircleButton(
        systemName: String,
        diameter: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.47, weight: .semibold))
                .foregroundStyle(PlayerTokens.playerForeground)
                .frame(width: diameter, height: diameter)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        }
    }

    /// 横屏顶栏文字胶囊按钮（r22 横屏重排）：`.ultraThinMaterial` 胶囊，
    /// 图标 + 文字，高走调用方传的 `PlayerTokens.topBarButton(tier)`
    /// （compact 44，与竖屏圆按钮同高）。动作与竖屏圆按钮一一对应
    /// （返回 / 搜索 / 控制舞台），只是横屏画成文字胶囊。
    /// r28：图标字号按壳版顶栏图标数 1:1，不再与文字同 17pt——
    /// 设置/控制 18px（app.css `.tbtn--icon .ico` 18px）、搜索 16px
    /// （app.css `.search .ico` 16px）、返回 18px（同 .tbtn--icon 通用
    /// 顶栏图标按钮）；文字仍 17pt 不动。图标字号由调用方按按钮传
    /// `iconSize`（三个胶囊共 3 处调用，只剩 landscapeCapsuleRow，
    /// 02/04/06 变体共用；默认横屏 r29 task 7 起改圆钮，不再调它）。
    private func topBarCapsuleButton(
        systemName: String,
        text: String,
        height: CGFloat,
        iconSize: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: iconSize, weight: .semibold))
                Text(text)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(PlayerTokens.playerForeground)
            .padding(.horizontal, 16)
            .frame(height: height)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        }
    }

    // MARK: - 歌词区（工人 B 的 LyricsZoneView）+ 队列面板覆盖层

    /// 歌词区是纵向唯一弹性段：最小高默认走 `lyricsZoneHeight(tier)`，剩下的空间
    /// 全归它（工人 C 总账里的余量就由它消化）。队列面板打开时只盖住这一段：
    /// 控制行和最底部细进度条在歌词区之外，面板再大也遮不到它们（不依赖
    /// 工人 C 的控制行高度）。
    /// 横屏重排（r22）才传 `minHeight`：横屏总高只有 402，顶区 + 控制行 +
    /// 进度条占去约 271，标准档最小高 180 会把进度条顶出屏；传 100（3 行歌词
    /// 约 70–80），实得 111–132，见 landscapeLayout 高账。
    private func lyricsZone(tier: PlayerTokens.PlayerSizeTier, width: CGFloat, minHeight: CGFloat? = nil) -> some View {
        ZStack {
            // tier 直传，不走 LyricsZoneView 的 UIScreen 自算：竖屏自算与调用方
            // 同档，横屏必须按高取档（landscapeTier），自算会按宽 874 错取 large。
            LyricsZoneView(tier: tier)
            if showQueue {
                QueuePanelView(onClose: { showQueue = false })
            }
        }
        // SwiftUI 没有 frame(width:minHeight:maxHeight:) 这一重载，
        // 用 minWidth/maxWidth 夹住宽度，语义与固定宽相同。
        .frame(
            minWidth: width,
            maxWidth: width,
            minHeight: minHeight ?? PlayerTokens.lyricsZoneHeight(tier),
            maxHeight: .infinity
        )
        .padding(.top, 8)
    }

    // MARK: - r29 task 7：横屏默认高对比歌词区（只给 landscapeLayout 用）

    /// 横屏默认歌词区：与竖屏共用的 lyricsZone / LyricsZoneView 同款行为
    /// （当前行贴底、自动跟随滚动、点行跳转、无歌词空态、队列面板只盖住
    /// 本区），只改对比度——且只改横屏这一路，LyricsPanelView.swift
    /// 一字不动（任务约束只改 PlayerView.swift），所以本区自带一份
    /// 横屏专用渲染（下面 landscapeLyricsContent / Row / Text），不复用
    /// LyricsZoneView。
    /// 改前（LyricsZoneRowView）：非当前行前景 playerDim = 白 0.52，
    /// 再 × 行透明度（上一行 0.55、之后 ×0.65：0.36 / 0.23 / 0.15…），
    /// 上一行实效 0.52 × 0.55 ≈ 0.29，还要再模糊 0.6 / 1.8 / 3.0…。
    /// 改后（本区）：非当前行前景白 0.85 × 行透明度 0.9 / 0.75 / 0.6 / 0.5，
    /// 上一行实效 0.85 × 0.9 ≈ 0.77；不模糊；行左对齐（图里歌词左对齐，
    /// 竖屏歌词居中不动）；不罩顶部渐隐遮罩（原 topFadeMask 会把上面几行
    /// 再压暗一截）。当前行红色 accent + semibold 不变；逐字未唱到的字
    /// 白 0.85（原 playerDim 0.52）；翻译行白 0.8（原 playerTranslation 0.58）。
    private func landscapeLyricsZone(tier: PlayerTokens.PlayerSizeTier, width: CGFloat, minHeight: CGFloat) -> some View {
        ZStack {
            GeometryReader { geo in
                landscapeLyricsContent(zoneWidth: geo.size.width, zoneHeight: geo.size.height, tier: tier)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showQueue {
                QueuePanelView(onClose: { showQueue = false })
            }
        }
        // SwiftUI 没有 frame(width:minHeight:maxHeight:) 这一重载，
        // 用 minWidth/maxWidth 夹住宽度，语义与固定宽相同（同 lyricsZone）。
        .frame(
            minWidth: width,
            maxWidth: width,
            minHeight: minHeight,
            maxHeight: .infinity
        )
        .padding(.top, 8)
    }

    /// 有效当前行（与 LyricsZoneView.effectiveCurrent 同款）：还没开唱
    /// （-1）时从第一行起；越界时夹到末行。
    private var landscapeEffectiveCurrent: Int {
        guard !store.lyrics.isEmpty else { return 0 }
        if store.currentLyricIndex < 0 { return 0 }
        return min(store.currentLyricIndex, store.lyrics.count - 1)
    }

    /// 折叠态渲染的行：从第一行到当前行（只往上、不往下看，当前行贴底）。
    private var landscapeVisibleIndices: [Int] {
        guard !store.lyrics.isEmpty else { return [] }
        return Array(0...landscapeEffectiveCurrent)
    }

    @ViewBuilder
    private func landscapeLyricsContent(zoneWidth: CGFloat, zoneHeight: CGFloat, tier: PlayerTokens.PlayerSizeTier) -> some View {
        if store.lyrics.isEmpty {
            Text("这首歌没有歌词")
                .font(.system(size: PlayerTokens.textMd))
                .foregroundStyle(PlayerTokens.playerDim)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(landscapeVisibleIndices, id: \.self) { index in
                            let line = store.lyrics[index]
                            landscapeLyricsRow(line: line, distance: landscapeEffectiveCurrent - index, tier: tier)
                                .id(index)
                                // 行点按只跳转（点行是跳转，见行上的高优先级手势）。
                                .highPriorityGesture(
                                    TapGesture().onEnded {
                                        store.seek(to: TimeInterval(line.startMs) / 1000)
                                    }
                                )
                        }
                    }
                    // 内容不足一屏时也撑满区高、底对齐：当前行永远贴底、完整可见。
                    // 显式给区宽——ScrollView 内容的布局宽由它定，不由最长
                    // 单行歌词的理想宽定（同 LyricsZoneView 的 r21b 修法）。
                    .frame(minWidth: zoneWidth, maxWidth: zoneWidth, minHeight: zoneHeight, alignment: .bottom)
                }
                // 禁手动滚动：自动跟随独占滚动，手指只点行跳转；点歌词区
                // 空白处什么都不做。
                .scrollDisabled(true)
                .onAppear { scrollToLandscapeCurrent(proxy: proxy, animated: false) }
                .onChange(of: store.currentLyricIndex) { _ in
                    scrollToLandscapeCurrent(proxy: proxy, animated: true)
                }
                .onChange(of: store.lyrics) { _ in
                    scrollToLandscapeCurrent(proxy: proxy, animated: false)
                }
            }
        }
    }

    /// 滚到当前行，锚点 .bottom：当前行底边贴住歌词区底边（同 LyricsZoneView）。
    private func scrollToLandscapeCurrent(proxy: ScrollViewProxy, animated: Bool) {
        guard !store.lyrics.isEmpty, store.lyrics.indices.contains(landscapeEffectiveCurrent) else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(landscapeEffectiveCurrent, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(landscapeEffectiveCurrent, anchor: .bottom)
        }
    }

    /// 横屏默认歌词行（高对比，见 landscapeLyricsZone）：当前行大 + 红色，
    /// 往上按距离逐行变淡（0.9 / 0.75 / 0.6 / 0.5），不模糊；
    /// 翻译行 12px 白 0.8，另起一行，跟在对应行下方，与正文共用同一透明度。
    private func landscapeLyricsRow(line: LyricLine, distance: Int, tier: PlayerTokens.PlayerSizeTier) -> some View {
        let isCurrent = distance == 0
        let rowOpacity: Double
        if isCurrent {
            rowOpacity = 1
        } else {
            switch distance {
            case 1: rowOpacity = 0.9
            case 2: rowOpacity = 0.75
            case 3: rowOpacity = 0.6
            default: rowOpacity = 0.5
            }
        }
        return VStack(alignment: .leading, spacing: 2) {
            landscapeLyricText(line: line, isCurrent: isCurrent, tier: tier)
            if !line.translation.isEmpty {
                Text(line.translation)
                    .font(.system(size: PlayerTokens.textXs))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .opacity(rowOpacity)
        .accessibilityLabel("歌词：\(line.text)，点按跳转到该句")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func landscapeLyricText(line: LyricLine, isCurrent: Bool, tier: PlayerTokens.PlayerSizeTier) -> some View {
        if isCurrent, !line.words.isEmpty {
            // 当前行 + 有逐字数据：逐字上色（唱到的字 accent + 600 字重，
            // 未唱到的字白 0.85；原 LyricsZoneRowView 未唱到的是 playerDim 0.52）。
            landscapeWordByWordText(line: line)
                .font(.system(size: PlayerTokens.lyricsCurrentSize(tier)))
                .lineLimit(1)
        } else if isCurrent {
            Text(line.text)
                .font(.system(size: PlayerTokens.lyricsCurrentSize(tier), weight: .semibold))
                .foregroundStyle(PlayerTokens.accent)
                .lineLimit(1)
        } else {
            Text(line.text)
                .font(.system(size: PlayerTokens.lyricsOtherSize(tier)))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
        }
    }

    private func landscapeWordByWordText(line: LyricLine) -> Text {
        let nowMs = Int(store.progress * 1000)
        return line.words.reduce(Text("")) { partial, word in
            let sung = word.startMs <= nowMs
            let piece = Text(word.text)
                .foregroundColor(sung ? PlayerTokens.accent : Color.white.opacity(0.85))
                .fontWeight(sung ? .semibold : .regular)
            return partial + piece
        }
    }

    // MARK: - 歌名 / 歌手 + 状态角标 / 播放失败原因

    private func titleBlock(tier: PlayerTokens.PlayerSizeTier) -> some View {
        titleTexts(tier: tier)
        // 段间距与工人 C 总账对齐：歌词区 → 歌名块 8，歌名块 → 控制行 10。
        // r26：compact 档有状态行（角标/失败原因）时收紧到 4/4（见下
        // titleBlockTopPadding/titleBlockBottomPadding 与文件底 r26 总账），
        // 与角标行压缩合计省约 15pt；无角标态仍是 8/10，一字不动；其余档不动。
        .padding(.top, titleBlockTopPadding(tier: tier))
        .padding(.bottom, titleBlockBottomPadding(tier: tier))
        // r22k：点歌名块打开队列（控制行按审计图改成星标/上一首/播放/
        // 下一首/AirPlay 后，队列列表按钮没位置了；队列入口改到这里，
        // 面板仍只盖住歌词区，见 lyricsZone）。
        .contentShape(Rectangle())
        .onTapGesture { showQueue.toggle() }
        .accessibilityHint("点按打开播放队列")
    }

    /// 状态行是否真的占高（r26）：失败原因文案，或至少一个角标（试听 /
    /// 演示音）时为真。只按可见内容判定——有曲目但两个角标条件全不
    /// 成立时角标行整行不渲染，不计入（r29：实际音质角标已删，见
    /// statusCapsules；该瞬态仍走旧 8/10 间距，不溢出，见文件底
    /// r26 总账注）。
    private var hasStatusRow: Bool {
        if store.errorMessage != nil { return true }
        guard store.currentTrack != nil else { return false }
        return store.currentTrack?.isTrial == true
            || store.isDemo
    }

    /// r26：titleBlock 上间距。compact + 有状态行时 8 → 4（省 4pt）；
    /// 其余情况一律 8（无角标态、各档、横屏不用 titleBlock，均不动）。
    /// r27：large + 有状态行时同样 8 → 4（省 4pt，large 角标溢出修复，
    /// 见文件底 r27 段落；standard 不动）。
    private func titleBlockTopPadding(tier: PlayerTokens.PlayerSizeTier) -> CGFloat {
        ((tier == .compact || tier == .large) && hasStatusRow) ? 4 : 8
    }

    /// r26：titleBlock 下间距。compact + 有状态行时 10 → 4（省 6pt）；
    /// 其余情况一律 10。
    /// r27：large + 有状态行时同样 10 → 4（省 6pt，large 角标溢出修复，
    /// 见文件底 r27 段落；standard 不动）。
    private func titleBlockBottomPadding(tier: PlayerTokens.PlayerSizeTier) -> CGFloat {
        ((tier == .compact || tier == .large) && hasStatusRow) ? 4 : 10
    }

    /// 歌名 / 歌手 + 状态角标（无段间距的本体）：竖屏 titleBlock 在外面加
    /// 8/10 段间距；横屏左列总高账紧张（见 landscapeLayout），直接用本体、
    /// 段间距由调用方另给 4。内容高：compact 档歌名 28×1.25 + 2 + 副标题
    /// 13×1.3 = 54，状态角标行有内容时再 +22 = 76。
    /// r26：compact 竖屏有状态行时角标行压缩（compactStyle，见
    /// statusCapsules），本体高 76 → 约 71（只省角标行 5pt；titleBlock
    /// 间距省的 10pt 在本体之外）；横屏传 false，一字不动。
    private func titleTexts(tier: PlayerTokens.PlayerSizeTier) -> some View {
        VStack(spacing: 2) {
            Text(store.currentTrack?.title ?? "未在播放")
                // 歌名居中大字，字号走 PlayerTokens.titleSize(tier)；
                // Fraunces 已随包（见 DesignTokens.liziDisplay）。
                // 长标题单行省略（lineLimit 1 + 默认尾部省略）或缩小
                // （minimumScaleFactor 0.5），不截断。
                .font(.liziDisplay(size: PlayerTokens.titleSize(tier)))
                .foregroundStyle(PlayerTokens.playerForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(subtitleText)
                .font(.system(size: PlayerTokens.subtitleSize(tier)))
                .foregroundStyle(PlayerTokens.playerSub)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
            statusCapsules(compactStyle: tier == .compact, largeStyle: tier == .large)
        }
    }

    /// 副标题（r22k：审计图 P4 只写歌名 + 歌手，专辑不进副标题；
    /// 没歌手时回落平台名，不编假数据）。
    private var subtitleText: String {
        guard let track = store.currentTrack else { return "从首页或搜索页选一首歌开始" }
        return track.artist.isEmpty ? track.platform : track.artist
    }

    /// 状态角标：只在有内容时出现 —— 试听、演示音。取链失败的原因由下面的
    /// error 行明示，不静默。r29：歌名下方中间的实际音质角标已删（用户真机
    /// 报「中间的杜比全景声显示也删除」），音质入口只剩底部第 3 排的音质
    /// 芯片（PlayerBottomDock，点开 9 档选择器），actualQuality 取链与
    /// 状态本身不动。
    /// 无曲目时什么都不显示（空态只有「未在播放」+ 副标题）。
    /// r26：compactStyle 只由竖屏 titleTexts 在 compact 档传 true（角标行
    /// 压缩：胶囊字 11→10、纵向 padding 2→1，行上间距 4→2；角标行总增量
    /// 22 → 约 17，省约 5pt，见文件底 r26 总账）。横屏 landscapeTitleTexts
    /// 传 false，横屏一字不动；其余档传 false。
    /// r27：largeStyle 只由竖屏 titleTexts 在 large 档传 true，角标行同款
    /// 压缩（22 → 约 17，省约 5pt；失败原因行上间距 4→2，约 20 → 约 18），
    /// 与 titleBlock 间距（large + 有状态行 8/10 → 4/4）合计省 15pt，
    /// 修 large 有角标溢出（见文件底 r27 段落）；standard 两个参数都 false。
    /// 压缩只在有状态行（hasStatusRow 为真）时生效，无角标态一字不动。
    @ViewBuilder
    private func statusCapsules(compactStyle: Bool, largeStyle: Bool = false) -> some View {
        // compact 与 large 的压缩值同一套（胶囊字 10、纵向 padding 1、
        // 行上间距 2），只在各自档位 + 有状态行时生效。
        let squeeze = compactStyle || largeStyle
        if let message = store.errorMessage {
            Text(playFailureText(for: message))
                .font(.system(size: PlayerTokens.textXs))
                .foregroundStyle(Color.red.opacity(0.85))
                .padding(.top, squeeze ? 2 : 4)
                // r28：只有取链失败原因是登录（loginPromptPlatform 非空，
                // 目前只有酷狗）时点红字才弹登录入口；其它失败原因点按无
                // 动作。内层手势优先于外层 titleBlock 的点歌名开队列，
                // 点红字只弹登录，不会同时打开队列。
                .onTapGesture {
                    if let platform = store.loginPromptPlatform {
                        loginTarget = LoginSheetTarget(platform: platform)
                    }
                }
        } else if store.currentTrack != nil {
            // r29：实际音质角标已删（只删显示，取链/状态不动）；角标行只剩
            // 试听/演示。两个条件全不成立时整行不渲染——旧代码空 HStack +
            // 上间距会留 6pt 幽灵高，删角标后这是常态（普通曲目），必须收掉。
            if store.currentTrack?.isTrial == true || store.isDemo {
                HStack(spacing: 6) {
                    if store.currentTrack?.isTrial == true {
                        statusCapsule("试听", compactStyle: squeeze)
                    }
                    if store.isDemo {
                        statusCapsule("演示音", compactStyle: squeeze)
                    }
                }
                .padding(.top, squeeze ? 2 : 4)
            }
        }
    }

    private func statusCapsule(_ text: String, compactStyle: Bool = false) -> some View {
        Text(text)
            .font(.system(size: compactStyle ? 10 : 11, weight: .medium))
            .foregroundStyle(PlayerTokens.playerForeground)
            .padding(.horizontal, 7)
            .padding(.vertical, compactStyle ? 1 : 2)
            .background(Color.white.opacity(0.16))
            .clipShape(Capsule())
    }

    /// 横屏左上歌名块（r22 横屏重排）：与 titleTexts 同内容（歌名 + 歌手 +
    /// 状态角标），只改对齐为左对齐（歌名 + 歌手左对齐，不居中）；段间距与
    /// 点按都不在这里——调用方给宽（变体顶行 220 + .clipped()；默认横屏
    /// 左列 260，行内 lineLimit 1 + minimumScaleFactor 0.5 自行截断），
    /// 队列入口是控制行三条杠。
    /// r29 task 7：默认横屏也复用本函数（左列封面下方的标题块，宽 260），
    /// 02/04 变体顶行与 smallCoverHeader 仍用它，函数本体一字未动。
    /// 内容高与 titleTexts 同款：compact 档歌名 28×1.25 + 2 + 副标题 13×1.3
    /// = 54，状态角标行有内容时再 +22 = 76。
    private func landscapeTitleTexts(tier: PlayerTokens.PlayerSizeTier) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(store.currentTrack?.title ?? "未在播放")
                .font(.liziDisplay(size: PlayerTokens.titleSize(tier)))
                .foregroundStyle(PlayerTokens.playerForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(subtitleText)
                .font(.system(size: PlayerTokens.subtitleSize(tier)))
                .foregroundStyle(PlayerTokens.playerSub)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // r26：横屏 compactStyle 恒为 false（角标行不压缩，横屏一字不动）。
            statusCapsules(compactStyle: false)
        }
    }

    /// 播放失败原因明示（PlaybackStore.errorMessage 的 reason 码，不编新文案，
    /// 只翻译成用户能看懂的话）。
    private func playFailureText(for reason: String) -> String {
        switch reason {
        case "vip": return "会员歌曲，无法播放整首"
        case "unavailable": return "这首歌暂时无法播放"
        case "login": return "需要登录后才能播放"
        case "region": return "该歌曲在你所在的地区不可用"
        case "drm": return "该歌曲受版权保护，无法播放"
        case "network": return "网络有问题，稍后再试"
        default: return "这首歌暂时无法播放"
        }
    }
}

// MARK: - 各档高度总账（与工人 C 在 PlayerTokens.swift 里算的总账同一套数；
// r27 注：本段「顶栏→封面→歌词区→歌名块→控制行→细进度条」是换 dock 之前
// 的旧底（控制行 + 细进度条）；默认版式已换 v4 底部三排，总账见下面 r27 段落
// （实账），本段数字只对 02/04/06 变体与横屏仍有效，不要拿本段数去核默认版式。
// 段间距已按该总账对齐：顶栏→封面 6，封面→歌词区 8，歌词区→歌名块 8，
// 歌名块→控制行 10，控制行→进度条 12。歌名块高 = titleSize×1.25 + 2
// + subtitleSize×1.3；状态角标行（r29 起只剩试听/演示，实际音质角标
// 已删）有内容时再 +22。
// 进度条按外框 32 计（视觉细条 4，触摸区 32，见 PlayerProgressBar.touchHeight），
// 不是 4。r27：顶栏直径改固定 49pt（实测值，见 topBar 注释），三档总账各变
// +5/+1/−3pt（compact 636→641、standard 779→780、large 854→851），仍全未超高；
// r29 task 5：顶栏三钮 49 → 44pt，三档总账各 −5pt（compact 641→636、
// standard 780→775、large 851→846），仍全未超高；task 6 只改默认版式，
// 变体仍调 titleBlock 不动，变体总账不受拆分影响。
// 歌词展开功能已删，封面不再随展开收小，总账里不再有展开腾出的余量。）
//
// - compact（375×667 SE 最短屏，topInset 20，底部 0）：
//   20 + 44 + 6 + 232 + 8 + 150 + 8 + 54 + 10 + 60 + 12 + 32 + 0 = 636 ≤ 667，
//   余 31（歌词区实得 150 + 31 = 181）；状态角标 +22 → 658 ≤ 667 仍过。
//   同档 mini（375×812，topInset 50，底部 34）：700 ≤ 812。
// - standard（402×874 用户真机 iPhone 16 Pro，topInset 59，底部 34）：
//   59 + 44 + 6 + 254 + 8 + 180 + 8 + 60 + 10 + 68 + 12 + 32 + 34 = 775 ≤ 874，
//   余 99（歌词区实得 180 + 99 = 279）；状态角标 +22 → 797 ≤ 874 仍过。
//   同档 390×844（topInset 47）：763 ≤ 844。
// - large（430×932，topInset 59，底部 34）：
//   59 + 44 + 6 + 280 + 8 + 210 + 8 + 67 + 10 + 76 + 12 + 32 + 34 = 846 ≤ 932，
//   余 86（歌词区实得 210 + 86 = 296）。
// 三档全未超高（上面这段总账是加音量行之前的数；r25-B4 在竖屏四变体接了
// 音量行，r25-B5 又只在 compact 默认/04 撤掉：该两档无角标歌词区实得 162、
// 角标 140（B4 口径重算，见下段），其余档/变体以下面 r25-B4/B5 的数为准）。
//
// r25-B4/B5 音量行总账（历史记录；r28：音量行与第二行都已删，App 内
// 无音量按钮，音量走机身键/控制中心；下面数字是删行前的槽位账，只留
// 作对照，驱动重算以当前代码为准）：竖屏四变体曾在控制行后加音量行
// （行高 28 + 上间隙 8 = 36pt，从弹性歌词区扣；横屏总高 402 已满，
// 不放）；r25-B5 只在 compact 档默认/04 不渲染（02/06 与其余档保持
// 现状；compact 上音量走系统音量键，与 r25 之前一致，不另开入口）。
// 歌词区实得高 = 屏高 − 固定段（从屏顶算起，竖屏圆钮
// 顶边 39pt，r23i 列扫描实测；不是 PlayerTokens 总账的 topInset 口径——
// 那套把顶栏顶边算成 20/47/59，B2 的「约 27pt」就是按那套算的，方向一致，
// 基线不同：636 + 36 + 22 − 667 = 27）：
// - 默认 / 04（段相同，只是顺序不同）：compact 375×667：固定段 505
//   （B4 接音量行时 541，B5 撤掉减 36），歌词区实得 162（≥ 最小高 150，
//   余 12pt，不再超高）；状态角标 +22 → 固定段 527，实得 140
//   （仍破 10pt，整列超高 10pt，见下段）。standard 390×844：固定段 615
//   → 实得 229（角标 207）；用户真机 402×874：同固定段 615 → 实得 259
//   （角标 237）。large 430×932：固定段 660 → 实得 272（角标 250）。
//   即 compact 默认/04 无角标已不压破下限，只剩角标态破 10pt。
// - 02：compact 固定段 313 → 实得 354（角标时小封面行 68→76，固定段 321
//   → 实得 346）；standard 固定段 359 → 实得 485（角标时小封面行 68→82，
//   固定段 373 → 实得 471）；用户真机 402×874：同固定段 → 实得 515
//   （角标 501）。large 固定段 371 → 实得 561（角标时小封面行 68→89，
//   固定段 392 → 实得 540）。全档远高于 150。
// - 06：compact 固定段 341 → 实得 326；standard 387 → 457；large 399 →
//   533（小封面行 96 始终高于歌名块 54/60/67 与角标 76/82/89，不随角标变）。
//   全档远高于 150。
// - compact 默认/04（B5 后）：无角标歌词区实得 162 ≥ 150，整列
//   505 + 150 = 655 ≤ 667，余 12pt，最底部进度条不再被顶出屏底；
//   有状态角标时实得 140 < 150，整列超高 10pt，进度条仍会被顶出屏底
//   10pt（B4 时超高 24/46pt，B5 只治了无角标态，角标态如实记录，
//   不硬塞）。r27：歌词展开功能已删，上面这句「展开腾出空间」已作废；
//   角标态的 10pt 由 r26 的角标压缩修掉（见下段），不再靠展开。
//
// r26 compact 角标溢出修复（只动竖屏默认/04 的 compact 档有角标态；
// 详见 verification/r26-compact-check.md，四变体 × 有/无角标逐项算式）：
// 旧算式（r25）：角标行增量 +22 = 间距 2 + 行上间距 4 + 胶囊 16
//   （11pt 字行约 12 + 纵向 padding 2+2）；titleBlock 间距 8/10；
//   固定段 505 + 22 = 527，歌词区实得 667 − 527 = 140 < 150，超高 10pt。
// 新算式（r26，compact + 有状态行才生效）：
//   (1) 角标行压缩（statusCapsules/statusCapsule 的 compactStyle）：
//       胶囊字 11→10、纵向 padding 2→1（胶囊 16 → 约 13，省 3），
//       行上间距 4→2（省 2）→ 角标行增量 22 → 约 17（省 5）；
//   (2) titleBlock 间距收紧（titleBlockTopPadding / BottomPadding）：
//       上 8→4（省 4）、下 10→4（省 6），合计省 10；
//   (3) 合计省约 15pt：固定段 527 − 15 = 512，歌词区实得 667 − 512
//       = 155 ≥ 150，整列 512 + 150 = 662 ≤ 667，余 5pt，进度条完整可见。
//   失败原因行同款：行增量约 20（间距 2 + 上间距 4 + 12pt 字行约 14）
//       → 约 18（上间距 4→2，省 2），加间距省 10 → 固定段约 513，
//       歌词区实得约 154，余约 4pt，同样不溢出。
//   无角标态：hasStatusRow 为假，全部走旧值（titleBlock 8/10、角标行
//   不渲染），固定段仍是 505、歌词区实得 162，一字不动。
//   02/06 compact：角标在小封面行里（landscapeTitleTexts，compactStyle
//   恒 false，不压缩）——02 有角标固定段 321、歌词区 346；06 固定段 341、
//   歌词区 326；r25 已过，本轮不动。
//   横屏：landscapeTitleTexts 传 compactStyle: false，titleBlock 只在
//   竖屏用，横屏总账与胶囊顶边 10pt 一字不动。
//   注：r29 之前，有曲目但三个角标条件全不成立时 HStack 为空，仍有上间
//   距 4 + 间距 2 = 6pt 幽灵高（固定段 511、歌词区 156 ≥ 150，不溢出；
//   当时是瞬态，曲目质量一到即有角标）。r29 删了实际音质角标后无角标
//   成了常态，statusCapsules 已改成两条件全不成立时整行不渲染，幽灵高
//   归零；上面「角标态破 10pt」的旧账只对试听/演示角标出现时仍有效，
//   普通曲目（无试听/演示）固定段 505、歌词区实得 162。
//   r29 task 5/6：默认版式顶栏 49 → 44（−5）、歌名/歌手拆分（+6），
//   普通曲目固定段 505 → 506、歌词区实得 162 → 161；有角标态 512 → 513、
//   实得 155 → 154；失败原因行 513 → 514、实得 154 → 153。仍不溢出。
//
// r27 v4 底部三排（只改竖屏默认版式；02/04/06 变体与横屏仍用旧控制行 +
// 细进度条，总账不动）：默认版式里 PlayerControlRow（68/60/76）+ 最底部
// 细进度条（32）由 PlayerBottomDock 替掉（第 3 排 32 + 间隙 8 + 第 2 排
// 进度条 50 + 间隙 8 + 最下面一排 61，标准档；compact：第 3 排 26 +
// 间隙 2 + 第 2 排 46 + 间隙 2 + 最下面一排 42；large：第 3 排 32 +
// 间隙 8 + 第 2 排 51 + 间隙 8 + 最下面一排 68；dock 上间隙 8，
// compact 4；底部 Home Indicator 安全区 34/0）。r28：第二行已删，
// App 内无音量按钮，音量走机身键/控制中心。compact 封面流 232 → 209
// （单张 168 → 154）。
// 实账（从屏顶 39pt 算起的 r25-B4 口径，固定段不含歌词区最小高；
// r27 压缩轮纠正：上一版实账漏计了 titleBlock 下间距 10pt（代码
// titleBlockBottomPadding，无角标 10、有角标 compact/large 4），
// 所以上一版固定段全档少算 10pt——compact 有角标 553 碰巧没错
// （角标净增量应为 +7 不是 +17：间距省 10 + 角标行 +17），其余五格
// 各少 10pt；下表是按代码逐项重算的纠正后数字，任务书的旧数只留作对照）。
// r29 task 5/6 纠正：r27 实账 standard/large 里「8+28」那 36pt 是已删
// 第二行（PlayerSecondRow.swift，r28 删文件；dock 只有三排，第 3 排
// 32 + 间隙 8 + 第 2 排 50 + 间隙 8 + 最下面一排 61），r27 换 dock 时
// 旧账没摘掉、r28 也没发现（r28.cjs 不验这份总账）；compact 那行从
// 没算过第二行（写着「无第二行」），所以 compact 505 是对的。下表是
// 顶栏 44 + 歌名/歌手拆分后的真数：固定段 = 顶 39 + 顶栏 44 + 6 +
// 封面 + 歌名顶 8 + 歌名（35/40/45）+ 歌词顶 8 + 歌手顶 8 + 副标题
// （17/18/20）+ 歌手底 10 + dock 顶（4/8/8）+ dock（118/159/167）+
// 安全区（0/34/34）；三档净变：顶栏 −5、拆分 +6、摘已删第二行 −36
// （只 standard/large 有）→ compact 505→506、standard 671→636、
// large 712→677。有曲无角标幽灵行 r29 已归零（statusCapsules 空态
// 不渲染），下表不再列。
// - standard（用户真机 402×874）：固定段 636
//   （39+44+6+254+8+40+8+8+18+10+8+32+8+50+8+61+34），歌词区实得
//   874 − 636 = 238 ≥ 180，余 58；有角标 +22 → 固定段 658，实得 216，
//   余 36；失败原因行 +20 → 固定段 656，实得 218，余 38；390×844 同档
//   按此口径固定段 636 + 180 = 816 ≤ 844，余 28。
// - large（430×932）：固定段 677（39+44+6+280+8+45+8+8+20+10+8
//   +32+8+51+8+68+34），歌词区实得 932 − 677 = 255 ≥ 210，余 45；
//   有角标态 r27 压缩 −15（歌手块间距 8/10 → 4/4 省 10，角标行 22 →
//   约 17 省 5）：固定段 684，实得 248，余 38；失败原因行 −12（间距
//   省 10 + 行 20 → 约 18 省 2）：固定段 685，实得 247，余 37。
// - compact（375×667，无第二行）：r27 压缩 −41（封面流 232 → 209 省 23；
//   dock 132 → 118 省 14：大播放键 Ø48 → 42、第 3 排 28 → 26、第 2 排
//   48 → 46、排间距 4 → 2；dock 上间距 8 → 4 省 4）。固定段 506
//   （39+44+6+209+8+35+8+8+17+10+4+26+2+46+2+42），歌词区实得
//   667 − 506 = 161 ≥ 150，余 11；有角标（r26 压缩后净 +7）→ 固定段
//   513，实得 154，余 4；失败原因行（净 +8）→ 固定段 514，实得 153，
//   余 3。歌词区最小高仍是 150，未放宽（约 5 行可见：顶部留白 20 +
//   当前行约 27 + 上方 4 行约 20/行）。
// - 02/04/06 变体：仍走旧控制行 + 细进度条；04 compact 封面跟随
//   209（歌词区 326 → 347，余量更大），其余总账仍是 r26 的数，一字不动。
// - 注意：PlayerTokens.swift 的纸面总账（topInset 口径）同步改成了
//   dock 段数与纠正后的 10pt，但纸面口径把顶栏顶边算成 20/47/59
//   （比实测 39 多/少），与本段实账差一个顶边基线；真机以本段实账为准。
//
// 横屏总账（r22 重排；874×402，top 0；灵动岛在左/在右只扣 leading/trailing，
// 不占高）：顶区 158.4（封面轨道 254×198/254×0.8；胶囊 44、歌名块 ≤80，
// 都比轨道矮，行高由轨道定）+ 歌词区上间隙 8 + 歌词区（弹性，最小高 100，
// 底部安全区 0 时实得 131.6、21 时实得 110.6）+ 控制行 60（compact）
// + 间隙 12 + 进度条 32（触摸区）+ 底部安全区（0 或 21）= 402，刚好。
// 横屏宽度账（岛在左）：59 + 内容列 815 + 0 = 874；岛在右对称：
// 0 + 815 + 59 = 874。内容列内：顶区 = 返回胶囊 + 歌名 220 + 居中封面流
// （吃中间剩余宽，约 237）+ 搜索胶囊 + 控制胶囊；歌词区 / 控制行 / 进度条满 815。
//
// r29 task 7 横屏默认重排（图纸 ~/workspace/lizi-landscape-diagram.png，
// 只改默认 landscapeLayout + 新增横屏专用歌词区，02/04/06 变体与竖屏
// 一字不动；驱动 verification/r29-task7.cjs）：
// - 顶行三钮：文字胶囊 → Ø38 小圆钮（复用 topBarCircleButton，图标因子
//   0.47，图标约 17.9pt；竖屏 Ø44，横屏再小一档），只留图标不留文字，
//   动作（返回首页 / 搜索页 / 舞台页）与 accessibilityLabel 不变。
// - 左列 260：CoverFlowView 改到左列，不再 scale 0.8；中央张 148 × 1.04
//   ≈ 154pt 方形完整保留，框高 162 只裁倒影（轨道本身 198，402 高装不下
//   198 + 标题块 54；框顶对齐，封面顶边不被裁）；标题 + 歌手放封面下面，
//   复用 landscapeTitleTexts（不新建 statusCapsules 调用点，r29-task4
//   驱动断言该函数恰好 3 处调用）；无试听/演示/失败时角标行不渲染，歌手
//   就是左列最下面一行（原杜比药丸位置；实际音质角标 r29 task 4 已删）。
// - 右列歌词 539：横屏专用高对比歌词区 landscapeLyricsZone（自带渲染，
//   LyricsPanelView.swift 一字不动——竖屏歌词颜色只许在 PlayerView.swift
//   内改，横屏这一路只能另起渲染）：非当前行白 0.85（原 playerDim 0.52）
//   × 0.9 / 0.75 / 0.6 / 0.5，不模糊，上一行实效约 0.77（原约 0.29）；
//   当前行红色 accent 不变；逐字未唱到的字白 0.85、翻译行白 0.8
//   （原 0.52 / 0.58）；行左对齐，不罩顶部渐隐遮罩；点行跳转、当前行贴底、
//   队列面板只盖住本区都与 LyricsZoneView 同款。
// - 控制行（compact 58）与进度条（触摸区 32 + 上间隙 12）位置与大小不动。
// - 高账（874×402，控制行按实值 58 算，旧账 60 是约数）：顶 padding 10
//   + 顶行 38 + 中段上间隙 6 + 左列（封面框 162 + 间隙 6 + 标题块 54
//   = 222）+ 控制行 58 + 进度条上间隙 12 + 进度条 32 + 底部安全区
//   （0 或 21）= 399（安全区 21 时余 3；安全区 0 时 378，余 24 归弹性
//   歌词区）；右列歌词区实得 225 / 246，减区顶 padding 8 得 217 / 238，
//   均 ≥ 最小高 100。宽账：左列 260 + 间距 16 + 右列 539 = 815。
// - 残留：试听/演示/取链失败时状态行多约 20–22pt，左列 222 → 约 244，
//   底部安全区 21 时整列超约 19pt，进度条视觉细条会被顶出屏底（触摸区仍
//   有约 13pt 在屏内，控制行完整可见）；安全区 0 时 398 ≤ 402 不超。
//   （修法要么裁封面方形本身、要么左列去掉状态行——后者会丢取链失败点
//   红字弹登录的入口，两害相权留了现状。）
//
// MARK: - r21b 根因（竖屏右移，像素实测钉死）
// r27 注：本节「展开」指 r21 当时截图里右下角的歌词「展开」入口，
// 该功能已删（见 LyricsPanelView.swift），此处只保留历史实测记录，
// 不表示现在还能展开。
//
// 实测（用户竖屏截图 1206×2622 px = 402×874 pt @3x，iPhone 16 Pro，在播
// 《Ionic Evolution》；像素实测，见 verification/r21b-layout.cjs 注释）：
// - 返回按钮中心 (52.8, 147.8)，直径 47.7 ≈ 标准档 48：设计值应为 (40, 83)
//   （左 16 padding + 半径 24；topInset 59 + 半径 24）→ 偏移 (+12.8, +64.8)。
// - 封面左缘 308.0pt（三处取样一致）：标准档单张 188×1.04 = 195.5，设计左缘
//   (402 − 195.5)/2 = 103.3 → 封面中心 405.8，设计中心 201 → 右移约 205。
// - 歌名中心约 413、副标题/红歌词行/控制行同样右移约 200；顶栏搜索/设置被顶出
//   右屏；背景铺满全屏左缘；最底部进度条位置正常。
// - 分档没错：按钮 Ø48、封面 188 都是标准档 → geo.size.width 在 381…414，
//   sizeTier / GeometryReader 尺寸不是根因。
// - 唯一同时解释四点的几何：内容 VStack 约 786 宽 × 约 744 高，摆在 (12.8, 64.8)：
//   左缘 12.8 → 返回按钮中心 12.8 + 16 + 24 = 52.8 ✓；内容中心 12.8 + 786/2
//   = 405.8 ✓（封面中心）；下移 64.8 = (874 − 744)/2 ✓（VStack 在 874 高里居中）。
//   即：VStack 按内容理想尺寸排（约 786 宽：某行单行 Text 的理想宽度——
//   长副标题/长歌词行在歌词区 ScrollView 链里未被行宽夹住——撑大了容器），
//   再被默认居中的 ZStack 居中放置；横向 (812 − 402)/2 ≈ 205 的居中差就是
//   右移量。背景与进度条因是满宽/全屏渲染，看不出位移；返回按钮因左锚定，
//   只露出 +13/+65 的容器原点偏移。
// - 排除：r19 同款 GeometryReader + ZStack + VStack 骨架在他手机上跑通过，
//   且 r19 与 r20 的背景（模糊封面 + blur 64 + scale 1.25）同一套代码——
//   背景不是（唯一）根因；r20 新加的歌词区 ScrollView 链（LyricsZoneView 内
//   GeometryReader + ScrollView + 单行 Text）是唯一能报出大理想宽的新元素。
//   最后一环（到底是哪一行 Text 报出 786）需真机 console 的 [r21-layout]
//   日志 + 新版截图确认；r21b 的修法不依赖这一环：每行死宽度 + 顶左锚定，
//   任何一行再宽也只能在行宽里截断，容器不可能再被撑宽、居中。
// - 横屏「什么都没有」：同一套竖屏纵向结构总高约 779pt，横屏可用高只有约
//   381pt（402 − 顶栏安全区 0 − 底部 0，中间行 306 是新账），歌名/歌词/
//   控制行/进度条全被顶到屏外，只剩顶栏、封面占位和右下角「展开」。r21b
//   给横屏单独立了左右分栏，不再复用竖屏纵向结构。
//
// MARK: - r22a 根因（顶栏太靠下 + 横屏铺不满，像素实测钉死，用户机 874×402）
//
// 竖屏实测（截图 1206×2622 px = 402×874 pt @3x，iPhone 16 Pro，在播 发如雪）：
// 返回按钮 bbox px x 48–191、y 372–539 → 中心 (39.8, 151.8)pt、直径 47.7pt
// （标准档 48）；顶边 124.0pt；时间 04:11 中心 y≈28.8pt；灵动岛中心
// y≈30.6pt（约占 y 11–48pt）；封面顶边 178.0pt。
// 横屏实测（截图 1206×555 px = 874×402 pt，在播 青花瓷）：返回中心
// (146.0, 22.9)pt；搜索 (672.1, 22.1)；齿轮 (728.9, 22.1)；封面左 123.2、
// 右 344.4（宽 221 ≈ 左列 220 ✓）；歌名中心 234.2pt（=124+110，左列居中 ✓）；
// 暂停中心 263.9pt；进度条左 124.1、右约 749.9（bbox 实测 123.2..750.0）；
// 红歌词行最右 745.5pt；「展开」中心 (730.1, 68.5)pt。
//
// 两张图的共同点：内容块被压成 626 宽、居中落在 124..750，右边空 124。
// - 竖屏：顶边 124（设计 59，+65）；封面顶边 178（设计 113，+65）；
//   顶边→进度条视觉顶实测 676pt；按代码段高反推歌词区 ≈152，与最小高 180
//   矛盾——但用字形带定位：歌词区顶 440、歌名框顶约 628 → 歌词区 ≈180
//   （最小高，未弹性展开，符合）。即整列被整体下移 65，歌词区没有展开。
// - 横屏：内容 124..750（626 宽），左列 220 尺寸本身正确，歌词区只剩
//   约 390（设计 579）；顶栏纵向位置正确（compact 44/2 = 22）。
// - r21 代码按 geo=874 推不出这个结果：行宽 = 874 − sideInsets，sideInsets
//   要 248（124+124）才得 626；而 124 不是任何 iPhone 的真安全区
//   （岛侧 59 / 刘海 47 / 无刘海 20）。即 geo.safeAreaInsets 在用户机上
//   被垫高了约 65（顶 59→124，两侧 59→124，0 的边不变：横屏顶 0 仍是 0，
//   所以横屏顶栏纵向位置正确）。垫高的机制未钉死（候选：视图层级里某处
//   多扣了一层安全区；[r21-layout] 日志会印 geo.safeAreaInsets 的实测值，
//   真机可对照确认），但数值是钉死的：两个像素精确值（顶边 124、封面 178）
//   与横屏行宽 626 都指向同一个 +65/+124。
// - 旧 r22a（第一轮）的修法是错的：它只把「frame(屏宽) 再 padding 两侧」
//   改成「contentWidth = geo 宽 − geo 安全区」，但 geo 安全区本身就是 124，
//   contentWidth 仍得 626，铺不满依旧。已废弃。
// - r22a 最终修法（本轮）：不再信任 geo 的尺寸与安全区。
//   (1) 屏宽/屏高走 UIScreen.main.bounds（真屏尺寸；geo.size 本身与它一致，
//       换源不换数，只是以后不再依赖 geo 的口径）。
//   (2) 安全区走 key window 的 safeAreaInsets（系统自己的值，不经过视图
//       层级，不会被垫）：顶部 windowTopInset（夹到 ≤59，无窗口时 47 兜底，
//       与 LyricsPanelView.keyWindowTopInset 同一口径）；横屏两侧
//       landscapeSideInsets（岛侧 59、另一侧 0，每侧夹到 ≤59；两侧都 >0
//       且相等时用界面方向定岛侧：landscapeLeft 岛在左，landscapeRight 岛在右）。
//   (3) 横屏容器改成 HStack 三段（左 spacer + 内容列 + 右 spacer），
//       总宽恒 = 屏宽，整行不可能再被居中——岛在左行落在 59..874，
//       岛在右行落在 0..815，两边都到边；歌词列回到 579（815 − 220 − 16）。
//   (4) 竖屏顶栏顶边改走 windowTopInset（59）：顶栏回到 59..107（中心 83），
//       紧贴状态栏下方，灵动岛同一行高度之下、只留 11pt 间距；弹性歌词区
//       把省下的 65pt 吃掉（180 → 245），进度条仍贴底；竖屏其他段一字未动。
// - 歌词列宽不变：815 − 220 − 16 = 579，与 r21 的 579 同值；高账不变：
//   44 + 8 + 306 + 12 + 32 = 402。竖屏 portraitLayout 除顶部 padding
//   的口径外一字未动（段高、分档、歌词区最小高全保留）。
// - 左列不是根因：用户说「左列太窄/内容太小」，实测左列 220 分毫不差
//   （封面 123.2..344.4 = 221），是整块内容被压成 626 居中，歌词区才只剩
//   390。修整块宽度，不动左列尺寸。
// - 背景不是根因：background 是 ZStack 里独立的兄弟视图，一直铺满全屏；
//   错的只是内容列的宽度口径与顶部 padding 的口径。
// - 次要问题（另立项，不在本轮改）：进度条视觉细条系统性偏上约 28pt
//   （视觉条落在触摸区顶部：竖屏视觉顶 800 = 触摸顶，设计应为触摸顶 +28；
//   横屏同样差约 27–28pt），疑似触摸区顶部锚定，机制未解。
//
// MARK: - r23i 根因（顶栏仍太靠下，用户 07:13 竖屏 / 07:15 横屏图）
//
// 像素实测（用户机 402×874pt，iPhone 16 Pro Max）：
// - 竖屏 07:13 图（21ADF00C…A69C7829，1206×2622 @3x）：返回圆钮列扫描
//   x=120px，背景 (65,57,46) → 圆钮 (131,126,120) 过渡在 px y=362 → 顶边
//   120.7pt；圆钮灰区 bbox y 362–529px，人字中心 145pt，直径 ≈48（标准档）；
//   灵动岛黑区 y 42–151px → 底 50.3pt；岛底→钮顶空 70.4pt。任务书写的
//   「约 133pt」与本次列扫描 120.7pt 差约 12pt，同一量级、结论一致（≫40）。
// - 横屏 07:15 图（094794E5…1D287F79AD53，1206×555，1.38px/pt）：返回胶囊
//   灰区 y 0–60px → 顶边约 0pt、高 43.5pt（≈ compact 44）；中列 x=145 灰起
//   于 y=0，搜索胶囊同。横屏顶区原来没有顶部 padding（文件里唯一的
//   .padding(.top, 12) 是底部进度条的，不是顶栏的）。
// - 首页 07:09 图（F1A53A76…5A9597，1206×2622 @3x）：齿轮顶 47.3pt、中心
//   63.2pt，搜索中心 63.2pt，LIZI 字中心 58.5pt——顶栏对齐档是中心 63pt。
//
// 根因：r22a 只换了 padding 的口径（geo 124 → key window 59），但容器上方
// 仍垫了约 62pt（120.7 − 59）：安全区被多扣了一层，r22a 的 124 = 59 + 65
// 是同一量级。只改 padding 数值不拆容器，顶边只能在 59 附近打转，到不了 39。
// r23i 修法（本文件内）：padding 按「目标顶边 − 垫高」给——竖屏 39 − 62
// = −23（负 padding 整列上拉 82pt，弹性歌词区吃掉，进度条仍贴底）；横屏
// 顶区加显式 padding 10（8–12pt 档中值，歌词区吸收，仍 ≥ 最小高 100）。
// 垫高机制本身（容器那层 62pt 从哪来）未钉死，真机以圆钮中心 63pt 验收：
// 若实测中心偏离 63 超过 ±5pt，说明垫高不是 62，按「实测顶边 − padding」
// 重算 topBarContainerOffset 再推。
