import CryptoKit // r49: urlHash 用 SHA256
import Foundation

/// /api/img 图片代理 + 各平台音频代理。
/// 对标 server.mjs 的 proxyImage / proxySourceAudio / proxyQQAudio。
/// 只放行 AUDIO_HOSTS 白名单里的 CDN 域名，别把口子开成任意 SSRF。

/// 封面取图并发门（r24 新写）：同一时刻最多 4 个上游取图在跑，FIFO 排队。
/// 根因（2026-11-20 08:30 真机诊断 + 本轮核对）：首页各轨全是普通 HStack
/// （非 Lazy），一屏几十张封面同时起取图，全涌进 URLSession.shared；
/// 共享会话单 host 默认只开 6 连接，排队请求在会话队列里空等，而空闲超时
/// 从 resume 那一刻就开始计时——尾部请求还没拿到连接就 -1001，再乘旧实现
/// 的 2 候选 × 2 重试 = 每张图 20003ms 成批死，http 腿再补一个 -1022。
/// 门把并发压到 4（< 6，会话内永不排队），排队发生在 Swift 侧、不进
/// URLSession 的超时计时；每个开始跑的请求都有完整超时可用。
/// r49：门等加 6s 硬上限 + 32 排队上限（见下），等槽超时/队满直接失败，
/// 不再无限等（门等期间超时计时根本没开始，20–30 张冷封面排队即 40–56s）。
/// r50：上面这套「队满当场拒」正是 2026-11-23 03:48 真机门风暴的死法——
/// 酷狗列表一开 50 张封面 22ms 内同时进门，4 槽 + 32 队只接纳 36 个，
/// 剩下的 gateWait=0 当场全拒，且 CoverImageLoader 的 60s 否定缓存把
/// 「没试过」当成「试过且失败」又罚 60 秒。r50 改成：队满不再当场拒，
/// 改为 FIFO 排队等槽、等槽总预算 36s（见 gateWaitTimeout）；等槽超时
/// 仍是「没试过」，调用方不得记否定缓存（见 CoverImageLoader）。
/// VM 证据：单发 curl p3/p4.music.126.net https 全部 200（首字节 1.5–1.7s），
/// 端点本身是好的；Referer 也已排除（无 Referer 同样 200，错 Referer 只会
/// 快 403、不会 10s 超时）。VM 通 ≠ 真机通：真机出口若另有拦截，快速失败 +
/// 占位，下次诊断凭新日志的 ms / code 再分。

/// r49: 门等待失败原因（与上游 -1001 区分的内部码；proxyImage 对其直接 502，
/// 不进会话——门等期间会话任务根本还没创建）。
enum CoverFetchGateError: Error, LocalizedError {
    /// r50：保留作兼容——acquire 不再抛它（队满改排队等槽，见下），
    /// 现实中不再产生 gate-queue-full 日志；proxyImage 的 gate 分支
    /// 仍认这个 case，以防将来恢复队满路径时日志原因不断。
    case queueFull
    /// 等槽超过总预算（r50：36s）。
    case gateTimeout
    var errorDescription: String? {
        switch self {
        case .queueFull: return "cover fetch gate queue full"
        case .gateTimeout: return "cover fetch gate timeout (36s)"
        }
    }
}

/// r49: 门内失败也带等槽毫秒数——run 抛错时调用方 catch 里也能读到真实
/// gateWaitMs（旧代码只在成功路径拷 waitMs，失败日志 gateWait 恒为 0）。
struct CoverFetchError: Error {
    let underlying: Error
    let waitMs: Int
}

