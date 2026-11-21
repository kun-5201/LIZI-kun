import Foundation

/// 静态文件：把 public/ 全量当静态目录发出去（对标 server.mjs 的静态托管）。
/// public/ 以 folder reference 打进包，Bundle 里路径就是 <App>.app/public/...。

enum StaticFiles {
    static var publicRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("public")
    }

    private static let mime: [String: String] = [
        "html": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "svg": "image/svg+xml",
        "ico": "image/x-icon",
        "mp3": "audio/mpeg",
        "flac": "audio/flac",
        "wav": "audio/wav",
        "ogg": "audio/ogg",
        "m4a": "audio/mp4",
        "mp4": "video/mp4",
        "webm": "video/webm",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "bin": "application/octet-stream",
        "txt": "text/plain; charset=utf-8",
        "map": "application/json; charset=utf-8",
    ]

    static func mimeType(forExtension ext: String) -> String {
        mime[ext.lowercased()] ?? "application/octet-stream"
    }

    /// 把一段已读入内存的数据按 HTTP Range 发出去。
    /// serve(path:) 和 /api/local/file 共用同一套 Range 代码，不各写一套。
    static func serveData(_ data: Data, type: String, rangeHeader: String?) -> HttpResponse {
        // Range: bytes=start-end（单段即可，<audio> 拖进度只发单段）。
        if let rangeHeader, rangeHeader.hasPrefix("bytes=") {
            let spec = rangeHeader.dropFirst("bytes=".count)
            let parts = spec.split(separator: "-", maxSplits: 1).map(String.init)
            if parts.count == 2, let start = Int(parts[0]) {
                let end = Int(parts[1]) ?? (data.count - 1)
                let s = max(0, start), e = min(data.count - 1, end)
                if s <= e {
                    let slice = data.subdata(in: s..<(e + 1))
                    return HttpResponse(status: 206, headers: [
                        "Content-Type": type,
                        "Accept-Ranges": "bytes",
                        "Content-Range": "bytes \(s)-\(e)/\(data.count)",
                        // 同 200 分支：Range 分片也不缓存（见下）。
                        "Cache-Control": "no-store",
                        "Pragma": "no-cache",
                    ], body: slice)
                }
            }
            return HttpResponse(status: 416, headers: ["Content-Range": "bytes */\(data.count)"], body: Data())
        }
        return HttpResponse(status: 200, headers: [
            "Content-Type": type,
            "Accept-Ranges": "bytes",
            // 升级重装后 WKWebView 的 HTTP 缓存仍在（同包名覆盖安装不清空
            // Library/Caches）：静态资源绝不能被缓存，否则旧 api.js /
            // player.js / app.js 会一直跑，服务端修了也看不到。no-store
            // 是最彻底的——每次都回源取包内最新文件。
            "Cache-Control": "no-store",
            "Pragma": "no-cache",
        ], body: data)
    }

    /// GET / 或 /xxx.html 等。支持 Range（音频/大文件拖进度用）。
    /// `..` 越界回 403；目录补 index.html；缺文件回 404 纯文本（与 server.mjs 一致）。
    static func serve(path: String, rangeHeader: String?) -> HttpResponse {
        guard let root = publicRoot else {
            return .text(404, "404")
        }
        var rel = path
        if rel == "/" || rel.isEmpty { rel = "/index.html" }
        let segments = rel.split(separator: "/").map(String.init)
        if segments.contains("..") {
            return .text(403, "403")
        }
        var fileURL = root
        for seg in segments where seg != "." {
            fileURL.appendPathComponent(seg)
        }
        // 目录尾斜杠补 index.html。
        if let isDir = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir == true {
            fileURL.appendPathComponent("index.html")
        }
        guard fileURL.path.hasPrefix(root.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let data = try? Data(contentsOf: fileURL) else {
            return .text(404, "404")
        }
        let ext = fileURL.pathExtension.lowercased()
        return serveData(data, type: mimeType(forExtension: ext), rangeHeader: rangeHeader)
    }
}

