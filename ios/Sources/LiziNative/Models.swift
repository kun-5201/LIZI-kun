import Foundation

/// 原生版数据模型（P1 填实）。
///
/// 字段名约定（已定死，首页 / 搜索 / 播放页三个 UI 工人按这些名字写）：
/// - 平台标识一律用 `platform`（netease / qq / kugou / qishui / bodian / kuwo / applemusic），
///   与壳版 Server 层一致；`source` 是 `platform` 的同义只读别名（壳版字段名叫 source）。
/// - 时长一律毫秒 `durationMs`（Int）；歌词时间一律毫秒（`startMs` / `endMs`，Int）。
/// - 不编平台没有的字段，不编假数据：没有官方接口的平台对应方法返回空态。

// MARK: - 音质（9 档，顺序即优先级：高 → 低）

/// 九档音质（MEMORY：九档音质，极高/较高同为 320k；显示音质 = 实际返回档位）。
enum AudioQuality: String, Codable, Hashable, CaseIterable {
    case standard   // 128k / 标准
    case higher     // 较高（320k）
    case exhigh     // 极高（320k）
    case lossless   // FLAC / 无损
    case hires      // Hi-Res / FLAC 24-bit（臻品音质 2.0）
    case surround   // 环绕声（jyeffect）
    case dolby      // Dolby Atmos / 杜比全景声
    case spatial    // Spatial / 臻品全景声 3.0
    case master     // Master / 臻品母带 4.0

    /// 优先级（越大越好），与 player.js QUALITY_MAP / canonQuality 的档位顺序一致。
    var rank: Int {
        switch self {
        case .standard: return 1
        case .higher: return 2
        case .exhigh: return 3
        case .lossless: return 4
        case .hires: return 5
        case .surround: return 6
        case .dolby: return 7
        case .spatial: return 8
        case .master: return 9
        }
    }

    /// UI 显示名（player.js QUALITY_LABEL 的中文名）。
    var displayName: String {
        switch self {
        case .standard: return "标准"
        case .higher: return "较高"
        case .exhigh: return "极高"
        case .lossless: return "无损"
        case .hires: return "臻品音质 2.0"
        case .surround: return "环绕声"
        case .dolby: return "杜比全景声"
        case .spatial: return "臻品全景声 3.0"
        case .master: return "臻品母带 4.0"
        }
    }

    /// 请求档位 → 各平台上游的真实参数（照抄 player.js QUALITY_MAP；平台没有该档时
    /// 取该平台不高于请求档的最高档）。
    func requestParam(platform: String) -> String {
        switch platform {
        case "netease":
            switch self {
            case .standard: return "standard"
            case .higher: return "higher"
            case .exhigh: return "exhigh"
            case .lossless: return "lossless"
            case .hires: return "hires"
            case .surround: return "jyeffect"
            case .dolby: return "dolby"
            case .spatial: return "sky"
            case .master: return "jymaster"
            }
        case "qq":
            switch self {
            case .standard, .higher: return "128"
            case .exhigh: return "320"
            case .lossless: return "flac"
            case .hires: return "hires"
            case .surround, .dolby: return "atmos51"
            case .spatial: return "atmos20"
            case .master: return "master"
            }
        case "kugou", "kuwo":
            switch self {
            case .standard, .higher: return "128"
            case .exhigh: return "320"
            case .lossless: return "flac"
            case .hires: return "hires"
            default: return "flac"
            }
        case "qishui":
            switch self {
            case .standard, .higher: return "standard"
            case .exhigh: return "high"
            case .lossless: return "lossless"
            default: return "hires"
            }
        case "bodian":
            switch self {
            case .standard, .higher: return "standard"
            case .exhigh: return "high"
            default: return "lossless"
            }
        case "applemusic":
            // Apple Music 公开 API 只有 30 秒试听（128k AAC），选什么档都只能拿到 standard。
            return "standard"
        case "lx":
            switch self {
            case .standard, .higher: return "128k"
            case .exhigh: return "320k"
            case .lossless: return "flac24bit"
            case .hires: return "hires"
            case .surround, .dolby, .spatial: return "atmos"
            case .master: return "master"
            }
        default:
            return "lossless"
        }
    }

