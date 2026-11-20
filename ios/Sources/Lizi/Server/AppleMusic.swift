// MARK: - Apple Music 平台（第 13 轮第 24 件，按 Folia 那套来）
//
// Folia 的做法：原生伴生 App（macOS WKWebView / Windows WebView2）内嵌
// music.apple.com + MusicKit JS，登录在伴生窗口里用 Apple ID 登，播放发生在
// 伴生 WebView 里的 MusicKit 播放器内，Folia 只遥控。v0.7.28 的修法是
// 「MusicKit 原地按账号地区整首播放」，不再本地重解析播放地址。
//
// Lizi 在 iPhone 上走不通伴生这条路，两个硬关卡（已核实，多源一致）：
//   1. 开发者 token：api.music.apple.com 每次请求都要 ES256 JWT（kid + iss +
//      6 个月 exp），用 MusicKit 私钥（.p8）签名；MusicKit key 要在 Apple
//      Developer 门户创建，**要付费 Apple Developer Program（$99/年），没有
//      免费 tier 能开**。未签名 IPA 也没有带 MusicKit 能力的 App ID。
//   2. iPhone 的 WKWebView 没有 EME（WWDC 2022：EME/MSE 只在 iPadOS 16+ 的
//      WKWebView 里有），MusicKit JS 在 iPhone 应用内 WebView 里播不了
//      FairPlay 受保护的整首，只能试听。
// 所以本轮先接公开 API 那一半（全部实测过，2026-11-19 VM curl）：
//   搜索  iTunes Search API（公开、无鉴权；TW 店面中文歌最全，US 兜底英文歌；
//         CN 店面回 0 条，VM 实测周杰伦 CN=0、TW=2、US=2）
//   推荐  Apple 排行榜 RSS（rss.applemarketingtools.com，公开；TW 店面
//         most-played songs/playlists；apple-music/top-songs 旧路径已 404）
//   歌单  RSS 热门歌单 + iTunes lookup（entity=song）取曲目
//   歌词  LRCLIB 兜底（第 20 件开关统一 gate；Apple 没有公开歌词接口，
//         Folia 走 TTML——要 MusicKit 授权，本轮没有）
//   播放  30 秒试听（previewUrl，128k AAC），明确标 试听，不假装整首
// 开发者 token 入口留在设置里（本地保存、绝不上传）：有 token 时搜索走
// api.music.apple.com catalog（代码路径已实现，replica 桩验通）；整首播放
// 要原生 MusicKit 播放器（ApplicationMusicPlayer）+ 用户自己的开发者账号，
// 不在本轮硬编，见汇报诚实边界。
// r31 路线 B ISRC（断点 1）：搜索的 catalog 门以前只认已贴 token，没贴过
// token 的用户永远走 iTunes、拿不到 ISRC。现改走三路 token（已贴 > 缓存
// 网页 > 现抠，见 catalogToken，与 Route B / AppleMusicAuth 同源）；
// catalogSearch 补 Origin 头（网页 token 在官方 host 上无 Origin 会 401，
// VM 实测）与 include=albums，并从 attributes.url 解析专辑 id（search
// 端点不回 relationships，VM 实测；见 catalogSearch 注释）。

import Foundation

final class AppleMusicService {
    static let devTokenKey = "lizi.applemusic.devtoken"
    static let userTokenKey = "lizi.applemusic.usertoken"
    // 实测过的店面链：TW 中文歌最全，US 兜底英文歌，HK 最后。
    static let storefronts = ["tw", "us", "hk"]
    static let catalogSongId = "1441633014" // 验 token 用的一首已知曲目（屋頂）

    private var tokenVerifiedAt: Date = .distantPast
    private var tokenValid: Bool = false
    private var userTokenVerifiedAt: Date = .distantPast
    private var userTokenValid: Bool = false

    private var devToken: String { UserDefaults.standard.string(forKey: Self.devTokenKey) ?? "" }
    private var userToken: String { UserDefaults.standard.string(forKey: Self.userTokenKey) ?? "" }

