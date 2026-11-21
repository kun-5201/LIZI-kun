import SwiftUI

/// 播放页底部（r20，照 01:14 截图拆分；旧 `PlayerDockView` 已删；
/// r35-7 控制行已删，只剩进度条）。
///
/// - `PlayerControlRow`（r35-7 已删：唯一调用方是旧横屏布局，传统横屏
///   改走右列五键红控制行后零调用；连同 playSize / classicControlIconSize /
///   classicModeIconSize / classicControlSpacing 四个尺寸 helper 一起删，
///   不留死代码。竖屏一直用 PlayerBottomDock，不受影响；随机播放入口仍在
///   队列面板头部，见 QueuePanelView；模式键（循环 → 单曲 → 随机）在竖屏
///   dock 与横屏传统控制行里各有一套同状态机，见 PlayerBottomDock.cycleDockMode）。
/// - `PlayerProgressBar`：最底部满宽细条，无时间数字，拖动 seek；播放头是
///   圆点（r22k：审计图里进度条上有圆点，旧代码只有 2pt 白线）。


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

    /// 填充色（r36 横屏传统：传 traditionalRed 时走纯红填充，稿里
    /// 进度条就是纯红填充（圆点色见 dotColor，r37-2 横屏是红点）；
    /// nil = 原来的 barA→barB 蓝紫渐变，竖屏 / dock 一字不动）。
    var fillColor: Color? = nil

    /// 轨道色 / 播放头圆点色（r37-2 横屏：修正版施工图里轨道是浅灰实线、
    /// 圆点是红色；nil = 原来的淡白轨道 + 白圆点，竖屏 / dock 一字不动）。
    var trackColor: Color? = nil
    var dotColor: Color? = nil

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
                    // 未走过的轨道（壳版 .dock__bar 的淡白底；r37-2 横屏传
                    // trackColor 时走调用方给的浅灰）。
                    trackColor ?? Color.white.opacity(0.08)
                    // 走过的部分：fillColor 有值时纯色（r36 横屏传统红条），
                    // 否则走过的渐变（壳版 .dock__paint：bar-a → bar-b）。
                    Group {
                        if let fillColor {
                            fillColor
                        } else {
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
                        }
                    }
                    .frame(width: max(0, fraction * width))
                    // 播放头：圆点（r22k：审计图里进度条上有圆点播放头，旧代码
                    // 只有 2pt 白线；圆点直径 10，中心落在 fraction 处，
                    // 两端夹住不冒出轨道外）。
                    if store.currentTrack != nil {
                        Circle()
                            .fill(dotColor ?? Color.white)
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
