import Foundation

/// 原生版直调共享 Swift 服务的薄类型化封装（P1 填实）。
///
/// 方向：SwiftUI → NativeBridge → LiziRouter.handle（进程内合成 HttpRequest，
/// 直接调各平台 Service 的 `handle`；**绝不走 HTTP 回环、不走 LocalHttpServer、
/// 不走 WebView**）。共享服务文件本身一行没改：`handle` 是各服务的公开入口，
/// 内部 `search/songUrl/lyric` 多为 private，这里只调入口、不动逻辑。
///
/// 约束：
/// - 搜索只用各平台自己的搜索接口，绝不用 LX 搜索（/api/lx/search 在 Router
///   里显式 404，原生层也守住：lx 只出现在取链）。
/// - 不编假数据：没有官方接口的平台（见各方法的注释）返回空态。
/// - Apple Music 只有 30 秒试听（公开 API）；整首要 MusicKit + 开发者 token，不编。
enum NativeBridge {
    /// 进程内路由器（单例；各平台 Service 的状态——会话、Cookie、LX 注册表——都挂在这里）。
    static let router = LiziRouter()

    /// LX 取链硬超时（第 15 轮：LX 脚本 Promise 可能永不 settle；25 秒不回就当失败）。
    static let lxTimeout: TimeInterval = 25
    /// 会员态查询超时（player.js MEMBER_TIMEOUT_MS = 2000；超时按「没会员」走 LX，
    /// LX 失败还会回落官方，不会把歌播死）。
    static let membershipTimeout: TimeInterval = 2
    /// 搜索上游请求失败时回给 UI 的文案（P1 集成补的轻量错误通道：call 回 nil
    /// = 请求本身没通，不是「搜不到」；上游正常回空列表不走这里）。
    static let searchErrorText = "接口请求失败，请检查网络后重试"
    /// 会员态缓存（player.js：每家 5 分钟）。
    static let membershipTTL: TimeInterval = 300

    private static var membershipCache: [String: (at: Date, member: Bool)] = [:]
    private static let membershipLock = NSLock()

    // MARK: - 取链结果

    /// 一次取链的结果（`url` 为空 = 这一档拿不到地址；调用方按编排继续往下一档）。
    struct SongURLResult {
        var url: URL?
        /// 上游实际回的档位（显示音质 = 这个，绝不显示请求的档位）。
        var actualQuality: AudioQuality?
        /// 是否试听片段（官方只给了 freeTrialInfo / preview）。
        var isTrial: Bool
        /// 是否 30 秒试听（Apple Music 公开 API 只出这个）。
        var isPreview: Bool
        /// 失败原因（vip / unavailable / login / region / drm / network；成功时为空）。
        var reason: String
        /// 这条地址从哪来（platform / cloud / lx / demo / local）。
        var via: String
        /// 实际码率 bps（上游给了才有）。
        var bitrate: Int
        /// 试听片段的起始毫秒（汽水等平台有）。
        var clipStartMs: Int

        init(url: URL? = nil, actualQuality: AudioQuality? = nil, isTrial: Bool = false,
             isPreview: Bool = false, reason: String = "", via: String = "",
             bitrate: Int = 0, clipStartMs: Int = 0) {
            self.url = url
            self.actualQuality = actualQuality
            self.isTrial = isTrial
            self.isPreview = isPreview
            self.reason = reason
            self.via = via
            self.bitrate = bitrate
            self.clipStartMs = clipStartMs
        }
    }

    // MARK: - 进程内请求

