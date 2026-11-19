import SwiftUI

/// 播放队列面板：与歌词共用同一面板区域切换（见 `PlayerView` 的面板 Tab）。
///
/// 点行切歌（`store.play(_:)`；同一首歌在队列里出现多次时按 `queueId` 区分，
/// 这里按行点的是该行的那一项）。当前在播的行高亮 + 「正在播放」标记。
struct QueuePanelView: View {
    @EnvironmentObject private var store: PlaybackStore

    var body: some View {
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
}

/// 队列收起态预览：前 3 行（PlayerView 的面板收起时用）。
struct QueuePreviewView: View {
    @EnvironmentObject private var store: PlaybackStore

    var body: some View {
        if store.queue.isEmpty {
            Text("队列是空的")
                .font(.system(size: PlayerTokens.textMd))
                .foregroundStyle(PlayerTokens.playerDim)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, PlayerTokens.sp2)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(store.queue.prefix(3).enumerated()), id: \.element.id) { index, item in
                    QueueRowView(item: item, isCurrent: index == store.currentIndex)
                        .onTapGesture { store.play(item.track) }
                }
            }
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
