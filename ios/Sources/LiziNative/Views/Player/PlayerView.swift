import SwiftUI

/// 播放页（r20 截图布局 1:1，对照 01:14 播放页截图；r21b 只修布局锚定）。
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
/// - `PlayerControlRow(tier:onOpenQueue:)` / `PlayerProgressBar(tier:)`：
///   工人 C 已在 `PlayerDockView.swift` 里落地（控制行最左是列表图标，点它
///   调 `onOpenQueue`；细条无时间数字，拖动 seek）。
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
            ZStack(alignment: .topLeading) {
                background
                    .frame(width: geo.size.width, height: geo.size.height)
                if isLandscape {
                    landscapeLayout(geo: geo, tier: tier)
                } else {
                    portraitLayout(geo: geo, tier: tier)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
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
                PlayerControlRow(tier: tier, onOpenQueue: { showQueue.toggle() })
                    .frame(width: contentWidth)
            }
            .padding(.horizontal, PlayerTokens.sp4)
            // 顶部走 safeAreaInsets：刘海 47 / 灵动岛 59 / 无刘海 20，
            // 父容器若已扣过安全区这里就是 0，不会双倍 padding。
            .padding(.top, geo.safeAreaInsets.top)
            // 细进度条：满宽（在横向 padding 的外层），与控制行隔 12，
            // 底部留 Home Indicator 安全区（有 Home Indicator 34，无则 0）。
            PlayerProgressBar(tier: tier)
                .frame(width: geo.size.width)
                .padding(.top, 12)
                .padding(.bottom, geo.safeAreaInsets.bottom)
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }

    // MARK: - 横屏：左右两栏（左：封面 + 歌名 + 控制行；右：歌词区满高）

    /// 横屏布局（r21b 新分支；r20 没有横屏布局，竖屏纵向总高约 779pt 在横屏
    /// 约 381pt 可用高里放不下，才出现「横屏什么都没有」）。
    /// 几何取壳版宽屏 `.now__stage` 的左右分栏（封面列 + 歌词列 1fr、居中），
    /// 按手机横屏 874×402 收窄：
    /// - 顶栏满宽一行（44 compact 按钮）；底部细进度条满宽一行。
    /// - 中间行高 306：左列宽 220（封面 + 歌名 + 控制行），右列歌词区吃剩余宽。
    /// - 横屏分档按高取档：landscapeTier = 按高 402 取档 → standard；顶栏 /
    ///   歌名 / 控制行再降一档用 compact（44/28/60），才塞得进 402 高。
    /// - 封面用 r19 收小档（isCompact：单张 148 / 轨道 198）再 ×0.8 → 轨道
    ///   约 158；左列超出的侧封面由 .clipped() 裁在列宽里，不漫进歌词列。
    /// - 灵动岛在左 / 在右：外层统一扣 geo.safeAreaInsets.leading/trailing，
    ///   两边都顾；竖屏这两项是 0，同一套代码。
    /// - 横屏封面不随歌词展开再缩（右列歌词区已是满高 306）：展开只切换歌词区
    ///   折叠 / 完整，封面保持 0.8。
    private func landscapeLayout(geo: GeometryProxy, tier: PlayerTokens.PlayerSizeTier) -> some View {
        let landscapeTier = PlayerTokens.sizeTier(
            for: CGSize(width: geo.size.height, height: geo.size.width),
            topInset: geo.safeAreaInsets.top)
        let compactTier = PlayerTokens.PlayerSizeTier.compact
        let middleHeight: CGFloat = 306
        let leftColumnWidth: CGFloat = 220
        let coverScale: CGFloat = 0.8
        let coverTrack = PlayerTokens.coverTrackHeight(landscapeTier) * 198 / 254 * coverScale
        let sideInsets = geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
        let lyricsWidth = geo.size.width - sideInsets - leftColumnWidth - 16
        return VStack(spacing: 0) {
            topBar(tier: compactTier)
                .frame(width: geo.size.width - sideInsets)
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 0) {
                    CoverFlowView(tier: landscapeTier, isCompact: true)
                        .scaleEffect(coverScale, anchor: .top)
                        .frame(width: leftColumnWidth, height: coverTrack)
                        .clipped()
                        .padding(.top, 4)
                    // 横屏歌名块不用 portrait 的 8/10 段间距（见 titleBlock 注释）：
                    // 左列总高账按无间距的歌名内容 76 计（带状态角标时）。
                    titleTexts(tier: compactTier)
                        .frame(width: leftColumnWidth)
                        .padding(.top, 4)
                    PlayerControlRow(tier: compactTier, onOpenQueue: { showQueue.toggle() })
                        .frame(width: leftColumnWidth)
                        .padding(.top, 4)
                }
                .frame(width: leftColumnWidth, height: middleHeight, alignment: .top)
                .clipped()
                lyricsZone(tier: landscapeTier, width: lyricsWidth)
            }
            .frame(height: middleHeight)
            .padding(.top, 8)
            PlayerProgressBar(tier: tier)
                .frame(width: geo.size.width - sideInsets)
                .padding(.top, 12)
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        .padding(.leading, geo.safeAreaInsets.leading)
        .padding(.trailing, geo.safeAreaInsets.trailing)
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
    // 圆形毛玻璃按钮（搜索放大镜 + 设置齿轮）。逐字徽章已撤下顶栏（移到歌词区
    // 左上角小字，LyricsZoneView 里接）；舞台 sparkles 按钮已撤下（播放页
    // 无舞台入口，舞台只从形态选择器进）；列表按钮已撤下（循环 / 随机改放
    // 队列面板头部，见 QueuePanelView）。

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
                    navigation.show(.search)
                }
                .accessibilityLabel("搜索")
                // 搜索页聚焦由搜索页负责：进搜索页时自动聚焦输入框。

                topBarCircleButton(
                    systemName: "gearshape",
                    diameter: PlayerTokens.topBarButton(tier)
                ) {
                    // 设置页路由已在 AppNavigation.swift 里：case settings。
                    navigation.show(.settings)
                }
                .accessibilityLabel("设置")
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

    // MARK: - 歌词区（工人 B 的 LyricsZoneView）+ 队列面板覆盖层

    /// 歌词区是纵向唯一弹性段：最小高走 `lyricsZoneHeight(tier)`，剩下的空间
    /// 全归它（工人 C 总账里的余量就由它消化）。队列面板打开时只盖住这一段：
    /// 控制行和最底部细进度条在歌词区之外，面板再大也遮不到它们（不依赖
    /// 工人 C 的控制行高度）。
    private func lyricsZone(tier: PlayerTokens.PlayerSizeTier, width: CGFloat) -> some View {
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
            minHeight: PlayerTokens.lyricsZoneHeight(tier),
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

    private var subtitleText: String {
        guard let track = store.currentTrack else { return "从首页或搜索页选一首歌开始" }
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        if !track.album.isEmpty { parts.append(track.album) }
        return parts.isEmpty ? track.platform : parts.joined(separator: " · ")
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
// 横屏总账（874×402，top 0，bottom 0；灵动岛在左/在右只扣 leading/trailing，
// 不占高）：顶栏 44（compact）+ 间隙 8 + 中间行 306 + 间隙 12 + 进度条 32
// = 402，刚好。中间行 306：左列 = 封面轨道 254×198/254×0.8 ≈ 158.4（计 159）
// + 4 + 歌名内容 76（compact 带状态角标：28×1.25 + 2 + 13×1.3 + 22）
// + 4 + 控制行 60（compact）= 303 ≤ 306，余 3；右列歌词区满高 306。
// 横屏宽度账（岛在左）：59 + 左列 220 + 间隙 16 + 歌词列 579 + 0 = 874；
// 岛在右对称：0 + 220 + 16 + 579 + 59 = 874。两边都过。
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
