import SwiftUI

/// rail 详情页（P2 工人 D）：4 个来源的整页（点「展开」/ 点卡片后打开）。
/// r26（用户 2026-11-20 22:39–22:40）：首页来源 chips 已删，本页目前
/// 没有首页入口——取数层与本页保留，等图纸批了接新入口时复用，
/// 不在这里重写或删掉。
///
/// 内容按 rail 形态分三种，点行行为各不相同：
/// - 曲目型（喜欢、波点 FM、精选新歌 feed）：TrackRowView 列表，点行走
///   `playback.setQueue(整份曲目, startAt: 下标)`，和搜索结果点歌一致。
/// - 歌单型（精选歌单 feed、我收藏的歌单）：歌单卡片列表，点卡在本页内下钻
///   到曲目列表（歌单曲目走 `NativeBridge.railPlaylistTracks`）。
/// - 电台频道型：频道卡片列表，点频道在本页内下钻到频道曲目
///   （走 `NativeBridge.railStationTracks`；频道曲目端点：网易
///   netease/dj/program、QQ qq/radio/tracks、
///   汽水 qishui/feed 带 mode；波点 FM 本身就是曲目列表，不下钻；
///   酷我 / Apple Music 无电台，不设入口）。
/// - 精选有多个 feed 的平台（网易 / QQ / 酷我）：顶部有 feed 切换，
///   切 feed 重新拉取；首页行只放默认 feed（见 RailsBridge）。
///
/// 导航缝合（工人 A 的活，本页不碰 AppNavigation.swift）：
/// - 本页由 RootView 的 `.rail(kind:platform:)` case 分支呈现，
///   初始化器 `init(kind:platform:)` 的字段名已按约定取
///   （`nav.show(.rail(kind: String, platform: String))`，kind 取
///   "featured" / "liked" / "playlists" / "radio"）。
/// - 歌单卡片点按：约定走 `nav.show(.playlist(...))`（工人 A / 歌单详情工人
///   落地后）；当前歌单详情页还没接线，这里先用本页内下钻展示曲目，
///   行为等价（点歌单 → 看到它的曲目 → 点行播放），接线后把
///   `drillPlaylist` 里的下钻改成 nav 调用即可。
/// - 封面无图用白色底 + 音符占位（CoverImageView），不编假封面；禁缩放
///   （SwiftUI 原生没有缩放手势，全页不加 magnification 手势）。
struct RailDetailView: View {
    let kind: RailKind
    let platform: String

    @EnvironmentObject var playback: PlaybackStore
    @EnvironmentObject var nav: AppNavigation

    @State private var result: RailResult?
    @State private var isLoading = false
    @State private var feed: String?
    /// 下钻中的歌单（nil = 在 rail 列表层）。
    @State private var drilledPlaylist: Playlist?
    /// 下钻中的电台频道（nil = 在 rail 列表层）。
    @State private var drilledStation: RadioStation?
    /// 下钻到的曲目（歌单 / 频道二选一）。
    @State private var drilledTracks: [Track] = []
    @State private var drilledTitle = ""
    @State private var drilledError: String?
    @State private var drilledLoading = false

    private var platformName: String {
        LiziPlatforms.all.first(where: { $0.id == platform })?.name ?? platform
    }

    /// 本页标题（喜欢 rail 按平台取真名，与来源 chip、
    /// 空态文案同一份事实来源 `RailKind.likedTitle(for:)`）。
    private var displayTitle: String { kind.displayTitle(platform: platform) }

    private var feeds: [(id: String, name: String)] {
        kind == .featured ? NativeBridge.featuredFeeds(for: platform) : []
    }

    private var isDrilled: Bool { drilledPlaylist != nil || drilledStation != nil }

    var body: some View {
        NavigationStack {
            Group {
                if isDrilled {
                    drilledView
                } else {
                    railView
                }
            }
            .navigationTitle(isDrilled ? drilledTitle : "\(displayTitle) · \(platformName)")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            if feed == nil {
                feed = NativeBridge.defaultFeaturedFeed(for: platform)
            }
            await load()
        }
    }

    // MARK: - rail 列表层

    private var railView: some View {
        VStack(spacing: 0) {
            if feeds.count > 1 {
                feedPicker
            }
            Group {
                if isLoading {
                    loadingView(text: "正在拉取\(displayTitle)…")
                } else if let error = result?.error {
                    errorView(error: error) { Task { await load() } }
                } else if let result, result.entries.isEmpty {
                    emptyView(reason: result.emptyReason ?? "暂无内容。")
                } else if let result {
                    List {
                        ForEach(result.entries) { entry in
                            entryRow(entry, tracks: result.tracks)
                        }
                    }
                    .listStyle(.plain)
                } else {
                    emptyView(reason: "暂无内容。")
                }
            }
        }
        .background(LiziTokens.paper)
    }

