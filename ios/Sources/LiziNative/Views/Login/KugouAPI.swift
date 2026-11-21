import Foundation
import CommonCrypto
import CoreImage
import UIKit

/// 酷狗音乐本机直连 API（r31-qqkg：登录改本机直连，不再调服务端桥接）。
///
/// 流程只学接口与步骤，代码是按 Lizi 结构新写的；网关协议（签名盐、
/// appid、RSA 公钥、x-router、模块参数）与服务端 `FoliaKugou.swift`
/// 同源（KuGouMusicApi v1.6.0 的 util/helper.js、util/request.js、
/// util/crypto.js），常数与之对齐，细节以这里为准：
///   扫码：login-user.kugou.com/v2/qrcode（appid 1001、type 1、plat 4、
///     srcappid 2919，web 签名）→ 二维码 URL 本地 CIFilter 生成
///     → v2/get_userinfo_qrcode 轮询（plat 4、appid 1005、srcappid 2919、
///     qrcode、dev=kugou_api_dev，带 Cookie 头）。
///   画像：usercenter.kugou.com/v3/get_my_info（plat 1，RSA 签名 body）。
///   设备注册：userservice.kugou.com/risk/v2/r_register_dev
///     （AES-CBC + RSA + MD5 签名），回 dfid。
///   取链：trackercdngz.kugou.com/v1/authorization → /tracker/v5/url 两步。
///
/// deviceMid：首次用当前毫秒时间戳生成，存 UserDefaults，登录与后续
/// 请求之间不变；guid（UUID 去横线 32 位 hex）同款持久化。
/// Cookie 值绝不打日志、不进诊断。
actor KugouAPI {
    static let shared = KugouAPI()

    struct Profile: Sendable {
        let id: String
        let name: String
        let avatarURL: String?
        /// 会员（r31-membership）：nil = 查不到（资料接口与 union 兜底
        /// 都没给准信），不是「非会员」；false = 已确认非会员。
        let vip: Bool?
        /// 是否 SVIP（资料接口 svip_level / svip / su_vip 任一 > 0）。
        let isSuperVIP: Bool
    }

    struct ResolvedAudio: Sendable {
        let url: URL
        let quality: String
    }

    struct Collection: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let kind: String // "playlist" / "album"
        let coverURL: String?
        let count: Int
        let isOwned: Bool
        let listId: String
    }

    enum QRStatus: Sendable {
        case waiting
        case scanned
        case expired
        case success(token: String, userid: String, sessionCookie: String)
    }

    enum APIError: LocalizedError {
        case invalidResponse
        case unavailable
        case qrCodeUnavailable
        case loginFailed(String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "酷狗登录状态无法识别，请重新获取二维码"
            case .unavailable: return "酷狗登录已失效或 Cookie 已过期"
            case .qrCodeUnavailable: return "酷狗没有返回二维码，请稍后重试"
            case .loginFailed(let message): return message
            }
        }
    }

    // MARK: - 协议常数（与服务端 FoliaKugou.swift 同源）

    private static let gateway = "https://gateway.kugou.com"
    private static let liteAppid = "3116"
    private static let liteClientver = "11440"
    private static let stdAppid = "1005"
    private static let stdClientver = "20489"
    private static let srcappid = "2919"
    private static let androidLiteSalt = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
    private static let androidStdSalt = "OIlwieks28dk2k092lksi2UIkp"
    private static let webSalt = "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt"
    private static let registerSalt = "1014"
    private static let signKeyLiteSalt = "185672dd44712f60bb1736df5a377e82"
    private static let gatewayUA = "Android15-1070-11083-46-0-DiscoveryDRADprotocol-wifi"
    private static let liteRSAPublicKeyB64 = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDECi0Np2UR87scwrvTr72L6oO01rBbbBPriSDFPxr3Z5syug0O24QyQO8bg27+0+4kBzTBTBOZ/WWU0WryL1JSXRTXLgFVxtzIY41Pe7lPOgsfTCn5kZcvKhYKJesKnnJDNr5/abvTGf+rHG3YRwsCHcQ08/q6ifSioBszvb3QiwIDAQAB"
    private static let coverSize = 1024

    // MARK: - 会话态（由 KugouSessionStore 同步进来；本 actor 不直接碰钥匙串）

    struct Session: Sendable {
        var token: String = ""
        var userid: String = ""
        var webCookie: String = ""
        var dfid: String = ""
    }

    private var session = Session()
    private let deviceMidKey = "lizi.kugou.deviceMid"
    private let deviceGuidKey = "lizi.kugou.deviceGuid"

    private init() {}

    func updateSession(_ s: Session) { session = s }
    func currentSession() -> Session { session }
    func clearSession() { session = Session() }

    /// 设备身份：guid（UUID 去横线 32 位 hex）与 mid（首次用当前毫秒
    /// 时间戳生成，存 UserDefaults，之后不变）。dfid 来自登录态，没有为 "-"。
    func deviceIdentity() -> (guid: String, mid: String, dfid: String) {
        let defaults = UserDefaults.standard
        var guid = defaults.string(forKey: deviceGuidKey) ?? ""
        if guid.isEmpty {
            guid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            defaults.set(guid, forKey: deviceGuidKey)
        }
        var mid = defaults.string(forKey: deviceMidKey) ?? ""
        if mid.isEmpty {
            mid = String(Int(Date().timeIntervalSince1970 * 1000))
            defaults.set(mid, forKey: deviceMidKey)
        }
        let dfid = session.dfid.isEmpty ? "-" : session.dfid
        return (guid, mid, dfid)
    }

    /// 发往上游的整罐 Cookie：先放存下来的 web 会话 Cookie 各条，再用
    /// dfid / token / userid 覆盖同名项。空串 = 没登录过。
    func sessionCookieHeader() -> String? {
        var jar: [String: String] = [:]
        var order: [String] = []
        for seg in session.webCookie.split(separator: ";") {
            let kv = seg.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces)
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty, !v.isEmpty else { continue }
            if jar[k] == nil { order.append(k) }
            jar[k] = v
        }
        let dev = deviceIdentity()
        if !dev.dfid.isEmpty, dev.dfid != "-" {
            jar["dfid"] = dev.dfid
            if !order.contains("dfid") { order.append("dfid") }
        }
        if !session.token.isEmpty {
            jar["token"] = session.token
            if !order.contains("token") { order.append("token") }
        }
        if !session.userid.isEmpty {
            jar["userid"] = session.userid
            if !order.contains("userid") { order.append("userid") }
        }
        guard !order.isEmpty else { return nil }
        return order.map { "\($0)=\(jar[$0]!)" }.joined(separator: "; ")
    }

    // MARK: - 扫码取码

    /// POST/GET login-user.kugou.com/v2/qrcode（appid 1001、type 1、
    /// plat 4、srcappid 2919，web 签名）。二维码 URL 本地 CIFilter 生成。
    func qrCode() async throws -> (key: String, imageData: Data, loginURL: String) {
        let res = try await gateway(path: "/v2/qrcode",
                                    baseURL: "https://login-user.kugou.com",
                                    method: "GET",
                                    params: ["appid": "1001", "type": "1", "plat": "4",
                                             "qrcode_txt": "https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=\(Self.stdAppid)&",
                                             "srcappid": Self.srcappid],
                                    encrypt: .web)
        let data = Self.dataDict(res.json)
        let key = Self.strField(data, "qrcode", "qrkey", "key", "ticket")
        guard !key.isEmpty else { throw APIError.qrCodeUnavailable }
        let url = "https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=\(key)"
        guard let imageData = Self.qrPNGData(for: url) else { throw APIError.qrCodeUnavailable }
        return (key, imageData, url)
    }

    // MARK: - 轮询

    /// 每 2.5s 一轮（视图调）：GET v2/get_userinfo_qrcode（plat 4、
    /// appid 1005、srcappid 2919、qrcode、dev=Cookie 里的 kugou_api_dev，
    /// Cookie 头带上）。0 过期 / 1 等待 / 2·3 已扫 / 4 成功（取 token +
    /// userid，拼 sessionCookie）。过期不自动刷新。
    func poll(key: String) async throws -> QRStatus {
        var params: [String: String] = ["plat": "4", "appid": Self.stdAppid,
                                         "srcappid": Self.srcappid, "qrcode": key]
        let fields = LiziKeychain.cookieFields(session.webCookie)
        if let dev = fields["kugou_api_dev"], !dev.isEmpty { params["dev"] = dev }
        let res = try await gateway(path: "/v2/get_userinfo_qrcode",
                                    baseURL: "https://login-user.kugou.com",
                                    method: "GET", params: params, encrypt: .web)
        let data = Self.dataDict(res.json)
        let qrStatus = Self.intField(data, "status", "code")
        let token = Self.strField(data, "token")
        let userid = Self.strField(data, "userid", "user_id", "uid")
        switch qrStatus {
        case 0:
            return .expired
        case 1:
            return .waiting
        case 2, 3:
            return .scanned
        default:
            if qrStatus == 4 || !token.isEmpty {
                guard !token.isEmpty, !userid.isEmpty else { return .waiting }
                // 收割本次确认响应下发的 Set-Cookie（非账号项进 webCookie；
                // 账号两项发请求时现拼，不写半对）。
                let accountKeys: Set<String> = ["token", "userid", "user_id"]
                let jar = res.setCookies.filter { entry in
                    let k = entry.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                    return !k.isEmpty && !accountKeys.contains(k.lowercased())
                }.joined(separator: "; ")
                session.token = token
                session.userid = userid
                if !jar.isEmpty { session.webCookie = jar }
                let cookie = sessionCookieHeader() ?? ""
                return .success(token: token, userid: userid, sessionCookie: cookie)
            }
            return .expired
        }
    }

    // MARK: - 设备注册

    /// 设备注册（关键）：POST userservice.kugou.com/risk/v2/r_register_dev
    /// （AES-CBC + RSA + MD5 签名），回 dfid。端点约每隔一次回空 data，
    /// 失败重试最多 4 次（间隔 400ms）。
    func registerDevice() async -> Bool {
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
            if await registerDeviceOnce() { return true }
        }
        return false
    }

    private func registerDeviceOnce() async -> Bool {
        let dev = deviceIdentity()
        let info: JVal = .o([
            ("availableRamSize", .i(4983533568)),
            ("availableRomSize", .i(48114719)),
            ("availableSDSize", .i(48114717)),
            ("basebandVer", .s("")),
            ("batteryLevel", .i(100)),
            ("batteryStatus", .i(3)),
            ("brand", .s("Redmi")),
            ("buildSerial", .s("unknown")),
            ("device", .s("marble")),
            ("imei", .s(dev.guid)),
            ("imsi", .s("")),
            ("manufacturer", .s("Xiaomi")),
            ("uuid", .s(dev.guid)),
            ("accelerometer", .b(false)),
            ("accelerometerValue", .s("")),
            ("gravity", .b(false)),
            ("gravityValue", .s("")),
            ("gyroscope", .b(false)),
            ("gyroscopeValue", .s("")),
            ("light", .b(false)),
            ("lightValue", .s("")),
            ("magnetic", .b(false)),
            ("magneticValue", .s("")),
            ("orientation", .b(false)),
            ("orientationValue", .s("")),
            ("pressure", .b(false)),
            ("pressureValue", .s("")),
            ("step_counter", .b(false)),
            ("step_counterValue", .s("")),
            ("temperature", .b(false)),
            ("temperatureValue", .s("")),
        ])
        guard let aes = Self.aesEncrypt(Self.jsonString(info)) else { return false }
        let pJSON = Self.jsonString(.o([
            ("aes", .s(aes.key)),
            ("uid", .i(Int(session.userid) ?? 0)),
            ("token", .s(session.token)),
        ]))
        guard let p = rsaPKCS1EncryptHex(pJSON) else { return false }
        do {
            let res = try await gateway(path: "/risk/v2/r_register_dev",
                                        baseURL: "https://userservice.kugou.com",
                                        method: "POST",
                                        params: ["part": "1", "platid": "1", "p": p],
                                        bodyRaw: Data(aes.base64.utf8),
                                        encrypt: .android)
            guard let plain = Self.aesDecryptJSON(res.raw.base64EncodedString(), key: aes.key) else { return false }
            guard Self.upstreamStatus(plain) == 1,
                  let dfid = Self.dataDict(plain)["dfid"] as? String, !dfid.isEmpty else { return false }
            session.dfid = dfid
            return true
        } catch {
            return false
        }
    }

    /// refreshProfile 前先调：注册设备拿 dfid，再把会话 Cookie 里的旧
    /// dfid/kg_dfid 清掉（网页 Cookie 里的 dfid 属于浏览器设备，Android
    /// 网关会拒 20010），拼上 "; dfid=<dfid>; kugou_api_guid=<guid>"
    /// 写回。回新的整罐 sessionCookie（调用方负责存钥匙串）。
    func cookieWithDevice() async -> String {
        _ = await registerDevice()
        var fields: [String: String] = [:]
        var order: [String] = []
        for seg in session.webCookie.split(separator: ";") {
            let kv = seg.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces)
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty, !v.isEmpty else { continue }
            let lower = k.lowercased()
            if lower == "dfid" || lower == "kg_dfid" { continue }
            if fields[k] == nil { order.append(k) }
            fields[k] = v
        }
        let dev = deviceIdentity()
        if !session.dfid.isEmpty {
            fields["dfid"] = session.dfid
            if !order.contains("dfid") { order.append("dfid") }
        }
        fields["kugou_api_guid"] = dev.guid
        if !order.contains("kugou_api_guid") { order.append("kugou_api_guid") }
        session.webCookie = order.map { "\($0)=\(fields[$0]!)" }.joined(separator: "; ")
        return sessionCookieHeader() ?? ""
    }

    // MARK: - 画像 / VIP

    /// 画像：androidProfile（POST usercenter.kugou.com/v3/get_my_info，
    /// plat 1，RSA 签名 body，1024-bit 公钥 raw RSA hex）。昵称、头像、
    /// VIP 字段多名兜底；VIP 为 0 再查 unionVIP；失败回落 legacyProfile。
    /// 上游明确拒了（status 0 / errcode 非 0）抛 unavailable；传输层
    /// 抛错原样往上走，调用方按「断网 ≠ 登出」处理。
    func androidProfile() async throws -> Profile {
        do {
            return try await androidProfileOnce()
        } catch let e as APIError {
            // RSA 体那路不通时回落 legacyProfile（同端点 POST form）。
            if case .invalidResponse = e {
                if let legacy = try? await legacyProfile() { return legacy }
            }
            throw e
        }
    }

    private func androidProfileOnce() async throws -> Profile {
        guard !session.token.isEmpty else { throw APIError.unavailable }
        let clienttime = Int(Date().timeIntervalSince1970)
        let pJSON = Self.jsonString(.o([
            ("token", .s(session.token)),
            ("clienttime", .i(clienttime)),
        ]))
        guard let p = rsaRawEncryptUpperHex(pJSON) else { throw APIError.invalidResponse }
        let body: JVal = .o([
            ("visit_time", .i(clienttime)),
            ("usertype", .i(1)),
            ("p", .s(p)),
            ("userid", .i(Int(session.userid) ?? 0)),
        ])
        let res = try await gateway(path: "/v3/get_my_info", method: "POST",
                                    params: ["plat": "1"], body: body,
                                    xRouter: "usercenter.kugou.com")
        guard Self.upstreamStatus(res.json) == 1 else { throw APIError.unavailable }
        let data = Self.dataDict(res.json)
        let profile = (data["user_info"] as? [String: Any])
            ?? (data["userinfo"] as? [String: Any])
            ?? (data["profile"] as? [String: Any]) ?? data
        return try await profileFromDict(profile)
    }

    /// 兜底：同端点 POST form（plat/token/userid/clienttime + web 签名）。
    private func legacyProfile() async throws -> Profile {
        guard !session.token.isEmpty else { throw APIError.unavailable }
        let clienttime = String(Int(Date().timeIntervalSince1970))
        var params: [String: String] = ["plat": "1", "token": session.token,
                                         "userid": session.userid, "clienttime": clienttime]
        params["signature"] = Self.webSignature(params)
        var comps = URLComponents(string: "https://usercenter.kugou.com/v3/get_my_info")!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw APIError.invalidResponse }
        let bodyString = params.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let (data, http) = try await Upstream.fetch(url, headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": Self.gatewayUA,
        ], timeout: 15, method: "POST", body: Data(bodyString.utf8))
        guard (200..<300).contains(http.statusCode),
              let json = Upstream.jsonObject(data),
              Self.upstreamStatus(json) == 1 else { throw APIError.unavailable }
        let dict = Self.dataDict(json)
        let profile = (dict["user_info"] as? [String: Any])
            ?? (dict["userinfo"] as? [String: Any])
            ?? (dict["profile"] as? [String: Any]) ?? dict
        return try await profileFromDict(profile)
    }

    private func profileFromDict(_ profile: [String: Any]) async throws -> Profile {
        let nickname = Self.strField(profile, "nickname", "nick_name", "username", "name")
        var avatar = Self.coverOf(profile)
        if avatar.isEmpty {
            avatar = Self.upgradeAvatarURL(Self.strField(profile, "avatar", "pic", "user_pic", "sizable_avatar"))
        }
        // r31-membership：资料接口任一会员字段 > 0 即会员（is_vip /
        // vip_type / svip_level / vip / m_type / su_vip / svip 全扫取最大，
        // 不能只取第一个在场的键）；svip_level / svip / su_vip > 0 即 SVIP。
        // 全 0 再补查 union_vip；union 查不到（抛错）时 vip 记 nil = 未知，
        // 不拿「非会员」冒充（登录态照保，见 KugouSessionStore）。
        let vipValue = VIPInfo.kugouVIPValue(from: profile)
        let isSuperVIP = VIPInfo.kugouSuperVIPValue(from: profile) > 0
        var vip: Bool?
        if vipValue > 0 {
            vip = true
        } else if let union = try? await unionVIP() {
            vip = union
        } else {
            vip = nil
        }
        let name = nickname.isEmpty ? "酷狗用户" : nickname
        return Profile(id: session.userid, name: name,
                       avatarURL: avatar.isEmpty ? nil : avatar, vip: vip, isSuperVIP: isSuperVIP)
    }

    /// VIP 兜底：unionVIP（kugouvip.kugou.com/v1/get_union_vip，
    /// busi_type=concept；vip_type 或 busi_vip 里任一 is_vip > 0 即会员）。
    /// 抛错 = 查不到（调用方记未知，不当非会员）。
    func unionVIP() async throws -> Bool {
        let res = try await gateway(path: "/v1/get_union_vip",
                                    baseURL: "https://kugouvip.kugou.com",
                                    method: "GET", params: ["busi_type": "concept"])
        let data = Self.dataDict(res.json)
        var vipType = VIPInfo.maxIntField(data, "vip_type", "vipType", "is_vip")
        if vipType == 0,
           let busi = data["busi_vip"] as? [[String: Any]],
           busi.contains(where: { VIPInfo.maxIntField($0, "is_vip", "vip_type") > 0 }) {
            vipType = 1
        }
        return vipType > 0
    }

    // MARK: - 歌单

    /// 账号歌单：Android 网关 POST /v7/get_all_list → 歌内页。
    /// 「我喜欢」就是这里面 listId "2"（或名字含「喜欢」）那张表。
    func userPlaylists() async throws -> [Collection] {
        guard !session.token.isEmpty else { throw APIError.unavailable }
        let body: JVal = .o([
            ("userid", .s(session.userid)),
            ("token", .s(session.token)),
            ("total_ver", .i(979)),
            ("type", .i(2)),
            ("page", .i(1)),
            ("pagesize", .i(30)),
        ])
        let res = try await gateway(path: "/v7/get_all_list", method: "POST",
                                    params: ["plat": "1", "userid": session.userid, "token": session.token],
                                    body: body, xRouter: "cloudlist.service.kugou.com")
        guard Self.upstreamStatus(res.json) == 1 else { throw APIError.unavailable }
        let items = Self.firstListArray(res.json, keys: ["info", "list", "lists"])
        return items.compactMap { item in
            let type = Self.userCollectionType(item)
            let owned = item["type"] == nil || scNum(item["type"]) == 0
            return Self.kugouCollection(item, type: type, owned: owned)
        }
    }

    // MARK: - 取链

    /// 取播放地址两步：先 trackercdngz.kugou.com/v1/authorization 取
    /// auth + open_time，再 /tracker/v5/url。回 URL + **实际**音质
    /// （缺字段回 "unknown"，绝不拿请求档冒充）。
    func musicURL(hash: String, quality: String, albumId: Int = 0, albumAudioId: Int = 0) async throws -> ResolvedAudio {
        let h = hash.lowercased()
        let dev = deviceIdentity()
        let clienttime = String(Int(Date().timeIntervalSince1970))
        var authParams: [String: String] = [
            "appid": Self.stdAppid, "clientver": "11430", "clienttime": clienttime,
            "dfid": dev.dfid, "mid": dev.mid, "uuid": "-",
            "hash": h, "quality": quality, "album_id": String(albumId),
            "album_audio_id": String(albumAudioId), "area_code": "1",
            "version": "11430", "ssa_flag": "is_fromtrack", "behavior": "play",
            "cmd": "26", "pid": "411",
        ]
        if !session.token.isEmpty { authParams["token"] = session.token }
        if !session.userid.isEmpty { authParams["userid"] = session.userid }
        authParams["signature"] = Self.androidSignature(authParams, body: nil)
        var authComps = URLComponents(string: "https://trackercdngz.kugou.com/v1/authorization")!
        authComps.queryItems = authParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let authURL = authComps.url else { throw APIError.invalidResponse }
        var headers: [String: String] = ["User-Agent": Self.gatewayUA]
        if let cookie = sessionCookieHeader() { headers["Cookie"] = cookie }
        let (authData, authHTTP) = try await Upstream.fetch(authURL, headers: headers, timeout: 15)
        guard (200..<300).contains(authHTTP.statusCode),
              let authJSON = Upstream.jsonObject(authData),
              Self.upstreamStatus(authJSON) == 1 else { throw APIError.unavailable }
        let authDict = Self.dataDict(authJSON)
        let auth = Self.strField(authDict, "auth").isEmpty ? Self.strField(authJSON, "auth") : Self.strField(authDict, "auth")
        let openTime = Self.strField(authDict, "open_time", "openTime").isEmpty
            ? Self.strField(authJSON, "open_time", "openTime") : Self.strField(authDict, "open_time", "openTime")
        guard !auth.isEmpty else { throw APIError.unavailable }
        var urlParams: [String: String] = [
            "hash": h, "quality": quality, "album_id": String(albumId),
            "album_audio_id": String(albumAudioId), "auth": auth, "open_time": openTime,
            "appid": Self.stdAppid, "clientver": "11430", "clienttime": clienttime,
            "dfid": dev.dfid, "mid": dev.mid, "uuid": "-",
        ]
        if !session.token.isEmpty { urlParams["token"] = session.token }
        if !session.userid.isEmpty { urlParams["userid"] = session.userid }
        urlParams["signature"] = Self.androidSignature(urlParams, body: nil)
        var urlComps = URLComponents(string: "https://trackercdngz.kugou.com/tracker/v5/url")!
        urlComps.queryItems = urlParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = urlComps.url else { throw APIError.invalidResponse }
        let (data, http) = try await Upstream.fetch(url, headers: headers, timeout: 15)
        guard (200..<300).contains(http.statusCode),
              let json = Upstream.jsonObject(data),
              Self.upstreamStatus(json) == 1 else { throw APIError.unavailable }
        var payload: [String: Any] = [:]
        let topData = json["data"]
        if let arr = topData as? [[String: Any]], let first = arr.first { payload = first }
        else if let d = topData as? [String: Any] { payload = d }
        else { payload = json }
        guard let urlString = Self.audioUrlOf(payload["play_url"] ?? payload["playUrl"] ?? payload["url"]),
              let playURL = URL(string: urlString) else { throw APIError.unavailable }
        let qualityValue = Self.strField(payload, "quality", "audio_quality", "quality_level")
        return ResolvedAudio(url: playURL, quality: qualityValue.isEmpty ? "unknown" : qualityValue)
    }

    private static func audioUrlOf(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        let values: [String]
        if let arr = raw as? [String] { values = arr }
        else if let s = raw as? String { values = [s] }
        else { return nil }
        for v in values {
            for part in v.components(separatedBy: ",") {
                let c = part.trimmingCharacters(in: .whitespaces)
                guard c.hasPrefix("http://") || c.hasPrefix("https://"), URL(string: c) != nil else { continue }
                return c
            }
        }
        return nil
    }

    // MARK: - 粘贴 / 网页 Cookie 归一化

    /// 粘贴登录校验：token 是账号对的必需项（userid 缺了由 status 补）。
    static func cookieProblem(_ raw: String) -> String? {
        let norm = normalizeWebCookie(raw)
        guard !norm.token.isEmpty else {
            return "Cookie 里没有 token：请在浏览器登录 www.kugou.com 后复制整段 Cookie"
        }
        return nil
    }

    /// 网页登录归一化：t≥24 → 补 token，KugooID → userid；其余段进
    /// webCookie（账号两项与 dfid 不进，device 注册时再拼）。
    /// 网页登录判登录：token + identity 非空且 ≠0（调用方用
    /// `KugouAPI.webLoginSignedIn` 判）。
    static func normalizeWebCookie(_ raw: String) -> (token: String, userid: String, webCookie: String) {
        let fields = LiziKeychain.cookieFields(raw)
        var token = fields["token"] ?? ""
        if token.isEmpty, let t = fields["t"], t.count >= 24 { token = t }
        let userid = fields["userid"] ?? fields["user_id"] ?? fields["kugooid"] ?? fields["kugoo_id"] ?? ""
        let accountKeys: Set<String> = ["token", "userid", "user_id", "t"]
        let jar = fields.filter { !accountKeys.contains($0.key) }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        return (token, userid, jar)
    }

    static func webLoginSignedIn(token: String, userid: String) -> Bool {
        !token.isEmpty && !userid.isEmpty && userid != "0"
    }

    // MARK: - 网关传输（与服务端 FoliaKugou.gateway 同源）

    private struct KGResponse {
        let httpStatus: Int
        let json: [String: Any]?
        let raw: Data
        let setCookies: [String]
    }

    private enum KGEncrypt {
        case android, web, register, none
    }

    private func gateway(path: String, baseURL: String = gateway,
                        method: String = "GET",
                        params: [String: String] = [:],
                        body: JVal? = nil, bodyRaw: Data? = nil,
                        xRouter: String? = nil,
                        extraHeaders: [String: String] = [:],
                        encrypt: KGEncrypt = .android,
                        clearDefault: Bool = false,
                        skipSignature: Bool = false,
                        encryptKey: Bool = false) async throws -> KGResponse {
        let dev = deviceIdentity()
        let clienttime = String(Int(Date().timeIntervalSince1970))
        var allParams: [String: String] = [:]
        if !clearDefault {
            allParams["dfid"] = dev.dfid
            allParams["mid"] = dev.mid
            allParams["uuid"] = "-"
            allParams["appid"] = Self.liteAppid
            allParams["clientver"] = Self.liteClientver
            allParams["clienttime"] = clienttime
            if !session.token.isEmpty { allParams["token"] = session.token }
            if !session.userid.isEmpty { allParams["userid"] = session.userid }
        }
        for (k, v) in params { allParams[k] = v }
        if encryptKey {
            allParams["key"] = Self.signKey(hash: (allParams["hash"] ?? "").lowercased(),
                                            mid: dev.mid, userid: session.userid,
                                            appid: allParams["appid"] ?? Self.liteAppid)
        }
        let bodyData: Data? = bodyRaw ?? (body.map { Data(Self.jsonString($0).utf8) })
        if !skipSignature {
            switch encrypt {
            case .android: allParams["signature"] = Self.androidSignature(allParams, body: bodyData)
            case .web: allParams["signature"] = Self.webSignature(allParams)
            case .register: allParams["signature"] = Self.registerSignature(allParams)
            case .none: break
            }
        }
        var comps = URLComponents(string: baseURL + path)
        comps?.queryItems = allParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps?.url else {
            throw NSError(domain: "LiziKugou", code: -1, userInfo: [NSLocalizedDescriptionKey: "bad url: \(path)"])
        }
        var headers: [String: String] = [
            "dfid": dev.dfid, "clienttime": clienttime, "mid": dev.mid,
            "kg-rc": "1", "kg-thash": "5d816a0", "kg-rec": "1",
            "kg-rf": "B9EDA08A64250DEFFBCADDEE00F8F25F",
            "User-Agent": Self.gatewayUA,
        ]
        if let xRouter { headers["x-router"] = xRouter }
        for (k, v) in extraHeaders { headers[k] = v }
        if let cookie = sessionCookieHeader(), !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        if method.uppercased() != "GET", body != nil, headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/json"
        }
        let (data, http) = try await Upstream.fetch(url, headers: headers, timeout: 20,
                                                    method: method, body: bodyData)
        var setCookies: [String] = []
        for (k, v) in http.allHeaderFields {
            guard let ks = k as? String, ks.lowercased() == "set-cookie",
                  let vs = v as? String else { continue }
            setCookies.append(contentsOf: SessionStore.parseSetCookieStrings([vs]).map { "\($0.key)=\($0.value)" })
        }
        return KGResponse(httpStatus: http.statusCode, json: Upstream.jsonObject(data), raw: data,
                          setCookies: setCookies)
    }

    static func upstreamStatus(_ json: [String: Any]?) -> Int {
        guard let json else { return 0 }
        if let s = json["status"] as? Int { return s }
        if let s = json["status"] as? NSNumber { return s.intValue }
        if let e = json["error_code"] as? Int { return e == 0 ? 1 : 0 }
        if let e = json["error_code"] as? NSNumber { return e.intValue == 0 ? 1 : 0 }
        if let e = json["errcode"] as? Int { return e == 0 ? 1 : 0 }
        if let e = json["errcode"] as? NSNumber { return e.intValue == 0 ? 1 : 0 }
        if let e = json["errcode"] as? String { return (Int(e) ?? 0) == 0 ? 1 : 0 }
        return 1
    }

    static func upstreamErrorCode(_ json: [String: Any]?) -> Int {
        guard let json else { return 0 }
        for key in ["error_code", "errcode"] {
            if let e = json[key] as? Int { return e }
            if let e = json[key] as? NSNumber { return e.intValue }
            if let e = json[key] as? String, let n = Int(e) { return n }
        }
        return 0
    }

    static func needsVerify(_ json: [String: Any]?) -> Bool {
        guard let json else { return false }
        guard upstreamStatus(json) == 0 else { return false }
        if upstreamErrorCode(json) == 20028 { return true }
        let msg = strField(json, "error", "error_msg", "msg")
        return msg.contains("本次请求需要验证")
    }

    // MARK: - 有序 JSON（签名要与 body 字节一致）

    private indirect enum JVal {
        case s(String)
        case i(Int)
        case b(Bool)
        case n
        case a([JVal])
        case o([(String, JVal)])
    }

    private static func jsonString(_ v: JVal) -> String {
        switch v {
        case .s(let s):
            var out = "\""
            for ch in s {
                switch ch {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default: out.append(ch)
                }
            }
            return out + "\""
        case .i(let n): return String(n)
        case .b(let x): return x ? "true" : "false"
        case .n: return "null"
        case .a(let arr): return "[" + arr.map { jsonString($0) }.joined(separator: ",") + "]"
        case .o(let pairs): return "{" + pairs.map { jsonString(.s($0.0)) + ":" + jsonString($0.1) }.joined(separator: ",") + "}"
        }
    }

    // MARK: - MD5 与签名

    private static func md5HexData(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sortedParamString(_ params: [String: String]) -> String {
        params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined()
    }

    private static func webSignature(_ params: [String: String]) -> String {
        Crypto.md5Hex(webSalt + sortedParamString(params) + webSalt)
    }

    private static func androidSignature(_ params: [String: String], body: Data?) -> String {
        var all = Data(androidLiteSalt.utf8)
        all.append(Data(sortedParamString(params).utf8))
        if let body { all.append(body) }
        all.append(Data(androidLiteSalt.utf8))
        return md5HexData(all)
    }

    private static func registerSignature(_ params: [String: String]) -> String {
        Crypto.md5Hex(registerSalt + params.values.sorted().joined() + registerSalt)
    }

    private static func signKey(hash: String, mid: String, userid: String, appid: String) -> String {
        Crypto.md5Hex(hash + signKeyLiteSalt + appid + mid + (userid.isEmpty ? "0" : userid))
    }

    // MARK: - RSA / AES

    private static func litePublicKey() -> SecKey? {
        guard let der = Data(base64Encoded: liteRSAPublicKeyB64) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024,
        ]
        return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil)
    }

    /// 原始 RSA：JSON 明文放进 128 字节缓冲的头部、其余补零，回大写 hex。
    private func rsaRawEncryptUpperHex(_ json: String) -> String? {
        guard let key = Self.litePublicKey(),
              let plain = json.data(using: .utf8), plain.count <= 128 else { return nil }
        var buf = Data(count: 128)
        buf.replaceSubrange(0..<plain.count, with: plain)
        guard let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, buf as CFData, nil) as Data? else { return nil }
        return cipher.map { String(format: "%02X", $0) }.joined()
    }

    /// PKCS1 v1.5 RSA：JSON 明文直接加密，回小写 hex。
    private func rsaPKCS1EncryptHex(_ json: String) -> String? {
        guard let key = Self.litePublicKey(),
              let plain = json.data(using: .utf8) else { return nil }
        guard let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, plain as CFData, nil) as Data? else { return nil }
        return cipher.map { String(format: "%02x", $0) }.joined()
    }

    /// AES-128-CBC/PKCS7：6 位小写随机 key；加密 key = MD5(key)[0:16] 的
    /// ASCII 字节，iv = MD5(key)[16:32]。回 (key, base64 密文)。
    private static func aesEncrypt(_ json: String) -> (key: String, base64: String)? {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var key = ""
        for _ in 0..<6 { key.append(alphabet[Int.random(in: 0..<alphabet.count)]) }
        let md5 = Crypto.md5Hex(key)
        guard let keyData = String(md5.prefix(16)).data(using: .utf8),
              let ivData = String(md5.dropFirst(16).prefix(16)).data(using: .utf8),
              let plain = json.data(using: .utf8) else { return nil }
        var out = Data(count: plain.count + kCCBlockSizeAES128)
        var outLen = 0
        let outCapacity = out.count
        let status = keyData.withUnsafeBytes { kPtr in
            ivData.withUnsafeBytes { ivPtr in
                plain.withUnsafeBytes { pPtr in
                    out.withUnsafeMutableBytes { oPtr in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                kPtr.baseAddress, keyData.count, ivPtr.baseAddress,
                                pPtr.baseAddress, plain.count, oPtr.baseAddress, outCapacity, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLen
        return (key, out.base64EncodedString())
    }

    private static func aesDecryptJSON(_ base64: String, key: String) -> [String: Any]? {
        let md5 = Crypto.md5Hex(key)
        guard let keyData = String(md5.prefix(16)).data(using: .utf8),
              let ivData = String(md5.dropFirst(16).prefix(16)).data(using: .utf8),
              let cipher = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        var out = Data(count: cipher.count + kCCBlockSizeAES128)
        var outLen = 0
        let outCapacity = out.count
        let status = keyData.withUnsafeBytes { kPtr in
            ivData.withUnsafeBytes { ivPtr in
                cipher.withUnsafeBytes { cPtr in
                    out.withUnsafeMutableBytes { oPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                kPtr.baseAddress, keyData.count, ivPtr.baseAddress,
                                cPtr.baseAddress, cipher.count, oPtr.baseAddress, outCapacity, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLen
        guard let text = String(data: out, encoding: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    // MARK: - 二维码（CoreImage 本地生成，不走网络画码服务）

    private static func qrPNGData(for urlString: String) -> Data? {
        guard let data = urlString.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = 512.0 / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage).pngData()
    }

    // MARK: - 归一化小工具

    static func dataDict(_ json: [String: Any]?) -> [String: Any] {
        guard let json else { return [:] }
        if let d = json["data"] as? [String: Any] { return d }
        return json
    }

    static func firstListArray(_ json: [String: Any]?, keys: [String]) -> [[String: Any]] {
        guard let json else { return [] }
        for holder in [json["data"], json] {
            guard let d = holder as? [String: Any] else { continue }
            for k in keys {
                if let arr = d[k] as? [[String: Any]], !arr.isEmpty { return arr }
            }
        }
        if let arr = json["data"] as? [[String: Any]] { return arr }
        return []
    }

    private static func firstField(_ d: [String: Any], keys: [String]) -> Any? {
        for k in keys {
            guard let v = d[k] else { continue }
            if let s = v as? String, s.isEmpty { continue }
            return v
        }
        return nil
    }

    static func strField(_ d: [String: Any], _ keys: String...) -> String {
        guard let v = firstField(d, keys: keys) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    static func intField(_ d: [String: Any], _ keys: String...) -> Int {
        guard let v = firstField(d, keys: keys) else { return 0 }
        return scNum(v)
    }

    static func coverOf(_ raw: [String: Any]) -> String {
        var value = ""
        if let albumInfo = raw["album_info"] as? [String: Any] {
            value = strField(albumInfo, "sizable_cover", "cover")
        }
        if value.isEmpty, let albumInfo = raw["albumInfo"] as? [String: Any] {
            value = strField(albumInfo, "sizable_cover", "cover")
        }
        if value.isEmpty {
            for key in ["audio_info", "audioInfo"] {
                if let ai = raw[key] as? [String: Any],
                   let tp = ai["trans_param"] as? [String: Any] ?? ai["transParam"] as? [String: Any] {
                    value = strField(tp, "union_cover")
                    if !value.isEmpty { break }
                }
            }
        }
        if value.isEmpty, let tp = raw["trans_param"] as? [String: Any] ?? raw["transParam"] as? [String: Any] {
            value = strField(tp, "union_cover")
        }
        if value.isEmpty {
            value = strField(raw, "sizable_cover", "Image", "image", "img", "pic", "picUrl", "cover", "coverUrl", "sizable_avatar")
        }
        guard !value.isEmpty else { return "" }
        let cover = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "{size}", with: String(coverSize))
        let lower = cover.lowercased()
        let isBareFile = (lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
                          || lower.hasSuffix(".png") || lower.hasSuffix(".webp"))
            && cover.count >= 8 && cover.prefix(8).allSatisfy({ $0.isNumber })
            && !cover.contains("/")
        if isBareFile {
            return "https://c1.kgimg.com/stdmusic/\(coverSize)/\(cover.prefix(8))/\(cover)"
        }
        if cover.hasPrefix("//") { return "https:" + cover }
        if cover.hasPrefix("http://") { return "https://" + cover.dropFirst("http://".count) }
        return cover
    }

    static func upgradeAvatarURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "{size}", with: String(coverSize))
        guard !s.isEmpty else { return "" }
        if s.hasPrefix("//") { s = "https:" + s }
        else if s.hasPrefix("http://") { s = "https://" + s.dropFirst("http://".count) }
        guard s.hasPrefix("https://") else { return "" }
        return s
    }

    static func kugouCollection(_ raw: [String: Any], type: String, owned: Bool = false) -> Collection? {
        let id: String
        switch type {
        case "album":
            id = strField(raw, "album_id", "AlbumID", "albumId", "musiclib_id", "musicLibId", "list_create_listid")
        case "artist":
            id = strField(raw, "author_id", "authorId")
        default:
            id = strField(raw, "global_collection_id", "globalCollectionId", "specialid", "specialId", "id")
        }
        guard !id.isEmpty else { return nil }
        let name = strField(raw, "name", "listname", "specialname", "album_name", "author_name")
        let trackCount = intField(raw, "song_count", "count", "m_count", "total", "music_num")
        let listId = strField(raw, "listid", "list_id")
        return Collection(id: id, name: name, kind: type,
                          coverURL: coverOf(raw).isEmpty ? nil : coverOf(raw),
                          count: trackCount, isOwned: owned, listId: listId)
    }

    static func userCollectionType(_ raw: [String: Any]) -> String {
        if scNum(raw["source"]) == 2 { return "album" }
        if raw["musiclib_id"] != nil || raw["musicLibId"] != nil { return "album" }
        return "playlist"
    }
}
