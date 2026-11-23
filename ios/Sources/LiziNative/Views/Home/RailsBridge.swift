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
///   kugou → /api/kugou/top/songs?type=1（新歌速递，默认 feed）
///   / playlists feed → /api/kugou/top/playlists（12，精选歌单）；
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
///   kugou → get_all_list 里的「我喜欢」表（listId "2" / 名字含「喜欢」）
///   取曲，未登录退回本地星标；
///   kuwo / applemusic → 没有喜欢接口，rail 里只有本地星标，
///   标题如实叫「本地星标收藏」，没有就诚实空态写清原因。
///   r31-starred（用户 2026-11-21 06:44，QQ/酷狗优先）：平台喜欢
///   拉不到（未登录/传输层没通/上游报错/拉到是空）时先看本地星标，
///   有星标就显示星标（失败原因写进分组卡，整页不带 error），没星标
///   才按原样报失败/空态；拉到了也把星标并进来（按喜欢复合键去重）。
///   刷新：喜欢栏不缓存（`HomeViewModel.loadRailPage` 每次切回都重拉；
///   面板/详情页每次出现也重拉），星标一点就变。
///   r31：各平台收藏的东西（歌单/专辑）都并进这一栏——网易 subscribed 歌单、
///   QQ 收藏歌单（subscribed 标记）+ 收藏专辑（user/albums）、酷狗非自有
///   歌单 + 专辑、汽水非自有歌单（isOwned 标记）、波点收藏歌单/专辑
///   （isOwned 标记 + albums 数组）；酷我/Apple Music 没有官方收藏接口，
///   只有本地星标，不编假数据。
/// - playlists（我收藏的歌单 → r31 改名「我的歌单」，只留用户自建的歌单，
///   收藏的已并进 liked）：netease → /api/user/playlist，分我创建
///   （subscribed==false）/ 我收藏（subscribed==true），未登录 → 诚实空态；
///   qq / qishui / bodian / kugou → 各自 /api/<platform>/user/playlists，
///   按 subscribed / isOwned 标记只留自建（QQ：QQ.swift userPlaylists 打
///   subscribed 标记；汽水：qishuiPlaylist 透传 isOwned；波点：路由打
///   isOwned / isLikedPlaylist 标记；酷狗：kugouCollection 的 isOwned）；
///   kuwo → 无用户歌单接口，诚实空态；
///   applemusic → /api/applemusic/playlists 兜底，前面插说明卡
///   「官方热门歌单（非本人收藏）」。
/// - radio（电台）：netease → /api/netease/dj/recommend（8）；
///   qq → /api/qq/radio/categories；
///   kugou → /api/kugou/fm/class（电台分类）；
///   qishui → /api/qishui/feed/modes；bodian → /api/bodian/personal/fm
///   （直接是曲目）；kuwo → 只有栏目目录、无单集曲目接口，诚实空态不冒充；
///   applemusic → 公开接口无电台，诚实空态。
/// - 频道曲目（详情页下钻）：netease → /api/netease/dj/program；
///   qq → /api/qq/radio/tracks；
///   kugou → /api/kugou/fm/songs；
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
    ///   `base_info.type==1`，见 `specs/sidecars.md:401`）。
    /// - qq：「我喜欢」（QQ 的 dirid 201 收藏夹，`QQ.swift`
    ///   `userLikedSongs` 调 `CgiGetDiss disstid:0, dirid:201`；该接口
    ///   只回曲目不回名字，名字见壳版 `public/app.js:11373` 注释
    ///   「QQ → 我喜欢」，空态文案同款）。
    /// - bodian：真名未核实到——fond 接口（`/api/service/playlist/fond`）
    ///   只回歌单对象且原生只取了 id，仓内无字面记载；保持「我的喜欢」，
    ///   不编。真机核实路径：登录后看 `/api/bodian/user/playlists` 里
    ///   fond 那条的 `name` 字段（`bodianPlaylist` 已原样透传它）。
    /// - kuwo / kugou / applemusic：无喜欢接口，rail 里只有本地星标，
    ///   标题如实叫「本地星标收藏」（与 `railLocalLiked` 的 groupHeader
    ///   文案同款），不冒充平台歌单名。
    /// - 未知平台：回落到通用「我的喜欢」。
    static func likedTitle(for platform: String) -> String {
        switch platform {
        case "netease": return "我喜欢的音乐"
        case "qq": return "我喜欢"
        case "qishui": return "我喜欢的音乐"
        case "bodian": return "我的喜欢"
        case "kuwo", "kugou", "applemusic": return "本地星标收藏"
        default: return "我的喜欢"
        }
    }

    /// 展示标题：只有 liked 按平台取真名，其余 rail 用固定 title。
    func displayTitle(platform: String) -> String {
        self == .liked ? Self.likedTitle(for: platform) : title
    }
}

