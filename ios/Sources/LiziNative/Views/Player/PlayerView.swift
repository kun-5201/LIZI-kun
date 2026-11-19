import SwiftUI

/// 播放页（r20 截图布局 1:1，对照 01:14 播放页截图）。
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
            ZStack {
                background
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        topBar(tier: tier)
                        // 歌词展开时封面收小：整体缩到 0.55（顶部锚定），布局高同步
                        // 压到轨道高 × 0.55，腾出的空间归弹性歌词区；收起时还原。
                        // 只缩放渲染 + 压布局高，不动 CoverFlowView 内部尺寸
                        // （它只按 tier 定尺寸，见文件头注释）。
                        CoverFlowView(tier: tier)
                            .scaleEffect(lyricsExpanded ? 0.55 : 1, anchor: .top)
                            .frame(height: lyricsExpanded
                                   ? PlayerTokens.coverTrackHeight(tier) * 0.55
                                   : PlayerTokens.coverTrackHeight(tier))
                            // 外框压高后内部轨道（定高 trackHeight）会溢出，
                            // .clipped() 裁掉溢出部分（缩放后内容只占上半 55%，
                            // 裁掉的是空区）；布局高以外框为准，空间真正腾出。
                            .clipped()
                            .animation(.easeInOut(duration: 0.3), value: lyricsExpanded)
                            .padding(.top, 6)
                        lyricsZone(tier: tier)
                        titleBlock(tier: tier)
                        PlayerControlRow(tier: tier, onOpenQueue: { showQueue.toggle() })
                    }
                    .padding(.horizontal, PlayerTokens.sp4)
                    // 顶部走 safeAreaInsets：刘海 47 / 灵动岛 59 / 无刘海 20，
                    // 父容器若已扣过安全区这里就是 0，不会双倍 padding。
                    .padding(.top, geo.safeAreaInsets.top)
                    // 细进度条：满宽（在横向 padding 的外层），与控制行隔 12，
                    // 底部留 Home Indicator 安全区（有 Home Indicator 34，无则 0）。
                    PlayerProgressBar(tier: tier)
                        .padding(.top, 12)
                        .padding(.bottom, geo.safeAreaInsets.bottom)
                }
            }
        }
        // 禁缩放：SwiftUI 默认没有捏合缩放；这里明确不加任何缩放手势。
        .navigationBarHidden(true)
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
    private func lyricsZone(tier: PlayerTokens.PlayerSizeTier) -> some View {
        ZStack {
            LyricsZoneView(isExpanded: $lyricsExpanded)
            if showQueue {
                QueuePanelView(onClose: { showQueue = false })
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: PlayerTokens.lyricsZoneHeight(tier),
            maxHeight: .infinity
        )
        .padding(.top, 8)
    }

    // MARK: - 歌名 / 歌手 + 状态角标 / 播放失败原因

    private func titleBlock(tier: PlayerTokens.PlayerSizeTier) -> some View {
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
        // 段间距与工人 C 总账对齐：歌词区 → 歌名块 8，歌名块 → 控制行 10。
        .padding(.top, 8)
        .padding(.bottom, 10)
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
// - standard（390×844，截图机，topInset 47，底部 34）：
//   47 + 48 + 6 + 254 + 8 + 180 + 8 + 60 + 10 + 68 + 12 + 32 + 34 = 767 ≤ 844，
//   余 77（歌词区实得 180 + 77 = 257）。
// - large（430×932，topInset 59，底部 34）：
//   59 + 52 + 6 + 280 + 8 + 210 + 8 + 67 + 10 + 76 + 12 + 32 + 34 = 854 ≤ 932，
//   余 78（歌词区实得 210 + 78 = 288）。
// 三档全未超高。最短屏 compact 带状态角标也只到 658/667，
// 歌词区最少也有 150（3 行歌词最少约 90），没有一档会挤爆。
