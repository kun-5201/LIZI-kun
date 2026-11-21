import Foundation

/// QQ 音乐本机直连 API（r31-qqkg：登录改本机直连，不再调服务端桥接）。
///
/// 流程只学 Moumusic 的接口与步骤（ptlogin 网页扫码），代码是按 Lizi
/// 结构新写的；服务端 `QQ.swift` 里已有的同款 ptlogin 实现（`ptQrCode` /
/// `ptPoll` / `ptCompleteOAuth`）是同一流程的 Lizi 版，常数与参数与之
/// 对齐，细节以这里为准：
///   xlogin 取 pt_login_sig → ptqrshow 取图 + qrsig → ptqrlogin 轮询
///   → 0 成功后手动跟 check_sig 跳转链（最多 6 跳，不用自动跳转）
///   → graph authorize 换 code（三档变体）→ musicu QQLogin 换 musickey。
///
/// Cookie 全部由本 actor 的字典 jar 手工收发，不走 URLSession 共享罐：
/// qrsig 单次有效，新旧两份签名混发会让一次有效扫码被报过期。
/// Cookie 值绝不打日志、不进诊断。
private final class LiziQQNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor QQMusicAPI {
    static let shared = QQMusicAPI()

    struct QRCodePayload: Sendable {
        let imageData: Data
        let qrsig: String
    }

    enum QRStatus: Sendable {
        case waiting
        case scanned
        case success(cookie: String)
        case expired
    }

    struct Profile: Sendable {
        let id: String
        let name: String
        let avatarURL: String?
        let refreshedCookie: String?
    }

    struct ResolvedAudio: Sendable {
        let url: URL
        let quality: String
    }

