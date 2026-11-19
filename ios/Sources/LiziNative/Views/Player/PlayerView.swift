import SwiftUI

/// 播放页（r20 截图布局 1:1，对照 01:14 播放页截图；r21b 只修布局锚定；
/// r22a：顶栏最终版（左返回 + 搜索 + 齿轮进舞台，位置上移到紧贴状态栏
/// 下方）+ 横屏宽度（屏宽 + key window 安全区，铺满 874）+ YRC 尖括号
/// 变体解析（酷狗新接口），竖屏其他部分不动。顶栏纠正（05:30 用户标注截图
/// 为准）：r22a 的「九宫格进舞台 + 齿轮开调节面板」做法作废，九宫格只在
/// 舞台页，播放页顶栏不再弹舞台调节面板；齿轮是控制舞台按钮，进舞台页。
/// r22k：按两张审计图核对——控制行竖屏是随机/爱心/上一首/播放/下一首/循环、
/// 横屏是随机/三条杠/上一首/播放/下一首/循环，无 AirPlay（PlayerDockView.swift）；
/// 队列入口竖屏点歌名块、横屏点三条杠，副标题只留歌手；
/// 顶栏位置（顶边 59）、横屏铺满、YRC 解析一字未动；顶栏图标与接线
/// 按本次纠正改（返回 + 搜索 + 齿轮进舞台）。
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
/// → 歌名 / 歌手 → 控制行（`PlayerControlRow`）→ 最底部细进度条
/// （`PlayerProgressBar`，满宽，留 Home Indicator 安全区）。
///
/// 依赖（r20 三工人分工，本文件只引用、不定义）：
/// - `LyricsZoneView`：工人 B 在 `LyricsPanelView.swift` 里新建——截至交回时
///   仍未落地，本文件先按任务书给的名字引用，集成时等工人 B。
/// - `PlayerControlRow(tier:)` / `PlayerProgressBar(tier:)`：
///   工人 C 已在 `PlayerDockView.swift` 里落地（r22 定稿：控制行竖屏是
///   随机 / 爱心 / 上一首 / 播放 / 下一首 / 循环，横屏是随机 / 三条杠 /
///   上一首 / 播放 / 下一首 / 循环，无 AirPlay；队列入口竖屏点歌名块
///   （见 titleBlock）、横屏点三条杠；细条无时间数字，拖动 seek，播放头是圆点）。
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
struct PlayerView: View {
    @EnvironmentObject private var store: PlaybackStore
    @EnvironmentObject private var navigation: AppNavigation

    /// 队列面板是否打开：控制行最左列表图标的回调切它（再点一次关上）。
    @State private var showQueue = false