    /// 合成一个 HttpRequest，进程内直调 Router（不经过任何 socket）。
    static func call(path: String, query: [String: String] = [:],
                     method: String = "GET") async -> [String: Any]? {
        let req = HttpRequest(method: method, path: path, query: query,
                              headers: [:], body: Data())
        let resp = await router.handle(req)
        guard (200...299).contains(resp.status),
              let obj = try? JSONSerialization.jsonObject(with: resp.body),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    /// 带 JSON body 的调用（r23a 登录底座；现有无 body 的 `call` 一行没动）。
    ///
    /// 用途：酷我 Cookie 登录（`POST /api/kuwo/login/cookie`，`{ cookie }`）、
    /// Apple Music token 粘贴（`POST /api/applemusic/login/token`，
    /// `{ token, userToken }`）、QQ 网页登录导入（`POST /api/qq/login/web`，
    /// `{ cookie }`）。`body` 序列化进 `HttpRequest.body`；服务端
    /// `HttpRequest.params` 是 query + JSON body 合并、body 优先
    /// （`HttpServer.swift`），与壳版 `public/api.js postSoft` 同款。
    /// body 序列化失败时直接回 nil，不发一个空 body 的 POST 去误导后端。
    static func call(path: String, query: [String: String] = [:],
                     method: String = "GET", body: [String: Any]) async -> [String: Any]? {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        let req = HttpRequest(method: method, path: path, query: query,
                              headers: ["Content-Type": "application/json"], body: bodyData)
        let resp = await router.handle(req)
        guard (200...299).contains(resp.status),
              let obj = try? JSONSerialization.jsonObject(with: resp.body),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    /// 带硬超时的异步调用（超时抛错，调用方按失败处理；LX 取链专用）。
    /// TimeoutError 不能嵌在泛型函数里（Swift 禁止），放枚举作用域。
    private struct TimeoutError: Error {}
    static func withTimeout<T>(seconds: TimeInterval,
                               _ op: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            guard let first = try await group.next() else { throw TimeoutError() }
            group.cancelAll()
            return first
        }
    }

    // MARK: - 搜索（只用各平台自己的接口，绝不用 LX）

    /// 按平台搜歌。`platform` 为 netease/qq/qishui/bodian/kuwo/applemusic；
    /// 不支持的平台返回空 SearchResult（不编假数据）。
    static func search(platform: String, query: String,
                       limit: Int = 20, offset: Int = 0) async -> SearchResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return SearchResult() }
        let page = offset / max(1, limit) + 1
        let base: [String: String] = ["s": q, "q": q, "keyword": q, "keywords": q,
                                      "limit": "\(limit)", "offset": "\(offset)",
                                      "page": "\(page)", "type": "song"]
        switch platform {
        case "netease":
            guard let d = await call(path: "/api/search", query: base) else {
                return SearchResult(errors: ["netease": Self.searchErrorText])
            }
            guard let rows = d["tracks"] as? [[String: Any]] else { return SearchResult() }
            let tracks = rows.compactMap { Track.from(dict: $0, platform: "netease") }
            let total = (d["songCount"] as? NSNumber)?.intValue ?? tracks.count
            return SearchResult(tracks: tracks, hasMore: offset + tracks.count < total,
                                totalCount: total)
        case "qq", "kuwo", "qishui", "bodian", "applemusic", "kugou":
            guard let d = await call(path: "/api/\(platform)/search", query: base) else {
                return SearchResult(errors: [platform: Self.searchErrorText])
            }
            guard let rows = d["tracks"] as? [[String: Any]] else { return SearchResult() }
            let tracks = rows.compactMap { Track.from(dict: $0, platform: platform) }
            let total = (d["songCount"] as? NSNumber)?.intValue ?? tracks.count
            let more = (d["more"] as? NSNumber)?.boolValue ?? (offset + tracks.count < total)
            return SearchResult(tracks: tracks, hasMore: more, totalCount: total)
        default:
            return SearchResult()
        }
    }

    /// P0 签名的兼容包装（keyword/source → platform/query）。
    static func search(keyword: String, source: String) async -> SearchResult {
        await search(platform: source, query: keyword)
    }

// MARK: - 取链：平台官方

/// 调各平台 song/url；返回实际档位（`actualQuality`），拿不到返回 url 为空的结果。
/// 不走 LX、不走云盘（编排在 PlaybackStore）。
static func songURL(track: Track, quality: AudioQuality) async -> SongURLResult {
let platform = track.platform
let key = track.platformKey
let param = quality.requestParam(platform: platform)
switch platform {
case "netease":
// /api/song/url：ids 是 JSON 数组字符串，level 原样透传。
guard let id = Int(key) else { return SongURLResult(reason: "unavailable", via: "platform")}
let d = await call(path: "/api/song/url",
query: ["ids": "[\(id)]", "level": param])
guard let items = d?["data"] as? [[String: Any]], let item = items.first else {
return SongURLResult(reason: "unavailable", via: "platform")
}
let urlString = (item["url"] as? String) ?? ""
let isTrial = item["freeTrialInfo"] != nil && !(item["freeTrialInfo"] is NSNull)
let br = (item["br"] as? NSNumber)?.intValue ?? 0
let served = (item["level"] as? String) ?? ""
if urlString.isEmpty {
let code = (item["code"] as? NSNumber)?.intValue ?? 0
return SongURLResult(reason: code == -110 ? "vip" : "unavailable", via: "platform")
}
return SongURLResult(url: Upstream.url(from: urlString).map { Upstream.upgradedAudioURL($0) },
actualQuality: AudioQuality.canon(platform: "netease", served: served, bitrate: br),
isTrial: isTrial, reason: "", via: "platform", bitrate: br)
case "qq":
let d = await call(path: "/api/qq/song/url",
query: ["mid": key, "quality": param])
return songURLFromSidecar(d, platform: "qq", quality: quality)
case "kuwo":
let d = await call(path: "/api/kuwo/song/url",
query: ["id": key, "quality": param])
return songURLFromSidecar(d, platform: "kuwo", quality: quality)
case "qishui":
let d = await call(path: "/api/qishui/song/url",
query: ["id": key, "quality": param])
return songURLFromSidecar(d, platform: "qishui", quality: quality)
case "bodian":
let d = await call(path: "/api/bodian/song/url",
query: ["id": key, "quality": param])
return songURLFromSidecar(d, platform: "bodian", quality: quality)
case "applemusic":
// 公开 API 只有 30 秒试听；整首要原生 MusicKit + 开发者 token（本轮不做）。
let d = await call(path: "/api/applemusic/song/url", query: ["id": key])
var r = songURLFromSidecar(d, platform: "applemusic", quality: quality)
r.isPreview = true
return r
case "kugou":
// Folia 取链：hash（platformKey 即大写 hash）+ albumId / albumAudioId
//（有专辑 id 时服务端先走带 album 的 song_url，再走 hash-only）。
let d = await call(path: "/api/kugou/song/url",
query: ["hash": key, "albumId": track.albumId,
"albumAudioId": "\(track.albumAudioId)", "quality": param])
return songURLFromSidecar(d, platform: "kugou", quality: quality)
case "local":
return SongURLResult(url: nil, reason: "local", via: "local")
default:
return SongURLResult(reason: "unavailable", via: "platform")
}
}

