import Foundation
import CoreImage
import UIKit

/// 网易云服务：weapi/eapi 直连 music.163.com、登录、会话。
/// 实现依据：specs/netease.md（server.mjs 全文 + npm 包 @neteasecloudmusicapienhanced/api@4.41.1 的
/// dj/recommend、dj/program、album/sublist、recommend/songs 四个模块）。
/// 边车（npm 包）在 iOS 上跑不了，/api/netease/* 的路由在这里用 weapi/eapi 直接实现：
/// 扫码 key/check 走 eapi（包里 APP_CONF.encrypt=true 时默认 eapi，type 硬编码为 3），
/// dj/专辑/每日推荐走 weapi；X-antiCheatToken 按包里的 register_checktoken_v3 从
/// ac.dun.163yun.com 实时取（取不到就按包的做法：不带头继续请求）。
/// 第 11 轮（kun 对齐）：搜索、取链、每日签到三条线按 kun（lty5201/kun，
/// dynamic-island-lyrics 分支，MusicAPI.swift / MusicClient.swift）对齐——
/// 搜索走 eapi /cloudsearch/pc，取链走 eapi /song/enhance/player/url/v1
///（encodeType 恒为 flac，sky 档加 immerseType c51），签到走 weapi
/// /point/dailyTask（type 0 安卓 + type 1 网页各一次）。其余网易接口不动。

final class NetEaseService {
    private let session = SessionStore.shared

    // 扫码诊断状态（必须放主类里：extension 里不能有存储属性）。
    private var lastQrCheck: [String: Any]?
    private var lastHarvest: [String: Any]?
    private var qrCache: [String: QrCacheEntry] = [:]
    private let qrCookieTTL: TimeInterval = 10 * 60

    // MARK: - 常量

    static let weapiUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let neteaseUA = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.17.204416"
    static let baseURL = "https://music.163.com"

    // MARK: - 传输层（fetchUpstream：15 秒超时，最多 2 次，间隔 400ms；前端 60 秒超时内必须回）

    struct UpstreamResult {
        var status: Int
        var json: [String: Any]
        var setCookies: [String]
    }