    /// 歌词区是否展开（r20 集成接线：LyricsZoneView 的 isExpanded 经 @Binding
    /// 接到这里；展开时封面流收小到一半、腾出的空间归弹性歌词区）。
    @State private var lyricsExpanded = false

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
                    landscapeLayout(geo: geo, tier: tier)
                } else {
                    portraitLayout(geo: geo, tier: tier)
                }
            }
            .frame(width: screenSize.width, height: screenSize.height, alignment: .topLeading)
            .onAppear { Self.logGeometry(geo) }
            .onChange(of: geo.size) { _ in Self.logGeometry(geo) }
        }
        // 禁缩放：SwiftUI 默认没有捏合缩放；这里明确不加任何缩放手势。
        .navigationBarHidden(true)
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

    /// 竖屏布局：段顺序与 r20 / 壳版窄屏一致（顶栏 → 封面流 → 歌词区 →
    /// 歌名块 → 控制行 → 最底部细进度条），只改锚定方式：
    /// - 每一行都给死宽度（内容宽 = 屏宽 − 2×16，进度条满屏宽）：行的布局宽
    ///   由 frame 定，不由内容理想宽定——再长的单行歌名/副标题/歌词也只能在
    ///   行宽里截断，撑不大 VStack。
    /// - 外层 VStack 死宽高 + .topLeading：不居中、不下拉。
    private func portraitLayout(geo: GeometryProxy, tier: PlayerTokens.PlayerSizeTier) -> some View {
        let contentWidth = geo.size.width - PlayerTokens.sp4 * 2
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar(tier: tier)
                    .frame(width: contentWidth)
                // 歌词展开时封面收小：整体缩到 0.55（顶部锚定），布局高同步
                // 压到轨道高 × 0.55，腾出的空间归弹性歌词区；收起时还原。
                // 只缩放渲染 + 压布局高，不动 CoverFlowView 内部尺寸
                // （它只按 tier 定尺寸，见文件头注释）。
                CoverFlowView(tier: tier)
                    .scaleEffect(lyricsExpanded ? 0.55 : 1, anchor: .top)
                    .frame(width: contentWidth, height: lyricsExpanded
                           ? PlayerTokens.coverTrackHeight(tier) * 0.55
                           : PlayerTokens.coverTrackHeight(tier))
                    // 外框压高后内部轨道（定高 trackHeight）会溢出，
                    // .clipped() 裁掉溢出部分（缩放后内容只占上半 55%，
                    // 裁掉的是空区）；布局高以外框为准，空间真正腾出。
                    .clipped()
                    .animation(.easeInOut(duration: 0.3), value: lyricsExpanded)
                    .padding(.top, 6)
                lyricsZone(tier: tier, width: contentWidth)
                titleBlock(tier: tier)
                    .frame(width: contentWidth)
                PlayerControlRow(tier: tier)
                    .frame(width: contentWidth)
            }
            .padding(.horizontal, PlayerTokens.sp4)
            // 顶部走 key window 的安全区真实值（r22a：geo.safeAreaInsets.top
            // 在真机上是 124 不是 59，顶栏被顶到 124 才出现——见文件底
            // 「r22a 顶栏太靠下根因」。windowTopInset 夹到 ≤59，顶栏顶边回 59，
            // 紧贴状态栏下方，灵动岛同一行高度之下、只留一点点间距；弹性歌词区
            // 会把省下的 65pt 吃掉（180 → 245），进度条仍贴底）。
            .padding(.top, Self.windowTopInset)
            // 细进度条：满宽（在横向 padding 的外层），与控制行隔 12，
            // 底部留 Home Indicator 安全区（有 Home Indicator 34，无则 0）。
            PlayerProgressBar(tier: tier)
                .frame(width: geo.size.width)
                .padding(.top, 12)
                .padding(.bottom, geo.safeAreaInsets.bottom)
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }

    // MARK: - 横屏：顶区（胶囊顶栏 + 左上歌名 + 居中封面流）→ 居中歌词区 → 底部控制行 + 进度条

    /// 横屏布局（r22 重排：旧左右分栏作废——歌名在左列压到歌词上重叠。
    /// 新图纸 ~/workspace/lizi-player-template-landscape.png 5 条：
    /// 1 歌名放左上（返回胶囊旁边、封面流左侧），歌名 + 歌手左对齐，不压歌词；
    /// 2 歌词放中间，居中干净显示，当前行高亮，上下行变淡；
    /// 3 横屏顶栏用文字胶囊按钮（返回 / 搜索 / 控制），竖屏仍用圆形图标；
    /// 4 封面流居中顶部，中间最大，两侧倾斜；
    /// 5 横屏铺满整屏，进度条满宽，底部留安全区。
    /// 结构（纵向一段到底）：顶区一行（返回胶囊 + 左上歌名 220 + 居中封面流
    /// + 搜索胶囊 + 控制胶囊，顶对齐，行高 = 封面轨道 158.4）→ 弹性歌词区
    /// （满 contentWidth 居中，最小高 100，剩下的空间全归它）→ 控制行居中
    /// （三条杠 / 上一首 / 播放 / 下一首，点三条杠开队列）→ 最底部细进度条
    /// （满 contentWidth，底部留 Home Indicator 安全区）。
    /// 高账（874×402）：顶区 158.4 + 歌词区上间隙 8 + 歌词区（≥100，底部安全区
    /// 0 时实得 131.6、21 时实得 110.6）+ 控制行 60（compact）+ 间隙 12
    /// + 进度条 32（触摸区）+ 底部安全区（0 或 21）= 402，刚好。
    /// 宽度（r22a 根因，见文件底）：屏宽走 UIScreen.main.bounds.width（874），
    /// 两侧走 key window 安全区（landscapeSideInsets，岛侧 59、另一侧 0）；
    /// HStack = 左侧 spacer + 内容列 + 右侧 spacer，总宽恒 = 屏宽。
    /// 歌名块宽 220、内容裁在框内（.clipped()），再长的标题/状态角标也漫不进
    /// 封面流；歌名块与歌词区上下分段，不再同行重叠（旧 bug：用户 05:32 截图
    /// 歌名压在歌词上，歌名该放的位置是空的）。
    /// 横屏封面不随歌词展开再缩：展开只切换歌词区折叠 / 完整，封面保持 0.8。
    /// 横屏分档按高取档：landscapeTier = 按高 402 取档 → standard；胶囊 /
    /// 歌名 / 控制行再降一档用 compact（44/28/60），才塞得进 402 高。
    private func landscapeLayout(geo: GeometryProxy, tier: PlayerTokens.PlayerSizeTier) -> some View {
        let landscapeTier = PlayerTokens.sizeTier(
            for: CGSize(width: geo.size.height, height: geo.size.width),
            topInset: geo.safeAreaInsets.top)
        let compactTier = PlayerTokens.PlayerSizeTier.compact
        let coverScale: CGFloat = 0.8
        let coverTrack = PlayerTokens.coverTrackHeight(landscapeTier) * 198 / 254 * coverScale
        let titleWidth: CGFloat = 220
        let lyricsMinHeight: CGFloat = 100
        // r22a：横屏宽度唯一口径。屏宽 + key window 两侧安全区（见文件底注释）；
        // 顶区 / 歌词区 / 控制行 / 进度条四行全用 contentWidth；HStack 三段
        // （左 spacer + 内容列 + 右 spacer）总宽恒 = 屏宽，行宽 = 容器宽，居中偏归零。
        let screenWidth = UIScreen.main.bounds.width
        let screenHeight = UIScreen.main.bounds.height
        let (leadingInset, trailingInset) = Self.landscapeSideInsets
        let contentWidth = screenWidth - leadingInset - trailingInset
        return HStack(spacing: 0) {
            Color.clear.frame(width: leadingInset)
            VStack(spacing: 0) {
                // 顶区：返回胶囊 + 左上歌名 + 居中封面流 + 搜索胶囊 + 控制胶囊。
                // 顶对齐：胶囊 44、歌名块约 54（有状态角标时 80），都比封面轨道矮，
                // 行高由封面轨道（158.4）定；封面流吃中间剩余宽、居中显示。
                HStack(alignment: .top, spacing: 12) {
                    topBarCapsuleButton(
                        systemName: "chevron.left",
                        text: "返回",
                        height: PlayerTokens.topBarButton(compactTier)
                    ) {
                        navigation.show(.home)
                    }
                    .accessibilityLabel("返回首页")
                    // 横屏歌名块：左对齐（见 landscapeTitleTexts），宽 220 裁在框内；
                    // 横屏队列入口是控制行三条杠，不再点歌名块（竖屏仍点歌名块）。
                    landscapeTitleTexts(tier: compactTier)
                        .frame(width: titleWidth)
                        .clipped()
                    CoverFlowView(tier: landscapeTier, isCompact: true)
                        .scaleEffect(coverScale, anchor: .top)
                        .frame(maxWidth: .infinity, height: coverTrack)
                        .clipped()
                    topBarCapsuleButton(
                        systemName: "magnifyingglass",
                        text: "搜索",
                        height: PlayerTokens.topBarButton(compactTier)
                    ) {
                        // 搜索页走 App 现有的搜索导航路由，不新造。
                        navigation.show(.search)
                    }
                    .accessibilityLabel("搜索")
                    topBarCapsuleButton(
                        systemName: "gearshape",
                        text: "控制",
                        height: PlayerTokens.topBarButton(compactTier)
                    ) {
                        // 控制胶囊就是齿轮那个舞台控制按钮（点进舞台页），
                        // 只是横屏画成文字胶囊；不进设置页、不在播放页弹调节面板。
                        navigation.show(.stage())
                    }
                    .accessibilityLabel("控制舞台")
                }
                .frame(width: contentWidth)
                // 歌词区：纵向唯一弹性段（满 contentWidth 居中；最小高 100，
                // 3 行歌词约 70–80，实得 111–132，见文件头高账）。
                lyricsZone(tier: landscapeTier, width: contentWidth, minHeight: lyricsMinHeight)
                PlayerControlRow(tier: compactTier, showsQueueButton: true, onOpenQueue: { showQueue.toggle() })
                    .frame(width: contentWidth)
                PlayerProgressBar(tier: tier)
                    .frame(width: contentWidth)
                    .padding(.top, 12)
                    .padding(.bottom, geo.safeAreaInsets.bottom)
            }
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

    // MARK: - 顶栏：左圆形毛玻璃返回（只有 <，无「返回」文字）；右两个同样
    // 圆形毛玻璃按钮（搜索 + 齿轮）。顶栏纠正（05:30 用户标注截图为准，
    // r22a 的九宫格做法作废）：搜索 magnifyingglass 回到播放页顶栏，点开
    // 搜索页（走 App 里现有的搜索导航路由 navigation.show(.search)，不新造）；
    // 齿轮 gearshape 是「控制舞台」按钮，点进舞台页（走 AppNavigation .stage()，
    // 不带 formId，读用户保存的形态）；进了舞台页，舞台页自己的齿轮再调当前
    // 舞台效果。齿轮绝不进 App 设置页（设置页只从首页齿轮进），也不在播放页
    // 直接弹舞台调节面板（StageSettingsView 只在 StageView 里调）。
    // 九宫格 square.grid.2x2（选舞台）只在舞台页里，不在播放页顶栏。
    // 左返回 chevron.left 不变。竖屏顶栏正好 3 个圆形图标，不多加；
    // 横屏顶栏同源不同形：横屏顶区调 topBarCapsuleButton（文字胶囊：返回 /
    // 搜索 / 控制），动作与竖屏圆按钮一一对应。顶栏位置见文件底
    // 「r22a 顶栏太靠下根因」：顶边走 key window 安全区真实值（59），
    // 紧贴状态栏下方，灵动岛同一行高度之下、只留一点点间距。

    private func topBar(tier: PlayerTokens.PlayerSizeTier) -> some View {
        HStack {
            topBarCircleButton(
                systemName: "chevron.left",
                diameter: PlayerTokens.topBarButton(tier)
            ) {
                navigation.show(.home)
            }
            .accessibilityLabel("返回首页")

            Spacer()

            HStack(spacing: 12) {
                topBarCircleButton(
                    systemName: "magnifyingglass",
                    diameter: PlayerTokens.topBarButton(tier)
                ) {
                    // 搜索页走 App 现有的搜索导航路由，不新造。
                    navigation.show(.search)
                }
                .accessibilityLabel("搜索")

                topBarCircleButton(
                    systemName: "gearshape",
                    diameter: PlayerTokens.topBarButton(tier)
                ) {
                    // 控制舞台：进舞台页（.stage()，读保存的形态）；不进设置页，
                    // 不在播放页弹调节面板——面板只在舞台页里由它自己的齿轮开。
                    navigation.show(.stage())
                }
                .accessibilityLabel("控制舞台")
            }
        }
    }

    /// 顶栏圆形毛玻璃按钮：`.ultraThinMaterial` 圆形，直径走
    /// `PlayerTokens.topBarButton(tier)`，图标按直径等比缩放。
    private func topBarCircleButton(
        systemName: String,
        diameter: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: diameter * 0.42, weight: .semibold))
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
    private func topBarCapsuleButton(
        systemName: String,
        text: String,
        height: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .semibold))
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
            LyricsZoneView(tier: tier, isExpanded: $lyricsExpanded)
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

    // MARK: - 歌名 / 歌手 + 状态角标 / 播放失败原因

    private func titleBlock(tier: PlayerTokens.PlayerSizeTier) -> some View {
        titleTexts(tier: tier)
        // 段间距与工人 C 总账对齐：歌词区 → 歌名块 8，歌名块 → 控制行 10。
        .padding(.top, 8)
        .padding(.bottom, 10)
        // r22k：点歌名块打开队列（控制行按审计图改成星标/上一首/播放/
        // 下一首/AirPlay 后，队列列表按钮没位置了；队列入口改到这里，
        // 面板仍只盖住歌词区，见 lyricsZone）。
        .contentShape(Rectangle())
        .onTapGesture { showQueue.toggle() }
        .accessibilityHint("点按打开播放队列")
    }

    /// 歌名 / 歌手 + 状态角标（无段间距的本体）：竖屏 titleBlock 在外面加
    /// 8/10 段间距；横屏左列总高账紧张（见 landscapeLayout），直接用本体、
    /// 段间距由调用方另给 4。内容高：compact 档歌名 28×1.25 + 2 + 副标题
    /// 13×1.3 = 54，状态角标行有内容时再 +22 = 76。
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
            statusCapsules
        }
    }

    /// 副标题（r22k：审计图 P4 只写歌名 + 歌手，专辑不进副标题；
    /// 没歌手时回落平台名，不编假数据）。
    private var subtitleText: String {
        guard let track = store.currentTrack else { return "从首页或搜索页选一首歌开始" }
        return track.artist.isEmpty ? track.platform : track.artist
    }

    /// 状态角标：只在有内容时出现 —— 实际音质（显示 = 实际返回档位，绝不显示
    /// 请求档位）、试听、演示音。取链失败的原因由下面的 error 行明示，不静默。
    /// 无曲目时什么都不显示（空态只有「未在播放」+ 副标题）。
    @ViewBuilder
    private var statusCapsules: some View {
        if let message = store.errorMessage {
            Text(playFailureText(for: message))
                .font(.system(size: PlayerTokens.textXs))
                .foregroundStyle(Color.red.opacity(0.85))
                .padding(.top, 4)
        } else if store.currentTrack != nil {
            HStack(spacing: 6) {
                if let quality = store.actualQuality {
                    statusCapsule(quality.displayName)
                }
                if store.currentTrack?.isTrial == true {
                    statusCapsule("试听")
                }
                if store.isDemo {
                    statusCapsule("演示音")
                }
            }
            .padding(.top, 4)
        }
    }

    private func statusCapsule(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(PlayerTokens.playerForeground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.16))
            .clipShape(Capsule())
    }

    /// 横屏左上歌名块（r22 横屏重排）：与 titleTexts 同内容（歌名 + 歌手 +
    /// 状态角标），只改对齐为左对齐（歌名 + 歌手左对齐，不居中）；段间距与
    /// 点按都不在这里——调用方给宽 220 + .clipped()，队列入口是控制行三条杠。
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
            statusCapsules
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
// 段间距已按该总账对齐：顶栏→封面 6，封面→歌词区 8，歌词区→歌名块 8，
// 歌名块→控制行 10，控制行→进度条 12。歌名块高 = titleSize×1.25 + 2
// + subtitleSize×1.3；状态角标行（音质/试听/演示）有内容时再 +22。
// 进度条按外框 32 计（视觉细条 4，触摸区 32，见 PlayerProgressBar.touchHeight），
// 不是 4；歌词区展开时封面收小一半（见 lyricsExpanded），总账只会更宽松。）
//
// - compact（375×667 SE 最短屏，topInset 20，底部 0）：
//   20 + 44 + 6 + 232 + 8 + 150 + 8 + 54 + 10 + 60 + 12 + 32 + 0 = 636 ≤ 667，
//   余 31（歌词区实得 150 + 31 = 181）；状态角标 +22 → 658 ≤ 667 仍过。
//   同档 mini（375×812，topInset 50，底部 34）：700 ≤ 812。
// - standard（402×874 用户真机 iPhone 16 Pro，topInset 59，底部 34）：
//   59 + 48 + 6 + 254 + 8 + 180 + 8 + 60 + 10 + 68 + 12 + 32 + 34 = 779 ≤ 874，
//   余 95（歌词区实得 180 + 95 = 275）；状态角标 +22 → 801 ≤ 874 仍过。
//   同档 390×844（topInset 47）：767 ≤ 844。
// - large（430×932，topInset 59，底部 34）：
//   59 + 52 + 6 + 280 + 8 + 210 + 8 + 67 + 10 + 76 + 12 + 32 + 34 = 854 ≤ 932，
//   余 78（歌词区实得 210 + 78 = 288）。
// 三档全未超高。最短屏 compact 带状态角标也只到 658/667，
// 歌词区最少也有 150（3 行歌词最少约 90），没有一档会挤爆。
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
// MARK: - r21b 根因（竖屏右移，像素实测钉死）
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