    // MARK: - r31：catalog 用的三路 token（与 Route B 同源）

    /// 网页播放器 token 缓存键（与 AppleMusicAuth / AppleAnimatedArtworkProvider
    /// 同值，字面量，不跨 target 引用常量——本文件同时编进壳版 Lizi 与原生
    /// LiziNative 两个 target，Auth 与 Route B 只在原生 target 里，直接
    /// 引用会断壳版构建；三份代码共用同一批 UserDefaults 键，缓存互通）。
    static let webTokenKey = "lizi.applemusic.webtoken"
    static let webTokenExpKey = "lizi.applemusic.webtoken.exp"

    /// 未过期的缓存网页 token（1 小时余量，与 Auth / Route B 同款判断），
    /// 没有或已过期回 nil，调用方现抠。
    private func cachedWebToken() -> String? {
        guard let cached = UserDefaults.standard.string(forKey: Self.webTokenKey),
              !cached.isEmpty,
              let exp = UserDefaults.standard.object(forKey: Self.webTokenExpKey) as? Date,
              exp > Date().addingTimeInterval(3600) else { return nil }
        return cached
    }

    /// catalog 搜索用的开发者 token（三路：用户已贴 > 未过期的缓存网页
    /// token > 现抠）。空 = 三条路全没拿到（没网 / 苹果改版抠不到），
    /// 调用方回落 iTunes，搜索不断。
    /// skipPasted=true 时只走网页 token 两路（catalogSearch 里已贴 token
    /// 被 401/403 拒后的重试用；Route B 的 ampGet 同款两段试法）。
    private func catalogToken(skipPasted: Bool = false) async -> String {
        if !skipPasted, !devToken.isEmpty { return devToken }
        if let cached = cachedWebToken() { return cached }
        if let (token, _) = await scrapeWebToken() { return token }
        return ""
    }

    /// 现抠网页播放器 token：GET https://music.apple.com →
    /// /assets/index~*.js → 按 payload 前缀 `eyJpc3MiOiJBTVBXZWJQbGF5`
    /// 定位 iss=AMPWebPlay 的 JWT（方法与 AppleAnimatedArtwork.scrapeWebToken /
    /// AppleMusicAuth.scrapeWebToken 同款；本文件不能直接调它们——前者在原生
    /// target，后者同上，且壳版 target 没有这两个文件）。
    /// 成功时写盘缓存并返回 (token, exp)；任何一步失败回 nil。token 是
    /// 网页播放器公开自带的（任何浏览器打开网页就能拿到），不是用户私密凭证。
    /// 首页 2.4MB + bundle 3.3MB：8MB 上限，超了直接放弃（Route B 同款保护）。
    private func scrapeWebToken() async -> (String, Date)? {
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
        guard let homeURL = URL(string: "https://music.apple.com"),
              let (homeData, _) = try? await Upstream.fetch(homeURL, headers: ["User-Agent": ua], timeout: 15),
              homeData.count < 8_000_000,
              let home = String(data: homeData, encoding: .utf8),
              let bundleRegex = try? NSRegularExpression(pattern: "/assets/index~[^\"'\\s]*\\.js"),
              let bundleMatch = bundleRegex.firstMatch(in: home, range: NSRange(home.startIndex..., in: home)),
              let bundleRange = Range(bundleMatch.range, in: home),
              let bundleURL = URL(string: "https://music.apple.com" + String(home[bundleRange])),
              let (jsData, _) = try? await Upstream.fetch(bundleURL, headers: ["User-Agent": ua], timeout: 15),
              jsData.count < 8_000_000,
              let js = String(data: jsData, encoding: .utf8),
              let tokenRegex = try? NSRegularExpression(pattern: "eyJ[A-Za-z0-9_-]+\\.eyJpc3MiOiJBTVBXZWJQbGF5[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"),
              let tokenMatch = tokenRegex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
              let tokenRange = Range(tokenMatch.range, in: js) else { return nil }
        let token = String(js[tokenRange])
        guard let exp = Self.jwtExpiry(token) else { return nil }
        UserDefaults.standard.set(token, forKey: Self.webTokenKey)
        UserDefaults.standard.set(exp, forKey: Self.webTokenExpKey)
        return (token, exp)
    }

