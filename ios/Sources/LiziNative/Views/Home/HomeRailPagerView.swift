import SwiftUI

/// r28 分页器栏内容（Views/Home/HomeRailPagerView.swift，r28 唯一新文件）：
/// 每日推荐之外的 5 栏（精选 / 用户收藏 / 喜欢的歌曲 / 用户创建的歌单 / 电台）
/// 在面板里的样子。栏里条目的形状照壳版 `public/app.js` 的 marqCardHtml
/// （约 12344–12400 行）1:1 抄（只换容器为上下翻页一次一栏，不搬壳版代码；
/// 行组件复用 RailDetailView 同款，不另起形状）：
/// - 曲目行 = 封面 + 歌名 + 歌手·专辑 + 时长（TrackRowView，与 RailDetailView 同款）；
/// - 歌单/电台卡 = 封面 56 + 名字 + 创建者·数量 + chevron
///   （与 RailDetailView 的 playlistCardRow / stationCardRow 同款；
///   壳版卡上还有「歌单/电台」小签，副标题已写清数量/创建者，这里不另贴签）；
/// - 分组说明卡（网易「我创建的歌单 / 我收藏的歌单」、Apple Music
///   「官方热门歌单（非本人收藏）」、本地星标说明）= 12pt 小字行，不可点
///   （壳版 marq__card--group 同款）。
/// - 平台返回类型本来就不同（见 RailsBridge 文件头）：网易/QQ/波点精选=歌单、
///   酷狗/汽水精选=曲目、酷我精选=排行榜（歌单）；空态文案原样保留
///   （如「这一层没有歌曲」「这一层没有歌单」与各平台诚实原因）。
///
/// 面板是定高窗：最多放 3 条可点条目（竖屏内容区约 255pt，行约 68–72pt，
/// 再加「查看全部」一行正好放下；横屏面板只有约 140 高，栏头 + 条占掉
/// 大半后 rail 栏只剩约一行的位置、其余裁断是模板原意），其余走底部
/// 「查看全部」进 RailDetailView 整页。
/// 点行行为与 RailDetailView 一致：曲目点播（setQueue 整份曲目，含分组卡
/// 之后的全部曲目）、歌单卡进歌单详情页（.playlist 路由）、电台频道卡
/// 进电台整页（.rail radio；频道下钻在详情页里点，面板不另做下钻层；
/// 波点电台本身就是曲目，点行直接播）。
/// 加载/失败/空态走 RailDetailView 同款三态（文案由 RailsBridge 原样给）。
/// 取数在 `HomeViewModel.loadRailPage`（切到某栏时再拉该栏、首次拉取后缓存，
/// 喜欢栏每次切回都重拉——本地星标一点就变，壳版同款不缓存）。
struct HomeRailPageView: View {
    @ObservedObject var viewModel: HomeViewModel
    @EnvironmentObject private var playback: PlaybackStore
    @EnvironmentObject private var nav: AppNavigation

    /// 面板里最多放几条可点条目（分组说明卡不占名额；见文件头高度账）。
    private static let maxRows = 3

    private var page: HomeRailPage { viewModel.railPage }
    private var platform: String { viewModel.selectedPlatform }