    /// 上游实际回的档位值 → 统一档位（照抄 player.js canonQuality；br 为码率 bps，
    /// 只在 served 对不上表时作后备判断）。
    static func canon(platform: String, served: String, bitrate: Int = 0) -> AudioQuality? {
        switch platform {
        case "netease":
            let table: [String: AudioQuality] = ["standard": .standard, "higher": .higher,
                "exhigh": .exhigh, "lossless": .lossless, "hires": .hires, "dolby": .dolby,
                "jyeffect": .surround, "sky": .spatial, "jymaster": .master]
            if let q = table[served] { return q }
        case "qq":
            let table: [String: AudioQuality] = ["master": .master, "atmos51": .dolby,
                "atmos20": .spatial, "hires": .hires, "flac": .lossless, "ape": .lossless,
                "320": .exhigh, "128": .standard, "m4a": .standard]
            if let q = table[served] { return q }
        case "kugou":
            let table: [String: AudioQuality] = ["hires": .hires, "flac": .lossless,
                "320": .exhigh, "128": .standard]
            if let q = table[served] { return q }
        case "kuwo":
            let table: [String: AudioQuality] = ["4000": .hires, "2000": .lossless,
                "320": .exhigh, "128": .standard, "web": .standard]
            if let q = table[served] { return q }
        case "qishui":
            let table: [String: AudioQuality] = ["hires": .hires, "lossless": .lossless,
                "high": .exhigh, "standard": .standard]
            if let q = table[served] { return q }
        case "bodian":
            let table: [String: AudioQuality] = ["lossless": .lossless, "high": .exhigh,
                "standard": .standard]
            if let q = table[served] { return q }
        case "lx":
            let table: [String: AudioQuality] = ["master": .master, "atmos": .dolby,
                "hires": .hires, "flac24bit": .lossless, "320k": .exhigh, "128k": .standard]
            if let q = table[served] { return q }
        default:
            break
        }
        if bitrate >= 800_000 { return .lossless }
        if bitrate >= 300_000 { return .exhigh }
        if bitrate >= 180_000 { return .higher }
        if bitrate > 0 { return .standard }
        return nil
    }
}

// MARK: - 曲目

/// 一首曲目。
struct Track: Identifiable, Codable, Hashable {
    var id: String
    /// 来源平台标识（netease / qq / kugou / qishui / bodian / kuwo / applemusic / local）。
    var platform: String
    /// `platform` 的同义只读别名（壳版字段名叫 source；UI 两边都能用）。
    var source: String { platform }
    var title: String
    var artist: String
    var album: String
    /// 封面 URL（可能为空；无封面时 UI 用白色占位，不用金色）。
    var coverURL: URL?
    /// 时长（毫秒）；未知时为 0。
    var durationMs: Int
    /// 实际返回的音质档位（显示音质 = 实际返回档位，绝不显示请求的档位）。
    /// 未取链时为 nil。
    var quality: AudioQuality?
    /// 是否 VIP 专属曲（fee != 0）；需要会员才能播整首。
    var vip: Bool
    /// 是否试听片段（官方只给了 freeTrialInfo / preview）。
    var isTrial: Bool
    /// 调各平台 song/url 时要传的键：网易 = id，QQ = mid，酷狗 = hash，
    /// 酷我 = rid，汽水/波点/Apple Music = id。空时用 `id`。
    var platformKey: String
    /// 专辑 id（平台有才填；没有时为空）。
    var albumId: String
    /// 歌手 id 列表（平台有才填）。
    var artistIds: [String]

    /// 时长（秒，UI/播放器用）。
    var durationSeconds: TimeInterval { TimeInterval(durationMs) / 1000 }

    init(id: String = UUID().uuidString, platform: String = "", title: String = "",
         artist: String = "", album: String = "", coverURL: URL? = nil,
         durationMs: Int = 0, quality: AudioQuality? = nil, vip: Bool = false,
         isTrial: Bool = false, platformKey: String = "", albumId: String = "",
         artistIds: [String] = []) {
        self.id = id
        self.platform = platform
        self.title = title
        self.artist = artist
        self.album = album
        self.coverURL = coverURL
        self.durationMs = durationMs
        self.quality = quality
        self.vip = vip
        self.isTrial = isTrial
        self.platformKey = platformKey.isEmpty ? id : platformKey
        self.albumId = albumId
        self.artistIds = artistIds
    }
}

/// 队列里的一项（同一首歌可进队列多次，queueId 区分每一次入队）。
struct QueueItem: Identifiable, Codable, Hashable {
    var id: String { queueId }
    var queueId: String
    var track: Track

    init(track: Track, queueId: String = UUID().uuidString) {
        self.track = track
        self.queueId = queueId
    }
}

// MARK: - 歌词

/// 一行歌词（时间毫秒，照抄 player.js parseLyrics 的统一结构）。
struct LyricLine: Identifiable, Codable, Hashable {
    var id: String { "\(startMs)-\(text)" }
    /// 行起点（毫秒）。
    var startMs: Int
    /// 行文本。
    var text: String
    /// 逐字（YRC/KRC 解析出才有；没有时为空，UI 按整行显示）。
    var words: [LyricWord]
    /// 译文（tlyric/ytlrc 有才填；没有时为空）。
    var translation: String

    init(startMs: Int = 0, text: String = "", words: [LyricWord] = [],
         translation: String = "") {
        self.startMs = startMs
        self.text = text
        self.words = words
        self.translation = translation
    }
}