    /// 解 JWT payload 的 exp（只读时间戳，不碰签名、不校验签名——苹果的
    /// token 只当不透明凭证用，服务端会校验；与 Route B 的 expiry(ofJWT:)
    /// 同款）。
    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - 路由

    func handle(_ req: HttpRequest) async -> HttpResponse {
        let part = String(req.path.dropFirst("/api/applemusic/".count))
        do {
            switch part {
            case "", "health":
                return .json(200, ["code": 200, "ok": true, "audio": true, "login": "token", "preview": true,
                                   "note": "公开 API：搜索/推荐/歌单/歌词；播放是 30 秒试听；整首要开发者 token + 原生 MusicKit 播放器"])
            case "status", "login/status":
                return .json(200, await statusBody())
            case "login/token":
                return await loginToken(req)
            case "logout":
                UserDefaults.standard.removeObject(forKey: Self.devTokenKey)
                UserDefaults.standard.removeObject(forKey: Self.userTokenKey)
                tokenValid = false; userTokenValid = false
                tokenVerifiedAt = .distantPast; userTokenVerifiedAt = .distantPast
                return .json(200, ["code": 200, "loggedIn": false])
            case "search":
                return try await search(req)
            case "daily":
                return try await daily(req)
            case "playlists", "recommend/playlists":
                return try await playlists(req)
            case "playlist/tracks":
                return try await playlistTracks(req)
            case "song/url":
                return try await songUrl(req)
            case "lyric":
                return try await lyric(req)
            default:
                return .json(404, ["code": 404, "error": "unknown applemusic api: \(part)"])
            }
        } catch {
            return .json(502, ["code": 502, "error": error.localizedDescription])
        }
    }

    // MARK: - 登录态（token）

    private func loginToken(_ req: HttpRequest) async -> HttpResponse {
        guard req.method == "POST" else {
            return .json(405, ["code": 405, "error": "请用 POST 提交 token"])
        }
        let token = req.string("token").trimmingCharacters(in: .whitespaces)
        let utoken = req.string("userToken").trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else {
            return .json(200, ["code": 200, "loggedIn": false, "error": "开发者 token 是空的"])
        }
        // r25 U8：JWT 三段格式校验 + catalog 真校验都在落盘之前。
        // 以前是先存盘、再由 statusBody 验，验失败也不清，脏 token 一直留
        // 在盘上、每次 status 都要再验一次。现：验失败不写盘。
        guard token.split(separator: ".").count == 3 else {
            return .json(200, ["code": 200, "loggedIn": false,
                               "error": "开发者 token 不是 JWT 格式（应为三段 base64，用 MusicKit 私钥签发）"])
        }
        let verified = await verifyDevToken(token)
        if verified == false {
            // catalog 明确判无效（401/403）：不写盘新 token，并清掉已存的
            // 旧 token + 复位校验缓存，错误原样回给 UI。
            UserDefaults.standard.removeObject(forKey: Self.devTokenKey)
            tokenValid = false; tokenVerifiedAt = .distantPast
            return .json(200, ["code": 200, "loggedIn": false,
                               "error": "开发者 token 无效或已过期（catalog 校验失败）"])
        }
        if verified == nil {
            // 限流/网络等不定论：不写盘新 token，也不清旧登录态（verifyDevToken
            // 的 nil 一贯是不定论、不清登录态），如实报原因、让用户稍后重试。
            return .json(200, ["code": 200, "loggedIn": false,
                               "error": "没能连上 Apple 校验 token（网络或限流），未保存，请稍后重试"])
        }
        UserDefaults.standard.set(token, forKey: Self.devTokenKey)
        if !utoken.isEmpty { UserDefaults.standard.set(utoken, forKey: Self.userTokenKey) }
        // 刚验过：把这次的通过结果记进 300 秒缓存，免得紧接着的 statusBody
        // 又调一次 catalog；user token 仍按老路子由 statusBody 现验。
        tokenValid = true; tokenVerifiedAt = Date()
        userTokenVerifiedAt = .distantPast
        return .json(200, await statusBody())
    }

