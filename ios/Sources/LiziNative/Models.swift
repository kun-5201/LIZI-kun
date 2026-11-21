import Foundation

/// 原生版数据模型（P1 填实）。
///
/// 字段名约定（已定死，首页 / 搜索 / 播放页三个 UI 工人按这些名字写）：
/// - 平台标识一律用 `platform`（netease / qq / qishui / bodian / kuwo / applemusic），
///   与壳版 Server 层一致；`source` 是 `platform` 的同义只读别名（壳版字段名叫 source）。
/// - 时长一律毫秒 `durationMs`（Int）；歌词时间一律毫秒（`startMs` / `endMs`，Int）。
/// - 不编平台没有的字段，不编假数据：没有官方接口的平台对应方法返回空态。

// MARK: - 音质（9 档，顺序即优先级：高 → 低）

/// 九档音质（r31 音质系统替换：Moumusic 的档位结构，只学流程和结构、
///
/// 按 Lizi 结构原生实现，不抄 Moumusic 代码；Moumusic 是 GPL-3.0，
/// 这里只取它的档位名 / 网易 level 映射 / 选档流程这些公开结构）。
/// 档位名与 Moumusic SettingsManager.AudioQuality 一致：
/// master 超清母带、atmos 高清环绕声、dolby 杜比全景声、
/// surround 沉浸环绕声、hires Hi-Res（FLAC 24-bit）、lossless 无损、
/// exhigh/higher 极高/较高（同档 320k）、standard 标准 128k。
/// 旧版的 `spatial`（臻品全景声 3.0）已删：它就是 Moumusic 的
/// surround（网易 sky / QQ atmos20），不是独立档位；旧存档里
/// "spatial" 由 SettingsStore.storedAudioQuality() 迁成 .surround。
/// 显示音质 = 实际返回档位（servedQuality），绝不显示请求的档位。
enum AudioQuality: String, Codable, Hashable, CaseIterable {
    case master     // 超清母带（jymaster）
    case atmos      // 高清环绕声（jyeffect）
    case dolby      // 杜比全景声（dolby）
    case surround   // 沉浸环绕声（sky）
    case hires      // Hi-Res / FLAC 24-bit
    case lossless   // FLAC / 无损
    case exhigh     // 极高（320k）
    case higher     // 较高（320k，与极高同档）
    case standard   // 标准（128k）

    /// 优先级（越大越好），与 Moumusic allCases 高 → 低的顺序一致。
    var rank: Int {
        switch self {
        case .standard: return 1
        case .higher: return 2
        case .exhigh: return 3
        case .lossless: return 4
        case .hires: return 5
        case .surround: return 6
        case .dolby: return 7
        case .atmos: return 8
        case .master: return 9
        }
    }

    /// UI 显示名（Moumusic displayName）。
    var displayName: String {
        switch self {
        case .master: return "超清母带"
        case .atmos: return "高清环绕声"
        case .dolby: return "杜比全景声"
        case .surround: return "沉浸环绕声"
        case .hires: return "Hi-Res"
        case .lossless: return "无损"
        case .exhigh: return "极高"
        case .higher: return "较高"
        case .standard: return "标准"
        }
    }

    /// 技术标注（Moumusic sourceDisplayName：档位名 + 英文/码率，
    /// 绝不宣称音源没给过的档位；只在选择器里作补充说明）。
    var sourceDisplayName: String {
        switch self {
        case .master: return "超清母带 / Master"
        case .atmos: return "高清环绕声 / Spatial"
        case .dolby: return "杜比全景声 / Dolby Atmos"
        case .surround: return "沉浸环绕声 / Surround"
        case .hires: return "Hi-Res / FLAC 24-bit"
        case .lossless: return "无损 FLAC"
        case .exhigh, .higher: return "320 kbps"
        case .standard: return "128 kbps"
        }
    }