/// 上游请求小工具（URLSession，带超时；对标 server.mjs 的 fetch 行为）。
enum Upstream {
    /// r31-cookie：上游请求一律走这只私有 session，不走 `URLSession.shared`。
    /// 根因（7 平台 Cookie 登录后都拉不到数据的共因之一）：`URLSession.shared`
    /// 自带共享 cookie 罐——匿名请求（搜索 / 推荐）回的 Set-Cookie 会被收进罐，
    /// 之后带登录 Cookie 的请求发出去时，罐里的旧 cookie 会跟显式 `Cookie`
    /// 头一起发（Moumusic `QQMusicAPI.swift` init 注释同款教训：罐里新旧两份
    /// 签名会让上游把一次有效登录判成过期/未登录）。Moumusic 的修法是专用
    /// session + `httpShouldSetCookies = false` + `httpCookieAcceptPolicy = .never`，
    /// 这里同款：从此只有各服务显式设置的 `Cookie` 头会被发出去，罐不再掺和。
    /// 不影响网易：`NetEase.fetchUpstream` 自带 `URLSession.shared`（扫码 803
    /// 的 MUSIC_U 收割要读共享罐，见该函数注释），不在这里改。
    /// 也不影响各服务的 Set-Cookie 读取：响应头照常从 `HTTPURLResponse`
    /// 取（酷我 `refreshToken`、酷狗 `KGResponse.setCookies` 同款），
    /// 只是不再写进共享罐。
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        return URLSession(configuration: c)
    }()
    /// 音频直链 https 升级（第 12 轮 ATS 修法，与 public/api.js 的
    /// AUDIO_HTTPS_SUFFIXES 是同一张表，改一边要同步另一边）。
    /// 根因见 project.yml 注释：plist 里 NSAllowsArbitraryLoads 已被系统
    /// 静默忽略，URLSession 拉 http 上游直接 -1022。凡实测支持 https 的
    /// 音频域，在探活、代理取上游之前一律先升成 https；没验过的域不动。
    /// r24：随 Folia 酷狗边车接回其音频域（网关 / 歌词 / m.kugou.com 的
    /// https 本轮 VM 实测通；音频 CDN 域沿用旧表实测结论：酷狗 FLAC 等
    /// 音频直链走 .kugou.com / .kglink.com）。
    static let audioHTTPSSuffixes = [".music.126.net", ".qq.com", ".kuwo.cn", ".kugou.com", ".kglink.com"]

    /// http → https（仅升级表里的域；host 不变，只换 scheme）。
    static func upgradedAudioURL(_ url: URL) -> URL {
        guard url.scheme == "http", let host = url.host else { return url }
        let h = host.lowercased()
        guard audioHTTPSSuffixes.contains(where: { h == $0.dropFirst() || h.hasSuffix($0) }) else { return url }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.scheme = "https"
        return comps?.url ?? url
    }

    /// 直链转 URL：先原样试；含空格 / {} / | 等非法字符时 URL(string:) 会回 nil，
    /// 这时只把非法字符做 % 编码（保留 :/?#[]@!$&'()*+,;= 结构字符和已有的 %
    /// 转义），再试一次。两次都 nil 才返回 nil（调用方按原有 400 / false 处理）。
    /// 背景：LX 脚本返回的直链偶有中文文件名或空格（如 .../周杰伦 - 晴天.mp3），
    /// 直接 URL(string:) 失败会让探活判死、代理回 400，明明是活链。
    static func url(from raw: String) -> URL? {
        if let u = URL(string: raw) { return u }
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.insert(charactersIn: "%")
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed),
              let u = URL(string: encoded) else { return nil }
        return u
    }

    static func fetch(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 20,
                      method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        // iOS 13+ 的 URLSession 拒绝 GET 带 body（NSURLError -1103 "resource exceeds maximum size"，
        // 2026-11-18 真机波点登录就是这么死的）。这里统一丢掉 GET 的 body：
        // 各边车不要依赖 GET+body（波点 users/login 改走 POST，checkRight/audioUrl 的参数 query 里本来就有）。
        req.httpBody = (method.uppercased() == "GET") ? nil : body
        // r31-cookie：走私有 session（见本文件 `session` 注释），不用
        // URLSession.shared——共享罐的旧 cookie 会跟显式 Cookie 头一起发出。
        // r33：幂等 GET 重试——QQ/酷狗 3 次、其他 2 次，间隔 180ms×失败次数
        // （第 1 次重试前 180ms，第 2 次前 360ms）；空 200（200 但 body 为空）
        // 与 5xx 也重试；4xx 不重试（重试也没用）；取消立即抛，不重试。
        // 次数按 host 定：*.qq.com / *.kugou.com（含 u.y.qq.com、
        // www2.kugou.kugou.com、网关域）3 次，其余 2 次；非 GET 只跑一次。
        let isGet = method.uppercased() == "GET"
        let host = (url.host ?? "").lowercased()
        let isRetryHost = host == "qq.com" || host.hasSuffix(".qq.com")
            || host == "kugou.com" || host.hasSuffix(".kugou.com")
        let maxAttempts = isGet ? (isRetryHost ? 3 : 2) : 1
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(180 * attempt) * 1_000_000)
            }
            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw NSError(domain: "LiziUpstream", code: -1, userInfo: [NSLocalizedDescriptionKey: "no http response"])
                }
                let empty200 = http.statusCode == 200 && data.isEmpty
                if (empty200 || http.statusCode >= 500), attempt + 1 < maxAttempts {
                    lastError = NSError(domain: "LiziUpstream", code: http.statusCode,
                                        userInfo: [NSLocalizedDescriptionKey: empty200 ? "empty 200" : "http \(http.statusCode)"])
                    continue
                }
                return (data, http)
            } catch {
                lastError = error
                if Task.isCancelled || attempt + 1 >= maxAttempts { throw error }
            }
        }
        throw lastError ?? NSError(domain: "LiziUpstream", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey: "upstream fetch failed"])
    }

    static func fetchJSON(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 20,
                          method: String = "GET", body: Data? = nil) async throws -> Any {
        let (data, _) = try await fetch(url, headers: headers, timeout: timeout, method: method, body: body)
        return try JSONSerialization.jsonObject(with: data)
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
