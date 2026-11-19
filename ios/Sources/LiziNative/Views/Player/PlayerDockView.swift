import SwiftUI

/// 播放页底部两件（r20，照 01:14 截图拆分；旧 `PlayerDockView` 已删）。
///
/// - `PlayerControlRow`：控制行，一行居中，正好 6 个（r22 定稿，无 AirPlay；
///   岛的 AirPlay 在扩展里另一套，见 LiziNativeLiveActivity，不动这里）。
///   两端是模式按钮：左端随机（shuffle，点按开关），右端循环（repeat / repeat.1，
///   点按在顺序 → 全部循环 → 单曲循环之间切；两个开关重启后保留，见 PlaybackStore）。
///   竖屏第 2 项是爱心（heart / heart.fill，已喜欢红色实心，点按调
///   `store.toggleLike()` 进「我的喜欢」）；横屏第 2 项是三条杠队列入口
///   （`list.bullet`，点按调调用方传的 `onOpenQueue`，只横屏传）。
///   其余三项两屏一样：上一首 | 播放（大，白圆底）| 下一首。
///   模式按钮（循环/随机）不在这一行——工人 A 把它放队列面板头部了。
/// - `PlayerProgressBar`：最底部满宽细条，无时间数字，拖动 seek；播放头是
///   圆点（r22k：审计图里进度条上有圆点，旧代码只有 2pt 白线）。
///
/// 接线（r22：`PlayerControlRow(tier:)` 默认竖屏（爱心，不带 onOpenQueue）；
/// 横屏调 `PlayerControlRow(tier:showsQueueButton:onOpenQueue:)`；
/// `PlayerProgressBar(tier: tier)` 不变）。
/// Home Indicator 安全区由调用方处理。
/// 禁缩放：本文件没有任何 MagnificationGesture / 捏合手势。

// MARK: - 控制行

/// 控制行：一行居中，正好 6 个（r22 定稿）。
/// 竖屏：随机 | 爱心 | 上一首 | 播放（大，白圆底）| 下一首 | 循环；
/// 横屏：随机 | 三条杠 | 上一首 | 播放 | 下一首 | 循环（第 2 项是队列入口）。
/// 播放页控制行没有 AirPlay（r22 定稿删掉；岛展开态的 AirPlay 在扩展里
/// 另一套，见 LiziNativeLiveActivity，不动）。
///
/// - 随机点按调 `store.setShuffled(!store.isShuffled)`（开时图标 accent 色）。
/// - 循环点按调 `store.cycleRepeatMode()`（顺序 → 全部循环 → 单曲循环；
///   图标与队列面板头部同一套映射：顺序/全部循环 repeat，单曲循环 repeat.1；
///   开时图标 accent 色）。两个开关都持久化，重启保留（见 PlaybackStore）。
/// - 爱心点按调 `store.toggleLike()`（已喜欢显示 heart.fill 红色实心，
///   未喜欢 heart 空心；持久化 + 喜欢 rail 都在 PlaybackStore.toggleLike() 里）。
/// - 三条杠只在横屏（`showsQueueButton` 为真时），点按调 `onOpenQueue`。
/// - 上一首 / 下一首 / 播放直接调 `store.previous()` / `next()` / `togglePlay()`。
/// - 无曲目时整行 disabled。
/// - 尺寸走分档：大播放键直径 `PlayerTokens.playSize(tier)`（行高 = 此值），
///   小图标字号 `PlayerTokens.controlIconSize(tier)`。
/// - 行内间距分档：compact 16，其余档 32。6 个按钮实算：compact
///   4×22 + 60 + 5×16 = 228 ≤ 815（横屏满宽）；standard 4×24 + 68 + 5×32
///   = 324 ≤ 370（竖屏）；large 4×26 + 76 + 5×32 = 340 ≤ 398（竖屏）。
struct PlayerControlRow: View {
    @EnvironmentObject private var store: PlaybackStore

    /// 尺寸档（调用方按实测屏宽经 `PlayerTokens.sizeTier(for:topInset:)` 传入）。
    var tier: PlayerTokens.PlayerSizeTier = .standard