    /// LX 协议里的档位名（Moumusic lxType；Lizi 的 LX 腿只认这套：
    /// master=jymaster、atmos=atmos、dolby=dolby、surround=surround、
    /// hires=flac24bit、lossless=flac、exhigh/higher=320k、standard=128k）。
    var lxType: String {
        switch self {
        case .master: return "jymaster"
        case .atmos: return "atmos"
        case .dolby: return "dolby"
        case .surround: return "surround"
        case .hires: return "flac24bit"
        case .lossless: return "flac"
        case .exhigh, .higher: return "320k"
        case .standard: return "128k"
        }
    }

    /// LX/音源回的档位字符串 → 统一档位（Moumusic init?(lxType:) 的
    /// 映射；对不上的字符串回 nil——调用方原样显示原文，不压档）。
    init?(lxType raw: String) {
        switch raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "master", "jymaster", "master_quality", "master-quality": self = .master
        case "atmos", "immersive": self = .atmos
        case "dolby", "dolby-atmos", "dolbyatmos": self = .dolby
        case "surround", "spatial", "spatial-audio": self = .surround
        case "128", "128k", "m4a", "mp3": self = .standard
        case "320", "320k": self = .exhigh
        case "flac", "lossless", "ape": self = .lossless
        case "flac24bit", "flac24", "hires", "highres": self = .hires
        default: return nil
        }
    }

    /// 网易官方取链的 level 参数（Moumusic neteaseLevel）：
    /// master=jymaster、atmos=jyeffect、dolby=dolby、surround=sky、
    /// hires=hires、lossless=lossless、exhigh/higher=exhigh、
    /// standard=standard。
    var neteaseLevel: String {
        switch self {
        case .master: return "jymaster"
        case .atmos: return "jyeffect"
        case .dolby: return "dolby"
        case .surround: return "sky"
        case .hires: return "hires"
        case .lossless: return "lossless"
        case .exhigh, .higher: return "exhigh"
        case .standard: return "standard"
        }
    }

    /// 网易 level → 统一档位（Moumusic init?(neteaseLevel:) 的映射）。
    init?(neteaseLevel raw: String) {
        switch raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "jymaster", "master": self = .master
        case "jyeffect", "atmos", "immersive": self = .atmos
        case "dolby", "dolby_atmos": self = .dolby
        case "sky", "surround", "spatial": self = .surround
        case "hires", "highres": self = .hires
        case "lossless", "flac": self = .lossless
        case "exhigh", "higher": self = .exhigh
        case "standard", "128k": self = .standard
        default: return nil
        }
    }

    /// 请求档位 → 各平台上游的真实参数（r31：网易直接走 neteaseLevel；
    /// 其它平台按各平台自己的取链参数；平台没有该档时取链端按实际返回
    /// 为准，不在这里降档——降档阶梯（R4）已删，请求档直发音源）。
    func requestParam(platform: String) -> String {
        switch platform {
        case "netease":
            return neteaseLevel
        case "qq":
            switch self {
            case .standard, .higher: return "128"
            case .exhigh: return "320"
            case .lossless: return "flac"
            case .hires: return "hires"
            case .atmos, .dolby: return "atmos51"
            case .surround: return "atmos20"
            case .master: return "master"
            }
        case "kuwo":
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
        case "kugou":
            // Folia qualityValue：standard→128，high/ultra→320，lossless→flac，hires→high。
            switch self {
            case .standard: return "128"
            case .higher, .exhigh: return "320"
            case .lossless: return "flac"
            case .hires: return "high"
            default: return "flac"
            }
        case "lx":
            // Lizi LX 腿的协议值（LXResolver.normalizeQuality / scriptTiers：
            // master / atmos / hires / flac24bit / 320k / 128k；服务端
            // normalizeQuality 把 atmos/dolby/surround/jyeffect 都归一成
            // atmos，所以 atmos/dolby/surround 三档发同一个值）。
            switch self {
            case .standard, .higher: return "128k"
            case .exhigh: return "320k"
            case .lossless: return "flac24bit"
            case .hires: return "hires"
            case .atmos, .dolby, .surround: return "atmos"
            case .master: return "master"
            }
        default:
            return "lossless"
        }
    }

    /// 上游实际回的档位值 → 统一档位（只认档位表；对不上的字符串回 nil，
    /// 调用方原样显示原文，绝不按码率猜档位）。
    /// r31（R6 已删）：旧版 canon 末尾的 br 分段（bitrate ≥ 800k →
    /// 无损、≥ 300k → 极高……）与「192k 等非标码率压 standard」已全删。
    /// 码率不是档位证据——192k 的流就是 192k，显示原文，不压成标准；
    /// 真实档位由实测链（StreamQualityMeasurer：AVFoundation 流实测 →
    /// 文件头 → URL 文件名）定，canon 只翻译音源给的档位名。
    static func canon(platform: String, served: String) -> AudioQuality? {
        switch platform {
        case "netease":
            let table: [String: AudioQuality] = ["standard": .standard, "higher": .higher,
                "exhigh": .exhigh, "lossless": .lossless, "hires": .hires, "dolby": .dolby,
                "jyeffect": .atmos, "sky": .surround, "jymaster": .master]
            if let q = table[served] { return q }
        case "qq":
            let table: [String: AudioQuality] = ["master": .master, "atmos51": .dolby,
                "atmos20": .surround, "hires": .hires, "flac": .lossless, "ape": .lossless,
                "320": .exhigh, "128": .standard, "m4a": .standard]
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
        case "kugou":
            // Folia 回的档位值就是请求时传的网关值（128 / 320 / flac / high）。
            let table: [String: AudioQuality] = ["high": .hires, "flac": .lossless,
                "320": .exhigh, "128": .standard]
            if let q = table[served] { return q }
        case "lx":
            // LX 腿回的是脚本 tier（scriptTiers：master / atmos / hires /
            // flac24bit / 320k / 128k）+ 归一化别名（jymaster / flac）。
            let table: [String: AudioQuality] = ["master": .master, "jymaster": .master,
                "atmos": .atmos, "dolby": .dolby, "surround": .surround,
                "hires": .hires, "flac24bit": .lossless, "flac": .lossless,
                "320k": .exhigh, "320": .exhigh, "128k": .standard, "128": .standard]
            if let q = table[served] { return q }
        default:
            break
        }
        return nil
    }

    /// QQ 直链文件名档位前缀 → 真实档位（QQ vkey 的 purl 就是这个文件名：
    /// C400=128k m4a、M500=128k mp3、M800=320k、A000=APE、F000=FLAC、
    /// RS01=Hi-Res、Q001=全景声 5.1、Q000=全景声 2.0、AI00=母带。
    /// 前缀只认大写——网易等平台的 URL 哈希是小写 hex，不会误撞）。
    static func qqFilenameTier(_ prefix: String) -> AudioQuality? {
        switch prefix {
        case "C400", "M500": return .standard
        case "M800": return .exhigh
        case "A000", "F000": return .lossless
        case "RS01": return .hires
        case "Q001": return .dolby
        case "Q000": return .surround
        case "AI00": return .master
        default: return nil
        }
    }

    /// 流实证校验（r31 真实音质 + r31 音质系统替换）：上游宣称的档位
    /// （`claimed`，来自 canon）绝不能高于返回流本身能证明的上限；
    /// 宣称高于上限时往下压，实证与宣称都给不出档位时回 nil
    /// （UI 不挂徽章，绝不拿请求档位顶）。
    /// - `url`：实际要播的地址（代理前的上游原址）。QQ 直链的文件名含
    ///   档位前缀时，前缀就是地面真相，直接定档、覆盖宣称。
    /// - `format`：上游给的容器名（网易 `type`、酷我 `format`；没有时
    ///   看 URL 后缀）。有损容器（mp3/m4a/aac/ogg）上限 320k（.exhigh）；
    ///   无损容器（flac/ape/wav）不设上限——容器本身不矛盾时宣称原样。
    /// - `bitrate`（bps）：r31（R6 已删）不再参与判定——码率分段
    ///   （≤400k 压档 / 192k 压 standard）已全删，参数只保留调用点
    ///   稳定，值被忽略；流的真实码率由实测链
    ///   （StreamQualityMeasurer：AVFoundation 读实际解码轨道）定，
    ///   不在这里按宣称的 br 猜档位。
    /// - 无实证（未知后缀、无码率、无前缀）时宣称原样——没有反证不
    ///   否定上游；LX 不透明地址就是这一档（残留风险见 NativeBridge
    ///   lxSongURL 的注释）。
    static func verified(claimed: AudioQuality?, url: URL?,
                         bitrate: Int = 0, format: String? = nil) -> AudioQuality? {
        guard let claimed else { return nil }
        // 1）QQ 文件名前缀 = 地面真相。
        if let name = url?.lastPathComponent, name.count >= 5,
           let q = qqFilenameTier(String(name.prefix(4))) { return q }
        // 2）容器实证：format 优先，其次 URL 后缀（无后缀时扫全串，
        // LX 的不透明地址常把 .mp3/.flac 藏在 query 里）。
        let fmt = (format ?? "").lowercased()
        var ext = (url?.pathExtension ?? "").lowercased()
        if ext.isEmpty, let s = url?.absoluteString.lowercased() {
            for cand in ["flac", "ape", "wav", "mp3", "m4a", "aac", "ogg"] where s.contains(".\(cand)") {
                ext = cand
                break
            }
        }
        let lossyExts = ["mp3", "m4a", "aac", "ogg", "oga"]
        let losslessExts = ["flac", "ape", "wav", "alac"]
        // format（上游明给的容器）优先于 URL 后缀：网易 FLAC 流的地址
        // 后缀常是 .mp3（type=flac 才是真的），以后缀否定它会把真无损
        // 压成 320k；只有 format 没给/不认时才看后缀。
        let lossy: Bool
        if lossyExts.contains(fmt) || losslessExts.contains(fmt) {
            lossy = lossyExts.contains(fmt)
        } else {
            lossy = lossyExts.contains(ext)
        }
        _ = bitrate // R6 已删：码率不参与判定（见本函数文件头）。
        func capped(_ cap: AudioQuality) -> AudioQuality {
            claimed.rank <= cap.rank ? claimed : cap
        }
        // 3）有损容器：上限 320k（容器实证，不是码率分段：mp3 文件
        // 物理上装不下无损/母带，宣称再高也只能是 320k）。
        if lossy { return capped(.exhigh) }
        // 4）无损容器 / 无实证：宣称原样。
        return claimed
    }
}

