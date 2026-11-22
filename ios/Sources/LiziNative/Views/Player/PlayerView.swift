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
/// （`PlayerBottomDock`，r27 v4；横屏传统模式（r35-7）是右列进度条 +
///   五键红控制行，不用 PlayerControlRow）。
///
/// 依赖（r20 三工人分工，本文件只引用、不定义）：
/// - `LyricsZoneView`：工人 B 在 `LyricsPanelView.swift` 里新建——截至交回时
///   仍未落地，本文件先按任务书给的名字引用，集成时等工人 B。
/// - `PlayerProgressBar(tier:)`：工人 C 已在 `PlayerDockView.swift` 里落地
///   （细条无时间数字，拖动 seek，播放头是圆点）；竖屏在 `PlayerBottomDock`
///   里复用（+ 两端时间），横屏传统模式（r35-7）在右列里复用。
///   `PlayerControlRow` r35-7 已删（唯一调用方是旧横屏布局；竖屏一直用
///   PlayerBottomDock，不受影响）；队列入口竖屏点歌名块（见 titleOnlyBlock），
///   横屏传统模式没有队列入口。
/// - 分档 API：工人 C 已在 `PlayerTokens.swift` 里落地，
///   `sizeTier(for:topInset:)` / `topBarButton(_:)` / `titleSize(_:)` /
///   `subtitleSize(_:)` / `coverItem(_:)` / `coverTrackHeight(_:)` /
///   `lyricsZoneHeight(_:)` / `progressHeight(_:)`，
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
/// r35-6：播放页排版只留默认——02 左右对半 / 04 上下分屏 / 06 极小封面
/// 三套版式全删（竖屏横屏共 6 个函数 + 专属 helper smallCoverHeader /
/// landscapeCapsuleRow / topBarCapsuleButton / titleBlock / titleTexts /
/// titleBlockTopPadding / titleBlockBottomPadding，全部随变体一起删，不留
/// 死代码）；设置页「播放页排版」一节与 `SettingsStore.nowLayout`（键
/// `lizi.now.layout`）一并清掉，旧值残留也再切不过去；播放页永远只走
/// 默认版式（竖屏两栏 / 横屏 5 条）。r25 #7 的版式对照随变体一起删，见 git 历史。
///
struct PlayerView: View {
    @EnvironmentObject private var store: PlaybackStore
    @EnvironmentObject private var navigation: AppNavigation

    /// r33：播放器壁纸——复用首页同一套 `BackgroundStore.shared`
    /// （键 `lizi.background.mode`、目录 Application Support/lizi.background/、
    /// 缓存图 `backgroundImage` / 视频 `videoFileURL` 与首页完全一致，
    /// 不另起读取逻辑；@ObservedObject 跟着模式/文件变当场重绘）。
    /// 首页是深色墨字配浅色蒙版，播放器是白字所以蒙版走深色压暗（见 background）。
    @ObservedObject private var backgroundStore = BackgroundStore.shared

    /// 队列面板是否打开：控制行最左列表图标的回调切它（再点一次关上）。
    @State private var showQueue = false

