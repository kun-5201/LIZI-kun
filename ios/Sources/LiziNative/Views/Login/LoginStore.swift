import Foundation

/// 登录核心底座（r23a，登录全套 P4 的共享底座；不做任何一家平台的具体登录流程）。
///
/// 持有 7 个平台的登录态（`LoginState`：loggedIn / 昵称 / 头像 URL / vip / 会员类型），
/// 状态来源一律是后端 status 接口——网易 `/api/session`（`loggedIn/profile/vip`），
/// 其余 6 家 `/api/<platform>/status`（qq / kuwo / qishui / bodian /
/// kugou / applemusic）。登录态本身持久化在后端 `SessionStore`（文件：网易 session.json、
/// 各边车 `.auth-*.json`、Apple Music token 在 UserDefaults，见
/// `ios/Sources/Lizi/Server/SessionStore.swift` 与各平台 `logout` 分支）；
/// 本类只做内存态 + 启动 / 出现时重查，不自己另写一套持久化。
///
/// 接口约定（r23f `LoginSheetTarget.swift` 文件头 + r23b–r23e 各 flow 已写好的调用点）：
/// 调用形式定稿只留一种（r23a 定稿，2026-11-20）：
/// - 平台级刷新 / 登出只用静态式：`LoginStore.refresh(platform:) async -> Bool`、
///   `LoginStore.logout(platform:) async -> Bool`。7 个 flow 视图已全部统一成
///   静态调用（QQLoginView / QQWebLoginSheet 原来的 `LoginStore.shared.refresh`
///   已改掉；汽水 / 波点原来的 `@EnvironmentObject loginStore` 实例调用已改掉）。
/// - 实例上只留 r23f 同步入口与读数：同步 `refresh()`（设置页 / 账号详情页
///   `.onAppear` 里直接调）、同步 `logout(platform:)`（账号详情退出确认按钮里
///   直接调，随后关页）、`isLoggedIn(platform:)`、`displayName(platform:)`
///   （昵称，取不到为 nil）、`avatarURL(platform:)`、`isVip(platform:)`。
///   实例上没有 `refresh(platform:)` / `logout(platform:)` 异步版——别再加，
///   否则两套写法又会分叉。
/// - `LoginStore.shared`：`@ObservedObject` 读数用（设置页账号行随 `@Published`
///   states 重绘）。
///
/// 登出语义（照抄 `NetEase.swift:483` 注释）：先读 cookie 发请求、本地登录态当即
/// 作废，不等上游回答。`logout` 调完后端登出路由后必须重新拉状态确认已登出；
/// 确认仍是已登录就如实返回 false（调用方按「未登出」处理，不假装已退出）。
@MainActor
final class LoginStore: ObservableObject {

    static let shared = LoginStore()

    /// 7 个平台 id（与 `SettingsStore.platformIds` 同序同值）。
    static let platforms = ["netease", "qq", "kugou", "qishui", "bodian", "kuwo", "applemusic"]

    /// 各平台登录态（内存态；初始全是未登录，`refresh()` 后以 status 接口为准）。
    @Published private(set) var states: [String: LoginState] = {
        var d: [String: LoginState] = [:]
        for p in platforms { d[p] = LoginState() }
        return d
    }()

    /// 正在刷新的平台（UI 转圈用；`refresh(platform:)` 重入时直接返回当前态）。
    @Published private(set) var refreshing: Set<String> = []

    /// 各平台最近一次 status 拉取失败的原因（请求本身没通时记；成功后清掉）。
    /// 登录态判断绝不拿它当「已登出」——断网 ≠ 登出。
    @Published private(set) var lastError: [String: String] = [:]

    private init() {}

    // MARK: - 读数（r23f 契约；全是同步读内存态，不发请求）

    func state(for platform: String) -> LoginState {
        states[platform] ?? LoginState()
    }

    /// 是否已登录（以最近一次 status 接口为准）。
    func isLoggedIn(platform: String) -> Bool {
        state(for: platform).loggedIn
    }

    /// 已登录昵称；未登录或上游没给昵称时为 nil（调用方显示「未获取到昵称」，不编）。
    func displayName(platform: String) -> String? {
        let n = state(for: platform).nickname
        return n.isEmpty ? nil : n
    }

    /// 已登录头像；没有时为 nil（调用方不显示头像，不留破图）。
    func avatarURL(platform: String) -> URL? {
        state(for: platform).avatarURL
    }

    /// 平台返回的 VIP 状态。
    func isVip(platform: String) -> Bool {
        state(for: platform).vip
    }

    // MARK: - 刷新

