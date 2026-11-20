import SwiftUI

/// 歌单详情页（NATIVE-REWRITE-PLAN.md §1 屏幕 5，P2-A）。
///
/// 组成：歌单封面大图 + 标题 + 创建者 + 曲目数 + 简介；曲目列表复用
/// TrackRowView（与搜索结果同一组件）；点行播放走
/// PlaybackStore.setQueue(playlist.tracks, startAt: index)（与搜索结果共用队列）；
/// 顶部「播放全部」按钮。
///
/// 诚实边界（不编假数据）：
/// - 曲目数为 0 或接口无数据时显示空态，写清原因，不编曲目。
/// - 各平台详情形状（r25-B2 逐家核对服务端路由后定；详情见
///   NativeBridge.playlistDetail / playlistMeta 的注释）：
///   网易/QQ 的 detail 端点回全量（名/封面/曲数/曲目）；波点/酷狗/汽水
///   detail 只回名/封面/曲数、曲目另调 tracks 合并；酷我非榜单 tracks
///   接口本身带名/封面/总数；只有酷我榜单是 tracks-only，标题为空时显示
///   「〈平台名〉歌单」通用名（不是真实歌单名），封面用白色底 + 音符占位，
///   曲目数显示已加载数；Apple Music tracks 回包带 name/cover（r25-B4：
///   服务端 playlistTracks 透 iTunes lookup 首条的歌单名/封面），显示真名真封面。
/// - 标题与曲目同时为空 = 接口没有返回数据或请求失败（两种情况桥接层无法区分，
///   空态文案把两种可能都写清，不谎称是哪一种）。
/// - 禁缩放：没有任何 MagnificationGesture，尺寸全部固定 pt。
struct PlaylistDetailView: View {
    let platform: String
    let id: String
    let isRank: Bool

    @EnvironmentObject private var playback: PlaybackStore
    @StateObject private var viewModel: PlaylistDetailViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(platform: String, id: String, isRank: Bool = false) {
        self.platform = platform
        self.id = id
        self.isRank = isRank
        _viewModel = StateObject(wrappedValue: PlaylistDetailViewModel(
            platform: platform, id: id, isRank: isRank))
    }

    private var isCompact: Bool { sizeClass == .compact }

