import AVFoundation
import Foundation

/// 音频代理加载器（P1 新写）。
///
/// 用途：直链播不通（防盗链 403 / CDN 抽风）时，AVPlayer 改走这条路拿音频。
/// AVPlayer 本身发不出自定义 Referer，所以用自定义 scheme `lizi-audio://` 触发
/// ResourceLoader，由这里用 URLSession 重新拉流：带平台 Referer、带 Range 分段。
///
/// 白名单照抄 Proxies（共享服务原样复用，不重写规则）：
/// - 平台直链：host 必须在 `Proxies.audioHosts[source]` 里（QQ 只认 *.qq.com）；
///   不在白名单的 host 直接拒绝加载（不发请求，不当 SSRF 口子）。
/// - LX 直链：不限域名（脚本会返回任意 CDN；壳版 Proxies 同款结论），只放行 http/https。
/// - Referer：`Proxies.audioReferer[source]`（波点有；QQ 用 https://y.qq.com/；
///   没有的平台不带）。
///
/// 注意：这只是「直链失败后的兜底一次」，不是常驻代理——直链能走就走直链。
final class AudioProxyLoader: NSObject, AVAssetResourceLoaderDelegate {

    /// 自定义 scheme（触发 ResourceLoader 用；真实地址存在映射表里，不进 URL）。
    static let scheme = "lizi-audio"

    private struct Job {
        var originalURL: URL
        var source: String
    }

    private var jobs: [String: Job] = [:]
    private let lock = NSLock()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()
    /// 已确认过的内容信息（每条 job 一份：总长度 + MIME，避免每次分段都重探）。
    private var contentInfo: [String: (length: Int64, mime: String)] = [:]

    /// 给一条原始直链生成走代理的 AVPlayer URL（id 只作映射键，不进网络）。
    func proxyURL(for originalURL: URL, source: String) -> URL {
        let id = UUID().uuidString
        lock.lock()
        jobs[id] = Job(originalURL: originalURL, source: source)
        lock.unlock()
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "audio"
        components.path = "/\(id)"
        // 正常情况下 components 一定能拼出来；拼不出来就回原地址（调用方再按直链失败处理）。
        return components.url ?? originalURL
    }

    /// 释放一条 job 的映射（切歌 / 停止时调，避免映射表一直涨）。
    func release(url: URL) {
        guard url.scheme == Self.scheme else { return }
        let id = url.lastPathComponent
        lock.lock()
        jobs.removeValue(forKey: id)
        contentInfo.removeValue(forKey: id)
        lock.unlock()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url,
              url.scheme == Self.scheme else { return false }
        let id = url.lastPathComponent
        lock.lock()
        let job = jobs[id]
        lock.unlock()
        guard let job else {
            loadingRequest.finishLoading(with: NSError(domain: "LiziAudioProxy", code: 404,
                                                      userInfo: [NSLocalizedDescriptionKey: "unknown audio job"]))
            return true
        }
        guard hostAllowed(job.originalURL, source: job.source) else {
            DiagLog.shared.recordLog(category: "audio",
                message: "音频代理拒绝 host（不在白名单）：\(job.originalURL.host ?? "") source=\(job.source)",
                fields: ["host": job.originalURL.host ?? "", "reason": "proxy-host-not-allowed", "lane": "audio-proxy"])
            loadingRequest.finishLoading(with: NSError(domain: "LiziAudioProxy", code: 403,
                                                      userInfo: [NSLocalizedDescriptionKey: "host not allowed"]))
            return true
        }
        Task { await serve(loadingRequest: loadingRequest, job: job, id: id) }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // URLSession 任务是按 request 发的、短命的，不用逐个取消；
        // AVFoundation 取消后多回来的数据会被丢弃，不写进播放器。
    }

    // MARK: - 分段拉流