    private func statusBody() async -> [String: Any] {
        let hasDev = !devToken.isEmpty
        var valid = false
        if hasDev {
            if Date().timeIntervalSince(tokenVerifiedAt) < 300 {
                valid = tokenValid
            } else if let ok = await verifyDevToken() {
                valid = ok; tokenValid = ok; tokenVerifiedAt = Date()
            } else {
                tokenValid = false; tokenVerifiedAt = Date()
            }
        }
        var sub = false
        if valid && !userToken.isEmpty {
            if Date().timeIntervalSince(userTokenVerifiedAt) < 300 {
                sub = userTokenValid
            } else if let ok = await verifyUserToken() {
                sub = ok; userTokenValid = ok; userTokenVerifiedAt = Date()
            } else {
                userTokenValid = false; userTokenVerifiedAt = Date()
            }
        }
        return ["code": 200, "loggedIn": valid, "vip": sub,
                "nickname": valid ? "Apple Music" : "",
                "error": hasDev ? (valid ? "" : "开发者 token 无效或已过期（catalog 校验失败）")
                                : "未配置开发者 token：搜索/推荐走公开 API，播放是 30 秒试听；整首要 Apple Developer 账号的 MusicKit 开发者 token"]
    }

    /// 开发者 token 校验：catalog 读一首已知曲目（公开文档端点，200 = token 有效）。
    /// 不传参时验已存盘的 token（statusBody 用）；传参验候选 token（loginToken
    /// 落盘前先验，r25 U8）。返回 nil = 其它状态码（限流/网络）不定论，不清登录态。
    private func verifyDevToken(_ candidate: String? = nil) async -> Bool? {
        let token = candidate ?? devToken
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/tw/songs/\(Self.catalogSongId)") else { return nil }
        do {
            let (_, resp) = try await Upstream.fetch(url, headers: ["Authorization": "Bearer \(token)"], timeout: 15)
            if resp.statusCode == 200 { return true }
            if resp.statusCode == 401 || resp.statusCode == 403 { return false }
            return nil // 其它状态码（限流/网络）不定论，不清登录态
        } catch { return nil }
    }

    /// 订阅校验：library 读一首（要 user token；200 = 订阅有效）。
    private func verifyUserToken() async -> Bool? {
        guard let url = URL(string: "https://api.music.apple.com/v1/me/library/songs?limit=1") else { return nil }
        do {
            let (_, resp) = try await Upstream.fetch(url, headers: ["Authorization": "Bearer \(devToken)",
                                                                    "Music-User-Token": userToken], timeout: 15)
            if resp.statusCode == 200 { return true }
            if resp.statusCode == 401 || resp.statusCode == 403 { return false }
            return nil
        } catch { return nil }
    }

    // MARK: - 公开 API：iTunes Search / lookup / RSS

    private static func itunesTrack(_ r: [String: Any]) -> [String: Any]? {
        guard let tid = r["trackId"] else { return nil }
        let name = scStr(r, "trackName")
        guard !name.isEmpty else { return nil }
        let art = scStr(r, "artworkUrl100").replacingOccurrences(of: "100x100bb.jpg", with: "600x600bb.jpg")
        let ms = (r["trackTimeMillis"] as? NSNumber)?.intValue ?? 0
        return ["id": "am-\(tid)", "source": "applemusic", "name": name,
                "artists": scStr(r, "artistName"), "album": scStr(r, "collectionName"),
                "cover": art, "duration": ms, "fee": 0,
                // r30 路线 B：ISRC 透传（iTunes Search/Lookup API 全键列表里
                // 根本没有 isrc，VM 实测确认；本字段恒为空，占位而已。
                // Apple Music 的 ISRC 只走 catalogSearch 的 attributes.isrc）。
                "isrc": scStr(r, "isrc"),
                "previewUrl": scStr(r, "previewUrl")]
    }