/// 边车 song/url 的通用解析（qq/kuwo/qishui/bodian/applemusic/kugou 同形：
/// { url, preview, quality, reason}）。
/// 第 22 轮第 5 件：回的地址先升 https（Upstream.upgradedAudioURL，与
/// 探活验的地址一致——探活验升级后、播放器播 http 原址等于验一套播一套；
/// 酷我平台腿也在此升级（同款修法）。
/// 升级表只含实测支持 https 的域（.music.126.net/.qq.com/
/// .kuwo.cn/.kugou.com/.kglink.com）；汽水 CDN 域（.365yg.com 等）未实测，不进表、
/// 不编——汽水地址原样走直链/代理，行为与修前一致。
private static func songURLFromSidecar(_ d: [String: Any]?, platform: String,
quality: AudioQuality) -> SongURLResult {
guard let d else { return SongURLResult(reason: "network", via: "platform")}
let urlString = (d["url"] as? String) ?? ""
let served = (d["quality"] as? String) ?? ""
let preview = (d["preview"] as? NSNumber)?.boolValue ?? false
let clipStartMs = (d["clipStartMs"] as? NSNumber)?.intValue ?? 0
if urlString.isEmpty {
let reason = (d["reason"] as? String) ?? (d["error"] as? String) ?? "unavailable"
return SongURLResult(reason: reason.isEmpty ? "unavailable" : reason, via: "platform")
}
return SongURLResult(url: Upstream.url(from: urlString).map { Upstream.upgradedAudioURL($0) },
actualQuality: AudioQuality.canon(platform: platform, served: served),
isTrial: preview, isPreview: preview,
reason: "", via: "platform", clipStartMs: clipStartMs)
}

// MARK: - 取链：个人云盘（只接网易「我的云盘」）

/// 网易个人云盘取链（照抄 player.js fetchCloudUrl：按 id 精确匹配，
/// 再按「歌名 + 歌手」归一化匹配；列表按会话缓存 10 分钟，最多 5 页）。
/// QQ / 酷我没有同等的个人云盘取链口；酷狗云盘取链在服务端
/// /api/kugou/user/cloud_url（songURL 的 cloud=1 走它），原生编排的
/// 云盘腿只接网易，其它平台直接返回 nil。
static func cloudSongURL(track: Track) async -> SongURLResult? {
guard track.platform == "netease" else { return nil}
guard SessionStore.shared.hasMusicU else { return nil}
let now = Date()
if now.timeIntervalSince(cloudCacheAt) > 600 || !cloudCacheLoggedIn {
var songs: [[String: Any]] = []
var loggedIn = false
if SessionStore.shared.hasMusicU {
loggedIn = true
for page in 0..<5 {
guard let d = await call(path: "/api/user/cloud",
query: ["limit": "200", "offset": "\(page * 200)"]),
let rows = cloudRows(d) else { break}
songs.append(contentsOf: rows)
if rows.count < 200 { break}
}
}
cloudCache = songs
cloudCacheAt = now
cloudCacheLoggedIn = loggedIn
}
guard cloudCacheLoggedIn,!cloudCache.isEmpty else { return nil}
guard let hit = findCloudSong(track, in: cloudCache) else { return nil}
let cloudId = cloudSongId(hit)
guard !cloudId.isEmpty else { return nil}
var r = await songURL(track: Track(id: cloudId, platform: "netease",
platformKey: cloudId), quality:.lossless)
if r.url != nil { r.via = "cloud"}
return r.url == nil ? nil : r
}

private static var cloudCache: [[String: Any]] = []
private static var cloudCacheAt: Date = .distantPast
private static var cloudCacheLoggedIn: Bool = false

/// /api/user/cloud 的行解析（normalize 的形状：data 数组或 songs 数组，字段 songId/songName/artist/album）。
private static func cloudRows(_ d: [String: Any]) -> [[String: Any]]? {
if let rows = d["songs"] as? [[String: Any]] { return rows}
if let data = d["data"] as? [[String: Any]] { return data}
if let data = d["data"] as? [String: Any], let rows = data["songs"] as? [[String: Any]] { return rows}
return nil
}

private static func cloudSongId(_ c: [String: Any]) -> String {
if let s = c["songId"] as? String { return s}
if let n = c["songId"] as? NSNumber { return n.stringValue}
if let n = c["id"] as? NSNumber { return n.stringValue}
return (c["id"] as? String) ?? ""
}

private static func normCloudKey(_ s: String) -> String {
s.lowercased().components(separatedBy: CharacterSet(charactersIn: " \n-_·•()（）[]{}'\"“”‘’.,，。、!！?？:：;；|/\\")).joined()
}

private static func findCloudSong(_ track: Track, in songs: [[String: Any]]) -> [String: Any]? {
if let byId = songs.first(where: { cloudSongId($0) == track.id}) { return byId}
let nameKey = normCloudKey(track.title)
guard !nameKey.isEmpty else { return nil}
let artistKey = normCloudKey(track.artist.components(separatedBy: "/").first ?? "")
return songs.first { c in
let cname = normCloudKey((c["songName"] as? String) ?? (c["name"] as? String) ?? "")
guard cname == nameKey else { return false}
guard !artistKey.isEmpty else { return true}
let ca = normCloudKey((c["artist"] as? String) ?? (c["artists"] as? String) ?? "")
return ca.isEmpty || ca.contains(artistKey) || artistKey.contains(ca)
}
}

// MARK: - 取链：LX（只做取链 fallback，绝不做搜索）