// MARK: - 播放来源（三段，Moumusic PlaybackSourceMode 的结构、Lizi 的语义）

/// 选哪条腿先取链（r31 音质系统替换）。
/// R7 已删：三段只是优先顺序，不再是硬隔离——任何一段取不到时都可
/// 以另一段兜底，绝不因模式把能播的地址拒在门外：
/// - automatic（自动）：LX 优先取请求档、账号只兜底；先拿到的一腿
///   档位低于请求档时，先记下它，再向另一腿要高档，留档高者。
/// - official（账号优先）：账号腿先，拿不到 / 档位不够时走 LX。
/// - thirdParty（第三方优先）：LX 腿先，拿不到时走账号。
enum PlaybackSourceMode: String, Codable, Hashable, CaseIterable {
    case automatic
    case official
    case thirdParty

    /// 设置页三段控件里的短名。
    var shortDisplayName: String {
        switch self {
        case .automatic: return "自动"
        case .official: return "账号优先"
        case .thirdParty: return "第三方优先"
        }
    }

    /// 设置页三段控件下的说明（每段到底先走哪条腿、兜底是谁）。
    var explanation: String {
        switch self {
        case .automatic:
            return "LX 音源优先取请求档位；LX 拿不到或档位不够时用账号音源兜底，档高者胜。"
        case .official:
            return "先用已登录账号的官方音源；账号拿不到或档位不够时用 LX 音源兜底。"
        case .thirdParty:
            return "先用 LX 第三方音源；LX 拿不到时用账号音源兜底。"
        }
    }
}

