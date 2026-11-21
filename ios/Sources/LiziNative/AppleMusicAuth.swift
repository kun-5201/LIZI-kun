import Foundation
import MusicKit // r31：MusicKit 路已停用，import 保留（有签名 + entitlement 后恢复 MusicKit 分支时直接用）。
import StoreKit

/// r29 task 1：Apple Music 真正登录（Apple ID + user token）+ 整首播放的授权端。
///
/// 现状（AppleMusic.swift 文件头已写明，本文件只接线、不改后端）：
/// - 开发者 token 要付费 Apple Developer 账号（用户没有），所以开发者 token
///   只能用现有的网页播放器公开 token（抠自 music.apple.com，2027-01-14 过期）；
/// - catalog API 只回 30 秒试听，整首要原生播放器（AppleMusicPlayer.swift，
///   MPMusicPlayerController.applicationMusicPlayer，不需要 MusicKit entitlement）。
///
/// 登录怎么做（r31 起只走 StoreKit；MusicKit 路已停用）：
/// - r31 根因：全仓没有 NSAppleMusicUsageDescription，而旧 signIn() 点按钮后
///   第一个系统调用就是 `MusicAuthorization.request()`；缺这个 key 时系统在
///   弹框前直接把进程杀掉（SIGABRT），根本不会返回 .denied——“被拒就走兜底”
///   的假设不成立；绕过 MusicKit 后 StoreKit 兜底同样要弹授权框、同样要求
///   这个 key，不补 key 兜底路一样闪退。所以 r31 两件事一起做：project.yml
///   补 usage key（构建设置 + info.properties 双写），signIn() 只走 StoreKit。
/// - StoreKit：先 `SKCloudServiceController.authorizationStatus()` 预读状态，
///   已授权直接 `requestUserToken(forDeveloperToken:)`；未定才
///   `requestAuthorization()` 弹框；被拒/受限直接回失败文案，不弹框、不静默。
///   这条路不需要 MusicKit entitlement，是拿 user token 的标准做法
///   （MusicKit 本身没有公开的取 user token API，配对用的就是 StoreKit
///   这两个调用）。
/// - MusicKit 路停用原因：未签名 IPA 无 MusicKit 能力/entitlement，这条路
///   无意义；有签名 + entitlement 后再启用（恢复本函数开头的 MusicKit 优先
///   分支，StoreKit 保持兜底）。import MusicKit 与本文件保留，只是不走这条路。
///
/// 开发者 token 来源（按优先级）：
/// 1. 用户已贴的 `lizi.applemusic.devtoken`（设置里粘贴入口）；
/// 2. 缓存的网页 token（`lizi.applemusic.webtoken` + `.exp`，未过期才用）；
/// 3. 现抠一份（`scrapeWebToken()`，约 30 行，方法照
///    AppleAnimatedArtwork.swift 文件头写的：GET music.apple.com →
///    /assets/index~*.js → 按 payload 前缀 `eyJpc3MiOiJBTVBXZWJQbGF5`
///    定位 JWT；那份代码是路线 B 工人的文件，这里不改它、自己另写一份）。
///
/// user token 落盘 `lizi.applemusic.usertoken`（与
/// AppleMusicService.userTokenKey 同值；这里用字面量，不跨 target 引用常量，
/// 免得以后挪文件时断链），重启还在；内存里再缓存一份，登出时两边一起清。
/// 订阅校验走后端现成的 verifyUserToken（GET /v1/me/library/songs 200 =
/// 订阅有效），本文件只调 `NativeBridge.call("/api/applemusic/status")`
/// 读 `vip`，不自己发 catalog 请求。
/// r34：订阅校验改成本机能力优先——SKCloudServiceController.requestCapabilities
/// → .musicCatalogPlayback 是本机能不能播整首的权威答案（本机判断，不走
/// 服务器、不耗 token）；查不到（出错）时才走后端 status 的 vip 兜底。
/// 起播准入不再硬要 user token（本机能力确认有订阅时，token 丢了也能播整首）。
/// r36（用户 2026-11-21 20:55 报“有订阅仍只能播试听”，r34 修过一次没生效）：
/// r34 的门本身就是 bug，已整条拆掉——播放路径不再调任何订阅校验
/// （readyForFullPlayback 已删；PlaybackStore.playCurrent 只看平台 +
/// store id 非空，直接走 applicationMusicPlayer 试播整首，整首还是试听由
/// 系统按设备订阅自己决定；起播失败才回落 30 秒试听链）。订阅校验
/// （hasCatalogPlayback / verifySubscription）只留作登录页 / 设置里的
/// 订阅行显示。verifySubscription 的 D 分支假阴性也修了：本机能力回
/// false 不再当定论（未签名 IPA 上 requestCapabilities 可能回空能力集），
/// 只有 true 才定论，false 继续走服务端再确认；false 的含义是“未确认”，
/// 不是“无订阅”。仍有两条假阴性链 VM 验不了（真机待确认）：① 服务端兜底
/// 要求 user token 在盘上，未签名 IPA 重装清 UserDefaults 即丢；
/// ② 服务端 verifyUserToken 走 /v1/me/library/songs，网页 token 在该端点
/// 上从没验过（r33 只验过 catalog 端点 200），401 即判 vip=false。
/// 另：play() 回 true 只代表 prepareToPlay 成功，不代表系统放的是整首；
/// 系统只放 30 秒试听时，PlaybackStore 的 onProgress 用系统报的时长
/// （应 >60 秒的歌只报 ≤35 秒）记一条 "am preview-only suspected" 诊断。
///
/// VM 上没有 Apple ID、没有订阅、没有真机：登录与整首播放的真机验证只能
/// 由用户在手机上做（见 verification/r29-task1.cjs 末尾的真机清单）。
@MainActor
final class AppleMusicAuth {
    static let shared = AppleMusicAuth()

