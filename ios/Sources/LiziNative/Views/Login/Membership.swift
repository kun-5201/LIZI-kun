import Foundation

/// 会员校验共享模型（r31-membership）。
///
/// 只学 Moumusic 的流程与接口（网易 vip/info、QQ VipQuery、酷狗
/// get_my_info + get_union_vip），代码按 Lizi 结构新写，不抄
/// Moumusic 代码（GPL-3.0）。
///
/// 关键教训（Moumusic 踩过的坑，见任务第 9 条）：只信网易
/// profile.vipType 会误判——部分 SVIP 账号 vipType 回 0。最终判定
/// hasActiveVIP = (vipType > 0) || vipInfo.isActive。
///
/// 会员校验只用来正确识别会员（显示 + 状态），不用来卡音质档、卡会员歌：
/// r31 已定「限制全去掉、返回什么播什么」，取链编排不问会员
/// （见 NativeBridge「会员态」一节与 PlaybackStore 酷狗分流注释——
/// 分流只决定酷狗非会员不走官方腿，不决定档位）。
///
/// 没有会员校验的平台（Moumusic 也没有，老实写清，不编）：
/// 酷我、Apple Music、汽水、波点——这四个平台 LoginStore 里没有任何
/// vipInfo 来源，显示为「未知/无会员校验」，不编 VIP 状态。
/// SVIP 识别：
/// - 网易：vip/info 的 redplus（黑胶 SVIP）在期即 SVIP；
///   associator（黑胶 VIP）/ musicPackage（音乐包）在期即普通 VIP。
/// - QQ：VipQuery 回包里的 iSuperVip（超级会员）> 0 即 SVIP。
/// - 酷狗：资料接口的 svip_level / svip（另有 su_vip = super vip 缩写，
///   同算 SVIP 证据）> 0 即 SVIP。
struct VIPInfo: Equatable, Sendable {
    /// 在期会员（普通 VIP 或 SVIP 任一在期）。
    var isActive: Bool = false
    /// 在期 SVIP（是普通 VIP 的超集：SVIP 一定也是会员）。
    var isSuperVIP: Bool = false
    /// 显示串：SVIP / VIP / ""（无会员时空串，调用方显示「非 VIP」）。
    var label: String = ""
    /// 在期会员包里最晚的到期时间（毫秒 epoch；0 = 未知/无在期包）。
    var expireTimeMs: Int64 = 0

    static func label(isSuperVIP: Bool, isActive: Bool) -> String {
        if isSuperVIP { return "SVIP" }
        if isActive { return "VIP" }
        return ""
    }

    /// 服务端 /api/session 的 vipInfo 字典 / 客户端 ensureVIPInfo 的
    /// 回包字典 → VIPInfo（键：isActive / isSuperVIP / label / expireTime）。
    /// 字典缺失或全空时回 nil（未知，不当非会员）。
    static func fromDictionary(_ d: [String: Any]) -> VIPInfo? {
        guard !d.isEmpty else { return nil }
        var info = VIPInfo()
        if let v = d["isActive"] as? NSNumber { info.isActive = v.boolValue }
        else if let v = d["isActive"] as? Bool { info.isActive = v }
        if let v = d["isSuperVIP"] as? NSNumber { info.isSuperVIP = v.boolValue }
        else if let v = d["isSuperVIP"] as? Bool { info.isSuperVIP = v }
        if let v = d["label"] as? String, !v.isEmpty { info.label = v }
        info.expireTimeMs = expireMs(d["expireTime"])
        if info.label.isEmpty { info.label = label(isSuperVIP: info.isSuperVIP, isActive: info.isActive) }
        if info.isSuperVIP { info.isActive = true }
        return info
    }

    /// 网易 vip/info 的 data 字典 → VIPInfo。
    /// data.{redplus, associator, musicPackage}.expireTime > 现在即在期
    /// （redplus = 黑胶 SVIP、associator = 黑胶 VIP、musicPackage = 音乐包）。
    static func fromNetEase(data: [String: Any], now: Date = Date()) -> VIPInfo {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var info = VIPInfo()
        var latestActive: Int64 = 0
        for (key, isSuper) in [("redplus", true), ("associator", false), ("musicPackage", false)] {
            let sub = data[key] as? [String: Any] ?? [:]
            let expire = expireMs(sub["expireTime"])
            guard expire > nowMs else { continue }
            info.isActive = true
            latestActive = max(latestActive, expire)
            if isSuper { info.isSuperVIP = true }
        }
        info.expireTimeMs = latestActive
        info.label = label(isSuperVIP: info.isSuperVIP, isActive: info.isActive)
        return info
    }