// MARK: - 曲目

/// 一首曲目。
struct Track: Identifiable, Codable, Hashable {
    var id: String
    /// 来源平台标识（netease / qq / qishui / bodian / kuwo / kugou / applemusic / local）。
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
    /// 调各平台 song/url 时要传的键：网易 = id，QQ = mid，酷我 = rid，
    /// 酷狗 = hash（track 的 id 即 hash），汽水/波点/Apple Music = id。空时用 `id`。
    var platformKey: String
    /// 专辑 id（平台有才填；没有时为空）。
    var albumId: String
    /// 专辑内曲目 id（酷狗 song_url 的 album_audio_id；其它平台为 0）。
    var albumAudioId: Int
    /// 歌手 id 列表（平台有才填）。
    var artistIds: [String]
    /// ISRC（国际标准录音编码，12 位，全球统一、不受语言影响）。
    /// r30 路线 B 用它走 Apple Music catalog 精确匹配。
    /// 只有 Apple Music 的 catalog 数据实测带 ISRC（2026-11-21 VM 实测：
    /// 其余 6 台的搜索行与歌曲详情里都没有 isrc 字段，见
    /// AppleAnimatedArtwork.swift 文件头的 r30 平台表）；没有时为空，
    /// 路线 B 回落名字匹配。归一化（去连字符/空白、全大写、12 位校验）
    /// 在 Track.from 里由 AppleAnimatedArtworkProvider.normalizedISRC 做。
    var isrc: String