    private var feedPicker: some View {
        Picker("精选分类", selection: Binding(
            get: { feed ?? NativeBridge.defaultFeaturedFeed(for: platform) ?? "playlists" },
            set: { newFeed in
                feed = newFeed
                Task { await load() }
            }
        )) {
            ForEach(feeds, id: \.id) { f in
                Text(f.name).tag(f.id)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func entryRow(_ entry: RailEntry, tracks: [Track]) -> some View {
        switch entry {
        case .groupHeader(let text):
            Text(text)
                .font(.liziBody(size: LiziTokens.size12, weight: .semibold))
                .foregroundColor(LiziTokens.ink3)
                .listRowBackground(LiziTokens.paper)
        case .track(let track):
            TrackRowView(track: track,
                         isCurrent: playback.currentTrack?.id == track.id
                            && playback.currentTrack?.platform == track.platform,
                         isCompact: true) {
                playback.setQueue(tracks, startAt: trackIndex(track, in: tracks))
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(LiziTokens.paper)
        case .playlist(let playlist):
            Button(action: { Task { await drillPlaylist(playlist) } }) {
                playlistCardRow(playlist: playlist)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(LiziTokens.paper)
        case .station(let station):
            Button(action: { Task { await drillStation(station) } }) {
                stationCardRow(station: station)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(LiziTokens.paper)
        }
    }

    // MARK: - 下钻层（歌单 / 频道曲目）

    private var drilledView: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: backToRail) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text(displayTitle)
                            .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                    }
                    .foregroundColor(LiziTokens.ink2)
                }
                .accessibilityLabel("返回\(displayTitle)")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Group {
                if drilledLoading {
                    loadingView(text: "正在拉取曲目…")
                } else if let error = drilledError {
                    errorView(error: error) { Task { await reloadDrilled() } }
                } else if drilledTracks.isEmpty {
                    emptyView(reason: "这张歌单没有曲目")
                } else {
                    List {
                        ForEach(drilledTracks.indices, id: \.self) { i in
                            let track = drilledTracks[i]
                            TrackRowView(track: track,
                                         isCurrent: playback.currentTrack?.id == track.id
                                            && playback.currentTrack?.platform == track.platform,
                                         isCompact: true) {
                                playback.setQueue(drilledTracks, startAt: i)
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(LiziTokens.paper)
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .background(LiziTokens.paper)
    }

    private func backToRail() {
        drilledPlaylist = nil
        drilledStation = nil
        drilledTracks = []
        drilledTitle = ""
        drilledError = nil
    }

    private func reloadDrilled() async {
        if let playlist = drilledPlaylist {
            await drillPlaylist(playlist)
        } else if let station = drilledStation {
            await drillStation(station)
        }
    }

    // MARK: - 卡片行

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

    // MARK: - 通用状态

    private func loadingView(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(text)
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
        }
        .frame(maxWidth: .infinity, minHeight: 195, alignment: .center)
    }

    private func emptyView(reason: String) -> some View {
        Text(reason)
            .font(.liziBody(size: LiziTokens.size13))
            .foregroundColor(LiziTokens.ink3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 195, alignment: .center)
            .padding(.horizontal, 24)
    }

    private func errorView(error: String, onRetry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundColor(LiziTokens.accent)
            Text(error)
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink2)
                .multilineTextAlignment(.center)
            Button("重试", action: onRetry)
                .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(LiziTokens.ink)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, minHeight: 195, alignment: .center)
        .padding(.horizontal, 24)
    }

    // MARK: - 拉取

    private func trackIndex(_ track: Track, in tracks: [Track]) -> Int {
        tracks.firstIndex(where: { $0.id == track.id && $0.platform == track.platform }) ?? 0
    }

    private func load() async {
        isLoading = true
        let fetched: RailResult
        switch kind {
        case .featured:
            fetched = await NativeBridge.railFeatured(platform: platform, feed: feed)
        case .liked:
            fetched = await NativeBridge.railLiked(platform: platform)
        case .playlists:
            fetched = await NativeBridge.railMyPlaylists(platform: platform)
        case .radio:
            fetched = await NativeBridge.railRadio(platform: platform)
        }
        result = fetched
        isLoading = false
    }

    /// 点歌单卡：走歌单详情页（P2 集成缝合：工人 A 已落地 `.playlist` 路由，
    /// 不再本页内下钻；电台频道仍走本页内下钻 drillStation）。
    private func drillPlaylist(_ playlist: Playlist) async {
        nav.show(.playlist(platform: playlist.source, id: playlist.id, isRank: playlist.isRank))
    }

    /// 点电台频道卡：本页内下钻到频道曲目列表。
    private func drillStation(_ station: RadioStation) async {
        drilledStation = station
        drilledPlaylist = nil
        drilledTitle = station.name
        drilledTracks = []
        drilledError = nil
        drilledLoading = true
        let fetched = await NativeBridge.railStationTracks(platform: platform, stationId: station.id)
        drilledTracks = fetched.tracks
        drilledError = fetched.error
        drilledLoading = false
    }
}