actor CoverFetchGate {
    static let shared = CoverFetchGate()
    static let maxConcurrent = 4
    /// r50：等槽总预算 36s（r49 是 6s + 32 队满当场拒）。
    /// 算账：burst 50 张封面 / 4 槽 × 单张取图约 1.5–2s ≈ 19–25s，
    /// 36s 让尾部排队者也能等到槽；不是「把 32 改大」——队满当场拒
    /// 已删，排队长度不再设限、只限等待时间（每 waiter 一个 36s
    /// 超时任务，到时摘队抛 gateTimeout）。超时仍是「没试过」，
    /// 调用方不得记否定缓存、可重试（见 CoverImageLoader）。
    static let gateWaitTimeout: TimeInterval = 36
    // r50：maxWaiters 已删——r49 的 32 队满当场拒就是门风暴的根因，
    // 排队本身只是一个挂起的 continuation，代价极小；上限改由
    // gateWaitTimeout 的时间预算承担。
    private var running = 0
    private var waiters: [Waiter] = []

    /// r49: 排队中的一次等槽：超时任务按 id 摘 waiter（CheckedContinuation
    /// 二次 resume 会 trap，摘掉才 resume；release 叫醒的已不在队里，
    /// 超时任务按 id 找不到、直接忽略）。
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// 在门内跑一次取图：拿槽 → 跑 work → 还槽（work 抛错/取消也还）。
    /// 返回取图结果 + 等槽毫秒数（诊断用：总 ms 大而 waitMs 小 = 上游 stalls；
    /// waitMs 大 = 首页并发把门堵了）。
    /// r49: 拿槽失败（超时/取消）也把已等毫秒数包在 CoverFetchError 里
    /// 抛出去——旧代码只在成功路径拷 waitMs，run 一抛错调用方 catch 里的
    /// gateWaitMs 恒为 0。
    func run<T>(_ work: () async throws -> T) async throws -> (value: T, waitMs: Int) {
        let t0 = Date()
        let waitMs: Int
        do {
            try await acquire()
            waitMs = Int(Date().timeIntervalSince(t0) * 1000)
        } catch {
            throw CoverFetchError(underlying: error, waitMs: Int(Date().timeIntervalSince(t0) * 1000))
        }
        defer { release() }
        do {
            let value = try await work()
            return (value, waitMs)
        } catch {
            throw CoverFetchError(underlying: error, waitMs: waitMs)
        }
    }

    /// r49: 拿一个取图槽；等槽期间被取消抛 CancellationError（调用方不跑取图，
    /// 有槽就还槽）；等槽超 36s 抛 gateTimeout。
    /// r50：删掉 r49 的「waiters 满 32 直接抛 queueFull」——burst 下队满
    /// 当场拒就是 03:48 风暴（50 连拒、gateWait=0）。现在队满只排队，
    /// FIFO 先到先得（列表自上而下创建视图，到达顺序 ≈ 可见顺序，
    /// 真正的可见优先需要调用方传优先级，那是调用方改动、本件不做，
    /// 见回报）；排空只靠 release（每完成一张唤醒队首），与 r49 相同。
    private func acquire() async throws {
        if running < Self.maxConcurrent {
            running += 1
            return
        }
        // r50: 不再设队满上限，直接进队等槽（36s 总预算，见 gateWaitTimeout）。
        let acquired = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let id = UUID()
            waiters.append(Waiter(id: id, continuation: continuation))
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(Self.gateWaitTimeout * 1_000_000_000))
                await CoverFetchGate.shared.timeOutWaiter(id: id)
            }
        }
        // 等槽期间被取消：拿到槽就还槽，没拿到（超时）本来就没槽；一律按取消走。
        if Task.isCancelled {
            if acquired { release() }
            throw CancellationError()
        }
        guard acquired else { throw CoverFetchGateError.gateTimeout }
    }

    /// r49: 门等超时——还在队里的 waiter 摘掉并以 false 叫醒（acquire 抛
    /// gateTimeout）；已被 release 叫醒的不在队里，直接忽略。
    private func timeOutWaiter(id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: idx)
        waiter.continuation.resume(returning: false)
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.continuation.resume(returning: true)
        } else {
            running -= 1
        }
    }
}

enum Proxies {
    /// 各源音频 CDN 白名单（server.mjs 的 AUDIO_HOSTS 原样搬过来）。
    /// r24 Folia 酷狗移植：`kugou` 行必须留——Folia 的 song_url 回的直链
    /// 落在 .kugou.com / .kglink.com，`/api/kugou/audio` 代理靠它放行；
    /// `bodian` 行里的 .kugou.com 也留（波点曲目可能挂酷狗图床/音频域）；
    /// `audioReferer["kugou"]` 与图片代理的 .kugou.com 同理（封面走
    /// imge.kugou.com，Referer 发 www.kugou.com）。
    static let audioHosts: [String: [String]] = [
        // 域名后缀匹配：".kugou.com" 匹配 xxx.kugou.com
        "kugou": [".kugou.com", ".kgmusic.cn", ".kglink.com", ".kugou.com.cn"],
        "qishui": [".365yg.com", ".douyinvod.com", ".byteicdn.com", ".pstatp.com", ".douyinpic.com", ".snssdk.com"],
        "bodian": [".kuwo.cn", ".kugou.com", ".bodian.com"],
        "kuwo": [".kuwo.cn", ".kuwo.com"],
        "spotify": [],
        "netease": [".music.126.net"],
        // QQ 用 proxyQQAudio 同款白名单（见下方 qqAudioHosts）。
        "qq": [],
        // 落雪：解析出的地址来自各家 CDN（server.mjs 的 AUDIO_HOSTS.lx）。
        // 自定义源时代静态白名单兜不住：脚本会返回任意 CDN（长青海棠网、
        // 环音、聚合的 IP 直连……），白名单一拦就 403、播不出声。
        // lx 代理只放行 http/https（上面已校验），不限域名：本地服务只绑
        // 127.0.0.1，只有本 App 自己能调；脚本本身走 lx.request 也能任意
        // 拉取，白名单对 lx 没有实际防护意义。其它平台的白名单保持不变。
        "lx": [],
    ]

