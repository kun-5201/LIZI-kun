import SwiftUI

/// 评论区面板（r27，v4 底部三排评论键点开；sheet 弹出，可全屏滚动）。
///
/// 只读，不发评论（发评论需登录，各平台发评接口未验证，见 CommentsService）。
/// 数据走 `NativeBridge.comments` → `/api/comments`：
/// - 网易云：真实评论列表（热门在前，可翻页「加载更多」）。
/// - 其它平台：服务端回 501 + 老实原因，这里原样显示 + 重试，不编假评论。
/// - 无评论时显示「暂无评论」；请求失败显示原因 + 重试按钮。
/// 曲目用打开时的快照（track），面板开着时切歌不重载，避免列表半路换内容。
struct CommentsPanelView: View {
    /// 打开时的曲目快照（id / platform / platformKey 够查评论用）。
    let track: Track

    @Environment(\.dismiss) private var dismiss

    @State private var comments: [NativeBridge.SongComment] = []
    @State private var total = 0
    @State private var hasMore = false
    @State private var offset = 0
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    private let pageSize = 20

    private var platformName: String {
        SettingsStore.platformNames[track.platform] ?? track.platform
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if let errorMessage {
                    errorState(message: errorMessage)
                } else if comments.isEmpty, isLoading {
                    loadingState
                } else if comments.isEmpty {
                    emptyState
                } else {
                    commentList
                }
            }
        }
        .task { await loadMore() }
    }

    // MARK: - 头部（不用 NavigationStack：播放页是深色全屏，系统导航栏
    // 会是浅色，顶栏自己画；关闭钮在右上角）

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title.isEmpty ? "未知标题" : track.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(track.artist.isEmpty ? platformName : track.artist) · \(platformName)评论"
                     + (total > 0 ? "（\(total)）" : ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.16), in: Circle())
            }
            .accessibilityLabel("关闭评论区")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    // MARK: - 列表

    private var commentList: some View {
        List {
            ForEach(comments) { comment in
                commentRow(comment)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            if hasMore {
                HStack {
                    Spacer()
                    Button(action: { Task { await loadMore() } }) {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("加载更多")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.14), in: Capsule())
                        }
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("加载更多评论")
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func commentRow(_ comment: NativeBridge.SongComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CoverImageView(url: comment.avatarURL, placeholderIconSize: 12)
                .frame(width: 36, height: 36)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.nickname)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                    if !comment.timeText.isEmpty {
                        Text(comment.timeText)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                    Spacer()
                    if comment.likedCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "hand.thumbsup")
                                .font(.system(size: 10))
                            Text("\(comment.likedCount)")
                                .font(.system(size: 11))
                                .monospacedDigit()
                        }
                        .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
                Text(comment.content)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 空态 / 加载 / 失败

    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .tint(.white)
            Text("评论加载中…")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.system(size: 28))
                .foregroundStyle(Color.white.opacity(0.4))
            Text("暂无评论")
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(Color.white.opacity(0.4))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(action: { Task { await reload() } }) {
                Text("重试")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.16), in: Capsule())
            }
            .accessibilityLabel("重新加载评论")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 加载

    private func reload() async {
        comments = []
        total = 0
        hasMore = false
        offset = 0
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        let result = await NativeBridge.comments(
            platform: track.platform, id: track.id, key: track.platformKey,
            offset: offset, limit: pageSize
        )
        isLoading = false
        if let error = result.error {
            errorMessage = error
            return
        }
        comments += result.comments
        total = result.total
        hasMore = result.hasMore
        offset += result.comments.count
    }
}
