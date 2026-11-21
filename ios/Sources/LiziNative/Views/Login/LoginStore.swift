import Foundation

/// 登录核心底座（r23a，登录全套 P4 的共享底座；不做任何一家平台的具体登录流程）。
///
/// 持有 7 个平台的登录态（`LoginState`：loggedIn / 昵称 / 头像 URL / vip / 会员类型），
/// 状态来源：网易 `/api/session`，其余 5 家 `/api/<platform>/status`
/// （kuwo / qishui / bodian / applemusic）；QQ / 酷狗 r31-qqkg 起改读本机
/// `QQMusicSessionStore` / `KugouSessionStore`（钥匙串为真源），不再只认
/// 服务端 `.auth-*.json`——设置页与歌单/喜欢取数门用同一把尺子。
/// 登录态本身持久化在后端 `SessionStore`（文件：网易 session.json、
/// 各边车 `.auth-*.json`、Apple Music token 在 UserDefaults，见
/// `ios/Sources/Lizi/Server/SessionStore.swift` 与各平台 `logout` 分支）；
/// QQ / 酷狗的持久化在钥匙串（见两个 SessionStore 文件头），本类只做
/// 内存态 + 启动 / 出现时重查，不自己另写一套持久化。
///
/// 会员校验（r31-membership，见 `Membership.swift`）：只识别、不卡档。
/// - 网易：`/api/session` 的 `sessionVerify()` 先取 profile 再取 vipInfo
///  （weapi `/music-vip-membership/client/vip/info`）；`LoginState.vipInfo`
///   是最终判定的一半：`isVip() = vipType > 0 || vipInfo.isActive`
///   （只信 vipType 会把部分 SVIP 账号误判成非会员）。
/// - QQ / 酷狗：会员查询挂在两个 SessionStore 的 `refreshProfile()` 里
///   （登录成功 + 每次 refreshProfile 后各验一次，无定时轮询；登出清会员态；
///   资料接口失败时先保登录态、只把会员态标未知——见 `refreshNativeSession`）。
/// - 酷我 / Apple Music / 汽水 / 波点没有会员校验接口（Moumusic 也没有），
///   `vipInfo` 恒为 nil，显示为未知，不编 VIP 状态。
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
///   （昵称，取不到为 nil）、`avatarURL(platform:)`、`isVip(platform:)`、
///   `isSuperVip(platform:)`、`vipLabel(platform:)`（r31-membership：SVIP 与
///   VIP 分开展示，未知显示「未知」）、`vipKnown(platform:)`。
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

    /// 平台返回的 VIP 状态（r31-membership：最终判定 =
    /// vipType > 0 || vipInfo.isActive；只信 vipType 会把部分 SVIP
    /// 账号误判成非会员。会员校验只识别、不卡档——取链不问它）。
    func isVip(platform: String) -> Bool {
        let s = state(for: platform)
        return s.vip || s.vipType > 0 || s.vipInfo?.isActive == true
    }

    /// 是否 SVIP（网易 redplus / QQ iSuperVip / 酷狗 svip_level·svip 在期）。
    /// 显示上 SVIP 与普通 VIP 分开，绝不把 SVIP 显示成普通 VIP。
    func isSuperVip(platform: String) -> Bool {
        state(for: platform).vipInfo?.isSuperVIP == true
    }

    /// 会员态是否已知（vipInfo 到过 / 服务端 status 明确回过 vip）。
    /// 未知 ≠ 非会员：未知时调用方显示「未知」，取链也不拿它分流
    /// （见 PlaybackStore 酷狗分流：只对「已知非会员」走 LX-only）。
    func vipKnown(platform: String) -> Bool {
        state(for: platform).vipKnown
    }

    /// 会员显示串：未登录 → "未登录"；SVIP → "SVIP"；VIP → "VIP"；
    /// 会员态未知且无其它会员证据 → "未知"；已知非会员 → "非 VIP"。
    /// 顺序注意：vipType > 0 本身就是会员证据（网易），vipInfo 没回来
    /// 也不应把已知的 VIP 显示成「未知」。酷我 / Apple Music /
    /// 汽水 / 波点没有会员校验接口，恒为「未知」，不编。
    func vipLabel(platform: String) -> String {
        let s = state(for: platform)
        guard s.loggedIn else { return "未登录" }
        if s.vipInfo?.isSuperVIP == true { return "SVIP" }
        if isVip(platform: platform) { return "VIP" }
        guard s.vipKnown else { return "未知" }
        return "非 VIP"
    }

    /// 取高音质档前懒补一次会员信息（r31-membership，网易专用）：
    /// 已有 vipInfo 就不发请求；否则调 `/api/vip/info`（weapi
    /// `/music-vip-membership/client/vip/info`）补一次。失败保持未知，
    /// 不改登录态、不拦播放——会员校验只识别、不卡档。
    func ensureVIPInfo(platform: String) async {
        guard platform == "netease", isLoggedIn(platform: platform) else { return }
        guard state(for: platform).vipInfo == nil else { return }
        guard let d = await NativeBridge.call(path: "/api/vip/info"),
              let data = d["data"] as? [String: Any] else { return }
        let info = VIPInfo.fromNetEase(data: data)
        guard isLoggedIn(platform: platform),
              states[platform]?.vipInfo == nil,
              var s = states[platform] else { return }
        s.vipInfo = info
        s.vipKnown = true
        if info.isActive {
            s.vip = true
            s.membershipType = info.label
        }
        states[platform] = s
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
    /// - 网易：`GET /api/session`；其余（除 QQ / 酷狗）：`GET /api/<platform>/status`。
    /// - QQ / 酷狗（r31-qqkg）：读本机 SessionStore（`refreshNativeSession`），
    ///   不再调服务端 status 接口。
    /// - 请求本身没通（`NativeBridge.call` 回 nil）时不改登录态（断网 ≠ 登出），只记
    ///   `lastError`，返回刷新前的 loggedIn。
    private func refreshOne(platform: String) async -> Bool {
        guard Self.platforms.contains(platform) else { return false }
        guard !refreshing.contains(platform) else { return isLoggedIn(platform: platform) }
        refreshing.insert(platform)
        defer { refreshing.remove(platform) }
        if platform == "qq" || platform == "kugou" {
            return await refreshNativeSession(platform: platform)
        }
        let path = platform == "netease" ? "/api/session" : "/api/\(platform)/status"
        guard let d = await NativeBridge.call(path: path) else {
            lastError[platform] = NativeBridge.searchErrorText
            return isLoggedIn(platform: platform)
        }
        states[platform] = Self.parse(platform: platform, dict: d)
        lastError[platform] = ""
        // r31-membership：网易 bootstrap 是 profile → vipInfo 两步
        // （服务端 sessionVerify 里已连调）；vipInfo 没回来（vip 接口
        // 那一步失败）时在这里懒补一次，不等下次刷新。
        if platform == "netease", states[platform]?.loggedIn == true,
           states[platform]?.vipInfo == nil {
            await ensureVIPInfo(platform: platform)
        }
        return states[platform]?.loggedIn == true
    }

    /// QQ / 酷狗登录态改读本机 SessionStore（r31-qqkg；调用方已持有
    /// `refreshing` 守卫）。先 `refreshProfile()`（画像失败但凭证可用 →
    /// 保持登录、会员态标未知，见各 SessionStore），再把发布字段组装成
    /// `LoginState`。会员查询挂在 `refreshProfile()` 里（登录成功 +
    /// 每次 refreshProfile 后各验一次，无定时轮询）。
    /// 无钥匙串凭证时 loggedIn=false；有残留凭证但未登录时保留昵称 /
    /// 头像并标 stale（r31-loginstate 语义：调用方显示「登录已失效」+ 头像）。
    private func refreshNativeSession(platform: String) async -> Bool {
        switch platform {
        case "qq":
            let store = QQMusicSessionStore.shared
            await store.refreshProfile()
            states[platform] = Self.stateFromNativeSession(
                isLoggedIn: store.isLoggedIn, nickname: store.profileName,
                avatarURLString: store.avatarURLString, isVIP: store.isVIP,
                isSuperVIP: store.isSuperVIP, hasResidualCookie: store.cookie != nil)
        case "kugou":
            let store = KugouSessionStore.shared
            await store.refreshProfile()
            states[platform] = Self.stateFromNativeSession(
                isLoggedIn: store.isLoggedIn, nickname: store.profileName,
                avatarURLString: store.avatarURLString, isVIP: store.isVIP,
                isSuperVIP: store.isSuperVIP, hasResidualCookie: store.cookie != nil)
        default:
            return false
        }
        lastError[platform] = ""
        return states[platform]?.loggedIn == true
    }

    /// 本机 SessionStore 发布字段 → LoginState。isVIP 为 nil（会员查询
    /// 还没回来）时 vipInfo 为 nil（未知，不编等级名、不当非会员）。
    private static func stateFromNativeSession(
        isLoggedIn: Bool, nickname: String?, avatarURLString: String?,
        isVIP: Bool?, isSuperVIP: Bool, hasResidualCookie: Bool
    ) -> LoginState {
        var s = LoginState()
        s.loggedIn = isLoggedIn
        s.nickname = nickname ?? ""
        s.avatarURL = normalizedAvatarURL(avatarURLString ?? "")
        s.vip = isVIP ?? false
        s.vipKnown = isVIP != nil
        if let isVIP {
            let status = VIPStatus(isVIP: isVIP, isSuperVIP: isSuperVIP)
            s.vipInfo = status.info()
            s.membershipType = status.info().label
        } else {
            s.vipInfo = nil
            s.membershipType = ""
        }
        if !isLoggedIn && hasResidualCookie {
            s.stale = true
        }
        return s
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

    /// 登出本体：QQ / 酷狗（r31-qqkg）走本机 SessionStore 的 `signOut()`
    /// （清钥匙串 + 清服务端同步副本 + revision+1），其余平台调后端
    /// 登出路由（结果不决定本地态——见文件头登出语义），随后重查确认；
    /// 确认已登出才返回 true。
    private func logoutConfirmed(platform: String) async -> Bool {
        if platform == "qq" {
            await QQMusicSessionStore.shared.signOut()
            return await refreshOne(platform: platform) == false
        }
        if platform == "kugou" {
            await KugouSessionStore.shared.signOut()
            return await refreshOne(platform: platform) == false
        }
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
    /// - 网易 `/api/session`：`{ loggedIn, profile: { nickname, avatar, vipType },
    ///   vipInfo: { isActive, isSuperVIP, label, expireTime } }`，
    ///   未登录另带 `reason`（no-session / expired / verify-failed）。
    ///   vipInfo 是 sessionVerify 里 profile 之后再取的 vip/info；
    ///   最终判定 `isVip() = vipType > 0 || vipInfo.isActive`。
    /// - QQ `/api/qq/status`：`{ loggedIn, nickname, avatar, uin,
    ///   vip: Bool?, isSuperVIP, vipKnown }`；vip 为 null = 未知，不当非会员；
    ///   上游 401 时 `{ loggedIn: false, stale: true, nickname, avatar, uin }`
    ///   （失效头像照留）。
    /// - 酷我 `/api/kuwo/status`：`{ loggedIn, uid, nickname, avatar, vip: false,
    ///   note }`（Cookie 登录无校验接口，vip 一律 false 不编；昵称 / 头像尽力
    ///   调 `/api/v1/www/user/userInfo` 取，取不到留空，不编）。
    /// - 汽水 `/api/qishui/status`：`{ loggedIn, user: { nickname, avatar }, uid }`，
    ///   续期失败时另带 `stale: true`。
    /// - 波点 `/api/bodian/status`：`{ loggedIn, user: { nickname, avatarUrl }, uid }`。
    /// - 酷狗 `/api/kugou/status`：`{ loggedIn, nickname, avatar, uid,
    ///   vip: Bool?, isSuperVIP, vipKnown }`（资料接口实算：任一会员字段 > 0
    ///   即会员，svip_level / svip > 0 即 SVIP；全 0 再补查 union_vip；
    ///   查不到回 null = 未知）。
    /// - Apple Music `/api/applemusic/status`：`{ loggedIn, vip, nickname, error,
    ///   tokenSource }`（tokenSource = pasted / web / ""，r33 起网页 token
    ///   兜底校验；nickname 是服务端原样回的 "Apple Music"，不是本类编的）。
    /// 酷我 / Apple Music / 汽水 / 波点没有会员校验接口（Moumusic 也没有）：
    /// 这里不编 vipInfo，vipKnown 恒为 false，显示为「未知」。
    static func parse(platform: String, dict: [String: Any]) -> LoginState {
        var s = LoginState()
        s.loggedIn = (dict["loggedIn"] as? NSNumber)?.boolValue ?? false
        let profile = dict["profile"] as? [String: Any] ?? [:]
        let user = dict["user"] as? [String: Any] ?? [:]
        s.nickname = firstString([dict, profile], keys: ["nickname"])
            ?? firstString([user], keys: ["nickname", "name", "nick"]) ?? ""
        let avatar = firstString([dict, profile], keys: ["avatar", "avatarUrl"])
            ?? firstString([user], keys: ["avatar", "avatarUrl", "picUrl", "medium_avatar_url", "avatar_url"]) ?? ""
        s.avatarURL = Self.normalizedAvatarURL(avatar)
        if let vip = dict["vip"] as? NSNumber { s.vip = vip.boolValue }
        // 网易：profile.vipType 只作辅助——部分 SVIP 账号 vipType 回 0，
        // 只信它会误判（r31-membership）。vipType 先存下来，最终判定
        // 在 isVip() 里做：vipType > 0 || vipInfo.isActive。
        if let vipType = profile["vipType"] as? NSNumber { s.vipType = vipType.intValue }
        if let vipType = profile["vipType"] as? String, let n = Int(vipType) { s.vipType = n }
        if s.vipType > 0 { s.vip = true }
        // 会员详情：网易取 vip/info（sessionVerify 已连调），QQ / 酷狗
        // 取各自 status 的 vip/isSuperVIP；vipInfo 到过即 vipKnown。
        if let vi = dict["vipInfo"] as? [String: Any], let info = VIPInfo.fromDictionary(vi) {
            s.vipInfo = info
            s.vipKnown = true
        } else if ["netease", "qq", "kugou"].contains(platform),
                  let vip = dict["vip"] as? NSNumber {
            // 只有这三家有会员校验接口，status 的 vip 才是校验结果；
            // 酷我 / Apple Music / 汽水 / 波点的 vip 字段不是校验结果
            // （酷我 vip 一律 false），不进 vipInfo、不算已知。
            let isSuper = (dict["isSuperVIP"] as? NSNumber)?.boolValue ?? false
            s.vipInfo = VIPStatus(isVIP: vip.boolValue, isSuperVIP: isSuper).info()
            s.vipKnown = (dict["vipKnown"] as? NSNumber)?.boolValue ?? true
        } else if let vipKnown = dict["vipKnown"] as? NSNumber {
            s.vipKnown = vipKnown.boolValue
        }
        if let info = s.vipInfo, info.isActive {
            s.vip = true
            if let mt = dict["membershipType"] as? String, !mt.isEmpty, mt != "VIP", mt != "SVIP" {
                s.membershipType = mt
            } else {
                s.membershipType = info.label
            }
        } else if let mt = dict["membershipType"] as? String, !mt.isEmpty {
            s.membershipType = mt
        } else if let mt = dict["vipType"] as? String, !mt.isEmpty {
            s.membershipType = mt
        } else {
            // 上游没给会员类型字符串：不编等级名，vip 只显示为 "VIP"，否则空。
            s.membershipType = s.vip ? "VIP" : ""
        }
        // SVIP 绝不显示成普通 VIP：vipInfo 说是 SVIP 时 membershipType 强制 SVIP。
        if s.vipInfo?.isSuperVIP == true { s.membershipType = "SVIP" }
        s.stale = (dict["stale"] as? NSNumber)?.boolValue ?? false
        let reason = (dict["reason"] as? String) ?? (dict["error"] as? String) ?? ""
        s.reason = s.loggedIn ? "" : reason
        return s
    }

    /// 头像 URL 归一（r31 头像修，各平台共用兜底）：上游头像常是 http://…
    /// （QQ thirdqq.qlogo.cn、酷狗 imge.kugou.com、酷我 img1.kuwo.cn 实测
    /// 都支持 https，VM curl http/https 双双 200）或 //…（协议相对）；
    /// 真机 ATS 只放行 https，http 原样进 AsyncImage 必 -1022，//
    /// 开头连 URL(string:) 都是 nil。统一升成 https；拿不到回 nil，
    /// 调用方显示默认头像，不转圈。
    static func normalizedAvatarURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        else if s.hasPrefix("http://") { s = "https://" + s.dropFirst("http://".count) }
        guard s.hasPrefix("https://"), let url = URL(string: s) else { return nil }
        return url
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
    /// 是否 VIP（平台返回的 VIP 状态；最终判定见 `LoginStore.isVip()`）。
    var vip: Bool = false
    /// 网易 profile.vipType（只作辅助：部分 SVIP 账号 vipType 回 0，
    /// 最终判定还要看 vipInfo.isActive；其余平台为 0）。
    var vipType: Int = 0
    /// 会员详情（r31-membership）：isActive + label + expireTime；
    /// nil = 会员查询还没回来 / 该平台没有会员校验接口（未知，不当非会员）。
    var vipInfo: VIPInfo?
    /// 会员态是否已知（vipInfo 到过 / 服务端 status 明确回过 vip）。
    var vipKnown: Bool = false
    /// 会员类型显示串（上游给了字符串就原样用；否则 vip 时为 "VIP"，
    /// SVIP 时强制 "SVIP"，否则 ""；不编等级名）。
    var membershipType: String = ""
    /// 有会话残留但校验未过（QQ / 汽水 status 的 `stale`）：loggedIn 为 false，
    /// 但昵称 / 头像仍是上次账号真实的，调用方可照壳版显示「登录已失效」+ 头像。
    var stale: Bool = false
    /// 未登录原因（上游原样：no-session / expired / verify-failed / error 文案）；已登录时 ""。
    var reason: String = ""
}