    private func itunesSearch(_ s: String, limit: Int) async -> [[String: Any]] {
        for cc in Self.storefronts {
            let lang = cc == "tw" ? "zh_tw" : (cc == "hk" ? "zh_hk" : "en_us")
            guard let url = URL(string: "https://itunes.apple.com/search?term=\(scURLEncode(s))&media=music&entity=song&limit=\(limit)&country=\(cc)&lang=\(lang)") else { continue }
            guard let j = try? await Upstream.fetchJSON(url, timeout: 15) as? [String: Any],
                  let list = j["results"] as? [[String: Any]], !list.isEmpty else { continue }
            return list.compactMap(Self.itunesTrack)
        }
        return []
    }

    /// iTunes lookup：一批 id 一次取回 previewUrl + 时长（daily/playlist 用）。
    private func itunesLookup(ids: [String], country: String = "tw") async -> [[String: Any]] {
        let clean = ids.map { $0.hasPrefix("am-") ? String($0.dropFirst(3)) : $0 }.filter { !$0.isEmpty }
        guard !clean.isEmpty,
              let url = URL(string: "https://itunes.apple.com/lookup?id=\(clean.joined(separator: ","))&entity=song&country=\(country)") else { return [] }
        guard let j = try? await Upstream.fetchJSON(url, timeout: 15) as? [String: Any],
              let list = j["results"] as? [[String: Any]] else { return [] }
        return list.compactMap(Self.itunesTrack)
    }

    private func rssFeed(kind: String, limit: Int) async -> [[String: Any]] {
        // 实测：/api/v2/tw/music/most-played/<n>/songs.json 与 playlists.json 通；
        // 旧路径 apple-music/top-songs 已 404。
        guard let url = URL(string: "https://rss.applemarketingtools.com/api/v2/tw/music/most-played/\(limit)/\(kind).json") else { return [] }
        guard let j = try? await Upstream.fetchJSON(url, timeout: 15) as? [String: Any],
              let feed = j["feed"] as? [String: Any],
              let list = feed["results"] as? [[String: Any]] else { return [] }
        return list
    }

    // MARK: - 端点

    private func search(_ req: HttpRequest) async throws -> HttpResponse {
        let s = [req.string("s"), req.string("key"), req.string("keywords")].first(where: { !$0.isEmpty }) ?? ""
        let sTrim = s.trimmingCharacters(in: .whitespaces)
        guard !sTrim.isEmpty else {
            return .json(200, ["code": 200, "source": "applemusic", "tracks": [], "songCount": 0])
        }
        let limit = max(1, min(50, req.int("limit", 20)))
        // r31：catalog 门改走三路 token（已贴 > 缓存网页 > 现抠）；r30 之前
        // 只认已贴 token，没贴过 token 的用户永远走 iTunes、拿不到 ISRC
        // （r31 断点 1：iTunes API 全键列表里根本没有 isrc）。三路全灭 /
        // catalog 查不到时 catalogSearch 回 nil，仍回落 iTunes，搜索不断。
        let token = await catalogToken()
        if !token.isEmpty, let tracks = await catalogSearch(sTrim, limit: limit, token: token) {
            return .json(200, ["code": 200, "source": "applemusic", "tracks": tracks, "songCount": tracks.count])
        }
        let tracks = await itunesSearch(sTrim, limit: limit)
        return .json(200, ["code": 200, "source": "applemusic", "tracks": tracks, "songCount": tracks.count])
    }

