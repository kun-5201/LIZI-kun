import Foundation

/// P2 四条 rails：精选 / 喜欢 / 我收藏的歌单 / 电台（`extension NativeBridge`）。
/// 喜欢 rail 的标题按平台取真名（见 `RailKind.likedTitle(for:)`）。
///
/// 只加方法，不改 NativeBridge.swift 本体。端点照抄壳版 `public/api.js`，
/// 逐平台映射照抄壳版 `public/app.js` 的 railFeatured / railLiked /
/// railMyPlaylists / railRadio（约 11983–12250 行），`call` 的 path 一律带
/// `/api` 前缀，与 NativeBridge 现有方法一致。
///
/// 逐平台映射（端点 = Router 直调路径；空态原因见各方法内的文案）：
/// - featured（精选）：netease → /api/top/playlist（limit 12，默认 feed）
///   / newsong feed → /api/personalized；qq → /api/qq/recommend/playlists（9）
///   / newsongs feed → /api/qq/recommend/new-songs（30）；
///   kugou → /api/kugou/top/playlists（12）/ newsongs feed → /api/kugou/top/songs；
///   qishui → /api/qishui/feed（20）；bodian → /api/bodian/recommendations；
///   kuwo → /api/kuwo/recommend/playlists（12）/ ranks feed → /api/kuwo/rank/list；
///   applemusic → /api/applemusic/playlists（12）。
/// - liked（喜欢 rail，标题按平台取真名，唯一事实来源是
///   `RailKind.likedTitle(for:)`；行标题 / 来源 chip / 空态文案 /
///   详情页标题都从那里取，三处一致）：
///   netease → 「我喜欢的音乐」（上游歌单 `name` 字段本名，
///   specialType==5，未登录 → 诚实空态「先登录」），再走 playlistDetail；
///   qq → 「我喜欢」（QQ dirid 201 收藏夹；接口只回曲目不回名字，
///   名字见壳版 `public/app.js:11373` 注释「QQ → 我喜欢」）；
///   qishui → 「我喜欢的音乐」（账号歌单里 `base_info.type==1` 那张，
///   见 `specs/sidecars.md`「type=1 是账号的「我喜欢的音乐」歌单」），
///   再 /api/qishui/playlist/tracks；
///   bodian → 真名未核实到（fond 接口只回歌单对象、原生只取了 id，
///   仓内无字面记载），保持「我的喜欢」，不编；
///   kugou / kuwo / applemusic → 没有喜欢接口，rail 里只有本地星标，
///   标题如实叫「本地星标收藏」，没有就诚实空态写清原因。
/// - playlists（我收藏的歌单）：netease → /api/user/playlist，分我创建
///   （subscribed==false）/ 我收藏（subscribed==true），未登录 → 诚实空态；
///   qq / kugou / qishui / bodian → 各自 /api/<platform>/user/playlists
///   （汽水滤掉 isLikedPlaylist 那张）；kuwo → 无用户歌单接口，诚实空态；
///   applemusic → /api/applemusic/playlists 兜底，前面插说明卡
///   「官方热门歌单（非本人收藏）」。
/// - radio（电台）：netease → /api/netease/dj/recommend（8）；
///   qq → /api/qq/radio/categories；kugou → /api/kugou/fm/class；
///   qishui → /api/qishui/feed/modes；bodian → /api/bodian/personal/fm
///   （直接是曲目）；kuwo → 只有栏目目录、无单集曲目接口，诚实空态不冒充；
///   applemusic → 公开接口无电台，诚实空态。
/// - 频道曲目（详情页下钻）：netease → /api/netease/dj/program；
///   qq → /api/qq/radio/tracks；kugou → /api/kugou/fm/songs；
///   qishui → /api/qishui/feed 带 mode；bodian FM 本身就是曲目列表；
///   kuwo / applemusic 无电台不设入口。
/// - 歌单曲目（详情页下钻）：复用 NativeBridge.playlistDetail，
///   另加 bodian（/api/bodian/playlist/tracks）与 kuwo 榜单
///   （/api/kuwo/rank/tracks，拿不到再回 /api/kuwo/playlist/tracks）。
///
/// 错误通道（参照 P1 SearchResult.errors 的做法）：
/// - `error` 非空 = 请求本身失败（call 回 nil，或上游回了 error / 非 0/200 code），
///   UI 要明示失败原因；
/// - `emptyReason` 非空 = 请求通了但内容为空（未登录 / 接口缺失 / 本地星标为空），
///   UI 显示诚实原因；两者都不填 = 有内容。绝不静默空列表。
/// - 未登录态（当前原生版未登录，登录迁移是 P4）：需要登录的 rail 在本阶段
///   只显示诚实空态，不搭登录 UI。
enum RailKind: String, CaseIterable, Hashable {
    case featured   // 精选
    case liked      // 喜欢 rail（标题按平台取真名，见 likedTitle）
    case playlists  // 我收藏的歌单
    case radio      // 电台