/// LX 取链（/api/lx/song/url，25 秒硬超时；没有 LX 解析的平台返回 nil）。
/// 支持：netease / qq / kuwo / qishui / kugou / bodian（r26 接回波点，
/// bd 映射见 LXResolver.sourceMap——但今天没有任何已注册源声明 bd，
/// 波点 LX 仍走不到真取链，缺的是源不是映射，见 LX.swift）。
/// Apple Music / Spotify 没有 LX 解析：LX 生态的源 id 只有 kw/kg/tx/wy/mg
///（赞助源另扩展了 qs），不存在 Apple Music 的源 id，不编假映射。
static func lxSongURL(track: Track, quality: AudioQuality) async -> SongURLResult? {
guard let lxSource = LXResolver.sourceMap[track.platform],!lxSource.isEmpty else { return nil}
var query: [String: String] = ["source": track.platform,
"quality": quality.requestParam(platform: "lx"),
"name": track.title, "artists": track.artist]
switch track.platform {
case "qq": query["mid"] = track.platformKey
case "kugou":
// 酷狗 LX 兜底：hash 当 id 传（Router 的 kugou 分支认 32 位 hex hash；
// 不是 hash 时 Router 按「歌名 歌手」传，name/artists 已在 query 里）。
query["id"] = track.platformKey
query["hash"] = track.platformKey
default: query["id"] = track.platformKey
}
let d: [String: Any]?
do {
d = try await withTimeout(seconds: lxTimeout) {
await call(path: "/api/lx/song/url", query: query)
}
} catch {
// 第 21 轮第 1 件：取消 ≠ 超时——旧代码两条路都记同一句
// "lx song/url timeout"，重按取消的旧调用也被算成超时，下次诊断分不清
// “25 秒真超时”还是“用户 5 秒重按取消”。分开记。
if error is CancellationError {
DiagLog.shared.recordPlaybackStep("lx song/url cancelled source=\(track.platform) id=\(track.id)")
} else {
DiagLog.shared.recordPlaybackStep("lx song/url timeout source=\(track.platform) id=\(track.id)")
}
return nil
}
guard let d, (d["code"] as? NSNumber)?.intValue == 0,
let urlString = d["url"] as? String,!urlString.isEmpty else {
// 第 21 轮第 1 件：LX 回来了但没给地址（code != 0 / 空地址）原来是静默
// nil，调用方继续往平台走，诊断里看不出 LX 到底回没回。现在记一笔，
// 和“根本没回来”（上面两句）分开。
DiagLog.shared.recordPlaybackStep("lx song/url empty source=\(track.platform) id=\(track.id)")
return nil
}
let served = (d["quality"] as? String) ?? ""
// 第 22 轮第 3 件：LX 回来的那一刻落盘——Router 的 "lx song/url start"
// 只证明进了取链，这一笔证明桥拿到了地址；start 与 return 之间断了，
// 就是卡在 /api/lx/song/url 的服务端一侧（脚本/探活），不是桥没等。
DiagLog.shared.recordPlaybackStep("lx song/url return source=\(track.platform) id=\(track.id) via=lx")
// 第 22 轮第 5 件：LX 地址先升 https 再交给播放器（与 songURLFromSidecar
// 同款修法）：探活验的是升级后的地址，播 http 原址等于验一套播一套；
// 酷我 发如雪那条 http://car-er.kuwo.cn 直播 "Cannot Open"、代理拉又被
// ATS -1022 拦，根因就是播/探用的不是同一条地址。升级表见
// Upstream.audioHTTPSSuffixes（.kuwo.cn 在表里，VM 实测 https 通）。
return SongURLResult(url: Upstream.url(from: urlString).map { Upstream.upgradedAudioURL($0) },
actualQuality: AudioQuality.canon(platform: "lx", served: served),
reason: "", via: "lx")
}

// MARK: - 会员态（决定 LX 排第几）

/// 该平台是否已登录且有会员（player.js fetchMembership + membershipFromStatus；
/// 5 分钟缓存，2 秒超时按「没会员」处理）。Apple Music / 本地无会员概念，返回 false。
static func isMember(platform: String) async -> Bool {
membershipLock.lock()
if let hit = membershipCache[platform], Date().timeIntervalSince(hit.at) < membershipTTL {
membershipLock.unlock()
return hit.member
}
membershipLock.unlock()
let member: Bool
do {
member = try await withTimeout(seconds: membershipTimeout) {
await memberStatus(platform: platform)
}
} catch {
member = false
}
membershipLock.lock()
membershipCache[platform] = (at: Date(), member: member)
membershipLock.unlock()
return member
}