    /// catalog 搜索（r31：token 由调用方按三路规则给；失败回 nil 走公开 API）。
    /// 两个 VM 实测点（2026-11-21，网页 token）：
    /// - 官方 api.music.apple.com 上网页 token 必须带 Origin，否则 401
    ///   （无 Origin → 401，有 Origin → 200；Route B 的 amp-api 同款要求）。
    ///   已贴的正式开发者 token 不受影响（多一个 Origin 头而已）。
    /// - search 端点忽略 include=albums：song 对象只有 id/type/href/
    ///   attributes，没有 relationships、也没有顶层 included——专辑 id
    ///   不能从 relationships 取。实际来源是 attributes.url：
    ///   https://music.apple.com/{sf}/album/<slug>/<albumId>?i=<songId>，
    ///   解析出的 albumId 与 songs/{id}?include=albums 的 relationships
    ///   对得上（tw/us 各 5 首实测全对，含 Anti-Hero 的 Midnights
    ///   1649434004）。relationships 分支是防御性的：万一苹果以后在
    ///   search 里回 relationships，优先用它。include=albums 仍带上
    ///   （无害，苹果以后认了直接生效）。
    /// - isrc 在 attributes.isrc 里（实测 TWK972201202 等），随字典回给
    ///   Track.from；albumId 同样进字典（NativeBridge 已接 dict["albumId"]，
    ///   不用改 Track.from）。albumId 只是 hint：没有它时路线 B 的
    ///   song-id 路（songs/{id}?include=albums）一样能拿到专辑。
    /// 已贴 token 被 401/403 拒时，改用网页 token 再试一次（Route B 的
    /// ampGet 同款两段试法；网页 token 本身被拒时不再试，直接回 nil）。
    private func catalogSearch(_ s: String, limit: Int, token: String) async -> [[String: Any]]? {
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/tw/search?types=songs&include=albums&term=\(scURLEncode(s))&limit=\(limit)") else { return nil }
        let isPasted = !devToken.isEmpty && token == devToken
        for attempt in 0..<2 {
            let t: String
            if attempt == 0 {
                t = token
            } else {
                guard isPasted else { return nil }
                t = await catalogToken(skipPasted: true)
                guard !t.isEmpty else { return nil }
            }
            var headers = ["Authorization": "Bearer \(t)", "Origin": "https://music.apple.com"]
            if !userToken.isEmpty { headers["Music-User-Token"] = userToken }
            guard let (data, resp) = try? await Upstream.fetch(url, headers: headers, timeout: 15) else { return nil }
            let status = resp.statusCode
            if status == 200 {
                guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = j["results"] as? [String: Any],
                      let songs = results["songs"] as? [String: Any],
                      let list = songs["data"] as? [[String: Any]] else { return nil }
                return list.compactMap { d -> [String: Any]? in
                    guard let a = d["attributes"] as? [String: Any] else { return nil }
                    let name = scStr(a, "name")
                    guard !name.isEmpty else { return nil }
                    let artT = scStr(a["artwork"] as? [String: Any] ?? [:], "url")
                        .replacingOccurrences(of: "{w}", with: "600").replacingOccurrences(of: "{h}", with: "600")
                    let previews = a["previews"] as? [[String: Any]]
                    let ms = (a["durationInMillis"] as? NSNumber)?.intValue ?? 0
                    return ["id": "am-\(scStr(d, "id"))", "source": "applemusic", "name": name,
                            "artists": scStr(a, "artistName"), "album": scStr(a, "albumName"),
                            "cover": artT, "duration": ms, "fee": 0,
                            // r30 路线 B：ISRC（catalog attributes.isrc，VM 实测有值，
                            // 如 TWK972201202；这是 7 个平台里唯一能拿到 ISRC 的路）。
                            // r31：门已开——三路 token 下无粘贴 token 也能走 catalog。
                            "isrc": scStr(a, "isrc"),
                            // r31：专辑 id（hint，供路线 B 的 hint 路径省一次查找；
                            // 没有它也不影响，song-id 路一样能拿到）。
                            "albumId": Self.albumIdFromCatalogSong(d, attributes: a),
                            "previewUrl": previews?.first.map { scStr($0, "url") } ?? ""]
                }
            }
            if status == 401 || status == 403 { continue }
            return nil
        }
        return nil
    }