    /// 同步入口（r23f：设置页 / 账号详情页 `.onAppear` 里直接调，不包 Task）。
    /// 内部起 Task 并行刷 7 家；结果经 `@Published states` 发布，账号行随之重绘。
    /// r24 第 1 件节流：首页 `.task` 里每次新建 HomeView 都调这里（冷启动
    /// 登录墙不能一直判「未登录」）；60 秒内只刷一次，免得回首页一次
    /// 就并行打 7 个 status。登录成功后调的是单平台 `refresh(platform:)`
    /// （静态），不受这个节流影响。
    private var lastRefreshAllAt: Date?
    func refresh() {
        if let at = lastRefreshAllAt, Date().timeIntervalSince(at) < 60 { return }
        lastRefreshAllAt = Date()
        Task { await refreshAll() }
    }

    /// 并行刷全部 7 个平台（各平台独立失败互不影响）。
    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for p in Self.platforms {
                group.addTask { _ = await self.refreshOne(platform: p) }
            }
        }
    }

    /// 刷一个平台的状态接口，返回刷完后的 loggedIn（汽水 / 波点：必须 true 才关弹窗）。
    /// - 网易：`GET /api/session`；其余：`GET /api/<platform>/status`。
    /// - 请求本身没通（`NativeBridge.call` 回 nil）时不改登录态（断网 ≠ 登出），只记
    ///   `lastError`，返回刷新前的 loggedIn。
    private func refreshOne(platform: String) async -> Bool {
        guard Self.platforms.contains(platform) else { return false }
        guard !refreshing.contains(platform) else { return isLoggedIn(platform: platform) }
        refreshing.insert(platform)
        defer { refreshing.remove(platform) }
        let path = platform == "netease" ? "/api/session" : "/api/\(platform)/status"
        guard let d = await NativeBridge.call(path: path) else {
            lastError[platform] = NativeBridge.searchErrorText
            return isLoggedIn(platform: platform)
        }
        states[platform] = Self.parse(platform: platform, dict: d)
        lastError[platform] = ""
        return states[platform]?.loggedIn == true
    }

    /// 静态刷新（7 个 flow 视图统一的调用形式；见文件头定稿）。
    @discardableResult
    static func refresh(platform: String) async -> Bool {
        await shared.refreshOne(platform: platform)
    }

    // MARK: - 登出

    /// 同步入口（r23f：账号详情退出确认按钮里直接调，随后关页）。
    /// 内部起 Task 走异步登出 + 状态重查；结果经 `@Published states` 发布。
    func logout(platform: String) {
        Task { _ = await logoutConfirmed(platform: platform) }
    }

    /// 静态登出（7 个 flow 视图统一的调用形式；见文件头定稿）：
    /// 调后端登出路由后重新拉状态确认已登出，返回确认结果。
    @discardableResult
    static func logout(platform: String) async -> Bool {
        await shared.logoutConfirmed(platform: platform)
    }

    /// 登出本体：调后端登出路由（结果不决定本地态——见文件头登出语义），
    /// 随后重查确认；确认已登出才返回 true。
    private func logoutConfirmed(platform: String) async -> Bool {
        guard let ep = Self.logoutEndpoint(for: platform) else { return false }
        // 后端登出路由本身就会清本地会话（网易 logout 成功 / 失败分支都
        // `session.clear()`，见 NetEase.swift:459/486；其余平台 logout 分支清
        // 各自的会话文件 / token）；这里不预判结果，只等重查的 verdict。
        _ = await NativeBridge.call(path: ep.path, method: ep.method)
        return await refreshOne(platform: platform) == false
    }

    // MARK: - 路由表（核对过后端实现，不编）

    /// 各平台登出路由（path + 方法）。方法照抄壳版 `public/api.js`：
    /// 网易 `logout: () => call('logout')`（call 默认 POST）、QQ
    /// `qqLogout` GET、各边车 `srcLogout`（callSoft，GET）、Apple Music
    /// `appleMusicLogout`（postSoft，POST）。
    ///
    /// 注意——网易不是 `/api/netease/logout`：`Router` 把 `/api/netease/*`
    /// 交给 `NetEaseService.handleNetease`，它没有 `logout` 分支（default 回
    /// 404 "unknown netease api"）；真正的登出是 `POST /api/logout`，经通用
    /// `/api/*` 转发进 `handleApi` 的 `"logout"` 路由（weapi `/logout`），
    /// `NetEase.swift:459/486` 在成功 / 失败分支都 `session.clear()`。
    /// 网易 flow（`NetEaseLoginView.swift:413`）也是 `/api/logout`，两边一致。
    static func logoutEndpoint(for platform: String) -> (path: String, method: String)? {
        switch platform {
        case "netease": return ("/api/logout", "POST")
        case "qq", "kuwo", "qishui", "bodian", "kugou": return ("/api/\(platform)/logout", "GET")
        case "applemusic": return ("/api/applemusic/logout", "POST")
        default: return nil
        }
    }

    // MARK: - 解析（只取上游实际回的字段，不编）

    /// status 接口字典 → LoginState。各平台回的形状（均已核对后端实现）：
    /// - 网易 `/api/session`：`{ loggedIn, profile: { nickname, avatar, vipType } }`，
    ///   未登录另带 `reason`（no-session / expired / verify-failed）。
    /// - QQ `/api/qq/status`：`{ loggedIn, nickname, avatar, uin }`；上游 401 时
    ///   `{ loggedIn: false, stale: true, nickname, avatar, uin }`（失效头像照留）。
    /// - 酷我 `/api/kuwo/status`：`{ loggedIn, uid, nickname: "", avatar: "", vip: false,
    ///   note }`（Cookie 登录无校验接口，昵称 / 会员一律空着，不编）。
    /// - 汽水 `/api/qishui/status`：`{ loggedIn, user: { nickname, avatar }, uid }`，
    ///   续期失败时另带 `stale: true`。
    /// - 波点 `/api/bodian/status`：`{ loggedIn, user: { nickname, avatarUrl }, uid }`。
    /// - 酷狗 `/api/kugou/status`：`{ loggedIn, nickname, avatar, uid, vip }`
    ///   （有 token 时调 user_detail 验登录态；未登录 `{ loggedIn: false }`）。
    /// - Apple Music `/api/applemusic/status`：`{ loggedIn, vip, nickname, error }`
    ///   （nickname 是服务端原样回的 "Apple Music"，不是本类编的）。
    static func parse(platform: String, dict: [String: Any]) -> LoginState {
        var s = LoginState()
        s.loggedIn = (dict["loggedIn"] as? NSNumber)?.boolValue ?? false
        let profile = dict["profile"] as? [String: Any] ?? [:]
        let user = dict["user"] as? [String: Any] ?? [:]
        s.nickname = firstString([dict, profile], keys: ["nickname"])
            ?? firstString([user], keys: ["nickname", "name", "nick"]) ?? ""
        let avatar = firstString([dict, profile], keys: ["avatar", "avatarUrl"])
            ?? firstString([user], keys: ["avatar", "avatarUrl", "picUrl", "medium_avatar_url", "avatar_url"]) ?? ""
        s.avatarURL = avatar.isEmpty ? nil : URL(string: avatar)
        if let vip = dict["vip"] as? NSNumber { s.vip = vip.boolValue }
        // 网易：profile.vipType > 0 即会员（NativeBridge.memberStatus 同款判定）。
        if let vipType = profile["vipType"] as? NSNumber, vipType.intValue > 0 { s.vip = true }
        if let vipType = profile["vipType"] as? String, (Int(vipType) ?? 0) > 0 { s.vip = true }
        if let mt = dict["membershipType"] as? String, !mt.isEmpty {
            s.membershipType = mt
        } else if let mt = dict["vipType"] as? String, !mt.isEmpty {
            s.membershipType = mt
        } else {
            // 上游没给会员类型字符串：不编等级名，vip 只显示为 "VIP"，否则空。
            s.membershipType = s.vip ? "VIP" : ""
        }
        s.stale = (dict["stale"] as? NSNumber)?.boolValue ?? false
        let reason = (dict["reason"] as? String) ?? (dict["error"] as? String) ?? ""
        s.reason = s.loggedIn ? "" : reason
        return s
    }

    /// 按顺序在几个字典里找第一个非空字符串值。
    private static func firstString(_ dicts: [[String: Any]], keys: [String]) -> String? {
        for d in dicts {
            for k in keys {
                if let v = d[k] as? String, !v.isEmpty { return v }
            }
        }
        return nil
    }
}

/// 一个平台的登录态（内存态；持久化在后端，见 `LoginStore` 文件头）。
struct LoginState {
    /// 是否已登录（以最近一次 status 接口为准）。
    var loggedIn: Bool = false
    /// 昵称（上游没给时 ""，调用方显示「未获取到昵称」，不编）。
    var nickname: String = ""
    /// 头像 URL（上游没给时 nil，调用方不显示头像）。
    var avatarURL: URL?
    /// 是否 VIP（平台返回的 VIP 状态）。
    var vip: Bool = false
    /// 会员类型显示串（上游给了字符串就原样用；否则 vip 时为 "VIP"，否则 ""；不编等级名）。
    var membershipType: String = ""
    /// 有会话残留但校验未过（QQ / 汽水 status 的 `stale`）：loggedIn 为 false，
    /// 但昵称 / 头像仍是上次账号真实的，调用方可照壳版显示「登录已失效」+ 头像。
    var stale: Bool = false
    /// 未登录原因（上游原样：no-session / expired / verify-failed / error 文案）；已登录时 ""。
    var reason: String = ""
}