    var body: some View {
        Group {
            if viewModel.isRailPageLoading(page) || viewModel.railResults[page] == nil {
                loadingView
            } else if let error = viewModel.railResults[page]?.error {
                errorView(error: error)
            } else if let reason = viewModel.railEmptyReason(for: page) {
                emptyView(reason: reason)
            } else {
                entriesView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 列表层

    private var entriesView: some View {
        let entries = viewModel.railEntries(for: page)
        let tracks = entries.compactMap { entry -> Track? in
            if case .track(let track) = entry { return track }
            return nil
        }
        let shown = visibleEntries(entries)
        let total = entries.filter { entry in
            if case .groupHeader = entry { return false }
            return true
        }.count
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { entry in
                entryRow(entry, tracks: tracks)
            }
            if viewModel.isMixedPlaylistsPage(page) {
                Text("该平台接口不区分自建与收藏，两页显示同一份歌单。")
                    .font(.liziBody(size: LiziTokens.size12))
                    .foregroundColor(LiziTokens.ink3)
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
            viewAllButton(total: total)
        }
    }

    /// 面板里放得下的条目（按顺序取最多 maxRows 条可点条目，路过的
    /// 分组说明卡一并带上、不占名额；超出的走「查看全部」）。
    private func visibleEntries(_ entries: [RailEntry]) -> [RailEntry] {
        var out: [RailEntry] = []
        var count = 0
        for entry in entries {
            if case .groupHeader = entry { out.append(entry); continue }
            guard count < Self.maxRows else { break }
            out.append(entry)
            count += 1
        }
        return out
    }

    @ViewBuilder
    private func entryRow(_ entry: RailEntry, tracks: [Track]) -> some View {
        switch entry {
        case .groupHeader(let text):
            Text(text)
                .font(.liziBody(size: LiziTokens.size12, weight: .semibold))
                .foregroundColor(LiziTokens.ink3)
                .padding(.vertical, 4)
        case .track(let track):
            TrackRowView(
                track: track,
                isCurrent: playback.currentTrack?.id == track.id
                    && playback.currentTrack?.platform == track.platform,
                isCompact: true
            ) {
                playback.setQueue(tracks, startAt: trackIndex(track, in: tracks))
            }
        case .playlist(let playlist):
            Button(action: {
                nav.show(.playlist(platform: playlist.source, id: playlist.id, isRank: playlist.isRank))
            }) {
                playlistCardRow(playlist: playlist)
            }
            .buttonStyle(.plain)
        case .station(let station):
            Button(action: { nav.show(.rail(kind: "radio", platform: platform)) }) {
                stationCardRow(station: station)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func viewAllButton(total: Int) -> some View {
        if let kind = page.railKind {
            Button(action: { nav.show(.rail(kind: kind.rawValue, platform: platform)) }) {
                HStack(spacing: 4) {
                    Text(total > Self.maxRows ? "查看全部（共 \(total) 项）" : "查看全部")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                .foregroundColor(LiziTokens.ink2)
            }
            .padding(.top, 8)
            .accessibilityLabel("查看全部\(page.title(platform: platform))")
        }
    }

    // MARK: - 卡片行（与 RailDetailView 同款形状，见文件头）

    private func playlistCardRow(playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            CoverImageView(url: playlist.coverURL, placeholderIconSize: 20)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.liziBody(size: LiziTokens.size16, weight: .semibold))
                    .foregroundColor(LiziTokens.ink)
                    .lineLimit(1)
                Text(playlistSubtitle(playlist: playlist))
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(LiziTokens.ink3)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func stationCardRow(station: RadioStation) -> some View {
        HStack(spacing: 12) {
            CoverImageView(url: station.coverURL, placeholderIconSize: 20)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .font(.liziBody(size: LiziTokens.size16, weight: .semibold))
                    .foregroundColor(LiziTokens.ink)
                    .lineLimit(1)
                Text(stationSubtitle(station: station))
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(LiziTokens.ink3)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func playlistSubtitle(playlist: Playlist) -> String {
        var parts: [String] = []
        if !playlist.creator.isEmpty { parts.append(playlist.creator) }
        if playlist.trackCount > 0 { parts.append("\(playlist.trackCount) 首") }
        return parts.joined(separator: " · ")
    }

    private func stationSubtitle(station: RadioStation) -> String {
        var parts: [String] = []
        if !station.creator.isEmpty { parts.append(station.creator) }
        if station.trackCount > 0 { parts.append("\(station.trackCount) 期节目") }
        if station.playCount > 0 { parts.append("播放 \(station.playCount)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 通用状态（RailDetailView 同款三态，面板内居中）

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("正在拉取\(page.title(platform: platform))…")
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func emptyView(reason: String) -> some View {
        Text(reason)
            .font(.liziBody(size: LiziTokens.size13))
            .foregroundColor(LiziTokens.ink3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 24)
    }

    private func errorView(error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundColor(LiziTokens.accent)
            Text(error)
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink2)
                .multilineTextAlignment(.center)
            Button("重试") {
                viewModel.loadRailPage(page, force: true)
            }
            .font(.liziBody(size: LiziTokens.size14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(LiziTokens.ink)
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 24)
    }

    // MARK: - 工具

    private func trackIndex(_ track: Track, in tracks: [Track]) -> Int {
        tracks.firstIndex(where: { $0.id == track.id && $0.platform == track.platform }) ?? 0
    }
}