    /// 时长（秒，UI/播放器用）。
    var durationSeconds: TimeInterval { TimeInterval(durationMs) / 1000 }

    init(id: String = UUID().uuidString, platform: String = "", title: String = "",
         artist: String = "", album: String = "", coverURL: URL? = nil,
         durationMs: Int = 0, quality: AudioQuality? = nil, vip: Bool = false,
         isTrial: Bool = false, platformKey: String = "", albumId: String = "",
         albumAudioId: Int = 0,
         artistIds: [String] = [], isrc: String = "") {
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
        self.albumAudioId = albumAudioId
        self.artistIds = artistIds
        self.isrc = isrc
    }

    /// r30：容错解码——队列持久化（PlaybackStore）存的是旧版 Track（无 isrc
    /// 键），合成的 Codable 会因缺键整个解码失败、队列丢光；这里逐字段
    /// decodeIfPresent、缺失按 memberwise init 的缺省值补，旧存档照常读回。
    /// encode 仍用合成实现（不写 encode(to:)）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        coverURL = try c.decodeIfPresent(URL.self, forKey: .coverURL)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        quality = try c.decodeIfPresent(AudioQuality.self, forKey: .quality)
        vip = try c.decodeIfPresent(Bool.self, forKey: .vip) ?? false
        isTrial = try c.decodeIfPresent(Bool.self, forKey: .isTrial) ?? false
        let rawKey = try c.decodeIfPresent(String.self, forKey: .platformKey) ?? ""
        platformKey = rawKey.isEmpty ? id : rawKey
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId) ?? ""
        albumAudioId = try c.decodeIfPresent(Int.self, forKey: .albumAudioId) ?? 0
        artistIds = try c.decodeIfPresent([String].self, forKey: .artistIds) ?? []
        isrc = try c.decodeIfPresent(String.self, forKey: .isrc) ?? ""
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

/// 排行榜目录里的一张榜（r35-10）：id 是榜单 id（网易 = 歌单 id、
/// QQ = topId、酷狗 = rankid、酷我 = bangId），点卡进详情页
/// （PlaylistDetailView，isRank: true，行首显示排名数字）。
struct RankBoard: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var coverURL: URL?
    /// 榜单曲数（上游给了才有；没有时为 0，不编）。
    var trackCount: Int

    init(id: String, name: String, coverURL: URL? = nil, trackCount: Int = 0) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.trackCount = trackCount
    }
}
