import SwiftUI

/// 播放页第二行小图标（r26，22:45 用户纠正）。
///
/// - 位置：竖屏四变体里原来底部音量条的位置（控制行之后、进度条之前；
///   02/04 里控制行在歌词区之上，第二行也随之在歌词区之上）。
/// - 4 个：随机 / 爱心 / 循环 / 音量（22:44 主控行只留上一首/播放/下一首
///   之后，随机/爱心/循环从主控行拿掉，改放这里；音量按钮不占顶栏位置，
///   也放这里）。顶栏齿轮（舞台控制键）原样保留，不动本文件之外的顶栏。
/// - 随机：点按调 `store.setShuffled(!isShuffled)`，开时 accent 色。
/// - 爱心：点按调 `store.toggleLike()`，已喜欢 heart.fill 红色实心。
/// - 循环：点按调 `store.cycleRepeatMode()`，顺序 → 全部循环 → 单曲循环
///   （PlaybackStore 原样；图标与 PlayerControlRow 同一套映射：
///   顺序/全部循环 repeat，单曲循环 repeat.1；开时 accent 色）。
/// - 音量：点按在行正上方弹出小音量滑杆（就地调），复用 PlayerVolumeRow
///   （静音按钮 + Slider，接 `store.volume` / `isMuted`，与 r25 底部音量行
///   同一套；volume 当次会话有效、isMuted 持久化，见 PlaybackStore）；
///   再点音量键或点面板右上角 × 关闭。图标跟静音/音量状态走。
/// - 尺寸：行高 28 + 上间隙 8 = 36pt，与被替掉的底部音量行同一槽位，
///   各档总账一字不动（见 PlayerView.swift 文件底 r26 第二行总账）；
///   compact 默认/04 仍不渲染（该档 375×667 塞不下 36pt，r25-B5 同款
///   守卫；见文件底说明与 verification/r26-player-volume-check.md）。
/// - 无曲目时整行 disabled（与 PlayerControlRow 同款）。
/// - 横屏不放（横屏总高 402 已满；横屏音量仍走系统音量键，与 r25 一致）。
/// - 禁缩放：本文件没有任何 MagnificationGesture / 捏合手势。
struct PlayerSecondRow: View {
    @EnvironmentObject private var store: PlaybackStore

    var tier: PlayerTokens.PlayerSizeTier = .standard

    /// 音量弹出滑杆是否打开（行内 @State；同一时刻只有一个竖屏变体在屏，
    /// 状态跟行走，切变体即收起）。
    @State private var showVolumePopover = false

    /// 行内间距（与 PlayerControlRow 同款：compact 16，其余档 32）。
    private var rowSpacing: CGFloat { tier == .compact ? 16 : 32 }

    /// 循环模式图标（与 PlayerControlRow / QueuePanelView 同一套映射）。
    private var repeatIconName: String {
        store.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private var repeatTitle: String {
        switch store.repeatMode {
        case .off: return "顺序"
        case .all: return "循环"
        case .one: return "单曲"
        }
    }

    /// 音量图标跟静音/音量状态走（与 PlayerVolumeRow 的静音按钮同一套
    /// 图标：静音或音量 0 → speaker.slash.fill；小音量 → wave.1；其余 → wave.2）。
    private var volumeIconName: String {
        if store.isMuted || store.volume <= 0 { return "speaker.slash.fill" }
        if store.volume < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    /// 音量键颜色：静音时红（与 PlayerVolumeRow 的静音态同款），
    /// 弹出滑杆打开时 accent（表示面板正开着），其余白字。
    private var volumeButtonColor: Color {
        if store.isMuted { return Color.red }
        if showVolumePopover { return PlayerTokens.accent }
        return PlayerTokens.playerForeground
    }

    /// 弹出滑杆面板高：音量行 28 + 上下 padding 各 10 = 48。
    private static let volumePopoverHeight: CGFloat = 48

    var body: some View {
        HStack(spacing: rowSpacing) {
            Button(action: { store.setShuffled(!store.isShuffled) }) {
                Image(systemName: "shuffle")
                    .font(.system(size: PlayerTokens.controlIconSize(tier), weight: .medium))
                    .foregroundStyle(store.isShuffled ? PlayerTokens.accent : PlayerTokens.playerForeground)
            }
            .accessibilityLabel(store.isShuffled ? "随机播放已开，点按关闭" : "随机播放已关，点按开启")

            Button(action: { store.toggleLike() }) {
                Image(systemName: store.isLiked ? "heart.fill" : "heart")
                    .font(.system(size: PlayerTokens.controlIconSize(tier), weight: .medium))
                    .foregroundStyle(store.isLiked ? Color.red : PlayerTokens.playerForeground)
            }
            .accessibilityLabel(store.isLiked ? "取消喜欢" : "喜欢")

            Button(action: { store.cycleRepeatMode() }) {
                Image(systemName: repeatIconName)
                    .font(.system(size: PlayerTokens.controlIconSize(tier), weight: .medium))
                    .foregroundStyle(store.repeatMode != .off ? PlayerTokens.accent : PlayerTokens.playerForeground)
            }
            .accessibilityLabel("循环模式：\(repeatTitle)，点按切换")

            Button(action: { showVolumePopover.toggle() }) {
                Image(systemName: volumeIconName)
                    .font(.system(size: PlayerTokens.controlIconSize(tier), weight: .medium))
                    .foregroundStyle(volumeButtonColor)
            }
            .accessibilityLabel(store.isMuted ? "音量（已静音），点按打开音量调节" : "音量，点按打开音量调节")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .disabled(store.currentTrack == nil)
        // 音量弹出滑杆：贴在行正上方（行顶往上 8pt 间隙 + 面板高），
        // 覆盖控制行/歌名区一带，不占布局高、不顶进度条；不加全屏
        // 点外关闭层（行的 overlay 里算不准全屏位置），关闭靠再点
        // 音量键或面板 ×。
        .overlay(alignment: .top) {
            if showVolumePopover {
                volumePopover
                    .offset(y: -(Self.volumePopoverHeight + 8))
            }
        }
    }

    /// 小音量滑杆面板：复用 PlayerVolumeRow（静音按钮 + Slider，
    /// 与 r25 底部音量行同一套接线），右上角 × 关闭；毛玻璃圆角，
    /// 宽 280（compact 内容宽 343 也放得下）。
    private var volumePopover: some View {
        HStack(spacing: 8) {
            PlayerVolumeRow(tier: tier)
            Button(action: { showVolumePopover = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PlayerTokens.playerForeground)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("关闭音量调节")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
    }
}
