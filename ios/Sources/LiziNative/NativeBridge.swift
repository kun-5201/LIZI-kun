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
    /// 每日推荐整链硬超时（r28：单腿都有超时，但网易匿名要连调两条
    /// （recommend/songs + personalized，各 15s × 2 次重试）、QQ 登录态
    /// 刷新 + 两条各 25s，最坏单次拉取 60–75s 才落空态；且每次回首页
    /// 都从头拉。整链 25s 不回就当空、UI 走诚实空态，不让 spinner
    /// 无限转。健康链路实测 0.3–5.2s（r28 真机前用 r27 Node 服务对
    /// 真上游测过），25s 是约 5 倍余量。超时只掐断 UI 的等待——
    /// 底下的 URLSession 取数不停（链路里没有取消检查点），它自己
    /// 到腿超时就停，不泄漏。
    static let dailyTimeout: TimeInterval = 25
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
        /// 上游实际回的档位（显示音质 = 这个，绝不显示请求的档位；
        /// r31：canon 的结果再过 AudioQuality.verified，按实际地址的
        /// 实证（QQ 文件名前缀 / 容器 / 码率）校验，宣称高于实证上限
        /// 时往下压、给不出时为 nil，UI 不挂徽章）。
        var actualQuality: AudioQuality?
        /// 是否试听片段（官方只给了 freeTrialInfo / preview）。
        var isTrial: Bool
        /// 是否 30 秒试听（Apple Music 公开 API 只出这个）。
        var isPreview: Bool
        /// 失败原因（vip / unavailable / login / region / drm / network；成功时为空）。
        var reason: String
        /// 这条地址从哪来（platform / cloud / lx / local）。
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
// r31 真实音质：type 是上游回的文件容器（mp3/flac），与 level/br 一起
// 作实证——level 只认上游宣称时，宣称与实际文件不符就挂假徽章
//（要了 dolby、实际只给了 320k mp3 时 level 仍可能报 dolby）。
if urlString.isEmpty {
let code = (item["code"] as? NSNumber)?.intValue ?? 0
return SongURLResult(reason: code == -110 ? "vip" : "unavailable", via: "platform")
}
let streamURL = Upstream.url(from: urlString).map { Upstream.upgradedAudioURL($0) }
let streamType = (item["type"] as? String) ?? ""
return SongURLResult(url: streamURL,
actualQuality: AudioQuality.verified(claimed: AudioQuality.canon(platform: "netease", served: served, bitrate: br), url: streamURL, bitrate: br, format: streamType),
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
/// r31 真实音质：served 只是边车回的宣称档位（汽水/波点上游不给档位时
/// 服务端曾直接拿请求档位顶，见 Qishui/Bodian song/url 的修法），
/// 这里再按实际地址的实证校验一遍（QQ 文件名前缀 / 容器后缀）：
/// 宣称高于实证上限时往下压，宣称与实证都给不出时回 nil（不挂徽章）。
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
let streamURL = Upstream.url(from: urlString).map { Upstream.upgradedAudioURL($0) }
let streamFormat = (d["format"] as? String) ?? ""
return SongURLResult(url: streamURL,
actualQuality: AudioQuality.verified(claimed: AudioQuality.canon(platform: platform, served: served), url: streamURL, format: streamFormat.isEmpty ? nil : streamFormat),
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
///（用户自加的自定义源可扩展 qs），不存在 Apple Music 的源 id，不编假映射。
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
// r31 真实音质（假「杜比全景声」根因）：LX 引擎返回的 tier 是「脚本
// 在这一档调用里成功了」，不是「这条流真是这一档」——脚本要 atmos
// 档时只消返回任意一条能播的地址（常是 320k mp3 / QQ M800 直链），
// 引擎就原样报 atmos，canon 直译成 .dolby，芯片就挂了假杜比。
// 没会员时 LX 先跑（PlaybackStore.resolveURL 的 lxFirst），QQ 匿名
// vkey 对这首歌根本不给 purl、官方腿走不到，所以用户实际听到的就
// 是 LX 这条 mp3，却顶着杜比徽章。这里按实际地址的实证校验：
// QQ 文件名前缀（M800/Q001…）定档，.mp3 上限 320k，
// 不透明地址才保留脚本宣称（残留风险：脚本 tier 是唯一证据时仍
// 可能虚高，见 AudioQuality.verified 的注释——不编更多证据）。
let streamURL = Upstream.url(from: urlString).map { Upstream.upgradedAudioURL($0) }
return SongURLResult(url: streamURL,
actualQuality: AudioQuality.verified(claimed: AudioQuality.canon(platform: "lx", served: served), url: streamURL),
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

    // MARK: - 评论区（r27，只读）

    /// 一条评论（服务端 /api/comments 归一化后的形状，见 CommentsService）。
    struct SongComment: Identifiable, Hashable {
        var id: String { "\(nickname)-\(timeMs)-\(content.prefix(12))" }
        var nickname: String
        var avatarURL: URL?
        var content: String
        /// 评论时间（毫秒 epoch；显示时格式化，见 timeText）。
        var timeMs: Int
        var likedCount: Int

        var timeText: String {
            guard timeMs > 0 else { return "" }
            let date = Date(timeIntervalSince1970: TimeInterval(timeMs) / 1000)
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.string(from: date)
        }
    }

    /// 拉评论（只读；发评论本轮不做）。
    /// - 只有网易云有验证过的公开读接口；其它平台服务端回 code 501 + 老实原因，
    ///   这里原样转成 error，不编假评论。
    /// - 返回 (comments, total, hasMore, error)：error 非空时 comments 为空，
    ///   UI 直接显示 error 文案 + 重试。
    static func comments(platform: String, id: String, key: String,
                         offset: Int = 0, limit: Int = 20) async
    -> (comments: [SongComment], total: Int, hasMore: Bool, error: String?) {
        let d = await call(path: "/api/comments", query: [
            "platform": platform, "id": id, "key": key,
            "offset": "\(offset)", "limit": "\(limit)",
        ])
        guard let d else {
            return ([], 0, false, "评论请求失败，请检查网络后重试")
        }
        let code = (d["code"] as? NSNumber)?.intValue ?? -1
        guard code == 0 else {
            let err = (d["error"] as? String) ?? ""
            return ([], 0, false, err.isEmpty ? "该平台暂无评论接口" : err)
        }
        let total = (d["total"] as? NSNumber)?.intValue ?? 0
        let hasMore = (d["hasMore"] as? NSNumber)?.boolValue ?? false
        let items = (d["comments"] as? [[String: Any]] ?? []).compactMap { c -> SongComment? in
            let content = (c["content"] as? String) ?? ""
            guard !content.isEmpty else { return nil }
            let avatar = (c["avatar"] as? String) ?? ""
            return SongComment(
                nickname: (c["nickname"] as? String) ?? "匿名用户",
                avatarURL: avatar.isEmpty ? nil : URL(string: avatar),
                content: content,
                timeMs: (c["timeMs"] as? NSNumber)?.intValue ?? 0,
                likedCount: (c["likedCount"] as? NSNumber)?.intValue ?? 0
            )
        }
        return (items, total, hasMore, nil)
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
    /// - r28：整链包一层 dailyTimeout（25s）硬超时，见 dailyTimeout 注释；
    ///   超时按空处理，loadDaily 走诚实空态，不留 spinner。
    /// - r31-daily：超时壳改成“弃子竞速”——取数腿跑在脱离的 Task 里，
    ///   壳里只竞 `opTask.value` 与 25s 睡眠。根因（用户 2026-11-21 05:58
    ///   “每日推荐一直拉取不到数据，面板一直在转圈圈”）：旧壳把取数腿
    ///   本身放进 withThrowingTaskGroup 当子任务，超时后群组退出要先等
    ///   该子任务完成（取消只是请求，腿里不响应取消的挂起——如 `try?`
    ///   吞掉取消的重试 sleep、URLSession 在弱网 connect/DNS 里不立即
    ///   退——群组就一直等，loadDaily 永远到不了 `isLoadingDaily = false`，
    ///   spinner 无限转；r28 的 25s 壳只掐了超时任务本身，没掐住加载）。
    ///   竞 `task.value` 时取消立即打断等待者（等值挂起本身响应取消），
    ///   25s 一到必回空结果，spinner 必停；被弃的腿留在后台、自己到腿
    ///   超时就停（各腿 15–25s 都有上限），它只读上游、不写任何 UI 状态。
    ///   超时/取消时也顺手 cancel 掉被弃任务（尽力而为，UI 不等它）。
    /// - r31-daily：回值改成 DailyResult（曲目 + 空原因）：旧写法只回
    ///   [DailyTrack]，主腿 301/401（未登录）与请求失败的信息全丢了，
    ///   空态只能写一句通用话，用户问“是不是系统不认登录”答不上来。
    ///   现在腿结果（DailyLeg）把 unauthorized / failed 原样带上来，
    ///   空时 loadDaily 能说清是没登录、没网还是上游没内容。
    struct DailyResult {
        var tracks: [DailyTrack]
        /// 为空时的诚实原因（nil = 用 loadDaily 的 emptyReason(for:) 通用文案）。
        var emptyReason: String?
    }

    static func dailyRecommend(platform: String) async -> DailyResult {
        let opTask = Task { await dailyRecommendUntimed(platform: platform) }
        do {
            return try await withTimeout(seconds: Self.dailyTimeout) {
                await opTask.value
            }
        } catch is CancellationError {
            opTask.cancel()
            return DailyResult(tracks: [], emptyReason: nil)
        } catch {
            // 超时（TimeoutError）必走这里：25s 一到即回，不等被弃的腿。
            opTask.cancel()
            return DailyResult(tracks: [], emptyReason: "每日推荐拉取超时（25 秒无响应），请检查网络后重试。")
        }
    }

    /// 每日推荐整链（无超时；dailyRecommend 的超时壳调这里）。
    private static func dailyRecommendUntimed(platform: String) async -> DailyResult {
        switch platform {
        case "netease":
            let main = await dailyTracks(path: "/api/recommend/songs", platform: platform)
            if !main.tracks.isEmpty { return DailyResult(tracks: main.tracks, emptyReason: nil) }
            let fallback = await dailyTracks(path: "/api/personalized", platform: platform)
            if !fallback.tracks.isEmpty { return DailyResult(tracks: fallback.tracks, emptyReason: nil) }
            if main.unauthorized {
                return DailyResult(tracks: [], emptyReason: "未登录网易云：每日推荐需要登录才能拉取；推荐新歌也没返回内容，请登录网易云后重试，或检查网络。")
            }
            if main.failed && fallback.failed {
                return DailyResult(tracks: [], emptyReason: "网易云每日推荐和推荐新歌都请求失败，请检查网络后重试。")
            }
            return DailyResult(tracks: [], emptyReason: nil)
        case "qq":
            let main = await dailyTracks(path: "/api/qq/user/daily-songs", platform: platform)
            if !main.tracks.isEmpty { return DailyResult(tracks: main.tracks, emptyReason: nil) }
            let fallback = await dailyTracks(path: "/api/qq/recommend/radar",
                                             query: ["page": "1"], platform: platform)
            if !fallback.tracks.isEmpty { return DailyResult(tracks: fallback.tracks, emptyReason: nil) }
            if main.unauthorized {
                return DailyResult(tracks: [], emptyReason: "未登录 QQ 音乐：每日推荐需要登录才能拉取；雷达推荐也没返回内容，请登录 QQ 音乐后重试，或检查网络。")
            }
            if main.failed && fallback.failed {
                return DailyResult(tracks: [], emptyReason: "QQ 音乐每日推荐和雷达推荐都请求失败，请检查网络后重试。")
            }
            return DailyResult(tracks: [], emptyReason: nil)
        case "qishui":
            let leg = await dailyTracks(path: "/api/qishui/feed",
                                        query: ["count": "20"], platform: platform)
            return DailyResult(tracks: leg.tracks,
                               emptyReason: leg.tracks.isEmpty
                                ? (leg.failed ? "汽水推荐流请求失败，请检查网络后重试。" : nil) : nil)
        case "bodian":
            let leg = await dailyTracks(path: "/api/bodian/ai/playlist",
                                        query: ["index": "0"], platform: platform)
            return DailyResult(tracks: leg.tracks,
                               emptyReason: leg.tracks.isEmpty
                                ? (leg.failed ? "波点潮趣日推请求失败，请检查网络后重试。" : nil) : nil)
        case "kuwo":
            let leg = await dailyTracks(path: "/api/kuwo/daily", platform: platform)
            return DailyResult(tracks: leg.tracks,
                               emptyReason: leg.tracks.isEmpty
                                ? (leg.failed ? "酷我每日推荐请求失败，请检查网络后重试。" : nil) : nil)
        case "kugou":
            let leg = await dailyTracks(path: "/api/kugou/everyday/recommend", platform: platform)
            return DailyResult(tracks: leg.tracks,
                               emptyReason: leg.tracks.isEmpty
                                ? (leg.failed ? "酷狗每日推荐请求失败，请检查网络后重试。" : nil) : nil)
        case "applemusic":
            let leg = await dailyTracks(path: "/api/applemusic/daily", platform: platform)
            return DailyResult(tracks: leg.tracks,
                               emptyReason: leg.tracks.isEmpty
                                ? (leg.failed ? "Apple Music 每日推荐请求失败，请检查网络后重试。" : nil) : nil)
        default:
            return DailyResult(tracks: [], emptyReason: nil)
        }
    }

    /// 每日推荐一行请求的归一化读数（{ tracks } / { data } / { songs }）。
    /// r31-daily：回腿结果不只给曲目——上游 301/401（未登录）与请求失败
    /// （call 回 nil / 包里 code 非 200）要原样带给调用方，空态才能说清
    /// 是没登录还是没网；rows 仍只认 { tracks } / { data } / { songs }，
    /// 不编假数据。code 缺键时按 200（成功）算，不把无 code 的成功包判失败。
    private struct DailyLeg {
        var tracks: [DailyTrack]
        /// 上游明确说没登录（包里 code 301/401，如网易 301、QQ 401）。
        var unauthorized: Bool
        /// 请求本身没通（call 回 nil）或包里 code 非 200/301/401。
        var failed: Bool
    }

    private static func dailyTracks(path: String, query: [String: String] = [:],
                                    platform: String) async -> DailyLeg {
        guard let d = await call(path: path, query: query) else {
            return DailyLeg(tracks: [], unauthorized: false, failed: true)
        }
        let code = (d["code"] as? NSNumber)?.intValue ?? 200
        let rows: [[String: Any]] = (d["tracks"] as? [[String: Any]])
            ?? (d["data"] as? [[String: Any]])
            ?? (d["songs"] as? [[String: Any]]) ?? []
        let tracks = rows.compactMap { Track.from(dict: $0, platform: platform) }
            .map { DailyTrack(track: $0) }
        return DailyLeg(tracks: tracks,
                        unauthorized: code == 301 || code == 401,
                        failed: code != 200 && code != 301 && code != 401)
    }

    /// 歌单全量曲目（r31：面板「点歌单看全部歌曲」用；旧实现只取一页——汽水/
    /// 波点 limit 50、酷狗 30、酷我榜单 50，50 首以上的歌单会被截断）。
    /// - netease / qq：detail 本身回全量（网易 n=1000 + trackIds 补全；QQ CGI，
    ///   code-10 时 musicu 内部分页），直接调 playlistDetail 取 tracks。
    /// - applemusic：iTunes lookup 单次回全量（无分页参数），直接调 playlistDetail。
    /// - qishui / bodian：playlist/tracks 支持 limit + offset + more，offset
    ///   翻页直到 more 为 false（每页 100，最多 20 页）。
    /// - kugou：playlist/tracks 支持 page + pagesize（≤100），翻页直到回包不足
    ///   一页（最多 20 页）。
    /// - kuwo：playlist/tracks 与 rank/tracks 都支持 limit + page + total，
    ///   翻页直到取满 total（最多 10 页）。
    /// `source` 只给波点专辑用（source=6，见 albumDetail 波点分支）。
    static func playlistAllTracks(platform: String, id: String, isRank: Bool = false,
                                  source: Int? = nil) async -> [Track] {
        switch platform {
        case "netease", "qq", "applemusic":
            return await playlistDetail(platform: platform, id: id, isRank: isRank).tracks
        case "qishui", "bodian":
            let path = "/api/\(platform)/playlist/tracks"
            var all: [Track] = []
            var offset = 0
            for _ in 0..<20 {
                var query: [String: String] = ["id": id, "limit": "100", "offset": "\(offset)"]
                if let source { query["source"] = "\(source)" }
                guard let d = await call(path: path, query: query),
                      (d["code"] as? NSNumber)?.intValue == 200 else { break }
                let rows = (d["tracks"] as? [[String: Any]]) ?? []
                let tracks = rows.compactMap { Track.from(dict: $0, platform: platform) }
                all.append(contentsOf: tracks)
                offset += tracks.count
                let more = (d["more"] as? NSNumber)?.boolValue == true
                if !more || tracks.isEmpty { break }
            }
            return all
        case "kugou":
            var all: [Track] = []
            for page in 1...20 {
                guard let d = await call(path: "/api/kugou/playlist/tracks",
                                         query: ["id": id, "limit": "100", "page": "\(page)"]),
                      (d["code"] as? NSNumber)?.intValue == 200 else { break }
                let rows = (d["tracks"] as? [[String: Any]]) ?? []
                let tracks = rows.compactMap { Track.from(dict: $0, platform: platform) }
                all.append(contentsOf: tracks)
                if tracks.count < 100 { break }
            }
            return all
        case "kuwo":
            let path = isRank ? "/api/kuwo/rank/tracks" : "/api/kuwo/playlist/tracks"
            var all: [Track] = []
            for page in 1...10 {
                guard let d = await call(path: path, query: ["id": id, "limit": "200", "page": "\(page)"]),
                      (d["code"] as? NSNumber)?.intValue == 200 else { break }
                let rows = (d["tracks"] as? [[String: Any]]) ?? []
                let tracks = rows.compactMap { Track.from(dict: $0, platform: platform) }
                all.append(contentsOf: tracks)
                let total = (d["total"] as? NSNumber)?.intValue ?? 0
                if total > 0, all.count >= total { break }
                if tracks.count < 200 { break }
            }
            return all
        default:
            return await playlistDetail(platform: platform, id: id, isRank: isRank).tracks
        }
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
            switch platform {
            case "qishui":
                detailPath = "/api/qishui/playlist/detail"
            case "bodian":
                detailPath = "/api/bodian/playlist/detail"
            default: // kugou
                detailPath = "/api/kugou/playlist/detail"
            }
            var pl = Playlist(id: id, source: platform)
            if let meta, !meta.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pl = meta
            } else if let d = await call(path: detailPath, query: ["id": id]) {
                pl = playlistFrom(dict: d, platform: platform, id: id)
            }
            // r31：曲目走 playlistAllTracks 翻页取全量（旧实现只取一页 limit 50）。
            pl.tracks = await playlistAllTracks(platform: platform, id: id)
            if pl.trackCount == 0 { pl.trackCount = pl.tracks.count }
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
            var pl = playlistFrom(dict: d, platform: platform, id: id)
            // r31：榜单 / 非榜单都翻页取全量（旧实现只取一页）。
            if pl.trackCount > pl.tracks.count || pl.tracks.count >= 50 {
                pl.tracks = await playlistAllTracks(platform: platform, id: id, isRank: isRank)
                if pl.trackCount == 0 { pl.trackCount = pl.tracks.count }
            }
            return pl
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
        case "qq":
            // r31：QQ 专辑曲目走服务端新加的 /api/qq/album/tracks（网页 CGI
            // fcg_v8_album_info_cp，见 QQ.swift albumTracks）。
            guard let d = await call(path: "/api/qq/album/tracks", query: ["id": id]) else {
                return Album(id: id, source: platform)
            }
            var album = Album(id: id, source: platform)
            album.title = (d["name"] as? String) ?? ""
            if let cover = d["cover"] as? String, !cover.isEmpty { album.coverURL = URL(string: cover) }
            album.tracks = ((d["tracks"] as? [[String: Any]]) ?? [])
                .compactMap { Track.from(dict: $0, platform: platform) }
            album.trackCount = (d["trackCount"] as? NSNumber)?.intValue ?? album.tracks.count
            return album
        case "kugou":
            // r31：酷狗专辑详情（名/封面/歌手）+ 曲目翻页（album_songs 每页
            // ≤50，见 FoliaKugou albumDetail / albumSongs，本来就有的路由）。
            var album = Album(id: id, source: platform)
            if let d = await call(path: "/api/kugou/album/detail", query: ["id": id]),
               let a = d["album"] as? [String: Any] {
                album.title = (a["name"] as? String) ?? ""
                album.artist = (a["artists"] as? String) ?? ""
                if let cover = a["cover"] as? String, !cover.isEmpty { album.coverURL = URL(string: cover) }
            }
            var tracks: [Track] = []
            for page in 1...10 {
                guard let d = await call(path: "/api/kugou/album/songs",
                                         query: ["id": id, "limit": "50", "page": "\(page)"]),
                      (d["code"] as? NSNumber)?.intValue == 200 else { break }
                let rows = (d["tracks"] as? [[String: Any]]) ?? []
                let pageTracks = rows.compactMap { Track.from(dict: $0, platform: platform) }
                tracks.append(contentsOf: pageTracks)
                if pageTracks.count < 50 { break }
            }
            album.tracks = tracks
            album.trackCount = tracks.count
            return album
        case "bodian":
            // r31：波点专辑取曲走歌单曲目接口 source=6（专辑的 sourceType；
            // 未实测——上游不认时回空，面板按诚实空态显示，不编曲目）。
            var album = Album(id: id, source: platform)
            album.tracks = await playlistAllTracks(platform: platform, id: id, source: 6)
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
        // r30 路线 B：ISRC 透传（各平台归一化层只负责把上游给的 isrc 原样放进
        // 字典；实测只有 Apple Music 的 catalog 数据带它，其余 6 台没有，
        // 见 AppleAnimatedArtwork.swift 文件头 r30 平台表）。归一化 +
        // 12 位校验不合格直接丢（空串），不把脏数据发去 catalog 查。
        let isrc = AppleAnimatedArtworkProvider.normalizedISRC((dict["isrc"] as? String) ?? "")
        return Track(id: idString, platform: platform, title: title,
                     artist: artist.isEmpty ? "未知歌手" : artist, album: album,
                     coverURL: URL(string: coverString),
                     durationMs: durationMs, vip: fee != 0,
                     platformKey: platformKey, albumId: albumId,
                     albumAudioId: albumAudioId, artistIds: artistIds, isrc: isrc)
    }
}