private static func memberStatus(platform: String) async -> Bool {
let d: [String: Any]?
switch platform {
case "netease":
d = await call(path: "/api/session")
guard let d, (d["loggedIn"] as? NSNumber)?.boolValue == true else { return false}
if let profile = d["profile"] as? [String: Any] {
if let vipType = profile["vipType"] as? NSNumber, vipType.intValue > 0 { return true}
if (profile["vipType"] as? NSNumber)?.boolValue == true { return true}
}
return (d["vip"] as? NSNumber)?.boolValue == true
case "qq", "kuwo", "qishui", "bodian", "kugou":
d = await call(path: "/api/\(platform)/status")
guard let d, (d["loggedIn"] as? NSNumber)?.boolValue == true else { return false}
return (d["vip"] as? NSNumber)?.boolValue == true
default:
return false
}
}

    // MARK: - 歌词（官方 → LRCLIB 兜底）

    /// 取一首歌的歌词（完整结果，含 format）。官方接口（各平台 lyric 已内置
    /// LRCLIB 兜底的照抄壳版；官方与兜底都空时这里再直调一次 Lrclib.fetch）；
    /// YRC 优先。无词返回空 ParsedLyrics（调用方显示歌名，绝不用 ♪ 作假歌词）。
    static func lyrics(for track: Track) async -> ParsedLyrics {
        let platform = track.platform
        let key = track.platformKey
        let meta: [String: String] = ["s": track.title, "name": track.title,
                                      "artist": track.artist,
                                      "album": track.album,
                                      "duration": "\(track.durationMs / 1000)"]
        var d: [String: Any]?
        switch platform {
        case "netease":
            d = await call(path: "/api/lyric", query: ["id": key])
        case "qq":
            d = await call(path: "/api/qq/lyric", query: ["mid": key])
        case "kuwo":
            d = await call(path: "/api/kuwo/lyric",
                           query: ["id": key].merging(meta) { a, _ in a })
        case "qishui":
            d = await call(path: "/api/qishui/lyric", query: ["id": key])
        case "bodian":
            d = await call(path: "/api/bodian/lyric", query: ["id": key])
        case "kugou":
            // 酷狗歌词：hash + 歌名/歌手/专辑/时长（秒），服务端先走
            // Folia 两步（search_lyric → download），再走 LRCLIB 兜底。
            d = await call(path: "/api/kugou/lyric",
                           query: ["hash": key].merging(meta) { a, _ in a })
        case "applemusic":
            d = await call(path: "/api/applemusic/lyric",
                           query: meta.merging(["id": key]) { a, _ in a })
        default:
            d = nil
        }
        let lyric = (d?["lyric"] as? String) ?? ""
        let yrc = (d?["yrc"] as? String) ?? ""
        let tlyric = (d?["tlyric"] as? String) ?? ""
        let ytlrc = (d?["ytlrc"] as? String) ?? ""
        var parsed = LyricsParser.parse(lyric: lyric, yrc: yrc, tlyric: tlyric, ytlrc: ytlrc)
        if parsed.lines.isEmpty,
           let fb = await Lrclib.fetch(artist: track.artist, track: track.title,
                                       album: track.album, duration: track.durationMs / 1000) {
            parsed = LyricsParser.parse(lyric: fb.lyric, yrc: fb.yrc)
        }
        return parsed
    }

    /// 歌词行（P0 签名的兼容包装；完整结果用 lyrics(for:)）。
    static func lyricLines(for track: Track) async -> [LyricLine] {
        (await lyrics(for: track)).lines
    }

    // MARK: - 每日推荐 / 歌单 / 歌手 / 专辑

    /// 每日推荐（各平台自己的推荐接口；壳版 `marqSource` 同款映射，
    ///   见 `public/app.js`；r24 第 1 件逐平台核对后重写）。
    /// - netease: /api/recommend/songs（需登录；未登录 / 取空时退到
    ///   /api/personalized 推荐新歌，壳版 paintDaily 同款兜底——匿名
    ///   也有 30 首可看，不是空态）。
    /// - qq: /api/qq/user/daily-songs（需登录）；未登录（401 空态）
    ///   或取空时退到 /api/qq/recommend/radar（匿名雷达推荐，
    ///   壳版 marqSource 同款）。旧写法调 /api/qq/recommend/new-songs
    ///   是「新歌首发」不是每日推荐，内容错位。
    /// - qishui: /api/qishui/feed（推荐流，匿名可用 20 首；旧写法
    ///   直接回 []，错——壳版 marqSource 就是走 feed）。
    /// - bodian: /api/bodian/ai/playlist?index=0（潮趣日推，匿名可用；
    ///   旧写法直接回 []，错——壳版 bodianDaily 就是这条）。
    /// - kuwo: /api/kuwo/daily；kugou: /api/kugou/everyday/recommend
    ///   （Folia everyday_recommend）；applemusic: /api/applemusic/daily
    ///   （公开排行榜 RSS）。三家形状都是 { tracks }，已核对，不动。
    static func dailyRecommend(platform: String) async -> [DailyTrack] {
        switch platform {
        case "netease":
            if let tracks = await dailyTracks(path: "/api/recommend/songs", platform: platform),
               !tracks.isEmpty { return tracks }
            return await dailyTracks(path: "/api/personalized", platform: platform) ?? []
        case "qq":
            if let tracks = await dailyTracks(path: "/api/qq/user/daily-songs", platform: platform),
               !tracks.isEmpty { return tracks }
            return await dailyTracks(path: "/api/qq/recommend/radar",
                                     query: ["page": "1"], platform: platform) ?? []
        case "qishui":
            return await dailyTracks(path: "/api/qishui/feed",
                                     query: ["count": "20"], platform: platform) ?? []
        case "bodian":
            return await dailyTracks(path: "/api/bodian/ai/playlist",
                                     query: ["index": "0"], platform: platform) ?? []
        case "kuwo":
            return await dailyTracks(path: "/api/kuwo/daily", platform: platform) ?? []
        case "kugou":
            return await dailyTracks(path: "/api/kugou/everyday/recommend", platform: platform) ?? []
        case "applemusic":
            return await dailyTracks(path: "/api/applemusic/daily", platform: platform) ?? []
        default:
            return []
        }
    }

    /// 每日推荐一行请求的归一化读数（{ tracks } / { data } / { songs }；
    /// 请求本身没通（call 回 nil）或上游回空都给 []，调用方按空走下一条兜底）。
    private static func dailyTracks(path: String, query: [String: String] = [:],
                                    platform: String) async -> [DailyTrack]? {
        guard let d = await call(path: path, query: query) else { return nil }
        let rows: [[String: Any]] = (d["tracks"] as? [[String: Any]])
            ?? (d["data"] as? [[String: Any]])
            ?? (d["songs"] as? [[String: Any]]) ?? []
        return rows.compactMap { Track.from(dict: $0, platform: platform) }
            .map { DailyTrack(track: $0) }
    }

    /// 歌单详情（含曲目）。r25-B2：按平台分三档（逐家核对服务端路由后定，
    ///   见下表；不编假数据，没有 detail 端点的平台保持 tracks-only 诚实空态）。
    /// - detail 本身回全量（名/封面/曲数/曲目），一次就够：
    ///   netease /api/playlist/detail（normalize 回 { playlist, tracks }）、
    ///   qq /api/qq/playlist/detail（回 { name, cover, tracks, trackCount }）。
    /// - detail 只回元信息（名/封面/曲数，无曲目）+ tracks 只回曲目，两步合并：
    ///   bodian /api/bodian/playlist/detail（{ playlist: bodianPlaylist }）
    ///     + /api/bodian/playlist/tracks（{ tracks, more }）；
    ///   kugou /api/kugou/playlist/detail（{ playlist: kugouCollection }）
    ///     + /api/kugou/playlist/tracks（{ tracks, songCount }）；
    ///   qishui /api/qishui/playlist/detail（{ playlist: qishuiPlaylist }，
    ///     注意它本身也是 playlistPage(limit:1) 的 collection，无曲目）
    ///     + /api/qishui/playlist/tracks（{ tracks, more }）。
    ///   两步里任何一步失败都不编：detail 失败则名/封面留空（通用名 + 占位封面），
    ///   tracks 失败则曲目留空（详情页照常显示已拿到的头部）。
    /// - 无 detail 端点，tracks-only（标题/封面无上游数据时详情页显示通用名 +
    ///   占位封面，曲目数显示已加载数）：
    ///   kuwo 非榜单 /api/kuwo/playlist/tracks（本身已回 name/cover/creator/total，
    ///     无需另调 detail——服务端路由里没有 playlist/detail）；
    ///   kuwo 榜单（isRank=true）/api/kuwo/rank/tracks（只回 { id, total, tracks }，
    ///     无榜单名/封面端点）；applemusic /api/applemusic/playlist/tracks
    ///     （回 { name, cover, tracks }：服务端 playlistTracks 已把 iTunes
    ///     lookup results[0] 的歌单名/封面透出来，见 AppleMusic.swift；
    ///     playlistFrom 认 name/cover 两个键，第二阶段直接显示真名真封面，
    ///     链路见 playlistMeta 的注释与 PlaylistDetailViewModel.load）。
    /// - `meta`：ViewModel 第一阶段已拿到的元信息（playlistMeta 的结果），
    ///   有就直接复用，不再重复调一次 detail；没传时内部自己调。
    static func playlistDetail(platform: String, id: String, isRank: Bool = false,
                               meta: Playlist? = nil) async -> Playlist {
        switch platform {
        case "netease", "qq":
            // detail 端点本身回全量，一次就够（meta 已带曲目时直接用它）。
            if let meta, !meta.tracks.isEmpty { return meta }
            let path = platform == "netease" ? "/api/playlist/detail" : "/api/qq/playlist/detail"
            guard let d = await call(path: path, query: ["id": id]) else {
                return meta ?? Playlist(id: id, source: platform)
            }
            return playlistFrom(dict: d, platform: platform, id: id)
        case "qishui", "bodian", "kugou":
            let detailPath: String
            let tracksPath: String
            switch platform {
            case "qishui":
                detailPath = "/api/qishui/playlist/detail"
                tracksPath = "/api/qishui/playlist/tracks"
            case "bodian":
                detailPath = "/api/bodian/playlist/detail"
                tracksPath = "/api/bodian/playlist/tracks"
            default: // kugou
                detailPath = "/api/kugou/playlist/detail"
                tracksPath = "/api/kugou/playlist/tracks"
            }
            var pl = Playlist(id: id, source: platform)
            if let meta, !meta.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pl = meta
            } else if let d = await call(path: detailPath, query: ["id": id]) {
                pl = playlistFrom(dict: d, platform: platform, id: id)
            }
            if let t = await call(path: tracksPath, query: ["id": id, "limit": "50"]) {
                let tp = playlistFrom(dict: t, platform: platform, id: id)
                pl.tracks = tp.tracks
                if pl.trackCount == 0 { pl.trackCount = tp.trackCount }
                // tracks 回包若带了名/封面而 detail 没给，补上（只取上游给的，不编）。
                if pl.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pl.title = tp.title
                }
                if pl.coverURL == nil { pl.coverURL = tp.coverURL }
            }
            return pl
        case "kuwo":
            let path: String
            var query: [String: String] = ["id": id]
            if isRank {
                path = "/api/kuwo/rank/tracks"
                query["limit"] = "50"
            } else {
                // 非榜单 tracks 接口本身已回 name/cover/creator/total，无需 detail。
                path = "/api/kuwo/playlist/tracks"
            }
            guard let d = await call(path: path, query: query) else {
                return Playlist(id: id, source: platform)
            }
            return playlistFrom(dict: d, platform: platform, id: id)
        case "applemusic":
            guard let d = await call(path: "/api/applemusic/playlist/tracks",
                                     query: ["id": id]) else {
                return Playlist(id: id, source: platform)
            }
            return playlistFrom(dict: d, platform: platform, id: id)
        default:
            return Playlist(id: id, source: platform)
        }
    }

    /// 歌单元信息（名/封面/曲数/创建者/简介），不含曲目（详情页第一阶段先显示头部用）。
    /// - 有 detail 端点的平台走 detail 端点：netease / qq（它们的 detail 回包
    ///   本身含曲目，返回的 Playlist 也带 tracks，调用方见 tracks 非空即知已全量，
    ///   不再调第二阶段）；qishui / bodian / kugou（detail 只回元信息）。
    /// - 无 detail 端点的平台（kuwo / applemusic）首阶段仍回空 Playlist，不编：
    ///   kuwo 非榜单的名/封面在 tracks 回包里，第二阶段一起拿；Apple Music
    ///   的名/封面也在 tracks 回包里（playlistTracks 透 { name, cover }），
    ///   第二阶段 playlistDetail → playlistFrom 直接显示到详情页头部；
    ///   只有 kuwo 榜单没有名/封面来源，保持 tracks-only 诚实空态。
    static func playlistMeta(platform: String, id: String, isRank: Bool = false) async -> Playlist {
        switch platform {
        case "netease":
            guard let d = await call(path: "/api/playlist/detail", query: ["id": id]) else {
                return Playlist(id: id, source: platform)
            }
            return playlistFrom(dict: d, platform: platform, id: id)
        case "qq":
            guard let d = await call(path: "/api/qq/playlist/detail", query: ["id": id]) else {
                return Playlist(id: id, source: platform)
            }
            return playlistFrom(dict: d, platform: platform, id: id)
        case "qishui":
            guard let d = await call(path: "/api/qishui/playlist/detail", query: ["id": id]) else {
                return Playlist(id: id, source: platform)
            }
            return playlistFrom(dict: d, platform: platform, id: id)
        case "bodian":
            guard let d = await call(path: "/api/bodian/playlist/detail", query: ["id": id]) else {
                return Playlist(id: id, source: platform)
            }
            return playlistFrom(dict: d, platform: platform, id: id)
        case "kugou":
            guard let d = await call(path: "/api/kugou/playlist/detail", query: ["id": id]) else {
                return Playlist(id: id, source: platform)
            }
            return playlistFrom(dict: d, platform: platform, id: id)
        default:
            // kuwo / applemusic：服务端路由里没有 playlist/detail，不编元信息。
            return Playlist(id: id, source: platform)
        }
    }

    /// 歌手详情（热门曲目）。只有网易有官方接口；其它平台没有 → 空 Artist，不编。
    static func artistDetail(platform: String, id: String) async -> Artist {
        guard platform == "netease" else { return Artist(id: id, source: platform) }
        guard let d = await call(path: "/api/artist/songs", query: ["id": id, "limit": "10"]) else {
            return Artist(id: id, source: platform)
        }
        let rows: [[String: Any]] = (d["songs"] as? [[String: Any]])
            ?? (d["tracks"] as? [[String: Any]]) ?? []
        var artist = Artist(id: id, source: platform)
        if let detail = await call(path: "/api/artist/\(id)"),
           let a = detail["artist"] as? [String: Any] {
            artist.name = (a["name"] as? String) ?? ""
            let cover = (a["cover"] as? String) ?? (a["avatar"] as? String) ?? (a["picUrl"] as? String) ?? ""
            artist.coverURL = URL(string: cover)
        }
        artist.hotTracks = rows.compactMap { Track.from(dict: $0, platform: platform) }
        return artist
    }

    /// 专辑详情（含曲目）。网易 / 酷我有官方接口；其它平台没有 → 空 Album，不编。
    static func albumDetail(platform: String, id: String) async -> Album {
        switch platform {
        case "netease":
            guard let d = await call(path: "/api/album/\(id)") else {
                return Album(id: id, source: platform)
            }
            var album = Album(id: id, source: platform)
            if let a = d["album"] as? [String: Any] {
                album.title = (a["name"] as? String) ?? ""
                album.artist = ((a["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: " / ")) ?? ""
                let cover = (a["cover"] as? String) ?? (a["picUrl"] as? String) ?? (a["blurPicUrl"] as? String) ?? ""
                album.coverURL = URL(string: cover)
            }
            album.tracks = ((d["songs"] as? [[String: Any]]) ?? [])
                .compactMap { Track.from(dict: $0, platform: platform) }
            album.trackCount = album.tracks.count
            return album
        case "kuwo":
            guard let d = await call(path: "/api/kuwo/album/tracks", query: ["id": id]) else {
                return Album(id: id, source: platform)
            }
            var album = Album(id: id, source: platform)
            album.tracks = ((d["tracks"] as? [[String: Any]]) ?? [])
                .compactMap { Track.from(dict: $0, platform: platform) }
            album.trackCount = album.tracks.count
            return album
        default:
            return Album(id: id, source: platform)
        }
    }

    // MARK: - 归一化解析（各平台回的 track 字典 → Track）

    /// 各平台归一化后的 track 字典统一形状：id / name / artists（字符串或数组）/
    /// album（字符串或字典）/ cover（或 picUrl/albumpic）/ duration（毫秒）/
    /// fee / mid / hash。解析不到关键字段返回 nil（不编假曲目）。
    static func trackFrom(dict: [String: Any], platform: String) -> Track? {
        Track.from(dict: dict, platform: platform)
    }

    private static func playlistFrom(dict d: [String: Any], platform: String, id: String) -> Playlist {
        // 网易：{ playlist: { name, coverImgUrl, trackCount, description, creator, tracks } }
        // 边车：{ name/cover/tracks/trackCount } 或 { playlist: {...} }（汽水）。
        let p: [String: Any] = (d["playlist"] as? [String: Any]) ?? d
        var pl = Playlist(id: id, source: platform)
        pl.title = (p["name"] as? String) ?? (p["title"] as? String) ?? ""
        let cover = (p["coverImgUrl"] as? String) ?? (p["cover"] as? String) ?? (p["picUrl"] as? String) ?? ""
        pl.coverURL = URL(string: cover)
        pl.trackCount = (p["trackCount"] as? NSNumber)?.intValue
            ?? ((p["tracks"] as? [[String: Any]])?.count ?? 0)
        pl.description = (p["description"] as? String) ?? ""
        if let creator = p["creator"] as? [String: Any] {
            pl.creator = (creator["nickname"] as? String) ?? ""
        } else {
            pl.creator = (p["creator"] as? String) ?? ""
        }
        pl.tracks = ((p["tracks"] as? [[String: Any]]) ?? (d["tracks"] as? [[String: Any]]) ?? [])
            .compactMap { Track.from(dict: $0, platform: platform) }
        if pl.trackCount == 0 { pl.trackCount = pl.tracks.count }
        return pl
    }
}

// MARK: - Track 归一化

extension Track {
    /// 各平台归一化 track 字典 → Track（见 NativeBridge.trackFrom 的字段说明）。
    static func from(dict: [String: Any], platform: String) -> Track? {
        let idString: String
        if let s = dict["id"] as? String, !s.isEmpty { idString = s }
        else if let n = dict["id"] as? NSNumber { idString = n.stringValue }
        else if let mid = dict["mid"] as? String, !mid.isEmpty { idString = mid }
        else { return nil }
        let title = (dict["name"] as? String) ?? (dict["title"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        let artist: String
        if let a = dict["artists"] as? String { artist = a }
        else if let arr = dict["artists"] as? [String] {
            // 汽水 / 波点曲目行就是这个形状（P2-B 发现：旧代码不认会掉成「未知歌手」）。
            artist = arr.joined(separator: " / ")
        }
        else if let arr = dict["artists"] as? [[String: Any]] {
            artist = arr.compactMap { $0["name"] as? String }.joined(separator: " / ")
        } else if let arr = dict["ar"] as? [[String: Any]] {
            artist = arr.compactMap { $0["name"] as? String }.joined(separator: " / ")
        } else { artist = "" }
        let album: String
        var albumId = ""
        if let a = dict["album"] as? String { album = a }
        else if let a = dict["album"] as? [String: Any] {
            album = (a["name"] as? String) ?? (a["title"] as? String) ?? ""
            if let n = a["id"] as? NSNumber { albumId = n.stringValue }
            else if let s = a["id"] as? String { albumId = s }
        } else if let a = dict["al"] as? [String: Any] {
            album = (a["name"] as? String) ?? ""
            if let n = a["id"] as? NSNumber { albumId = n.stringValue }
        } else { album = "" }
        var coverString = (dict["cover"] as? String) ?? ""
        if coverString.isEmpty { coverString = (dict["picUrl"] as? String) ?? "" }
        if coverString.isEmpty { coverString = (dict["albumpic"] as? String) ?? "" }
        if coverString.isEmpty, let a = dict["album"] as? [String: Any] {
            coverString = (a["picUrl"] as? String) ?? ""
        }
        if coverString.isEmpty, let a = dict["al"] as? [String: Any] {
            coverString = (a["picUrl"] as? String) ?? ""
        }
        var durationMs = 0
        if let n = dict["duration"] as? NSNumber { durationMs = n.intValue }
        else if let n = dict["dt"] as? NSNumber { durationMs = n.intValue }
        else if let n = dict["interval"] as? NSNumber { durationMs = n.intValue * 1000 }
        else if let n = dict["Duration"] as? NSNumber { durationMs = n.intValue * 1000 }
        let fee = (dict["fee"] as? NSNumber)?.intValue ?? 0
        let platformKey = (dict["mid"] as? String)
            ?? (dict["rid"] as? String) ?? (dict["hash"] as? String) ?? idString
        if albumId.isEmpty {
            if let s = dict["albumId"] as? String { albumId = s }
            else if let n = dict["albumIdNum"] as? NSNumber { albumId = n.stringValue }
        }
        let albumAudioId = (dict["albumAudioId"] as? NSNumber)?.intValue ?? 0
        let artistIds: [String]
        if let arr = dict["artistIds"] as? [String] { artistIds = arr }
        else if let arr = dict["artistIds"] as? [NSNumber] { artistIds = arr.map { $0.stringValue } }
        else { artistIds = [] }
        return Track(id: idString, platform: platform, title: title,
                     artist: artist.isEmpty ? "未知歌手" : artist, album: album,
                     coverURL: URL(string: coverString),
                     durationMs: durationMs, vip: fee != 0,
                     platformKey: platformKey, albumId: albumId,
                     albumAudioId: albumAudioId, artistIds: artistIds)
    }
}