    /// r36：横屏底图专辑取色（首页 AlbumTone 同款，见 HomeView panelTone）：
    /// 当前曲目封面取 5 档色板，stops[2]/[3]/[4] → tone-a/b/c；切歌重算；
    /// 没封面 / 取图失败 / 取色失败 → 默认色（AlbumTone.fallback，深场）。
    /// r39-2：取色任务改挂整页（见 body），横竖屏共用同一份 tone——
    /// 横屏底图渐变 + 横竖屏全部元素颜色都走它，竖屏不再另取。
    @State private var playerTone = AlbumTone.fallback

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
                Group {
                    if isLandscape { traditionalLandscapeBackground } else { background }
                }
                // r37-3：横屏底图改按 geo.size（当前真实布局尺寸）取框，
                // 不再取 UIScreen.main.bounds——后者是静态快照，旋转瞬间 /
                // 分屏下可能仍是旧朝向尺寸，底图就会留一条没盖住的边
                // （窗口底默认偏白，看着就是一条白条）；竖屏一字不动。
                .frame(width: isLandscape ? geo.size.width : screenSize.width,
                       height: isLandscape ? geo.size.height : screenSize.height)
                if isLandscape {
                    landscapeLayout(geo: geo, tier: tier)
                } else {
                    portraitLayout(geo: geo, tier: tier)
                }
            }
            .frame(width: screenSize.width, height: screenSize.height, alignment: .topLeading)
            // r39-2：取色任务改挂整页 ZStack（原来只挂横屏分支）——横竖屏
            // 共用同一份 playerTone，切歌（coverURL 变）任务重开、旧任务
            // 取消、旧结果不回写；没封面 / 取图失败 / 取色失败 → fallback。
            // 取图复用 CoverImageLoader 进程内缓存，不另发请求（r36 原机制）。
            .task(id: store.currentTrack?.coverURL) {
                guard let url = store.currentTrack?.coverURL else {
                    playerTone = .fallback
                    return
                }
                guard let image = await CoverImageLoader.shared.image(for: url),
                      url == store.currentTrack?.coverURL,
                      let tone = AlbumToneExtractor.tone(from: image) else {
                    if url == store.currentTrack?.coverURL { playerTone = .fallback }
                    return
                }
                if url == store.currentTrack?.coverURL { playerTone = tone }
            }
            .onAppear { Self.logGeometry(geo) }
            .onChange(of: geo.size) { _ in Self.logGeometry(geo) }
        }
        // 禁缩放：SwiftUI 默认没有捏合缩放；这里明确不加任何缩放手势。
        .navigationBarHidden(true)
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
    /// 歌名块的位置、原来药丸的位置）：
    /// - 每一行都给死宽度（内容宽 = 屏宽 − 2×16）：行的布局宽
    ///   由 frame 定，不由内容理想宽定——再长的单行歌名/副标题/歌词也只能在
    ///   行宽里截断，撑不大 VStack。
    /// - 外层 VStack 死宽高 + .topLeading：不居中、不下拉。
    /// - r27 v4：主控行 + 底部细进度条由 `PlayerBottomDock`（底部三排：
    ///   下载/喜欢/评论/音质 → 进度条+时间 → 模式/上一首/播放/下一首/队列）
    ///   替掉；横屏仍用旧控制行 + 细进度条。
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
                // 歌词区之下（原来歌名块的位置，原来药丸的位置）：
                // 顶栏 → 封面流 → 歌名 → 歌词区 → 歌手 → 底部三排。
                // 旧 titleBlock 已拆成两行（r35-6：旧 titleBlock 随 02/04/06
                // 变体一起删）：titleOnlyBlock（歌名，点按开队列）+ artistBlock
                // （歌手 + 试听/演示角标）。
                titleOnlyBlock(tier: tier)
                    .frame(width: contentWidth)
                lyricsZone(tier: tier, width: contentWidth, albumTone: playerTone) // r39-2：竖屏歌词区接专辑 tone
                artistBlock(tier: tier)
                    .frame(width: contentWidth)
                // r27 v4 底部三排（见 PlayerBottomDock）：第 3 排下载/喜欢/
                // 评论/音质 → 第 2 排进度条+两端时间 → 最下面一排模式/
                // 上一首/播放/下一首/队列。进度条在 dock 里，不再单挂
                // 最底部细进度条；底部留 Home Indicator 安全区（有 34，无 0）。
                // r27 压缩：compact 档 dock 上间距 8 → 4（省 4pt，见文件底
                // r27 段落）；其余档 8 不动。dock 只在默认版式用，变体不动。
                PlayerBottomDock(tier: tier, width: contentWidth, onOpenQueue: { showQueue.toggle() }, albumTone: playerTone) // r39-2：竖屏底部三排接专辑 tone
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
            .foregroundStyle(albumText) // r39-2：竖屏歌名走专辑文字色
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
            .contentShape(Rectangle())
            .onTapGesture { showQueue.toggle() }
            .accessibilityHint("点按打开播放队列")
    }

    /// 歌手块（titleBlock 的副标题 + 状态角标两行 1:1，字号/对齐/压缩逻辑
    /// 不动；放在 lyricsZone 之后、dock 之前，即原来歌名块的位置）。
    /// 上间距 8（有状态行时 compact/large 收到 4，与旧 titleBlockTopPadding
    /// 同规则）；下间距 10（有状态行时 compact/large 收到 4，与旧
    /// titleBlockBottomPadding 同规则）。副标题行高 ≈ subtitleSize × 1.3
    /// （17/18/20），有状态行时再加角标行（试听/演示）。
    private func artistBlock(tier: PlayerTokens.PlayerSizeTier) -> some View {
        VStack(spacing: 2) {
            Text(subtitleText)
                .font(.system(size: PlayerTokens.subtitleSize(tier)))
                .foregroundStyle(albumSecondaryText) // r39-2：竖屏歌手走专辑次要文字色
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


    // MARK: - 横屏默认：顶行三圆钮 → 左列封面 + 标题 / 右列歌词 → 底部控制行 + 进度条

    // MARK: - 横屏传统：v2 稿图比例（r36，第③件；用户 2026-11-21 21:23 批 v2 稿
    //   `~/workspace/lizi-landscape-mockup-v2.png`，脚本 `draw-landscape-mockup-v2.py`；
    //   r35-7 的 232 封面 + 文字钮整段作废）
    // r37-2：下面 v2 比例数字（封面左 120、右列 x=540、歌名红合行、返回/
    //   顶栏左右留白按岛侧 59pt 兜底）已被修正版施工图
    //   `~/workspace/lizi-landscape-fixed-mockup.png`（用户已批「对」）取代，
    //   以 landscapeLayout / traditionalRightColumn / traditionalTopBar
    //   里的 r37-2 注释为准：返回贴左 3.75% 屏宽、封面左 15.625%、
    //   右列 x=50% 宽 37.5%、歌名/歌手分两行（白字）、进度条下加两端时间；
    //   其余 v2 口径（Ø44 圆钮、齿轮进舞台不带 openSettings、背景优先级
    //   壁纸 > 取色 > 深色底、控制行五键真实现）一字不动。

    /// r39-2：专辑强调色——a/b/c 三档中按深浅场取最易读的一档：深场取
    /// 最亮的 c，浅场取最深的 a；只取 AlbumTone 已有的三档，不编新色。
    /// 没封面 / 取色失败时 playerTone 已是 AlbumTone.fallback（深场）。
    /// 横屏 v2 稿主红 traditionalRed（226,72,72）随改动删掉，不留死常量。
    private var albumAccent: Color { playerTone.isDark ? playerTone.c : playerTone.a }
    /// r39-2：专辑文字色——深场白字、浅场墨字（AlbumTone.text 原样）。
    private var albumText: Color { playerTone.text }
    /// r39-2：专辑次要文字色（AlbumTone.secondaryText 原样）。
    private var albumSecondaryText: Color { playerTone.secondaryText }

    /// v2 比例（稿图 1280×720，真机横屏比 16:9 更宽，一律按相对比例换算，
    /// 不按绝对像素硬套；横向按屏宽、纵向按屏高）：
    /// - 封面 360×360：宽 28.125% 屏宽（360/1280），左上角 (120,115)：
    ///   左留白 9.375% 屏宽、顶留白 15.97% 屏高，圆角 24（= 封面边长的 1/15）。
    /// - 右列 x=540：起 42.1875% 屏宽，宽 50% 屏宽（540→1180）；
    ///   封面右缘 37.5% 与右列之间隔 4.6875% 屏宽。
    /// - 顶栏：返回 `<` 左上角 (45,26)；搜索/齿轮 Ø44 圆钮（44/1280 =
    ///   3.4375% 屏宽），中心 y=50（6.94% 屏高），中心 x≈1085（84.77%）、
    ///   1175（91.80%），两钮中心距 90px（7.03% 屏宽）。
    /// - 右列各行 y（稿图）：歌名 150、当前句 285、下一句 320、
    ///   进度条 380、控制行 460；字号按屏高换算（歌名 28、当前句 24、
    ///   下一句 22）；控制行五键中心距 92px（7.19% 屏宽）。
    /// - 混音 / 发行两行：Track 模型没有混音师 / 发行公司字段，各平台
    ///   歌曲详情也不返回（网易专辑详情有 company，但那是专辑详情接口，
    ///   不是播放中的曲目字段；本轮不为两行新拉接口）——不编假数据，
    ///   两行不渲染（稿图里的「混音：Cheeze」「发行：Old Tape」是稿图
    ///   作者拿歌手名/歌名后缀填的占位，不是真数据）；其余各行按稿图
    ///   间距排布（歌名→当前句取稿图歌名→混音的 50px 间距，行间不留空洞）。
    /// - 尺寸账（874×402；r39-3 按新稿 1280×590 换算，旧 246 账作废）：
    ///   封面 273 方形（400/1280×屏宽），顶 72.6；右列（行高按字号×1.2 估）：
    ///   标题 46 + 间距 3.4 + 歌手 23 + 间距 8.9 + 当前句 29.7 + 间距 6.7 +
    ///   下一句 28 + 间距 12.3 + 进度条 32 + 间距 5.6 + 时间 19.8 +
    ///   间距 8.9 + 控制行 32.7 ≈ 277（含标题顶垫 19.5），右列底约 349 ≈
    ///   封面底 346；下面余约 53pt 空底是稿图原样（稿图控制行下面同样留空），不是 bug。
    /// - 顶栏图标钮按 v2 的 Ø44 做（r34 的 Ø38 作废，用户 21:23 定稿）；
    ///   返回仍是 r35 的裸红 `<`，不动。
    /// - 背景优先级（21:17 取色 + 21:21 壁纸）：用户壁纸（照片/视频，
    ///   BackgroundStore）> 专辑取色（AlbumTone）> 深色默认底
    ///   （AlbumTone.fallback）；固定死深红底作废；不许白色。
    /// - 封面：真专辑图原样显示（与竖屏/Now Playing 同一 coverURL）；
    ///   没封面 / 加载失败走深色默认封面（CoverImageView r36），不许白框；
    ///   加载失败本身是 bug（重试见 CoverImageLoader.swift），不拿色块顶替。
    /// 横屏传统模式（r36 v2；r37-2 按用户已批的修正版施工图
    /// `~/workspace/lizi-landscape-fixed-mockup.png` 重排，1280×720 稿图比例换算）：
    /// - 返回 `<` 移到最左侧（稿里 x=48/1280 = 3.75% 屏宽，贴左边缘；岛在左时
    ///   也不再取 59pt 兜底——返回钮在屏顶（中心 y≈6.67% 屏高），岛在横屏时
    ///   贴侧边中部，纵向不重叠；样式仍是裸 `<`，r39-2 起走专辑强调色，
    ///   r39-3 字形高按新稿 36px 改大）。
    /// - 搜索 / 舞台两个 Ø44 红圈钮在右上角（稿里中心 x≈87.5% / 94.14% 屏宽，
    ///   中心 y 同返回钮；齿轮右缘离屏边约 4.14% 屏宽，留出间距），和返回分开两端；颜色 r39-2 起走专辑强调色。
    /// - 封面移到左中（稿里 x=200/1280 = 15.625% 屏宽，顶 130/720 = 18.06% 屏高，
    ///   边长 r39-3 起是 400/1280 = 31.25% 屏宽的方形，真机约 273pt）；
    ///   右列从 50% 屏宽起，宽 37.5% 屏宽。
    /// - 右列：歌名 / 歌手 / 当前句 / 下一句 / 进度条
    ///   （可拖 + 点按 seek，复用 PlayerProgressBar）/ 两端时间 / 控制行五键；颜色 r39-2 起
    ///   全部走专辑 tone（歌名/歌手/下一句走文字色，当前句/进度条/控制行
    ///   走强调色）。
    /// - r37-3：整层按 geo.size 排布（不用 UIScreen 快照），底图见
    ///   traditionalLandscapeBackground；r37-8：封面容器挂滑动切歌手势。
    /// - r39-3（本件：横屏背景占满 + 改大，定稿
    ///   `~/workspace/lizi-r39-landscape-fullscreen-mockup.png`，画布 1280×590）：
    ///   背景 r37-3 已铺满（traditionalLandscapeBackground ignoresSafeArea +
    ///   按 geo.size 取框）、r39-2 已改走专辑取色渐变，本次核查无白边来源，不再动；
    ///   尺寸一律按新稿像素 / 画布换算（横向 /1280×屏宽，纵向 /590×屏高，
    ///   真机 874×402 下实得：封面 273、歌名 38、歌手 19、当前句 24.5、
    ///   下一句 23、时间 16、控制行 32.7；字面 pt 硬套右列底约 431 > 屏高 402、
    ///   封面底约 473，会溢出，故不用字面值）；位置 / 排版 / 行间距 / 顶栏中心 y
    ///   一律不动，颜色全部沿用 r39-2 的 albumAccent / albumText /
    ///   albumSecondaryText，不写死红。
    private func landscapeLayout(geo: GeometryProxy, tier: PlayerTokens.PlayerSizeTier) -> some View {
        let compactTier = PlayerTokens.PlayerSizeTier.compact
        let screenWidth = geo.size.width
        let screenHeight = geo.size.height
        let islandTrailing = Self.landscapeSideInsets.trailing
        // r46-4：第 4 件——顶栏按真屏宽（UIScreen）算，不按 geo：播放器 geo
        // 在用户机上只有约 750pt（r22a 同款垫高；六处实测全吻合 W≈750：
        // 齿轮 678、搜索 628、封面宽 257、右列起 334、进度右缘 734），按 geo
        // 算齿轮中心只到 678pt、离屏边 196pt；用户 21:31 批的 v2 稿要求齿轮
        // 右缘离屏边 16pt（中心 843pt）、搜索 785pt——真屏宽 874 下
        // 874−16−15 = 843、843−58 = 785，恰好是稿子的数。封面/右列不动、
        // 仍按 geo 分数（与批过的稿一致）；顶栏因此比 geo 宽、向右溢出
        // 约 108pt（ZStack 不裁切，body 的 ZStack 本就是真屏宽 874）。
        let trueScreenWidth = UIScreen.main.bounds.size.width
        // r37-2：返回贴左边缘（稿 48/1280）；右上两钮右缘留约 4.14% 屏宽
        // （稿齿轮右缘 1231/1280），岛在右时取岛侧 59pt 兜底防重叠。
        // r46-4：右缘改离屏边 16pt（岛在右时仍取 59pt，不与灵动岛重叠）。
        let topLeading = 0.0375 * trueScreenWidth
        let topTrailing = max(islandTrailing, 16)
        // r44：封面按批改大稿 v2（874×402pt 基准）改大：边长 =
        // min(0.343×屏宽，0.746×屏高)，基准 300pt（横屏以屏高为准）；
        // 左 50/874×屏宽、顶 51/402×屏高；r39-3 的 400/1280×屏宽
        // （约 273pt）作废。注意：左 50pt 落在 59pt 岛侧安全区内，
        // 岛在封面一侧时可能与灵动岛重叠——稿子就是这么画的，按稿子做，
        // 风险见交回。
        let coverSize = min(0.343 * screenWidth, 0.746 * screenHeight)
        // r37-2：顶栏三钮中心 y = 稿里 48/720 = 6.67% 屏高；钮径仍是 r36-5 的 Ø44
        // （44/1280 = 3.4375% 屏宽）。
        let topBarDiameter = 0.034375 * screenWidth
        let topBarTop = 0.0667 * screenHeight - topBarDiameter / 2
        return ZStack(alignment: .topLeading) {
            traditionalTopBar(width: trueScreenWidth - topLeading - topTrailing, screenWidth: trueScreenWidth, screenHeight: screenHeight)
                .padding(.leading, topLeading)
                .padding(.top, topBarTop)
            // r44：封面与右列间距按大稿 40/874×屏宽；右列从 390/874×屏宽起
            // （0.446×屏宽），宽 465/874×屏宽（0.532×屏宽），右缘 855/874
            // （0.978×屏宽）；r39-3 的 0.03125×屏宽间距、右列从 50% 起作废。
            HStack(alignment: .top, spacing: 40 / 874 * screenWidth) {
                // r37-8：封面容器（固定 coverSize 方形）挂滑动切歌手势——
                // 手势挂容器不挂图片，占位态（歌名文字占位）一样能滑；
                // 阈值 0.3×边长、方向（左滑上一首 / 右滑下一首）与
                // CoverFlowView.swipeGesture 同款。
                // r37-8 细化：封面未加载先显示歌名文字占位（深色渐变底，
                // 与 DefaultCoverArt 同款配色，不许白底），确保用户能先看、
                // 能先滑动、能认出是哪首歌；图一加载出来 ProxyImageView 只
                // 渲染图、整支占位（含歌名）消失，不显示歌名。
                // 占位标题取当前这首歌（store.currentTrack?.title）；右列的
                // 歌名行不动，这里只是封面占位态的文字。滑动手势挂在容器上
                // （见下 .gesture），一字不动。
                ZStack {
                    ProxyImageView(url: store.currentTrack?.coverURL) {
                        landscapeCoverTitlePlaceholder(
                            title: store.currentTrack?.title, coverSize: coverSize
                        )
                    }
                }
                .frame(width: coverSize, height: coverSize)
                .clipShape(RoundedRectangle(cornerRadius: coverSize * 18 / 400)) // r44：圆角因子 18/400 不变、随封面边长等比缩放（r39-3 的因子，基准封面 300pt 时约 13.5pt）
                .contentShape(Rectangle())
                .gesture(landscapeCoverSwipeGesture(coverSize: coverSize))
                traditionalRightColumn(width: 465 / 874 * screenWidth, screenWidth: screenWidth, screenHeight: screenHeight, tier: compactTier) // r44：右列宽 465/874×屏宽（基准 465pt）
            }
            .frame(width: screenWidth, alignment: .leading)
            .padding(.leading, 50 / 874 * screenWidth) // r44：封面左 50/874×屏宽（基准 50pt）
            .padding(.top, 51 / 402 * screenHeight) // r44：封面顶 51/402×屏高（基准 51pt；右列顶与封面顶同高）
        }
        .frame(width: screenWidth, height: screenHeight, alignment: .topLeading)
        // r37-3：横屏整层忽略安全区——祖先一旦按安全区缩进本页，底图与返回键
        // 仍贴到左右边缘，不留白条；竖屏不动（portraitLayout 不走这里）。
        .ignoresSafeArea()
    }

    /// r37-8 细化：横屏封面未加载的歌名文字占位（见 landscapeLayout）：
    /// 深色渐变底（DefaultCoverArt 同款配色，不许白底）+ 当前歌名居中；
    /// 字号按封面边长取（边长 × 0.08，稿图 360 → 约 29pt），最多 3 行、
    /// 左右留 12pt，不溢出。切换靠 ProxyImageView：图一到只渲染图，
    /// 本占位整支消失，有封面时不显示歌名；无歌名时只剩深色底，不编假数据。
    @ViewBuilder
    private func landscapeCoverTitlePlaceholder(title: String?, coverSize: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.24), Color(white: 0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Text(title ?? "")
                .font(.system(size: coverSize * 0.08, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 12)
        }
    }

    /// r37-8：横屏封面滑动切歌（CoverFlowView.swipeGesture 的单封面版）：
    /// 阈值 0.3×边长、左滑上一首 / 右滑下一首与竖屏封面流一致；
    /// 队列不足 2 首或无当前下标时不切歌；单张静态封面没有跟手位移
    /// （没有 5 张流可插值），过阈值即切歌。手势挂在封面容器上
    /// （见 landscapeLayout），占位态也一样接。
    private func landscapeCoverSwipeGesture(coverSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onEnded { value in
                let dx = value.translation.width
                guard store.queue.count >= 2, store.currentIndex >= 0,
                      abs(dx) > coverSize * 0.3 else { return }
                if dx < 0 {
                    // 左滑上一首：直接按队列下标（不走 previous() 的回开头分支，
                    // 与 CoverFlowView 同款）。
                    let prev = (store.currentIndex - 1 + store.queue.count) % store.queue.count
                    if store.queue.indices.contains(prev) {
                        store.play(queueItem: store.queue[prev])
                    }
                } else {
                    // 右滑下一首：走 next()，和按钮一致。
                    store.next()
                }
            }
    }

    /// 传统横屏顶栏（r36 v2）：左裸 `<` 返回（r39-3：字形高按新稿 36px 改大，
    /// 见下；颜色 r39-2 起走专辑强调色），右搜索 / 齿轮两个专辑色描边 Ø44 圆钮
    /// （v2 稿图；r34 的 Ø38 作废，r35 的「舞台」/「舞台控制」文字钮作废，
    /// 用户 21:16 + 21:23 定稿）。钮径 =
    /// 44/1280 屏宽（0.034375 × 屏宽）；图标字号 = 钮径 × 0.47
    /// （r34 同款因子）；两钮中心距（r37-2，修正版施工图）85px
    /// （0.0664 × 屏宽），r36 的 90px 作废。三钮同在一条 HStack、行高 = 钮径，
    /// 中心 y 天然同高（r39-3 核查：不用另调）。
    /// 搜索进搜索页（.search，r34 原行为）；齿轮进舞台页（.stage()，
    /// 不带 openSettings，舞台页里自己的齿轮再调设置，r34 原行为）。
    /// 设置不进横屏顶栏。顶栏只留这 3 个功能。
    private func traditionalTopBar(width: CGFloat, screenWidth: CGFloat, screenHeight: CGFloat) -> some View {
        let diameter = 0.034375 * screenWidth
        return HStack(spacing: 0) {
            Button(action: { navigation.show(.home) }) {
                Image(systemName: "chevron.left")
                    // r39-3：返回 chevron 按新稿高 36px——字形高 = 36/590×屏高
                    // （真机约 24.5pt）；SF chevron 字形高约字号 ×0.6，字号取
                    // 36/590×屏高/0.6 ≈ 41pt（0.6 为估计值，未真机实测，见交回）。
                    .font(.system(size: 36 / 590 * screenHeight / 0.6, weight: .semibold))
                    .foregroundStyle(albumAccent)
            }
            .accessibilityLabel("返回首页")
            Spacer()
            traditionalTopBarCircleButton(systemName: "magnifyingglass", diameter: diameter) {
                // 搜索页走 App 现有的搜索导航路由，不新造（r34 原行为）。
                navigation.show(.search)
            }
            .accessibilityLabel("搜索")
            Spacer()
                // r37-2：两钮中心距 = 稿里 (1205−1120)/1280 = 6.64% 屏宽，
                // 减钮径 3.44% → 间隔 3.2% 屏宽（r36 的 3.59% 作废）。
                .frame(width: 0.032 * screenWidth)
            traditionalTopBarCircleButton(systemName: "gearshape", diameter: diameter) {
                // 齿轮就是舞台控制按钮（点进舞台页，不进设置页、
                // 不在播放页弹调节面板；r34 原行为）。
                navigation.show(.stage())
            }
            .accessibilityLabel("控制舞台")
        }
        .frame(width: width, height: diameter)
    }

    /// v2 顶栏图标圆钮：红描边圆（线宽 2，稿里 3px/1280 屏宽 ≈ 2pt），
    /// 红图标，透明底（r34 的毛玻璃底 + 白图标作废，v2 稿里就是红圈红标）。
    /// r39-2：描边与图标走专辑强调色（不再是固定红），样式/尺寸不动。
    private func traditionalTopBarCircleButton(systemName: String, diameter: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.47, weight: .semibold))
                .foregroundStyle(albumAccent)
                .frame(width: diameter, height: diameter)
                .overlay(Circle().stroke(albumAccent, lineWidth: 2))
        }
    }

    /// 传统横屏右列（r36 v2；r37-2 按修正版施工图重排；r44 按批改大稿 v2
    /// 874×402pt 基准改大：歌名 60/402 屏高粗体 → 歌手 30 → 当前句 40 专辑强调色粗体
    /// → 下一句 36 → 进度条（复用 PlayerProgressBar，可拖 + 点按
    ///   seek；填充/圆点走专辑强调色、轨道走专辑文字色，见 r39-2）→ 两端时间
    ///   26（00:29 / 04:30，零补齐）→ 控制行五键 48 高。r39-3 的
    ///   56/28/36/34/24（/590）作废。
    /// 行间距按大稿 y 换算（/402 屏高，SF 行高≈字号×1.21 推导，逐行顶与
    /// 稿子差 ≤ 约 1pt）：歌名顶垫 9、歌手 3、当前句 8、下一句 5、
    /// 进度条 +5、时间 5、控制行 1。
    /// r46-3：第 3 件——删掉 r44 的 −15 负顶垫：它把 32pt 触摸框顶拉进
    /// 下一句歌词行框（框顶 262pt 在模型里、实测约 219pt），视觉条
    /// （框底对齐）实测 247–251pt、压住下一句墨迹 225–253pt，重叠约 12pt。
    /// 新账（模型 ×1.21）：下一句行框底 277pt，进度条框顶 282pt、视觉条
    /// 310–314pt，时间顶 319pt、控制行 351–399pt（底留 2.7pt）。
    /// 任务书的「视觉条真落 290pt」在现有列预算里做不到：按模型算视觉条
    /// 290pt 就是 −15 那笔旧账（框顶 262pt），而实测行高比模型短约 43pt、
    /// 框顶实际约 219pt——290 这个数本身就是按错模型算出来的；要视觉条
    /// 在实测里真落 290pt，模型值须到约 333pt，列底会溢出到 426pt。
    /// 硬要求是「进度条不能挡着歌词」：新排布在模型里视觉条离下一句行框
    /// 底 33pt，按实测行高反推约 267–279pt、离下一句墨迹底（253pt）约
    /// 14–26pt，两种口径都零重叠；歌名/歌手/两句歌词位置一字不动。
    /// 纵向落点（基准，模型）：歌名顶 60、歌手 135、当前句 180、下一句 233、
    /// 进度条视觉条 310–314、时间 319、控制行 351–399（收在屏底之上）。
    /// 无曲目时：歌名「未在播放」、歌手占位文案、歌词行空串占位、时间 00:00 /
    /// 00:00、控制行 disabled——区域结构不塌、不留白。
    private func traditionalRightColumn(width: CGFloat, screenWidth: CGFloat, screenHeight: CGFloat, tier: PlayerTokens.PlayerSizeTier) -> some View {
        let h = screenHeight
        return VStack(alignment: .leading, spacing: 0) {
            Text(traditionalTitleText)
                .font(.system(size: 60 / 402 * h, weight: .bold)) // r44：歌名按大稿 v2 60pt 改大（/402 屏高；r39-3 的 56/590 作废）
                .foregroundStyle(albumText) // r39-2：歌名走专辑文字色
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: width, alignment: .leading)
                .padding(.top, 9 / 402 * h) // r44：歌名顶垫 9/402（顶 60pt）
            Text(traditionalArtistText)
                .font(.system(size: 30 / 402 * h)) // r44：歌手按大稿 v2 30pt 改大（r39-3 的 28/590 作废）
                .foregroundStyle(albumSecondaryText) // r39-2：歌手走专辑次要文字色
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: width, alignment: .leading)
                .padding(.top, 3 / 402 * h) // r44：歌手顶垫 3/402（顶 135pt）
            traditionalLyricLine(text: traditionalCurrentLyric, size: 40 / 402 * h, color: albumAccent, weight: .bold) // r44：当前句按大稿 v2 40pt 改大（r39-3 的 36/590 作废）
                .padding(.top, 8 / 402 * h) // r44：当前句顶垫 8/402（顶 180pt）
            traditionalLyricLine(text: traditionalNextLyric, size: 36 / 402 * h, color: albumSecondaryText) // r39-2：下一句走专辑次要文字色；r44：按大稿 v2 36pt 改大（r39-3 的 34/590 作废）
                .padding(.top, 5 / 402 * h) // r44：下一句顶垫 5/402（顶 233pt）
            PlayerProgressBar(tier: tier, fillColor: albumAccent, trackColor: albumText.opacity(0.78), dotColor: albumAccent) // r39-2：进度条填充/圆点走专辑强调色，轨道走专辑文字色（不透明度 0.78 与改前白 0.78 一致）
                .frame(width: width)
                .padding(.top, 5 / 402 * h) // r46-3：第 3 件——负顶垫 −15 改 +5/402：32pt 触摸框顶落在 282pt（模型）、框底视觉条 310–314pt，下一句行框底 277pt 之下、零重叠；时间/控制行顶垫同步让出 4pt/2pt，列底 399pt 不溢出
            HStack {
                Text(landscapeTimeText(store.progress))
                Spacer()
                Text(landscapeTimeText(store.duration))
            }
            .font(.system(size: 26 / 402 * h)) // r44：两端时间按大稿 v2 26pt 改大（r39-3 的 24/590 作废）
            .foregroundStyle(albumSecondaryText) // r39-2：两端时间走专辑次要文字色
            .frame(width: width)
            .padding(.top, 5 / 402 * h) // r46-3：第 3 件——时间顶垫 9→5/402（顶 319pt；省 4pt 让给进度条）
            traditionalControlRow(width: width, screenWidth: screenWidth, screenHeight: h)
                .padding(.top, 1 / 402 * h) // r46-3：第 3 件——控制行顶垫 3→1/402（顶 351pt；省 2pt 让给进度条，底 399pt）
        }
        .frame(width: width, alignment: .topLeading)
    }

    /// 右列歌名行（r37-2：只剩歌名，歌手另起一行 traditionalArtistText；
    /// r36 的「歌名 - 歌手」合行作废，按修正版施工图：歌名白粗体大字、
    /// 歌手小字在下）。无曲目时「未在播放」。
    private var traditionalTitleText: String {
        store.currentTrack?.title ?? "未在播放"
    }

    /// 右列歌手行（r37-2）：歌手名；没歌手时回落平台名（与竖屏 subtitleText
    /// 同规则）；无曲目时是选歌占位文案——行位不塌。
    private var traditionalArtistText: String {
        subtitleText
    }

    /// 横屏两端时间（r37-2）：零补齐 mm:ss（稿里 00:29 / 04:30）；
    /// PlayerTokens.formatDuration 是 m:ss（0:29），竖屏 dock 用它，横屏另起不改它。
    private func landscapeTimeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// 有效当前行（r35-7：从旧 landscapeEffectiveCurrent 原样搬来；还没开唱
    /// （-1）时从第一行起；越界时夹到末行；没歌词时调用方先判空，这里只保下标）。
    private var landscapeEffectiveCurrent: Int {
        guard !store.lyrics.isEmpty else { return 0 }
        if store.currentLyricIndex < 0 { return 0 }
        return min(store.currentLyricIndex, store.lyrics.count - 1)
    }

    /// 当前句 / 下一句歌词（r35-7）：只取有效当前行这一行与下一行；没歌词时空串、不编。
    private var traditionalCurrentLyric: String {
        guard !store.lyrics.isEmpty else { return "" }
        return store.lyrics[landscapeEffectiveCurrent].text
    }

    private var traditionalNextLyric: String {
        guard !store.lyrics.isEmpty else { return "" }
        let next = landscapeEffectiveCurrent + 1
        guard store.lyrics.indices.contains(next) else { return "" }
        return store.lyrics[next].text
    }

    /// 歌词行（r36 v2）：单行；空串时用一个空格占住行位（不塌掉下面行的位置）。
    /// 当前句稿里是粗体（f_lyr CJKB 24），下一句常规（f_lyr2 22）。
    private func traditionalLyricLine(text: String, size: CGFloat, color: Color, weight: Font.Weight = .regular) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 传统横屏控制行（r36 v2；r44 按批改大稿 v2 改大：五键中心距 80pt
    /// （80/874 × 屏宽），行高 48pt（48/402 × 屏高），图标/暂停字号 28pt
    /// （28/402 × 屏高；稿子图标半尺寸 s=14pt → 字形约 28pt）；
    /// r39-3 的中心距 92px（0.071875×屏宽）、行高/字号 48/590 屏高作废。
    /// 居中排布不动（稿子是左对齐，任务书只定了 80pt 步进、未定左偏移，
    /// 保持居中、见交回）：喜欢 | 上一首 |
    /// 暂停（大）| 下一首 | 模式。
    /// 全部专辑强调色图标（稿里同款红，r39-2 起走 albumAccent，不写死红）；
    /// 暂停是大号裸条（没有白圆底，与
    /// PlayerControlRow 的白圆大播放键不同）；没有队列入口、没有弹幕键
    /// （原生本来就没有弹幕键）；无曲目时整行 disabled。
    private func traditionalControlRow(width: CGFloat, screenWidth: CGFloat, screenHeight: CGFloat) -> some View {
        let pitch = 80 / 874 * screenWidth // r44：五键中心距 80/874×屏宽（基准 80pt）
        // r44：控制行 48 高、图标/暂停字号 28pt（均按大稿 v2：48/402、
        // 28/402 × 屏高；r39-3 的 48/590 屏高作废）。
        let iconSize = 28 / 402 * screenHeight
        let pauseSize = 28 / 402 * screenHeight
        let rowHeight = 48 / 402 * screenHeight
        return HStack(spacing: 0) {
            traditionalControlCell(pitch: pitch, height: rowHeight) {
                Button(action: { store.toggleLike() }) {
                    Image(systemName: store.isLiked ? "heart.fill" : "heart")
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundStyle(albumAccent)
                }
                .accessibilityLabel(store.isLiked ? "取消喜欢" : "喜欢")
            }
            traditionalControlCell(pitch: pitch, height: rowHeight) {
                Button(action: { store.previous() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: iconSize))
                        .foregroundStyle(albumAccent)
                }
                .accessibilityLabel("上一首")
            }
            traditionalControlCell(pitch: pitch, height: rowHeight) {
                Button(action: { store.togglePlay() }) {
                    if store.isLoading {
                        ProgressView()
                            .tint(albumAccent)
                    } else {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: pauseSize, weight: .semibold))
                            .foregroundStyle(albumAccent)
                            .offset(x: store.isPlaying ? 0 : 2)
                    }
                }
                .accessibilityLabel(store.isPlaying ? "暂停" : "播放")
            }
            traditionalControlCell(pitch: pitch, height: rowHeight) {
                Button(action: { store.next() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: iconSize))
                        .foregroundStyle(albumAccent)
                }
                .accessibilityLabel("下一首")
            }
            traditionalControlCell(pitch: pitch, height: rowHeight) {
                Button(action: { cycleTraditionalMode() }) {
                    Image(systemName: traditionalModeIconName)
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundStyle(albumAccent)
                }
                .accessibilityLabel("播放模式：\(traditionalModeTitle)，点按切换")
            }
        }
        .frame(width: width)
        .frame(height: rowHeight)
        .disabled(store.currentTrack == nil)
    }

    /// 控制行等宽格（r36 v2）：每键一个 pitch 宽，中心距就是 pitch。
    private func traditionalControlCell<Content: View>(pitch: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(width: pitch, height: height)
    }

    // MARK: - 传统横屏模式键：循环 → 单曲 → 随机（三态一键，与竖屏 dock 同一套状态机）

    /// 与 PlayerBottomDock.DockPlayMode / cycleDockMode 同一套状态机
    /// （只调现成的 cycleRepeatMode / setShuffled，不另造状态、不改
    /// PlayerBottomDock）：循环 → 单曲 → 随机 → 循环；顺序（off 且随机
    /// off）不在三态里，点按进循环。图标：循环 / 顺序 repeat、单曲 repeat.1、
    /// 随机 shuffle；三态都持久化（见 PlaybackStore）。
    private enum TraditionalPlayMode { case all, one, shuffle, off }

    private var traditionalMode: TraditionalPlayMode {
        if store.isShuffled { return .shuffle }
        switch store.repeatMode {
        case .all: return .all
        case .one: return .one
        case .off: return .off
        }
    }

    private var traditionalModeIconName: String {
        switch traditionalMode {
        case .all, .off: return "repeat"
        case .one: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }

    private var traditionalModeTitle: String {
        switch traditionalMode {
        case .all: return "循环"
        case .one: return "单曲"
        case .shuffle: return "随机"
        case .off: return "顺序"
        }
    }

    private func cycleTraditionalMode() {
        switch traditionalMode {
        case .all:
            store.cycleRepeatMode()
        case .one:
            store.setShuffled(true)
        case .shuffle:
            store.setShuffled(false)
            if store.repeatMode == .one {
                store.cycleRepeatMode()
                store.cycleRepeatMode()
            } else if store.repeatMode == .off {
                store.cycleRepeatMode()
            }
        case .off:
            store.cycleRepeatMode()
        }
    }

    /// 传统横屏底图（r36，第③件 + 21:21 壁纸）：
    /// 优先级：用户壁纸（照片/视频，BackgroundStore，与竖屏同一套；
    /// 照片 scaledToFill + 3pt 轻模糊，视频 LoopingVideoBackgroundView
    /// 静音循环——竖屏 background 的壁纸分支原样搬过来）>
    /// 专辑取色（AlbumTone，playerTone；没封面 / 取色失败时
    /// AlbumTone.fallback 深场）> 深色默认底。
    /// 固定死深红底作废（r35-7 的 traditionalBgTop/Bottom 已删）；
    /// 不许白色。底层永远垫一层取色渐变（壁纸文件万一读不到也不透黑）。
    /// 壁纸上另压一层黑 0.35（竖屏深色压暗的轻量版，红字在浅色
    /// 照片上仍可读；取色渐变不压——首页面板同款，专辑色原样透出）。
    /// 只做底色，不盖内容、不挡点按。
    private var traditionalLandscapeBackground: some View {
        ZStack {
            // r37-3：底层先垫纯黑——上面任何一层（取色渐变 / 壁纸）万一没盖住，
            // 露出来的也是黑不是白；竖屏 background 不动。
            Color.black
            LinearGradient(
                colors: [playerTone.a, playerTone.b, playerTone.c],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if backgroundStore.hasCustomBackground {
                if backgroundStore.mode == .image, let image = backgroundStore.backgroundImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .blur(radius: 3)
                } else if backgroundStore.mode == .video, let url = backgroundStore.videoFileURL {
                    LoopingVideoBackgroundView(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                Color.black.opacity(0.35)
            }
        }
        .allowsHitTesting(false)
        // r37-3：横屏底图忽略安全区（竖屏 background 早就有 ignoresSafeArea，
        // 横屏这支一直没加）：背景铺满整个横屏安全区（含左右边缘），
        // 返回键浮在背景上层，不留白条；壁纸 > 取色 > 深色底的优先级不动。
        .ignoresSafeArea()
    }


    // MARK: - 背景：r33 起分两支——设了壁纸用壁纸，没设走原来的封面底色

    /// 背景层（ZStack 最底层，body 里 `background` 先于内容放，
    /// 只做底色，永远不盖内容、不挡点按——本层 `.allowsHitTesting(false)`）。
    /// - 设了壁纸（`BackgroundStore.hasCustomBackground`，与首页同一判断）：
    ///   图片 → 沙盒图 `scaledToFill` 铺满 + 3pt 轻模糊（与首页
    ///   HomeBackgroundView 同值）；视频 → 复用首页的
    ///   `LoopingVideoBackgroundView`（AVPlayer 静音循环、
    ///   `resizeAspectFill` 铺满、播完回 0、切后台暂停，见 BackgroundView.swift，
    ///   本文件不另写播放器）。
    /// - 没设壁纸：原来的分支一字不动——有封面 = 模糊封面大图（blur 64 +
    ///   （r35-7：横屏传统模式不再走这里，见 traditionalLandscapeBackground，只剩竖屏用）
    ///   scale 1.25），无封面 = ink→黑渐变。
    /// 可读性蒙版（r39-2 起竖屏歌名/歌词/控制器按专辑 tone 走：深场白字、
    /// 浅场墨字；压暗层强度也跟 playerTone.isDark 走——深场保持原来两层
    /// （底色黑 0.52 + 纵向 0.40/透明/0.62 暗角），浅场减弱（底色 0.22 +
    /// 纵向 0.16/透明/0.28），让浅色封面透出来、深色字可读；有壁纸时再加
    /// 的那层也同步减弱（深场 0.18 → 浅场 0.08）。只动压暗强度，结构与
    /// 底图分支一字不动）。
    private var background: some View {
        ZStack {
            if backgroundStore.hasCustomBackground {
                if backgroundStore.mode == .image, let image = backgroundStore.backgroundImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .blur(radius: 3)
                } else if backgroundStore.mode == .video, let url = backgroundStore.videoFileURL {
                    LoopingVideoBackgroundView(url: url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            } else if let url = store.currentTrack?.coverURL {
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
            // r39-2：压暗 + 暗角强度跟 playerTone.isDark 走——深场
            // 保持原值（白字可读），浅场减弱（深色字压在浅色模糊封面上可读）。
            // r20 按截图再压暗一点：底色 0.45 → 0.52，下沿 0.55 → 0.62（深场值）。
            Color.black.opacity(playerTone.isDark ? 0.52 : 0.22)
            LinearGradient(
                colors: [
                    Color.black.opacity(playerTone.isDark ? 0.40 : 0.16),
                    Color.clear,
                    Color.clear,
                    Color.black.opacity(playerTone.isDark ? 0.62 : 0.28),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // r33：有自定义壁纸时再加一层黑 0.18（壁纸可能比模糊封面亮得多、
            // 花得多；只在壁纸支出现，不动原来无壁纸的亮度）。
            // r39-2：这层也跟 isDark 走，浅场减到 0.08。
            if backgroundStore.hasCustomBackground {
                Color.black.opacity(playerTone.isDark ? 0.18 : 0.08)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.42), value: store.currentTrack?.id)
        .animation(.easeOut(duration: 0.42), value: backgroundStore.mode)
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
    // 横屏顶栏同源不同形：横屏顶行是 Ø38 小圆钮（r29 task 7 起调
    // topBarCircleButton，见 landscapeLayout），动作与竖屏圆按钮一一对应；
    // （r35-6：旧文字胶囊顶行 topBarCapsuleButton 随 02/04/06 变体一起删）。
    // 顶栏位置见文件底
    // 「r22a 顶栏太靠下根因」：顶边走 key window 安全区真实值（59），
    // 紧贴状态栏下方，灵动岛同一行高度之下、只留一点点间距。
    //
    // r27 竖屏三钮 1:1（只改竖屏，横屏胶囊不动；不拿 App 现有的按钮尺寸）：
    // 参考图 3C9A94A6…（1206×2622 @3x，屏 402pt），PIL 实测（阈值 80/110
    // 两档行扫描 + 白字 bbox，见交回）：
    // - 三圆直径：左圆行 y=180/190 扫描 x 48–191、搜索圆 x 834–977、
    //   齿轮圆 x 1014–1157，弦拟合 Ø≈145–146px → 48.3–48.7pt，
    //   统一取整 49pt（r27 实测值；r29 task 5 改小一档 → 44pt、r33 再改小
    //   一档 → 38pt（与横屏同值），见下面常量，三档同一值，不再走 PlayerTokens.topBarButton 的 44/48/52；
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
    //   顶边 39 不动。r33：直径 38pt 后图标字号 = 38 × 0.47 ≈ 17.9pt，
    //   字形高约 14.3–17.0pt；圆心 = 39 + 19 = 58pt，顶边 39 不动。
    // - 注意（r27 追加，v4 合成图已批）：任务二原图的左图标实测是向左
    //   尖角 "<"（31×53px），但用户批的 v4 合成图（build-player-v4-composite.py）
    //   把返回画成了向下 chevron ⌄（折线 [97,169]→[122,195]→[147,169]，
    //   线宽 7px，即 50×26px = 16.7×8.7pt），以 v4 为准：返回图标用
    //   chevron.down。任务书给的 Ø136px / 搜索圆心 960px 与实测（Ø≈146px /
    //   905.5px）不符，仍按实测落数（见上）。

    /// r29 task 5：竖屏顶栏三钮统一直径 44pt（r27 实测 49pt，改小一档；
    /// 见上面 topBar 注释；三档同一值，不走 PlayerTokens.topBarButton）。
    /// r33：44 → 38pt（横屏传统模式 r35-7 不再用圆钮，竖屏三钮仍是 38）；
    /// 图标因子共用 0.47（见 topBarCircleButton），
    /// 图标 20.7 → 17.9pt，与横屏一致；顶边 39 不动，圆心 61 → 58pt；
    /// 右侧两钮 HStack 间距 12 不动（钮间空隙 16 → 22pt，不挡）。
    private static let portraitTopBarButtonDiameter: CGFloat = 38

    private func topBar(tier: PlayerTokens.PlayerSizeTier) -> some View {
        _ = tier // r33：竖屏三钮直径固定 38pt（r29 task 5 的 44pt 再小一档，与横屏同值），不再按 tier 分档。
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

    /// 顶栏圆形毛玻璃按钮：`.ultraThinMaterial` 圆形，直径由调用方传
    /// （r33 起竖屏横屏同为 38pt；r29 task 5 是 44pt，r27 实测 49pt，
    /// 见 topBar 注释）；图标字号 = 直径 × 0.47（Ø38 时 17.9pt；
    /// Ø44 时 20.7pt；r27 Ø49 时 23pt，实测图标 17.7–21.7pt，
    /// 旧 0.42 偏小；SF 图标字形高约 0.8–0.95em）。
    private func topBarCircleButton(
        systemName: String,
        diameter: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.47, weight: .semibold))
                .foregroundStyle(albumText) // r39-2：竖屏顶栏三钮图标走专辑文字色
                .frame(width: diameter, height: diameter)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(albumText.opacity(0.25), lineWidth: 0.5)) // r39-2：描边同色
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
    private func lyricsZone(tier: PlayerTokens.PlayerSizeTier, width: CGFloat, minHeight: CGFloat? = nil, albumTone: AlbumTone = .fallback) -> some View {
        ZStack {
            // tier 直传，不走 LyricsZoneView 的 UIScreen 自算：竖屏自算与调用方
            // 同档，横屏必须按高取档（landscapeTier），自算会按宽 874 错取 large。
            // r39-2：专辑 tone 直传，竖屏歌词当前行/翻译行按专辑换色。
            LyricsZoneView(tier: tier, albumTone: albumTone)
            if showQueue {
                QueuePanelView(onClose: { showQueue = false }, albumTone: playerTone) // r39-2：队列面板接专辑 tone
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


    // MARK: - 歌名 / 歌手 + 状态角标 / 播放失败原因


    /// 状态行是否真的占高（r26）：失败原因文案，或至少一个角标（试听/网盘）
    /// 时为真。只按可见内容判定——有曲目但角标条件不成立时角标行整行
    /// 不渲染，不计入（r29：实际音质角标已删，见 statusCapsules；r31：
    /// 提示音角标已删；该瞬态仍走旧 8/10 间距，不溢出，见文件底 r26 总账注）。
    private var hasStatusRow: Bool {
        if store.errorMessage != nil { return true }
        guard store.currentTrack != nil else { return false }
        return store.currentTrack?.isTrial == true || store.currentVia == "cloud"
    }




    /// 副标题（r22k：审计图 P4 只写歌名 + 歌手，专辑不进副标题；
    /// 没歌手时回落平台名，不编假数据）。
    private var subtitleText: String {
        guard let track = store.currentTrack else { return "从首页或搜索页选一首歌开始" }
        return track.artist.isEmpty ? track.platform : track.artist
    }

    /// 状态角标：只在有内容时出现 —— 试听（r31：提示音角标已删）与网盘
    /// （r31-clouddrive：via == cloud 时「网盘」胶囊，与官方区分开；和试听
    /// 同一行）。
    /// 取链失败的原因由下面的
    /// error 行明示，不静默。r29：歌名下方中间的实际音质角标已删（用户真机
    /// 报「中间的杜比全景声显示也删除」），音质入口只剩底部第 3 排的音质
    /// 芯片（PlayerBottomDock，点开 9 档选择器），显示
    /// store.servedQualityText（实际档位名 → 音源原文 → 「未知」）；
    /// r31 音质系统替换后 actualQuality 取链与状态本身走新编排
    /// （PlaybackStore.resolveURL：播放来源三段 + 单曲覆盖），
    /// 本页仍不显示音质角标。
    /// 无曲目时什么都不显示（空态只有「未在播放」+ 副标题）。
    /// r26：compactStyle 只由竖屏 artistBlock 在 compact 档传 true（角标行
    /// 压缩：胶囊字 11→10、纵向 padding 2→1，行上间距 4→2；角标行总增量
    /// 22 → 约 17，省约 5pt，见文件底 r26 总账）。横屏传统模式（r35-7）
    /// 不再调 statusCapsules（只显示当前 / 下一句歌词，不要角标行）；其余档传 false。
    /// r27：largeStyle 只由竖屏 artistBlock 在 large 档传 true，角标行同款
    /// 压缩（22 → 约 17，省约 5pt；失败原因行上间距 4→2，约 20 → 约 18），
    /// 与 artistBlock 间距（large + 有状态行 8/10 → 4/4）合计省 15pt，
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
                // 动作。内层手势优先于外层 titleOnlyBlock 的点歌名开队列，
                // 点红字只弹登录，不会同时打开队列。
                .onTapGesture {
                    if let platform = store.loginPromptPlatform {
                        loginTarget = LoginSheetTarget(platform: platform)
                    }
                }
        } else if store.currentTrack != nil {
            // r29：实际音质角标已删（只删显示，取链/状态不动）；r31：提示音
            // 角标已删。角标行只剩试听 + 网盘（r31-clouddrive：currentVia ==
            // "cloud" 时「网盘」胶囊，和试听同一行）；条件都不成立时整行不
            // 渲染——旧代码空 HStack + 上间距会留 6pt 幽灵高，删角标后这是常态
            // （普通曲目），必须收掉。
            if store.currentVia == "cloud" || store.currentTrack?.isTrial == true {
                HStack(spacing: 6) {
                    if store.currentVia == "cloud" {
                        statusCapsule("网盘", compactStyle: squeeze)
                    }
                    if store.currentTrack?.isTrial == true {
                        statusCapsule("试听", compactStyle: squeeze)
                    }
                }
                .padding(.top, squeeze ? 2 : 4)
            }
        }
    }

    private func statusCapsule(_ text: String, compactStyle: Bool = false) -> some View {
        Text(text)
            .font(.system(size: compactStyle ? 10 : 11, weight: .medium))
            .foregroundStyle(albumText) // r39-2：角标文字走专辑文字色
            .padding(.horizontal, 7)
            .padding(.vertical, compactStyle ? 1 : 2)
            .background(albumText.opacity(0.16)) // r39-2：角标底同色（不透明度与改前白 0.16 一致）
            .clipShape(Capsule())
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
// （实账）。r35-6：02/04/06 变体已删，本段旧底数字不再对应任何现行版式，只留作历史，
// 不要拿本段数去核默认版式。
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
//   0.47，图标约 17.9pt；r33 起竖屏也是 Ø38，两边同值），只留图标不留文字，
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
// r33 播放页布局（本轮，只改默认 landscapeLayout + 竖屏顶栏直径，
// 02/04/06 变体、竖屏其他段、CoverFlowView.swift 一字不动；
// 驱动断言建议见交回，不改 verification/*.cjs）：
// - 横屏左列 260 → 320pt：实测原图（1206×555，1.38px/pt，在播
//   《爱你 (把我们衣服纽扣互扣)》/ 徐俊雅）两侧封面只露约 53pt
//   （列半宽 130 − 中央张半宽 77，左约 90px、右约 85px）；320 后
//   列半宽 160 不再卡边，两侧各露约 75pt（侧张中心 ±100.7、投影
//   半宽约 52，外缘约 ±152）；中央张 154 不动，仍是最大一张；
//   右列歌词 539 → 479；歌名 13 字缩放因子约 0.77 → 0.94（自然宽约
//   339pt），仍完整。
// - 横屏封面框 162 → 154pt（= 方形本身，倒影全裁）+ 标题上间隙
//   6 → 4pt，左列 222 → 212；省下的 10pt 全给控制行–进度条间距：
//   上间隙 12 → 23pt。暂停钮底 337 → 326pt，进度条细条顶仍在 349pt
//   不动（触摸区 349–381 + 底部安全区 21 = 402），间距 12 → 23pt，
//   播放头圆点顶约 346pt，离暂停钮底约 20pt；顶行/中段上间隙/控制行/
//   进度条触摸区/底部安全区一字不动。右上搜索/设置钮不动，不挡东西。
// - 高账（874×402）：10 + 38 + 6 + 214（中段，左列 212、余 2pt）
//   + 58 + 23 + 32 + 21 = 402（安全区 21 时正好；安全区 0 时余 21
//   归弹性歌词区）；歌词区内容 206 / 227，均 ≥ 最小高 100。
// - 残留：状态行（试听/演示/取链失败）+22pt 时左列 212 → 234，
//   安全区 21 时超约 20pt（r29 是 19pt，+1pt）；安全区 0 时
//   401 ≤ 402 仍不超。控制行完整可见，进度条触摸区约 10pt 在屏内。
// - 竖屏顶栏三钮 44 → 38pt（portraitTopBarButtonDiameter），与横屏
//   同值；图标因子共用 0.47 不动，图标 20.7 → 17.9pt；顶边 39 不动，
//   圆心 61 → 58pt；右侧两钮间距 12 不动，钮间空隙 16 → 22pt。
//   竖屏三档固定段总账各 −6pt（r29 task 5 段落的 44 仍是当时值）。
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