    private func serve(loadingRequest: AVAssetResourceLoadingRequest, job: Job, id: String) async {
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading(with: NSError(domain: "LiziAudioProxy", code: 400,
                                                      userInfo: [NSLocalizedDescriptionKey: "no data request"]))
            return
        }
        let offset = dataRequest.requestedOffset
        let length = Int64(dataRequest.requestedLength)
        // Range：AVFoundation 要哪段就拉哪段（seek 时只拉目标段，不从头下整首）。
        let end = length > 0 ? offset + length - 1 : nil
        var headers: [String: String] = ["User-Agent": "Mozilla/5.0"]
        if let referer = referer(for: job.source), !referer.isEmpty {
            headers["Referer"] = referer
        }
        if let end {
            headers["Range"] = "bytes=\(offset)-\(end)"
        } else {
            headers["Range"] = "bytes=\(offset)-"
        }
        // 第 22 轮第 5 件：上游取流先升 https（Upstream.upgradedAudioURL，
        // 与服务端 /api/audio 同款）：http 原址进 URLSession 在真机上直接
        // 被 ATS -1022 拦（04:22 诊断：car-er.kuwo.cn 的代理取流失败，
        // 错的就是这一行）；.kuwo.cn 在升级表里，VM 实测 https 通
        //（https://car-er.kuwo.cn/ 回 403，TLS 与服务端都正常——403 只是
        // 根路径没有音频资源）。白名单校验仍用原地址的 host
        //（升级只换 scheme，不换 host），下面 hostAllowed 不动。
        let fetchURL = Upstream.upgradedAudioURL(job.originalURL)
        var urlRequest = URLRequest(url: fetchURL, timeoutInterval: 30)
        urlRequest.httpMethod = "GET"
        for (k, v) in headers { urlRequest.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                DiagLog.shared.recordPlaybackStep("audio proxy upstream HTTP \(code) source=\(job.source) host=\(job.originalURL.host ?? "")")
                loadingRequest.finishLoading(with: NSError(domain: "LiziAudioProxy", code: code,
                                                          userInfo: [NSLocalizedDescriptionKey: "upstream HTTP \(code)"]))
                return
            }
            // 内容信息：第一次回包时从 Content-Range / Content-Length 定总长度与 MIME。
            if let contentRequest = loadingRequest.contentInformationRequest {
                lock.lock()
                let known = contentInfo[id]
                lock.unlock()
                let total = totalLength(http: http, dataCount: data.count, offset: offset) ?? known?.length
                let mime = http.value(forHTTPHeaderField: "Content-Type") ?? known?.mime ?? "audio/mpeg"
                if let total {
                    contentRequest.contentType = mime
                    contentRequest.contentLength = total
                    contentRequest.isByteRangeAccessSupported = true
                    lock.lock()
                    contentInfo[id] = (length: total, mime: mime)
                    lock.unlock()
                }
            }
            dataRequest.respond(with: data)
            loadingRequest.finishLoading()
        } catch {
            DiagLog.shared.recordPlaybackStep("audio proxy fetch FAIL source=\(job.source) host=\(job.originalURL.host ?? "") scheme=\(fetchURL.scheme ?? "-") err=\(error.localizedDescription)")
            loadingRequest.finishLoading(with: error)
        }
    }

    /// 从 Content-Range（bytes a-b/total）或 Content-Length 推总长度。
    private func totalLength(http: HTTPURLResponse, dataCount: Int, offset: Int64) -> Int64? {
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last, let n = Int64(total) {
            return n
        }
        if let len = http.value(forHTTPHeaderField: "Content-Length"), let n = Int64(len) {
            // 206 分段回包时 Content-Length 只是本段长度；200 整包时才是总长度。
            return http.statusCode == 200 ? n : offset + n
        }
        return nil
    }

    // MARK: - 白名单与 Referer（照抄 Proxies）

    private func hostAllowed(_ url: URL, source: String) -> Bool {
        guard let host = url.host?.lowercased(),
              url.scheme == "http" || url.scheme == "https" else { return false }
        if source == "qq" { return Proxies.qqHostAllowed(host) }
        if source == "lx" { return true }
        let suffixes = Proxies.audioHosts[source] ?? []
        guard !suffixes.isEmpty else { return false }
        return suffixes.contains { host == $0.dropFirst() || host.hasSuffix($0) }
    }

    private func referer(for source: String) -> String? {
        if source == "qq" { return "https://y.qq.com/" }
        return Proxies.audioReferer[source]
    }
}

// r31：提示音生成器已删（用户 2026-11-21 05:40 决定：播放失败不再播
// 提示音）。平台 → 云盘 → LX 全失败后直接报错，保持静默，不出声。
// 旧生成器（运行时合成 40 秒正弦提示音写进 Caches）连同调用点已整段
// 删除，不留死代码。