    var body: some View {
        Group {
            if viewModel.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载歌单…")
                        .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                        .foregroundStyle(SearchDesignTokens.ink3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let playlist = viewModel.playlist, viewModel.hasContent {
                contentView(playlist)
            } else {
                emptyState
            }
        }
        .background(SearchDesignTokens.paper)
        .task {
            await viewModel.load()
        }
    }

    // MARK: - 有内容的详情

    @ViewBuilder
    private func contentView(_ playlist: Playlist) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                headerView(playlist)
                playAllButton(playlist)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                Divider()
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                ForEach(Array(playlist.tracks.enumerated()), id: \.offset) { index, track in
                    trackRow(track, in: playlist.tracks, at: index)
                }
            }
            .padding(.bottom, 24)
        }
    }

    /// 头部：封面大图 + 标题 + 创建者 + 曲目数 + 简介。
    private func headerView(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                coverView(url: playlist.coverURL)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(displayTitle(playlist))
                            .font(SearchDesignTokens.font(SearchDesignTokens.size20, weight: .semibold))
                            .foregroundStyle(SearchDesignTokens.ink)
                            .lineLimit(2)
                        if isRank {
                            Text("榜单")
                                .font(SearchDesignTokens.font(SearchDesignTokens.size12, weight: .semibold))
                                .foregroundStyle(SearchDesignTokens.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: SearchDesignTokens.radius10)
                                        .stroke(SearchDesignTokens.accent.opacity(0.5), lineWidth: 1)
                                )
                        }
                    }
                    if !playlist.creator.isEmpty {
                        Text(playlist.creator)
                            .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                            .foregroundStyle(SearchDesignTokens.ink2)
                            .lineLimit(1)
                    }
                    Text(countText(playlist))
                        .font(SearchDesignTokens.font(SearchDesignTokens.size13))
                        .foregroundStyle(SearchDesignTokens.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !playlist.description.isEmpty {
                Text(playlist.description)
                    .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                    .foregroundStyle(SearchDesignTokens.ink2)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// 标题：上游给了真实标题就显示；tracks-only 接口没给标题时显示
    /// 「〈平台名〉歌单」通用名（明确不是真实歌单名，不编标题）。
    private func displayTitle(_ playlist: Playlist) -> String {
        let title = playlist.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return "\(SearchViewModel.label(for: platform))歌单"
    }

    /// 曲目数：上游给了总数（网易/QQ/汽水 trackCount）就显示总数；
    /// tracks-only 接口只有已加载数（playlistFrom 已回落为 tracks.count），
    /// 显示已加载数，不谎称总数。
    private func countText(_ playlist: Playlist) -> String {
        let total = playlist.trackCount > 0 ? playlist.trackCount : playlist.tracks.count
        if total <= 0 { return "暂无曲目" }
        if playlist.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "已加载 \(total) 首"
        }
        return "共 \(total) 首"
    }

    /// 封面大图（120pt）：有图显示图，无图白色底 + 音符占位，不用金色。
    @ViewBuilder
    private func coverView(url: URL?) -> some View {
        Group {
            ProxyImageView(url: url) { coverPlaceholder }
        }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: SearchDesignTokens.radius14))
    }

    private var coverPlaceholder: some View {
        ZStack {
            Color.white
            Image(systemName: "music.note")
                .font(.system(size: 36))
                .foregroundStyle(SearchDesignTokens.ink3)
        }
    }

    /// 「播放全部」：整队设为队列从第 0 首开始播；无曲目时禁用。
    private func playAllButton(_ playlist: Playlist) -> some View {
        Button {
            playback.setQueue(playlist.tracks, startAt: 0)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("播放全部")
                    .font(SearchDesignTokens.font(SearchDesignTokens.size16, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(SearchDesignTokens.accent)
            .clipShape(RoundedRectangle(cornerRadius: SearchDesignTokens.radius14))
        }
        .buttonStyle(.plain)
        .disabled(playlist.tracks.isEmpty)
        .opacity(playlist.tracks.isEmpty ? 0.4 : 1)
        .accessibilityLabel("播放全部")
    }

    // MARK: - 点行播放（与 SearchView.trackRow 同一套规则）

    /// 点行播放：同队列同位置（当前在播的同一首）点则 toggle 播放/暂停；
    /// 否则把整队歌单设为队列并从该位置开始播。
    private func trackRow(_ track: Track, in list: [Track], at index: Int) -> some View {
        let isCurrent = playback.currentTrack?.id == track.id
            && playback.currentTrack?.platform == track.platform
            && playback.currentIndex >= 0
            && playback.queue.indices.contains(playback.currentIndex)
            && playback.queue[playback.currentIndex].track.id == track.id
            && playback.queue[playback.currentIndex].track.platform == track.platform
        return TrackRowView(track: track, isCurrent: isCurrent, isCompact: isCompact) {
            if isCurrent {
                playback.togglePlay()
            } else {
                playback.setQueue(list, startAt: index)
            }
        }
    }

    // MARK: - 空态

    /// 空态：标题与曲目同时为空 = 接口没有返回数据或请求失败（桥接层无法区分，
    /// 两种可能都写清）；有标题但 0 曲目 = 该歌单暂无曲目。
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 25))
                .foregroundStyle(SearchDesignTokens.ink3)
            if let playlist = viewModel.playlist,
               !playlist.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("该歌单暂无曲目")
                    .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                    .foregroundStyle(SearchDesignTokens.ink3)
                Text("上游未返回曲目")
                    .font(SearchDesignTokens.font(SearchDesignTokens.size13))
                    .foregroundStyle(SearchDesignTokens.ink3)
            } else {
                Text("未能加载歌单详情")
                    .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                    .foregroundStyle(SearchDesignTokens.ink3)
                Text("接口没有返回数据或请求失败，请检查网络后重试")
                    .font(SearchDesignTokens.font(SearchDesignTokens.size13))
                    .foregroundStyle(SearchDesignTokens.ink3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - ViewModel

/// 歌单详情状态机：两阶段加载，不编数据。
/// 第一阶段调 NativeBridge.playlistMeta（detail 端点拿名/封面/曲数），
/// 有真名/真封面就先显示头部；第二阶段调 NativeBridge.playlistDetail
/// （有 detail 的平台内部再合一次元信息 + tracks，见其注释；无 detail 的
/// 平台 tracks-only），补全曲目。网易/QQ 的 detail 本身已回全量曲目，
/// 第一阶段后直接结束，不再调第二阶段。
/// `hasContent` = 标题或曲目任一非空；两者都空 = 无数据（空态写清两种可能）。
@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    let platform: String
    let id: String
    let isRank: Bool

    @Published private(set) var playlist: Playlist?
    @Published private(set) var isLoading = true

    private var started = false

    init(platform: String, id: String, isRank: Bool = false) {
        self.platform = platform
        self.id = id
        self.isRank = isRank
    }

    var hasContent: Bool {
        guard let playlist else { return false }
        return !playlist.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !playlist.tracks.isEmpty
    }

    func load() async {
        guard !started else { return }
        started = true
        isLoading = true
        // 第一阶段：元信息（名/封面/曲数）。无 detail 端点的平台（酷我/
        // Apple Music）这步为空，不编，直接等第二阶段。
        let meta = await NativeBridge.playlistMeta(platform: platform, id: id, isRank: isRank)
        if !meta.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || meta.coverURL != nil {
            playlist = meta
        }
        // detail 本身已回全量曲目（网易/QQ）：一次就够，不再调第二阶段。
        if !meta.tracks.isEmpty {
            playlist = meta
            isLoading = false
            return
        }
        // 第二阶段：曲目（第一阶段的 meta 传进去复用，不重复调 detail）。
        let full = await NativeBridge.playlistDetail(platform: platform, id: id, isRank: isRank,
                                                     meta: meta)
        if full.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let shown = playlist,
           !shown.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // detail 成功但 tracks 失败时 full 只有空标题：保留第一阶段
            // 已显示的真名/真封面/创建者/简介/曲数，只把曲目（空）合进来。
            var merged = full
            merged.title = shown.title
            merged.coverURL = shown.coverURL ?? merged.coverURL
            merged.creator = shown.creator.isEmpty ? merged.creator : shown.creator
            merged.description = shown.description.isEmpty ? merged.description : shown.description
            if merged.trackCount == 0 { merged.trackCount = shown.trackCount }
            playlist = merged
        } else {
            playlist = full
        }
        isLoading = false
    }
}

#Preview {
    PlaylistDetailView(platform: "netease", id: "123")
        .environmentObject(PlaybackStore())
}