    /// 到期时间归一（毫秒 epoch）：NSNumber / 数字字符串都认；
    /// 秒级（< 1e12）按秒 ×1000 换算成毫秒；缺失/非法回 0。
    static func expireMs(_ value: Any?) -> Int64 {
        let raw: Int64
        if let n = value as? NSNumber { raw = n.int64Value }
        else if let s = value as? String, let n = Int64(s) { raw = n }
        else { return 0 }
        guard raw > 0 else { return 0 }
        return raw < 1_000_000_000_000 ? raw * 1000 : raw
    }

    // MARK: - QQ VipQuery 扫描

    /// QQ VipQuery 的 data（或整个 req）→ 会员态。
    /// code == 0 的前提由调用方（QQMusicAPI.vipStatus / 服务端
    /// QQ.vipQuery）先验，这里只扫字段：
    /// - 含 vip/green 且不含 time/end/start/expire/pay/url/icon/desc
    ///   的键，数值 > 0 即会员；
    /// - iSuperVip（超级会员）> 0 即 SVIP。
    /// 递归扫字典与数组（回包可能把会员字段包在子对象里）。
    static func qqStatus(from value: Any) -> VIPStatus {
        VIPStatus(isVIP: containsVIPFlag(value), isSuperVIP: containsSuperVIPFlag(value))
    }

    /// 含 vip/green 的会员标志键（排除时间/链接/描述类键）。
    static func containsVIPFlag(_ value: Any) -> Bool {
        func isFlagKey(_ key: String) -> Bool {
            let k = key.lowercased()
            guard k.contains("vip") || k.contains("green") else { return false }
            return !(k.contains("time") || k.contains("end") || k.contains("start") || k.contains("expire")
                     || k.contains("pay") || k.contains("url") || k.contains("icon") || k.contains("desc"))
        }
        if let dict = value as? [String: Any] {
            for (key, item) in dict {
                if isFlagKey(key) {
                    if let n = item as? NSNumber, n.intValue > 0 { return true }
                    if let t = item as? String, let n = Int(t), n > 0 { return true }
                }
                if containsVIPFlag(item) { return true }
            }
        } else if let arr = value as? [Any] {
            return arr.contains { containsVIPFlag($0) }
        }
        return false
    }

    /// iSuperVip / 其它含 supervip 的键数值 > 0 即 SVIP。
    static func containsSuperVIPFlag(_ value: Any) -> Bool {
        if let dict = value as? [String: Any] {
            for (key, item) in dict {
                let k = key.lowercased()
                if k.contains("supervip") {
                    if let n = item as? NSNumber, n.intValue > 0 { return true }
                    if let t = item as? String, let n = Int(t), n > 0 { return true }
                }
                if containsSuperVIPFlag(item) { return true }
            }
        } else if let arr = value as? [Any] {
            return arr.contains { containsSuperVIPFlag($0) }
        }
        return false
    }

    // MARK: - 酷狗资料字段扫描

    /// 酷狗 get_my_info 的 user_info 字典里任一会员字段 > 0 即会员。
    /// 字段（任务第 3 条）：is_vip / vip_type / svip_level / vip /
    /// m_type / su_vip / svip。注意不能用「取第一个在场的键」
    /// （intField 语义）：is_vip = 0 时 vip_type 可能 = 1，必须全扫取最大。
    static func kugouVIPValue(from profile: [String: Any]) -> Int {
        maxIntField(profile, "is_vip", "vip_type", "vipType", "vip", "m_type", "su_vip", "svip")
    }

    /// 酷狗 SVIP 字段：svip_level / svip / su_vip 任一 > 0 即 SVIP。
    static func kugouSuperVIPValue(from profile: [String: Any]) -> Int {
        maxIntField(profile, "svip_level", "svip", "su_vip")
    }

    /// 多键取最大值（NSNumber / 数字字符串都认；键都不在回 0）。
    static func maxIntField(_ d: [String: Any], _ keys: String...) -> Int {
        var best = 0
        for k in keys {
            if let n = d[k] as? NSNumber { best = max(best, n.intValue) }
            else if let s = d[k] as? String, let n = Int(s) { best = max(best, n) }
        }
        return best
    }
}

/// QQ / 酷狗会员查询的结构化结果（nil = 上游没给准信，不是「非会员」）。
/// expireTime 对这两家没有（上游不给到期时间），进 LoginState 时
/// expireTimeMs 记 0、label 按 SVIP/VIP 写。
struct VIPStatus: Equatable, Sendable {
    var isVIP: Bool
    var isSuperVIP: Bool

    func info() -> VIPInfo {
        VIPInfo(isActive: isVIP, isSuperVIP: isSuperVIP,
                label: VIPInfo.label(isSuperVIP: isSuperVIP, isActive: isVIP),
                expireTimeMs: 0)
    }
}
