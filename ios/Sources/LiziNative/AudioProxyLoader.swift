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
/// - Referer：`Proxies.audioReferer[source]`（酷狗/波点有；QQ 用 https://y.qq.com/；
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
        var urlRequest = URLRequest(url: job.originalURL, timeoutInterval: 30)
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
            DiagLog.shared.recordPlaybackStep("audio proxy fetch FAIL source=\(job.source) host=\(job.originalURL.host ?? "") err=\(error.localizedDescription)")
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

// MARK: - 演示音（取链全失败时的最后一档）

/// 演示音生成器：平台 → 云盘 → LX 全失败时，播一段本地合成的提示音（不是真歌，
/// UI 按 `isDemo == true` + reason 显示「为什么不是真歌」，绝不假装在放原曲）。
/// 照抄壳版 player.js 的兜底语义（取链失败走演示音、播放失败也走演示音），
/// 但原生版没有现成的演示音频文件，改为运行时合成一段 40 秒正弦提示音写进 Caches，
/// 只生成一次、重复用。
enum DemoTone {
    private static let fileName = "lizi-demo-tone.wav"

    /// 演示音文件 URL（不存在时现场合成；合成失败返回 nil，调用方报播放失败）。
    static func url() -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let dir else { return nil }
        let file = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let data = renderWAV(seconds: 40, frequency: 440, sampleRate: 22050) else { return nil }
        do {
            try data.write(to: file, options: [.atomic])
            return file
        } catch {
            return nil
        }
    }

    /// 16-bit 单声道 WAV：低音量正弦（0.15），40 秒。
    private static func renderWAV(seconds: Int, frequency: Double, sampleRate: Int) -> Data? {
        let count = seconds * sampleRate
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            // 每 4 秒一个音节起伏，避免持续长音刺耳。
            let gate = 0.5 + 0.5 * sin(2 * Double.pi * Double(i) / Double(sampleRate * 4))
            let sample = sin(2 * Double.pi * frequency * t) * 0.15 * gate
            var v = Int16(max(-1, min(1, sample)) * Double(Int16.max))
            pcm.append(Data(bytes: &v, count: 2))
        }
        var wav = Data()
        func u32(_ n: UInt32) { var v = n.littleEndian; wav.append(Data(bytes: &v, count: 4)) }
        func u16(_ n: UInt16) { var v = n.littleEndian; wav.append(Data(bytes: &v, count: 2)) }
        wav.append(Data("RIFF".utf8)); u32(UInt32(36 + pcm.count)); wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        wav.append(Data("data".utf8)); u32(UInt32(pcm.count)); wav.append(pcm)
        return wav
    }
}
