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
///   接口本身带名/封面/总数；酷我榜单是 tracks-only（r35-10 起排行榜块
///   点卡时传目录卡片的榜单名/封面当种子，第一阶段先用种子显示头部，
///   第二阶段回来保留真名真封面只补曲目；没种子的旧入口仍显示
///   「〈平台名〉歌单」通用名，封面用深色默认封面（r36：第⑥件全站占位
///   统一深色，不许白底），曲目数显示已加载数）；Apple Music tracks 回包带 name/cover（r25-B4：
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
    /// r36：排行榜详情的封面轮播状态机（独立实例，与首页环分开；
    /// 只在 isRank 分支用，普通歌单详情不用）。
    @StateObject private var rankRingModel = HomeCoverRingModel()

    init(platform: String, id: String, isRank: Bool = false,
         title: String? = nil, coverURL: URL? = nil) {
        self.platform = platform
        self.id = id
        self.isRank = isRank
        _viewModel = StateObject(wrappedValue: PlaylistDetailViewModel(
            platform: platform, id: id, isRank: isRank, title: title, coverURL: coverURL))
    }

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
        // r39-5：第 5 件——外层 GeometryReader 实测宽（HomeView 外层同款），
        // 传给环的 screenWidth，让详情页 3D 环走第 5 件新几何，
        // 不再以 screenWidth=0 回落旧 tier 分档。
        GeometryReader { geo in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    headerView(playlist)
                    playAllButton(playlist)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    Divider()
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    if isRank && !playlist.tracks.isEmpty {
                    // r36（用户 21:27 + 21:41 + 21:43 + 21:44 + v4）：
                    // 排行榜详情里的歌按首页那样一张一张卡片显示——首页封面
                    // 轮播（真封面、横向轮播、当前大张居中、左右露出相邻封面、
                    // 封面下歌名 + 歌手），不是普通列表、不是网格。
                    // 不带排名数字（21:43 作废 r35-10 的行首排名数字）、
                    // 不显示多少首（21:44）、不加任何提示文字（21:44，
                    // hideEntryHint）。全量曲目（100/1000 首）都进轮播，
                    // 取数走 playlistDetail isRank 全量（见 NativeBridge）。
                    // 点卡播歌走环自带的 playTrack（setQueue 整队从该下标
                    // 起播）；「播放全部」按钮保留，点行播放逻辑不动。
                    // 只改排行榜详情这支，普通歌单详情保持原样（下面的
                    // ForEach 列表行）。
                    HomeCoverRingView(
                        model: rankRingModel,
                        dailyTracks: playlist.tracks,
                        marqueeSpeed: 24,
                        tier: PlayerTokens.sizeTier(for: UIScreen.main.bounds.size, topInset: 0),
                        panelIsDark: false,
                        hideEntryHint: true,
                        screenWidth: geo.size.width, // r39-5：第 5 件——实测宽，不回落旧分档
                        screenHeight: geo.size.height // r43-1：第 1 件——实测高，判横竖屏用（成员初始化器顺序：screenHeight 是末位存储属性，调用点必须放最后）
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                } else {
                    // r54（用户 2026-11-23：自建歌单「精选」——点开歌单后，
                    // 里面的歌要像「今日推荐」那样变成卡片显示出来）：
                    // 普通歌单详情的曲目也走 HomeCoverRingView（与上面 isRank
                    // 分支、首页每日推荐同一套卡片，不另起一套样子；
                    // coverOnly: true 与每日推荐同款——封面未到先盖歌名占位；
                    // 入口提示行不隐藏，与每日推荐一致。点卡播歌走环自带的
                    // playTrack：整份歌单 setQueue、从点中的起播，队列就是
                    // 该歌单的歌；封面跟换走 r54 的 ProxyImageView 修法）。
                    HomeCoverRingView(
                        model: rankRingModel,
                        dailyTracks: playlist.tracks,
                        marqueeSpeed: 24,
                        tier: PlayerTokens.sizeTier(for: UIScreen.main.bounds.size, topInset: 0),
                        panelIsDark: false,
                        coverOnly: true,
                        screenWidth: geo.size.width, // r39-5：第 5 件——实测宽，不回落旧分档
                        screenHeight: geo.size.height // r43-1：第 1 件——实测高，判横竖屏用（成员初始化器顺序：screenHeight 是末位存储属性，调用点必须放最后）
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }
            .padding(.bottom, 24)
            }
        }
        // 环的 3D 展开态要这个坐标空间锚点（HomeView 同款，见 HomeView.swift）。
        .coordinateSpace(name: "liziHome")
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
                    // r36（用户 21:44）：榜单详情页不显示歌的数量（「共 N 首」
                    // 之类）；普通歌单详情照旧显示。
                    if !isRank {
                        Text(countText(playlist))
                            .font(SearchDesignTokens.font(SearchDesignTokens.size13))
                            .foregroundStyle(SearchDesignTokens.ink3)
                    }
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

    /// 封面大图（120pt）：有图显示真图，无图/加载失败深色默认封面
    /// （r36 第⑥件：全站占位统一深色 DefaultCoverArt，不许白底）。
    /// CoverImageView 自带重试（见 CoverImageLoader.swift）。
    @ViewBuilder
    private func coverView(url: URL?) -> some View {
        CoverImageView(url: url, placeholderIconSize: 36)
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: SearchDesignTokens.radius14))
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
/// r35-10（P0-4）：排行榜块点卡时 init 传了目录卡片的榜单名/封面种子，
/// load 起手先用种子显示头部（不等网络），第二阶段的 merge 保留它
/// （full 没真名时留 shown），上游给了真名真封面时以上游为准。
/// 第一阶段后直接结束，不再调第二阶段。
/// `hasContent` = 标题或曲目任一非空；两者都空 = 无数据（空态写清两种可能）。
@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    let platform: String
    let id: String
    let isRank: Bool
    /// 排行榜块点卡时传的页头种子（r35-10 P0-4）：目录卡片的榜单名/封面。
    /// 第一阶段先用它显示头部，第二阶段回来保留真名真封面只补曲目
    /// （下面的 merge 已守着：full 没真名时留 shown；full 有真名时以上游为准）。
    let seedTitle: String?
    let seedCoverURL: URL?

    @Published private(set) var playlist: Playlist?
    @Published private(set) var isLoading = true

    private var started = false

    init(platform: String, id: String, isRank: Bool = false,
         title: String? = nil, coverURL: URL? = nil) {
        self.platform = platform
        self.id = id
        self.isRank = isRank
        self.seedTitle = title
        self.seedCoverURL = coverURL
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
        // r35-10（P0-4）：有页头种子时第一阶段先用种子显示头部（不等网络；
        // 酷我榜单、QQ/酷狗榜单的 playlistMeta 本来就回空，种子是唯一
        // 的第一阶段头部来源）。第二阶段的 merge 会保留它（full 没真名
        // 时留 shown），上游给了真名真封面时以上游为准。
        if let seed = seedTitle,
           !seed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            playlist = Playlist(id: id, title: seed, coverURL: seedCoverURL, source: platform)
        }
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