/// 歌词里的一个字（逐字歌词用；时间毫秒，绝对时间）。
struct LyricWord: Codable, Hashable {
    var text: String
    /// 字起点（毫秒，绝对时间）。
    var startMs: Int
    /// 字结束（毫秒，绝对时间）。
    var endMs: Int

    init(text: String, startMs: Int, endMs: Int) {
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

/// 一次歌词拉取的完整结果（官方 → LRCLIB 兜底后仍为空时 lines 为空，
/// 调用方显示歌名，绝不用 ♪ 作假歌词）。
struct ParsedLyrics: Codable, Hashable {
    var lines: [LyricLine]
    /// yrc（逐字）/ lrc / none。
    var format: String

    init(lines: [LyricLine] = [], format: String = "none") {
        self.lines = lines
        self.format = format
    }
}

// MARK: - 搜索 / 内容

/// 一次搜索的结果（分平台分组；只用各平台自己的搜索接口，绝不用 LX 搜索）。
struct SearchResult: Codable {
    var tracks: [Track]
    var playlists: [Playlist]
    var artists: [Artist]
    var albums: [Album]
    /// 是否还有更多（分页用）。
    var hasMore: Bool
    /// 上游报的总条数（未知时为 tracks.count）。
    var totalCount: Int
    /// 按平台分的失败信息（platform → 原因文案；P1 集成补的轻量错误通道）。
    /// 空 = 这一搜没有接口失败；「搜不到结果」时对应平台不在这里面，UI 才能
    /// 分清「搜不到」和「接口挂了」。只在上游请求本身失败（call 回 nil）时填，
    /// 上游正常回空列表不填。
    var errors: [String: String]

    init(tracks: [Track] = [], playlists: [Playlist] = [],
         artists: [Artist] = [], albums: [Album] = [],
         hasMore: Bool = false, totalCount: Int = 0,
         errors: [String: String] = [:]) {
        self.tracks = tracks
        self.playlists = playlists
        self.artists = artists
        self.albums = albums
        self.hasMore = hasMore
        self.totalCount = totalCount
        self.errors = errors
    }
}

/// 一个歌单。
struct Playlist: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var coverURL: URL?
    /// 曲目数（未知时为 0）。
    var trackCount: Int
    /// 来源平台标识。
    var source: String
    /// 歌单描述（可能为空）。
    var description: String
    /// 创建者（有才填）。
    var creator: String
    /// 是否酷我榜单：rank 标记来自搜索/榜单字典的 rank 字段（壳版 app.js
    /// openPlatPlaylist：p.rank 为真走 kuwoRankTracks）；为真时详情走
    /// /api/kuwo/rank/tracks，否则走 /api/kuwo/playlist/tracks。默认 false。
    /// 桥接搜索目前只填 tracks、不填歌单，该标记由填歌单的工人（P2-B/C/D 的
    /// 榜单/推荐来源）从字典 rank 字段置 true。
    var isRank: Bool
    /// 详情拉取到的曲目（列表接口不填，只有 playlistDetail 填）。
    var tracks: [Track]

    init(id: String = "", title: String = "", coverURL: URL? = nil,
         trackCount: Int = 0, source: String = "", description: String = "",
         creator: String = "", isRank: Bool = false, tracks: [Track] = []) {
        self.id = id
        self.title = title
        self.coverURL = coverURL
        self.trackCount = trackCount
        self.source = source
        self.description = description
        self.creator = creator
        self.isRank = isRank
        self.tracks = tracks
    }
}

/// 一位歌手（P2 歌手页填充）。
struct Artist: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var coverURL: URL?
    var source: String
    /// 热门曲目（artistDetail 填；列表接口不填）。
    var hotTracks: [Track]
    /// 专辑列表（P2 歌手页 artistAlbums 填；列表接口不填）。
    var albums: [Album]

    init(id: String = "", name: String = "", coverURL: URL? = nil,
         source: String = "", hotTracks: [Track] = [], albums: [Album] = []) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.source = source
        self.hotTracks = hotTracks
        self.albums = albums
    }
}

/// 一张专辑（P2 专辑页填充）。
struct Album: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var artist: String
    var coverURL: URL?
    var source: String
    /// 曲目数（未知时为 0）。
    var trackCount: Int
    /// 专辑曲目（albumDetail 填；列表接口不填）。
    var tracks: [Track]

    init(id: String = "", title: String = "", artist: String = "",
         coverURL: URL? = nil, source: String = "", trackCount: Int = 0,
         tracks: [Track] = []) {
        self.id = id
        self.title = title
        self.artist = artist
        self.coverURL = coverURL
        self.source = source
        self.trackCount = trackCount
        self.tracks = tracks
    }
}

/// 每日推荐里的一首歌。
struct DailyTrack: Identifiable, Codable, Hashable {
    var id: String { track.id }
    var track: Track
    /// 推荐理由（上游有才填；没有时为空，不编）。
    var reason: String

    init(track: Track, reason: String = "") {
        self.track = track
        self.reason = reason
    }
}
