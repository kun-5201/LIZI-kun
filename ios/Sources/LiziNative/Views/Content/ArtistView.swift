import SwiftUI

/// 歌手页（P2-B，照抄壳版 public/pages/artist.js 的三段结构）。
///
/// - 顶部：120 头像 + 名字 + 「N 张专辑 · M 首歌」+ 简介（两行截断）。
/// - 热门：Top 10，点行走 PlaybackStore.setQueue 播。
/// - 专辑：网格，点专辑进专辑页（nav.show(.album)）。
/// - 全部歌曲：本地过滤框（只过滤已加载，不再发请求，壳版拍板）+ 排序 + 加载更多。
///
/// 数据来源（逐平台，见文件头注释与交回报告的接口调查表）：
/// - netease：/api/artist/:id（头像/简介/专辑数/歌曲数 + hotSongs 前 10 作热门）
///   + /api/artist/albums/:id（12 张一批）+ /api/artist/songs（100 首一批，order hot/time）。
/// - qishui / bodian：只有 /api/<平台>/artist/songs（50 首一批）——无头像/简介/专辑数，
///   名字取自曲目行的歌手名，无专辑网格；热门 = 歌曲列表前 10 首（上游返回顺序）。
/// - qq / kugou / kuwo / applemusic：服务端无歌手详情路由 → 诚实空态，不编数据。
///
/// 约定：
/// - 不建导航、不改 RootView/AppNavigation：返回栏沿用 SearchView 的模式，
///   由 RootView/协调员在外包一层；本页只负责内容。
/// - nav.show(.artist/.album) 的 case 由工人 A 在 AppNavigation.swift 里加；
///   在它落盘之前，本文件引用到的 case 编译不过，属已知集成依赖（见交回报告）。
/// - 禁缩放：SwiftUI 视图本身没有捏合/双击缩放手势，字号全部固定 pt。
/// - 封面无图用白色底 + 音符占位，不用金色（与 TrackRowView 同款占位）。
struct ArtistView: View {
    @EnvironmentObject private var nav: AppNavigation
    @EnvironmentObject private var playback: PlaybackStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @StateObject private var vm: ArtistViewModel

    init(platform: String, id: String) {
        _vm = StateObject(wrappedValue: ArtistViewModel(platform: platform, id: id))
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }

    private var filteredSongs: [Track] {
        let f = vm.filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !f.isEmpty else { return vm.allSongs }
        return vm.allSongs.filter {
            $0.title.lowercased().contains(f)
                || $0.artist.lowercased().contains(f)
                || $0.album.lowercased().contains(f)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let reason = vm.unsupportedReason {
                    emptyState(reason)
                } else if vm.isLoading && vm.artist.name.isEmpty {
                    ProgressView("歌手载入中…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    if vm.loadFailed {
                        Text("歌手信息载入失败，请检查网络后重试")
                            .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                            .foregroundStyle(SearchDesignTokens.accent)
                    }
                    header
                    hotSection
                    albumsSection
                    songsSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(SearchDesignTokens.paper)
        .task { await vm.load() }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            avatar
            VStack(alignment: .leading, spacing: 6) {
                Text(vm.artist.name.isEmpty ? "未知歌手" : vm.artist.name)
                    .font(SearchDesignTokens.font(SearchDesignTokens.size25, weight: .bold))
                    .foregroundStyle(SearchDesignTokens.ink)
                    .lineLimit(2)
                Text(countsText)
                    .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                    .foregroundStyle(SearchDesignTokens.ink3)
                if !vm.briefDesc.isEmpty {
                    Text(vm.briefDesc)
                        .font(SearchDesignTokens.font(SearchDesignTokens.size13))
                        .foregroundStyle(SearchDesignTokens.ink2)
                        .lineLimit(2)
                }
                if vm.platform != "netease" {
                    Text("该平台暂无歌手详情接口，仅展示歌曲列表")
                        .font(SearchDesignTokens.font(SearchDesignTokens.size12))
                        .foregroundStyle(SearchDesignTokens.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
    }

    /// 「45 张专辑 · 582 首歌」（网易）；汽水/波点没有计数接口，只写已加载数，不编总数。
    private var countsText: String {
        if vm.platform == "netease" {
            return "\(vm.albumCount) 张专辑 · \(vm.songCount) 首歌"
        }
        return "已加载 \(vm.allSongs.count) 首"
    }

    private var avatar: some View {
        Group {
            ProxyImageView(url: vm.artist.coverURL) { placeholder }
        }
        .frame(width: 120, height: 120)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ZStack {
            SearchDesignTokens.coverPlaceholder
            Image(systemName: "music.note")
                .font(.system(size: 36))
                .foregroundStyle(SearchDesignTokens.ink3)
        }
    }

    // MARK: - 热门 Top 10

    private var hotSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtistSectionHeader(title: "热门", countText: "Top 10")
            if vm.hotTracks.isEmpty {
                Text("没有热门曲目")
                    .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                    .foregroundStyle(SearchDesignTokens.ink3)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(vm.hotTracks.enumerated()), id: \.offset) { index, track in
                        TrackRowView(
                            track: track,
                            isCurrent: playback.currentTrack?.id == track.id
                                && playback.currentTrack?.platform == track.platform,
                            isCompact: isCompact,
                            onTap: { playback.setQueue(vm.hotTracks, startAt: index) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 专辑网格

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtistSectionHeader(
                title: "专辑",
                countText: vm.platform == "netease" && vm.albumCount > 0
                    ? "\(vm.albums.count) / \(vm.albumCount)" : "\(vm.albums.count) 张"
            )
            if vm.albums.isEmpty {
                Text(vm.platform == "netease" ? "这个歌手还没有专辑" : "该平台暂无歌手专辑接口")
                    .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                    .foregroundStyle(SearchDesignTokens.ink3)
                    .padding(.vertical, 4)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 16
                ) {
                    ForEach(vm.albums) { album in
                        ArtistAlbumCard(
                            album: album,
                            yearText: ArtistViewModel.yearText(for: album, years: vm.albumYears),
                            onTap: { nav.show(.album(platform: album.source, id: album.id)) }
                        )
                    }
                }
                if vm.albumsMore {
                    Button(action: { Task { await vm.loadMoreAlbums() } }) {
                        Text(vm.albumsLoading ? "载入中…" : "加载更多")
                            .font(SearchDesignTokens.font(SearchDesignTokens.size14, weight: .medium))
                            .foregroundStyle(SearchDesignTokens.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.albumsLoading)
                }
            }
        }
    }

    // MARK: - 全部歌曲

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtistSectionHeader(
                title: "全部歌曲",
                countText: vm.songTotal > 0
                    ? "\(vm.allSongs.count) / \(vm.songTotal) 首" : "\(vm.allSongs.count) 首"
            )
            HStack(spacing: 8) {
                TextField("搜索他的歌", text: $vm.filter)
                    .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(SearchDesignTokens.paper2)
                    .clipShape(RoundedRectangle(cornerRadius: SearchDesignTokens.radius10))
                if vm.platform == "netease" {
                    Picker("排序", selection: $vm.order) {
                        Text("热度").tag(ArtistSongOrder.hot)
                        Text("时间").tag(ArtistSongOrder.time)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                    .onChange(of: vm.order) { _ in
                        Task { await vm.reloadSongs() }
                    }
                }
            }
            if filteredSongs.isEmpty {
                Text(vm.filter.isEmpty ? "还没有歌" : "已加载的 \(vm.allSongs.count) 首里没有匹配「\(vm.filter)」")
                    .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                    .foregroundStyle(SearchDesignTokens.ink3)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredSongs.enumerated()), id: \.offset) { _, track in
                        TrackRowView(
                            track: track,
                            isCurrent: playback.currentTrack?.id == track.id
                                && playback.currentTrack?.platform == track.platform,
                            isCompact: isCompact,
                            onTap: {
                                if let index = vm.allSongs.firstIndex(of: track) {
                                    playback.setQueue(vm.allSongs, startAt: index)
                                }
                            }
                        )
                    }
                }
            }
            if vm.songsMore && vm.filter.isEmpty {
                Button(action: { Task { await vm.loadMoreSongs() } }) {
                    Text(vm.songsLoading ? "载入中…" : "加载更多")
                        .font(SearchDesignTokens.font(SearchDesignTokens.size14, weight: .medium))
                        .foregroundStyle(SearchDesignTokens.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .disabled(vm.songsLoading)
            }
        }
    }

    // MARK: - 空态

    private func emptyState(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(SearchDesignTokens.ink3)
            Text(reason)
                .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                .foregroundStyle(SearchDesignTokens.ink2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }
}

// MARK: - 专辑卡片

private struct ArtistAlbumCard: View {
    let album: Album
    let yearText: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    ProxyImageView(url: album.coverURL) { ArtistAlbumPlaceholder() }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: SearchDesignTokens.radius10))
                Text(album.title)
                    .font(SearchDesignTokens.font(SearchDesignTokens.size14, weight: .semibold))
                    .foregroundStyle(SearchDesignTokens.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !yearText.isEmpty {
                    Text(yearText)
                        .font(SearchDesignTokens.font(SearchDesignTokens.size12))
                        .foregroundStyle(SearchDesignTokens.ink3)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ArtistAlbumPlaceholder: View {
    var body: some View {
        ZStack {
            SearchDesignTokens.coverPlaceholder
            Image(systemName: "music.note")
                .font(.system(size: 28))
                .foregroundStyle(SearchDesignTokens.ink3)
        }
    }
}

/// 内容页小节标题（「热门 Top 10」/「专辑 12 / 45」这种；AlbumView 共用）。
struct ArtistSectionHeader: View {
    let title: String
    let countText: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(SearchDesignTokens.font(SearchDesignTokens.size20, weight: .bold))
                .foregroundStyle(SearchDesignTokens.ink)
            Text(countText)
                .font(SearchDesignTokens.font(SearchDesignTokens.size13))
                .foregroundStyle(SearchDesignTokens.ink3)
            Spacer()
        }
    }
}

// MARK: - ViewModel

/// 歌手页排序（只网易支持 order 参数；汽水/波点上游无排序参数，不显示切换）。
enum ArtistSongOrder: String {
    case hot
    case time
}

@MainActor
final class ArtistViewModel: ObservableObject {
    let platform: String
    let id: String

    @Published private(set) var artist: Artist
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    /// 该平台无歌手详情接口时的诚实空态文案；非空 = 整页只显示空态。
    @Published private(set) var unsupportedReason: String?
    /// 网易 /api/artist/:id 回的计数与简介（其它平台没有，不编）。
    @Published private(set) var albumCount = 0
    @Published private(set) var songCount = 0
    @Published private(set) var briefDesc = ""
    @Published private(set) var hotTracks: [Track] = []
    @Published private(set) var albums: [Album] = []
    /// 专辑 id → publishTime（毫秒）；Album 模型没有发行时间字段，放这里不改模型。
    @Published private(set) var albumYears: [String: Int] = [:]
    @Published private(set) var albumsMore = false
    @Published private(set) var albumsLoading = false
    @Published private(set) var allSongs: [Track] = []
    @Published private(set) var songTotal = 0
    @Published private(set) var songsMore = false
    @Published private(set) var songsLoading = false
    @Published var order: ArtistSongOrder = .hot
    @Published var filter = ""

    init(platform: String, id: String) {
        self.platform = platform
        self.id = id
        self.artist = Artist(id: id, source: platform)
    }

    // MARK: - 加载

    func load() async {
        switch platform {
        case "netease":
            await loadNetease()
        case "qishui", "bodian":
            await loadSongListOnly()
        case "qq":
            unsupportedReason = "QQ 音乐暂无歌手详情接口：歌手 id 是 songmid 字符串，服务端没有 artist 详情路由（壳版同样不接 QQ 歌手页）。"
        case "kugou":
            unsupportedReason = "酷狗暂无歌手详情接口：服务端没有 artist 详情路由。"
        case "kuwo":
            unsupportedReason = "酷我暂无歌手详情接口：服务端没有 artist 详情路由（仅有专辑曲目接口）。"
        case "applemusic":
            unsupportedReason = "Apple Music 公开 API 暂无歌手详情接口。"
        default:
            unsupportedReason = "该平台暂无歌手详情接口。"
        }
    }

    /// 网易：头部 + 专辑 + 全部歌曲并行拉（壳版 artist.js 同样并行）。
    private func loadNetease() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let header = NativeBridge.call(path: "/api/artist/\(id)")
        async let albumsResp = NativeBridge.call(
            path: "/api/artist/albums/\(id)", query: ["limit": "12", "offset": "0"])
        async let songsResp = NativeBridge.call(
            path: "/api/artist/songs",
            query: ["id": id, "limit": "100", "offset": "0", "order": "hot"])
        let (h, a, s) = await (header, albumsResp, songsResp)
        if let h, let info = h["artist"] as? [String: Any] {
            artist.name = Self.stringValue(info["name"])
            let avatar = [info["avatar"], info["cover"], info["picUrl"]]
                .compactMap { Self.stringValue($0) }.first(where: { !$0.isEmpty }) ?? ""
            artist.coverURL = URL(string: avatar)
            albumCount = Self.intValue(info["albumSize"])
            songCount = Self.intValue(info["musicSize"])
            briefDesc = Self.stringValue(info["briefDesc"])
            hotTracks = ((h["hotSongs"] as? [[String: Any]]) ?? [])
                .compactMap { Self.trackRow($0, platform: platform) }
                .prefix(10).map { $0 }
        } else {
            loadFailed = true
        }
        if let a, let rows = a["albums"] as? [[String: Any]] {
            applyAlbums(rows, reset: true)
            albumsMore = (a["more"] as? NSNumber)?.boolValue ?? false
        }
        if let s, let rows = s["songs"] as? [[String: Any]] {
            applySongs(rows, total: Self.intValue(s["total"]), reset: true)
        }
    }

    /// 汽水/波点：只有歌曲列表接口（/api/<平台>/artist/songs，50 首一批）。
    /// 无头像/简介/专辑数：名字取自曲目行的歌手名；热门 = 列表前 10 首。
    private func loadSongListOnly() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let path = "/api/\(platform)/artist/songs"
        guard let d = await NativeBridge.call(path: path, query: ["id": id, "limit": "50", "offset": "0"]),
              let rows = d["tracks"] as? [[String: Any]] else {
            loadFailed = true
            return
        }
        applySongs(rows, total: 0, reset: true)
        songsMore = rows.count >= 50
        if artist.name.isEmpty, let first = allSongs.first {
            artist.name = first.artist
        }
        hotTracks = Array(allSongs.prefix(10))
    }

    func loadMoreAlbums() async {
        guard platform == "netease", albumsMore, !albumsLoading else { return }
        albumsLoading = true
        defer { albumsLoading = false }
        guard let d = await NativeBridge.call(
            path: "/api/artist/albums/\(id)",
            query: ["limit": "12", "offset": "\(albums.count)"]),
            let rows = d["albums"] as? [[String: Any]] else { return }
        applyAlbums(rows, reset: false)
        albumsMore = (d["more"] as? NSNumber)?.boolValue ?? false
    }

    func loadMoreSongs() async {
        guard !songsLoading else { return }
        songsLoading = true
        defer { songsLoading = false }
        let path: String
        let query: [String: String]
        switch platform {
        case "netease":
            path = "/api/artist/songs"
            query = ["id": id, "limit": "100", "offset": "\(allSongs.count)", "order": order.rawValue]
        case "qishui", "bodian":
            path = "/api/\(platform)/artist/songs"
            query = ["id": id, "limit": "50", "offset": "\(allSongs.count)"]
        default:
            return
        }
        guard let d = await NativeBridge.call(path: path, query: query) else { return }
        let key = platform == "netease" ? "songs" : "tracks"
        guard let rows = d[key] as? [[String: Any]] else { return }
        if platform == "netease" {
            applySongs(rows, total: Self.intValue(d["total"]), reset: false)
        } else {
            let before = allSongs.count
            allSongs.append(contentsOf: rows.compactMap { Self.trackRow($0, platform: platform) })
            songsMore = rows.count >= 50
            if allSongs.count == before { songsMore = false }
            hotTracks = Array(allSongs.prefix(10))
        }
    }

    /// 切换排序（只网易）：清空重拉第一页。
    func reloadSongs() async {
        guard platform == "netease" else { return }
        allSongs = []
        songTotal = 0
        songsMore = false
        guard let d = await NativeBridge.call(
            path: "/api/artist/songs",
            query: ["id": id, "limit": "100", "offset": "0", "order": order.rawValue]),
            let rows = d["songs"] as? [[String: Any]] else { return }
        applySongs(rows, total: Self.intValue(d["total"]), reset: true)
    }

    // MARK: - 归一化（只解析本页要的字段；不改 NativeBridge/Track.from）

    private func applyAlbums(_ rows: [[String: Any]], reset: Bool) {
        var parsed: [Album] = []
        for row in rows {
            guard let album = Self.albumRow(row, platform: platform) else { continue }
            let ms = Self.intValue(row["publishTime"])
            if ms > 0 { albumYears[album.id] = ms }
            parsed.append(album)
        }
        albums = reset ? parsed : albums + parsed
        artist.albums = albums
    }

    private func applySongs(_ rows: [[String: Any]], total: Int, reset: Bool) {
        let parsed = rows.compactMap { Self.trackRow($0, platform: platform) }
        allSongs = reset ? parsed : allSongs + parsed
        songTotal = total > 0 ? total : allSongs.count
        songsMore = !parsed.isEmpty && allSongs.count < songTotal
    }

    /// 专辑网格卡片的年份行：「2024 · 12 首」；年份/曲目数缺失的段不编，缺了就省。
    static func yearText(for album: Album, years: [String: Int]) -> String {
        var parts: [String] = []
        if let ms = years[album.id], ms > 0 {
            let year = Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
            parts.append("\(year)")
        }
        if album.trackCount > 0 { parts.append("\(album.trackCount) 首") }
        return parts.joined(separator: " · ")
    }

    /// 歌手专辑行：{ id, name, cover, publishTime, size }（网易 normalize 的形状）。
    static func albumRow(_ dict: [String: Any], platform: String) -> Album? {
        let id = stringValue(dict["id"])
        guard !id.isEmpty else { return nil }
        let name = stringValue(dict["name"])
        guard !name.isEmpty else { return nil }
        let cover = stringValue(dict["cover"])
        var album = Album(
            id: id, title: name, coverURL: URL(string: cover),
            source: platform, trackCount: intValue(dict["size"]))
        if album.trackCount == 0 { album.trackCount = intValue(dict["songCount"]) }
        return album
    }

    /// 曲目行：Track.from 之后，把它解析不到的 `artists: [String]`（汽水/波点）
    /// 再补一次——Track.from 只认 String / [[String: Any]] 两种 artists 形状，
    /// [String] 会掉成「未知歌手」（P1 已有缺口，本页本地补，不动共享代码）。
    static func trackRow(_ dict: [String: Any], platform: String) -> Track? {
        guard var track = Track.from(dict: dict, platform: platform) else { return nil }
        if track.artist == "未知歌手" || track.artist.isEmpty {
            let joined = joinedArtists(dict["artists"]) ?? joinedArtists(dict["ar"])
            if let joined, !joined.isEmpty { track.artist = joined }
        }
        return track
    }

    /// artists 三种形状都认：String / [String] / [{name}]。
    static func joinedArtists(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let arr = value as? [String] {
            let names = arr.filter { !$0.isEmpty }
            return names.isEmpty ? nil : names.joined(separator: " / ")
        }
        if let arr = value as? [[String: Any]] {
            let names = arr.compactMap { stringValue($0["name"]) }.filter { !$0.isEmpty }
            return names.isEmpty ? nil : names.joined(separator: " / ")
        }
        return nil
    }

    static func intValue(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let n = Int(s) { return n }
        return 0
    }

    static func stringValue(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }
}

#Preview {
    ArtistView(platform: "netease", id: "6452")
        .environmentObject(AppNavigation())
        .environmentObject(PlaybackStore())
}