    /// catalog search 行 → 专辑 id。优先 relationships.albums（search
    /// 目前不回，防御性）；否则解析 attributes.url 里的
    /// /album/<slug>/<albumId>?i=<songId>（VM 实测与 song-detail 的
    /// relationships 对得上，见 catalogSearch 注释）。解析不上回 ""，
    /// 不编假 id、不发额外请求。
    private static func albumIdFromCatalogSong(_ d: [String: Any], attributes a: [String: Any]) -> String {
        if let rel = d["relationships"] as? [String: Any],
           let albums = rel["albums"] as? [String: Any],
           let list = albums["data"] as? [[String: Any]],
           let id = list.first?["id"] as? String, !id.isEmpty { return id }
        let url = scStr(a, "url")
        guard let range = url.range(of: "/album/") else { return "" }
        let tail = url[range.upperBound...]
        let parts = tail.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return "" }
        let idPart = parts[1].split(separator: "?").first.map(String.init) ?? ""
        guard !idPart.isEmpty, idPart.allSatisfy({ $0.isNumber }) else { return "" }
        return idPart
    }

    private func daily(_ req: HttpRequest) async throws -> HttpResponse {
        let limit = max(1, min(50, req.int("limit", 20)))
        let rss = await rssFeed(kind: "songs", limit: limit)
        guard !rss.isEmpty else {
            return .json(200, ["code": 200, "source": "applemusic", "tracks": [], "error": "Apple 排行榜拉不到"])
        }
        let ids = rss.compactMap { scStr($0, "id") }
        let looked = await itunesLookup(ids: ids)
        var byId: [String: [String: Any]] = [:]
        for t in looked { if let id = t["id"] as? String { byId[id] = t } }
        // lookup 漏掉的保留 RSS 的名字/歌手/封面（无试听，song/url 再补）。
        let tracks: [[String: Any]] = rss.map { r in
            let id = "am-\(scStr(r, "id"))"
            if let full = byId[id] { return full }
            let art = scStr(r, "artworkUrl100").replacingOccurrences(of: "100x100bb.jpg", with: "600x600bb.jpg")
            return ["id": id, "source": "applemusic", "name": scStr(r, "name"),
                    "artists": scStr(r, "artistName"), "album": "", "cover": art,
                    "duration": 0, "fee": 0, "previewUrl": ""]
        }
        return .json(200, ["code": 200, "source": "applemusic", "name": "Apple Music 热门歌曲",
                           "from": "chart", "tracks": tracks])
    }

    private func playlists(_ req: HttpRequest) async throws -> HttpResponse {
        let limit = max(1, min(50, req.int("limit", 12)))
        let rss = await rssFeed(kind: "playlists", limit: limit)
        let lists: [[String: Any]] = rss.map { r in
            let art = scStr(r, "artworkUrl100").replacingOccurrences(of: "100x100bb.jpg", with: "600x600bb.jpg")
            return ["id": "ampl-\(scStr(r, "id"))", "source": "applemusic", "name": scStr(r, "name"),
                    "cover": art, "trackCount": 0]
        }
        return .json(200, ["code": 200, "source": "applemusic", "playlists": lists])
    }

    private func playlistTracks(_ req: HttpRequest) async throws -> HttpResponse {
        var id = [req.string("id"), req.string("playlistId")].first(where: { !$0.isEmpty }) ?? ""
        if id.hasPrefix("ampl-") { id = String(id.dropFirst(5)) }
        guard !id.isEmpty,
              let url = URL(string: "https://itunes.apple.com/lookup?id=\(scURLEncode(id))&entity=song&country=tw") else {
            return .json(200, ["code": 200, "source": "applemusic", "tracks": [], "error": "歌单 id 是空的"])
        }
        guard let j = try? await Upstream.fetchJSON(url, timeout: 15) as? [String: Any],
              let list = j["results"] as? [[String: Any]] else {
            return .json(200, ["code": 200, "source": "applemusic", "tracks": [], "error": "歌单拉不到"])
        }
        // results[0] 是歌单本身，后面是曲目。r25-B4：把歌单本身的
        // collectionName / artworkUrl100 透出来（{ name, cover }，
        // NativeBridge.playlistFrom 认这两个键），详情页才能显示真名真封面；
        // 没有该字段的回包（results 为空或首条不是歌单）保持空串，不编。
        // 封面与曲目同一口径升到 600（itunesTrack 同款替换）。
        let head = list.first(where: { !scStr($0, "collectionName").isEmpty })
        let plName = head.map { scStr($0, "collectionName") } ?? ""
        let plCover = head.map { scStr($0, "artworkUrl100").replacingOccurrences(of: "100x100bb.jpg", with: "600x600bb.jpg") } ?? ""
        let tracks = list.dropFirst().compactMap(Self.itunesTrack)
        return .json(200, ["code": 200, "source": "applemusic", "name": plName, "cover": plCover, "tracks": tracks])
    }

    private func songUrl(_ req: HttpRequest) async throws -> HttpResponse {
        var id = [req.string("id"), req.string("mid")].first(where: { !$0.isEmpty }) ?? ""
        if id.hasPrefix("am-") { id = String(id.dropFirst(3)) }
        guard !id.isEmpty else {
            return .json(200, ["code": 200, "url": "", "preview": true, "error": "id required"])
        }
        if !devToken.isEmpty,
           let url = URL(string: "https://api.music.apple.com/v1/catalog/tw/songs/\(scURLEncode(id))"),
           let j = try? await Upstream.fetchJSON(url, headers: ["Authorization": "Bearer \(devToken)"], timeout: 15) as? [String: Any],
           let data = j["data"] as? [[String: Any]], let first = data.first,
           let a = first["attributes"] as? [String: Any] {
            let previews = a["previews"] as? [[String: Any]]
            let purl = previews?.first.map { scStr($0, "url") } ?? ""
            let ms = (a["durationInMillis"] as? NSNumber)?.intValue ?? 0
            return .json(200, ["code": 200, "url": purl, "preview": true, "quality": "standard",
                               "duration": ms / 1000, "note": "30 秒试听；整首要原生 MusicKit 播放器"])
        }
        let looked = await itunesLookup(ids: [id])
        guard let t = looked.first, let purl = t["previewUrl"] as? String, !purl.isEmpty else {
            return .json(200, ["code": 200, "url": "", "preview": true,
                               "error": "这首歌没有试听地址（Apple Music 无公开整首流）"])
        }
        let ms = (t["duration"] as? NSNumber)?.intValue ?? 0
        return .json(200, ["code": 200, "url": purl, "preview": true, "quality": "standard",
                           "duration": ms / 1000, "note": "30 秒试听；整首要原生 MusicKit 播放器"])
    }

    private func lyric(_ req: HttpRequest) async throws -> HttpResponse {
        // Apple 没有公开歌词接口（Folia 走 MusicKit TTML，要授权）；直接走 LRCLIB，
        // 开关在 Lrclib.fetch 里统一 gate（第 20 件）。
        let artist = req.string("artist")
        let track = [req.string("s"), req.string("name")].first(where: { !$0.isEmpty }) ?? ""
        let album = req.string("album")
        let dur = req.int("duration")
        if let hit = await Lrclib.fetch(artist: artist, track: track, album: album, duration: dur) {
            return .json(200, ["code": 200, "lyric": hit.lyric, "yrc": hit.yrc, "format": "lrc", "source": "lrclib"])
        }
        return .json(200, ["code": 200, "lyric": "", "yrc": "", "format": "none"])
    }
}