    var title: String {
        switch self {
        case .featured: return "精选"
        case .liked: return "我的喜欢"
        case .playlists: return "我收藏的歌单"
        case .radio: return "电台"
        }
    }

    /// 喜欢 rail 按平台的真名（唯一事实来源；首页行标题、来源 chip、
    /// 空态文案、详情页标题都从这里取，三处一致）。
    /// - netease / qishui：「我喜欢的音乐」（上游歌单 `name` 字段本名：
    ///   网易 specialType==5，见 `specs/netease.md:478`；汽水
    ///   `base_info.type==1`，见 `specs/sidecars.md:496`）。
    /// - qq：「我喜欢」（QQ 的 dirid 201 收藏夹，`QQ.swift`
    ///   `userLikedSongs` 调 `CgiGetDiss disstid:0, dirid:201`；该接口
    ///   只回曲目不回名字，名字见壳版 `public/app.js:11373` 注释
    ///   「QQ → 我喜欢」，空态文案同款）。
    /// - bodian：真名未核实到——fond 接口（`/api/service/playlist/fond`）
    ///   只回歌单对象且原生只取了 id，仓内无字面记载；保持「我的喜欢」，
    ///   不编。真机核实路径：登录后看 `/api/bodian/user/playlists` 里
    ///   fond 那条的 `name` 字段（`bodianPlaylist` 已原样透传它）。
    /// - kugou / kuwo / applemusic：无喜欢接口，rail 里只有本地星标，
    ///   标题如实叫「本地星标收藏」（与 `railLocalLiked` 的 groupHeader
    ///   文案同款），不冒充平台歌单名。
    /// - 未知平台：回落到通用「我的喜欢」。
    static func likedTitle(for platform: String) -> String {
        switch platform {
        case "netease": return "我喜欢的音乐"
        case "qq": return "我喜欢"
        case "qishui": return "我喜欢的音乐"
        case "bodian": return "我的喜欢"
        case "kugou", "kuwo", "applemusic": return "本地星标收藏"
        default: return "我的喜欢"
        }
    }

    /// 展示标题：只有 liked 按平台取真名，其余 rail 用固定 title。
    func displayTitle(platform: String) -> String {
        self == .liked ? Self.likedTitle(for: platform) : title
    }
}

/// 一个电台频道（qq / 酷狗 / 汽水是频道目录；网易是 DJ 电台）。
struct RadioStation: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var coverURL: URL?
    /// 节目 / 曲目数（上游没给时为 0，不编）。
    var trackCount: Int
    /// 播放量（上游没给时为 0，不编）。
    var playCount: Int
    /// 创建者 / 分组（汽水 feed/modes 的 group、网易 DJ 的昵称）。
    var creator: String
    /// 来源平台。
    var platform: String

    init(id: String = "", name: String = "", coverURL: URL? = nil,
         trackCount: Int = 0, playCount: Int = 0, creator: String = "",
         platform: String = "") {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.trackCount = trackCount
        self.playCount = playCount
        self.creator = creator
        self.platform = platform
    }
}

/// rail 里的一行内容（四条 rail 的内容形态不统一：精选可能是曲目也可能是
/// 歌单，喜欢 / 波点 FM 是曲目，收藏是歌单，电台是频道；用一个枚举收拢，
/// 首页行与详情页共用同一份数据）。
enum RailEntry: Identifiable, Hashable {
    case track(Track)
    case playlist(Playlist)
    case station(RadioStation)
    /// 分组说明卡（只展示，不可点）：网易「我创建的歌单 / 我收藏的歌单」、
    /// Apple Music「官方热门歌单（非本人收藏）」、本地星标说明。
    case groupHeader(String)

    var id: String {
        switch self {
        case .track(let t): return "track-\(t.platform)-\(t.id)"
        case .playlist(let p): return "playlist-\(p.source)-\(p.id)"
        case .station(let s): return "station-\(s.platform)-\(s.id)"
        case .groupHeader(let text): return "group-\(text)"
        }
    }
}

/// 一条 rail 的拉取结果（带 per-platform 错误通道，见文件头）。
struct RailResult {
    var kind: RailKind
    var platform: String
    /// 当前 feed（只有 featured 有；详情页切 feed 用）。
    var feed: String?
    var entries: [RailEntry]
    /// 诚实空态原因（请求通了但内容为空时填；有内容时为 nil）。
    var emptyReason: String?
    /// 请求失败原因（call 回 nil 或上游回 error 时填；成功时为 nil）。
    var error: String?

    init(kind: RailKind, platform: String, feed: String? = nil,
         entries: [RailEntry] = [], emptyReason: String? = nil, error: String? = nil) {
        self.kind = kind
        self.platform = platform
        self.feed = feed
        self.entries = entries
        self.emptyReason = emptyReason
        self.error = error
    }

    var tracks: [Track] {
        entries.compactMap { if case .track(let t) = $0 { return t } else { return nil } }
    }