    struct AccountPlaylist: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let count: Int
        let coverURL: String?
    }

    enum APIError: LocalizedError {
        case invalidResponse
        case unavailable
        case qrCodeUnavailable
        case oauthFailed
        /// 100035（用户未登录）这类服务端拦截：界面按它停下来指路网页登录，不再空转换码。
        case oauthNeedsWebLogin
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "QQ 音乐登录状态无法识别，请重新获取二维码"
            case .unavailable: return "QQ 音乐登录已失效或 Cookie 已过期"
            case .qrCodeUnavailable: return "QQ 当前拒绝了二维码请求，请稍后重试"
            case .oauthFailed: return "QQ 扫码成功，但音乐登录凭证获取失败，请重新扫码"
            case .oauthNeedsWebLogin: return "QQ 扫码成功，但音乐登录凭证获取失败（100035 用户未登录），请用网页登录"
            }
        }
    }

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
    private static let musicuURL = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
    private static let profileURL = URL(string: "https://c.y.qq.com/rsc/fcgi-bin/fcg_get_profile_homepage.fcg")!

    private let session: URLSession
    /// ptlogin 会话 jar：名 → 值（只记本次扫码流程收到的 Set-Cookie）。
    private var ptCookies: [String: String] = [:]
    private var ptLoginSig: String?

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        session = URLSession(configuration: config, delegate: LiziQQNoRedirectDelegate(), delegateQueue: nil)
    }

    // MARK: - 扫码取码

    /// 先清全部 Cookie → GET xlogin 取 pt_login_sig → GET ptqrshow 取图 + qrsig。
    /// 403 或回 HTML 反爬页 = 取码失败（抛 qrCodeUnavailable）。
    func qrCode() async throws -> QRCodePayload {
        ptCookies.removeAll()
        ptLoginSig = nil
        // 1. 登录页拿 pt_login_sig（拿不到也不致命：轮询时 login_sig 送空串）。
        if let xlogin = URL(string: "https://xui.ptlogin2.qq.com/cgi-bin/xlogin?appid=716027609&daid=383&style=33&login_text=%E7%99%BB%E5%BD%95&hide_title_bar=1&hide_border=1&target=self&s_url=https%3A%2F%2Fgraph.qq.com%2Foauth2.0%2Flogin_jump&pt_3rd_aid=100497308&theme=2&verify_theme=") {
            var req = URLRequest(url: xlogin, timeoutInterval: 10)
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            if let (_, resp) = try? await session.data(for: req) {
                collectCookies(from: resp)
                ptLoginSig = ptCookies["pt_login_sig"]
            }
        }
        // 2. 取二维码图（图本身就是 body；qrsig 在 Set-Cookie 里）。
        var comps = URLComponents(string: "https://ssl.ptlogin2.qq.com/ptqrshow")!
        comps.queryItems = [
            URLQueryItem(name: "appid", value: "716027609"),
            URLQueryItem(name: "e", value: "2"),
            URLQueryItem(name: "l", value: "M"),
            URLQueryItem(name: "s", value: "3"),
            URLQueryItem(name: "d", value: "72"),
            URLQueryItem(name: "v", value: "4"),
            URLQueryItem(name: "t", value: String(format: "%.6f", Double.random(in: 0...1))),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
        ]
        guard let showURL = comps.url else { throw APIError.qrCodeUnavailable }
        var req = URLRequest(url: showURL, timeoutInterval: 10)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: req)
        collectCookies(from: response)
        if (response as? HTTPURLResponse)?.statusCode == 403 { throw APIError.qrCodeUnavailable }
        guard Self.isSuccess(response),
              let qrsig = ptCookies["qrsig"], !qrsig.isEmpty else { throw APIError.qrCodeUnavailable }
        // QQ 偶尔回 200 的 HTML 反爬页：绝不把它当二维码图发给界面。
        guard Self.looksLikeImage(data) else { throw APIError.qrCodeUnavailable }
        return QRCodePayload(imageData: data, qrsig: qrsig)
    }

    // MARK: - 轮询

    /// 一次 ptqrlogin：66 等待 / 67 已扫 / 65·68 过期 / 0 成功（成功时
    /// 在里面走完凭证交换，返回整罐 Cookie）。
    /// o1vId 必带：缺了扫码回 0 但 check_sig 拿不到 skey/p_skey。
    func poll(qrsig: String) async throws -> QRStatus {
        ptCookies["qrsig"] = qrsig
        var comps = URLComponents(string: "https://ssl.ptlogin2.qq.com/ptqrlogin")!
        comps.queryItems = [
            URLQueryItem(name: "u1", value: "https://graph.qq.com/oauth2.0/login_jump"),
            URLQueryItem(name: "ptqrtoken", value: String(Self.hash33(qrsig))),
            URLQueryItem(name: "ptredirect", value: "0"),
            URLQueryItem(name: "h", value: "1"),
            URLQueryItem(name: "t", value: "1"),
            URLQueryItem(name: "g", value: "1"),
            URLQueryItem(name: "from_ui", value: "1"),
            URLQueryItem(name: "ptlang", value: "2052"),
            URLQueryItem(name: "action", value: "0-0-\(Int(Date().timeIntervalSince1970 * 1000))"),
            URLQueryItem(name: "js_ver", value: "22080914"),
            URLQueryItem(name: "js_type", value: "1"),
            URLQueryItem(name: "login_sig", value: ptLoginSig ?? ""),
            URLQueryItem(name: "pt_uistyle", value: "40"),
            URLQueryItem(name: "aid", value: "716027609"),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
            URLQueryItem(name: "o1vId", value: "49283d5cbb01a744d46314da4608d929"),
        ]
        guard let url = comps.url else { throw APIError.invalidResponse }
        var req = URLRequest(url: url, timeoutInterval: 10)
        var pollCookie = "qrsig=\(qrsig)"
        if let sig = ptLoginSig, !sig.isEmpty { pollCookie += "; pt_login_sig=\(sig)" }
        req.setValue(pollCookie, forHTTPHeaderField: "Cookie")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: req)
        collectCookies(from: response)
        guard Self.isSuccess(response),
              let body = String(data: data, encoding: .utf8),
              let parsed = Self.parsePTUI(body) else { throw APIError.invalidResponse }
        switch parsed.code {
        case "66": return .waiting
        case "67": return .scanned
        case "65", "68": return .expired
        case "0":
            guard let jumpURL = parsed.url else { throw APIError.oauthFailed }
            try await completeOAuth(redirectURL: jumpURL)
            let cookie = cookieHeader()
            guard !cookie.isEmpty else { throw APIError.unavailable }
            return .success(cookie: cookie)
        default: return .waiting
        }
    }

    // MARK: - 凭证交换

    /// 手动跟 check_sig 跳转链（最多 6 跳，每跳都收 Set-Cookie）→
    /// graph authorize 换 code（三档 scope/openapi 依次试）→
    /// musicu QQLogin 换 musickey。成功后 jar 里补 musickey / uin。
    private func completeOAuth(redirectURL: URL) async throws {
        var currentURL = redirectURL
        for _ in 0..<6 {
            var req = URLRequest(url: currentURL, timeoutInterval: 10)
            req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
            req.setValue(fullCookieHeader(), forHTTPHeaderField: "Cookie")
            let (_, response) = try await session.data(for: req)
            collectCookies(from: response)
            guard let http = response as? HTTPURLResponse,
                  (300...399).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"), !location.isEmpty else { break }
            if let absolute = URL(string: location), absolute.scheme != nil {
                currentURL = absolute
            } else if let resolved = URL(string: location, relativeTo: currentURL) {
                currentURL = resolved
            } else {
                break
            }
        }
        let credential = ptCookies["qqmusic_key"] ?? ptCookies["p_skey"] ?? ptCookies["skey"] ?? ""
        guard !credential.isEmpty else { throw APIError.oauthFailed }
        // g_tk 必须用 p_skey 算：check_sig 有的变体回 qqmusic_key，用它
        // 算出的 g_tk 会被 graph 拒掉；p_skey 没有才退 skey。
        let gtkSource = ptCookies["p_skey"] ?? ptCookies["skey"] ?? credential
        let variants: [(scope: String, openapi: String)] = [
            ("get_user_info,get_app_friends", "1010_1030"),
            ("get_user_info,get_app_friends", "80901010_1030"),
            ("all", "80901010_1030"),
        ]
        var foundCode: String?
        var lastReason: String?
        for variant in variants {
            let fields: [String: String] = [
                "response_type": "code",
                "client_id": "100497308",
                "redirect_uri": "https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/",
                "scope": variant.scope,
                "state": "state",
                "switch": "",
                "from_ptlogin": "1",
                "src": "1",
                "update_auth": "1",
                "openapi": variant.openapi,
                "g_tk": String(Self.hash5381(gtkSource)),
                "auth_time": String(Int(Date().timeIntervalSince1970 * 1000)),
                "ui": "DFEC5395-9E69-4D3E-96A6-300BB770874D",
            ]
            var authReq = URLRequest(url: URL(string: "https://graph.qq.com/oauth2.0/authorize")!, timeoutInterval: 10)
            authReq.httpMethod = "POST"
            authReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            authReq.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            authReq.setValue("https://graph.qq.com/oauth2.0/show?which=Login&display=pc&client_id=100497308", forHTTPHeaderField: "Referer")
            authReq.setValue("https://graph.qq.com", forHTTPHeaderField: "Origin")
            authReq.setValue(fullCookieHeader(), forHTTPHeaderField: "Cookie")
            authReq.httpBody = Self.formEncode(fields).data(using: .utf8)
            let (authData, authResponse) = try await session.data(for: authReq)
            collectCookies(from: authResponse)
            if let http = authResponse as? HTTPURLResponse,
               let code = Self.extractCode(from: authData, response: http), !code.isEmpty {
                foundCode = code
                break
            }
            if let reason = Self.authorizeErrorReason(authData) { lastReason = reason }
        }
        guard let code = foundCode else {
            // 100035（用户未登录）这类服务端拦截：原因原样往前传，界面
            // 按它停下来指路网页登录，别只说「重新扫码」。
            if let reason = lastReason, reason.contains("网页登录") { throw APIError.oauthNeedsWebLogin }
            throw APIError.oauthFailed
        }
        let loginPayload: [String: Any] = [
            "comm": ["g_tk": 5381, "platform": "yqq", "ct": 24, "cv": 0, "tmeLoginType": 2],
            "req": ["module": "QQConnectLogin.LoginServer", "method": "QQLogin", "param": ["code": code]],
        ]
        guard let loginBody = try? JSONSerialization.data(withJSONObject: loginPayload) else {
            throw APIError.oauthFailed
        }
        var loginReq = URLRequest(url: Self.musicuURL, timeoutInterval: 15)
        loginReq.httpMethod = "POST"
        loginReq.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        loginReq.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        loginReq.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        loginReq.setValue(fullCookieHeader(), forHTTPHeaderField: "Cookie")
        loginReq.httpBody = loginBody
        let (loginData, loginResponse) = try await session.data(for: loginReq)
        collectCookies(from: loginResponse)
        guard Self.isSuccess(loginResponse),
              let root = Self.jsonObject(from: loginData) else { throw APIError.oauthFailed }
        if let codeValue = Self.firstInteger(in: root, containers: ["req", "req_0"], keys: ["code", "ret"]),
           codeValue != 0 { throw APIError.oauthFailed }
        var musicKey: String?
        var musicID: String?
        for container in [(root["req"] as? [String: Any])?["data"] as? [String: Any],
                          (root["req_0"] as? [String: Any])?["data"] as? [String: Any],
                          root["data"] as? [String: Any]].compactMap({ $0 }) {
            if musicKey == nil, let v = Self.text(container["musickey"]), !v.isEmpty { musicKey = v }
            if musicID == nil, let v = Self.text(container["musicid"]), !v.isEmpty { musicID = v }
        }
        if musicKey == nil || musicID == nil {
            let found = Self.findCredentials(root)
            if musicKey == nil { musicKey = found.key }
            if musicID == nil { musicID = found.id }
        }
        guard let keyValue = musicKey, !keyValue.isEmpty,
              let idValue = musicID, !idValue.isEmpty, idValue != "0" else {
            throw APIError.oauthFailed
        }
        ptCookies["musickey"] = keyValue
        ptCookies["qm_keyst"] = keyValue
        ptCookies["qqmusic_key"] = keyValue
        ptCookies["uin"] = idValue
        guard Self.hasMusicCredential(Self.cookieFields(cookieHeader())) else {
            throw APIError.oauthFailed
        }
    }

    // MARK: - 资料 / VIP

    /// 画像：先过 hasMusicCredential 门；uin 取 uin/p_uin/pt2gguin/
    /// qqmusic_uin/loginUin（去前导 o，拒 0）；GET
    /// fcg_get_profile_homepage.fcg（cid=205360838，g_tk 固定 5381）。
    /// 昵称、头像字段多名兜底，缺失调 baseUserInfo。
    func profile(cookie: String) async throws -> Profile {
        let fields = Self.cookieFields(cookie)
        guard Self.hasMusicCredential(fields) else { throw APIError.unavailable }
        let accountID = Self.accountID(from: fields)
        guard !accountID.isEmpty else { throw APIError.unavailable }
        var comps = URLComponents(url: Self.profileURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "cid", value: "205360838"),
            URLQueryItem(name: "userid", value: accountID),
            URLQueryItem(name: "reqfrom", value: "1"),
            URLQueryItem(name: "g_tk", value: "5381"),
            URLQueryItem(name: "loginUin", value: accountID),
            URLQueryItem(name: "hostUin", value: "0"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "yqq.json"),
            URLQueryItem(name: "needNewCode", value: "0"),
        ]
        guard let url = comps.url else { throw APIError.invalidResponse }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        collectCookies(from: response)
        guard Self.isSuccess(response), let object = Self.jsonObject(from: data) else {
            throw APIError.invalidResponse
        }
        // code 1000 是这个旧画像端点不可用的回包：不因此判凭证已死，
        // 走 baseUserInfo 兜底；其它非 0 码才算凭证被拒。
        if let code = Self.integer(in: object, keys: ["code"]), code != 0 && code != 1000 {
            throw APIError.unavailable
        }
        let dataObject = object["data"] as? [String: Any] ?? object
        let info = ((dataObject["mymusic"] as? [String: Any])?["info"] as? [String: Any])
            ?? (dataObject["info"] as? [String: Any])
            ?? dataObject["user"] as? [String: Any]
            ?? dataObject["profile"] as? [String: Any]
            ?? dataObject
        let id = Self.text(in: info, keys: ["uin", "uid", "user_id", "loginUin"]) ?? accountID
        var name = Self.text(in: info, keys: ["nick", "nickname", "name", "nickName"])
        var avatar = Self.text(in: info, keys: ["logo", "avatar", "avatarUrl", "avatar_url"])
            .map { Self.upgradeAvatarURL($0) } ?? ""
        if avatar.isEmpty { avatar = "" }
        if name == nil || avatar.isEmpty,
           let base = await baseUserInfo(uin: Self.normalizedAccountID(accountID), cookie: cookie) {
            if name == nil { name = base.nick }
            if avatar.isEmpty { avatar = base.avatar ?? "" }
        }
        let finalName = name ?? "QQ 音乐用户 \(Self.normalizedAccountID(accountID))"
        return Profile(id: id, name: finalName,
                       avatarURL: avatar.isEmpty ? nil : avatar,
                       refreshedCookie: Self.mergedCookie(original: cookie, response: response as? HTTPURLResponse))
    }

    /// 画像缺昵称/头像时的兜底：userInfo.BaseUserInfoServer
    /// get_user_baseinfo_v2，vec_uin=[uin]，map_userinfo[uin] 的
    /// nick / headurl / logo。尽力取，失败回 nil，不因此判未登录。
    private func baseUserInfo(uin: String, cookie: String) async -> (nick: String?, avatar: String?)? {
        guard !uin.isEmpty else { return nil }
        guard let data = try? await musicu(module: "userInfo.BaseUserInfoServer",
                                           method: "get_user_baseinfo_v2",
                                           param: ["vec_uin": [uin]], cookie: cookie) else { return nil }
        guard let map = data["map_userinfo"] as? [String: Any],
              let info = (map[uin] as? [String: Any]) ?? (map.values.first as? [String: Any]) else { return nil }
        let nick = Self.text(in: info, keys: ["nick", "nickname"])
        let avatar = Self.text(in: info, keys: ["headurl", "logo"])
            .map { Self.upgradeAvatarURL($0) }
        return (nick, avatar?.isEmpty == true ? nil : avatar)
    }

    /// VIP（r31-membership）：SRFVipQuery_V2（userInfo.VipQueryServer）。
    /// 回 nil = 上游没给准信（查不到 / 不通 / code 非 0，不是「非会员」），
    /// 调用方不拿它当 false 写死。回包扫含 vip/green 且不含
    /// time/end/start/expire/pay/url/icon/desc 的键，数值 > 0 即会员；
    /// iSuperVip（超级会员）> 0 即 SVIP（见 Membership.swift）。
    /// g_tk = hash5381(凭证)，凭证取 cookie 的 qqmusic_key / qm_keyst /
    /// p_skey / skey（p_skey 优先是已落地的教训：check_sig 有的变体回
    /// qqmusic_key，用它算出的 g_tk 会被 graph 拒掉）；uin 取
    /// uin / p_uin / wxuin。
    func vipStatus(cookie: String) async -> VIPStatus? {
        let fields = Self.cookieFields(cookie)
        let rawUin = fields["uin"] ?? fields["p_uin"] ?? fields["wxuin"] ?? ""
        let uin = String(rawUin.drop { !$0.isNumber })
        guard !uin.isEmpty else { return nil }
        let credential = fields["p_skey"] ?? fields["skey"] ?? fields["qqmusic_key"] ?? fields["qm_keyst"] ?? ""
        let payload: [String: Any] = [
            "comm": ["g_tk": Self.hash5381(credential), "uin": uin, "format": "json", "ct": 24, "cv": 0],
            "req": ["module": "userInfo.VipQueryServer", "method": "SRFVipQuery_V2",
                    "param": ["uin_list": [uin]]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var req = URLRequest(url: Self.musicuURL, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: req),
              let root = Self.jsonObject(from: data),
              let reqObj = root["req"] as? [String: Any],
              (Self.integer(in: reqObj, keys: ["code"]) ?? 0) == 0 else { return nil }
        return VIPInfo.qqStatus(from: reqObj["data"] ?? reqObj)
    }

    // MARK: - 歌单

    /// 账号歌单：musicu GetPlaylistByUin（自建）→ 空回落
    /// fcg_user_created_diss（网页 CGI）。「我喜欢」本身不在这两路里，
    /// 它是 dirid 201 收藏夹，见服务端 `QQ.swift userLikedSongs`。
    func userPlaylists(cookie: String) async throws -> [AccountPlaylist] {
        let fields = Self.cookieFields(cookie)
        let rawUin = fields["uin"] ?? fields["p_uin"] ?? fields["wxuin"] ?? ""
        let uin = String(rawUin.drop { !$0.isNumber })
        guard !uin.isEmpty else { throw APIError.invalidResponse }
        let credential = fields["qqmusic_key"] ?? fields["p_skey"] ?? fields["skey"] ?? ""
        let gtk = Self.hash5381(credential)
        if let rows = try? await musicuPlaylists(cookie: cookie, uin: uin, gtk: gtk), !rows.isEmpty {
            return rows
        }
        var comps = URLComponents(string: "https://c.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss")!
        comps.queryItems = [
            URLQueryItem(name: "cv", value: "4747474"), URLQueryItem(name: "ct", value: "24"),
            URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "inCharset", value: "utf-8"),
            URLQueryItem(name: "outCharset", value: "utf-8"), URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "yqq.json"), URLQueryItem(name: "needNewCode", value: "1"),
            URLQueryItem(name: "uin", value: uin), URLQueryItem(name: "hostuin", value: uin),
            URLQueryItem(name: "sin", value: "0"), URLQueryItem(name: "size", value: "200"),
            URLQueryItem(name: "g_tk", value: String(gtk)), URLQueryItem(name: "g_tk_new_20200303", value: String(gtk)),
        ]
        guard let url = comps.url else { throw APIError.invalidResponse }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        guard let root = Self.jsonObject(from: data) else { throw APIError.invalidResponse }
        let list = ((root["data"] as? [String: Any])?["disslist"] as? [[String: Any]]) ?? []
        return list.compactMap { item in
            let id = (item["tid"] as? Int).map(String.init) ?? (item["tid"] as? String) ?? ""
            let name = (item["diss_name"] as? String) ?? ""
            guard !id.isEmpty, !name.isEmpty, id != "0" else { return nil }
            return AccountPlaylist(id: id, name: name, count: (item["song_cnt"] as? Int) ?? 0,
                                   coverURL: (item["diss_cover"] as? String)
                                    .flatMap { $0.isEmpty ? nil : Self.upgradeAvatarURL($0) })
        }
    }

    private func musicuPlaylists(cookie: String, uin: String, gtk: Int) async throws -> [AccountPlaylist] {
        let payload: [String: Any] = [
            "comm": ["g_tk": gtk, "uin": uin, "format": "json", "ct": 20, "cv": 4747474],
            "req_0": ["module": "music.musicasset.PlaylistBaseRead", "method": "GetPlaylistByUin",
                      "param": ["uin": uin]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return [] }
        var req = URLRequest(url: Self.musicuURL, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        guard let root = Self.jsonObject(from: data),
              let reqObj = root["req_0"] as? [String: Any],
              let payloadData = reqObj["data"] as? [String: Any] else { return [] }
        let rows = (payloadData["v_playlist"] as? [[String: Any]]) ?? []
        return rows.compactMap { item in
            let id = (item["tid"] as? Int).map(String.init) ?? (item["tid"] as? String) ?? ""
            let name = (item["dirName"] as? String) ?? (item["diss_name"] as? String) ?? ""
            guard !id.isEmpty, id != "0", !name.isEmpty else { return nil }
            let cover = (item["picUrl"] as? String) ?? (item["diss_cover"] as? String)
            return AccountPlaylist(id: id, name: name,
                                   count: (item["songNum"] as? Int) ?? (item["song_cnt"] as? Int) ?? 0,
                                   coverURL: cover.flatMap { $0.isEmpty ? nil : Self.upgradeAvatarURL($0) })
        }
    }

    // MARK: - 取链

    /// 取播放地址（vkey.GetVkeyServer CgiGetVkey）：回 URL + **实际**音质——
    /// 按上游回的文件名判定档位，缺字段回 "unknown"，绝不拿请求档冒充。
    func musicURL(songMid: String, mediaMid: String?, quality: String, cookie: String) async throws -> ResolvedAudio {
        let fields = Self.cookieFields(cookie)
        let uin = fields["qqmusic_uin"] ?? fields["uin"] ?? "0"
        let guid = String(Int.random(in: 100_000_000...2_000_000_000))
        let fileID = mediaMid?.isEmpty == false ? mediaMid! : songMid
        let file = Self.filename(for: quality, mediaMid: fileID)
        let body: [String: Any] = [
            "comm": ["cv": 4747474, "ct": 24, "format": "json", "inCharset": "utf-8",
                     "outCharset": "utf-8", "notice": 0, "platform": "yqq.json",
                     "needNewCode": 1, "uin": Int(uin) ?? 0],
            "req_1": ["module": "vkey.GetVkeyServer", "method": "CgiGetVkey",
                      "param": ["filename": [file], "guid": guid, "songmid": [songMid],
                                "songtype": [0], "uin": uin, "loginflag": 1, "platform": "20"]],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw APIError.invalidResponse
        }
        var req = URLRequest(url: Self.musicuURL, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("https://y.qq.com/portal/player.html", forHTTPHeaderField: "Referer")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard Self.isSuccess(response), let root = Self.jsonObject(from: data) else {
            throw APIError.invalidResponse
        }
        let container = (root["req_1"] as? [String: Any]) ?? (root["req_0"] as? [String: Any])
        let payload = container?["data"] as? [String: Any]
        let info = (payload?["midurlinfo"] as? [[String: Any]])?.first
        guard let path = Self.text(info?["purl"]), !path.isEmpty else { throw APIError.unavailable }
        let rawURL: String
        if let absolute = URL(string: path), absolute.scheme != nil {
            rawURL = path
        } else if let host = (payload?["sip"] as? [String])?.first, !host.isEmpty {
            rawURL = host + path
        } else {
            throw APIError.unavailable
        }
        guard let url = URL(string: rawURL.replacingOccurrences(of: "http://", with: "https://")),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw APIError.unavailable
        }
        // 请求的文件名只是请求：上游没回文件名就没证据说它按档给了。
        let returnedQuality = Self.text(info?["filename"]).map { Self.quality(forFilename: $0) } ?? "unknown"
        return ResolvedAudio(url: url, quality: returnedQuality)
    }

    // MARK: - musicu 通用调用

    /// POST musicu.fcg {comm, req_0:{module,method,param}}，回 data 字典；
    /// 任一 code 非 0 即抛 unavailable（调用方按登录失效/失败处理）。
    private func musicu(module: String, method: String, param: [String: Any], cookie: String) async throws -> [String: Any] {
        let fields = Self.cookieFields(cookie)
        let uin = fields["uin"] ?? fields["p_uin"] ?? "0"
        let body: [String: Any] = [
            "comm": ["g_tk": 5381, "uin": uin, "format": "json", "ct": 24, "cv": 0],
            "req_0": ["module": module, "method": method, "param": param],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw APIError.invalidResponse
        }
        var req = URLRequest(url: Self.musicuURL, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        guard Self.isSuccess(response), let root = Self.jsonObject(from: data),
              let reqObj = root["req_0"] as? [String: Any],
              (Self.integer(in: reqObj, keys: ["code"]) ?? -1) == 0,
              let payload = reqObj["data"] as? [String: Any] else { throw APIError.unavailable }
        return payload
    }

    // MARK: - Cookie jar（手工收发，不走共享罐）

    private func collectCookies(from response: URLResponse) {
        guard let http = response as? HTTPURLResponse else { return }
        for (key, value) in http.allHeaderFields {
            guard String(describing: key).lowercased() == "set-cookie" else { continue }
            for (k, v) in SessionStore.parseSetCookieStrings([String(describing: value)]) {
                if v.isEmpty { ptCookies.removeValue(forKey: k) } else { ptCookies[k] = v }
            }
        }
    }

    /// 扫码成功后存进钥匙串的整罐 Cookie（白名单 + 排序，稳定输出）。
    /// 白名单与网页客户端一致：skey 是有的 check_sig 变体回的凭证，
    /// 丢了它 graph 会拒掉一次成功扫码。
    private func cookieHeader() -> String {
        let allowed = Set([
            "uin", "wxuin", "p_uin", "wxopenid", "skey", "p_skey",
            "pt2gguin", "pt4_token", "qqmusic_uin", "qqmusic_key", "qm_keyst",
            "music_key", "wxskey", "wx_skey", "musickey", "musicid", "loginUin",
            "pskey", "pt_login_sig", "pt4_aid", "ptnick", "nick", "nickname",
            "psrf_access_token", "psrf_qq_access_token", "psrf_qqopenid",
        ])
        var selected: [String: String] = [:]
        for (k, v) in ptCookies where allowed.contains(k) { selected[k] = v }
        return selected.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// 跳转链 / authorize / musicu 用的全量头（白名单会丢 pt_oauth_token /
    /// pt_login_type，musicu 认不到人，所以这里不设白名单）。
    private func fullCookieHeader() -> String {
        ptCookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: - 粘贴 / 网页 Cookie 校验（与服务端 webLoginImport 同规则）

    /// 账号 id 取 uin / p_uin / wxuin / pt2gguin / qqmusic_uin / loginUin
    /// （p_uin 开头的 "o" 去掉；"0" / "null" 不算）；凭证取第一个非空的
    /// qqmusic_key / qm_keyst / musickey / music_key / p_skey / skey /
    /// psrf_access_token / psrf_qq_access_token。两样缺一不可，缺了返回
    /// 中文原因；都齐回 nil。
    static func cookieProblem(_ raw: String) -> String? {
        let fields = cookieFields(raw)
        guard !accountID(from: fields).isEmpty else {
            return "网页登录没拿到 QQ 号（缺 uin / p_uin / wxuin）：请确认已在网页里登录，再点一次「同步登录状态」"
        }
        guard !credentialKey(in: fields).isEmpty else {
            return "网页登录没拿到登录票据（缺 qqmusic_key / p_skey）：请确认已在网页里登录，再点一次「同步登录状态」"
        }
        return nil
    }

    /// 网页登录自动签入的判定（ProviderWebLoginSheet 用）：满足
    /// （uin≠0 + 任一凭证）或（凭证 + psrf_qqopenid）即算登上。
    static func webLoginSignedIn(fields: [String: String]) -> Bool {
        let hasCredential = !credentialKey(in: fields).isEmpty
        guard hasCredential else { return false }
        if !accountID(from: fields).isEmpty { return true }
        return !(fields["psrf_qqopenid"]?.isEmpty ?? true)
    }

    static func cookieFields(_ cookie: String) -> [String: String] {
        LiziKeychain.cookieFields(cookie)
    }

    static func accountID(from fields: [String: String]) -> String {
        for key in ["uin", "p_uin", "pt2gguin", "qqmusic_uin", "loginUin", "wxuin"] {
            guard let value = fields[key], isUsableAccountID(value) else { continue }
            return normalizedAccountID(value)
        }
        return ""
    }

    static func normalizedAccountID(_ value: String) -> String {
        value.hasPrefix("o") ? String(value.dropFirst()) : value
    }

    static func isUsableAccountID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalized = normalizedAccountID(trimmed)
        return normalized != "0" && normalized.lowercased() != "null" && normalized.lowercased() != "undefined"
    }

    static func credentialKey(in fields: [String: String]) -> String {
        for key in ["qqmusic_key", "qm_keyst", "musickey", "music_key", "p_skey", "skey",
                    "psrf_access_token", "psrf_qq_access_token"] {
            if let value = fields[key], !value.isEmpty { return value }
        }
        return ""
    }

    static func hasMusicCredential(_ fields: [String: String]) -> Bool {
        ["qqmusic_key", "qm_keyst", "musickey", "music_key", "p_skey", "skey", "wxskey", "wx_skey",
         "psrf_access_token", "psrf_qq_access_token"]
            .contains { key in
                guard let value = fields[key] else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    /// 头像 URL 归一：// 补 https、http 升 https；t_user_default 是 QQ
    /// 默认头像占位图，不要。非 https 回 ""。
    static func upgradeAvatarURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains("t_user_default") else { return "" }
        if s.hasPrefix("//") { s = "https:" + s }
        else if s.hasPrefix("http://") { s = "https://" + s.dropFirst("http://".count) }
        guard s.hasPrefix("https://") else { return "" }
        return s
    }

    // MARK: - 解析小工具

    static func jsonObject(from data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
    }

    static func text(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    static func text(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    static func integer(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? NSNumber { return value.intValue }
            if let value = object[key] as? String, let number = Int(value) { return number }
        }
        return nil
    }

    static func isSuccess(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
    }

    static func firstInteger(in object: [String: Any], containers: [String], keys: [String]) -> Int? {
        for container in containers {
            if let nested = object[container] as? [String: Any],
               let value = integer(in: nested, keys: keys) { return value }
        }
        return integer(in: object, keys: keys)
    }

    /// musicu 回包深处找 musickey / musicid（有的版本包在 data/result 里）。
    static func findCredentials(_ root: [String: Any]) -> (key: String?, id: String?) {
        var key: String?
        var id: String?
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                for (k, child) in dict {
                    switch k.lowercased() {
                    case "musickey", "qm_keyst", "qqmusic_key", "music_key":
                        if key == nil, let v = text(child), !v.isEmpty { key = v }
                    case "musicid", "uin", "loginuin", "qqmusic_uin":
                        if id == nil, let v = text(child), isUsableAccountID(v) { id = v }
                    default: break
                    }
                    walk(child)
                }
            } else if let arr = value as? [Any] {
                arr.forEach(walk)
            }
        }
        walk(root)
        return (key, id)
    }

    /// ptuiCB('66',...)：不认回调名，只取括号里的字段。
    static func parsePTUI(_ body: String) -> (code: String, url: URL?)? {
        let fields = callbackFields(body)
        guard fields.count >= 3, let code = fields.first else { return nil }
        let candidate = fields.dropFirst().first(where: { $0.hasPrefix("http") })
        return (code, candidate.flatMap(URL.init(string:)))
    }

    static func callbackFields(_ body: String) -> [String] {
        guard let start = body.firstIndex(of: "("),
              let end = body.lastIndex(of: ")"), start < end else { return [] }
        let payload = body[body.index(after: start)..<end]
        return payload.split(separator: ",", omittingEmptySubsequences: false).map { value in
            var item = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if item.hasPrefix("'") && item.hasSuffix("'") && item.count >= 2 {
                item.removeFirst()
                item.removeLast()
            } else if item.hasPrefix("\"") && item.hasSuffix("\"") && item.count >= 2 {
                item.removeFirst()
                item.removeLast()
            }
            return item.replacingOccurrences(of: "\\'", with: "'")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
    }

    /// graph.qq.com 正常在 302 Location 里给 code；有的边缘节点回 200 HTML
    /// 页面，里面同样带跳转地址——两种都认，但绝不把任意 body 当凭证。
    static func extractCode(from data: Data, response: HTTPURLResponse) -> String? {
        if let location = response.value(forHTTPHeaderField: "Location"),
           let code = extractCode(from: location), !code.isEmpty { return code }
        guard let body = String(data: data, encoding: .utf8), !body.isEmpty else { return nil }
        for candidate in [body, body.replacingOccurrences(of: "&amp;", with: "&")] {
            if let match = candidate.range(of: #"(?:[?&])code=([^&#\"'\s<>]+)"#, options: .regularExpression) {
                let fragment = String(candidate[match])
                let value = fragment.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                if let decoded = value.removingPercentEncoding, !decoded.isEmpty { return decoded }
            }
        }
        return nil
    }

    static func extractCode(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "code" })?.value
    }

    /// authorize 没拿到 code 时 body 里带的 QQ 业务码（100035 用户未登录 /
    /// 100012 非 POST / 100010 回调不合法）：原话往前传，界面按它分流。
    static func authorizeErrorReason(_ data: Data) -> String? {
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        if body.contains("100035") { return "QQ 扫码成功，但音乐登录凭证获取失败（100035 用户未登录），请用网页登录" }
        if body.contains("100012") { return "QQ 扫码成功，但音乐登录凭证获取失败（100012），请重新扫码" }
        if body.contains("100010") { return "QQ 扫码成功，但音乐登录凭证获取失败（100010），请重新扫码" }
        return nil
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    static func looksLikeImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }
        return bytes.count >= 12 && Array(bytes[0...3]) == [0x52, 0x49, 0x46, 0x46]
            && Array(bytes[8...11]) == [0x57, 0x45, 0x42, 0x50]
    }

    static func mergedCookie(original: String, response: HTTPURLResponse?) -> String? {
        guard let response,
              let header = response.allHeaderFields.first(where: {
                  String(describing: $0.key).lowercased() == "set-cookie"
              })?.value else { return nil }
        var values = cookieFields(original)
        for (k, v) in SessionStore.parseSetCookieStrings([String(describing: header)]) {
            values[k] = v
        }
        return values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: - JS 语义 hash（Double 累加 + 32 位截断，防 Int 溢出崩溃）

    static func hash33(_ value: String) -> Int {
        var result: Double = 0
        for unit in value.utf16 {
            result += Double(toInt32Shift(result)) + Double(unit)
        }
        return Int(toInt32(result) & 0x7FFF_FFFF)
    }

    static func hash5381(_ value: String) -> Int {
        var result: Double = 5381
        for unit in value.utf16 {
            result += Double(toInt32Shift(result)) + Double(unit)
        }
        return Int(toInt32(result) & 0x7FFF_FFFF)
    }

    private static func toInt32Shift(_ value: Double) -> Int32 {
        Int32(bitPattern: toUInt32(value) &* 32)
    }

    private static func toInt32(_ value: Double) -> Int32 {
        Int32(bitPattern: toUInt32(value))
    }

    private static func toUInt32(_ value: Double) -> UInt32 {
        var remainder = value.truncatingRemainder(dividingBy: 4_294_967_296)
        if remainder < 0 { remainder += 4_294_967_296 }
        return UInt32(remainder)
    }

    // MARK: - 档位文件名（QQMusicApi 客户端同款前缀）

    static func filename(for quality: String, mediaMid: String) -> String {
        switch quality.lowercased() {
        case "master", "jymaster": return "AI00\(mediaMid).flac"
        case "hires", "flac24bit", "flac24": return "Q000\(mediaMid).flac"
        case "atmos", "surround": return "Q001\(mediaMid).flac"
        case "dolby": return "D004\(mediaMid).mp4"
        case "flac", "lossless": return "F000\(mediaMid).flac"
        case "exhigh", "higher", "320k", "320": return "M800\(mediaMid).mp3"
        default: return "M500\(mediaMid).mp3"
        }
    }

    static func quality(forFilename filename: String) -> String {
        let value = filename.uppercased()
        if value.hasPrefix("AI00") { return "jymaster" }
        if value.hasPrefix("Q000") { return "flac24bit" }
        if value.hasPrefix("Q001") { return "atmos" }
        if value.hasPrefix("D004") { return "dolby" }
        if value.hasPrefix("F000") { return "flac" }
        if value.hasPrefix("M800") { return "320k" }
        if value.hasPrefix("C600") { return "192k" }
        if value.hasPrefix("M500") { return "128k" }
        return "unknown"
    }
}