    /// 横屏时第 2 项是队列入口（三条杠）而不是爱心；竖屏默认 false（爱心）。
    var showsQueueButton: Bool = false

    /// 横屏三条杠的回调（调用方一般传 `{ showQueue.toggle() }`）；竖屏不用，默认 nil。
    var onOpenQueue: (() -> Void)? = nil

    /// 行内间距：compact 16，其余档 32。
    private var rowSpacing: CGFloat { tier == .compact ? 16 : 32 }

    /// 循环模式图标（与队列面板头部同一套映射：顺序/全部循环都用 repeat，
    /// 单曲循环用 repeat.1；见 QueuePanelView.repeatIconName）。
    private var repeatIconName: String {
        switch store.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    /// 循环模式文案（与队列面板头部同一套：顺序 / 循环 / 单曲）。
    private var repeatTitle: String {
        switch store.repeatMode {
        case .off: return "顺序"
        case .all: return "循环"
        case .one: return "单曲"
        }
    }

    var body: some View {
        HStack(spacing: rowSpacing) {
            Button(action: { store.setShuffled(!store.isShuffled) }) {
                Image(systemName: "shuffle")
                    .font(.system(size: PlayerTokens.controlIconSize(tier), weight: .medium))
                    .foregroundStyle(store.isShuffled ? PlayerTokens.accent : PlayerTokens.playerForeground)
            }
            .accessibilityLabel(store.isShuffled ? "随机播放已开，点按关闭" : "随机播放已关，点按开启")

            if showsQueueButton {
                Button(action: { onOpenQueue?() }) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: PlayerTokens.controlIconSize(tier), weight: .medium))
                        .foregroundStyle(PlayerTokens.playerForeground)
                }
                .accessibilityLabel("打开播放队列")
            } else {
                Button(action: { store.toggleLike() }) {
                    Image(systemName: store.isLiked ? "heart.fill" : "heart")
                        .font(.system(size: PlayerTokens.controlIconSize(tier), weight: .medium))
                        .foregroundStyle(store.isLiked ? Color.red : PlayerTokens.playerForeground)
                }
                .accessibilityLabel(store.isLiked ? "取消喜欢" : "喜欢")
            }

            Button(action: { store.previous() }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: PlayerTokens.controlIconSize(tier)))
                    .foregroundStyle(PlayerTokens.playerForeground)
            }
            .accessibilityLabel("上一首")

            playButton

            Button(action: { store.next() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: PlayerTokens.controlIconSize(tier)))
                    .foregroundStyle(PlayerTokens.playerForeground)
            }
            .accessibilityLabel("下一首")

            Button(action: { store.cycleRepeatMode() }) {
                Image(systemName: repeatIconName)
                    .font(.system(size: PlayerTokens.controlIconSize(tier), weight: .medium))
                    .foregroundStyle(store.repeatMode != .off ? PlayerTokens.accent : PlayerTokens.playerForeground)
            }
            .accessibilityLabel("循环模式：\(repeatTitle)，点按切换")
        }
        .frame(maxWidth: .infinity)
        .frame(height: PlayerTokens.playSize(tier))
        .disabled(store.currentTrack == nil)
    }

    private var playButton: some View {
        Button(action: { store.togglePlay() }) {
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: PlayerTokens.playSize(tier),
                           height: PlayerTokens.playSize(tier))
                    .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
                if store.isLoading {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: PlayerTokens.playSize(tier) * 0.44, weight: .semibold))
                        .foregroundStyle(.black)
                        .offset(x: store.isPlaying ? 0 : 2)
                }
            }
        }
        .accessibilityLabel(store.isPlaying ? "暂停" : "播放")
    }
}

// MARK: - 底部细进度条