    var playlists: [Playlist] {
        entries.compactMap { if case .playlist(let p) = $0 { return p } else { return nil } }
    }

    var stations: [RadioStation] {
        entries.compactMap { if case .station(let s) = $0 { return s } else { return nil } }
    }
}

extension NativeBridge {

    // MARK: - 精选 feed（照抄壳版 FEAT_FEEDS 的 feed 划分；默认 = 任务指定的主 feed）

    /// 该平台精选有哪些 feed（id + 展示名；详情页切 feed 用）。
    /// r22j：顺序照抄壳版 FEAT_FEEDS（app.js）——滚轮里第一项就是首页
    /// 精选行的默认 feed：网易推荐歌单 wheel:false 不进滚轮，默认推荐新歌；
    /// 酷狗新歌速递在前、精选歌单在后；酷我排行榜在前、推荐歌单在后。
    static func featuredFeeds(for platform: String) -> [(id: String, name: String)] {
        switch platform {
        case "netease": return [("newsong", "推荐新歌"), ("playlists", "推荐歌单")]
        case "qq": return [("playlists", "推荐歌单"), ("newsongs", "新歌首发")]
        case "kugou": return [("newsongs", "新歌速递"), ("playlists", "精选歌单")]
        case "qishui": return [("feed", "为你推荐")]
        case "bodian": return [("playlists", "推荐歌单")]
        case "kuwo": return [("ranks", "排行榜"), ("playlists", "推荐歌单")]
        case "applemusic": return [("playlists", "热门歌单")]
        default: return []
        }
    }

    /// 首页行默认 feed（各平台第一个 feed；网易默认推荐新歌，推荐歌单在详情页切）。
    static func defaultFeaturedFeed(for platform: String) -> String? {
        featuredFeeds(for: platform).first?.id
    }

    // MARK: - 精选

