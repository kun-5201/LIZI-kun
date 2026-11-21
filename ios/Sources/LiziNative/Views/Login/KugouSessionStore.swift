import Foundation
import Combine

/// 酷狗音乐登录态（r31-qqkg：本机直连版）。
///
/// 真源是钥匙串里的整罐会话 Cookie（service 按平台，account "cookie"），
/// 不再是服务端 `.auth-kugou.json` 或 UserDefaults。服务端边车只收一份
/// 同步副本（直接写 SessionStore sidecar 文件，供歌单/取链等已落地的
/// 服务端取数链路继续用；登录链路本身不再走服务端）。
///
/// 行为：
/// - 粘贴登录要求 profile 通过；扫码/网页登录先存、后台再 refreshProfile。
/// - refreshProfile 前先 cookieWithDevice() 注册设备（拿 dfid，旧
///   dfid/kg_dfid 清掉再拼 "dfid=<dfid>; kugou_api_guid=<guid>" 写回）。
/// - profile 失败但 token + userid 都在 → 保持登录；否则退出登录。
/// - 未签名 IPA 上钥匙串可能写失败：报明白话，不谎称已登录。
/// - deviceMid 首次用当前毫秒时间戳生成、存 UserDefaults，登录与后续
///   请求之间不变（KugouAPI.deviceIdentity 管，写进服务端 device 文件
///   的 mid 字段，两边同一台设备）。
#if os(iOS)
@MainActor
final class KugouSessionStore: ObservableObject {
    static let shared = KugouSessionStore()

    enum SessionError: LocalizedError {
        case emptyCookie
        case invalidCookie
        case validationFailed
        case keychainFailed(String)
        var errorDescription: String? {
            switch self {
            case .emptyCookie: return "请粘贴酷狗 Cookie"
            case .invalidCookie: return "Cookie 格式不正确，请粘贴酷狗网页中的完整 Cookie"
            case .validationFailed: return "酷狗登录已失效或 Cookie 已过期"
            case .keychainFailed(let message): return message
            }
        }
    }

    static let keychainService = "com.lty5201.lizi.kugou.session"

    @Published private(set) var isLoggedIn = false
    @Published private(set) var profileName: String?
    @Published private(set) var avatarURLString: String?
    /// nil = 会员查询还没回来（或上游没给准信），不是「非会员」。
    @Published private(set) var isVIP: Bool?
    /// 是否 SVIP（资料接口 svip_level / svip / su_vip 任一 > 0；
    /// isVIP 为 nil 时无意义，读 false）。登录成功 + 每次 refreshProfile
    /// 后由画像刷新，登出清掉。
    @Published private(set) var isSuperVIP: Bool = false
    @Published private(set) var sessionRevision = 0

    var cookie: String? { storedCookie }
    var hasStoredCookie: Bool { storedCookie != nil }

    private var storedCookie: String?

    private init() {
        storedCookie = LiziKeychain.readCookie(service: Self.keychainService)
        if storedCookie == nil, let migrated = Self.migrateFromServerSidecarIfNeeded() {
            storedCookie = migrated
            try? LiziKeychain.writeCookie(migrated, service: Self.keychainService)
        }
        isLoggedIn = false
        if let cookie = storedCookie {
            Task { @MainActor [weak self] in
                await self?.pushSessionToAPI(cookie: cookie)
                await self?.refreshProfile()
            }
        }
    }

    /// 粘贴 Cookie 登录：要求 profile 通过才算登录成功。
    func signIn(cookie rawCookie: String) async throws {
        try await signIn(cookie: rawCookie, requireProfile: true)
    }

    /// 扫码登录：轮询确认时已有成对的 token + userid，先存、后台再
    /// refreshProfile（画像接口经常比凭证慢半拍，滞后不等于登录失败）。
    func signInFromQR(cookie rawCookie: String) async throws {
        try await signIn(cookie: rawCookie, requireProfile: false)
        Task { @MainActor [weak self] in
            await self?.refreshProfile()
        }
    }

