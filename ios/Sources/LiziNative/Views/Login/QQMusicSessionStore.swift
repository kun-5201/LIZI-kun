import Foundation
import Combine

/// QQ 音乐登录态（r31-qqkg：本机直连版）。
///
/// 真源是钥匙串里的整罐 Cookie（service 按平台，account "cookie"），
/// 不再是服务端 `.auth-qq.json` 或 UserDefaults。服务端边车只收一份
/// 同步副本（`POST /api/qq/login/sync`，供歌单/喜欢/取链等已落地的
/// 服务端取数链路继续用；登录链路本身不再走服务端）。
///
/// 行为（Moumusic QQMusicSessionStore 同款判定，代码按 Lizi 结构新写）：
/// - 粘贴登录要求 profile 通过；扫码/网页登录先存、后台再 refreshProfile。
/// - 无刷新接口，Cookie 长期有效；每 12h 静默 refreshProfile（协调器调）。
/// - profile 失败但仍有可用凭证 → 保持登录、fallback 名；否则退出登录。
/// - 未签名 IPA 上钥匙串可能写失败：报明白话，不谎称已登录。
#if os(iOS)
@MainActor
final class QQMusicSessionStore: ObservableObject {
    static let shared = QQMusicSessionStore()

    enum SessionError: LocalizedError {
        case emptyCookie
        case invalidCookie
        case validationFailed
        case keychainFailed(String)
        var errorDescription: String? {
            switch self {
            case .emptyCookie: return "请粘贴 QQ 音乐 Cookie"
            case .invalidCookie: return "Cookie 格式不正确，请粘贴 QQ 音乐网页中的完整 Cookie"
            case .validationFailed: return "QQ 音乐登录已失效或 Cookie 已过期"
            case .keychainFailed(let message): return message
            }
        }
    }

    static let keychainService = "com.lty5201.lizi.qqmusic.session"

