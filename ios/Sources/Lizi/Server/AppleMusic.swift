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
        // 只做格式校验（JWT 三段），真校验走 statusBody 的 catalog 调用。
        guard token.split(separator: ".").count == 3 else {
            return .json(200, ["code": 200, "loggedIn": false,
                               "error": "开发者 token 不是 JWT 格式（应为三段 base64，用 MusicKit 私钥签发）"])
        }
        UserDefaults.standard.set(token, forKey: Self.devTokenKey)
        if !utoken.isEmpty { UserDefaults.standard.set(utoken, forKey: Self.userTokenKey) }
        tokenVerifiedAt = .distantPast; userTokenVerifiedAt = .distantPast
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
    private func verifyDevToken() async -> Bool? {
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/tw/songs/\(Self.catalogSongId)") else { return nil }
        do {
            let (_, resp) = try await Upstream.fetch(url, headers: ["Authorization": "Bearer \(devToken)"], timeout: 15)
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
        if !devToken.isEmpty, let tracks = await catalogSearch(sTrim, limit: limit) {
            return .json(200, ["code": 200, "source": "applemusic", "tracks": tracks, "songCount": tracks.count])
        }
        let tracks = await itunesSearch(sTrim, limit: limit)
        return .json(200, ["code": 200, "source": "applemusic", "tracks": tracks, "songCount": tracks.count])
    }

    /// catalog 搜索（有开发者 token 时走 api.music.apple.com；失败回 nil 走公开 API）。
    private func catalogSearch(_ s: String, limit: Int) async -> [[String: Any]]? {
        guard let url = URL(string: "https://api.music.apple.com/v1/catalog/tw/search?types=songs&term=\(scURLEncode(s))&limit=\(limit)") else { return nil }
        var headers = ["Authorization": "Bearer \(devToken)"]
        if !userToken.isEmpty { headers["Music-User-Token"] = userToken }
        guard let j = try? await Upstream.fetchJSON(url, headers: headers, timeout: 15) as? [String: Any],
              let results = j["results"] as? [String: Any],
              let songs = results["songs"] as? [String: Any],
              let data = songs["data"] as? [[String: Any]] else { return nil }
        return data.compactMap { d -> [String: Any]? in
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
                    "previewUrl": previews?.first.map { scStr($0, "url") } ?? ""]
        }
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
        // results[0] 是歌单本身，后面是曲目。
        let tracks = list.dropFirst().compactMap(Self.itunesTrack)
        return .json(200, ["code": 200, "source": "applemusic", "tracks": tracks])
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
