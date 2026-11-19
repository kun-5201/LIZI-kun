import SwiftUI

/// 播放队列面板（r20：由 `PlayerView` 叠在歌词区上打开/关闭，只盖住歌词区，
/// 绝不遮控制行和最底部细进度条；不用 sheet，sheet 会盖住整页）。
///
/// 点行切歌（`store.play(_:)`；同一首歌在队列里出现多次时按 `queueId` 区分，
/// 这里按行点的是该行的那一项）。当前在播的行高亮 + 「正在播放」标记。
///
/// 头部一行小按钮（r20 从顶栏 / 传输排撤下后搬到这里，功能接原来的
/// store 调用，一个没丢）：
/// - 循环模式切换：点按 `store.cycleRepeatMode()`（顺序 → 全部循环 → 单曲循环）。
/// - 随机开关：点按 `store.setShuffled(!store.isShuffled)`。
struct QueuePanelView: View {
    @EnvironmentObject private var store: PlaybackStore

    /// 关闭回调（`PlayerView` 的 showQueue；不传时不显示关闭按钮）。
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if store.queue.isEmpty {
                VStack {
                    Spacer()
                    Text("队列是空的")
                        .font(.system(size: PlayerTokens.textMd))
                        .foregroundStyle(PlayerTokens.playerDim)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.queue.enumerated()), id: \.element.id) { index, item in
                            QueueRowView(item: item, isCurrent: index == store.currentIndex)
                                .onTapGesture { store.play(item.track) }
                            Divider()
                                .background(Color.white.opacity(0.08))
                                .padding(.leading, 56)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 毛玻璃卡片：盖在歌词区上时歌词不透出来干扰阅读。
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: PlayerTokens.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: PlayerTokens.radiusLg)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - 头部：循环模式切换 + 随机开关 + 数量 + 关闭

    private var headerRow: some View {
        HStack(spacing: 8) {
            headerButton(icon: repeatIconName, title: repeatTitle, isActive: store.repeatMode != .off) {
                store.cycleRepeatMode()
            }
            .accessibilityLabel("循环模式：\(repeatTitle)，点按切换")

            headerButton(icon: "shuffle", title: "随机", isActive: store.isShuffled) {
                store.setShuffled(!store.isShuffled)
            }
            .accessibilityLabel(store.isShuffled ? "随机播放已开，点按关闭" : "随机播放已关，点按开启")

            Spacer()

            if !store.queue.isEmpty {
                Text("共 \(store.queue.count) 首")
                    .font(.system(size: PlayerTokens.textXs))
                    .foregroundStyle(PlayerTokens.playerDim)
            }

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PlayerTokens.playerForeground)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
                .accessibilityLabel("关闭队列")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// 头部小按钮：图标 + 短文字的胶囊；激活态（循环开 / 随机开）用 accent。
    private func headerButton(
        icon: String,
        title: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isActive ? PlayerTokens.accent : PlayerTokens.playerForeground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isActive ? PlayerTokens.accent.opacity(0.18) : Color.white.opacity(0.12),
                in: Capsule()
            )
        }
    }

    // MARK: - 循环模式图标 / 文案（旧 PlayerView 的 modeButton 逻辑原样搬来，
    // 只是拆成独立的循环按钮 + 随机按钮，不再点按切循环、长按切随机共用一个键）

    private var repeatIconName: String {
        switch store.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private var repeatTitle: String {
        switch store.repeatMode {
        case .off: return "顺序"
        case .all: return "循环"
        case .one: return "单曲"
        }
    }
}

/// 队列里的一行。
struct QueueRowView: View {
    let item: QueueItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            CoverImageView(url: item.track.coverURL, placeholderIconSize: 14)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.track.title.isEmpty ? "未知标题" : item.track.title)
                    .font(.system(size: PlayerTokens.textMd, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? PlayerTokens.accent : PlayerTokens.playerForeground)
                    .lineLimit(1)
                Text(item.track.artist.isEmpty ? item.track.platform : item.track.artist)
                    .font(.system(size: PlayerTokens.textXs))
                    .foregroundStyle(PlayerTokens.playerDim)
                    .lineLimit(1)
            }

            Spacer()

            if isCurrent {
                Text("正在播放")
                    .font(.system(size: PlayerTokens.textXs, weight: .medium))
                    .foregroundStyle(PlayerTokens.accent)
            } else {
                Text(PlayerTokens.formatDuration(item.track.durationSeconds))
                    .font(.system(size: PlayerTokens.textXs))
                    .foregroundStyle(PlayerTokens.playerDim)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}