    /// 网页登录：网页里已经登完，画像只是元数据，不把它当登录前提。
    func signInFromWeb(cookie rawCookie: String) async throws {
        try await signIn(cookie: rawCookie, requireProfile: false)
        Task { @MainActor [weak self] in
            await self?.refreshProfile()
        }
    }

    private func signIn(cookie rawCookie: String, requireProfile: Bool) async throws {
        let cookie = LiziKeychain.normalizedCookie(rawCookie)
        guard !cookie.isEmpty else { throw SessionError.emptyCookie }
        guard LiziKeychain.looksLikeCookie(cookie) else { throw SessionError.invalidCookie }
        let norm = KugouAPI.normalizeWebCookie(cookie)
        guard !norm.token.isEmpty else { throw SessionError.validationFailed }
        // 先把会话推给 API（画像要靠它发请求），再决定要不要 profile。
        await pushSessionToAPI(cookie: cookie)
        var profile: KugouAPI.Profile?
        if requireProfile {
            profile = try? await KugouAPI.shared.androidProfile()
        }
        if requireProfile, profile == nil {
            throw SessionError.validationFailed
        }
        let sessionCookie = await KugouAPI.shared.sessionCookieHeader() ?? cookie
        do {
            try LiziKeychain.writeCookie(sessionCookie, service: Self.keychainService)
        } catch let e as LiziKeychain.KeychainError {
            throw SessionError.keychainFailed(e.localizedDescription)
        }
        storedCookie = sessionCookie
        profileName = profile?.name ?? "酷狗用户"
        avatarURLString = profile?.avatarURL
        isVIP = profile?.vip ?? nil
        isSuperVIP = profile?.isSuperVIP ?? false
        isLoggedIn = true
        sessionRevision &+= 1
        syncToServer()
    }

    /// 静默刷新画像（12h 协调器调；登录页成功后也调一次）。
    /// 先 cookieWithDevice() 注册设备；画像失败但 token + userid 都在
    /// → 保持登录；否则退出登录。断网不等于登出。
    func refreshProfile() async {
        guard let storedCookie else { return }
        await pushSessionToAPI(cookie: storedCookie)
        let refreshedCookie = await KugouAPI.shared.cookieWithDevice()
        if !refreshedCookie.isEmpty, refreshedCookie != storedCookie {
            self.storedCookie = refreshedCookie
            try? LiziKeychain.writeCookie(refreshedCookie, service: Self.keychainService)
            syncToServer()
        }
        guard let profile = try? await KugouAPI.shared.androidProfile() else {
            let session = await KugouAPI.shared.currentSession()
            guard !session.token.isEmpty, !session.userid.isEmpty, session.userid != "0" else {
                await signOut()
                return
            }
            // r31-membership：画像失败但 token + userid 都在 → 保登录态，
            // 只把会员态标未知（isVIP nil、isSuperVIP false），不拿旧值冒充、
            // 不直接踢下线；下次 refreshProfile / 登录时再验。
            profileName = profileName ?? "酷狗用户"
            isVIP = nil
            isSuperVIP = false
            isLoggedIn = true
            sessionRevision &+= 1
            return
        }
        profileName = profile.name
        avatarURLString = profile.avatarURL
        isVIP = profile.vip
        isSuperVIP = profile.isSuperVIP
        isLoggedIn = true
        sessionRevision &+= 1
        syncToServer()
    }

    /// 登出：清钥匙串 + 清服务端同步副本（调 /api/kugou/logout）+
    /// revision+1。设备身份（guid/deviceMid）保留，换号还是同一台设备。
    func signOut() async {
        LiziKeychain.deleteCookie(service: Self.keychainService)
        storedCookie = nil
        profileName = nil
        avatarURLString = nil
        isVIP = nil
        isSuperVIP = false
        isLoggedIn = false
        sessionRevision &+= 1
        await KugouAPI.shared.clearSession()
        SessionStore.shared.clearSidecarAuth("kugou")
        _ = await NativeBridge.call(path: "/api/kugou/logout", method: "GET")
    }

    // MARK: - 会话同步

