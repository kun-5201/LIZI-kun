import Foundation

/// 原生版数据模型骨架（P0：空模型定义，后续工人按各平台真实接口填充字段）。
///
/// 约定：
/// - `source` 一律用平台标识字符串（netease / qq / kugou / qishui / bodian / kuwo / applemusic），
///   与壳版 Server 层一致；不编平台没有的字段，不编假数据。
/// - 搜索只用各平台自己的接口（绝不用 LX 搜索）；LX 只做取链 fallback（P1 编排器负责）。

/// 一首曲目。
struct Track: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var artist: String
    var album: String
    /// 封面 URL（可能为空；无封面时 UI 用白色占位，不用金色）。
    var coverURL: URL?
    /// 时长（秒）；未知时为 0。
    var duration: TimeInterval
    /// 来源平台标识（见文件头约定）。
    var source: String
    /// 实际返回的音质档位（显示音质 = 实际返回档位，绝不显示请求的档位）。
    var quality: String

    init(id: String = UUID().uuidString, title: String = "", artist: String = "",
         album: String = "", coverURL: URL? = nil, duration: TimeInterval = 0,
         source: String = "", quality: String = "") {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.coverURL = coverURL
        self.duration = duration
        self.source = source
        self.quality = quality
    }
}

/// 一行歌词。
struct LyricLine: Identifiable, Codable, Hashable {
    var id: String { "\(startTime)-\(text)" }
    /// 行起点（秒）。
    var startTime: TimeInterval
    /// 行文本。
    var text: String
    /// 逐字（YRC/KRC 解析出才有；没有时为空，UI 按整行显示）。
    var words: [LyricWord]

    init(startTime: TimeInterval = 0, text: String = "", words: [LyricWord] = []) {
        self.startTime = startTime
        self.text = text
        self.words = words
    }
}

/// 歌词里的一个字（逐字歌词用）。
struct LyricWord: Codable, Hashable {
    var text: String
    /// 字起点（秒，绝对时间）。
    var startTime: TimeInterval
    /// 字时长（秒）。
    var duration: TimeInterval
}

/// 一次搜索的结果（分平台分组；P1 填充分页与各平台真实字段）。
struct SearchResult: Codable {
    var tracks: [Track]
    var playlists: [Playlist]
    var artists: [Artist]
    var albums: [Album]

    init(tracks: [Track] = [], playlists: [Playlist] = [],
         artists: [Artist] = [], albums: [Album] = []) {
        self.tracks = tracks
        self.playlists = playlists
        self.artists = artists
        self.albums = albums
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

    init(id: String = "", title: String = "", coverURL: URL? = nil,
         trackCount: Int = 0, source: String = "", description: String = "") {
        self.id = id
        self.title = title
        self.coverURL = coverURL
        self.trackCount = trackCount
        self.source = source
        self.description = description
    }
}

/// 一位歌手（P2 歌手页填充）。
struct Artist: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var coverURL: URL?
    var source: String

    init(id: String = "", name: String = "", coverURL: URL? = nil, source: String = "") {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.source = source
    }
}

/// 一张专辑（P2 专辑页填充）。
struct Album: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var artist: String
    var coverURL: URL?
    var source: String

    init(id: String = "", title: String = "", artist: String = "", coverURL: URL? = nil, source: String = "") {
        self.id = id
        self.title = title
        self.artist = artist
        self.coverURL = coverURL
        self.source = source
    }
}