    /// 用户粘贴的 MusicKit 开发者 token（设置粘贴入口的键）。
    static let devTokenKey = "lizi.applemusic.devtoken"
    /// music user token（与 AppleMusicService.userTokenKey 同值，字面量）。
    static let userTokenKey = "lizi.applemusic.usertoken"
    /// 缓存的网页播放器 token（与 AppleAnimatedArtworkProvider 的键同值）。
    static let webTokenKey = "lizi.applemusic.webtoken"
    static let webTokenExpKey = "lizi.applemusic.webtoken.exp"

    /// 订阅校验缓存（内存态；重启后失效，r36 起只供登录页 / 设置里的订阅行
    /// 显示时复用，不再参与播放决策）。
    private(set) var subscriptionValid = false
    private var subscriptionVerifiedAt: Date = .distantPast
    private static let subscriptionCacheTTL: TimeInterval = 300

    /// 本机目录播放能力缓存（r34）：SKCloudServiceController.requestCapabilities
    /// → .musicCatalogPlayback。nil = 没查过 / 上次出错（错误不缓存，下次重查）。
    private var catalogPlaybackCapable: Bool? = nil
    private var catalogPlaybackCheckedAt: Date = .distantPast

    /// 内存里缓存的 user token（与 UserDefaults 同步；登出时两边一起清）。
    private var cachedUserToken: String?

    private init() {}

    // MARK: - 读数

    /// 已存 user token（内存缓存优先，UserDefaults 兜底；重启后从盘上读回）。
    var userToken: String {
        if let cached = cachedUserToken, !cached.isEmpty { return cached }
        let saved = UserDefaults.standard.string(forKey: Self.userTokenKey) ?? ""
        if !saved.isEmpty { cachedUserToken = saved }
        return saved
    }

    /// 是否有 user token（= Apple ID 登录过且没登出；订阅是否有效另看
    /// `subscriptionValid`，登录 ≠ 有订阅）。
    var isLoggedIn: Bool { !userToken.isEmpty }

    /// Apple Music 曲目的 store id：platformKey 优先（原始 id），
    /// 空时用 id；都带 "am-" 前缀时去掉（MPMusicPlayerController
    /// setQueue 要的是裸 store id）。
    static func storeID(for track: Track) -> String {
        let raw = !track.platformKey.isEmpty ? track.platformKey : track.id
        return raw.hasPrefix("am-") ? String(raw.dropFirst(3)) : raw
    }

    // MARK: - 开发者 token