    static func railFeatured(platform: String, feed: String? = nil) async -> RailResult {
        let f = feed ?? defaultFeaturedFeed(for: platform) ?? "playlists"
        switch platform {
        case "netease":
            if f == "newsong" {
                guard let d = await call(path: "/api/personalized") else {
                    return railFailed(kind: .featured, platform: platform, feed: f)
                }
                if let e = railError(d) {
                    return RailResult(kind: .featured, platform: platform, feed: f, error: e)
                }
                let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
                return railDone(kind: .featured, platform: platform, feed: f,
                                entries: tracks.map { RailEntry.track($0) },
                                emptyReason: "网易云没返回推荐新歌")
            }
            guard let d = await call(path: "/api/top/playlist",
                                     query: ["limit": "12", "cat": "全部", "order": "hot"]) else {
                return railFailed(kind: .featured, platform: platform, feed: f)
            }
            if let e = railError(d) {
                return RailResult(kind: .featured, platform: platform, feed: f, error: e)
            }
            let lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .featured, platform: platform, feed: f,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "网易云没返回推荐歌单")
        case "qq":
            if f == "newsongs" {
                guard let d = await call(path: "/api/qq/recommend/new-songs", query: ["limit": "30"]) else {
                    return railFailed(kind: .featured, platform: platform, feed: f)
                }
                if let e = railError(d) {
                    return RailResult(kind: .featured, platform: platform, feed: f, error: e)
                }
                let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
                return railDone(kind: .featured, platform: platform, feed: f,
                                entries: tracks.map { RailEntry.track($0) },
                                emptyReason: "QQ 音乐没返回新歌")
            }
            guard let d = await call(path: "/api/qq/recommend/playlists", query: ["limit": "9"]) else {
                return railFailed(kind: .featured, platform: platform, feed: f)
            }
            if let e = railError(d) {
                return RailResult(kind: .featured, platform: platform, feed: f, error: e)
            }
            let lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .featured, platform: platform, feed: f,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "QQ 音乐没返回推荐歌单")
        case "kugou":
            if f == "newsongs" {
                guard let d = await call(path: "/api/kugou/top/songs", query: ["type": "1"]) else {
                    return railFailed(kind: .featured, platform: platform, feed: f)
                }
                if let e = railError(d) {
                    return RailResult(kind: .featured, platform: platform, feed: f, error: e)
                }
                let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
                return railDone(kind: .featured, platform: platform, feed: f,
                                entries: tracks.map { RailEntry.track($0) },
                                emptyReason: "酷狗没返回新歌")
            }
            guard let d = await call(path: "/api/kugou/top/playlists", query: ["limit": "12"]) else {
                return railFailed(kind: .featured, platform: platform, feed: f)
            }
            if let e = railError(d) {
                return RailResult(kind: .featured, platform: platform, feed: f, error: e)
            }
            let lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .featured, platform: platform, feed: f,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "酷狗没返回精选歌单")
        case "qishui":
            guard let d = await call(path: "/api/qishui/feed", query: ["limit": "20"]) else {
                return railFailed(kind: .featured, platform: platform, feed: f)
            }
            if let e = railError(d) {
                return RailResult(kind: .featured, platform: platform, feed: f, error: e)
            }
            let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
            return railDone(kind: .featured, platform: platform, feed: f,
                            entries: tracks.map { RailEntry.track($0) },
                            emptyReason: "汽水没返回推荐流")
        case "bodian":
            guard let d = await call(path: "/api/bodian/recommendations") else {
                return railFailed(kind: .featured, platform: platform, feed: f)
            }
            if let e = railError(d) {
                return RailResult(kind: .featured, platform: platform, feed: f, error: e)
            }
            let lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .featured, platform: platform, feed: f,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "波点没返回推荐歌单")
        case "kuwo":
            if f == "ranks" {
                guard let d = await call(path: "/api/kuwo/rank/list") else {
                    return railFailed(kind: .featured, platform: platform, feed: f)
                }
                if let e = railError(d) {
                    return RailResult(kind: .featured, platform: platform, feed: f, error: e)
                }
                let lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
                return railDone(kind: .featured, platform: platform, feed: f,
                                entries: lists.map { RailEntry.playlist($0) },
                                emptyReason: "酷我没返回排行榜")
            }
            guard let d = await call(path: "/api/kuwo/recommend/playlists", query: ["limit": "12"]) else {
                return railFailed(kind: .featured, platform: platform, feed: f)
            }
            if let e = railError(d) {
                return RailResult(kind: .featured, platform: platform, feed: f, error: e)
            }
            let lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .featured, platform: platform, feed: f,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "酷我没返回推荐歌单")
        case "applemusic":
            guard let d = await call(path: "/api/applemusic/playlists", query: ["limit": "12"]) else {
                return railFailed(kind: .featured, platform: platform, feed: f)
            }
            if let e = railError(d) {
                return RailResult(kind: .featured, platform: platform, feed: f, error: e)
            }
            let lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .featured, platform: platform, feed: f,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "Apple Music 没返回热门歌单")
        default:
            return railEmpty(kind: .featured, platform: platform, feed: f,
                             reason: "「\(platform)」的精选还没接通")
        }
    }

    // MARK: - 喜欢 rail（标题按平台取真名，见 RailKind.likedTitle）

    static func railLiked(platform: String) async -> RailResult {
        switch platform {
        case "netease":
            guard let uid = await neteaseUserId() else {
                return railEmpty(kind: .liked, platform: platform,
                                 reason: "先在设置里登录网易云，才能看「我喜欢的音乐」（登录流程在 P4，未登录时这里是空的）。")
            }
            guard let d = await call(path: "/api/user/playlist", query: ["uid": uid]) else {
                return railFailed(kind: .liked, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .liked, platform: platform, error: e)
            }
            let lists = railRows(d, keys: ["playlists"])
            let like = lists.first { ($0["specialType"] as? NSNumber)?.intValue == 5 }
                ?? lists.first { (($0["name"] as? String) ?? "").contains("喜欢的音乐") }
            guard let like, let likeId = railString(like["id"]), !likeId.isEmpty else {
                return railEmpty(kind: .liked, platform: platform, reason: "没找到「我喜欢的音乐」歌单")
            }
            let detail = await playlistDetail(platform: platform, id: likeId)
            return railDone(kind: .liked, platform: platform,
                            entries: detail.tracks.map { RailEntry.track($0) },
                            emptyReason: "这张歌单没有曲目")
        case "qq":
            guard let d = await call(path: "/api/qq/user/liked-songs", query: ["limit": "100"]) else {
                return railFailed(kind: .liked, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .liked, platform: platform, error: e)
            }
            let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
            return railDone(kind: .liked, platform: platform,
                            entries: tracks.map { RailEntry.track($0) },
                            emptyReason: "QQ 音乐的「我喜欢」是空的")
        case "qishui":
            guard let d = await call(path: "/api/qishui/user/playlists", query: ["limit": "100"]) else {
                return railFailed(kind: .liked, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .liked, platform: platform, error: e)
            }
            let lists = railRows(d, keys: ["playlists"])
            let like = lists.first { ($0["isLikedPlaylist"] as? NSNumber)?.boolValue == true }
                ?? lists.first { (($0["name"] as? String) ?? "").contains("喜欢的音乐") }
            guard let like, let likeId = railString(like["id"]), !likeId.isEmpty else {
                return railEmpty(kind: .liked, platform: platform, reason: "没找到汽水的「我喜欢的音乐」歌单")
            }
            guard let t = await call(path: "/api/qishui/playlist/tracks",
                                     query: ["id": likeId, "limit": "50"]) else {
                return railFailed(kind: .liked, platform: platform)
            }
            if let e = railError(t) {
                return RailResult(kind: .liked, platform: platform, error: e)
            }
            let tracks = railRows(t, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
            return railDone(kind: .liked, platform: platform,
                            entries: tracks.map { RailEntry.track($0) },
                            emptyReason: "这张歌单没有曲目")
        case "bodian":
            guard let d = await call(path: "/api/bodian/liked_songs") else {
                return railFailed(kind: .liked, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .liked, platform: platform, error: e)
            }
            let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
            return railDone(kind: .liked, platform: platform,
                            entries: tracks.map { RailEntry.track($0) },
                            emptyReason: "波点的「我的喜欢」是空的")
        case "kugou", "kuwo", "applemusic":
            // 这三家没有「我喜欢的音乐」列表接口：只显示本地星标（P2 起 PlaybackStore
            // 同时持久化完整 Track），没有就诚实空态写清原因，不编假数据。
            return railLocalLiked(kind: .liked, platform: platform)
        default:
            return railEmpty(kind: .liked, platform: platform,
                             reason: "「\(platform)」的「我喜欢」还没接通")
        }
    }

    /// 本地星标兜底（kugou / kuwo / applemusic 的喜欢 rail，标题是
    /// 「本地星标收藏」）：有星标就列出来并在前面插一张说明卡，
    /// 没有就诚实空态。
    private static func railLocalLiked(kind: RailKind, platform: String) -> RailResult {
        let platformName = LiziPlatforms.all.first(where: { $0.id == platform })?.name ?? platform
        let local = PlaybackStore.likedTracks().filter { $0.platform == platform }
        guard !local.isEmpty else {
            let reason: String
            switch platform {
            case "kugou":
                reason = "酷狗没有「我喜欢的音乐」列表接口——在本 App 里点星标收藏的歌会显示在这里"
            case "kuwo":
                reason = "酷我没有「我喜欢的音乐」接口——在本 App 里点星标收藏的歌会显示在这里"
            case "applemusic":
                reason = "Apple Music 公开接口没有「我喜欢的歌」列表——在本 App 里点星标收藏的歌会显示在这里"
            default:
                reason = "该平台没有「我喜欢」接口——在本 App 里点星标收藏的歌会显示在这里"
            }
            return railEmpty(kind: kind, platform: platform, reason: reason)
        }
        var entries: [RailEntry] = [.groupHeader("本地星标收藏（\(platformName)没有喜欢接口）")]
        entries.append(contentsOf: local.map { RailEntry.track($0) })
        return RailResult(kind: kind, platform: platform, entries: entries)
    }

    // MARK: - 我收藏的歌单

    static func railMyPlaylists(platform: String) async -> RailResult {
        switch platform {
        case "netease":
            guard let uid = await neteaseUserId() else {
                return railEmpty(kind: .playlists, platform: platform,
                                 reason: "先在设置里登录网易云，才能看「我收藏的歌单」（登录流程在 P4，未登录时这里是空的）。")
            }
            guard let d = await call(path: "/api/user/playlist", query: ["uid": uid]) else {
                return railFailed(kind: .playlists, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .playlists, platform: platform, error: e)
            }
            let raw = railRows(d, keys: ["playlists"])
            // 注意：parsed 与 raw 一一对应（map，不用 compactMap 后再 zip，
            // 否则解析失败项会让 subscribed 分组错位）。
            let parsed = raw.map { railPlaylistFrom($0, platform: platform) }
            let mine = zip(parsed, raw).compactMap { pair -> Playlist? in
                guard let p = pair.0 else { return nil }
                return (pair.1["subscribed"] as? NSNumber)?.boolValue == true ? nil : p
            }
            let sub = zip(parsed, raw).compactMap { pair -> Playlist? in
                guard let p = pair.0 else { return nil }
                return (pair.1["subscribed"] as? NSNumber)?.boolValue == true ? p : nil
            }
            guard !mine.isEmpty || !sub.isEmpty else {
                return railEmpty(kind: .playlists, platform: platform, reason: "还没有收藏或创建任何歌单")
            }
            var entries: [RailEntry] = []
            if !mine.isEmpty {
                entries.append(.groupHeader("我创建的歌单"))
                entries.append(contentsOf: mine.map { RailEntry.playlist($0) })
            }
            if !mine.isEmpty, !sub.isEmpty {
                entries.append(.groupHeader("我收藏的歌单"))
            }
            entries.append(contentsOf: sub.map { RailEntry.playlist($0) })
            return RailResult(kind: .playlists, platform: platform, entries: entries)
        case "qq":
            guard let d = await call(path: "/api/qq/user/playlists") else {
                return railFailed(kind: .playlists, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .playlists, platform: platform, error: e)
            }
            let lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .playlists, platform: platform,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "QQ 音乐没有返回歌单")
        case "kugou":
            guard let d = await call(path: "/api/kugou/user/playlists") else {
                return railFailed(kind: .playlists, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .playlists, platform: platform, error: e)
            }
            let lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .playlists, platform: platform,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "酷狗没有返回歌单")
        case "qishui":
            guard let d = await call(path: "/api/qishui/user/playlists", query: ["limit": "100"]) else {
                return railFailed(kind: .playlists, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .playlists, platform: platform, error: e)
            }
            let lists = railRows(d, keys: ["playlists"])
                .filter { ($0["isLikedPlaylist"] as? NSNumber)?.boolValue != true }
                .compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .playlists, platform: platform,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "汽水没有返回歌单")
        case "bodian":
            guard let d = await call(path: "/api/bodian/user/playlists") else {
                return railFailed(kind: .playlists, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .playlists, platform: platform, error: e)
            }
            let lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .playlists, platform: platform,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "波点没有返回歌单")
        case "kuwo":
            return railEmpty(kind: .playlists, platform: platform,
                             reason: "酷我 Web 没有用户歌单接口（Cookie 登录态只影响播放请求），这里是空的，不编内容。")
        case "applemusic":
            guard let d = await call(path: "/api/applemusic/playlists", query: ["limit": "12"]) else {
                return railFailed(kind: .playlists, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .playlists, platform: platform, error: e)
            }
            let lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
            guard !lists.isEmpty else {
                return railEmpty(kind: .playlists, platform: platform, reason: "Apple Music 没有返回歌单")
            }
            var entries: [RailEntry] = [.groupHeader("官方热门歌单（非本人收藏——Apple Music 没有用户歌单接口）")]
            entries.append(contentsOf: lists.map { RailEntry.playlist($0) })
            return RailResult(kind: .playlists, platform: platform, entries: entries)
        default:
            return railEmpty(kind: .playlists, platform: platform,
                             reason: "「\(platform)」的歌单还没接通")
        }
    }

    // MARK: - 电台

    static func railRadio(platform: String) async -> RailResult {
        switch platform {
        case "netease":
            guard let d = await call(path: "/api/netease/dj/recommend", query: ["limit": "8"]) else {
                return railFailed(kind: .radio, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .radio, platform: platform, error: e)
            }
            // dj/recommend 是 weapi 透传（无 normalize）：djRadios 或 data 数组，
            // 每项可能是 { djRadio: {...} } 包一层，也可能是电台本身。
            let rows = railRows(d, keys: ["djRadios", "data"])
            let stations = rows.compactMap { row -> RadioStation? in
                let r = (row["djRadio"] as? [String: Any]) ?? row
                return railStationFrom(r, platform: platform)
            }
            return railDone(kind: .radio, platform: platform,
                            entries: stations.map { RailEntry.station($0) },
                            emptyReason: "网易云没返回推荐电台")
        case "qq":
            guard let d = await call(path: "/api/qq/radio/categories") else {
                return railFailed(kind: .radio, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .radio, platform: platform, error: e)
            }
            let stations = railRows(d, keys: ["stations"]).compactMap { railStationFrom($0, platform: platform) }
            return railDone(kind: .radio, platform: platform,
                            entries: stations.map { RailEntry.station($0) },
                            emptyReason: "QQ 音乐没返回电台频道")
        case "kugou":
            guard let d = await call(path: "/api/kugou/fm/class") else {
                return railFailed(kind: .radio, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .radio, platform: platform, error: e)
            }
            let stations = railRows(d, keys: ["stations"]).compactMap { railStationFrom($0, platform: platform) }
            return railDone(kind: .radio, platform: platform,
                            entries: stations.map { RailEntry.station($0) },
                            emptyReason: "酷狗没返回电台频道")
        case "qishui":
            guard let d = await call(path: "/api/qishui/feed/modes") else {
                return railFailed(kind: .radio, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .radio, platform: platform, error: e)
            }
            let stations = railRows(d, keys: ["stations"]).compactMap { railStationFrom($0, platform: platform) }
            return railDone(kind: .radio, platform: platform,
                            entries: stations.map { RailEntry.station($0) },
                            emptyReason: "汽水没返回场景电台")
        case "bodian":
            // 波点私人 FM 直接是曲目列表，不是频道目录。
            guard let d = await call(path: "/api/bodian/personal/fm") else {
                return railFailed(kind: .radio, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .radio, platform: platform, error: e)
            }
            let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
            return railDone(kind: .radio, platform: platform,
                            entries: tracks.map { RailEntry.track($0) },
                            emptyReason: "波点私人 FM 没返回歌曲")
        case "kuwo":
            return railEmpty(kind: .radio, platform: platform,
                             reason: "酷我只开放电台栏目目录，没有单集曲目接口，无法播放——不拿目录冒充电台。")
        case "applemusic":
            return railEmpty(kind: .radio, platform: platform,
                             reason: "Apple Music 公开接口没有电台（Catalog API 的电台要开发者 token），这里是空的，不编内容。")
        default:
            return railEmpty(kind: .radio, platform: platform,
                             reason: "「\(platform)」的电台还没接通")
        }
    }

    // MARK: - 频道曲目（详情页下钻；kuwo / applemusic 无电台不设入口）

    static func railStationTracks(platform: String, stationId: String) async -> RailResult {
        switch platform {
        case "netease":
            guard let d = await call(path: "/api/netease/dj/program",
                                     query: ["rid": stationId, "limit": "50"]) else {
                return railFailed(kind: .radio, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .radio, platform: platform, error: e)
            }
            // dj/program 是 weapi 透传：programs[i].mainSong 才是曲目，
            // 节目名 / 封面当曲名 / 封面的后备（照抄壳版 ncProgramTrack）。
            var tracks: [Track] = []
            for program in railRows(d, keys: ["programs"]) {
                guard var song = program["mainSong"] as? [String: Any] else { continue }
                if (song["name"] as? String ?? "").isEmpty,
                   let programName = program["name"] as? String {
                    song["name"] = programName
                }
                guard var track = Track.from(dict: song, platform: platform) else { continue }
                if track.coverURL == nil,
                   let cover = program["coverUrl"] as? String, !cover.isEmpty {
                    track.coverURL = URL(string: cover)
                }
                tracks.append(track)
            }
            return railDone(kind: .radio, platform: platform,
                            entries: tracks.map { RailEntry.track($0) },
                            emptyReason: "这个电台暂时没有节目")
        case "qq":
            guard let d = await call(path: "/api/qq/radio/tracks", query: ["id": stationId]) else {
                return railFailed(kind: .radio, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .radio, platform: platform, error: e)
            }
            let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
            return railDone(kind: .radio, platform: platform,
                            entries: tracks.map { RailEntry.track($0) },
                            emptyReason: "这个电台暂时没有曲目")
        case "kugou":
            guard let d = await call(path: "/api/kugou/fm/songs",
                                     query: ["fmid": stationId, "limit": "30"]) else {
                return railFailed(kind: .radio, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .radio, platform: platform, error: e)
            }
            let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
            return railDone(kind: .radio, platform: platform,
                            entries: tracks.map { RailEntry.track($0) },
                            emptyReason: "这个电台暂时没有曲目")
        case "qishui":
            guard let d = await call(path: "/api/qishui/feed",
                                     query: ["limit": "50", "mode": stationId]) else {
                return railFailed(kind: .radio, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .radio, platform: platform, error: e)
            }
            let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
            return railDone(kind: .radio, platform: platform,
                            entries: tracks.map { RailEntry.track($0) },
                            emptyReason: "这个场景暂时没有曲目")
        default:
            return railEmpty(kind: .radio, platform: platform,
                             reason: "这个频道暂时没有曲目")
        }
    }

    // MARK: - 歌单曲目（详情页下钻）

    /// 点歌单卡进曲目列表。`feed` 只在 kuwo 榜单时用（ranks feed 的卡走
    /// /api/kuwo/rank/tracks，拿不到再回普通歌单接口）。
    /// bodian 走 /api/bodian/playlist/tracks（playlistDetail 没接 bodian）；
    /// 其余平台复用 NativeBridge.playlistDetail。
    static func railPlaylistTracks(platform: String, playlist: Playlist, feed: String? = nil) async -> RailResult {
        switch platform {
        case "bodian":
            guard let d = await call(path: "/api/bodian/playlist/tracks",
                                     query: ["id": playlist.id, "limit": "50"]) else {
                return railFailed(kind: .playlists, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .playlists, platform: platform, error: e)
            }
            let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
            return railDone(kind: .playlists, platform: platform,
                            entries: tracks.map { RailEntry.track($0) },
                            emptyReason: "这张歌单没有曲目")
        case "kuwo":
            if feed == "ranks" {
                if let d = await call(path: "/api/kuwo/rank/tracks",
                                      query: ["id": playlist.id, "limit": "50"]),
                   railError(d) == nil {
                    let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
                    if !tracks.isEmpty {
                        return RailResult(kind: .playlists, platform: platform,
                                          entries: tracks.map { RailEntry.track($0) })
                    }
                }
            }
            let detail = await playlistDetail(platform: platform, id: playlist.id)
            return railDone(kind: .playlists, platform: platform,
                            entries: detail.tracks.map { RailEntry.track($0) },
                            emptyReason: "这张歌单没有曲目")
        default:
            let detail = await playlistDetail(platform: platform, id: playlist.id)
            return railDone(kind: .playlists, platform: platform,
                            entries: detail.tracks.map { RailEntry.track($0) },
                            emptyReason: "这张歌单没有曲目")
        }
    }

    // MARK: - 登录态（网易喜欢 / 收藏歌单用；未登录返回 nil）

    /// 网易 userId（/api/session 的 profile.userId；未登录 / 拿不到时返回 nil）。
    /// 当前原生版是未登录态，调用方按 nil 走诚实空态，不弹登录（登录是 P4）。
    private static func neteaseUserId() async -> String? {
        guard SessionStore.shared.hasMusicU else { return nil }
        guard let d = await call(path: "/api/session"),
              (d["loggedIn"] as? NSNumber)?.boolValue == true,
              let profile = d["profile"] as? [String: Any] else { return nil }
        if let n = profile["userId"] as? NSNumber, n.intValue != 0 { return n.stringValue }
        if let s = profile["userId"] as? String, !s.isEmpty { return s }
        return nil
    }

    // MARK: - 解析 / 结果构造（私有）

    /// 请求本身没通（call 回 nil）→ 错误通道，不静默空列表。
    private static func railFailed(kind: RailKind, platform: String, feed: String? = nil) -> RailResult {
        RailResult(kind: kind, platform: platform, feed: feed, error: searchErrorText)
    }

    /// 诚实空态（请求通了但内容为空 / 接口缺失 / 未登录）。
    private static func railEmpty(kind: RailKind, platform: String, feed: String? = nil,
                                  reason: String) -> RailResult {
        RailResult(kind: kind, platform: platform, feed: feed, emptyReason: reason)
    }

    /// 有内容就返回内容，空就填空态原因。
    private static func railDone(kind: RailKind, platform: String, feed: String? = nil,
                                 entries: [RailEntry], emptyReason: String) -> RailResult {
        if entries.isEmpty {
            return RailResult(kind: kind, platform: platform, feed: feed, emptyReason: emptyReason)
        }
        return RailResult(kind: kind, platform: platform, feed: feed, entries: entries)
    }

    /// 上游回的 error 字段，或非 0/200 的 code（callSoft 的边车失败就是这个形状）。
    private static func railError(_ d: [String: Any]?) -> String? {
        guard let d else { return nil }
        if let e = d["error"] as? String, !e.isEmpty { return e }
        if let code = d["code"] as? NSNumber, code.intValue != 0, code.intValue != 200 {
            return "接口返回异常（code=\(code.intValue)）"
        }
        return nil
    }

    /// 按优先级取第一个非空数组字段（各平台归一化键名不完全一致）。
    private static func railRows(_ d: [String: Any]?, keys: [String]) -> [[String: Any]] {
        guard let d else { return [] }
        for key in keys {
            if let rows = d[key] as? [[String: Any]], !rows.isEmpty { return rows }
        }
        return []
    }

    /// id 可能是 String 也可能是 NSNumber。
    private static func railString(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func railFirstNonEmpty(_ values: [String?]) -> String {
        values.compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
    }

    /// 歌单字典 → Playlist（各平台归一化形状：id / name / cover /
    /// trackCount 或 tracks（个数）/ creator（字典或字符串））。
    private static func railPlaylistFrom(_ d: [String: Any], platform: String) -> Playlist? {
        guard let id = railString(d["id"]), !id.isEmpty else { return nil }
        let title = (d["name"] as? String) ?? (d["title"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        let cover = railFirstNonEmpty([d["cover"] as? String, d["coverImgUrl"] as? String,
                                       d["picUrl"] as? String, d["pic"] as? String,
                                       d["img"] as? String])
        var creator = ""
        if let c = d["creator"] as? [String: Any] { creator = (c["nickname"] as? String) ?? "" }
        else if let c = d["creator"] as? String { creator = c }
        var trackCount = (d["trackCount"] as? NSNumber)?.intValue ?? 0
        if trackCount == 0, let n = d["tracks"] as? NSNumber { trackCount = n.intValue }
        if trackCount == 0, let rows = d["tracks"] as? [[String: Any]] { trackCount = rows.count }
        return Playlist(id: id, title: title,
                        coverURL: cover.isEmpty ? nil : URL(string: cover),
                        trackCount: trackCount, source: platform, creator: creator)
    }

    /// 电台 / 频道字典 → RadioStation（网易 DJ：picUrl / programCount /
    /// dj.nickname；汽水场景：coverUrl / group；QQ / 酷狗：stations 归一化形状）。
    private static func railStationFrom(_ d: [String: Any], platform: String) -> RadioStation? {
        guard let id = railString(d["id"]), !id.isEmpty else { return nil }
        let name = (d["name"] as? String) ?? (d["title"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        let cover = railFirstNonEmpty([d["cover"] as? String, d["coverUrl"] as? String,
                                       d["coverImgUrl"] as? String, d["picUrl"] as? String,
                                       d["pic"] as? String])
        var creator = ""
        if let c = d["creator"] as? [String: Any] { creator = (c["nickname"] as? String) ?? "" }
        else if let c = d["creator"] as? String { creator = c }
        if creator.isEmpty, let dj = d["dj"] as? [String: Any] { creator = (dj["nickname"] as? String) ?? "" }
        if creator.isEmpty { creator = (d["group"] as? String) ?? "" }
        let trackCount = (d["trackCount"] as? NSNumber)?.intValue
            ?? (d["programCount"] as? NSNumber)?.intValue ?? 0
        let playCount = (d["playCount"] as? NSNumber)?.intValue
            ?? (d["play_count"] as? NSNumber)?.intValue
            ?? (d["listenNum"] as? NSNumber)?.intValue ?? 0
        return RadioStation(id: id, name: name,
                            coverURL: cover.isEmpty ? nil : URL(string: cover),
                            trackCount: trackCount, playCount: playCount,
                            creator: creator, platform: platform)
    }
}
