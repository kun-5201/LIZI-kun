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
    /// 每条腿的独立预算（r35-9：套壳 api.js 每条腿 AbortSignal.timeout(60000)，
    /// 主腿→兜底腿各拿一个全新 60 秒；原生之前整链共用 25 秒，4G 慢网下
    /// 主腿一慢就吃光预算，兜底腿（personalized、雷达、推荐歌单合成）
    /// 根本轮不到，用户只看到空态。套壳同一网络主腿 12 秒 + 兜底 12 秒
    /// = 24 秒出数据，就是「每腿独立」省出来的）。
    /// 每日推荐的每条腿（dailyTracks / synthesizedDailyTracks）与每栏
    /// （HomeViewModel.loadRailPage）各包一层 60 秒；整链再包一层
    /// dailyChainTimeout 兜底。
    static let legTimeout: TimeInterval = 60
    /// 每日推荐整链兜底（r35-9：每腿独立 60 秒之后，整链再包一层 120 秒；
    /// 旧 dailyTimeout（整链 25 秒）作废——25 秒是 r28 的旧账（见下），
    /// 链路里单腿 15–25 秒的上限仍在，120 秒只是外层兜底。
    /// r28 旧账：单腿都有超时，但网易匿名要连调两条（recommend/songs +
    /// personalized，各 15s × 2 次重试）、QQ 登录态刷新 + 两条各 25s，
    /// 最坏单次拉取 60–75s 才落空态；且每次回首页都从头拉。整链 25s
    /// 不回就当空、UI 走诚实空态，不让 spinner 无限转。健康链路实测
    /// 0.3–5.2s（r28 真机前用 r27 Node 服务对真上游测过），25s 是约
    /// 5 倍余量。超时只掐断 UI 的等待——底下的 URLSession 取数不停
    /// （链路里没有取消检查点），它自己到腿超时就停，不泄漏。
    static let dailyChainTimeout: TimeInterval = 120
    /// 搜索上游请求失败时回给 UI 的文案（P1 集成补的轻量错误通道：call 回 nil
    /// = 请求本身没通，不是「搜不到」；上游正常回空列表不走这里）。
    static let searchErrorText = "接口请求失败，请检查网络后重试"

    // MARK: - 取链结果

    /// 一次取链的结果（`url` 为空 = 这一档拿不到地址；调用方按编排继续往下一档）。
    struct SongURLResult {
        var url: URL?
        /// 上游实际回的档位（显示音质 = 这个，绝不显示请求的档位；
        /// r31：canon 的结果再过 AudioQuality.verified，按实际地址的
        /// 实证（QQ 文件名前缀 / 容器 / 码率）校验，宣称高于实证上限
        /// 时往下压、给不出时为 nil，UI 不挂徽章）。
        /// r31（R6 已删）：canon 不再按 br 猜档位；served 对不上档位
        /// 表时 actualQuality 为 nil，原文进 servedLabel，UI 原样显示。
        var actualQuality: AudioQuality?
        /// 音源回的档位原文（canon 翻译不出时才有值，如 "192k"；
        /// 翻译得出时为 nil，显示档位名就够了）。
        var servedLabel: String?
        /// 是否试听片段（官方只给了 freeTrialInfo / preview）。
        /// r31（R5 已删）：这只是标记，不再据此丢弃——30 秒试听照播。
        var isTrial: Bool
        /// 是否 30 秒试听（Apple Music 公开 API 只出这个）。
        var isPreview: Bool
        /// 失败原因（vip / unavailable / login / region / drm / network；成功时为空）。
        var reason: String
        /// 这条地址从哪来（platform / cloud / lx / local）。
        var via: String
        /// 实际码率 bps（上游给了才有；只作信息，不参与档位判定）。
        var bitrate: Int
        /// 试听片段的起始毫秒（汽水等平台有）。
        var clipStartMs: Int
        /// 云盘命中时云盘那首歌的元数据（歌名/歌手/专辑/封面/时长；网易的由
        /// /api/song/detail 补，酷狗的由云盘列表直接给）。PlaybackStore 只拿它
        /// 补当前曲目缺失的字段（封面/时长/歌手/专辑），不覆盖已有的标题/歌手，
        /// 非云盘腿为 nil。
        var resolvedTrack: Track?

        init(url: URL? = nil, actualQuality: AudioQuality? = nil, isTrial: Bool = false,
             isPreview: Bool = false, reason: String = "", via: String = "",
             bitrate: Int = 0, clipStartMs: Int = 0, servedLabel: String? = nil,
             resolvedTrack: Track? = nil) {
            self.url = url
            self.actualQuality = actualQuality
            self.isTrial = isTrial
            self.isPreview = isPreview
            self.reason = reason
            self.via = via
            self.bitrate = bitrate
            self.clipStartMs = clipStartMs
            self.servedLabel = servedLabel
            self.resolvedTrack = resolvedTrack
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

    /// 不论 2xx 与否都把 JSON 体还回来的调用（r35-9，套壳 callSoft 同款）：
    /// `call` 在非 2xx 时直接回 nil，错误体（code/error/message）全丢了，
    /// 空态只能写一句通用话；这里把 (status, dict) 一起还回来，调用方
    /// （dailyTracks / RailsBridge.railError）自己按体里的 code/error 判。
    /// 没体（空 body / 解析失败）时 dict 为 nil，与 `call` 的失败口径一致。
    static func callSoft(path: String, query: [String: String] = [:],
                         method: String = "GET") async -> (status: Int, dict: [String: Any]?) {
        let req = HttpRequest(method: method, path: path, query: query,
                              headers: [:], body: Data())
        let resp = await router.handle(req)
        guard let obj = try? JSONSerialization.jsonObject(with: resp.body),
              let dict = obj as? [String: Any] else { return (resp.status, nil) }
        return (resp.status, dict)
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
    /// r33（a）：旧实现是 withThrowingTaskGroup——超时后群组退出要等取数
    /// 子任务完成，腿里不响应取消的挂起会让群组一直等（r31-daily 的转圈
    /// 根因；「等值挂起响应取消」的假设没有实测证据）。新实现是 detached
    /// 竞速，不用 TaskGroup：取数腿与超时睡眠各跑一个 detached 任务，
    /// 先到者胜，胜出后取消另一方；checked continuation + 一次性结算
    /// 守卫保证只 resume 一次。关键：超时由计时任务直接 resume
    /// continuation，当前任务不等取数腿——腿不响应取消也 25s 必回，
    /// 超时/取消都抛错，由调用方按失败处理，绝不挂起。
    /// （项目是 Swift 5 模式，continuation 被 Task 捕获可编译。）
    private final class TimeoutRaceBox {
        private let lock = NSLock()
        private var done = false
        /// 第一个调用者返回 true 并锁定胜出，后来者返回 false。
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return false }
            done = true
            return true
        }
    }

    static func withTimeout<T>(seconds: TimeInterval,
                               _ op: @escaping () async throws -> T) async throws -> T {
        let opTask = Task.detached { try await op() }
        let timerTask = Task.detached {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                    let box = TimeoutRaceBox()
                    Task {
                        do {
                            let value = try await opTask.value
                            if box.claim() {
                                timerTask.cancel()
                                cont.resume(returning: value)
                            }
                        } catch {
                            if box.claim() {
                                timerTask.cancel()
                                cont.resume(throwing: error)
                            }
                        }
                    }
                    Task {
                        do {
                            try await timerTask.value
                            if box.claim() {
                                opTask.cancel()
                                cont.resume(throwing: TimeoutError())
                            }
                        } catch {
                            // 睡眠被取消 = 取数腿已胜出或外层已取消，无事可做。
                        }
                    }
                }
            } onCancel: {
                opTask.cancel()
                timerTask.cancel()
            }
        } catch {
            opTask.cancel()
            timerTask.cancel()
            throw error
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
/// r48-11：音频信息磁盘缓存（TTL 10 分钟）——取链结果（url + 音质/码率/
/// 试听标记）落盘，10 分钟内重播同一首歌同一档位直接读本地，不再调取链。
/// 流地址本身短命（网易 expi 约 20 分钟），TTL 只给 10 分钟；读时不刷新
/// mtime（DiskCache touch:false），到期即废。播一半死了由
/// PlaybackStore.handlePlaybackFailure 清掉（removeAudio），免得下次
/// 重试又拿到同一条死链。只缓存平台腿（网易/QQ/酷狗/酷我/汽水/波点）；
/// Apple Music（试听语义 + r48-5 地区检查在取链里，不进缓存）、本地、
/// LX 腿（脚本自带取链、过期规则未知）不进。
static func songURL(track: Track, quality: AudioQuality) async -> SongURLResult {
    let cacheable = ["netease", "qq", "kugou", "kuwo", "qishui", "bodian"].contains(track.platform)
    let audioKey = DiskCache.audioKey(platform: track.platform, id: track.platformKey, quality: quality.rawValue)
    if cacheable,
       let data = DiskCache.data(kind: .audio, key: audioKey, touch: false),
       let cached = Self.audioResultFromData(data) {
        return cached
    }
    let result = await songURLUncached(track: track, quality: quality)
    if cacheable, result.url != nil, let data = Self.audioResultData(result) {
        DiskCache.store(data, kind: .audio, key: audioKey)
    }
    return result
}

private static func audioResultData(_ r: SongURLResult) -> Data? {
    var d: [String: Any] = ["url": r.url?.absoluteString ?? "", "via": r.via,
                            "isTrial": r.isTrial, "isPreview": r.isPreview,
                            "bitrate": r.bitrate, "clipStartMs": r.clipStartMs]
    if let q = r.actualQuality { d["quality"] = q.rawValue }
    if let s = r.servedLabel { d["servedLabel"] = s }
    return try? JSONSerialization.data(withJSONObject: d)
}

private static func audioResultFromData(_ data: Data) -> SongURLResult? {
    guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let urlString = d["url"] as? String,
          let url = URL(string: urlString) else { return nil }
    return SongURLResult(url: url,
                         actualQuality: (d["quality"] as? String).flatMap(AudioQuality.init(rawValue:)),
                         isTrial: d["isTrial"] as? Bool ?? false,
                         isPreview: d["isPreview"] as? Bool ?? false,
                         reason: "", via: d["via"] as? String ?? "platform",
                         bitrate: d["bitrate"] as? Int ?? 0,
                         clipStartMs: d["clipStartMs"] as? Int ?? 0,
                         servedLabel: d["servedLabel"] as? String)
}

private static func songURLUncached(track: Track, quality: AudioQuality) async -> SongURLResult {
let platform = track.platform
let key = track.platformKey
let param = quality.requestParam(platform: platform)
switch platform {
case "netease":
// /api/song/url：ids 是 JSON 数组字符串，level 原样透传。
guard let id = Int(key) else { return SongURLResult(reason: "unavailable", via: "platform")}
// r49：取链单独区分 network 与 unavailable——call() 在 502/超时/
// 空体时直接回 nil，桥层原来一律坍缩成 unavailable；这里用已有的
// callSoft 变体（(status, dict)，不新加 call()、其它调用方一字不
// 动）：没体（dict nil）或服务端 502 → reason:"network"；有体无
// 数据才按 per-item 码判 vip/unavailable。
let (songUrlStatus, d) = await callSoft(path: "/api/song/url",
query: ["ids": "[\(id)]", "level": param])
guard let d else {
return SongURLResult(reason: "network", via: "platform")
}
guard let items = d["data"] as? [[String: Any]], let item = items.first else {
return SongURLResult(reason: songUrlStatus == 502 ? "network" : "unavailable", via: "platform")
}
let urlString = (item["url"] as? String) ?? ""
let isTrial = item["freeTrialInfo"] != nil && !(item["freeTrialInfo"] is NSNull)
let br = (item["br"] as? NSNumber)?.intValue ?? 0
let served = (item["level"] as? String) ?? ""
// r31 真实音质：type 是上游回的文件容器（mp3/flac），与 level/br 一起
// 作实证——level 只认上游宣称时，宣称与实际文件不符就挂假徽章
//（要了 dolby、实际只给了 320k mp3 时 level 仍可能报 dolby）。
if urlString.isEmpty {
// r48-8：normalize 已把 per-item code 与 cannotListenReason 透传下来
// （以前 normalize 不传 code，这里的 -110 判定是死代码、网易失败原因
// 永远是 unavailable）。匿名 VIP 歌回 code 404 + cannotListenReason 1，
// 同样是服务端明确说「需会员」，与 -110 同按 vip 计。
let code = (item["code"] as? NSNumber)?.intValue ?? 0
let cannotListen = (item["cannotListenReason"] as? NSNumber)?.intValue ?? 0
return SongURLResult(reason: (code == -110 || cannotListen == 1) ? "vip" : "unavailable", via: "platform")
}
let streamURL = Upstream.url(from: urlString).map { Upstream.upgradedAudioURL($0) }
let streamType = (item["type"] as? String) ?? ""
// r31（R6 已删）：canon 只翻译档位名，不按 br 猜档；翻译不出时
// actualQuality 为 nil、原文进 servedLabel，UI 原样显示 "192k" 之类，
// 不压成标准。verified 的 bitrate 参数已忽略（见 Models.swift）。
let neteaseClaimed = AudioQuality.canon(platform: "netease", served: served)
return SongURLResult(url: streamURL,
actualQuality: AudioQuality.verified(claimed: neteaseClaimed, url: streamURL, bitrate: br, format: streamType),
isTrial: isTrial, reason: "", via: "platform", bitrate: br,
servedLabel: neteaseClaimed == nil && !served.isEmpty ? served : nil)
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
// r31（R6 已删）：canon 只翻译档位名；翻译不出时原文进 servedLabel。
let sidecarClaimed = AudioQuality.canon(platform: platform, served: served)
return SongURLResult(url: streamURL,
actualQuality: AudioQuality.verified(claimed: sidecarClaimed, url: streamURL, format: streamFormat.isEmpty ? nil : streamFormat),
isTrial: preview, isPreview: preview,
reason: "", via: "platform", clipStartMs: clipStartMs,
servedLabel: sidecarClaimed == nil && !served.isEmpty ? served : nil)
}

// MARK: - 取链：个人云盘（网易「我的云盘」+ 酷狗「我的云盘」）

/// 个人云盘取链（r31-clouddrive：网易 + 酷狗；其余 5 台没有可用的网盘接口，见下表）。
///
/// 7 平台核查（2026-11-21，证据见 verification/r31-clouddrive.cjs §1）：
/// - 网易：有。POST weapi /v1/cloud/get（/api/user/cloud），MUSIC_U 登录；
///   行只有 songId/songName/artist/album/fileSize/fileName，没有封面/时长，
///   封面/时长靠命中后调 /api/song/detail（/v3/song/detail）补。
/// - 酷狗：有。服务端 FoliaKugou 已有 user/cloud（POST mcloudservice.kugou.com
///   /v1/get_list，token 登录；回 tracks，含封面/时长/hash）+ user/cloud_url
///   （GET gateway /bsstrackercdngz/v2/query_musicclound_url，key=signCloudKey）；
///   本轮之前原生编排没接线（cloudSongURL 只认 netease），本轮接上。
/// - QQ：产品上有「音乐云盘」（微云音乐网盘；Folia 前端 qqLists.ts 有
///   /user/cloud 路由，只列对上曲库且 playable 的歌），但 Lizi 的 QQ 服务端
///   是按 jsososo QQMusicApi / Moumusic 接口移植的，那套接口里没有云盘
///   列出/取链的上游 CGI，本轮未核实到可直接用的上游模块——不编接口、不留
///   空壳，cloudSongURL 对 qq 回 nil。
/// - 酷我：没有。客户端只有本地下载/离线缓存，没有个人云盘上传/列表/取链
///   的可用接口；Folia 里也没有 kuwo 的 user_cloud。
/// - 汽水：没有。只有「本地音乐」扫描（本机文件），没有云端网盘与可用接口。
/// - 波点：没有。同汽水，只有本机/歌单，没有云盘接口。
/// - Apple Music：没有可取链的网盘接口。iCloud 音乐资料库（iTunes Match /
///   订阅上传）里的歌没有可供取链的流地址，播要走 MusicKit/系统音乐资料库，
///   不是一条 URL；本轮不接。
///
/// 匹配规则（两台共用同一套 findCloudSong，规则写死在这里）：
/// 1) id 精确匹配优先：网易 cloudSongId == track.id；酷狗 hash == track.id /
///    platformKey（大小写不敏感）。上传的就是这首歌时 id 一致，直接命中。
/// 2) 否则歌名 + 歌手/专辑打分：歌名归一化相等是硬门槛；歌手双方都有且互含
///    得 2 分，专辑双方都有且相等得 1 分；总分 >= 1 才命中，取最高分（并列取
///    先出现的）。歌手/专辑两边都对不上、只有歌名相同——不播，宁可不播也不
///    播错一首（同名不同歌手是最常见的错播）。
/// 3) 「未知歌手」按缺失算（两边都是）：网易云盘行 artist 为空、酷狗
///    kugouTrack 兜底填的「未知歌手」都不算歌手证据。
/// 归一化（normCloudKey）：去大小写；整段删掉 (...) / （...） / [...] /
/// 【...】 / {...} 里的后缀（Live/翻唱/feat. 之类不参与匹配——旧实现只删
/// 括号字符、留下了里面的字，「夜曲 (Live版)」对不上「夜曲」）；再去空白/
/// 标点/连字符。歌手只比第一位（按 / 切）。
/// 缓存：列表按登录态 + 10 分钟缓存；网易每次最多 10 页 x 200（旧 5 页，
/// 1000 首以上云盘的歌翻不到）；酷狗每次最多 10 页 x 50（pagesize 上限
/// 50）。未登录不拉列表。
static func cloudSongURL(track: Track, quality: AudioQuality) async -> SongURLResult? {
switch track.platform {
case "netease": return await neteaseCloudSongURL(track: track, quality: quality)
case "kugou": return await kugouCloudSongURL(track: track, quality: quality)
default: return nil
}
}

/// 网易云盘腿：列表 -> 匹配 -> /api/song/url 取链 -> /api/song/detail 补封面/时长。
/// hasMusicU 只在这一段里出现（r31-mquality §6d：全仓 hasMusicU 检查都在
/// cloudSongURL 这一段里；酷狗腿不认 MUSIC_U，401 靠服务端回包认）。
static func neteaseCloudSongURL(track: Track, quality: AudioQuality) async -> SongURLResult? {
guard SessionStore.shared.hasMusicU else { return nil }
let now = Date()
if now.timeIntervalSince(cloudCacheAt) > 600 || !cloudCacheLoggedIn {
var songs: [[String: Any]] = []
var loggedIn = false
if SessionStore.shared.hasMusicU {
loggedIn = true
for page in 0..<10 {
guard let d = await call(path: "/api/user/cloud",
query: ["limit": "200", "offset": "\(page * 200)"]),
let rows = cloudRows(d) else { break }
songs.append(contentsOf: rows)
if rows.count < 200 { break }
}
}
cloudCache = songs
cloudCacheAt = now
cloudCacheLoggedIn = loggedIn
}
guard cloudCacheLoggedIn, !cloudCache.isEmpty else { return nil }
let candidates = cloudCache.compactMap { cloudCandidate(from: $0) }
guard let hit = findCloudSong(track, in: candidates) else { return nil }
let cloudId = hit.platformKey
guard !cloudId.isEmpty else { return nil }
var r = await songURL(track: Track(id: cloudId, platform: "netease",
platformKey: cloudId), quality: quality)
guard r.url != nil else { return nil }
r.via = "cloud"
// 云盘行没有封面/时长：命中后调 /api/song/detail（ids 用裸数字串，不带
// 括号——NetEase.idList 按逗号切，"[123]" 解析不出）补一次；detail 空
// 时用云盘行自己的歌名/歌手/专辑顶（至少不丢元数据）。
r.resolvedTrack = await neteaseCloudDetail(id: cloudId) ?? hit
return r
}

private static var cloudCache: [[String: Any]] = []
private static var cloudCacheAt: Date = .distantPast
private static var cloudCacheLoggedIn: Bool = false

/// 网易云盘行 -> 候选曲目（songId/name/artists/album；行里没有封面/时长，
/// resolvedTrack 的封面/时长由 neteaseCloudDetail 另补）。
private static func cloudCandidate(from c: [String: Any]) -> Track? {
let id = cloudSongId(c)
guard !id.isEmpty else { return nil }
let name = (c["songName"] as? String) ?? (c["name"] as? String) ?? ""
guard !name.isEmpty else { return nil }
let artist = (c["artist"] as? String) ?? (c["artists"] as? String) ?? ""
let album = (c["album"] as? String) ?? ""
return Track(id: id, platform: "netease", title: name, artist: artist, album: album, platformKey: id)
}

/// 网易云盘命中后补元数据：/api/song/detail（/v3/song/detail）按 cloudId
/// 取一首歌的归一化行（toTrack：封面 al.picUrl、时长 dt）；拿不到回 nil，
/// 调用方用云盘行自己顶。
private static func neteaseCloudDetail(id: String) async -> Track? {
guard let n = Int(id) else { return nil }
guard let d = await call(path: "/api/song/detail", query: ["ids": "\(n)"]),
let rows = d["tracks"] as? [[String: Any]],
let first = rows.first else { return nil }
return Track.from(dict: first, platform: "netease")
}

private static var kugouCloudCache: [Track] = []
private static var kugouCloudCacheAt: Date = .distantPast
private static var kugouCloudCacheLoggedIn: Bool = false

/// 酷狗云盘腿：列表（/api/kugou/user/cloud，token 登录；未登录服务端回
/// code 401，这里按 401 认未登录、不另查登录态）-> 匹配 -> 取链
/// （/api/kugou/user/cloud_url，hash + albumAudioId + name；回的 quality
/// 是空串——云盘文件实际档位未知，绝不硬编 flac，actualQuality 保持 nil，
/// UI 不挂徽章）。登录态不认 MUSIC_U（那是网易的），只认 401。
static func kugouCloudSongURL(track: Track, quality: AudioQuality) async -> SongURLResult? {
let now = Date()
if now.timeIntervalSince(kugouCloudCacheAt) > 600 || !kugouCloudCacheLoggedIn {
var songs: [Track] = []
var loggedIn = false
for page in 1...10 {
guard let d = await call(path: "/api/kugou/user/cloud",
query: ["page": "\(page)", "limit": "50"]) else { break }
let code = (d["code"] as? NSNumber)?.intValue ?? 0
if code == 401 { break }
guard code == 200 else { break }
loggedIn = true
let rows = (d["tracks"] as? [[String: Any]]) ?? []
let tracks = rows.compactMap { Track.from(dict: $0, platform: "kugou") }
songs.append(contentsOf: tracks)
if tracks.count < 50 { break }
}
kugouCloudCache = songs
kugouCloudCacheAt = now
kugouCloudCacheLoggedIn = loggedIn
}
guard kugouCloudCacheLoggedIn, !kugouCloudCache.isEmpty else { return nil }
guard let hit = findCloudSong(track, in: kugouCloudCache) else { return nil }
let hash = hit.platformKey.uppercased()
guard !hash.isEmpty else { return nil }
guard let d = await call(path: "/api/kugou/user/cloud_url",
query: ["hash": hash, "albumAudioId": "\(hit.albumAudioId)", "name": hit.title]),
(d["code"] as? NSNumber)?.intValue == 0,
let urlString = d["url"] as? String, !urlString.isEmpty,
let url = Upstream.url(from: urlString).map({ Upstream.upgradedAudioURL($0) }) else { return nil }
// r31 真实音质：云盘文件实际档位未知（服务端 quality 回空串），actualQuality
// 保持 nil、servedLabel 不填，UI 显示「未知」不挂假徽章；resolvedTrack 带
// 云盘行的歌名/歌手/专辑/封面/时长，播放页补显示用（只补缺失项，见
// PlaybackStore.applyCloudTrack）。
return SongURLResult(url: url, via: "cloud", resolvedTrack: hit)
}

/// /api/user/cloud 的行解析（normalize 的形状：data 数组或 songs 数组，字段 songId/songName/artist/album）。
private static func cloudRows(_ d: [String: Any]) -> [[String: Any]]? {
if let rows = d["songs"] as? [[String: Any]] { return rows }
if let data = d["data"] as? [[String: Any]] { return data }
if let data = d["data"] as? [String: Any], let rows = data["songs"] as? [[String: Any]] { return rows }
return nil
}

private static func cloudSongId(_ c: [String: Any]) -> String {
if let s = c["songId"] as? String { return s }
if let n = c["songId"] as? NSNumber { return n.stringValue }
if let n = c["id"] as? NSNumber { return n.stringValue }
return (c["id"] as? String) ?? ""
}

/// 云盘匹配归一化：去大小写；整段删掉括号里的后缀（Live/翻唱/feat. 等不
/// 参与匹配）；再去空白/标点/连字符。旧实现只删括号字符、留下里面的字，
/// 「夜曲 (Live版)」归一化成「夜曲live版」，对不上「夜曲」。
private static func normCloudKey(_ s: String) -> String {
var t = s.lowercased()
let pairs: [(Character, Character)] = [("(", ")"), ("（", "）"), ("[", "]"), ("【", "】"), ("{", "}")]
for (open, close) in pairs {
while let o = t.firstIndex(of: open), let c = t[o...].firstIndex(of: close), c > o {
t.removeSubrange(o...c)
}
}
return t.components(separatedBy: CharacterSet(charactersIn: " \n-_·•'\"“”‘’.,，。、!！?？:：;；|/\\")).joined()
}

/// 歌手归一化键：只比第一位（按 / 切）；空、「未知歌手」按缺失（空串）。
private static func cloudArtistKey(_ s: String) -> String {
let first = (s.components(separatedBy: "/").first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
if first.isEmpty || first == "未知歌手" { return "" }
return normCloudKey(first)
}

/// 云盘匹配（网易 + 酷狗共用；规则见 cloudSongURL 头注）。
/// - id 精确匹配优先（大小写不敏感；酷狗 hash 全大写，网易 id 是数字串）。
/// - 否则歌名归一化相等 + 歌手/专辑打分（歌手互含 2 分，专辑相等 1 分），
///   >= 1 分才命中，取最高分；只有歌名对上不播。
/// - 「未知歌手」按缺失算。
private static func findCloudSong(_ track: Track, in candidates: [Track]) -> Track? {
let trackIdKey = track.platformKey.isEmpty ? track.id : track.platformKey
if let byId = candidates.first(where: { $0.platformKey.uppercased() == trackIdKey.uppercased() }) { return byId }
let nameKey = normCloudKey(track.title)
guard !nameKey.isEmpty else { return nil }
let artistKey = cloudArtistKey(track.artist)
let albumKey = normCloudKey(track.album)
var best: Track?
var bestScore = 0
for c in candidates {
guard normCloudKey(c.title) == nameKey else { continue }
var score = 0
let ca = cloudArtistKey(c.artist)
if !artistKey.isEmpty, !ca.isEmpty, (ca.contains(artistKey) || artistKey.contains(ca)) { score += 2 }
let calbum = normCloudKey(c.album)
if !albumKey.isEmpty, !calbum.isEmpty, calbum == albumKey { score += 1 }
if score > bestScore { bestScore = score; best = c }
}
return bestScore >= 1 ? best : nil
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
// 自动模式下 LX 先跑（PlaybackStore.resolveURL），QQ 匿名
// vkey 对这首歌根本不给 purl、官方腿走不到，所以用户实际听到的就
// 是 LX 这条 mp3，却顶着杜比徽章。这里按实际地址的实证校验：
// QQ 文件名前缀（M800/Q001…）定档，.mp3 上限 320k，
// 不透明地址才保留脚本宣称（残留风险：脚本 tier 是唯一证据时仍
// 可能虚高，见 AudioQuality.verified 的注释——不编更多证据）。
// r31 音质系统替换：起播后实测链（StreamQualityMeasurer）还会按
// 实际解码轨道再定一次档，宣称档位只是初值。
let streamURL = Upstream.url(from: urlString).map { Upstream.upgradedAudioURL($0) }
// r31（R6 已删）：canon 只翻译脚本 tier；翻译不出时原文进 servedLabel。
let lxClaimed = AudioQuality.canon(platform: "lx", served: served)
return SongURLResult(url: streamURL,
actualQuality: AudioQuality.verified(claimed: lxClaimed, url: streamURL),
reason: "", via: "lx",
servedLabel: lxClaimed == nil && !served.isEmpty ? served : nil)
}

// MARK: - 会员态（r31 已删：R1/R2）
//
// 取链编排不再问会员/登录：isMember / memberStatus / 会员缓存已全删。
// 腿的顺序只由「播放来源」三段定（PlaybackStore.resolveURL），请求档
// 直发音源，返回什么播什么。登录态本身还在（各平台登录流程、云盘
// 读取照旧），只是不再拿它决定档位与腿的顺序。

    // MARK: - 歌词（r55 Folia 歌词：服务端回包统一 Folia 字段形
    // {mainText, wordByWordText, translationText, romanizationText,
    // isPureMusic, source}；本平台空时走跨平台自动匹配，顺序
    // 网易 → QQ → 酷狗 → 汽水，10 秒总预算，超时回空，绝不阻塞播放；
    // 酷我/Apple Music 无歌词源，不列入；波点按 Folia 注释不是歌词源，
    // 不列入。纯音乐（isPureMusic）直接回空，不跑自动匹配。
    // 缓存：DiskCache 歌词分支存新字段形 JSON（30 天）；读到旧字段形
    // （无 mainText/wordByWordText）视为无缓存，删掉旧文件后重取。）

    /// 取一首歌的歌词（完整结果，含 format）。缓存 → 本平台 → 跨平台
    /// 自动匹配；仍为空回空 ParsedLyrics（调用方显示歌名，绝不用 ♪
    /// 作假歌词）。YRC 优先，翻译/音译按行起点对齐（LyricsParser）。
    static func lyrics(for track: Track) async -> ParsedLyrics {
        let platform = track.platform
        let key = track.platformKey
        // r48-11：歌词磁盘缓存（30 天 TTL）——官方歌词原文落盘，二次直接读
        // 本地解析，不再调官方接口；官方空时不写（自动匹配结果进缓存）。
        let lyricKey = DiskCache.lyricKey(platform: platform, id: key)
        var skipOfficialFetch = false
        if let cached = DiskCache.data(kind: .lyric, key: lyricKey),
           let raw = try? JSONSerialization.jsonObject(with: cached) as? [String: Any] {
            if raw["mainText"] is String || raw["wordByWordText"] is String {
                let cachedParsed = LyricsParser.parseFolia(
                    mainText: raw["mainText"] as? String ?? "",
                    wordByWordText: raw["wordByWordText"] as? String ?? "",
                    translationText: raw["translationText"] as? String ?? "",
                    romanizationText: raw["romanizationText"] as? String ?? "",
                    isPureMusic: raw["isPureMusic"] as? Bool ?? false)
                if !cachedParsed.lines.isEmpty || cachedParsed.isPureMusic { return cachedParsed }
                // r48-11（自查补）：缓存的官方原文非空、但解析不出行（上游回了
                // 损坏文本）时不直接回空——跳过官方重取（原文已在盘里，重取
                // 还是同一份），直接走下面的跨平台自动匹配，与首次取数同款。
                skipOfficialFetch = true
            } else {
                // 旧字段形缓存（lyric/yrc/tlyric/ytlrc，无 mainText）：
                // 删文件后按无缓存走官方取词（旧文件会触发 skipOfficialFetch、
                // 永远跳过官方重取，所以必须清掉）。
                DiskCache.remove(kind: .lyric, key: lyricKey)
            }
        }
        var d: [String: Any]?
        if !skipOfficialFetch {
            d = await fetchPlatformLyrics(platform: platform, key: key, track: track)
        }
        if let d {
            // 纯音乐直接回空，不跑自动匹配（无词可找，跑了只会浪费
            // 10 秒甚至错配）；纯音乐标记也写盘。
            if d["isPureMusic"] as? Bool == true {
                if let data = try? JSONSerialization.data(withJSONObject: d) {
                    DiskCache.store(data, kind: .lyric, key: lyricKey)
                }
                return ParsedLyrics(lines: [], format: "none", isPureMusic: true)
            }
            let parsed = LyricsParser.parseFolia(
                mainText: d["mainText"] as? String ?? "",
                wordByWordText: d["wordByWordText"] as? String ?? "",
                translationText: d["translationText"] as? String ?? "",
                romanizationText: d["romanizationText"] as? String ?? "")
            // r48-11：官方回了内容才写盘（空结果不写，不缓存「没词」）。
            if !(d["mainText"] as? String ?? "").isEmpty || !(d["wordByWordText"] as? String ?? "").isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: d) {
                DiskCache.store(data, kind: .lyric, key: lyricKey)
            }
            if !parsed.lines.isEmpty { return parsed }
        }
        // 跨平台自动匹配（Folia autoMatchBestLyric 的 Lizi 版）：
        // 本平台取词为空时，按顺序试其他平台；仍为空回空，不阻塞播放。
        if let matched = await autoMatchLyrics(for: track, skipPlatform: platform) {
            DiskCache.store(matched.rawData, kind: .lyric, key: lyricKey)
            return matched.parsed
        }
        return ParsedLyrics(lines: [], format: "none")
    }

    /// 单平台取词：调本平台 /api/*/lyric，返回服务端解析后的字典
    /// （Folia 字段形）；上游空/失败回 nil，不抛错。
    /// 酷我用自己的歌词系统（PC lrcx + H5）；Apple Music 用自己的官方
    /// 歌词（lyrics/syllable-lyrics + user token，TTML 原生解析）；
    /// Spotify 无歌词源，直接回 nil。
    private static func fetchPlatformLyrics(platform: String, key: String, track: Track) async -> [String: Any]? {
        let meta: [String: String] = ["s": track.title, "name": track.title,
                                      "artist": track.artist,
                                      "album": track.album,
                                      "duration": "\(track.durationMs / 1000)"]
        switch platform {
        case "netease": return await call(path: "/api/lyric", query: ["id": key])
        case "qq": return await call(path: "/api/qq/lyric", query: ["mid": key])
        case "qishui": return await call(path: "/api/qishui/lyric", query: ["id": key])
        case "bodian": return await call(path: "/api/bodian/lyric", query: ["id": key])
        case "kuwo": return await call(path: "/api/kuwo/lyric", query: ["id": key])
        case "applemusic": return await call(path: "/api/applemusic/lyric", query: ["id": key])
        case "kugou":
            // 酷狗歌词：hash + 歌名/歌手/专辑/时长（秒），服务端先走
            // Folia 两步（search_lyric → download），KRC 内嵌翻译/音译轨。
            return await call(path: "/api/kugou/lyric",
                              query: ["hash": key].merging(meta) { a, _ in a })
        default: return nil
        }
    }

    /// 跨平台自动匹配：按顺序在其他平台搜歌（取首个匹配）再取词；
    /// 每平台先搜后取，搜不到跳过，不编数据；10 秒总预算，超时回 nil。
    private static func autoMatchLyrics(for track: Track, skipPlatform: String) async -> (rawData: Data, parsed: ParsedLyrics)? {
        let order = ["netease", "qq", "kugou", "qishui"].filter { $0 != skipPlatform }
        let query = "\(track.title) \(track.artist)".trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        return await withTaskGroup(of: (rawData: Data, parsed: ParsedLyrics)?.self) { group in
            group.addTask {
                for platform in order {
                    guard let hit = await search(platform: platform, query: query, limit: 1).tracks.first else { continue }
                    let key = hit.platformKey
                    guard !key.isEmpty else { continue }
                    guard let d = await fetchPlatformLyrics(platform: platform, key: key, track: hit) else { continue }
                    if d["isPureMusic"] as? Bool == true { continue }
                    let parsed = LyricsParser.parseFolia(
                        mainText: d["mainText"] as? String ?? "",
                        wordByWordText: d["wordByWordText"] as? String ?? "",
                        translationText: d["translationText"] as? String ?? "",
                        romanizationText: d["romanizationText"] as? String ?? "")
                    if !parsed.lines.isEmpty,
                       let data = try? JSONSerialization.data(withJSONObject: d) {
                        return (data, parsed)
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            // 先完成的孩子说了算（超时任务先回 nil 就直接回空，
            // 不等搜词任务跑完；搜词先命中就取消超时任务）。
            for await value in group {
                group.cancelAll()
                return value
            }
            return nil
        }
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
    /// - r33：回空根治——网易/QQ/酷狗/酷我主腿空时走推荐歌单合成兜底
    ///   （synthesizedDailyTracks：推荐歌单前 3 张详情并行取、展平、
    ///   「歌名|歌手」小写去重、截 30 条；主腿有数据时不走）；汽水/波点
    ///   无合成腿（Moumusic 无对照），Apple Music 不用（RSS 通）。
    /// - r35-9：每条腿独立 60 秒（dailyTracksTimed / synthesizedDailyTracksTimed，
    ///   套壳每腿 AbortSignal.timeout(60000) 同款），整链再包一层
    ///   dailyChainTimeout（120s）兜底；旧整链 25 秒（dailyTimeout）作废——
    ///   25 秒是 r28 的旧账，单腿最坏 30–80 秒，整链 25 秒掐的是兜底腿
    ///   的命，不是掐慢网。网易主腿 + 兜底腿、QQ 主腿 + 雷达腿用 async let
    ///   并行取，主腿有数据用主腿、主腿空用兜底，耗时取两者最大值
    ///   （主腿 401 未登录时仍走兜底，兜底数据不标成主腿数据写缓存——
    ///   缓存只存曲目 + 空原因，不存腿名，见 HomeDataCache）。
    /// - r28：整链包一层硬超时；超时按空处理，loadDaily 走诚实空态，不留 spinner。
    /// - r33：r31-daily 的“弃子竞速”仍建立在 withTimeout（TaskGroup）
    ///   之上，群组等腿的假设没有实测证据，真机（2026-11-21）7 平台仍
    ///   全部转圈。withTimeout 本身已改成 detached 竞速（见其注释），
    ///   这里不再另起 opTask，直接把整链放进 withTimeout；超时/取消
    ///   120s 一到必回空结果，spinner 必停；被弃的腿留在后台、自己到腿
    ///   超时就停（各腿 60s 都有上限），它只读上游、不写任何 UI 状态。
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
        do {
            return try await withTimeout(seconds: Self.dailyChainTimeout) {
                await dailyRecommendUntimed(platform: platform)
            }
        } catch is CancellationError {
            return DailyResult(tracks: [], emptyReason: nil)
        } catch {
            // 超时（TimeoutError）必走这里：120s 一到即回，不等被弃的腿。
            return DailyResult(tracks: [], emptyReason: "每日推荐拉取超时（120 秒无响应），请检查网络后重试。")
        }
    }

    /// 排行榜目录（r35-10：面板里的排行榜块用；Moumusic 榜单按平台分明，
    /// 只有实现了榜单目录的平台才有榜，没榜的平台老实写没有、不编假榜）。
    /// - 有榜单目录：网易 eapi /toplist、QQ musicu GetAll、酷狗 rank/list、
    ///   酷我 /api/kuwo/rank/list（已有全链路）。各走独立 60 秒预算（r35-9
    ///   同款每腿预算），callSoft 透传非 2xx 错误体，空态带上游原话。
    /// - 没榜单目录：汽水（两端都没有）→「汽水暂无官方排行榜」，不发请求；
    ///   Apple Music（没有榜单目录；公开 RSS 热门歌曲榜已接在每日推荐里，
    ///   不是目录，别冒充）→「Apple Music 暂无官方榜单目录」，不发请求；
    ///   波点（VM 实测 2026-11-21：静态页域名被 DNS 拦到 webblock 页，
    ///   接口不可用）→「波点榜单接口不可用」，不发请求、不硬上。
    /// 回 (boards, emptyReason)：有榜时 emptyReason 为 nil；没榜/拉不到时
    /// emptyReason 是诚实文案（块里只画标题行 + 这句，不隐藏整块）。
    static func rankBoards(platform: String) async -> (boards: [RankBoard], emptyReason: String?) {
        switch platform {
        case "bodian":
            return ([], "波点榜单接口不可用（上游静态榜单页已无法访问）。")
        case "qishui":
            return ([], "汽水暂无官方排行榜。")
        case "applemusic":
            return ([], "Apple Music 暂无官方榜单目录（热门歌曲榜已在每日推荐里）。")
        case "netease", "qq", "kugou", "kuwo":
            break
        default:
            return ([], "该平台暂无排行榜。")
        }
        let displayName = LiziPlatforms.all.first(where: { $0.id == platform })?.name ?? platform
        let path: String
        switch platform {
        case "netease": path = "/api/toplist"
        case "qq": path = "/api/qq/rank/list"
        case "kugou": path = "/api/kugou/rank/list"
        default: path = "/api/kuwo/rank/list"
        }
        let start = Date()
        do {
            let (status, dict) = try await withTimeout(seconds: Self.legTimeout) {
                await callSoft(path: path)
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let code = (dict?["code"] as? NSNumber)?.intValue ?? status
            let boards = ((dict?["playlists"] as? [[String: Any]]) ?? []).compactMap { p -> RankBoard? in
                let id: String
                if let s = p["id"] as? String, !s.isEmpty { id = s }
                else if let n = p["id"] as? NSNumber { id = n.stringValue }
                else { return nil }
                let name = (p["name"] as? String) ?? ""
                guard !name.isEmpty else { return nil }
                let cover = (p["cover"] as? String) ?? ""
                let count = (p["tracks"] as? NSNumber)?.intValue ?? (p["trackCount"] as? NSNumber)?.intValue ?? 0
                return RankBoard(id: id, name: name,
                                 coverURL: cover.isEmpty ? nil : URL(string: cover),
                                 trackCount: count)
            }
            let failed = !(200...299).contains(code)
            DiagLog.shared.recordLog(category: "rank", message: "rank list",
                                     fields: ["platform": platform, "leg": path, "ms": ms,
                                              "count": boards.count, "code": code, "timedOut": false])
            if failed {
                let err = (dict?["error"] as? String) ?? (dict?["message"] as? String) ?? ""
                // r37-7：失败文案按平台隔离——旧写法只写「排行榜目录拉取失败」，
                // 酷我一家 illegal 看着像全平台榜单都挂了。现带平台名，只说
                // 这一家；其它平台榜单是各自独立的 rankBoards 调用，不受影响。
                let reason = err.isEmpty
                    ? "\(displayName)排行榜目录拉取失败（code=\(code)），请检查网络后重试。"
                    : "\(displayName)排行榜目录拉取失败（上游：\(err)）。"
                return ([], reason)
            }
            if boards.isEmpty {
                return ([], "\(displayName)暂未返回排行榜。")
            }
            return (boards, nil)
        } catch {
            DiagLog.shared.recordLog(category: "rank", message: "rank list timeout",
                                     fields: ["platform": platform, "leg": path,
                                              "ms": Int(Self.legTimeout * 1000),
                                              "count": 0, "code": -1, "timedOut": true])
            return ([], "\(displayName)排行榜目录拉取超时（60 秒无响应），请检查网络后重试。")
        }
    }

    /// 推荐歌单合成兜底（r33；只学 Moumusic recommendedContent 的流程，
    /// 不抄代码）：推荐歌单 → 前 3 张歌单详情并行取（playlistAllTracks
    /// 已按平台翻页取全量）→ 曲目展平、按「歌名|歌手」小写去重 → 截 30 条。
    /// 只在主腿回空时由 dailyRecommendUntimed 调用；主腿有数据时不走；
    /// 合成也空时回 []，调用方给诚实空态。
    /// 各平台推荐歌单路由：网易 /api/top/playlist、QQ /api/qq/recommend/playlists、
    /// 酷狗 /api/kugou/top/playlists（壳版精选歌单同款；旧写法 /api/kugou/recommend/playlists
    /// 是 yueku http 端点，壳版根本没有这条路由，且 iOS ATS 会拦掉 http，
    /// 真机上合成腿永远到不了——r34 改走 top/playlists）、酷我 /api/kuwo/recommend/playlists。
    /// 汽水/波点没有合成腿（Moumusic 无对照），Apple Music 不用（RSS 通）。
    private static func synthesizedDailyTracks(platform: String) async -> [DailyTrack] {
        let listPath: String
        switch platform {
        case "netease": listPath = "/api/top/playlist"
        case "qq": listPath = "/api/qq/recommend/playlists"
        case "kugou": listPath = "/api/kugou/top/playlists"
        case "kuwo": listPath = "/api/kuwo/recommend/playlists"
        default: return []
        }
        guard let d = await call(path: listPath, query: ["limit": "3"]) else { return [] }
        let code = (d["code"] as? NSNumber)?.intValue ?? 200
        guard code == 200 else { return [] }
        var ids: [String] = []
        for p in (d["playlists"] as? [[String: Any]] ?? []).prefix(3) {
            if let id = p["id"] as? String, !id.isEmpty { ids.append(id) }
            else if let n = p["id"] as? NSNumber { ids.append(n.stringValue) }
        }
        guard !ids.isEmpty else { return [] }
        var all: [Track] = []
        await withTaskGroup(of: [Track].self) { group in
            for id in ids {
                group.addTask { await playlistAllTracks(platform: platform, id: id) }
            }
            for await tracks in group { all.append(contentsOf: tracks) }
        }
        var seen = Set<String>()
        var out: [DailyTrack] = []
        for t in all where !t.title.isEmpty {
            let key = "\(t.title.lowercased())|\(t.artist.lowercased())"
            guard seen.insert(key).inserted else { continue }
            out.append(DailyTrack(track: t))
            if out.count >= 30 { break }
        }
        return out
    }

    /// 一条每日腿包一层 60 秒独立预算（r35-9，套壳每腿 AbortSignal.timeout(60000)
    /// 同款）：超时按失败腿回（failed = true），不抛错、不拦后面的腿。
    /// 分腿耗时记进诊断日志（P1-4）：平台、腿名、耗时毫秒、结果条数/code/
    /// 是否超时——下次报「拉不到数据」时日志直接写明哪条腿花了多少秒。
    private static func dailyTracksTimed(path: String, query: [String: String] = [:],
                                         platform: String) async -> DailyLeg {
        let start = Date()
        do {
            let leg = try await withTimeout(seconds: Self.legTimeout) {
                await dailyTracks(path: path, query: query, platform: platform)
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            DiagLog.shared.recordLog(category: "daily", message: "daily leg",
                                     fields: ["platform": platform, "leg": path, "ms": ms,
                                              "count": leg.tracks.count, "code": leg.code,
                                              "timedOut": false])
            return leg
        } catch {
            DiagLog.shared.recordLog(category: "daily", message: "daily leg timeout",
                                     fields: ["platform": platform, "leg": path,
                                              "ms": Int(Self.legTimeout * 1000),
                                              "count": 0, "code": -1, "timedOut": true])
            return DailyLeg(tracks: [], unauthorized: false, failed: true, code: -1)
        }
    }

    /// 合成兜底腿包一层 60 秒独立预算（r35-9，P1-2：与 P0-1 一起改，
    /// 否则合成腿在慢网上永远跑不到；超时回 []，调用方走诚实空态）。
    /// 分腿耗时记进诊断日志（P1-4），腿名 "synth"。
    private static func synthesizedDailyTracksTimed(platform: String) async -> [DailyTrack] {
        let start = Date()
        do {
            let tracks = try await withTimeout(seconds: Self.legTimeout) {
                await synthesizedDailyTracks(platform: platform)
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            DiagLog.shared.recordLog(category: "daily", message: "daily leg",
                                     fields: ["platform": platform, "leg": "synth",
                                              "ms": ms, "count": tracks.count,
                                              "code": 200, "timedOut": false])
            return tracks
        } catch {
            DiagLog.shared.recordLog(category: "daily", message: "daily leg timeout",
                                     fields: ["platform": platform, "leg": "synth",
                                              "ms": Int(Self.legTimeout * 1000),
                                              "count": 0, "code": -1, "timedOut": true])
            return []
        }
    }

    /// 每日推荐整链（无超时；dailyRecommend 的超时壳调这里）。
    private static func dailyRecommendUntimed(platform: String) async -> DailyResult {
        switch platform {
        case "netease":
            // r35-9：主腿 + 兜底腿 async let 并行取（各 60 秒独立预算），
            // 耗时取两者最大值；主腿有数据用主腿、主腿空用兜底。
            async let mainLeg = dailyTracksTimed(path: "/api/recommend/songs", platform: platform)
            async let fbLeg = dailyTracksTimed(path: "/api/personalized", platform: platform)
            let main = await mainLeg
            let fallback = await fbLeg
            if !main.tracks.isEmpty { return DailyResult(tracks: main.tracks, emptyReason: nil) }
            if !fallback.tracks.isEmpty { return DailyResult(tracks: fallback.tracks, emptyReason: nil) }
            // r33：主腿 + 推荐新歌都空，走推荐歌单合成兜底（/api/top/playlist 前 3 张）。
            let synth = await synthesizedDailyTracksTimed(platform: platform)
            if !synth.isEmpty { return DailyResult(tracks: synth, emptyReason: nil) }
            if main.unauthorized {
                return DailyResult(tracks: [], emptyReason: withServerMessage("未登录网易云：每日推荐需要登录才能拉取；推荐新歌、推荐歌单合成也没返回内容，请登录网易云后重试，或检查网络。", main))
            }
            if main.failed && fallback.failed {
                return DailyResult(tracks: [], emptyReason: withServerMessage("网易云每日推荐、推荐新歌和推荐歌单合成都请求失败，请检查网络后重试。", main.failed ? main : fallback))
            }
            return DailyResult(tracks: [], emptyReason: nil)
        case "qq":
            // r35-9：主腿 + 雷达腿 async let 并行取（各 60 秒独立预算），
            // 耗时取两者最大值；主腿有数据用主腿、主腿空用兜底。
            async let mainLeg = dailyTracksTimed(path: "/api/qq/user/daily-songs", platform: platform)
            async let fbLeg = dailyTracksTimed(path: "/api/qq/recommend/radar",
                                               query: ["page": "1"], platform: platform)
            let main = await mainLeg
            let fallback = await fbLeg
            if !main.tracks.isEmpty { return DailyResult(tracks: main.tracks, emptyReason: nil) }
            if !fallback.tracks.isEmpty { return DailyResult(tracks: fallback.tracks, emptyReason: nil) }
            // r33：雷达兜底（GetRadarSong）是否真回数据从未验证过——空了就改走
            // 推荐歌单合成腿（/api/qq/recommend/playlists 前 3 张详情）。
            let synth = await synthesizedDailyTracksTimed(platform: platform)
            if !synth.isEmpty { return DailyResult(tracks: synth, emptyReason: nil) }
            if main.unauthorized {
                return DailyResult(tracks: [], emptyReason: withServerMessage("未登录 QQ 音乐：每日推荐需要登录才能拉取；雷达推荐、推荐歌单合成也没返回内容，请登录 QQ 音乐后重试，或检查网络。", main))
            }
            if main.failed && fallback.failed {
                return DailyResult(tracks: [], emptyReason: withServerMessage("QQ 音乐每日推荐、雷达推荐和推荐歌单合成都请求失败，请检查网络后重试。", main.failed ? main : fallback))
            }
            return DailyResult(tracks: [], emptyReason: nil)
        case "qishui":
            let leg = await dailyTracksTimed(path: "/api/qishui/feed",
                                             query: ["count": "20"], platform: platform)
            return DailyResult(tracks: leg.tracks,
                               emptyReason: leg.tracks.isEmpty
                                ? (leg.failed ? withServerMessage("汽水推荐流请求失败，请检查网络后重试。", leg) : "汽水推荐流没有返回内容（汽水音乐需要设备注册/登录，请在设置里登录汽水音乐后重试）。") : nil)
        case "bodian":
            let leg = await dailyTracksTimed(path: "/api/bodian/ai/playlist",
                                             query: ["index": "0"], platform: platform)
            return DailyResult(tracks: leg.tracks,
                               emptyReason: leg.tracks.isEmpty
                                ? (leg.failed ? withServerMessage("波点潮趣日推请求失败，请检查网络后重试。", leg) : "波点潮趣日推没有返回内容（波点需要登录，请在设置里登录波点后重试）。") : nil)
        case "kuwo":
            let leg = await dailyTracksTimed(path: "/api/kuwo/daily", platform: platform)
            if !leg.tracks.isEmpty { return DailyResult(tracks: leg.tracks, emptyReason: nil) }
            // r33：主腿空，走推荐歌单合成兜底（/api/kuwo/recommend/playlists 前 3 张）。
            let synth = await synthesizedDailyTracksTimed(platform: platform)
            if !synth.isEmpty { return DailyResult(tracks: synth, emptyReason: nil) }
            return DailyResult(tracks: leg.tracks,
                               emptyReason: leg.failed ? withServerMessage("酷我每日推荐请求失败，推荐歌单合成也没返回内容，请检查网络后重试。", leg) : "酷我今日没有返回推荐内容（每日推荐与推荐歌单合成都为空）。")
        case "kugou":
            let leg = await dailyTracksTimed(path: "/api/kugou/everyday/recommend", platform: platform)
            if !leg.tracks.isEmpty { return DailyResult(tracks: leg.tracks, emptyReason: nil) }
            // r33：主腿（everyday_song_recommend，先保留）空，走推荐歌单合成兜底
            // （/api/kugou/top/playlists 前 3 张，壳版精选歌单同款；r34：
            // 旧推荐端点是 yueku http，壳版无此路由且真机 ATS 拦 http）。
            let synth = await synthesizedDailyTracksTimed(platform: platform)
            if !synth.isEmpty { return DailyResult(tracks: synth, emptyReason: nil) }
            return DailyResult(tracks: leg.tracks,
                               emptyReason: leg.failed ? withServerMessage("酷狗每日推荐请求失败，推荐歌单合成也没返回内容，请检查网络后重试。", leg) : "酷狗今日没有返回推荐内容（每日推荐与推荐歌单合成都为空）。")
        case "applemusic":
            let leg = await dailyTracksTimed(path: "/api/applemusic/daily", platform: platform)
            return DailyResult(tracks: leg.tracks,
                               emptyReason: leg.tracks.isEmpty
                                ? (leg.failed ? withServerMessage("Apple Music 每日推荐请求失败，请检查网络后重试。", leg) : nil) : nil)
        default:
            return DailyResult(tracks: [], emptyReason: nil)
        }
    }

    /// 每日推荐一行请求的归一化读数（{ tracks } / { data } / { songs }）。
    /// r31-daily：回腿结果不只给曲目——上游 301/401（未登录）与请求失败
    /// （call 回 nil / 包里 code 非 200）要原样带给调用方，空态才能说清
    /// 是没登录还是没网；rows 仍只认 { tracks } / { data } / { songs }，
    /// 不编假数据。code 缺键时按 HTTP 状态算（callSoft 透传；无状态时 200，
    /// 不把无 code 的成功包判失败）。
    /// r35-9：code/errorText 从 callSoft 的体里读（非 2xx 的体以前被 `call`
    /// 直接丢掉，401 也只能报「请求失败」）；errorText 是体里的 error /
    /// message / msg 原话，空态文案缀在后面（见 withServerMessage）。
    private struct DailyLeg {
        var tracks: [DailyTrack]
        /// 上游明确说没登录（包里 code 301/401，如网易 301、QQ 401）。
        var unauthorized: Bool
        /// 请求本身没通（没体）或包里 code 非 2xx/301/401。
        var failed: Bool
        /// 上游回的 code（体里 code 缺键时取 HTTP 状态；没体时 -1）。
        var code: Int
        /// 体里的 error / message / msg 原话（没有时 nil，不编）。
        var errorText: String?

        init(tracks: [DailyTrack], unauthorized: Bool, failed: Bool,
             code: Int = 200, errorText: String? = nil) {
            self.tracks = tracks
            self.unauthorized = unauthorized
            self.failed = failed
            self.code = code
            self.errorText = errorText
        }
    }

    /// 空原因后挂上游原话（r35-9）：腿里带回来的 errorText（体里的 error /
    /// message / msg）有值时缀在文案后，没值时原文案不动，不编。
    private static func withServerMessage(_ base: String, _ leg: DailyLeg) -> String {
        guard let msg = leg.errorText, !msg.isEmpty else { return base }
        return "\(base)（上游：\(msg)）"
    }

    private static func dailyTracks(path: String, query: [String: String] = [:],
                                    platform: String) async -> DailyLeg {
        let (status, d) = await callSoft(path: path, query: query)
        guard let d else {
            return DailyLeg(tracks: [], unauthorized: false, failed: true, code: -1)
        }
        let code = (d["code"] as? NSNumber)?.intValue ?? status
        // r33：多键解析——除 tracks/data/songs 外再扫 list/rows/result/
        // dailySongs/recommend；data 是字典时再往里一层扫
        // list/tracks/songs/recommend/dailySongs（网易 recommend/songs
        // 的 dailySongs 就包在 data 里，normalize 之后仍可能走这条）。
        let nestedRows: [[String: Any]]? = {
            guard let inner = d["data"] as? [String: Any] else { return nil }
            return (inner["list"] as? [[String: Any]])
                ?? (inner["tracks"] as? [[String: Any]])
                ?? (inner["songs"] as? [[String: Any]])
                ?? (inner["recommend"] as? [[String: Any]])
                ?? (inner["dailySongs"] as? [[String: Any]])
        }()
        let rows: [[String: Any]] = (d["tracks"] as? [[String: Any]])
            ?? (d["data"] as? [[String: Any]])
            ?? (d["songs"] as? [[String: Any]])
            ?? (d["list"] as? [[String: Any]])
            ?? (d["rows"] as? [[String: Any]])
            ?? (d["result"] as? [[String: Any]])
            ?? (d["dailySongs"] as? [[String: Any]])
            ?? (d["recommend"] as? [[String: Any]])
            ?? nestedRows ?? []
        let tracks = rows.compactMap { Track.from(dict: $0, platform: platform) }
            .map { DailyTrack(track: $0) }
        return DailyLeg(tracks: tracks,
                        unauthorized: code == 301 || code == 401,
                        failed: !(200...299).contains(code) && code != 301 && code != 401,
                        code: code,
                        errorText: (d["error"] as? String)
                            ?? (d["message"] as? String) ?? (d["msg"] as? String))
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
            if isRank {
                // r35-10：酷狗榜单详情走 /api/kugou/rank/song，page + pagesize 100，
                // 翻到 total 为止，最多 10 页（P1-4；TOP500 = 5 页）。
                var all: [Track] = []
                var total = 0
                for page in 1...10 {
                    guard let d = await call(path: "/api/kugou/rank/song",
                                             query: ["id": id, "limit": "100", "page": "\(page)"]),
                          (d["code"] as? NSNumber)?.intValue == 200 else { break }
                    let rows = (d["tracks"] as? [[String: Any]]) ?? []
                    let tracks = rows.compactMap { Track.from(dict: $0, platform: platform) }
                    all.append(contentsOf: tracks)
                    total = (d["total"] as? NSNumber)?.intValue ?? total
                    if total > 0, all.count >= total { break }
                    if tracks.count < 100 { break }
                }
                return all
            }
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
    /// - 榜单详情（r35-10，isRank=true）：网易榜单 id 即歌单 id，沿用
    ///   playlist/detail；QQ 走 /api/qq/rank/tracks（GetDetail + songId 换
    ///   mid；playlistMeta 不发请求，页头靠 P0-4 的种子）；酷狗不调
    ///   playlist/detail，曲目走 /api/kugou/rank/song 翻页取全量；
    ///   酷我走 /api/kuwo/rank/tracks（无名/封面端点，页头靠种子）。
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
            let path: String
            if platform == "netease" {
                // 榜单 id 即歌单 id，沿用 playlist/detail（normalize 自带
                // trackIds 补全，热歌榜 10 首预览也能拉全）。
                path = "/api/playlist/detail"
            } else if isRank {
                // r35-10：QQ 榜单详情不走歌单 detail（topId 不是歌单 dissid），
                // 走新的 /api/qq/rank/tracks（musicu GetDetail + songId 换 mid）。
                path = "/api/qq/rank/tracks"
            } else {
                path = "/api/qq/playlist/detail"
            }
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
            } else if isRank, platform == "kugou" {
                // r35-10：酷狗榜单详情不调 /api/kugou/playlist/detail
                //（rankid 不是歌单 id）；页头靠 PlaylistDetailViewModel 传入的
                // 榜单名/封面种子（P0-4），曲目走下面的 playlistAllTracks(isRank: true)。
            } else if let d = await call(path: detailPath, query: ["id": id]) {
                pl = playlistFrom(dict: d, platform: platform, id: id)
            }
            // r31：曲目走 playlistAllTracks 翻页取全量（旧实现只取一页 limit 50）。
            pl.tracks = await playlistAllTracks(platform: platform, id: id, isRank: isRank)
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
            if isRank {
                // r35-10：rank id 不是歌单 id，调 playlist/detail 会失败；
                // 页头靠 P0-4 的种子，直接回空 Playlist，不发请求。
                return Playlist(id: id, source: platform)
            }
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
            if isRank {
                // r35-10：rank id 不是歌单 id，调 playlist/detail 会失败；
                // 页头靠 P0-4 的种子，直接回空 Playlist，不发请求。
                return Playlist(id: id, source: platform)
            }
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
        // r37-4（卡片封面适配所有模式）：封面键回落补齐——服务端归一化层
        // 多数已把各家拼写收到 "cover"，但凡有一路字典绕过归一化直达这里
        // （LX 解析行、搜索行、未来新腿），"pic"/"coverUrl"/"img" 就会被
        // 丢掉、卡片回黑底音符占位；只读上游已给的键，不编图。视图层铺满
        // 本来就是对的（六路卡片全是 CoverImageView scaledToFill + 方形
        // frame + 圆角裁切，无拉伸、无留白），缺的是这里少收的键。
        var coverString = (dict["cover"] as? String) ?? ""
        if coverString.isEmpty { coverString = (dict["picUrl"] as? String) ?? "" }
        if coverString.isEmpty { coverString = (dict["pic"] as? String) ?? "" }
        if coverString.isEmpty { coverString = (dict["coverUrl"] as? String) ?? "" }
        if coverString.isEmpty { coverString = (dict["img"] as? String) ?? "" }
        if coverString.isEmpty { coverString = (dict["albumpic"] as? String) ?? "" }
        if coverString.isEmpty, let a = dict["album"] as? [String: Any] {
            coverString = (a["picUrl"] as? String) ?? ""
        }
        if coverString.isEmpty, let a = dict["album"] as? [String: Any] {
            coverString = (a["pic"] as? String) ?? ""
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