    @Published private(set) var isLoggedIn = false
    @Published private(set) var profileName: String?
    @Published private(set) var avatarURLString: String?
    /// nil = 会员查询还没回来（或上游没给准信），不是「非会员」。
    @Published private(set) var isVIP: Bool?
    /// 是否 SVIP（VipQuery 的 iSuperVip > 0；isVIP 为 nil 时无意义，读 false）。
    /// 登录成功 + 每次 refreshProfile 后由 refreshVIP() 刷新，登出清掉。
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
        if storedCookie != nil {
            Task { @MainActor [weak self] in
                await self?.refreshProfile()
            }
        }
    }

    /// 粘贴 Cookie 登录：要求 profile 通过才算登录成功。
    func signIn(cookie rawCookie: String) async throws {
        try await signIn(cookie: rawCookie, requireProfile: true)
    }

    /// 扫码登录：QR 回调里已有音乐凭证，先存、后台再 refreshProfile
    /// （画像接口经常比凭证慢半拍，滞后不等于登录失败）。
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
        if QQMusicAPI.cookieProblem(cookie) != nil { throw SessionError.validationFailed }
        var profile: QQMusicAPI.Profile?
        if requireProfile {
            profile = try? await QQMusicAPI.shared.profile(cookie: cookie)
        }
        if requireProfile, profile == nil {
            throw SessionError.validationFailed
        }
        do {
            try LiziKeychain.writeCookie(cookie, service: Self.keychainService)
        } catch let e as LiziKeychain.KeychainError {
            throw SessionError.keychainFailed(e.localizedDescription)
        }
        storedCookie = cookie
        if let refreshedCookie = profile?.refreshedCookie {
            try? LiziKeychain.writeCookie(refreshedCookie, service: Self.keychainService)
            storedCookie = refreshedCookie
        }
        profileName = profile?.name ?? "QQ 音乐用户"
        avatarURLString = profile?.avatarURL
        isLoggedIn = true
        sessionRevision &+= 1
        await syncToServer()
        refreshVIP()
    }

    /// 会员查询（r31-membership）：SRFVipQuery_V2，登录成功与每次
    /// refreshProfile 后都刷一次（无定时轮询）。查不到回 nil = 未知，
    /// 不当非会员；SVIP（iSuperVip）与普通 VIP 分开存。
    private func refreshVIP() {
        guard let cookie = storedCookie else { return }
        Task { @MainActor [weak self] in
            guard let status = await QQMusicAPI.shared.vipStatus(cookie: cookie) else {
                self?.isVIP = nil
                self?.isSuperVIP = false
                return
            }
            self?.isVIP = status.isVIP
            self?.isSuperVIP = status.isSuperVIP
        }
    }

    /// 静默刷新画像（12h 协调器调；登录页成功后也调一次）。
    /// 画像失败但凭证还可用 → 保持登录、fallback 名；否则退出登录。
    /// 断网（profile 抛错）不等于登出：凭证在就保持登录。
    func refreshProfile() async {
        guard let storedCookie else { return }
        guard let profile = try? await QQMusicAPI.shared.profile(cookie: storedCookie) else {
            guard Self.hasUsableCredential(storedCookie) else {
                await signOut()
                return
            }
            profileName = profileName ?? "QQ 音乐用户"
            isLoggedIn = true
            sessionRevision &+= 1
            refreshVIP()
            return
        }
        profileName = profile.name
        avatarURLString = profile.avatarURL
        isLoggedIn = true
        sessionRevision &+= 1
        refreshVIP()
        if let refreshedCookie = profile.refreshedCookie {
            try? LiziKeychain.writeCookie(refreshedCookie, service: Self.keychainService)
            self.storedCookie = refreshedCookie
            await syncToServer()
        }
    }

    /// 登出：清钥匙串 + 清服务端同步副本（调 /api/qq/logout，服务端
    /// 凭证缓存与网页 Cookie 一并清掉）+ revision+1。
    func signOut() async {
        LiziKeychain.deleteCookie(service: Self.keychainService)
        storedCookie = nil
        profileName = nil
        avatarURLString = nil
        isVIP = nil
        isSuperVIP = false
        isLoggedIn = false
        sessionRevision &+= 1
        _ = await NativeBridge.call(path: "/api/qq/logout", method: "GET")
    }

    // MARK: - 服务端同步副本（只供已落地的服务端取数链路用）

    /// 把钥匙串 Cookie 翻成服务端凭证字典，经 /api/qq/login/sync 写进
    /// 服务端 QQService（清掉它内存里旧凭证的缓存）。失败不影响本次
    /// 登录态本身——钥匙串才是真源，取数时 401 会明说。
    private func syncToServer() async {
        guard let cookie = storedCookie else { return }
        let fields = QQMusicAPI.cookieFields(cookie)
        let uin = QQMusicAPI.accountID(from: fields)
        let key = QQMusicAPI.credentialKey(in: fields)
        guard !uin.isEmpty, !key.isEmpty else { return }
        var body: [String: Any] = [
            "musicid": uin, "str_musicid": uin, "musickey": key,
            "loginType": 6, "musickeyCreateTime": Date().timeIntervalSince1970,
            "keyExpiresIn": 259200, "webCookie": cookie,
        ]
        if let name = profileName, !name.isEmpty { body["nickname"] = name }
        if let avatar = avatarURLString, !avatar.isEmpty { body["avatarUrl"] = avatar }
        _ = await NativeBridge.call(path: "/api/qq/login/sync", method: "POST", body: body)
    }

    /// 迁移：钥匙串是空的、但服务端 `.auth-qq.json` 里还有旧登录的凭证
    /// （r31 之前服务端桥接登录的用户），接过来，不让人重新登录。
    /// 只读 webCookie（或 uin + musickey 拼一段），不写回服务端。
    private static func migrateFromServerSidecarIfNeeded() -> String? {
        guard let auth = SessionStore.shared.sidecarAuth("qq") else { return nil }
        if let web = auth["webCookie"] as? String, !web.isEmpty,
           QQMusicAPI.cookieProblem(web) == nil { return web }
        let uin = (auth["str_musicid"] as? String) ?? (auth["musicid"] as? String) ?? ""
        let key = (auth["musickey"] as? String) ?? ""
        guard !uin.isEmpty, uin != "0", !key.isEmpty else { return nil }
        let cookie = "uin=\(uin); qqmusic_uin=\(uin); qm_keyst=\(key); qqmusic_key=\(key)"
        return QQMusicAPI.cookieProblem(cookie) == nil ? cookie : nil
    }

    static func hasUsableCredential(_ cookie: String) -> Bool {
        let fields = QQMusicAPI.cookieFields(cookie)
        let accountID = QQMusicAPI.accountID(from: fields)
        return !accountID.isEmpty && !QQMusicAPI.credentialKey(in: fields).isEmpty
    }
}
#endif
