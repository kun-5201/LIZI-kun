import SwiftUI

/// 专辑页（P2-B，照抄壳版 public/pages/album.js 的布局）。
///
/// - 上：大封面 + 专辑名 / 歌手（可点 → 歌手页）/ 发行日期 / 公司 / 曲目数 + 总时长
///   + [播放全部] / [收藏] + 简介（3 行折叠，可展开）。
/// - 下：曲目表（复用 TrackRowView；点行走 PlaybackStore.setQueue 播）。
/// - 收藏调工人 C 的 AlbumShelfStore（约定 API：contains(albumId:platform:) / toggle(_:)；
///   在它落盘之前，本文件引用到的符号编译不过，属已知集成依赖，见交回报告）。
///
/// 数据来源（逐平台，见交回报告的接口调查表）：
/// - netease：GET /api/album/:id → { album: { name, cover, company, description,
///   publishTime, size, artists: [{id, name}] }, songs }。歌手 id 保留，可点进歌手页。
/// - kuwo：GET /api/kuwo/album/tracks?id= → { name, cover, total, tracks }；
///   无公司/简介/发行日期/歌手 id——歌手名取自首支曲目，仅文本展示，不可点，不编。
/// - qq / qishui / bodian / applemusic：服务端无专辑详情路由 → 诚实空态，不编数据。
///
/// 约定：
/// - 不建导航、不改 RootView/AppNavigation：返回栏沿用 SearchView 的模式，
///   由 RootView/协调员在外包一层；本页只负责内容。
/// - nav.show(.artist) 的 case 由工人 A 在 AppNavigation.swift 里加；
///   在它落盘之前，本文件引用到的 case 编译不过，属已知集成依赖。
/// - 禁缩放：SwiftUI 视图本身没有捏合/双击缩放手势，字号全部固定 pt。
/// - 封面无图用白色底 + 音符占位，不用金色（与 TrackRowView 同款占位）。
struct AlbumView: View {
    @EnvironmentObject private var nav: AppNavigation
    @EnvironmentObject private var playback: PlaybackStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @StateObject private var vm: AlbumViewModel

    init(platform: String, id: String) {
        _vm = StateObject(wrappedValue: AlbumViewModel(platform: platform, id: id))
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }

    /// 全部曲目总时长（毫秒 →「48 分 12 秒」/「1 小时 3 分」，壳版 fmtLong 口径）。
    private var totalDurationText: String {
        let ms = vm.tracks.reduce(0) { $0 + max(0, $1.durationMs) }
        let seconds = ms / 1000
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分 \(String(format: "%02d", secs)) 秒"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let reason = vm.unsupportedReason {
                    emptyState(reason)
                } else if vm.isLoading && vm.album.title.isEmpty {
                    ProgressView("专辑载入中…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                } else {
                    if vm.loadFailed {
                        Text("专辑载入失败，请检查网络后重试")
                            .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                            .foregroundStyle(SearchDesignTokens.accent)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    hero
                    tracksSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(SearchDesignTokens.paper)
        .task {
            await vm.load()
            vm.refreshCollected()
        }
    }

    // MARK: - 上半：封面 + 信息

    private var hero: some View {
        VStack(alignment: .center, spacing: 12) {
            cover
            Text(vm.album.title.isEmpty ? "未知专辑" : vm.album.title)
                .font(SearchDesignTokens.font(SearchDesignTokens.size25, weight: .bold))
                .foregroundStyle(SearchDesignTokens.ink)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            artistLine
            metaText
            actionRow
            if !vm.descriptionText.isEmpty {
                descriptionBlock
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var cover: some View {
        Group {
            ProxyImageView(url: vm.album.coverURL) { AlbumCoverPlaceholder() }
        }
        .frame(width: 240, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: SearchDesignTokens.radius14))
    }

    /// 歌手名：有 id 的可点进歌手页（网易 artists[]）；没 id 的（酷我取自曲目行）
    /// 只作纯文本展示，不做点了没反应的死按钮。
    @ViewBuilder
    private var artistLine: some View {
        if vm.artistLinks.isEmpty {
            if !vm.album.artist.isEmpty {
                Text(vm.album.artist)
                    .font(SearchDesignTokens.font(SearchDesignTokens.size16))
                    .foregroundStyle(SearchDesignTokens.ink2)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 4) {
                ForEach(Array(vm.artistLinks.enumerated()), id: \.offset) { index, link in
                    if index > 0 {
                        Text("/")
                            .font(SearchDesignTokens.font(SearchDesignTokens.size16))
                            .foregroundStyle(SearchDesignTokens.ink3)
                    }
                    Button(action: {
                        nav.show(.artist(platform: vm.platform, id: link.id))
                    }) {
                        Text(link.name)
                            .font(SearchDesignTokens.font(SearchDesignTokens.size16))
                            .foregroundStyle(SearchDesignTokens.accent)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 「2025-06-05 · 公司 · 12 首 · 48 分 12 秒」——缺失的段不编，缺了就省。
    private var metaText: some View {
        let parts = [vm.publishDateText, vm.companyText,
                     "\(vm.tracks.count) 首 · \(totalDurationText)"]
            .filter { !$0.isEmpty }
        return Group {
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(SearchDesignTokens.font(SearchDesignTokens.size13))
                    .foregroundStyle(SearchDesignTokens.ink3)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button(action: {
                if !vm.tracks.isEmpty {
                    playback.setQueue(vm.tracks, startAt: 0)
                }
            }) {
                Text("播放全部")
                    .font(SearchDesignTokens.font(SearchDesignTokens.size16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(vm.tracks.isEmpty
                                ? SearchDesignTokens.ink3 : SearchDesignTokens.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(vm.tracks.isEmpty)
            Button(action: { vm.toggleCollect() }) {
                HStack(spacing: 6) {
                    Image(systemName: vm.isCollected ? "checkmark" : "plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text(vm.isCollected ? "已在我的专辑" : "收纳到我的专辑")
                        .font(SearchDesignTokens.font(SearchDesignTokens.size14, weight: .medium))
                }
                .foregroundStyle(vm.isCollected
                                 ? SearchDesignTokens.accent : SearchDesignTokens.ink2)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .overlay(
                    RoundedRectangle(cornerRadius: SearchDesignTokens.radius10)
                        .stroke(SearchDesignTokens.ink3.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var descriptionBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(vm.descriptionText)
                .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                .foregroundStyle(SearchDesignTokens.ink2)
                .lineLimit(vm.descriptionExpanded ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: { vm.descriptionExpanded.toggle() }) {
                Text(vm.descriptionExpanded ? "收起" : "展开")
                    .font(SearchDesignTokens.font(SearchDesignTokens.size13, weight: .medium))
                    .foregroundStyle(SearchDesignTokens.accent)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 下半：曲目表

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtistSectionHeader(title: "曲目", countText: "\(vm.tracks.count) 首 · \(totalDurationText)")
            if vm.tracks.isEmpty {
                Text("这张专辑没有可播的曲目")
                    .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                    .foregroundStyle(SearchDesignTokens.ink3)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(vm.tracks.enumerated()), id: \.offset) { index, track in
                        TrackRowView(
                            track: track,
                            isCurrent: playback.currentTrack?.id == track.id
                                && playback.currentTrack?.platform == track.platform,
                            isCompact: isCompact,
                            onTap: { playback.setQueue(vm.tracks, startAt: index) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 空态

    private func emptyState(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
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

private struct AlbumCoverPlaceholder: View {
    var body: some View {
        ZStack {
            SearchDesignTokens.coverPlaceholder
            Image(systemName: "music.note")
                .font(.system(size: 48))
                .foregroundStyle(SearchDesignTokens.ink3)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class AlbumViewModel: ObservableObject {
    let platform: String
    let id: String

    @Published private(set) var album: Album
    @Published private(set) var tracks: [Track] = []
    /// 可点进歌手页的歌手（id, name）；酷我无歌手 id 时为空，歌手名只放 album.artist 纯文本。
    @Published private(set) var artistLinks: [(id: String, name: String)] = []
    /// 发行日期「yyyy-MM-dd」（网易 publishTime；酷我无此字段时为空）。
    @Published private(set) var publishDateText = ""
    @Published private(set) var companyText = ""
    @Published private(set) var descriptionText = ""
    @Published var descriptionExpanded = false
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    /// 该平台无专辑详情接口时的诚实空态文案；非空 = 整页只显示空态。
    @Published private(set) var unsupportedReason: String?
    @Published private(set) var isCollected = false

    init(platform: String, id: String) {
        self.platform = platform
        self.id = id
        self.album = Album(id: id, source: platform)
    }

    // MARK: - 加载

    func load() async {
        switch platform {
        case "netease":
            await loadNetease()
        case "kuwo":
            await loadKuwo()
        case "qq":
            unsupportedReason = "QQ 暂无专辑详情接口：服务端没有 album 详情路由。"
        case "qishui":
            unsupportedReason = "汽水暂无专辑详情接口：服务端没有 album 详情路由。"
        case "bodian":
            unsupportedReason = "波点暂无专辑详情接口：服务端没有 album 详情路由。"
        case "applemusic":
            unsupportedReason = "Apple Music 公开 API 暂无专辑详情接口。"
        default:
            unsupportedReason = "该平台暂无专辑详情接口。"
        }
    }

    /// 网易：GET /api/album/:id（normalize 形状见 NetEase.swift album/:id）。
    private func loadNetease() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let d = await NativeBridge.call(path: "/api/album/\(id)") else {
            loadFailed = true
            return
        }
        guard let info = d["album"] as? [String: Any] else {
            loadFailed = true
            return
        }
        album.title = ArtistViewModel.stringValue(info["name"])
        let cover = ArtistViewModel.stringValue(info["cover"])
        album.coverURL = URL(string: cover)
        companyText = ArtistViewModel.stringValue(info["company"])
        descriptionText = ArtistViewModel.stringValue(info["description"])
        let ms = ArtistViewModel.intValue(info["publishTime"])
        publishDateText = Self.dateText(ms: ms)
        let artists = (info["artists"] as? [[String: Any]]) ?? []
        artistLinks = artists.compactMap { a in
            let name = ArtistViewModel.stringValue(a["name"])
            let aid = ArtistViewModel.stringValue(a["id"])
            guard !name.isEmpty, !aid.isEmpty else { return nil }
            return (id: aid, name: name)
        }
        album.artist = artistLinks.map { $0.name }.joined(separator: " / ")
        tracks = ((d["songs"] as? [[String: Any]]) ?? [])
            .compactMap { Self.trackRow($0, platform: platform) }
        album.tracks = tracks
        album.trackCount = tracks.count
        if album.artist.isEmpty, let first = tracks.first {
            album.artist = first.artist
        }
    }

    /// 酷我：GET /api/kuwo/album/tracks?id= → { name, cover, total, tracks }。
    /// 无公司/简介/发行日期/歌手 id；歌手名取自首支曲目。
    private func loadKuwo() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let d = await NativeBridge.call(path: "/api/kuwo/album/tracks", query: ["id": id]) else {
            loadFailed = true
            return
        }
        album.title = ArtistViewModel.stringValue(d["name"])
        let cover = ArtistViewModel.stringValue(d["cover"])
        album.coverURL = URL(string: cover)
        tracks = ((d["tracks"] as? [[String: Any]]) ?? [])
            .compactMap { Self.trackRow($0, platform: platform) }
        album.tracks = tracks
        album.trackCount = tracks.count
        if let first = tracks.first {
            album.artist = first.artist
        }
    }

    // MARK: - 收藏（工人 C 的 AlbumShelfStore，约定 API）

    func refreshCollected() {
        guard !album.id.isEmpty else { return }
        isCollected = AlbumShelfStore.contains(albumId: album.id, platform: album.source)
    }

    func toggleCollect() {
        guard !album.id.isEmpty else { return }
        AlbumShelfStore.toggle(album)
        refreshCollected()
    }

    // MARK: - 小工具

    /// publishTime（毫秒）→「yyyy-MM-dd」；0/缺失 → 空（不编日期）。
    static func dateText(ms: Int) -> String {
        guard ms > 0 else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
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

    /// 与 ArtistViewModel.trackRow 同款：Track.from 之后补 `artists: [String]` 形状。
    static func trackRow(_ dict: [String: Any], platform: String) -> Track? {
        guard var track = Track.from(dict: dict, platform: platform) else { return nil }
        if track.artist == "未知歌手" || track.artist.isEmpty {
            let joined = joinedArtists(dict["artists"]) ?? joinedArtists(dict["ar"])
            if let joined, !joined.isEmpty { track.artist = joined }
        }
        return track
    }

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
}

#Preview {
    AlbumView(platform: "netease", id: "123")
        .environmentObject(AppNavigation())
        .environmentObject(PlaybackStore())
}