    /// 把整罐 Cookie 拆成 API 会话（token/userid/webCookie/dfid）推给
    /// KugouAPI；dfid 缺了先留空，cookieWithDevice 会补。
    private func pushSessionToAPI(cookie: String) async {
        let norm = KugouAPI.normalizeWebCookie(cookie)
        let fields = LiziKeychain.cookieFields(cookie)
        var session = KugouAPI.Session()
        session.token = norm.token
        session.userid = norm.userid
        session.webCookie = norm.webCookie
        session.dfid = fields["dfid"] ?? fields["kg_dfid"] ?? ""
        await KugouAPI.shared.updateSession(session)
    }

    /// 同步副本写服务端边车文件：登录态（token/userid/webCookie/dfid）
    /// + 设备身份（guid/mid——mid 就是 deviceMid，两边同一台设备）。
    /// 只供已落地的服务端取数链路用；登录链路本身不再走服务端。
    /// r36-kugou-vip：同步时把会员身份也写进去（vip_type：SVIP "2" /
    /// VIP "1" / 已知非会员 "0"；会员态未知时不写、不覆盖旧值）。
    /// 以前这里只写 token/userid/webCookie/dfid，会员字段全程没进过
    /// 服务端登录态——服务端 loginState() 读的 vip_type / vip_token
    /// 全仓无写入方（vip_token 至今没有来源，见下注；vip_type 唯一
    /// 写入方是服务端 status()，而原生 App 从不调 /api/kugou/status，
    /// 且 saveSidecarAuth 是整文件覆盖、这一次同步就会把 status()
    /// 写过的 vip_type 也抹掉）。取链端因此没有任何会员标记可用，
    /// 会员身份只活在本机 KugouSessionStore 里、到不了取链那一环。
    /// 注：vip_token 没有来源——扫码/粘贴/网页三种登录的上游回包里
    /// 都没有 vip_token 字段（poll 只给 token+userid，get_my_info
    /// 只给会员标志位），不编；取链认 token/userid/dfid/Cookie，
    /// 不认 vip_token。
    private func syncToServer() {
        Task {
            let session = await KugouAPI.shared.currentSession()
            let dev = await KugouAPI.shared.deviceIdentity()
            var auth: [String: Any] = [:]
            if !session.token.isEmpty { auth["token"] = session.token }
            if !session.userid.isEmpty { auth["userid"] = session.userid }
            if !session.webCookie.isEmpty { auth["webCookie"] = session.webCookie }
            if !session.dfid.isEmpty { auth["dfid"] = session.dfid }
            // 会员身份（r36-kugou-vip）：isSuperVIP → "2"（svip_level=2
            // 的惯例，服务端 status() 存 String(vipValue) 同款；r31
            // 夹具 svip_level: 2 → SVIP），普通 VIP → "1"，已知非会员
            // → "0"；isVIP 为 nil（未知）时不写，旧值留着、不拿未知覆盖。
            if isSuperVIP { auth["vip_type"] = "2" }
            else if let vip = isVIP { auth["vip_type"] = vip ? "1" : "0" }
            if !auth.isEmpty { SessionStore.shared.saveSidecarAuth("kugou", auth) }
            SessionStore.shared.saveSidecarAuth("kugou-device", ["guid": dev.guid, "mid": dev.mid])
        }
    }

    /// 迁移：钥匙串是空的、但服务端 `.auth-kugou.json` 里还有旧登录的
    /// token/userid（r31 之前服务端桥接登录的用户），接过来，不让人重登。
    private static func migrateFromServerSidecarIfNeeded() -> String? {
        guard let auth = SessionStore.shared.sidecarAuth("kugou"),
              let token = auth["token"] as? String, !token.isEmpty else { return nil }
        let userid: String
        if let u = auth["userid"] as? String { userid = u }
        else if let u = auth["userid"] as? NSNumber { userid = u.stringValue }
        else { userid = "" }
        guard !userid.isEmpty, userid != "0" else { return nil }
        var parts: [String] = ["token=\(token)", "userid=\(userid)"]
        if let web = auth["webCookie"] as? String, !web.isEmpty { parts.append(web) }
        if let dfid = auth["dfid"] as? String, !dfid.isEmpty { parts.append("dfid=\(dfid)") }
        return parts.joined(separator: "; ")
    }
}
#endif