    private func fetchUpstream(_ url: URL, headers: [String: String], body: Data,
                               timeout: TimeInterval = 15, attempts: Int = 2) async throws -> UpstreamResult {
        var lastError: Error?
        for attempt in 0..<max(1, attempts) {
            do {
                var req = URLRequest(url: url, timeoutInterval: timeout)
                req.httpMethod = "POST"
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                req.httpBody = body
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw NSError(domain: "NetEase", code: -1, userInfo: [NSLocalizedDescriptionKey: "no http response"])
                }
                // 先收 cookie，再解析 JSON（和 server.mjs 的顺序一致）。
                var setCookies: [String] = []
                for (k, v) in http.allHeaderFields {
                    if let ks = k as? String, ks.lowercased() == "set-cookie", let vs = v as? String {
                        setCookies.append(vs)
                    }
                }
                if !setCookies.isEmpty { session.saveCookies(setCookies) }
                // 再从 URLSession 的共享 cookie 仓补一份：多条 Set-Cookie 在
                // allHeaderFields 里会拼成一条（甚至可能看不到），但 URLSession.shared
                // 一定把响应 cookie 存进了共享仓（默认配置）。803 的 MUSIC_U 只走
                // Set-Cookie——丢了它，扫码就永远收不到登录态。
                if let stored = HTTPCookieStorage.shared.cookies(for: url) {
                    var extra: [String: String] = [:]
                    for c in stored { extra[c.name] = c.value }
                    if !extra.isEmpty { session.setCookies(extra) }
                }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return UpstreamResult(status: http.statusCode, json: obj, setCookies: setCookies)
                }
                let raw = String(data: data, encoding: .utf8) ?? ""
                return UpstreamResult(status: http.statusCode,
                                      json: ["code": 500, "raw": String(raw.prefix(500))],
                                      setCookies: setCookies)
            } catch {
                lastError = error
                if attempt < max(1, attempts) - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(400 * (attempt + 1)) * 1_000_000)
                }
            }
        }
        throw lastError ?? NSError(domain: "NetEase", code: -1, userInfo: [NSLocalizedDescriptionKey: "upstream failed"])
    }

    private func formBody(_ fields: [(String, String)]) -> Data {
        // application/x-www-form-urlencoded：必须用严格字符集。
        // .urlQueryAllowed 不转义 +，而 weapi 的 params 是 base64（含 +），
        // + 会被服务端解成空格 → base64 损坏 → AES 解密失败（约 98.5% 的调用）。
        let strict = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let s = fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: strict) ?? "")"
        }.joined(separator: "&")
        return Data(s.utf8)
    }

    /// weapi 请求：POST https://music.163.com/weapi + apiPath。
    func weapiRequest(_ apiPath: String, _ payload: [String: Any],
                      timeout: TimeInterval = 15, attempts: Int = 2) async throws -> UpstreamResult {
        var obj = payload
        obj["csrf_token"] = session.csrf
        guard let enc = NetEaseCrypto.weapi(obj) else {
            throw NSError(domain: "NetEase", code: -2, userInfo: [NSLocalizedDescriptionKey: "weapi encrypt failed"])
        }
        let url = URL(string: Self.baseURL + "/weapi" + apiPath)!
        let headers: [String: String] = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Referer": "https://music.163.com",
            "User-Agent": Self.weapiUA,
            "Cookie": session.cookieHeader,
            "X-Real-IP": "118.88.88.88",
            "X-Forwarded-For": "118.88.88.88",
        ]
        let body = formBody([("params", enc.params), ("encSecKey", enc.encSecKey), ("csrf_token", session.csrf)])
        return try await fetchUpstream(url, headers: headers, body: body, timeout: timeout, attempts: attempts)
    }

    /// eapi 请求：签名路径 /api + apiPath，实际打到 https://music.163.com/eapi + apiPath。
    /// checkToken 为 true 时先取易盾 token 加 X-antiCheatToken 头（取不到就不带，继续请求）。
    func eapiRequest(_ apiPath: String, _ payload: [String: Any], checkToken: Bool = false,
                     timeout: TimeInterval = 15, attempts: Int = 2) async throws -> UpstreamResult {
        let signedPath = apiPath.hasPrefix("/api") ? apiPath : "/api" + apiPath
        guard let params = NetEaseCrypto.eapi(apiPath: signedPath, object: payload, csrf: session.csrf) else {
            throw NSError(domain: "NetEase", code: -2, userInfo: [NSLocalizedDescriptionKey: "eapi encrypt failed"])
        }
        let url = URL(string: Self.baseURL + "/eapi" + apiPath)!
        var headers: [String: String] = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Referer": "https://music.163.com",
            "Origin": "https://music.163.com",
            "User-Agent": Self.neteaseUA,
            "Cookie": session.cookieHeader,
        ]
        if checkToken, let token = await fetchAntiCheatToken(), !token.isEmpty {
            headers["X-antiCheatToken"] = token
        }
        let body = formBody([("params", params)])
        return try await fetchUpstream(url, headers: headers, body: body, timeout: timeout, attempts: attempts)
    }

    /// 易盾反作弊 token v3（包里 register_checktoken_v3 的做法）：
    /// GET https://ac.dun.163yun.com/v3/b?pn=YD00000558929251，解析 null([200,ts,"TOKEN"])。
    func fetchAntiCheatToken() async -> String? {
        guard let url = URL(string: "https://ac.dun.163yun.com/v3/b?pn=YD00000558929251") else { return nil }
        do {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.httpMethod = "GET"
            let (data, _) = try await URLSession.shared.data(for: req)
            let text = String(data: data, encoding: .utf8) ?? ""
            if let range = text.range(of: #"null\(\[200,\d+,"([^"]+)"\]\)"#, options: .regularExpression) {
                let m = String(text[range])
                if let first = m.firstIndex(of: "\""), let last = m.lastIndex(of: "\""), first != last {
                    return String(m[m.index(after: first)..<last])
                }
            }
        } catch { /* 取不到就返回 nil，调用方不带头继续请求 */ }
        return nil
    }

    // MARK: - 路由表（ROUTES，server.mjs 原样）

    struct Route {
        var path: String
        var channel: String // "weapi" 或 "eapi"
    }

    static let routes: [String: Route] = [
        "login/qr/key": Route(path: "/login/qrcode/unikey", channel: "eapi"),
        "login/qr/check": Route(path: "/login/qrcode/client/login", channel: "eapi"),
        "login/cellphone": Route(path: "/login/cellphone", channel: "weapi"),
        "login/status": Route(path: "/w/nuser/account/get", channel: "weapi"),
        // 会员信息（r31-membership）：weapi /music-vip-membership/client/vip/info，
        // /api/vip/info 直通（normalize 默认原样回 {code, data}，客户端
        // LoginStore.ensureVIPInfo 懒补时调它；/api/session 里 sessionVerify
        // 也连调它，见 vipInfo()）。
        "vip/info": Route(path: "/music-vip-membership/client/vip/info", channel: "weapi"),
        "logout": Route(path: "/logout", channel: "weapi"),
        "user/playlist": Route(path: "/user/playlist", channel: "weapi"),
        "user/detail": Route(path: "/v1/user/detail/:uid", channel: "weapi"),
        // 我的云盘（第 7 轮第 8 件）：上游 NeteaseCloudMusicApi /user/cloud
        // 就是 POST /weapi/v1/cloud/get {limit, offset}，登录态走 MUSIC_U。
        // 未登录时上游回 301，前端云盘腿直接跳过这一档。
        "user/cloud": Route(path: "/v1/cloud/get", channel: "weapi"),
        "playlist/detail": Route(path: "/v6/playlist/detail", channel: "weapi"),
        "playlist/track/all": Route(path: "/v6/playlist/detail", channel: "weapi"),
        // 每日签到（第 11 轮 kun 对齐：kun MusicAPI.dailySignIn，weapi
        // /point/dailyTask，type 0 安卓 3 点 + type 1 网页 2 点；-2 = 当天已签）。
        // 只走 Lizi 现有的网易登录会话（MUSIC_U），不重做登录。
        "daily/signin": Route(path: "/point/dailyTask", channel: "weapi"),
        "song/url": Route(path: "/song/enhance/player/url/v1", channel: "eapi"),
        "song/detail": Route(path: "/v3/song/detail", channel: "weapi"),
        "song/wiki": Route(path: "/song/play/about/block/page", channel: "weapi"),
        "lyric": Route(path: "/song/lyric/v1", channel: "weapi"),
        // 搜索（第 11 轮 kun 对齐：kun MusicAPI.search 走 eapi /cloudsearch/pc，
        // 不再走 weapi /search/get；回的歌自带 al.picUrl，封面不用再补调）。
        "search": Route(path: "/cloudsearch/pc", channel: "eapi"),
        "personalized": Route(path: "/personalized/newsong", channel: "weapi"),
        "recommend/songs": Route(path: "/v1/discovery/recommend/songs", channel: "weapi"),
        "top/playlist": Route(path: "/personalized/playlist", channel: "weapi"),
        // 排行榜目录（r35-10：Moumusic iOS officialToplists 同款 eapi /toplist，
        // 匿名可调；VM 实测 2026-11-21：code 200、65 个榜，项有 id/name/
        // coverImgUrl/trackCount。详情复用 /api/playlist/detail，榜单 id
        // 即歌单 id；热歌榜只回 10 首预览时服务端 playlist/detail 已从
        // trackIds 按组补齐，不用这里再补）。
        "toplist": Route(path: "/toplist", channel: "eapi"),
        "artist/:id": Route(path: "/v1/artist/:id", channel: "weapi"),
        "artist/albums/:id": Route(path: "/artist/albums/:id", channel: "weapi"),
        "artist/songs": Route(path: "/v1/artist/songs", channel: "weapi"),
        "album/:id": Route(path: "/v1/album/:id", channel: "weapi"),
    ]

    /// matchRoute：先精确匹配，再按含 : 的 key 逐段匹配。
    func matchRoute(_ name: String) -> (key: String, route: Route, params: [String: String])? {
        if let r = Self.routes[name] { return (name, r, [:]) }
        let nameSegs = name.split(separator: "/").map(String.init)
        for (key, route) in Self.routes where key.contains(":") {
            let keySegs = key.split(separator: "/").map(String.init)
            guard keySegs.count == nameSegs.count else { continue }
            var params: [String: String] = [:]
            var ok = true
            for (ks, ns) in zip(keySegs, nameSegs) {
                if ks.hasPrefix(":") { params[String(ks.dropFirst())] = ns }
                else if ks != ns { ok = false; break }
            }
            if ok { return (key, route, params) }
        }
        return nil
    }

    // MARK: - 小工具

    func idList(_ v: Any?) -> [Int] {
        guard let v else { return [] }
        let s: String
        if let n = v as? NSNumber { s = n.stringValue }
        else if let str = v as? String { s = str }
        else { return [] }
        return s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 != 0 }
    }

    func str(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }
    func int(_ d: [String: Any], _ k: String) -> Int {
        if let n = d[k] as? Int { return n }
        if let n = d[k] as? NSNumber { return n.intValue }
        if let s = d[k] as? String, let n = Int(s) { return n }
        return 0
    }
    func intOr(_ d: [String: Any], _ k: String, _ def: Int) -> Int {
        if d[k] == nil { return def }
        return int(d, k)
    }
    func arr(_ d: [String: Any], _ k: String) -> [[String: Any]] { d[k] as? [[String: Any]] ?? [] }
    func dict(_ d: [String: Any], _ k: String) -> [String: Any] { d[k] as? [String: Any] ?? [:] }

    /// YRC 逐字文本转行级 LRC（r55 Folia 歌词：翻译/音译对齐用）。
    /// ytlrc / yromalrc 是逐字版（`[起点ms,时长ms](起点,时长,0)字…` 或
    /// 尖括号 `<mm:ss.xxx>字…`），客户端只认 `[mm:ss.xx]文本` 行级形；
    /// 这里逐行取行起点、剥逐字标签、拼回行级文本。无行起点或空行跳过。
    static func yrcToLrc(_ yrc: String) -> String {
        guard !yrc.isEmpty else { return "" }
        var out: [String] = []
        for raw in yrc.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            var startMs: Int? = nil
            var text = line
            if let m = line.range(of: #"^\[(\d+),(\d+)\]"#, options: .regularExpression) {
                let nums = String(line[m]).components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
                if nums.count >= 2 { startMs = nums[0] }
                text = String(line[m.upperBound...])
            } else if let m = line.range(of: #"<(\d+):(\d+(?:\.\d+)?)>"#, options: .regularExpression) {
                let stamp = String(line[m]).replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
                let parts = stamp.split(separator: ":")
                if parts.count == 2, let mm = Int(parts[0]), let ss = Double(parts[1]) {
                    startMs = Int((Double(mm) * 60 + ss) * 1000)
                }
            }
            text = text.replacingOccurrences(of: #"\(\d+,\d+(?:,\d+)?\)"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"<\d+:\d+(?:\.\d+)?>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let startMs else { continue }
            let mm = startMs / 60000
            let ss = Double(startMs % 60000) / 1000.0
            out.append("[\(String(format: "%02d:%05.2f", mm, ss))]\(text)")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - 曲目归一化（toTrack / fetchTrackDetails）

    func toTrack(_ s: [String: Any]) -> [String: Any]? {
        guard let id = s["id"] as? Int ?? (s["id"] as? NSNumber)?.intValue else { return nil }
        let artists = (s["ar"] as? [[String: Any]]) ?? (s["artists"] as? [[String: Any]]) ?? []
        let album = (s["al"] as? [String: Any]) ?? (s["album"] as? [String: Any]) ?? [:]
        let names = artists.compactMap { $0["name"] as? String }
        let cover = str(album, "picUrl").isEmpty ? (str(album, "blurPicUrl").isEmpty ? (str(s, "picUrl").isEmpty ? str(s, "coverImgUrl") : str(s, "picUrl")) : str(album, "blurPicUrl")) : str(album, "picUrl")
        let dt = int(s, "dt")
        let out: [String: Any] = [
            "id": id,
            "name": str(s, "name"),
            "artists": names.joined(separator: " / ").isEmpty ? "未知歌手" : names.joined(separator: " / "),
            "artistIds": artists.compactMap { ($0["id"] as? NSNumber)?.intValue ?? $0["id"] as? Int },
            "album": str(album, "name"),
            "albumId": album["id"] as? Int ?? NSNull(),
            "cover": cover,
            "duration": dt != 0 ? dt : int(s, "duration"),
            "fee": s["fee"] as? Int ?? 0,
            // r30 路线 B：ISRC 透传（上游给才有；VM 实测网易搜索行与
            // weapi /v3/song/detail 全键列表均无 isrc，本字段恒为空，
            // 只是占位透传、不改任何取链逻辑）。
            "isrc": str(s, "isrc"),
            // r58 Folia 获取标志：网易行自带 `t`（0 普通、1/2 云盘歌；
            // Folia netease.ts normalizeSongResult：t==1||t==2 →
            // sourceType='cloud' → sourceRef.variant='cloud'）。
            // 只透传、不改任何取链逻辑；客户端 Track.from 按它打标志。
            "t": int(s, "t"),
        ]
        return out
    }

    /// cloudsearch type 10 的专辑行 → 平铺字典（客户端 albumFrom 直接认：
    /// id / name / picUrl / artist / trackCount）。没 id 或没名不要（坏行跳过，
    /// 不拖垮整页——Folia qishui searchPlaylists 同款做法）。
    func toAlbum(_ s: [String: Any]) -> [String: Any]? {
        guard let id = s["id"] as? Int ?? (s["id"] as? NSNumber)?.intValue,
              !str(s, "name").isEmpty else { return nil }
        let artists = (s["artists"] as? [[String: Any]]) ?? (s["ar"] as? [[String: Any]]) ?? []
        let names = artists.compactMap { $0["name"] as? String }
        return ["id": id, "name": str(s, "name"),
                "picUrl": str(s, "picUrl"),
                "artist": names.joined(separator: " / "),
                "trackCount": int(s, "size")]
    }

    /// cloudsearch type 1000 的歌单行 → 平铺字典（客户端 playlistFrom 直接认：
    /// id / name / coverImgUrl / creator{nickname} / trackCount / description）。
    func toPlaylist(_ s: [String: Any]) -> [String: Any]? {
        guard let id = s["id"] as? Int ?? (s["id"] as? NSNumber)?.intValue,
              !str(s, "name").isEmpty else { return nil }
        let creator = (s["creator"] as? [String: Any]) ?? [:]
        return ["id": id, "name": str(s, "name"),
                "coverImgUrl": str(s, "coverImgUrl"),
                "creator": ["nickname": str(creator, "nickname")],
                "trackCount": int(s, "trackCount"),
                "description": str(s, "description")]
    }

    /// 每批最多 500 个 id 调 /v3/song/detail，收集各批 d.songs。
    func fetchTrackDetails(_ ids: [Int]) async -> [[String: Any]] {
        guard !ids.isEmpty else { return [] }
        var out: [[String: Any]] = []
        var i = 0
        while i < ids.count {
            let batch = Array(ids[i..<min(i + 500, ids.count)])
            do {
                let c = try JSONSerialization.data(withJSONObject: batch.map { ["id": $0] })
                let cStr = String(data: c, encoding: .utf8) ?? "[]"
                let r = try await weapiRequest("/v3/song/detail", ["c": cStr])
                out.append(contentsOf: arr(r.json, "songs"))
            } catch { /* 某批失败就跳过，不影响其他批 */ }
            i += 500
        }
        return out
    }

    func profileOf(_ p: [String: Any]?) -> [String: Any]? {
        guard let p, int(p, "userId") != 0 else { return nil }
        return [
            "userId": int(p, "userId"),
            "nickname": str(p, "nickname"),
            "avatar": str(p, "avatarUrl").isEmpty ? str(p, "avatar") : str(p, "avatarUrl"),
            "vipType": int(p, "vipType"),
        ]
    }
}

extension NetEaseService {
    // MARK: - 通用转发 /api/*（ROUTES + 参数整形 + normalize）

    func handleApi(_ req: HttpRequest) async -> HttpResponse {
        let name = String(req.path.dropFirst("/api/".count))
        guard let hit = matchRoute(name) else {
            return .json(404, ["error": "unknown api: \(name)"])
        }
        var payload = req.params
        // 路径占位符替换（pathParams 优先，取不到回 400），替换后从 payload 删除。
        var apiPath = hit.route.path
        for (key, value) in hit.params {
            apiPath = apiPath.replacingOccurrences(of: ":\(key)", with: value)
            payload.removeValue(forKey: key)
        }
        for part in apiPath.split(separator: "/") where part.hasPrefix(":") {
            let key = String(part.dropFirst())
            guard let v = payload[key] else {
                return .json(400, ["error": "\(key) required"])
            }
            apiPath = apiPath.replacingOccurrences(of: ":\(key)", with: "\(v)")
            payload.removeValue(forKey: key)
        }

        // song/detail 不走通用 weapiRequest，直接调 fetchTrackDetails。
        if hit.key == "song/detail" {
            let ids = idList(payload["ids"])
            let tracks = await fetchTrackDetails(ids)
            return .json(200, ["code": 200, "tracks": tracks.compactMap { toTrack($0) }])
        }

        // 每日签到不走通用单次转发：kun dailySignIn() 的做法是 type 0（安卓）
        // 和 type 1（网页）各调一次 /point/dailyTask，code 200 累加 point，
        // code -2（当天已签）也算成功；两次都失败才算失败。未登录时根本
        // 不调上游，直接回 301（和 kun 调用方「未登录不调」一致）。
        if hit.key == "daily/signin" {
            guard session.hasMusicU else {
                return .json(200, ["code": 301, "loggedIn": false, "signedIn": false,
                                   "message": "需要登录网易云音乐后才能签到"])
            }
            var gained = 0
            var anyOK = false
            var alreadySigned = false
            var details: [[String: Any]] = []
            for type in [0, 1] {
                do {
                    let r = try await weapiRequest("/point/dailyTask", ["type": type])
                    let code = int(r.json, "code")
                    let point = int(r.json, "point")
                    details.append(["type": type, "code": code, "point": point])
                    if code == 200 { anyOK = true; gained += point }
                    if code == -2 { anyOK = true; alreadySigned = true }
                } catch {
                    details.append(["type": type, "code": 502, "point": 0,
                                    "error": error.localizedDescription])
                }
            }
            guard anyOK else {
                return .json(502, ["code": 502, "signedIn": false,
                                   "message": "签到失败，上游无响应", "details": details])
            }
            return .json(200, ["code": 200, "signedIn": true, "point": gained,
                               "alreadySigned": alreadySigned, "details": details])
        }

        // 参数整形。
        payload = shapePayload(routeKey: hit.key, payload: payload)

        let t0 = Date()
        // r49：ladder 任一档的 vip 信号（song/url 分支内赋值），normalize
        // 之后用来把最终无 url 的项优先改成 reason:"vip"。
        var songUrlSawVipRefusal = false
        do {
            let result: UpstreamResult
            // 搜索要快：上游慢网时别重试、别拖到前端 60 秒超时才掐掉——
            // 单次 10 秒上限，失败就回 502，前端显示明确原因。
            // 其它接口保持 15 秒 × 2 次。
            let isSearch = hit.key == "search"
            let reqTimeout: TimeInterval = isSearch ? 10 : 15
            let reqAttempts = isSearch ? 1 : 2
            if hit.key == "song/url" {
                // 2026-11-19 第 13 轮第 12 件：所选档拿不到地址时向低档重试
                // （jymaster → dolby/sky → hires → lossless → exhigh → higher
                // → standard），直到拿到地址；上游自动降级时首调即中，不多花请求。
                // normalize 会把实际 level/br 原样透传，前端只显示实际档。
                // r49：① 登录态只记诊断、不拦路——匿名（!hasMusicU）也照常
                // 走 ladder，未登录用户的免费歌必须还能播，绝不直接回 login
                // 拦掉；② 保留首个 vip 信号——每档都覆写 got，只有拿到 url
                // 才 break，前档的 vip 信号会被后档洗掉（normalize 只看最终
                // 一档）；任一档出现 code -110 或 cannotListenReason==1 即
                // 记下 sawVipRefusal，最终无 url 时优先回 reason:"vip"。
                // ③ 每档的 level / code / cannotListenReason / url 有无 /
                // MUSIC_U 有无（只记布尔，绝不记 cookie 值）写进 DiagLog。
                let hasMusicU = session.hasMusicU
                let ladder = ["jymaster", "dolby", "sky", "hires", "lossless", "exhigh", "higher", "standard"]
                let reqLevel = payload["level"] as? String ?? "lossless"
                var idx = ladder.firstIndex(of: reqLevel) ?? 4
                var got: UpstreamResult? = nil
                var lastErr: Error? = nil
                var sawVipRefusal = false
                var tierDiag: [[String: Any]] = []
                while idx < ladder.count {
                    var p2 = payload
                    p2["level"] = ladder[idx]
                    if ladder[idx] == "sky" { p2["immerseType"] = "c51" } else { p2.removeValue(forKey: "immerseType") }
                    do {
                        let rr = try await eapiRequest(apiPath, p2, timeout: reqTimeout, attempts: reqAttempts)
                        let first = (rr.json["data"] as? [[String: Any]])?.first ?? [:]
                        let itemCode = int(first, "code")
                        let itemCannot = int(dict(first, "freeTrialPrivilege"), "cannotListenReason")
                        let hasUrl = ((first["url"] as? String) ?? "").isEmpty == false
                        if !hasUrl && (itemCode == -110 || itemCannot == 1) { sawVipRefusal = true }
                        tierDiag.append(["level": ladder[idx], "code": itemCode,
                                         "cannotListenReason": itemCannot, "hasUrl": hasUrl,
                                         "hasMusicU": hasMusicU])
                        payload = p2
                        got = rr
                        if hasUrl { break }
                    } catch let e {
                        lastErr = e
                        tierDiag.append(["level": ladder[idx], "code": -1,
                                         "cannotListenReason": 0, "hasUrl": false,
                                         "hasMusicU": hasMusicU, "error": e.localizedDescription])
                    }
                    idx += 1
                }
                songUrlSawVipRefusal = sawVipRefusal
                DiagLog.shared.recordLog(category: "netease-url", message: "song/url ladder", fields: [
                    "anonymous": !hasMusicU, "hasMusicU": hasMusicU,
                    "sawVipRefusal": sawVipRefusal, "tiers": tierDiag,
                ])
                guard let rr = got else {
                    throw lastErr ?? NSError(domain: "LiziUpstream", code: 502,
                                             userInfo: [NSLocalizedDescriptionKey: "网易取链失败"])
                }
                result = rr
            } else if hit.route.channel == "eapi" {
                result = try await eapiRequest(apiPath, payload, timeout: reqTimeout, attempts: reqAttempts)
            } else {
                result = try await weapiRequest(apiPath, payload, timeout: reqTimeout, attempts: reqAttempts)
            }
            var normalized = await normalize(routeKey: hit.key, data: result.json, payload: payload)
            // r49：保留首个 vip 信号——normalize 只看最终一档，前档的 vip
            // 拒绝会被后档洗掉；ladder 任一档拒过时，最终无 url 的项优先
            // 回 reason:"vip"，而不是最后一档的笼统 unavailable。
            if hit.key == "song/url", songUrlSawVipRefusal,
               var items = normalized["data"] as? [[String: Any]] {
                items = items.map { item in
                    var it = item
                    if ((it["url"] as? String) ?? "").isEmpty { it["reason"] = "vip" }
                    return it
                }
                normalized["data"] = items
            }
            // 退出登录：上游已作废 MUSIC_U，本地 session.json 必须一起清掉。
            // 之前这里只转发不清理 —— 退出后死 cookie 还留在本地，之后
            // 每次 /api/session 的 sessionVerify 都拿不到 profile 而回
            // loggedIn:false，且死 cookie 继续跟着每个请求发出去。
            if hit.key == "logout" {
                session.clear()
            }
            if isSearch {
                DiagLog.shared.recordSearch([
                    "endpoint": "/cloudsearch/pc",
                    "ms": Int(Date().timeIntervalSince(t0) * 1000),
                    "http": result.status,
                    "code": normalized["code"] as Any,
                    "count": (normalized["tracks"] as? [[String: Any]])?.count ?? 0,
                    "at": Int(Date().timeIntervalSince1970),
                ])
            }
            return .json(200, normalized)
        } catch {
            if hit.key == "search" {
                DiagLog.shared.recordSearch([
                    "endpoint": "/cloudsearch/pc",
                    "ms": Int(Date().timeIntervalSince(t0) * 1000),
                    "error": error.localizedDescription,
                    "at": Int(Date().timeIntervalSince1970),
                ])
            }
            // 退出登录：上游调用抛错（超时/断网）时本地也必须清掉 —— Folia
            // logout 是先读 cookie 发请求、本地登录态当即作废，不等上游回答。
            // 这里请求本身要带 cookie 头去上游作废，所以不能先清再发；但发
            // 失败也不能留着死 cookie（成功分支已清，只补失败分支）。
            if hit.key == "logout" {
                session.clear()
            }
            return .json(502, ["code": 502, "error": error.localizedDescription])
        }
    }

    private func shapePayload(routeKey: String, payload: [String: Any]) -> [String: Any] {
        var p = payload
        switch routeKey {
        case "login/qr/key":
            p = ["type": 1]
        case "login/qr/check":
            var np: [String: Any] = ["type": 1]
            if let k = p["key"] { np["key"] = k }
            p = np
        case "song/url":
            // kun 对齐（MusicAPI.songURL）：level 原样透传，encodeType 恒为 flac；
            // 只有 sky（环绕声）档加 immerseType c51。档位表按 kun
            // AudioQuality.neteaseLevel 补齐 dolby / sky。
            // 第 13 轮第 12 件：不在表里 / 没传 level 时默认 lossless（不降级），
            // 拿不到所选档时由调用点向低档重试（见 handle 里的 song/url 分支）。
            let levels = ["standard", "higher", "exhigh", "lossless", "hires", "dolby", "jymaster", "jyeffect", "sky"]
            let level = levels.contains(str(p, "level")) ? str(p, "level") : "lossless"
            let ids = idList(p["ids"])
            var np: [String: Any] = ["ids": (try? JSONSerialization.data(withJSONObject: ids)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]",
                 "level": level, "encodeType": "flac"]
            if level == "sky" { np["immerseType"] = "c51" }
            p = np
        case "playlist/detail", "playlist/track/all":
            p = ["id": int(p, "id"), "n": 1000, "s": 8]
        case "lyric":
            p = ["id": int(p, "id"), "cp": false, "lv": -1, "tv": -1, "rv": -1,
                 "kv": -1, "yv": -1, "ytv": -1, "yrv": -1]
        case "song/wiki":
            p = ["songId": int(p, "id")]
        case "user/playlist":
            p = ["uid": int(p, "uid"), "limit": 1000, "offset": 0, "includeVideo": true]
        case "user/cloud":
            p = ["limit": intOr(p, "limit", 200), "offset": intOr(p, "offset", 0)]
        case "user/detail":
            p = ["uid": int(p, "uid") != 0 ? int(p, "uid") : int(p, "userId")]
        case "search":
            // r58 Folia 口径：搜索类型透传（song=1、album=10、playlist=1000，
            // Folia neteaseProvider searchSongs/searchAlbums/searchPlaylists
            // 同款：同一 /cloudsearch/pc 端点，只换 type）。默认 1。
            let typeStr = str(p, "type")
            let typeCode = ["song": 1, "album": 10, "playlist": 1000][typeStr]
                ?? (Int(typeStr) ?? 1)
            p = ["s": str(p, "s").isEmpty ? str(p, "keywords") : str(p, "s"),
                 "type": typeCode, "limit": intOr(p, "limit", 30), "offset": intOr(p, "offset", 0),
                 "total": true]
        case "top/playlist":
            p = ["cat": str(p, "cat").isEmpty ? "全部" : str(p, "cat"),
                 "order": str(p, "order").isEmpty ? "hot" : str(p, "order"),
                 "limit": intOr(p, "limit", 12), "offset": intOr(p, "offset", 0), "total": true]
        case "artist/albums/:id":
            p = ["limit": intOr(p, "limit", 12), "offset": intOr(p, "offset", 0), "total": true]
        case "artist/songs":
            p = ["id": int(p, "id"), "limit": intOr(p, "limit", 100), "offset": intOr(p, "offset", 0),
                 "order": str(p, "order") == "time" ? "time" : "hot"]
        default:
            break
        }
        return p
    }

    private func normalize(routeKey: String, data: [String: Any], payload: [String: Any]) async -> [String: Any] {
        let code = intOr(data, "code", 200)
        switch routeKey {
        case "search":
            let result = dict(data, "result")
            // r58 Folia 口径：type 10 专辑 / 1000 歌单走同一端点回的
            // result.albums / result.playlists（Folia searchAlbums /
            // searchPlaylists 同款字段），归一成客户端 playlistFrom /
            // albumFrom 直接认的平铺字典；默认 type 1 仍是歌。
            let typeCode = (payload["type"] as? NSNumber)?.intValue ?? 1
            if typeCode == 10 {
                let albums = arr(result, "albums").compactMap { toAlbum($0) }
                let count = (result["albumCount"] as? Int) ?? albums.count
                return ["code": code, "albums": albums, "albumCount": count]
            }
            if typeCode == 1000 {
                let playlists = arr(result, "playlists").compactMap { toPlaylist($0) }
                let count = (result["playlistCount"] as? Int) ?? playlists.count
                return ["code": code, "playlists": playlists, "playlistCount": count]
            }
            let tracks = arr(result, "songs").compactMap { toTrack($0) }
            // kun 对齐后搜索走 eapi /cloudsearch/pc：回的歌自带 al.picUrl，
            // toTrack 直接取封面；前端对可见行调 /api/song/detail 懒补的
            // 逻辑仍在（无害，云搜没给的字段才补）。旧 weapi /search/get
            // 回的歌没有 al.picUrl（只有 picId，拼不出封面地址），那条
            // 「每搜一次再调 /v3/song/detail 全量补封面」已被第 8 轮 Folia
            // 化改掉，不再恢复。
            let songCount = (result["songCount"] as? Int) ?? tracks.count
            return ["code": code, "tracks": tracks, "songCount": songCount]
        case "song/url":
            let items = arr(data, "data").map { s -> [String: Any] in
                let url = s["url"] as? String
                // r48-8：会员歌匿名请求时上游回的不是 -110——实测《죽을 만큼
                // 아파서》5400327 匿名调回 per-item code 404 +
                // freeTrialPrivilege.cannotListenReason 1（需会员才能听），
                // 只认 -110 会把这种真 VIP 拒绝也写成笼统 unavailable。
                // code 与 cannotListenReason 透传给桥层，reason 在这里与
                // 桥层同口径判定（见 NativeBridge.songURL 网易分支）。
                let code = s["code"] as? Int ?? 0
                let cannotListen = dict(s, "freeTrialPrivilege")["cannotListenReason"] as? Int ?? 0
                let vipRefusal = url == nil && (code == -110 || cannotListen == 1)
                return [
                    "id": s["id"] as Any,
                    "url": url as Any,
                    "br": s["br"] as Any,
                    "size": s["size"] as Any,
                    "type": s["type"] as Any,
                    "time": s["time"] as Any,
                    "fee": s["fee"] as? Int ?? 0,
                    "code": code,
                    "cannotListenReason": cannotListen,
                    "reason": url != nil ? NSNull() : (vipRefusal ? "vip" : "unavailable"),
                    "freeTrialInfo": s["freeTrialInfo"] as Any,
                    "level": s["level"] as Any,
                ]
            }
            return ["code": code, "data": items]
        case "lyric":
            // r55 Folia 歌词：网易走 weapi /song/lyric/v1（已在线上跑通的端点，
            // 不换），只取字段 + 去 LRCLIB 兜底。Folia 字段形：
            // mainText = lrc.lyric（行级 LRC），wordByWordText = yrc.lyric
            // （逐字 YRC），translationText = tlyric（行级翻译；没有时把逐字
            // 版 ytlrc 转回行级 LRC 再对齐），romanizationText 同理
            // （romalrc / yromalrc）。isPureMusic 取上游 nolyric 标记。
            // 富文本 JSON 转换（旧 richLyricToLrc）已删：Folia 无此处理，
            // lrc.lyric 本身就是 LRC 文本。
            let mainText = str(dict(data, "lrc"), "lyric").isEmpty ? str(data, "lyric") : str(dict(data, "lrc"), "lyric")
            let yrc = str(dict(data, "yrc"), "lyric")
            let tlyric = str(dict(data, "tlyric"), "lyric")
            let ytlrc = str(dict(data, "ytlrc"), "lyric")
            let romalrc = str(dict(data, "romalrc"), "lyric")
            let yromalrc = str(dict(data, "yromalrc"), "lyric")
            return [
                "code": code,
                "mainText": mainText,
                "wordByWordText": yrc,
                "translationText": tlyric.isEmpty ? Self.yrcToLrc(ytlrc) : tlyric,
                "romanizationText": romalrc.isEmpty ? Self.yrcToLrc(yromalrc) : romalrc,
                "isPureMusic": data["nolyric"] as? Bool ?? false,
                "source": "netease",
            ]
        case "playlist/detail", "playlist/track/all":
            let p = dict(data, "playlist")
            var tracks = arr(p, "tracks")
            let ids = arr(p, "trackIds").compactMap { $0["id"] as? Int }
            if ids.count > tracks.count || routeKey == "playlist/track/all" {
                tracks = await fetchTrackDetails(ids)
            }
            let creator = dict(p, "creator")
            return [
                "code": code,
                "playlist": [
                    "id": p["id"] as Any,
                    "name": str(p, "name"),
                    "cover": str(p, "coverImgUrl"),
                    "trackCount": int(p, "trackCount"),
                    "playCount": int(p, "playCount"),
                    "description": str(p, "description"),
                    "creator": creator.isEmpty ? NSNull() : ["nickname": str(creator, "nickname"), "avatar": str(creator, "avatarUrl")],
                ],
                "tracks": tracks.compactMap { toTrack($0) },
            ]
        case "user/playlist":
            let lists = arr(data, "playlist").map { p -> [String: Any] in
                ["id": p["id"] as Any, "name": str(p, "name"), "cover": str(p, "coverImgUrl"),
                 "trackCount": int(p, "trackCount"), "playCount": int(p, "playCount"),
                 "subscribed": p["subscribed"] as? Bool ?? false,
                 "specialType": (p["specialType"] as? NSNumber)?.intValue ?? 0]
            }
            return ["code": code, "playlists": lists]
        case "user/cloud":
            // 上游 /v1/cloud/get 的 data 项：songId / songName / artist / album /
            // fileSize / fileName / addTime。artist 可能是字符串也可能是对象数组，
            // 都归一化成字符串，前端按 songId 或「歌名 + 歌手」匹配。
            let songs = arr(data, "data").map { c -> [String: Any] in
                let artists: String
                if let a = c["artist"] as? String { artists = a }
                else if let list = c["artists"] as? [[String: Any]] {
                    artists = list.compactMap { $0["name"] as? String }.joined(separator: " / ")
                } else if let a = c["artists"] as? String { artists = a }
                else { artists = "" }
                return [
                    "songId": c["songId"] as Any,
                    "name": str(c, "songName").isEmpty ? str(c, "name") : str(c, "songName"),
                    "artists": artists,
                    "album": str(c, "album").isEmpty ? str(c, "albumName") : str(c, "album"),
                    "fileSize": c["fileSize"] as Any,
                    "fileName": str(c, "fileName"),
                ]
            }
            return ["code": code, "count": intOr(data, "count", songs.count),
                    "hasMore": data["hasMore"] as? Bool ?? false, "songs": songs]
        case "user/detail":
            let p = dict(data, "profile")
            return [
                "code": code,
                "level": intOr(data, "level", 0),
                "listenSongs": intOr(data, "listenSongs", 0),
                "createDays": intOr(data, "createDays", 0),
                "canSeePlayRecord": data["peopleCanSeeMyPlayRecord"] as? Bool ?? false,
                "profile": [
                    "userId": int(p, "userId"), "nickname": str(p, "nickname"),
                    "avatar": str(p, "avatarUrl"), "background": str(p, "backgroundUrl"),
                    "signature": str(p, "signature"), "description": str(p, "description"),
                    "follows": int(p, "follows"), "followeds": int(p, "followeds"),
                    "playlistCount": int(p, "playlistCount"), "eventCount": int(p, "eventCount"),
                    "createTime": int(p, "createTime"), "province": int(p, "province"),
                    "city": int(p, "city"), "gender": int(p, "gender"), "vipType": int(p, "vipType"),
                    "auth": (p["allAuthTypes"] as? [[String: Any]] ?? []).compactMap { $0["desc"] as? String },
                ],
            ]
        case "personalized":
            let items = arr(data, "result").map { toTrack(dict($0, "song").isEmpty ? $0 : dict($0, "song")) }
            return ["code": code, "tracks": items.compactMap { $0 }]
        case "top/playlist":
            let list = arr(data, "playlists").isEmpty ? (arr(data, "result").isEmpty ? arr(data, "recommend") : arr(data, "result")) : arr(data, "playlists")
            let lists = list.compactMap { p -> [String: Any]? in
                guard p["id"] != nil else { return nil }
                let cover = str(p, "coverImgUrl").isEmpty ? (str(p, "picUrl").isEmpty ? str(p, "pic") : str(p, "picUrl")) : str(p, "coverImgUrl")
                return ["id": p["id"] as Any, "name": str(p, "name"), "cover": cover,
                        "count": (p["playCount"] as? Int) ?? (p["playcount"] as? Int) ?? 0,
                        "creator": str(dict(p, "creator"), "nickname"),
                        "tracks": int(p, "trackCount")]
            }
            return ["code": code, "more": (data["more"] as? Bool) ?? (data["hasMore"] as? Bool) ?? false, "playlists": lists]
        case "toplist":
            // 排行榜目录：eapi /toplist 回 { code, list: [{ id, name,
            // coverImgUrl, trackCount, ... }] }（VM 实测 65 个榜）。
            // 榜单 id 即歌单 id，详情走 /api/playlist/detail。
            let lists = arr(data, "list").compactMap { p -> [String: Any]? in
                guard p["id"] != nil, !str(p, "name").isEmpty else { return nil }
                let cover = str(p, "coverImgUrl").isEmpty ? (str(p, "picUrl").isEmpty ? str(p, "pic") : str(p, "picUrl")) : str(p, "coverImgUrl")
                return ["id": p["id"] as Any, "name": str(p, "name"), "cover": cover,
                        "tracks": int(p, "trackCount")]
            }
            return ["code": code, "playlists": lists]
        case "song/wiki":
            let blocks = arr(dict(data, "data"), "blocks").isEmpty ? arr(data, "blocks") : arr(dict(data, "data"), "blocks")
            let basic = blocks.first { str($0, "code") == "SONG_PLAY_ABOUT_SONG_BASIC" } ?? [:]
            let creatives = basic["creatives"] as? [[String: Any]] ?? []
            func pick(_ type: String) -> [String: Any] {
                creatives.first { str($0, "creativeType") == type } ?? [:]
            }
            func textOf(_ c: [String: Any]) -> String? {
                let links = arr(dict(c, "uiElement"), "textLinks")
                return links.first.flatMap { str($0, "text").isEmpty ? nil : str($0, "text") }
            }
            func listOf(_ c: [String: Any]) -> [String] {
                (c["resources"] as? [[String: Any]] ?? []).compactMap {
                    let t = str($0, "text")
                    return t.isEmpty ? str($0, "name") : t
                }.filter { !$0.isEmpty }
            }
            let bpmText = textOf(pick("bpm"))
            let bpm: Any = (bpmText != nil && bpmText!.allSatisfy { $0.isNumber }) ? Int(bpmText!) as Any : NSNull()
            let similar = blocks.first { str($0, "code") == "SONG_PLAY_ABOUT_SIMILAR_SONG" } ?? [:]
            var similarIds: [Int] = []
            for c in similar["creatives"] as? [[String: Any]] ?? [] {
                for r in c["resources"] as? [[String: Any]] ?? [] {
                    if let id = r["resourceId"] as? Int ?? r["id"] as? Int { similarIds.append(id) }
                }
            }
            return [
                "code": code, "bpm": bpm,
                "language": textOf(pick("language")) as Any,
                "tags": listOf(pick("songTag")),
                "bizTags": listOf(pick("songBizTag")),
                "awards": listOf(pick("songAward")),
                "similarIds": similarIds,
            ]
        case "recommend/songs":
            // r24 第 1 件根因：上游 /v1/discovery/recommend/songs 回的是
            // { code, data: { dailySongs, recommendReasons } }——dailySongs
            // 包在 data 里，不在顶层。旧写法 arr(data, "dailySongs") 在顶层
            // 找永远是空，再退 arr(data, "recommend") 也是空，于是登录后
            // 每日推荐也永远是空（用户 08:35「每日推荐也没有数据」）。
            // 这条映射不是死代码：/api/recommend/songs 走 handleApi →
            // normalize 才是 NativeBridge.dailyRecommend 的 live 路径；
            // /api/netease/recommend/songs 的 passthrough 才是另一条。
            let inner = dict(data, "data")
            let daily = arr(inner, "dailySongs")
            let fallback = arr(inner, "recommend").isEmpty ? arr(data, "recommend") : arr(inner, "recommend")
            let tracks = (daily.isEmpty ? fallback : daily).compactMap { toTrack($0) }
            return ["code": code, "tracks": tracks]
        case "artist/:id":
            let a = dict(data, "artist")
            return [
                "code": code,
                "artist": [
                    "id": a["id"] as Any, "name": str(a, "name").isEmpty ? str(a, "nickname") : str(a, "name"),
                    "nickname": str(a, "nickname"),
                    "avatar": str(a, "img1v1Url").isEmpty ? (str(a, "cover").isEmpty ? str(a, "picUrl") : str(a, "cover")) : str(a, "img1v1Url"),
                    "cover": str(a, "cover").isEmpty ? str(a, "img1v1Url") : str(a, "cover"),
                    "briefDesc": str(a, "briefDesc"),
                    "albumSize": int(a, "albumSize"), "musicSize": int(a, "musicSize"),
                    "alias": a["alias"] as Any, "trans": str(a, "trans"),
                ],
                "hotSongs": arr(data, "hotSongs").compactMap { toTrack($0) },
            ]
        case "artist/albums/:id":
            let albums = (arr(data, "hotAlbums").isEmpty ? arr(data, "albums") : arr(data, "hotAlbums")).compactMap { a -> [String: Any]? in
                guard a["id"] != nil else { return nil }
                let cover = str(a, "picUrl").isEmpty ? (str(a, "blurPicUrl").isEmpty ? str(a, "coverImgUrl") : str(a, "blurPicUrl")) : str(a, "picUrl")
                return ["id": a["id"] as Any, "name": str(a, "name"), "cover": cover,
                        "publishTime": int(a, "publishTime"),
                        "size": (a["size"] as? Int) ?? (a["songCount"] as? Int) ?? 0]
            }
            return ["code": code, "more": (data["more"] as? Bool) ?? (data["hasMore"] as? Bool) ?? false, "albums": albums]
        case "artist/songs":
            return ["code": code,
                    "total": (data["total"] as? Int) ?? arr(data, "songs").count,
                    "more": (data["more"] as? Bool) ?? (data["hasMore"] as? Bool) ?? false,
                    "songs": arr(data, "songs").compactMap { toTrack($0) }]
        case "album/:id":
            let al = dict(data, "album")
            return [
                "code": code,
                "album": [
                    "id": al["id"] as Any, "name": str(al, "name"),
                    "cover": str(al, "picUrl").isEmpty ? str(al, "blurPicUrl") : str(al, "picUrl"),
                    "company": str(al, "company"), "description": str(al, "description"),
                    "publishTime": int(al, "publishTime"),
                    "size": (al["size"] as? Int) ?? arr(data, "songs").count,
                    "artists": (al["artists"] as? [[String: Any]] ?? al["ar"] as? [[String: Any]] ?? []).map { ["id": $0["id"] as Any, "name": str($0, "name")] },
                ],
                "songs": arr(data, "songs").compactMap { toTrack($0) },
            ]
        case "login/status":
            if let p = profileOf(dict(data, "profile")) {
                return ["loggedIn": true, "profile": p]
            }
            return ["loggedIn": false]
        case "login/qr/key":
            return ["code": code, "key": data["unikey"] as Any, "message": data["message"] as Any]
        case "login/qr/check":
            recordQrCheck(data, channel: "eapi")
            return [
                "code": data["code"] as Any,
                "message": (data["message"] as? String) ?? (data["msg"] as? String) ?? (data["errmsg"] as? String) ?? "",
                "nickname": data["nickname"] as Any,
                "avatar": data["avatarUrl"] as Any,
                "loggedIn": session.hasMusicU,
            ]
        default:
            return data
        }
    }
}

extension NetEaseService {
    // MARK: - /api/netease/*（边车透传的 Swift 实现）

    func handleNetease(_ req: HttpRequest) async -> HttpResponse {
        let part = String(req.path.dropFirst("/api/netease/".count))
        switch part {
        case "health":
            // iOS 上没有独立边车进程；本地服务本身就是健康的。
            return .json(200, ["code": 200, "ok": true])
        case "login/qr/key":
            return await neteaseQrKey()
        case "login/qr/check":
            return await neteaseQrCheck(req)
        case "recommend/songs":
            var p2: [String: Any] = [:]
            if let a = req.params["afresh"] { p2["afresh"] = a }
            // 第 12 轮：旧路径 /api/v3/... 上游回 404「接口未找到」——登录后
            // 每日推荐主路永远 404，前端只能走 3 首兜底。正确路径是
            // /v1/discovery/recommend/songs（路由表里一直是这条，见
            // NetEase.swift 路由表 "recommend/songs"）。
            return await passthroughWeapi("/v1/discovery/recommend/songs", p2)
        case "dj/recommend":
            // r34：limit 透传（壳版 API.neteaseDjRecommend(8) 带 limit=8；
            // 旧写法传 [:]，上游用默认条数，与壳版不是同一参数）。
            return await passthroughWeapi("/api/djradio/recommend/v1", ["limit": req.int("limit", 8)])
        case "dj/program":
            var p3: [String: Any] = [
                "radioId": req.int("rid"), "limit": req.int("limit", 30),
                "offset": req.int("offset"),
            ]
            if let a = req.params["asc"] { p3["asc"] = a }
            return await passthroughWeapi("/api/dj/program/byradio", p3)
        case "album/sublist":
            return await passthroughWeapi("/api/album/sublist", [
                "limit": req.int("limit", 100), "offset": req.int("offset"), "total": true,
            ])
        case "play/record":
            // r31-rank：听歌排行（只做网易服务端排行）。
            return await neteasePlayRecord(req)
        default:
            return .json(404, ["error": "unknown netease api"])
        }
    }

    /// 边车透传：weapi 直连，响应原样返回（无 normalize）。
    private func passthroughWeapi(_ apiPath: String, _ payload: [String: Any]) async -> HttpResponse {
        do {
            let r = try await weapiRequest(apiPath, payload)
            return .json(r.status == 200 ? 200 : r.status, r.json)
        } catch {
            return .json(502, ["code": 502, "error": error.localizedDescription])
        }
    }

    /// 听歌排行（r31-rank）：weapi POST `/v1/play/record`，`{uid, type, limit}`，
    /// type 1 = 最近一周、0 = 所有时间；回包原样返回（`weekData` / `allData`，
    /// 单条 `{playCount, score, song}`，另有 `weekDataSize` / `allDataSize`）。
    ///
    /// uid 不由客户端传：`LoginStore.LoginState` 里没有 uid 字段（只有昵称 /
    /// 头像 / vip），这里用本次登录会话的 `sessionVerify()` 取
    /// `profile.userId`（与 `/api/session` 同源）；没登录 / 会话已死回
    /// code 401（HTTP 200 壳，`NativeBridge.call` 只认 2xx，见其注释），
    /// 客户端按未登录处理（显示登录按钮），不编空榜。
    /// 上游未登录时回 code -2「无权限访问」（VM 实测，见
    /// verification/r31-rank.cjs §8 探针）——那支只有没 MUSIC_U 才走到，
    /// 这里 hasMusicU 已先拦住，探针只是证明端点本身存在且要登录。
    private func neteasePlayRecord(_ req: HttpRequest) async -> HttpResponse {
        guard session.hasMusicU else {
            return .json(200, ["code": 401, "error": "未登录网易云"])
        }
        let type = req.int("type", 1) == 0 ? 0 : 1
        let limit = min(max(req.int("limit", 100), 1), 1000)
        do {
            guard let v = try await sessionVerify(),
                  let profile = v["profile"] as? [String: Any],
                  int(profile, "userId") != 0 else {
                return .json(200, ["code": 401, "error": "未登录网易云"])
            }
            let r = try await weapiRequest("/v1/play/record",
                                           ["uid": int(profile, "userId"), "type": type, "limit": limit])
            return .json(r.status == 200 ? 200 : r.status, r.json)
        } catch {
            return .json(502, ["code": 502, "error": error.localizedDescription])
        }
    }

    // MARK: - 扫码登录（边车版：/api/netease/login/qr/*）

    /// key：eapi /login/qrcode/unikey（type 3，包里模块硬编码），再本地生成二维码图。
    private func neteaseQrKey() async -> HttpResponse {
        do {
            let r = try await eapiRequest("/login/qrcode/unikey", ["type": 3], checkToken: true)
            let unikey = r.json["unikey"] as? String
            guard let unikey, !unikey.isEmpty else {
                return .json(r.json["code"] as? Int ?? 502, [
                    "code": r.json["code"] as Any, "key": NSNull(),
                    "channel": "netease-api",
                    "message": (r.json["message"] as? String) ?? "拿不到二维码 key",
                ])
            }
            let qrimg = qrDataURL(for: "https://music.163.com/login?codekey=\(unikey)")
            return .json(200, ["code": 200, "key": unikey, "qrimg": qrimg, "channel": "netease-api"])
        } catch {
            return .json(502, ["code": 502, "key": NSNull(), "channel": "netease-api", "message": error.localizedDescription])
        }
    }

    /// check：eapi /login/qrcode/client/login（type 3）。803 时当场抓 cookie 并 harvest。
    private func neteaseQrCheck(_ req: HttpRequest) async -> HttpResponse {
        let key = req.string("key")
        guard !key.isEmpty else {
            return .json(400, ["code": 400, "message": "key required"])
        }
        do {
            let r = try await eapiRequest("/login/qrcode/client/login", ["key": key, "type": 3], checkToken: true)
            let code = (r.json["code"] as? NSNumber)?.intValue ?? 0
            let message = (r.json["message"] as? String) ?? (r.json["msg"] as? String) ?? ""
            if code == 803 {
                let extracted = extractCookie(body: r.json, setCookies: r.setCookies)
                if extracted.pairs["MUSIC_U"] != nil {
                    qrCacheSet(key: key, pairs: extracted.pairs, field: extracted.field)
                }
                let h = await runHarvest(key: key)
                recordQrCheck(r.json, channel: "netease-api")
                return .json(200, [
                    "code": code, "message": message.isEmpty ? "授权登陆成功" : message,
                    "hasMusicU": true, "cookieKeys": h["keys"] as Any,
                    "channel": "netease-api", "loggedIn": h["ok"] as? Bool ?? false,
                    "profile": h["profile"] as Any,
                    "harvest": ["tried": h["tried"] as Any, "gotCookie": true, "field": h["field"] as Any],
                ])
            }
            let keys = Array(extractCookie(body: r.json, setCookies: r.setCookies).pairs.keys)
            recordQrCheck(r.json, channel: "netease-api")
            return .json(200, [
                "code": code, "message": message,
                "hasMusicU": keys.contains("MUSIC_U"), "cookieKeys": keys,
                "channel": "netease-api",
            ])
        } catch {
            return .json(502, ["code": 502, "message": error.localizedDescription, "channel": "netease-api"])
        }
    }

    /// 二维码图：CoreImage 生成，与包里 login_qr_create 的 data URL 格式一致
    ///（https://music.163.com/login?codekey=<key>，平台默认 pc，不带 chainId）。
    private func qrDataURL(for urlString: String) -> String {
        guard let data = urlString.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return "" }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return "" }
        let scale = 512.0 / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return "" }
        let image = UIImage(cgImage: cgImage)
        guard let png = image.pngData() else { return "" }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    // MARK: - 扫码诊断

    func recordQrCheck(_ raw: [String: Any], channel: String) {
        lastQrCheck = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "channel": channel,
            "code": raw["code"] as Any,
            "message": (raw["message"] as? String) ?? (raw["msg"] as? String) ?? "",
            "hasMusicU": session.hasMusicU,
            "loggedIn": session.hasMusicU,
            "cookieKeys": session.cookieKeys,
        ]
    }

    func lastQrCheckPayload() -> [String: Any] {
        var out = lastQrCheck ?? [
            "at": NSNull(), "channel": NSNull(), "code": NSNull(),
            "message": "还没有 check 过",
        ]
        out["hasMusicU"] = session.hasMusicU
        out["loggedIn"] = session.hasMusicU
        out["cookieKeys"] = session.cookieKeys
        out["harvest"] = lastHarvest as Any
        return out
    }

    // MARK: - harvest（扫码收尾，harvest-core.mjs 的逻辑）

    private struct QrCacheEntry {
        var pairs: [String: String]
        var field: String?
        var at: Date
    }

    private func qrCacheSet(key: String, pairs: [String: String], field: String?) {
        qrCache[key] = QrCacheEntry(pairs: pairs, field: field, at: Date())
    }

    private func qrCacheGet(key: String) -> QrCacheEntry? {
        qrCache = qrCache.filter { Date().timeIntervalSince($0.value.at) < qrCookieTTL }
        return qrCache[key]
    }

    /// extractCookie：三种来源按优先顺序，优先返回含 MUSIC_U 的那份。
    func extractCookie(body: [String: Any], setCookies: [String]) -> (field: String?, pairs: [String: String]) {
        if let s = body["cookie"] as? String, !s.isEmpty {
            let pairs = parseCookieInput(s)
            if pairs["MUSIC_U"] != nil { return ("body.cookie", pairs) }
            if !pairs.isEmpty { return ("body.cookie", pairs) }
        }
        if let d = body["data"] as? [String: Any], let s = d["cookie"] as? String, !s.isEmpty {
            let pairs = parseCookieInput(s)
            if pairs["MUSIC_U"] != nil { return ("body.data.cookie", pairs) }
            if !pairs.isEmpty { return ("body.data.cookie", pairs) }
        }
        if !setCookies.isEmpty {
            // Set-Cookie 分支必须用逗号感知的解析：URLSession 会把多条 Set-Cookie
            // 拼成一条（", " 连接），parseCookieInput 只按 ';' 切，会把非首位 cookie
            // 的键解析成 ", MUSIC_U" 这类带前导逗号的键，导致 pairs["MUSIC_U"] 查不到
            // ——803 明明到了，harvest 却报 not-authorized（见 runHarvest 兜底）。
            let pairs = SessionStore.parseSetCookieStrings(setCookies)
            if !pairs.isEmpty { return ("set-cookie", pairs) }
        }
        return (nil, [:])
    }

    /// parseCookieInput：宽容解析（去 Cookie: 前缀、去引号、裸值当 MUSIC_U、跳过属性键）。
    func parseCookieInput(_ raw: String) -> [String: String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("cookie:") { s = String(s.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces) }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        if !s.contains("=") && !s.contains(";") {
            return s.isEmpty ? [:] : ["MUSIC_U": s]
        }
        let attrs: Set<String> = ["path", "domain", "expires", "max-age", "secure", "httponly", "samesite", "version", "priority", "comment", "partitioned"]
        var out: [String: String] = [:]
        for seg in s.split(separator: ";") {
            let kv = seg.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces)
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty, !v.isEmpty, !attrs.contains(k.lowercased()) else { continue }
            out[k] = v
        }
        return out
    }

    private func slim(_ pairs: [String: String]) -> [String: String] {
        pairs.filter { !$0.value.isEmpty }
    }

    /// runHarvest：按 cache → recheck → status 的顺序找 MUSIC_U；拿到后快照→整份替换→校验，失败回滚。
    func runHarvest(key: String) async -> [String: Any] {
        var tried: [String] = []
        var code: Int? = nil
        var field: String? = nil
        var pairs: [String: String] = [:]

        if let cached = qrCacheGet(key: key), cached.pairs["MUSIC_U"] != nil {
            tried.append("cache")
            pairs = cached.pairs
            field = cached.field
        }
        if pairs["MUSIC_U"] == nil {
            tried.append("check")
            do {
                let r = try await eapiRequest("/login/qrcode/client/login", ["key": key, "type": 3], checkToken: true)
                code = (r.json["code"] as? NSNumber)?.intValue
                let ex = extractCookie(body: r.json, setCookies: r.setCookies)
                if ex.pairs["MUSIC_U"] != nil {
                    pairs = ex.pairs
                    field = ex.field
                    qrCacheSet(key: key, pairs: pairs, field: field)
                }
            } catch { /* 重查失败就继续走 status */ }
        }
        if pairs["MUSIC_U"] == nil {
            tried.append("status")
            do {
                let r = try await weapiRequest("/w/nuser/account/get", [:])
                let ex = extractCookie(body: r.json, setCookies: r.setCookies)
                if ex.pairs["MUSIC_U"] != nil {
                    pairs = ex.pairs
                    field = ex.field
                }
            } catch { /* 状态也失败就按无 MUSIC_U 处理 */ }
        }

        // 兜底：fetchUpstream 可能已把 MUSIC_U 存进 SessionStore（803 响应
        // 的 Set-Cookie），只是上面三步都没从响应里解析出来。会话本身已登录
        // 就别再报 not-authorized / no-music-u，直接校验它。
        if pairs["MUSIC_U"] == nil, session.hasMusicU {
            do {
                if let v = try await sessionVerify(), let profile = v["profile"] {
                    let out: [String: Any] = [
                        "ok": true, "code": code as Any, "gotCookie": true, "field": "session",
                        "keys": session.cookieKeys, "tried": tried + ["session"], "profile": profile,
                    ]
                    lastHarvest = ["at": ISO8601DateFormatter().string(from: Date()), "ok": true,
                                   "tried": tried + ["session"], "gotCookie": true, "field": "session", "cookieKeys": session.cookieKeys]
                    return out
                }
            } catch { /* 校验出错就按原路返回失败 */ }
        }

        let keys = Array(pairs.keys)
        guard pairs["MUSIC_U"] != nil else {
            let reason = (code != nil && code != 803) ? "not-authorized" : "no-music-u"
            let message = (code != nil && code != 803)
                ? "上游这次回的是 \(code!)（不是 803）：二维码 key 已被用过或已过期"
                : "扫码已确认，但上游这次没下发 MUSIC_U"
            let out: [String: Any] = [
                "ok": false, "reason": reason, "code": code as Any,
                "gotCookie": false, "field": field as Any, "keys": keys, "tried": tried, "message": message,
            ]
            lastHarvest = ["at": ISO8601DateFormatter().string(from: Date()), "ok": false, "reason": reason,
                           "code": code as Any, "tried": tried, "gotCookie": false, "field": field as Any, "cookieKeys": keys]
            return out
        }

        let snap = session.snapshot()
        session.replaceCookies(slim(pairs))
        do {
            if let v = try await sessionVerify(), let profile = v["profile"] {
                let out: [String: Any] = [
                    "ok": true, "code": code as Any, "gotCookie": true, "field": field as Any,
                    "keys": keys, "tried": tried, "profile": profile,
                ]
                lastHarvest = ["at": ISO8601DateFormatter().string(from: Date()), "ok": true,
                               "tried": tried, "gotCookie": true, "field": field as Any, "cookieKeys": keys]
                return out
            }
            session.restore(snap)
            let out: [String: Any] = [
                "ok": false, "reason": "invalid", "code": code as Any, "gotCookie": true,
                "field": field as Any, "keys": keys, "tried": tried,
                "message": "拿到了 MUSIC_U，但用它校验没通过（可能已过期）",
            ]
            lastHarvest = ["at": ISO8601DateFormatter().string(from: Date()), "ok": false, "reason": "invalid",
                           "tried": tried, "gotCookie": true, "field": field as Any, "cookieKeys": keys]
            return out
        } catch {
            session.restore(snap)
            let out: [String: Any] = [
                "ok": false, "reason": "error", "code": code as Any, "gotCookie": true,
                "field": field as Any, "keys": keys, "tried": tried,
                "message": "拿到了 MUSIC_U，但校验时出错了：\(error.localizedDescription)",
            ]
            lastHarvest = ["at": ISO8601DateFormatter().string(from: Date()), "ok": false, "reason": "error",
                           "tried": tried, "gotCookie": true, "field": field as Any, "cookieKeys": keys]
            return out
        }
    }

    func handleLoginHarvest(_ req: HttpRequest) async -> HttpResponse {
        let key = req.string("key")
        guard !key.isEmpty else {
            return .json(400, ["ok": false, "reason": "no-key", "message": "缺少扫码 key"])
        }
        let out = await runHarvest(key: key)
        if out["ok"] as? Bool == true {
            return .json(200, [
                "ok": true, "profile": out["profile"] as Any,
                "harvest": ["tried": out["tried"] as Any, "gotCookie": true, "field": out["field"] as Any],
                "cookieKeys": out["keys"] as Any,
            ])
        }
        return .json(400, [
            "ok": false, "reason": out["reason"] as Any, "code": out["code"] as Any,
            "message": out["message"] as Any,
            "harvest": ["tried": out["tried"] as Any, "gotCookie": false, "field": out["field"] as Any],
            "cookieKeys": out["keys"] as Any,
        ])
    }

    // MARK: - session/import（粘贴 cookie 登录）

    func handleSessionImport(_ req: HttpRequest) async -> HttpResponse {
        let raw = req.string("cookie").isEmpty ? req.string("value") : req.string("cookie")
        let pairs = parseCookieInput(raw)
        let keys = Array(pairs.keys)
        guard pairs["MUSIC_U"] != nil else {
            // r31-cookie：失败也回 HTTP 200 + ok:false（QQ `webLoginImport` /
            // 酷我 `loginCookie` 同款）：原生 `NativeBridge.call` 碰到非 2xx
            // 直接回 nil，body 里的 `message` 到不了 UI；200 才能把「缺
            // MUSIC_U / 已过期」的具体原因原样显示出来。壳版 Node 服务的
            // 400 约定（`public/api.js:129`）不在这改，那是另一份服务。
            return .json(200, [
                "ok": false, "reason": "no-music-u", "keys": keys, "cookieKeys": keys,
                "message": "这段内容里没有 MUSIC_U（F12 → Application → Cookies → music.163.com 里那一项）",
            ])
        }
        let snap = session.snapshot()
        session.replaceCookies(pairs)
        do {
            if let v = try await sessionVerify(), let profile = v["profile"] {
                return .json(200, ["ok": true, "profile": profile, "cookieKeys": keys])
            }
            session.restore(snap)
            return .json(200, [
                "ok": false, "reason": "invalid", "keys": keys, "cookieKeys": keys,
                "message": "这段 cookie 无效或已过期（MUSIC_U 不是当前账号的，或已经登出过）",
            ])
        } catch {
            session.restore(snap)
            return .json(200, [
                "ok": false, "reason": "error", "keys": keys, "cookieKeys": keys,
                "message": "校验登录态失败：\(error.localizedDescription)",
            ])
        }
    }

    // MARK: - sessionVerify（只走自家 weapi；iOS 上没有边车进程）

    /// 有 profile 时返回 { loggedIn: true, profile, vipInfo? }，否则 nil；
    /// 传输失败时抛出。vipInfo 是启动 / 登录成功后 bootstrap 的第二步
    /// （先取 profile 再取 vipInfo，r31-membership）：vip 接口那一步失败
    /// 时不推翻登录态，只是不带 vipInfo（客户端 ensureVIPInfo 再懒补一次）。
    func sessionVerify() async throws -> [String: Any]? {
        let r = try await weapiRequest("/w/nuser/account/get", [:])
        if let p = profileOf(dict(r.json, "profile")) {
            var out: [String: Any] = ["loggedIn": true, "profile": p]
            if let vi = await vipInfo() { out["vipInfo"] = vi }
            return out
        }
        return nil
    }

    /// 会员信息（r31-membership）：weapi POST
    /// `/music-vip-membership/client/vip/info`，看
    /// data.{redplus, associator, musicPackage}.expireTime 是否 > 现在
    /// （redplus = 黑胶 SVIP、associator = 黑胶 VIP、musicPackage = 音乐包）。
    /// 只信 profile.vipType 会误判——部分 SVIP 账号 vipType 回 0，
    /// 最终判定 hasActiveVIP = (vipType > 0) || vipInfo.isActive
    /// （客户端 LoginStore.isVip() 同款）。失败回 nil（未知，不当非会员）。
    func vipInfo() async -> [String: Any]? {
        guard session.hasMusicU else { return nil }
        do {
            let r = try await weapiRequest("/music-vip-membership/client/vip/info", [:])
            guard let data = r.json["data"] as? [String: Any] else { return nil }
            let nowMs = Int(Date().timeIntervalSince1970 * 1000)
            var isActive = false
            var isSuperVIP = false
            var expireTime = 0
            for (key, isSuper) in [("redplus", true), ("associator", false), ("musicPackage", false)] {
                let sub = data[key] as? [String: Any] ?? [:]
                let expire = Self.vipExpireMs(sub["expireTime"])
                guard expire > nowMs else { continue }
                isActive = true
                expireTime = max(expireTime, expire)
                if isSuper { isSuperVIP = true }
            }
            return ["isActive": isActive, "isSuperVIP": isSuperVIP,
                    "label": isSuperVIP ? "SVIP" : (isActive ? "VIP" : ""),
                    "expireTime": expireTime]
        } catch {
            return nil
        }
    }

    /// 到期时间归一（毫秒 epoch）：NSNumber / 数字字符串都认；
    /// 秒级（< 1e12）按秒 ×1000 换算；缺失/非法回 0。
    static func vipExpireMs(_ value: Any?) -> Int {
        let raw: Int
        if let n = value as? NSNumber { raw = n.intValue }
        else if let s = value as? String, let n = Int(s) { raw = n }
        else { return 0 }
        guard raw > 0 else { return 0 }
        return raw < 1_000_000_000_000 ? raw * 1000 : raw
    }
}