    /// 开发者 token（优先级：用户已贴 > 未过期的缓存网页 token > 现抠）。
    /// 空 = 三条路全没拿到（没网 / 苹果改版抠不到），调用方按失败处理。
    func developerToken() async -> String {
        let pasted = UserDefaults.standard.string(forKey: Self.devTokenKey) ?? ""
        if !pasted.isEmpty { return pasted }
        if let cached = UserDefaults.standard.string(forKey: Self.webTokenKey),
           !cached.isEmpty,
           let exp = UserDefaults.standard.object(forKey: Self.webTokenExpKey) as? Date,
           exp > Date().addingTimeInterval(3600) {
            return cached
        }
        guard let (token, exp) = await scrapeWebToken() else { return "" }
        UserDefaults.standard.set(token, forKey: Self.webTokenKey)
        UserDefaults.standard.set(exp, forKey: Self.webTokenExpKey)
        return token
    }

    /// 现抠网页播放器 token：GET music.apple.com → /assets/index~*.js →
    /// 按 payload 前缀定位 iss=AMPWebPlay 的 JWT（方法见文件头；这份是
    /// task 1 自己的实现，不改路线 B 的 AppleAnimatedArtwork.swift）。
    /// 返回 (token, exp)；任何一步失败回 nil。token 是网页播放器公开
    /// 自带的（任何浏览器打开网页就能拿到），不是用户私密凭证。
    private func scrapeWebToken() async -> (String, Date)? {
        DiagLog.shared.recordPlaybackStep("am auth webtoken scrape start")
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
        func fetch(_ url: URL) async -> Data? {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  data.count < 8_000_000 else { return nil }
            return data
        }
        guard let homeURL = URL(string: "https://music.apple.com"),
              let homeData = await fetch(homeURL),
              let home = String(data: homeData, encoding: .utf8),
              let bundleRegex = try? NSRegularExpression(pattern: "/assets/index~[^\"'\\s]*\\.js"),
              let bundleMatch = bundleRegex.firstMatch(in: home, range: NSRange(home.startIndex..., in: home)),
              let bundleRange = Range(bundleMatch.range, in: home),
              let bundleURL = URL(string: "https://music.apple.com" + String(home[bundleRange])),
              let jsData = await fetch(bundleURL),
              let js = String(data: jsData, encoding: .utf8),
              let tokenRegex = try? NSRegularExpression(pattern: "eyJ[A-Za-z0-9_-]+\\.eyJpc3MiOiJBTVBXZWJQbGF5[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"),
              let tokenMatch = tokenRegex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
              let tokenRange = Range(tokenMatch.range, in: js) else { return nil }
        let token = String(js[tokenRange])
        guard let exp = Self.jwtExpiry(token) else { return nil }
        DiagLog.shared.recordPlaybackStep("am auth webtoken scraped exp=\(exp)")
        return (token, exp)
    }

