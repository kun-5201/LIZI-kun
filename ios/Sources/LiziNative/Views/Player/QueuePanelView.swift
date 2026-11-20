import SwiftUI

/// 播放队列面板（r20：由 `PlayerView` 叠在歌词区上打开/关闭，只盖住歌词区，
/// 绝不遮控制行和最底部细进度条；不用 sheet，sheet 会盖住整页）。
///
/// 点行切歌（`store.play(queueItem:)`；按 `queueId` 定位，同一首歌在队列里
/// 出现多次时点第几行就播第几行，r25-B2 U6；旧 `play(item.track)` 按
/// id+platform 找第一个匹配项，点第二行会播成第一行，已不用）。
/// 当前在播的行高亮 + 「正在播放」标记。
/// 左滑删除单行（`store.removeFromQueue(at:)`）+ 头部「清空」按钮
/// （二次确认后 `store.clearQueue()`，清空并停止；r25-B2 U3）。
/// 列表用 List（swipeActions 只在 List 行上生效，ScrollView 里不生效），
/// 行背景透明 + 隐藏系统分隔线，沿用原来的自定义 Divider，外观不变。
///
/// 头部只留：清空（二次确认）+ 共 N 首 + 关闭 X。
/// 模式控制（循环 / 随机）不在这里——唯一入口是底部 v4 控制行
/// `PlayerBottomDock` 的模式键（`cycleDockMode`）；r29 task 3 删了
/// 头部重复的那两个按钮（用户真机报「为什么是 2 个控制器」）。
struct QueuePanelView: View {
    @EnvironmentObject private var store: PlaybackStore

    /// 关闭回调（`PlayerView` 的 showQueue；不传时不显示关闭按钮）。
    var onClose: (() -> Void)? = nil

    /// 清空队列二次确认弹窗。
    @State private var showClearConfirm = false

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
                List {
                    ForEach(Array(store.queue.enumerated()), id: \.element.id) { index, item in
                        VStack(spacing: 0) {
                            QueueRowView(item: item, isCurrent: index == store.currentIndex)
                                .onTapGesture { store.play(queueItem: item) }
                            Divider()
                                .background(Color.white.opacity(0.08))
                                .padding(.leading, 56)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.removeFromQueue(at: index)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .accessibilityLabel("从队列删除 \(item.track.title)")
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 毛玻璃卡片：盖在歌词区上时歌词不透出来干扰阅读。
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: PlayerTokens.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: PlayerTokens.radiusLg)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .alert("清空队列", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) {
                store.clearQueue()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空队列并停止播放，此操作无法撤销。")
        }
    }

    // MARK: - 头部：清空 + 数量 + 关闭（r29 task 3：模式键只留底部 v4 dock）

    private var headerRow: some View {
        HStack(spacing: 8) {
            Spacer()

            if !store.queue.isEmpty {
                Button {
                    showClearConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                        Text("清空")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.12), in: Capsule())
                }
                .accessibilityLabel("清空队列")

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
