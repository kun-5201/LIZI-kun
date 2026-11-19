import SwiftUI

/// 播放页底部两件（r20，照 01:14 截图拆分；旧 `PlayerDockView` 已删）。
///
/// - `PlayerControlRow`：控制行，一行居中：队列列表 | 上一首 | 播放（大，白圆底）
///   | 下一首。模式按钮（循环/随机）不在这一行——工人 A 把它放队列面板头部了。
/// - `PlayerProgressBar`：最底部满宽细条，无时间数字，拖动 seek。
///
/// 接线（工人 A 在 `PlayerView.swift` 里接，两个组件的调用方就是 PlayerView）：
/// `PlayerControlRow(tier: tier, onOpenQueue: { … })`，
/// `PlayerProgressBar(tier: tier)`。Home Indicator 安全区由调用方处理。
/// 禁缩放：本文件没有任何 MagnificationGesture / 捏合手势。

// MARK: - 控制行

/// 控制行：队列列表 | 上一首 | 播放（大，白圆底）| 下一首，一行居中。
///
/// - 列表图标点按回调由调用方传进来（`onOpenQueue`），这里不写死打开方式。
/// - 上一首 / 下一首 / 播放直接调 `store.previous()` / `next()` / `togglePlay()`。
/// - 无曲目时整行 disabled。
/// - 尺寸走分档：大播放键直径 `PlayerTokens.playSize(tier)`（行高 = 此值），
///   小图标字号 `PlayerTokens.controlIconSize(tier)`。
struct PlayerControlRow: View {
    @EnvironmentObject private var store: PlaybackStore

    /// 尺寸档（调用方按实测屏宽经 `PlayerTokens.sizeTier(for:topInset:)` 传入）。
    var tier: PlayerTokens.PlayerSizeTier = .standard
    /// 列表图标点按回调（调用方传入，如打开队列面板；不要在这里写死）。
    var onOpenQueue: () -> Void = {}

    var body: some View {
        HStack(spacing: 32) {
            Button(action: onOpenQueue) {
                Image(systemName: "list.bullet")
                    .font(.system(size: PlayerTokens.controlIconSize(tier), weight: .medium))
                    .foregroundStyle(PlayerTokens.playerForeground)
            }
            .accessibilityLabel("播放队列")

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
                    // 播放头：一根发亮的细线（壳版 .dock__head）。
                    if store.currentTrack != nil {
                        Rectangle()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: 2)
                            .shadow(color: .white.opacity(0.45), radius: 8, x: 0, y: 0)
                            .offset(x: max(0, fraction * width - 1))
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