    /// 解 JWT payload 的 exp（只读时间戳，不碰签名、不校验签名——
    /// 苹果的 token 只当不透明凭证用，服务端会校验）。
    static func jwtExpiry(_ token: String) -> Date? {
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

    // MARK: - Apple ID 登录

    struct SignInResult {
        var success: Bool
        var subscriptionValid: Bool
        var method: String // "storekit" / ""（没走到取 token；r31 前还有 "musickit"，MusicKit 路停用后不再出现）
        var message: String
    }

    /// 用 Apple ID 登录（r31：只走 StoreKit；MusicKit 路已停用，见文件头）：
    /// 先预读授权状态再决定是否弹框——已授权直接取 token；未定才弹框；
    /// 被拒/受限直接回失败文案（给用户一句明白话，不静默、不闪退）。
    /// 拿到 user token 后落盘，再验订阅、刷新 LoginStore。
    /// 只有授权通过却拿不到 token 时才回失败（message 写清原因，不编）。
    func signIn() async -> SignInResult {
        let devToken = await developerToken()
        guard !devToken.isEmpty else {
            DiagLog.shared.recordPlaybackStep("am signin FAIL no dev token (pasted/web/scrape all empty)")
            return SignInResult(success: false, subscriptionValid: false, method: "",
                                message: "拿不到开发者 token（没贴 token 且网页 token 也抠不到），请检查网络后重试")
        }
        // r31：MusicKit 路已停用——未签名 IPA 无 MusicKit entitlement，且缺
        // NSAppleMusicUsageDescription 时 MusicAuthorization.request() 会在
        // 弹框前直接杀进程（SIGABRT，不回 .denied）。有签名 + entitlement 后
        // 再启用：恢复这里的 MusicKit 优先分支（先 MusicAuthorization.request()，
        // .authorized 时走 requestUserToken），StoreKit 分支保持兜底。
        // StoreKit 路：先预读状态（authorizationStatus，不弹框）再决定是否弹框。
        let currentStatus = SKCloudServiceController.authorizationStatus()
        DiagLog.shared.recordPlaybackStep("am signin StoreKit current status=\(currentStatus)")
        switch currentStatus {
        case .authorized:
            break // 已授权：直接取 token，不再弹框。
        case .notDetermined:
            // 未定：弹一次授权框；用户点了不允许就按被拒处理。
            let skStatus = await requestStoreKitAuthorization()
            DiagLog.shared.recordPlaybackStep("am signin StoreKit request status=\(skStatus)")
            guard skStatus == .authorized else {
                return SignInResult(success: false, subscriptionValid: false, method: "",
                                    message: "未获得 Apple Music 访问授权，请在系统设置里允许 Apple Music 访问后重试")
            }
        case .denied, .restricted:
            // 被拒/受限：不再弹框（系统不会再弹），直接给一句明白话。
            DiagLog.shared.recordPlaybackStep("am signin StoreKit denied/restricted, no prompt")
            return SignInResult(success: false, subscriptionValid: false, method: "",
                                message: "Apple Music 访问已被拒绝，请在系统设置里允许 Apple Music 访问后重试")
        @unknown default:
            return SignInResult(success: false, subscriptionValid: false, method: "",
                                message: "Apple Music 授权状态未知，请重试")
        }
        guard let token = await requestUserToken(devToken: devToken) else {
            DiagLog.shared.recordPlaybackStep("am signin FAIL StoreKit authorized but requestUserToken empty")
            return SignInResult(success: false, subscriptionValid: false, method: "storekit",
                                message: "授权通过但没拿到 music user token，请重试")
        }
        return await finishSignIn(userToken: token, method: "storekit")
    }

    /// StoreKit 授权（completionHandler 版包一层 continuation；系统弹框由用户点）。
    private func requestStoreKitAuthorization() async -> SKCloudServiceAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SKCloudServiceController.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// 取 music user token（StoreKit 标准调用；MusicKit 路与 StoreKit 路共用）。
    /// 空串 / error 都按 nil 处理（调用方按失败回落，不崩）。
    private func requestUserToken(devToken: String) async -> String? {
        await withCheckedContinuation { continuation in
            SKCloudServiceController().requestUserToken(forDeveloperToken: devToken) { token, error in
                if let error {
                    DiagLog.shared.recordPlaybackStep("am requestUserToken error=\(error.localizedDescription)")
                }
                continuation.resume(returning: (token?.isEmpty == false) ? token : nil)
            }
        }
    }

    /// 拿到 user token 后的收尾：落盘（内存 + UserDefaults）→ 验订阅 →
    /// 刷新 LoginStore。订阅校验走后端现成的 status（verifyUserToken：
    /// GET /v1/me/library/songs 200 = 订阅有效）。
    private func finishSignIn(userToken token: String, method: String) async -> SignInResult {
        cachedUserToken = token
        UserDefaults.standard.set(token, forKey: Self.userTokenKey)
        subscriptionVerifiedAt = .distantPast
        let sub = await verifySubscription()
        await LoginStore.refresh(platform: "applemusic")
        DiagLog.shared.recordPlaybackStep("am signin ok method=\(method) subscriptionValid=\(sub)")
        return SignInResult(success: true, subscriptionValid: sub, method: method,
                            message: sub ? "Apple ID 登录成功，订阅有效，可整首播放"
                                         : "Apple ID 登录成功，但订阅未确认（播放不受影响：点歌会直接试播整首，系统按该 Apple ID 的订阅决定整首还是试听）")
    }

    // MARK: - 订阅校验

    /// 本机能不能播 Apple Music 整首目录（r34 建，r36 改语义）：StoreKit
    /// 能力查询，本机判断。requestCapabilities → capabilities 含
    /// .musicCatalogPlayback = 该设备的 Apple ID 有订阅、可播目录。
    /// r36 更正：它不是“权威答案”——未签名 IPA 上它可能回空能力集
    /// （false），r35 把这个 false 当定论就是本轮根因。所以只有 true
    /// 才是定论；false 与出错（nil）一样是不定论，调用方必须继续走
    /// 服务端再确认（见 verifySubscription），绝不许拿 false 直接判
    /// “无订阅”。本地 IPC 调用，无网络、不耗 token、不弹框。
    /// 300 秒内复用缓存（与订阅缓存同 TTL；错误结果不缓存，下次重查；
    /// 缓存的 false 只是“上次查的结果”，不是定论）。
    func hasCatalogPlayback() async -> Bool? {
        if let cached = catalogPlaybackCapable,
           Date().timeIntervalSince(catalogPlaybackCheckedAt) < Self.subscriptionCacheTTL {
            return cached
        }
        let result: Bool? = await withCheckedContinuation { cont in
            SKCloudServiceController().requestCapabilities { caps, error in
                if let error {
                    DiagLog.shared.recordPlaybackStep("am capabilities error=\(error.localizedDescription)")
                    cont.resume(returning: nil)
                    return
                }
                let capable = caps.contains(.musicCatalogPlayback)
                DiagLog.shared.recordPlaybackStep("am capabilities musicCatalogPlayback=\(capable)")
                cont.resume(returning: capable)
            }
        }
        if let result {
            catalogPlaybackCapable = result
            catalogPlaybackCheckedAt = Date()
        }
        return result
    }

    /// 验订阅（r36：只作显示用，不作播放门槛；播放路径已不再调它）。
    /// 根因（r35 的 bug，用户 2026-11-21 20:55 报“有订阅仍只能播试听”）：
    /// 旧版 `if let capable = await hasCatalogPlayback() { return capable }`
    /// 把本机能力回的 false 当成定论直接返回——requestCapabilities 在
    /// 未签名 IPA 上回空能力集（false，不是 nil）时，服务端兜底根本不跑，
    /// 一次假阴性就把有订阅的用户锁死在试听；false 还会被缓存 300 秒。
    /// 新版：只有本机能力明确 true 才是定论；false / 查不到都继续走服务端
    /// 再确认一次（后端 /api/applemusic/status 读 vip）。返回值 false 的
    /// 含义是“未确认有订阅”，不是“确认无订阅”——调用方文案必须写“未确认”，
    /// 不许写成“无订阅 / 播放不可用”。
    /// 仍有两条已知的假阴性（VM 验不了，真机待确认，见文件头 r36 段）：
    /// 服务端兜底要求 user token 在盘上（重装清 UserDefaults 即丢）；
    /// 服务端 verifyUserToken 走 /v1/me/library/songs，网页 token 在该端点
    /// 上从没验过（r33 只验过 catalog 端点 200），401 即判 vip=false。
    func verifySubscription() async -> Bool {
        if let capable = await hasCatalogPlayback(), capable {
            subscriptionValid = true
            subscriptionVerifiedAt = Date()
            return true
        }
        // 本机能力 false 或查不到：不下定论，走服务端再确认一次。
        guard !userToken.isEmpty else { return false }
        if Date().timeIntervalSince(subscriptionVerifiedAt) < Self.subscriptionCacheTTL {
            return subscriptionValid
        }
        guard let d = await NativeBridge.call(path: "/api/applemusic/status") else {
            return subscriptionValid
        }
        subscriptionValid = (d["vip"] as? Bool) ?? false
        subscriptionVerifiedAt = Date()
        return subscriptionValid
    }

    // MARK: - 登出

    /// 清 Apple ID 登录态：user token（UserDefaults + 内存缓存）+
    /// 订阅缓存。开发者 token 不在这里清——AppleMusicLoginView 的登出
    /// 走 LoginStore.logout → 后端 /api/applemusic/logout，那边同时清
    /// 开发者 token 和 user token；这里只保证内存里不留 token。
    func signOut() {
        cachedUserToken = nil
        UserDefaults.standard.removeObject(forKey: Self.userTokenKey)
        subscriptionValid = false
        subscriptionVerifiedAt = .distantPast
        catalogPlaybackCapable = nil
        catalogPlaybackCheckedAt = .distantPast
        DiagLog.shared.recordPlaybackStep("am signout user token cleared (memory + UserDefaults)")
    }
}