/// 一个电台频道（qq / 汽水是频道目录；网易是 DJ 电台）。
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
    /// 专辑（r31：收藏的专辑并进「我喜欢」后新增；点卡进面板内专辑曲目）。
    case album(Album)
    /// 分组说明卡（只展示，不可点）：网易「我创建的歌单 / 我收藏的歌单」、
    /// Apple Music「官方热门歌单（非本人收藏）」、本地星标说明。
    case groupHeader(String)

    var id: String {
        switch self {
        case .track(let t): return "track-\(t.platform)-\(t.id)"
        case .playlist(let p): return "playlist-\(p.source)-\(p.id)"
        case .station(let s): return "station-\(s.platform)-\(s.id)"
        case .album(let a): return "album-\(a.source)-\(a.id)"
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
        // r55：按 id 去重（保第一项、保顺序）——歌单里同一首歌出现两次时
        // RailEntry.id（track-<platform>-<id>）会撞，ForEach 行为未定义、可 trap。
        self.entries = dedupedById(entries)
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

    var albums: [Album] {
        entries.compactMap { if case .album(let a) = $0 { return a } else { return nil } }
    }
}

extension NativeBridge {

    // MARK: - 精选 feed（照抄壳版 FEAT_FEEDS 的 feed 划分；默认 = 任务指定的主 feed）

    /// 该平台精选有哪些 feed（id + 展示名；详情页切 feed 用）。
    /// r22j：顺序照抄壳版 FEAT_FEEDS（app.js）——滚轮里第一项就是首页
    /// 精选行的默认 feed：网易推荐歌单 wheel:false 不进滚轮，默认推荐新歌；
    /// 酷我排行榜在前、推荐歌单在后。
    static func featuredFeeds(for platform: String) -> [(id: String, name: String)] {
        switch platform {
        case "netease": return [("newsong", "推荐新歌"), ("playlists", "推荐歌单")]
        case "qq": return [("playlists", "推荐歌单"), ("newsongs", "新歌首发")]
        case "qishui": return [("feed", "为你推荐")]
        case "bodian": return [("playlists", "推荐歌单")]
        case "kugou": return [("newsongs", "新歌速递"), ("playlists", "精选歌单")]
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
                guard let d = await callRail(path: "/api/personalized") else {
                    // r31：传输层没通（断网/超时/上游无响应）时写明端点，
                    // 不再回通用 searchErrorText——实测接口、解析、登录
                    // 三者都没问题（见 verification/r31-featured.cjs），
                    // 剩下的失败只能出在传输层；文案写明端点，下次真机
                    // 复现时凭这一句就能区分是没连上还是上游空回。
                    return RailResult(kind: .featured, platform: platform, feed: f,
                                    error: "网易推荐新歌拉取失败：/api/personalized 未连通（网络或上游超时），请检查网络后重试")
                }
                if let e = railError(d) {
                    return RailResult(kind: .featured, platform: platform, feed: f, error: e)
                }
                let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
                return railDone(kind: .featured, platform: platform, feed: f,
                                entries: tracks.map { RailEntry.track($0) },
                                emptyReason: "网易云没返回推荐新歌")
            }
            guard let d = await callRail(path: "/api/top/playlist",
                                     query: ["limit": "12", "cat": "全部", "order": "hot"]) else {
                // r31：同 newsong 分支——传输层失败写明端点，不回通用文案。
                return RailResult(kind: .featured, platform: platform, feed: f,
                                error: "网易精选歌单拉取失败：/api/top/playlist 未连通（网络或上游超时），请检查网络后重试")
            }
            if let e = railError(d) {
                return RailResult(kind: .featured, platform: platform, feed: f, error: e)
            }
            var lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
            if lists.isEmpty {
                // r31：上游 200 但空列表时再抽一次（order=new）：实测
                // /personalized/playlist 是轮换推荐（每次返回的集合都
                // 不同），单次空抽不应直接判死；两次都空才回诚实空态。
                // 只在「通了但空」时重试，传输层失败/上游报错不走这里。
                if let d2 = await callRail(path: "/api/top/playlist",
                                       query: ["limit": "12", "cat": "全部", "order": "new"]),
                   railError(d2) == nil {
                    lists = railRows(d2, keys: ["playlists"])
                        .compactMap { railPlaylistFrom($0, platform: platform) }
                }
            }
            return railDone(kind: .featured, platform: platform, feed: f,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "网易云没返回推荐歌单")
        case "qq":
            if f == "newsongs" {
                guard let d = await callRail(path: "/api/qq/recommend/new-songs", query: ["limit": "30"]) else {
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
            guard let d = await callRail(path: "/api/qq/recommend/playlists", query: ["limit": "9"]) else {
                return railFailed(kind: .featured, platform: platform, feed: f)
            }
            if let e = railError(d) {
                return RailResult(kind: .featured, platform: platform, feed: f, error: e)
            }
            let lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .featured, platform: platform, feed: f,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "QQ 音乐没返回推荐歌单")
        case "qishui":
            guard let d = await callRail(path: "/api/qishui/feed", query: ["limit": "20"]) else {
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
            guard let d = await callRail(path: "/api/bodian/recommendations") else {
                return railFailed(kind: .featured, platform: platform, feed: f)
            }
            if let e = railError(d) {
                return RailResult(kind: .featured, platform: platform, feed: f, error: e)
            }
            let lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .featured, platform: platform, feed: f,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "波点没返回推荐歌单")
        case "kugou":
            if f == "newsongs" {
                guard let d = await callRail(path: "/api/kugou/top/songs", query: ["type": "1"]) else {
                    return railFailed(kind: .featured, platform: platform, feed: f)
                }
                if let e = railError(d) {
                    return RailResult(kind: .featured, platform: platform, feed: f, error: e)
                }
                let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
                return railDone(kind: .featured, platform: platform, feed: f,
                                entries: tracks.map { RailEntry.track($0) },
                                emptyReason: "酷狗没返回新歌速递")
            }
            guard let d = await callRail(path: "/api/kugou/top/playlists", query: ["limit": "12"]) else {
                return railFailed(kind: .featured, platform: platform, feed: f)
            }
            if let e = railError(d) {
                return RailResult(kind: .featured, platform: platform, feed: f, error: e)
            }
            let lists = railRows(d, keys: ["playlists"]).compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .featured, platform: platform, feed: f,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "酷狗没返回精选歌单")
        case "kuwo":
            if f == "ranks" {
                guard let d = await callRail(path: "/api/kuwo/rank/list") else {
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
            guard let d = await callRail(path: "/api/kuwo/recommend/playlists", query: ["limit": "12"]) else {
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
            guard let d = await callRail(path: "/api/applemusic/playlists", query: ["limit": "12"]) else {
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
                // r31-starred：未登录也先看本地星标——星标的歌照样进「我喜欢」；
                // 没星标才回原来的「先登录」诚实空态。
                if let fb = await localStarredFallback(platform: platform, note: "还没登录，先显示星标的歌") { return fb }
                return railEmpty(kind: .liked, platform: platform,
                                 reason: "先在设置里登录网易云，才能看「我喜欢的音乐」（登录流程在 P4，未登录时这里是空的）。")
            }
            guard let d = await callRail(path: "/api/user/playlist", query: ["uid": uid]) else {
                if let fb = await localStarredFallback(platform: platform, note: "「我喜欢的音乐」暂时拉不到，先显示星标的歌") { return fb }
                return railFailed(kind: .liked, platform: platform)
            }
            if let e = railError(d) {
                if let fb = await localStarredFallback(platform: platform, note: e) { return fb }
                return RailResult(kind: .liked, platform: platform, error: e)
            }
            let lists = railRows(d, keys: ["playlists"])
            let like = lists.first { ($0["specialType"] as? NSNumber)?.intValue == 5 }
                ?? lists.first { (($0["name"] as? String) ?? "").contains("喜欢的音乐") }
            var entries: [RailEntry] = []
            if let like, let likeId = railString(like["id"]), !likeId.isEmpty {
                let detail = await playlistDetail(platform: platform, id: likeId)
                entries.append(contentsOf: detail.tracks.map { RailEntry.track($0) })
            }
            // r31：收藏的歌单（subscribed==true）并进「我喜欢」，放分组卡后。
            let subs = lists.filter { ($0["subscribed"] as? NSNumber)?.boolValue == true }
                .compactMap { railPlaylistFrom($0, platform: platform) }
            if !subs.isEmpty {
                entries.append(.groupHeader("我收藏的歌单"))
                entries.append(contentsOf: subs.map { RailEntry.playlist($0) })
            }
            // r31-starred：登录态下星标的歌也并进来（去重：平台喜欢表里已有的不重复）。
            await appendLocalStarred(&entries, platform: platform)
            if entries.isEmpty {
                return railEmpty(kind: .liked, platform: platform, reason: "没找到「我喜欢的音乐」歌单，也没有收藏歌单")
            }
            return RailResult(kind: .liked, platform: platform, entries: entries)
        case "qq":
            // r31-qqkg：与设置页同一把尺子——登录态以本机 QQMusicSessionStore
            // 为准；未登录不调服务端接口（服务端副本可能还留着旧凭证），
            // 先看本地星标，没星标就诚实空态请用户扫码登录。
            if !(await MainActor.run { QQMusicSessionStore.shared.isLoggedIn }) {
                if let fb = await localStarredFallback(platform: platform, note: "先在卡片上扫码登录 QQ 音乐") { return fb }
                return railEmpty(kind: .liked, platform: platform,
                                 reason: "先在卡片上扫码登录 QQ 音乐，才能看「我喜欢」")
            }
            // r31：喜欢曲目 + 收藏的歌单（subscribed==true）+ 收藏的专辑，
            // 三路并行取。
            // r31-starred（用户 2026-11-21 06:44：QQ 优先）：登录了但喜欢
            // 拉不到（传输层没通 / 上游报登录态已失效）时，不再直接报红错
            // 空页——有本地星标就回落到星标（分组卡里原样带上失败原因，
            // 登录失效的信号不丢，只是不再用它把整页挡掉）；没星标才按
            // 原样返回失败。喜欢曲目空 + 收藏也空时同样先看星标。
            async let likedD = callRail(path: "/api/qq/user/liked-songs", query: ["limit": "100"])
            async let listsD = callRail(path: "/api/qq/user/playlists")
            async let albumsD = callRail(path: "/api/qq/user/albums", query: ["limit": "100"])
            guard let liked = await likedD else {
                if let fb = await localStarredFallback(platform: platform, note: "「我喜欢」暂时拉不到，先显示星标的歌") { return fb }
                return railFailed(kind: .liked, platform: platform)
            }
            if let e = railError(liked) {
                if let fb = await localStarredFallback(platform: platform, note: e) { return fb }
                return RailResult(kind: .liked, platform: platform, error: e)
            }
            var entries: [RailEntry] = railRows(liked, keys: ["tracks"])
                .compactMap { Track.from(dict: $0, platform: platform) }
                .map { RailEntry.track($0) }
            if let lists = await listsD, railError(lists) == nil {
                let subs = railRows(lists, keys: ["playlists"])
                    .filter { ($0["subscribed"] as? NSNumber)?.boolValue == true }
                    .compactMap { railPlaylistFrom($0, platform: platform) }
                if !subs.isEmpty {
                    entries.append(.groupHeader("我收藏的歌单"))
                    entries.append(contentsOf: subs.map { RailEntry.playlist($0) })
                }
            }
            if let albums = await albumsD, railError(albums) == nil {
                let list = railRows(albums, keys: ["data"])
                    .compactMap { railAlbumFrom($0, platform: platform) }
                if !list.isEmpty {
                    entries.append(.groupHeader("我收藏的专辑"))
                    entries.append(contentsOf: list.map { RailEntry.album($0) })
                }
            }
            // r31-starred：登录态下星标的歌也并进来（去重）；平台喜欢 +
            // 收藏全空时星标就是整页内容，不空页。
            await appendLocalStarred(&entries, platform: platform)
            if entries.isEmpty {
                return railEmpty(kind: .liked, platform: platform, reason: "QQ 音乐的「我喜欢」是空的，也没有收藏的歌单/专辑")
            }
            return RailResult(kind: .liked, platform: platform, entries: entries)
        case "qishui":
            guard let d = await callRail(path: "/api/qishui/user/playlists", query: ["limit": "100"]) else {
                if let fb = await localStarredFallback(platform: platform, note: "「我喜欢的音乐」暂时拉不到，先显示星标的歌") { return fb }
                return railFailed(kind: .liked, platform: platform)
            }
            if let e = railError(d) {
                if let fb = await localStarredFallback(platform: platform, note: e) { return fb }
                return RailResult(kind: .liked, platform: platform, error: e)
            }
            let lists = railRows(d, keys: ["playlists"])
            let like = lists.first { ($0["isLikedPlaylist"] as? NSNumber)?.boolValue == true }
                ?? lists.first { (($0["name"] as? String) ?? "").contains("喜欢的音乐") }
            var entries: [RailEntry] = []
            if let like, let likeId = railString(like["id"]), !likeId.isEmpty {
                // r31：喜欢曲目走 playlistAllTracks 翻页取全量（旧实现只取一页 50 首）。
                let tracks = await playlistAllTracks(platform: platform, id: likeId)
                entries.append(contentsOf: tracks.map { RailEntry.track($0) })
            }
            // r31：收藏的歌单（isOwned==false）并进来；喜欢表本身不重复出现。
            let subs = lists.filter { ($0["isOwned"] as? NSNumber)?.boolValue == false }
                .filter { ($0["isLikedPlaylist"] as? NSNumber)?.boolValue != true }
                .compactMap { railPlaylistFrom($0, platform: platform) }
            if !subs.isEmpty {
                entries.append(.groupHeader("我收藏的歌单"))
                entries.append(contentsOf: subs.map { RailEntry.playlist($0) })
            }
            // r31-starred：同网易/QQ——拉到内容时星标并进来（去重），
            // 喜欢表 + 收藏全空时星标兜底，不空页。
            await appendLocalStarred(&entries, platform: platform)
            if entries.isEmpty {
                return railEmpty(kind: .liked, platform: platform, reason: "没找到汽水的「我喜欢的音乐」歌单，也没有收藏歌单")
            }
            return RailResult(kind: .liked, platform: platform, entries: entries)
        case "bodian":
            guard let d = await callRail(path: "/api/bodian/liked_songs") else {
                if let fb = await localStarredFallback(platform: platform, note: "「我的喜欢」暂时拉不到，先显示星标的歌") { return fb }
                return railFailed(kind: .liked, platform: platform)
            }
            if let e = railError(d) {
                if let fb = await localStarredFallback(platform: platform, note: e) { return fb }
                return RailResult(kind: .liked, platform: platform, error: e)
            }
            var entries: [RailEntry] = railRows(d, keys: ["tracks"])
                .compactMap { Track.from(dict: $0, platform: platform) }
                .map { RailEntry.track($0) }
            // r31：收藏的歌单（isOwned==false）+ 收藏的专辑并进来。
            if let u = await callRail(path: "/api/bodian/user/playlists"), railError(u) == nil {
                let subs = railRows(u, keys: ["playlists"])
                    .filter { ($0["isOwned"] as? NSNumber)?.boolValue == false }
                    .filter { ($0["isLikedPlaylist"] as? NSNumber)?.boolValue != true }
                    .compactMap { railPlaylistFrom($0, platform: platform) }
                if !subs.isEmpty {
                    entries.append(.groupHeader("我收藏的歌单"))
                    entries.append(contentsOf: subs.map { RailEntry.playlist($0) })
                }
                let albums = railRows(u, keys: ["albums"])
                    .compactMap { railAlbumFrom($0, platform: platform) }
                if !albums.isEmpty {
                    entries.append(.groupHeader("我收藏的专辑"))
                    entries.append(contentsOf: albums.map { RailEntry.album($0) })
                }
            }
            // r31-starred：同网易/QQ/汽水——星标并进来（去重），全空时星标兜底。
            await appendLocalStarred(&entries, platform: platform)
            if entries.isEmpty {
                return railEmpty(kind: .liked, platform: platform, reason: "波点的「我的喜欢」是空的，也没有收藏内容")
            }
            return RailResult(kind: .liked, platform: platform, entries: entries)
        case "kugou":
            // r31-qqkg：同款登录态门（本机 KugouSessionStore，与设置页同一把
            // 尺子）；未登录直接走本地星标，不调服务端接口。
            if !(await MainActor.run { KugouSessionStore.shared.isLoggedIn }) {
                return await railLocalLiked(kind: .liked, platform: platform)
            }
            // r31：酷狗以前只有本地星标——get_all_list 里其实有「我喜欢」那张
            // 表（listId "2" / 名字含「喜欢」），以前被当成普通歌单。未登录
            // 时 user/playlists 回 401，退回本地星标（旧行为），不报错。
            // r31-starred（用户 2026-11-21 06:44：酷狗优先）：登录了但
            // user/playlists 拉不到时同款回落——以前只有含「登录」的报错
            // 才回落，其它报错（上游异常/非 200）直接报红空页；现在任何
            // 拉不到都先看星标，有星标就显示星标，没星标才报原来的错。
            guard let d = await callRail(path: "/api/kugou/user/playlists") else {
                return await railLocalLiked(kind: .liked, platform: platform)
            }
            if let e = railError(d) {
                if e.contains("登录") { return await railLocalLiked(kind: .liked, platform: platform) }
                if let fb = await localStarredFallback(platform: platform, note: e) { return fb }
                return RailResult(kind: .liked, platform: platform, error: e)
            }
            let lists = railRows(d, keys: ["playlists"])
            var entries: [RailEntry] = []
            if let liked = lists.first(where: { isKugouLikedList($0) }),
               let likedId = railString(liked["id"]), !likedId.isEmpty {
                let tracks = await playlistAllTracks(platform: platform, id: likedId)
                entries.append(contentsOf: tracks.map { RailEntry.track($0) })
            }
            let subs = lists.filter { ($0["isOwned"] as? NSNumber)?.boolValue != true }
                .filter { !isKugouLikedList($0) }
                .compactMap { railPlaylistFrom($0, platform: platform) }
            if !subs.isEmpty {
                entries.append(.groupHeader("我收藏的歌单"))
                entries.append(contentsOf: subs.map { RailEntry.playlist($0) })
            }
            let albums = railRows(d, keys: ["albums"])
                .compactMap { railAlbumFrom($0, platform: platform) }
            if !albums.isEmpty {
                entries.append(.groupHeader("我收藏的专辑"))
                entries.append(contentsOf: albums.map { RailEntry.album($0) })
            }
            // r31-starred：星标并进来——旧实现不去重，同一首歌既在酷狗
            // 「我喜欢」表里又被星标过会在页里出现两次；现走共用去重。
            await appendLocalStarred(&entries, platform: platform)
            if entries.isEmpty {
                return railEmpty(kind: .liked, platform: platform,
                                 reason: "酷狗没有返回「我喜欢」与收藏内容——登录后才有；未登录时只有本地星标")
            }
            return RailResult(kind: .liked, platform: platform, entries: entries)
        case "kuwo", "applemusic":
            // 这两家没有「我喜欢的音乐」列表接口，也没有用户收藏接口：
            // 只显示本地星标（P2 起 PlaybackStore 同时持久化完整 Track），
            // 没有就诚实空态写清原因，不编假数据。
            return await railLocalLiked(kind: .liked, platform: platform)
        default:
            return railEmpty(kind: .liked, platform: platform,
                             reason: "「\(platform)」的「我喜欢」还没接通")
        }
    }

    /// 酷狗 get_all_list 里的「我喜欢」表：listId "2"（见
    /// specs/sidecars.md canAddToKugouPlaylist 注释），或名字含「喜欢」。
    private static func isKugouLikedList(_ d: [String: Any]) -> Bool {
        if let listId = d["listId"] as? String, listId == "2" { return true }
        if let n = d["listId"] as? NSNumber, n.intValue == 2 { return true }
        return ((d["name"] as? String) ?? "").contains("喜欢")
    }

    /// 专辑字典 → Album（QQ user/albums、酷狗 user/playlists 的 albums、
    /// 波点 user/playlists 的 albums 三路共用；字段名各家不一，按宽容读）。
    private static func railAlbumFrom(_ d: [String: Any], platform: String) -> Album? {
        guard let id = railString(d["id"]), !id.isEmpty else { return nil }
        let title = (d["name"] as? String) ?? (d["title"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        // r37-4：封面键与 railPlaylistFrom 对齐（补 "coverUrl"/"img"；
        // 专辑行个别平台用这两个键，旧链收不到就回黑底音符占位）。
        let cover = railFirstNonEmpty([d["cover"] as? String, d["coverImgUrl"] as? String,
                                       d["picUrl"] as? String, d["pic"] as? String,
                                       d["coverUrl"] as? String, d["img"] as? String])
        var artist = ""
        if let a = d["artists"] as? [[String: Any]] {
            artist = a.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }.joined(separator: " / ")
        }
        if artist.isEmpty { artist = (d["artists"] as? String) ?? "" }
        if artist.isEmpty, let c = d["creator"] as? [String: Any] { artist = (c["nickname"] as? String) ?? "" }
        let trackCount = (d["trackCount"] as? NSNumber)?.intValue ?? 0
        return Album(id: id, title: title, artist: artist,
                     coverURL: cover.isEmpty ? nil : URL(string: cover),
                     source: platform, trackCount: trackCount)
    }

    /// r31-starred：平台喜欢列表拉不到时的本地星标回落（QQ/酷狗优先，
    /// 其余 5 台同款；kuwo / applemusic 本来就只走本地星标，不经这里）。
    /// - 有星标：回整页结果（分组卡 + 星标曲目），`error` 为 nil——
    ///   面板/详情页遇 `error` 非空就只显示报错、把条目盖掉，所以回落
    ///   页不能带 error；失败原因写进分组卡括号里（登录失效的信号不丢，
    ///   只是不再用它把整页挡掉）。
    /// - 没星标：回 nil，调用方按原样返回失败/空态（不编假数据）。
    private static func localStarredFallback(platform: String, note: String) async -> RailResult? {
        let local = await PlaybackStore.likedTracks().filter { $0.platform == platform }
        guard !local.isEmpty else { return nil }
        let platformName = LiziPlatforms.all.first(where: { $0.id == platform })?.name ?? platform
        var entries: [RailEntry] = [.groupHeader("本地星标收藏（\(platformName)：\(note)）")]
        entries.append(contentsOf: local.map { RailEntry.track($0) })
        return RailResult(kind: .liked, platform: platform, entries: entries)
    }

    /// r31-starred：平台喜欢拉到了，星标的歌也并进同一页（分组卡
    /// 「本地星标收藏」；酷狗 r31 起已有这路，旧实现不去重）。
    /// 去重按喜欢复合键（`PlaybackStore.likeKey`：platform + id）——
    /// 同一首歌既在平台喜欢表里又被星标过，只留平台那一行。
    /// 没星标 / 星标全已在页里时什么都不加。
    private static func appendLocalStarred(_ entries: inout [RailEntry], platform: String) async {
        let local = await PlaybackStore.likedTracks().filter { $0.platform == platform }
        guard !local.isEmpty else { return }
        let seen = Set(entries.compactMap { entry -> String? in
            if case .track(let t) = entry { return PlaybackStore.likeKey(for: t) }
            return nil
        })
        let fresh = local.filter { !seen.contains(PlaybackStore.likeKey(for: $0)) }
        guard !fresh.isEmpty else { return }
        entries.append(.groupHeader("本地星标收藏"))
        entries.append(contentsOf: fresh.map { RailEntry.track($0) })
    }

    /// 本地星标兜底（kuwo / applemusic 的喜欢 rail，标题是
    /// 「本地星标收藏」；酷狗 r31 起走平台喜欢表，未登录时退回这里）：
    /// 有星标就列出来并在前面插一张说明卡，没有就诚实空态。
    /// r22l 编译修：PlaybackStore 是 @MainActor（第 22 轮第 5 件，代际计数器
    /// 设计靠它，不许摘），它的 static likedTracks() 也是主隔离；本函数原来是
    /// 同步非隔离，同步调它报硬错。改成 async 后用 await 跨隔离取（调用方
    /// railLiked 本来就是 async），不降级 store、不改返回内容。
    private static func railLocalLiked(kind: RailKind, platform: String) async -> RailResult {
        let platformName = LiziPlatforms.all.first(where: { $0.id == platform })?.name ?? platform
        let local = await PlaybackStore.likedTracks().filter { $0.platform == platform }
        guard !local.isEmpty else {
            let reason: String
            switch platform {
            case "kuwo":
                reason = "酷我没有「我喜欢的音乐」接口——在本 App 里点星标收藏的歌会显示在这里"
            case "kugou":
                reason = "酷狗没有「我喜欢的音乐」列表接口——在本 App 里点星标收藏的歌会显示在这里"
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
            guard let d = await callRail(path: "/api/user/playlist", query: ["uid": uid]) else {
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
            // r31-qqkg：登录态门（本机 QQMusicSessionStore，与设置页同一把尺子）；
            // 未登录报登录空态，不调服务端接口。
            if !(await MainActor.run { QQMusicSessionStore.shared.isLoggedIn }) {
                return railEmpty(kind: .playlists, platform: platform,
                                 reason: "先在卡片上扫码登录 QQ 音乐，才能看「我的歌单」")
            }
            guard let d = await callRail(path: "/api/qq/user/playlists") else {
                return railFailed(kind: .playlists, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .playlists, platform: platform, error: e)
            }
            // r31：「我的歌单」只留自建（subscribed==true 的收藏已并进「我喜欢」，
            // 见 QQ.swift userPlaylists 的打标记）。
            let lists = railRows(d, keys: ["playlists"])
                .filter { ($0["subscribed"] as? NSNumber)?.boolValue != true }
                .compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .playlists, platform: platform,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "QQ 音乐没有返回歌单")
        case "qishui":
            guard let d = await callRail(path: "/api/qishui/user/playlists", query: ["limit": "100"]) else {
                return railFailed(kind: .playlists, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .playlists, platform: platform, error: e)
            }
            let lists = railRows(d, keys: ["playlists"])
                .filter { ($0["isLikedPlaylist"] as? NSNumber)?.boolValue != true }
                .filter { ($0["isOwned"] as? NSNumber)?.boolValue != false }
                .compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .playlists, platform: platform,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "汽水没有返回歌单")
        case "bodian":
            guard let d = await callRail(path: "/api/bodian/user/playlists") else {
                return railFailed(kind: .playlists, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .playlists, platform: platform, error: e)
            }
            // r31：只留自建（isOwned==false 的收藏已并进「我喜欢」；fond
            // 喜欢表本身不进歌单列表，曲目已在 liked 那路）。
            let lists = railRows(d, keys: ["playlists"])
                .filter { ($0["isOwned"] as? NSNumber)?.boolValue != false }
                .filter { ($0["isLikedPlaylist"] as? NSNumber)?.boolValue != true }
                .compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .playlists, platform: platform,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "波点没有返回歌单")
        case "kugou":
            // r31-qqkg：登录态门（本机 KugouSessionStore，与设置页同一把尺子）；
            // 未登录报登录空态，不调服务端接口。
            if !(await MainActor.run { KugouSessionStore.shared.isLoggedIn }) {
                return railEmpty(kind: .playlists, platform: platform,
                                 reason: "先在卡片上扫码登录酷狗音乐，才能看「我的歌单」")
            }
            guard let d = await callRail(path: "/api/kugou/user/playlists") else {
                return railFailed(kind: .playlists, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .playlists, platform: platform, error: e)
            }
            // r31：只留自有（isOwned==true；非自有的收藏已并进「我喜欢」；
            // 专辑不进歌单列表，收藏的专辑在 liked 那路）。
            let lists = railRows(d, keys: ["playlists"])
                .filter { ($0["isOwned"] as? NSNumber)?.boolValue == true }
                .compactMap { railPlaylistFrom($0, platform: platform) }
            return railDone(kind: .playlists, platform: platform,
                            entries: lists.map { RailEntry.playlist($0) },
                            emptyReason: "酷狗没有返回歌单")
        case "kuwo":
            return railEmpty(kind: .playlists, platform: platform,
                             reason: "酷我 Web 没有用户歌单接口（Cookie 登录态只影响播放请求），这里是空的，不编内容。")
        case "applemusic":
            guard let d = await callRail(path: "/api/applemusic/playlists", query: ["limit": "12"]) else {
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
            guard let d = await callRail(path: "/api/netease/dj/recommend", query: ["limit": "8"]) else {
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
            guard let d = await callRail(path: "/api/qq/radio/categories") else {
                return railFailed(kind: .radio, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .radio, platform: platform, error: e)
            }
            let stations = railRows(d, keys: ["stations"]).compactMap { railStationFrom($0, platform: platform) }
            return railDone(kind: .radio, platform: platform,
                            entries: stations.map { RailEntry.station($0) },
                            emptyReason: "QQ 音乐没返回电台频道")
        case "qishui":
            guard let d = await callRail(path: "/api/qishui/feed/modes") else {
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
            guard let d = await callRail(path: "/api/bodian/personal/fm") else {
                return railFailed(kind: .radio, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .radio, platform: platform, error: e)
            }
            let tracks = railRows(d, keys: ["tracks"]).compactMap { Track.from(dict: $0, platform: platform) }
            return railDone(kind: .radio, platform: platform,
                            entries: tracks.map { RailEntry.track($0) },
                            emptyReason: "波点私人 FM 没返回歌曲")
        case "kugou":
            guard let d = await callRail(path: "/api/kugou/fm/class") else {
                return railFailed(kind: .radio, platform: platform)
            }
            if let e = railError(d) {
                return RailResult(kind: .radio, platform: platform, error: e)
            }
            let stations = railRows(d, keys: ["stations"]).compactMap { railStationFrom($0, platform: platform) }
            return railDone(kind: .radio, platform: platform,
                            entries: stations.map { RailEntry.station($0) },
                            emptyReason: "酷狗没返回电台分类")
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

    // MARK: - 频道曲目（详情页下钻；kuwo / applemusic 无电台不设入口；酷狗走 /api/kugou/fm/songs）

    static func railStationTracks(platform: String, stationId: String) async -> RailResult {
        switch platform {
        case "netease":
            guard let d = await callRail(path: "/api/netease/dj/program",
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
            guard let d = await callRail(path: "/api/qq/radio/tracks", query: ["id": stationId]) else {
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
            guard let d = await callRail(path: "/api/qishui/feed",
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
        case "kugou":
            guard let d = await callRail(path: "/api/kugou/fm/songs",
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
        default:
            return railEmpty(kind: .radio, platform: platform,
                             reason: "这个频道暂时没有曲目")
        }
    }

    // MARK: - 歌单曲目（详情页下钻）

    /// 点歌单卡进曲目列表。r31：曲目走 `playlistAllTracks` 翻页取全量
    /// （旧实现只取一页：汽水/波点 limit 50、酷狗 30、酷我榜单 50，
    /// 50 首以上的歌单会被截断；面板「点歌单看全部歌曲」就靠这里不断）。
    /// 网易/QQ/Apple Music 的 detail 本身回全量，playlistAllTracks 内部
    /// 直接调 playlistDetail，不另翻页。
    static func railPlaylistTracks(platform: String, playlist: Playlist, feed: String? = nil) async -> RailResult {
        let tracks = await playlistAllTracks(platform: platform, id: playlist.id, isRank: playlist.isRank)
        return railDone(kind: .playlists, platform: platform,
                        entries: tracks.map { RailEntry.track($0) },
                        emptyReason: "这张歌单没有曲目")
    }

    // MARK: - 登录态（网易喜欢 / 收藏歌单用；未登录返回 nil）

    /// 网易 userId（/api/session 的 profile.userId；未登录 / 拿不到时返回 nil）。
    /// 当前原生版是未登录态，调用方按 nil 走诚实空态，不弹登录（登录是 P4）。
    private static func neteaseUserId() async -> String? {
        guard SessionStore.shared.hasMusicU else { return nil }
        guard let d = await callRail(path: "/api/session"),
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
    /// callSoft 的 rail 版（r35-9）：非 2xx 也把 JSON 体还回来，railError
    /// 才能读到体里的 code/error；没体时回 nil，走原来的 guard-else。
    /// `call` 在非 2xx 时直接回 nil，401/403 的体全丢了，空态只能写通用话。
    private static func callRail(path: String, query: [String: String] = [:]) async -> [String: Any]? {
        await callSoft(path: path, query: query).dict
    }

    private static func railError(_ d: [String: Any]?) -> String? {
        guard let d else { return nil }
        if let e = d["error"] as? String, !e.isEmpty { return e }
        let code = (d["code"] as? NSNumber)?.intValue ?? 0
        guard code != 0, code != 200 else { return nil }
        // r35-9：失败码时先读体里的 message / msg 原话，再回通用 code 文案；
        // code 0/200 时只认 error 字段（成功包里可能带 message 说明文字，
        // 不能把它当成错误）。
        if let e = d["message"] as? String, !e.isEmpty { return e }
        if let e = d["msg"] as? String, !e.isEmpty { return e }
        return "接口返回异常（code=\(code)）"
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
    /// dj.nickname；汽水场景：coverUrl / group；QQ：stations 归一化形状）。
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