/// 最底部满宽细条，视觉高 `PlayerTokens.progressHeight(tier)`（各档 4pt），
/// 无时间数字（按截图不显示时间数字）。
///
/// 触摸区（r20 工人 E）：视觉细条仍 4pt、贴框底，组件外框加高到 32pt，
/// 手势挂在整个外框上——手指按住外框任意纵向位置都能拖。多出的 28pt
/// 向上延伸，仍在进度条自己的地盘内：上方与控制行之间还有调用方给的
/// 12pt 间隙，下方是调用方留的 Home Indicator 安全区，都不侵占。
///
/// 拖动 seek 沿用旧 `PlayerDockView` 的 `dragFraction` 做法：
/// 拖动中显示拖动进度、松手才调一次 `seek(to:)`；拖动只改渐变填充宽度，
/// 不改任何一个 view 的 frame。轨道淡白底 + 走过渐变（沿用 barA/barB）。
/// 满宽：本组件自身不加横向 padding，宽度由调用方给满；Home Indicator
/// 安全区由调用方处理。
struct PlayerProgressBar: View {
    @EnvironmentObject private var store: PlaybackStore

    /// 尺寸档（调用方按实测屏宽经 `PlayerTokens.sizeTier(for:topInset:)` 传入）。
    var tier: PlayerTokens.PlayerSizeTier = .standard

    /// 触摸区高（r20 工人 E）：32pt。视觉细条仍 4pt，贴框底。
    /// 总高账 +28pt：compact 最紧 608+28=636 ≤ 667（状态角标行再 +22
    /// 也 658 ≤ 667），standard / large 余量更大，均在 PlayerTokens 的
    /// 高度账余量内；若协调员要同步，此数需记进 PlayerTokens 的总高度账。
    private static let touchHeight: CGFloat = 32

    /// 拖动中的进度（0…1）；非 nil 时显示它，不读 `store.progress`。
    @State private var dragFraction: CGFloat?

    private var fraction: CGFloat {
        if let dragFraction { return dragFraction }
        guard store.duration > 0 else { return 0 }
        return CGFloat(max(0, min(store.progress / store.duration, 1)))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // 外框 = 整个 32pt 触摸区；视觉细条（4pt）贴框底，位置与改前一致。
            ZStack(alignment: .bottomLeading) {
                // 视觉细条：高 4pt，贴框底；外观与改前一字不改。
                ZStack(alignment: .leading) {
                    // 未走过的轨道（壳版 .dock__bar 的淡白底）。
                    Color.white.opacity(0.08)
                    // 走过的渐变（壳版 .dock__paint：bar-a → bar-b）。
                    LinearGradient(
                        colors: [
                            PlayerTokens.barA.opacity(0.75),
                            PlayerTokens.barA,
                            PlayerTokens.barB,
                            PlayerTokens.barB.opacity(0.9),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: max(0, fraction * width))
                    // 播放头：圆点（r22k：审计图里进度条上有圆点播放头，旧代码
                    // 只有 2pt 白线；圆点直径 10，中心落在 fraction 处，
                    // 两端夹住不冒出轨道外）。
                    if store.currentTrack != nil {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 10, height: 10)
                            .offset(x: min(max(0, fraction * width - 5), max(0, width - 10)))
                    }
                }
                .frame(height: PlayerTokens.progressHeight(tier))
            }
            // 手势挂在整个 32pt 外框上：contentShape(Rectangle()) 让框内
            // 任意纵向位置都可命中；DragGesture 只取横向 x 换算进度，
            // 纵向按在框内哪里都一样拖。
            .contentShape(Rectangle())
            .gesture(seekGesture(width: width))
            .disabled(store.currentTrack == nil || store.duration <= 0)
        }
        .frame(height: Self.touchHeight)
        .accessibilityLabel("进度条")
        .accessibilityValue("\(PlayerTokens.formatDuration(store.progress)) / \(PlayerTokens.formatDuration(store.duration))")
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard width > 0, store.currentTrack != nil, store.duration > 0 else { return }
                dragFraction = clamp(value.location.x / width)
            }
            .onEnded { value in
                guard width > 0, store.currentTrack != nil, store.duration > 0 else {
                    dragFraction = nil
                    return
                }
                let target = clamp(value.location.x / width)
                dragFraction = nil
                // seek(to:) 入参是秒。
                store.seek(to: TimeInterval(target) * store.duration)
            }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