    /// QQ 音频代理的域名白名单（server.mjs 的 proxyQQAudio：/(^|\.)qq\.com$/i，仅腾讯域名）。
    static func qqHostAllowed(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "qq.com" || h.hasSuffix(".qq.com")
    }

    static let audioReferer: [String: String] = [
        "kugou": "https://www.kugou.com/",
        "qishui": "",
        "bodian": "https://www.bodian.com/",
    ]

    private static func hostAllowed(_ host: String, suffixes: [String]) -> Bool {
        let h = host.lowercased()
        return suffixes.contains { h == $0.dropFirst() || h.hasSuffix($0) }
    }

    /// 单次取图上限（秒，r24 新写）：VM 实测网易 CDN 首字节 1.5–1.7s，
    /// 6s 是 3.5 倍余量，仍比旧的 10s 短；配合“只取一次、不重试”，
    /// 代理腿最坏 6s（旧 40s）。
    private static let imageFetchTimeout: TimeInterval = 6

    /// 封面专用会话（r24 新写）：与 URLSession.shared 分池——音频/API 流量
    /// 不再和封面抢同一批连接；请求空闲 6s、整程 8s（数据细流也不许无限拖）；
    /// 单 host 6 连接是系统默认值，这里写明：真正限流的是 CoverFetchGate，
    /// 不是会话。
    private static let imageSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.httpMaximumConnectionsPerHost = 6
        // r49: 挂轻量 metrics delegate（只采失败请求的段耗时，见下）；
        // URLSession 强持 delegate，会话静态常驻、无需另行持有。
        return URLSession(configuration: config, delegate: ImageSessionMetricsDelegate(), delegateQueue: nil)
    }()

    /// r49: 失败日志用的 URL 指纹——整条 URL 的 SHA256 前 8 位，只记指纹、不记完整 URL。
    private static func urlHash(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    /// r49: 墙钟总闸超时（与 -1001 区分的内部错；proxyImage 按
    /// proxy-wallclock-timeout 记原因）。
    private enum ImageFetchWallClockError: Error, LocalizedError {
        case timedOut
        var errorDescription: String? { "image fetch wall-clock timeout (6s)" }
    }

    /// r49: 会话调用墙钟总闸——data 任务与 6s 睡眠竞速；谁先完就以谁为准，
    /// 另一路 group.cancelAll() 取消到底（URLSession 的 async API 收到取消会
    /// 取消底层 URLSessionTask，不是调用方不等了、任务还在跑）。
    /// 6s 与 imageFetchTimeout 同值：r50 门等总预算 36s + 会话 6s，单次
    /// proxyImage 最坏 ≈ 42s（r49 是 12s），且失败原因可按段区分
    /// （gate-timeout / wallclock / -1001）。42s 只发生在 burst 尾部
    /// 排队时，单张冷封面仍是 6s 会话上限；队空自动补试靠调用方重试
    /// （否定缓存不再罚 gate 失败，见 CoverImageLoader）。
    private static func fetchWithWallClock(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await imageSession.data(for: request) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(imageFetchTimeout * 1_000_000_000))
                throw ImageFetchWallClockError.timedOut
            }
            do {
                guard let first = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// r49: 封面会话轻量 metrics 采（URLSessionTaskDelegate）：只在任务失败时
    /// （task.error != nil）把最后一次 transaction 的 DNS/连接/响应段耗时写进
    /// DiagLog；成功请求不记。只实现 didFinishCollecting，不碰重定向/鉴权等
    /// 回调，不改变会话行为。DiagLog.recordLog 自带 NSLock，delegate 队列调也安全。
    private final class ImageSessionMetricsDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard let error = task.error else { return }
            let last = metrics.transactionMetrics.last
            func ms(_ start: Date?, _ end: Date?) -> Int {
                guard let start, let end else { return -1 }
                return max(0, Int(end.timeIntervalSince(start) * 1000))
            }
            let dnsMs = ms(last?.domainLookupStartDate, last?.domainLookupEndDate)
            let connectMs = ms(last?.connectStartDate, last?.connectEndDate)
            let responseMs = ms(last?.responseStartDate, last?.responseEndDate)
            let host = task.originalRequest?.url?.host ?? ""
            let code = (error as NSError).code
            DiagLog.shared.recordLog(category: "cover",
                message: "img metrics host=\(host) code=\(code) dns=\(dnsMs)ms connect=\(connectMs)ms response=\(responseMs)ms",
                fields: ["host": host, "reason": "img-metrics", "code": code, "lane": "proxy",
                         "dnsMs": dnsMs, "connectMs": connectMs, "responseMs": responseMs])
        }
    }

    /// 封面 URL 入口 https 归一（r24 新写）：只换 scheme，不换 host。
    /// 真机 ATS 下 http 永远 -1022，升上去是唯一能成的路；https 原样过。
    /// 各家上游原样返回的封面多是 http（网易 picUrl、QQ 部分 pic 字段），
    /// 归一放在入口，各调用点不再各自升级——模型层（NativeBridge 等数据链）
    /// 一个字不动。
    static func upgradedImageURL(_ url: URL) -> URL {
        guard url.scheme == "http" else { return url }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.scheme = "https"
        return comps?.url ?? url
    }

    /// 直链腿唯一入口（r24 新写）：CoverImageLoader / 岛 / 锁屏 / 舞台主色共用。
    /// 旧写法各处 `URLSession.shared.data(from:)`：默认 60s 空闲超时、7 天总
    /// 上限、无并发门——代理 40s 死透后直链再等 60s，一张图最坏 100s 才占位。
    /// 新写法：入口 https 归一 → 同一个门、同一个 6s 会话、带各家 Referer/UA；
    /// 任何失败回 nil（调用方占位），不抛错。
    /// r50：签名不动（NowPlayingCoordinator / StageBridge 也在调，改签名
    /// 要动调用方）；新增 directImageDataDetailed 供 CoverImageLoader 用，
    /// 区分「门等失败（没试过）」与「真取失败」，否定缓存只罚后者。
    static func directImageData(_ url: URL) async -> Data? {
        await directImageDataDetailed(url).data
    }

    /// r50：directImageData 的带原因版。gateFailed=true 表示等槽超时、
    /// 连网都没碰（CoverFetchGateError），调用方不得记否定缓存；
    /// gateFailed=false 的 nil 是真取失败（上游 4xx/5xx、超时、坏数据）。
    static func directImageDataDetailed(_ url: URL) async -> (data: Data?, gateFailed: Bool) {
        let fetchURL = upgradedImageURL(url)
        guard let host = fetchURL.host else { return (nil, false) }
        var request = URLRequest(url: fetchURL, timeoutInterval: imageFetchTimeout)
        let ref = imageReferer(host)
        if !ref.isEmpty {
            request.setValue(ref, forHTTPHeaderField: "Referer")
        }
        request.setValue(imageUA, forHTTPHeaderField: "User-Agent")
        do {
            let fetched = try await CoverFetchGate.shared.run {
                // r49: 墙钟总闸（见 fetchWithWallClock）：6s 竞速，超时取消到底层任务。
                try await fetchWithWallClock(request)
            }
            let (data, resp) = fetched.value
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return (nil, false) }
            return (data, false)
        } catch {
            // r50: 门等失败与真取失败分开——run 抛出的 CoverFetchError
            // 里包着 CoverFetchGateError 时就是「没试过」。
            if let wrapped = error as? CoverFetchError,
               wrapped.underlying is CoverFetchGateError {
                return (nil, true)
            }
            return (nil, false)
        }
    }

    /// /api/img?url=：封面代理（绕开防盗链）。
    /// 白名单、上限、重定向再校验均按规格文档 §7.1。
    /// r24 重写（根因：2026-11-20 08:30 真机诊断 + 本轮核查）——旧实现
    /// （http→https 候选 × 每候选重试 2 次 × 10s）整段删除，不是改数：
    /// https 腿在真机上 10s 超时 ×2 = 20003ms，http 腿 ATS -1022 秒拦；
    /// VM 单发同款 URL 全部 200，Referer 也已排除（见 CoverFetchGate 注释）。
    /// 新逻辑：入口一次升 https → 门（最多 4 并发，r50：队满排队等槽、
    /// 总预算 36s，不再当场拒）→ 单次取图 6s → 失败立刻
    /// 502，不重试、不回退 http。代理腿最坏 6s（旧 40s）。
    /// 保留：取消（-999）回 499 不重试（r20 的修法）；上游 HTTP 错误
    /// （403/404）不重试、直接 502；Content-Type 与 10MB 上限。
    static func proxyImage(_ req: HttpRequest) async -> HttpResponse {
        guard let raw = req.query["url"], let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https" else {
            return .error(400, "bad url")
        }
        guard let host = url.host, imageHostAllowed(host) else {
            // 第 15 轮第 1 件：白名单 403 原来是静默 return，Apple Music 封面
            // 全死在这里、诊断里一行都没有；现在记一条，下次报告能看到 host。
            DiagLog.shared.recordLog(category: "cover",
                message: "img proxy 403 host not allowed: \(url.host ?? "")",
                fields: ["host": url.host ?? "", "reason": "proxy-host-not-allowed", "code": 403, "lane": "proxy"])
            return .json(403, ["error": "host not allowed"])
        }
        let fetchURL = upgradedImageURL(url)
        let started = Date()
        var gateWaitMs = 0
        do {
            var request = URLRequest(url: fetchURL, timeoutInterval: imageFetchTimeout)
            let ref = imageReferer(host)
            if !ref.isEmpty {
                request.setValue(ref, forHTTPHeaderField: "Referer")
            }
            request.setValue(imageUA, forHTTPHeaderField: "User-Agent")
            let fetched = try await CoverFetchGate.shared.run {
                // r49: 墙钟总闸（见 fetchWithWallClock）：6s 竞速，超时取消到底层任务。
                try await fetchWithWallClock(request)
            }
            gateWaitMs = fetched.waitMs
            let (data, resp) = fetched.value
            guard let http = resp as? HTTPURLResponse else {
                return .error(502, "no http response")
            }
            // 跟随重定向后，再校验一次最终 URL 的 host。
            if let finalURL = http.url, let finalHost = finalURL.host, !imageHostAllowed(finalHost) {
                DiagLog.shared.recordLog(category: "cover",
                    message: "img proxy 403 redirect host not allowed: \(host) -> \(finalHost)",
                    fields: ["host": finalHost, "reason": "proxy-redirect-host-not-allowed", "code": 403, "lane": "proxy"])
                return .json(403, ["error": "redirect host not allowed"])
            }
            // 先判状态再判 Content-Type：上游 403 常回 HTML 错误页，旧代码
            // 会报 415「not an image」，掩盖真实原因；现在直接记上游状态。
            guard (200..<300).contains(http.statusCode) else {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                // r49: 上游状态失败日志也补 urlHash / gateWaitMs / sessionMs 分段字段。
                let sessionMs = max(0, ms - gateWaitMs)
                let hash = urlHash(fetchURL)
                DiagLog.shared.recordLog(category: "cover",
                    message: "img proxy \(host) upstream HTTP \(http.statusCode) (\(ms)ms gateWait=\(gateWaitMs)ms session=\(sessionMs)ms urlHash=\(hash))",
                    fields: ["host": host, "reason": "proxy-status-\(http.statusCode)", "code": http.statusCode, "lane": "proxy", "urlHash": hash, "gateWaitMs": gateWaitMs, "sessionMs": sessionMs])
                return .error(502, "上游 \(host) 返回 HTTP \(http.statusCode)")
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
            guard contentType.hasPrefix("image/") else {
                return .json(415, ["error": "not an image"])
            }
            if data.count > 10 * 1024 * 1024 {
                return .json(413, ["error": "image too large"])
            }
            return HttpResponse(status: http.statusCode, headers: [
                "Content-Type": contentType,
                "Cache-Control": "public, max-age=86400",
            ], body: data)
        } catch {
            // r49: run 抛错也带 gateWaitMs——先拆 CoverFetchError 的包装
            // （旧代码 gateWaitMs 只在成功路径赋值，失败日志恒为 0）。
            var rootError = error
            if let wrapped = error as? CoverFetchError {
                gateWaitMs = wrapped.waitMs
                rootError = wrapped.underlying
            }
            // 第 20 轮：任务被取消（-999，调用方导航走了 / 视图没了 / 连接断了）
            // 不是失败：不重试、不记日志，立刻回 499。注意：URLSession 的 async API 在
            // 这里漏出的是原始 NSURLError -999，不是 CancellationError，
            // 两边都要认。
            if rootError is CancellationError || (rootError as NSError).code == NSURLErrorCancelled {
                return .error(499, "cancelled")
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let sessionMs = max(0, ms - gateWaitMs)
            let hash = urlHash(fetchURL)
            // r49: 门等失败（r50 起只有超时）直接 502，不进会话——门等期间会话
            // 任务根本还没创建，与 -1001 是两回事，原因可区分。
            if let gateError = rootError as? CoverFetchGateError {
                let reason = gateError == .gateTimeout ? "gate-timeout" : "gate-queue-full"
                DiagLog.shared.recordLog(category: "cover",
                    message: "img proxy \(host) gate failed (\(ms)ms gateWait=\(gateWaitMs)ms session=\(sessionMs)ms urlHash=\(hash) reason=\(reason))",
                    fields: ["host": host, "reason": reason, "lane": "proxy", "urlHash": hash, "gateWaitMs": gateWaitMs, "sessionMs": sessionMs])
                // r50：门等失败打上进程内标记头——这是「没试过」，不是上游失败；
                // CoverImageLoader 认这个头：不记否定缓存、不再白白跑直链腿
                // （直链走同一个门，burst 下同样要排队）。body 与旧 .error
                // 一致，对 Router / NowPlayingCoordinator 的行为不变。
                var resp = HttpResponse.error(502, rootError.localizedDescription)
                resp.headers["X-Lizi-Gate-Failed"] = reason
                return resp
            }
            let code = (rootError as NSError).code
            // r49: 墙钟总闸超时与普通上游失败原因分开记（-1001 之外的新码）。
            let reason = rootError is ImageFetchWallClockError ? "proxy-wallclock-timeout" : "proxy-error"
            DiagLog.shared.recordLog(category: "cover",
                message: "img proxy \(host) fetch failed (\(ms)ms gateWait=\(gateWaitMs)ms session=\(sessionMs)ms urlHash=\(hash) code=\(code)): \(rootError.localizedDescription)",
                fields: ["host": host, "reason": reason, "lane": "proxy", "urlHash": hash, "gateWaitMs": gateWaitMs, "sessionMs": sessionMs])
            return .error(502, rootError.localizedDescription)
        }
    }

    private static let imageHostsExact: Set<String> = [
        "p1.music.126.net", "p2.music.126.net", "p3.music.126.net",
        "p4.music.126.net", "p5.music.126.net", "p6.music.126.net",
        "y.gtimg.cn", "music-file.y.qq.com", "qpic.y.qq.com", "i.scdn.co",
    ]
    private static let imageHostSuffixes = [
        ".music.126.net", ".kugou.com", ".douyinpic.com", ".douyincdn.com", ".huoshanimg.com",
        ".kuwo.cn", ".scdn.co", ".spotifycdn.com", ".y.qq.com", ".qlogo.cn", ".qpic.cn",
        // 第 15 轮第 1 件：Apple Music 封面 host is1-ssl.mzstatic.com
        // （artworkUrl100 换 600x600bb.jpg，AppleMusic.swift:165/258/271）。
        // 白名单里没有它时每张 AM 封面走代理必回 403；直连实测 200，
        // 是白名单漏了，不是 URL 坏。七平台同步：这是平台无关的封面代理，
        // 不是只给 Apple Music 开的口子（后缀匹配，其它 mzstatic 子域同理）。
        ".mzstatic.com",
    ]

    private static func imageHostAllowed(_ host: String) -> Bool {
        let h = host.lowercased()
        if imageHostsExact.contains(h) { return true }
        return imageHostSuffixes.contains { h.hasSuffix($0) }
    }

    /// 封面代理的完整浏览器 UA：裸 "Mozilla/5.0" 在个别 CDN 边缘节点会被当成
    /// 非浏览器流量；发完整 UA 更稳。
    private static let imageUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// 各家封面 CDN 的 Referer（第 6 轮）：旧代码不管哪家都发 music.163.com，
    /// 对酷狗/QQ/酷我属于外站 Referer，个别边缘节点会按防盗链拦掉。
    /// 本机 curl 上四家 Referer 全回 200（见轮次报告），但边缘节点行为可能
    /// 按地域不同，这里按各家官网发；返回 "" 表示不发 Referer（空 Referer 各家都放行）。
    private static func imageReferer(_ host: String) -> String {
        let h = host.lowercased()
        if h.hasSuffix(".music.126.net") { return "https://music.163.com/" }
        if h.hasSuffix(".kugou.com") { return "https://www.kugou.com/" }
        if h == "y.gtimg.cn" || h.hasSuffix(".y.qq.com") || h.hasSuffix(".qpic.cn")
            || h.hasSuffix(".qlogo.cn") || h == "music-file.y.qq.com" || h == "qpic.y.qq.com" {
            return "https://y.qq.com/"
        }
        if h.hasSuffix(".kuwo.cn") || h.hasSuffix(".kuwo.com") { return "https://www.kuwo.cn/" }
        return ""
    }

    /// 2xx 回包的音频校验：上游对坏地址有时回 200 + HTML 错误页（被截断的
    /// PHP 地址、过期 vkey 的 403 页），原样透传给 <audio> 只会让播放器
    /// 解码失败、界面静默无声。2xx 时要求 Content-Type 是音频（audio/*、
    /// video/*、application/octet-stream——酷狗 FLAC 就回这个；206 分片
    /// 缺 Content-Type 也认），且正文非空；否则返回错误文案，由调用方
    /// 换 502 让播放器快速失败、走平台备用重试。非 2xx 原样透传不动。
    /// 兜底（2026-11-18 实测）：Content-Type 不可信时看文件头——QQ 试听
    /// aqqmusic.tc.qq.com 把真 MP3 标成 application/x-www-form-urlencoded
    /// （正文 FF FB 帧同步）；小分片（iOS AVFoundation 常先发 Range:
    /// bytes=0-1 探针，2 字节无法嗅探）看 URL 后缀，且 CT 不是错误页
    /// 类型（text/*、json、xml）时才放行。
    private static func audioBodyError(status: Int, data: Data, contentType: String?, url: URL?) -> String? {
        guard (200..<300).contains(status) else { return nil }
        if data.isEmpty { return "上游返回空音频（HTTP \(status)）" }
        let ct = (contentType ?? "").lowercased()
        let audioCT = ct.hasPrefix("audio/") || ct.hasPrefix("video/")
            || ct == "application/octet-stream" || ct == "binary/octet-stream"
        if !audioCT && !(status == 206 && ct.isEmpty) {
            if looksLikeAudio(data) != nil { return nil }
            if let url, audioExtensionMIME(url) != nil,
               !ct.hasPrefix("text/") && !ct.contains("json") && !ct.contains("xml") {
                return nil
            }
            return "上游返回的不是音频（HTTP \(status)，Content-Type: \(ct.isEmpty ? "缺失" : ct)）"
        }
        return nil
    }

    /// 文件头嗅探：返回嗅到的音频 MIME，嗅不到返回 nil。
    /// MP3（ID3 或 FF Ex 帧同步）、FLAC（fLaC）、MP4/M4A（ftyp）、OGG（OggS）。
    private static func looksLikeAudio(_ data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33 { return "audio/mpeg" }
        if b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 { return "audio/mpeg" }
        if b[0] == 0x66 && b[1] == 0x4C && b[2] == 0x61 && b[3] == 0x43 { return "audio/flac" }
        if b.count >= 8 && b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 { return "audio/mp4" }
        if b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53 { return "audio/ogg" }
        return nil
    }

    /// 按 URL 后缀给 MIME（小分片探针用）。
    private static func audioExtensionMIME(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "ogg", "oga": return "audio/ogg"
        case "wav": return "audio/wav"
        default: return nil
        }
    }

    /// 下行 Content-Type：上游已是音频 CT 就原样透传；否则用嗅探结果，
    /// 嗅不到（小分片）用 URL 后缀，再不行才用上游原值。
    private static func outgoingAudioContentType(data: Data, url: URL, upstreamCT: String?) -> String {
        let ct = (upstreamCT ?? "").lowercased()
        if ct.hasPrefix("audio/") || ct.hasPrefix("video/")
            || ct == "application/octet-stream" || ct == "binary/octet-stream" {
            return upstreamCT ?? "audio/mpeg"
        }
        return looksLikeAudio(data) ?? audioExtensionMIME(url) ?? upstreamCT ?? "audio/mpeg"
    }

    /// 音频代理的单次 Range 上限（2MB，第 11 轮第 8/9 件）：
    /// 播放器（Chromium / AVFoundation）常发 bytes=0- 这种不封口的 Range；
    /// 旧代码原样透传，Upstream.fetch（data(for:) 整段缓冲）会把整首歌
    /// （master FLAC 常 100MB+）下完才回包——VM 上 12 秒、手机弱网下超
    /// 30 秒超时 → 502 → 播放器报 code=4（00:17/00:19 三首歌全是这个死法）。
    /// 这里把 Range 截成 ≤2MB 的闭区间；无 Range 时注入 bytes=0-2MB-1。
    /// 上游回 206 + Content-Range，播放器按需再要下一段，首字节几秒内就到。
    /// 各家 CDN 都认 Range（VM 实测 QQ/网易/酷狗/酷我/汽水全回 206）。
    private static let audioRangeCap = 2 * 1024 * 1024

    /// 见 audioRangeCap 注释：只处理最常见的 bytes=<start>-<end?> 形；
    /// 解析失败（多段 Range、后缀 Range 等罕见形状）原样透传，不乱改。
    private static func cappedRangeHeader(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "bytes=0-\(audioRangeCap - 1)" }
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("bytes=") else { return raw }
        let body = String(s.dropFirst("bytes=".count))
        let parts = body.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(String(parts[0])) else { return raw }
        if parts[1].isEmpty {
            return "bytes=\(start)-\(start + audioRangeCap - 1)"
        }
        guard let end = Int(String(parts[1])) else { return raw }
        if end - start + 1 > audioRangeCap {
            return "bytes=\(start)-\(start + audioRangeCap - 1)"
        }
        return raw
    }

    /// 音频代理拉上游失败时留痕（第 11 轮第 8/9 件）：原来 catch / 502 只回状态，
    /// 诊断里只有播放器侧的 code=4，分不清是上游 DNS 挂了、超时、403 还是 502。
    /// 只记主机 + 状态/原因，不记完整直链（LX 直链可能含 key）。
    private static func recordAudioProxyFailure(source: String, host: String, reason: String) {
        DiagLog.shared.recordPlaybackStep("\(source) audio FAIL host=\(host) \(reason)")
        DiagLog.shared.recordLog(category: "audio",
            message: "音频代理拉上游失败：source=\(source) host=\(host) \(reason)",
            fields: ["host": host, "reason": "proxy-upstream", "lane": "proxy"])
    }

    /// /api/<source>/audio?url=：音频代理，转发 Range，返回上游状态码原样。
    /// 第 12 轮：拉上游之前先把 http 升成 https（Upstream.upgradedAudioURL，
    /// 与前端同一张表）——代理是直链失败后的兜底，兜底自己不能再死在 ATS -1022
    /// 上。白名单校验仍用原始 host（升级只换 scheme，不换 host）。
    static func proxySourceAudio(_ req: HttpRequest, source: String) async -> HttpResponse {
        guard let raw = req.query["url"], let url = Upstream.url(from: raw),
              let host = url.host,
              (url.scheme == "http" || url.scheme == "https") else {
            return .error(400, "bad url")
        }
        let fetchURL = Upstream.upgradedAudioURL(url)
        let allow: [String]
        if source == "qq" {
            // QQ 走独立实现（proxyQQAudio）：仅腾讯域名，Referer https://y.qq.com/。
            guard qqHostAllowed(host) else {
                return .json(403, ["error": "host not allowed"])
            }
            var headers: [String: String] = ["User-Agent": "Mozilla/5.0", "Referer": "https://y.qq.com/"]
            headers["Range"] = cappedRangeHeader(req.headers["range"])
            do {
                let (data, http) = try await Upstream.fetch(fetchURL, headers: headers, timeout: 30)
                if !(200..<300).contains(http.statusCode) {
                    recordAudioProxyFailure(source: source, host: host, reason: "upstream HTTP \(http.statusCode)")
                }
                if let err = audioBodyError(status: http.statusCode, data: data,
                                            contentType: http.value(forHTTPHeaderField: "Content-Type"), url: url) {
                    recordAudioProxyFailure(source: source, host: host, reason: err)
                    return .error(502, err)
                }
                var out: [String: String] = [
                    "Content-Type": outgoingAudioContentType(data: data, url: url, upstreamCT: http.value(forHTTPHeaderField: "Content-Type")),
                    "Cache-Control": "no-store",
                    "Accept-Ranges": "bytes",
                ]
                for k in ["content-length", "content-range"] {
                    if let v = http.value(forHTTPHeaderField: k) { out[k] = v }
                }
                DiagLog.shared.recordPlaybackStep("\(source) audio \(http.statusCode) host=\(host) bytes=\(data.count)")
                return HttpResponse(status: http.statusCode, headers: out, body: data)
            } catch {
                recordAudioProxyFailure(source: source, host: host, reason: "fetch error: \(error.localizedDescription)")
                return .error(502, String(describing: error))
            }
        }
        allow = audioHosts[source] ?? []
        if source != "lx" {
            guard !allow.isEmpty else { return .error(403, "no audio for source \(source)") }
            guard hostAllowed(host, suffixes: allow) else {
                return .error(403, "host not allowed: \(host)")
            }
        }
        var headers: [String: String] = ["User-Agent": "Mozilla/5.0"]
        if let ref = audioReferer[source], !ref.isEmpty { headers["Referer"] = ref }
        headers["Range"] = cappedRangeHeader(req.headers["range"])
        do {
            let (data, http) = try await Upstream.fetch(fetchURL, headers: headers, timeout: 30)
            if !(200..<300).contains(http.statusCode) {
                recordAudioProxyFailure(source: source, host: host, reason: "upstream HTTP \(http.statusCode)")
            }
            if let err = audioBodyError(status: http.statusCode, data: data,
                                        contentType: http.value(forHTTPHeaderField: "Content-Type"), url: url) {
                recordAudioProxyFailure(source: source, host: host, reason: err)
                return .error(502, err)
            }
            var out: [String: String] = [
                "Content-Type": outgoingAudioContentType(data: data, url: url, upstreamCT: http.value(forHTTPHeaderField: "Content-Type")),
                "Cache-Control": "no-store",
                "Accept-Ranges": "bytes",
            ]
            for k in ["content-length", "content-range"] {
                if let v = http.value(forHTTPHeaderField: k) { out[k] = v }
            }
            DiagLog.shared.recordPlaybackStep("\(source) audio \(http.statusCode) host=\(host) bytes=\(data.count)")
            return HttpResponse(status: http.statusCode, headers: out, body: data)
        } catch {
            recordAudioProxyFailure(source: source, host: host, reason: "fetch error: \(error.localizedDescription)")
            return .error(502, String(describing: error))
        }
    }
}
