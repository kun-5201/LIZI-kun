import Foundation

/// 看视频 / 看广告得来的免费播放资格 — 只做校验，不做领取。
///
/// 口径（用户 2026-11-21 07:33 决定，覆盖 r31 原任务单「功能真实现」的领法部分）：
/// 本 App 不告诉用户怎么领，不加任何引导入口与按钮；
/// 只校验用户是不是已经在官方 App 里看视频 / 看广告拿到了免费播放资格，
/// 校验到有就放行（正常播），没有就按正常规则走。
///
/// 7 平台逐个核查（2026-11-21，VM 核查 + 公开报道；结论写进 `spec(for:)`，不编）：
/// - 网易：有。官方免费模式：看 15 秒广告 → 30 分钟免费听歌，仅受邀非会员，
///   每日次数有限（具体次数官方未公开，以 App 内提示为准），自然时长倒计时、
///   不可累积，数字专辑 / 付费单曲除外，仅标准音质。
///   无公开的资格状态查询接口（NeteaseCloudMusicApi 功能表只有 vip_info /
///   vip 任务 / vip 成长值，没有免费模式模块；Binaryify 原仓库现仅剩 README）。
/// - QQ：有。免费畅听：看 15 秒广告 → 30 分钟，仅受邀非绿钻 / 非付费包，
///   每日可多次，自然时长倒计时，付费单曲 / 专辑 / 电台 VIP 内容除外，
///   仅标准音质。无公开的资格状态查询接口（musicu 无公开的免费时长查询模块）。
/// - 酷狗：有。主 App 免费模式：看广告 → 约 30 分钟，仅受邀非会员，测试名单
///   每日更新，充过会员的账号看不到入口；另有概念版每日登录 / 看广告换当日 VIP、
///   免费版 App 看 2 条广告换全天。无公开的资格状态查询接口；Lizi 内
///   Folia `user/vip` 只回付费 VIP（vip_type），免费模式不改变该标志。
/// - 汽水：没有这种资格形态。基础听歌本身免费（非会员可完整听全部歌曲，
///   会员只加无损音质 / 离线下载 / 去广告），播放不靠免费资格。
/// - 波点：有。QQ 音乐概念版：新用户 90 天福利会员（每天登录领），之后每天
///   看 3 个 5–10 秒广告换 1 天会员；单条广告约 45 分钟 VIP。无公开的资格
///   状态查询接口；Bodian `checkRight` 只区分可播 / 试听 / 需权益
///   （status 3 / 7），不回免费资格剩余。
/// - 酷我：未核实到。多篇盘点提到「看广告换听歌」，但未核实到具体领法
///   （几条广告、多少时长、次数）与公开接口；Lizi 内 status 的 vip 一律
///   false、无校验接口。不编领法、不编时长。
/// - Apple Music：没有。无免费档、无广告 tier、无看视频领权益；只有新用户
///   试用（1 个月 / 购设备 3 个月 / Shazam 试用）。
///
/// 校验方法（唯一可观测的信号；见 `notePlatformGranted` / `verify`）：
/// 各平台都不给第三方查「免费资格剩多少」的接口，唯一能从服务端读到的信号是
/// 取链结果本身：曲目行带付费标记（`Track.vip`，fee != 0）且账号非 VIP 时，
/// 平台腿回了完整地址 → 服务端这次放行了，记一次「已验证有资格」；
/// 平台腿以 reason `vip` 拒绝 → 服务端这次没放行，本地资格立即失效
/// （服务端为准）。`Track.vip` 只有网易（fee）、QQ（pay.pay_play）、波点
/// （payInfo.payType）三家带标记，酷我 / 汽水 / 酷狗 / Apple Music 的曲目行
/// fee 恒 0，分不出 VIP 歌，所以这四家记为无法校验 / 没有，不编。
/// 本地有效期是按官方口径的上限估算（网易 / QQ / 酷狗 30 分钟，波点 1 天），
/// 真正失效以服务端下一次拒绝为准，拒绝即刻失效。
///
/// 持久化：每个平台一条 JSON，键 `lizi.videoreward.<platform>`（本类自己的键，
/// 不碰 `LoginStore.swift`；读登录态只调 `LoginStore` 现有接口
/// `isVip(platform:)` / `refresh(platform:)`）。重启保留；过期即失效。
@MainActor
final class VideoRewardStore: ObservableObject {

    static let shared = VideoRewardStore()

    /// 7 个平台 id（与 `LoginStore.platforms` 同序同值）。
    static let platforms = ["netease", "qq", "kugou", "qishui", "bodian", "kuwo", "applemusic"]

    /// 资格状态（只描述校验结果，不描述领取动作）。
    enum EligibilityStatus: String, Codable {
        /// 已验证有免费资格（证据见 `evidence`），且未过期。
        case active
        /// 已核查过，无免费资格（或曾有但已过期 / 被服务端拒绝后失效）。
        case none
        /// 账号已有付费 VIP，官方免费模式只给非会员，无需免费资格。
        case notNeeded
        /// 平台官方有此资格形态，但 Lizi 没有可区分的校验信号（无资格状态接口、
        /// 曲目行不带付费标记），无法校验，不编有 / 没有。
        case unverifiable
        /// 平台根本没有这种资格形态。
        case unsupported
    }

    /// 一条平台的资格记录（Codable → UserDefaults JSON，重启保留）。
    struct Eligibility: Codable {
        var platform: String
        var status: EligibilityStatus
        /// 本地估算的到期时间（active 才有；见文件头：官方口径上限估算）。
        var expiresAt: Date?
        /// 最近一次核验时间（平台腿放行 / 状态刷新 / 过期失效时更新）。
        var lastVerifiedAt: Date?
        /// 证据原文（哪次取链放行 / 哪次被拒 / 哪次过期），不编。
        var evidence: String
    }

    /// 每平台的核查结论（见文件头 7 平台表）。
    struct Spec {
        /// 官方有没有「看视频 / 看广告换免费播放资格」这一形态
        /// （.unconfirmed = 有盘点提到但未核实到具体领法与接口）。
        enum Grant { case yes, no, unconfirmed }
        var grant: Grant
        /// 本地估算的有效期上限（秒；官方口径；没有口径时为 nil）。
        var grantWindowSeconds: TimeInterval?
        /// 该平台的曲目行是否带付费标记（`Track.vip` 是否可信）——只有带标记的
        /// 平台，「VIP 歌平台腿回了地址 + 账号非 VIP」才能算一次已验证的资格。
        var verifiable: Bool
        /// 「没有」时的诚实说明（statusText / footnote 用，不含任何领法）。
        var unsupportedNote: String
    }

    /// 7 平台核查表（核查日期 2026-11-21；口径见文件头）。
    static func spec(for platform: String) -> Spec {
        switch platform {
        case "netease":
            // 免费模式：15 秒广告 → 30 分钟；曲目行 fee 可信。
            return Spec(grant: .yes, grantWindowSeconds: 1800, verifiable: true, unsupportedNote: "")
        case "qq":
            // 免费畅听：15 秒广告 → 30 分钟；曲目行 pay.pay_play 可信。
            return Spec(grant: .yes, grantWindowSeconds: 1800, verifiable: true, unsupportedNote: "")
        case "kugou":
            // 主 App 免费模式约 30 分钟；但曲目行 fee 恒 0，分不出 VIP 歌，
            // 且无资格状态接口 → 无法校验。
            return Spec(grant: .yes, grantWindowSeconds: 1800, verifiable: false, unsupportedNote: "")
        case "qishui":
            // 基础听歌本身免费，无会员墙，没有这种资格形态。
            return Spec(grant: .no, grantWindowSeconds: nil, verifiable: false,
                        unsupportedNote: "基础听歌本身免费，无需此资格")
        case "bodian":
            // 概念版：每天 3 条广告换 1 天会员；曲目行 payInfo.payType 可信。
            return Spec(grant: .yes, grantWindowSeconds: 86400, verifiable: true, unsupportedNote: "")
        case "kuwo":
            // 有盘点提到看广告换听歌，但未核实到具体领法与公开接口；
            // 曲目行 fee 恒 0，且 status 的 vip 一律 false → 无法校验。
            return Spec(grant: .unconfirmed, grantWindowSeconds: nil, verifiable: false, unsupportedNote: "")
        case "applemusic":
            // 无免费档、无广告 tier，无看视频领权益。
            return Spec(grant: .no, grantWindowSeconds: nil, verifiable: false,
                        unsupportedNote: "无免费档、无广告")
        default:
            return Spec(grant: .unconfirmed, grantWindowSeconds: nil, verifiable: false, unsupportedNote: "")
        }
    }

    /// 各平台记录（内存态；初始化时从 UserDefaults 读回，重启保留）。
    @Published private(set) var records: [String: Eligibility] = [:]

    private init() {
        for p in Self.platforms {
            records[p] = Self.load(platform: p)
        }
    }

    // MARK: - 键与持久化（本类自己的 UserDefaults 键）

    static func key(for platform: String) -> String { "lizi.videoreward.\(platform)" }

    private static func load(platform: String) -> Eligibility {
        if let data = UserDefaults.standard.data(forKey: key(for: platform)),
           let rec = try? JSONDecoder().decode(Eligibility.self, from: data) {
            return rec
        }
        return baseline(platform: platform)
    }

    /// 未存过记录时的基线（只按核查表给，不编资格）：
    /// 没有此形态 → unsupported；有形态但无法校验 → unverifiable；
    /// 有形态且可校验 → none（未验证到）。
    static func baseline(platform: String) -> Eligibility {
        let s = spec(for: platform)
        let status: EligibilityStatus
        switch s.grant {
        case .no: status = .unsupported
        case .unconfirmed: status = .unverifiable
        case .yes: status = s.verifiable ? .none : .unverifiable
        }
        return Eligibility(platform: platform, status: status,
                           expiresAt: nil, lastVerifiedAt: nil, evidence: "")
    }

    private func save(_ rec: Eligibility) {
        records[rec.platform] = rec
        if let data = try? JSONEncoder().encode(rec) {
            UserDefaults.standard.set(data, forKey: Self.key(for: rec.platform))
        }
    }

    // MARK: - 读数（纯本地计算；过期即失效）

    /// 该平台当前记录（读时先算过期：active 已过 expiresAt 就地转 none 并落盘，
    /// 过期资格绝不继续当有效用）。
    func record(for platform: String) -> Eligibility {
        var rec = records[platform] ?? Self.baseline(platform: platform)
        if rec.status == .active, let exp = rec.expiresAt, Date() >= exp {
            rec.status = .none
            rec.expiresAt = nil
            rec.lastVerifiedAt = Date()
            rec.evidence = "已过期（本地估算有效期到 \(Self.formatTime(exp))）"
            save(rec)
        }
        return rec
    }

    /// 是否有免费播放资格（只认未过期的 active；其余一律 false，按正常规则走）。
    func isEligible(platform: String) -> Bool {
        record(for: platform).status == .active
    }

    // MARK: - 校验入口（证据只来自服务端取链结果与登录态，不编）

    /// 平台腿放行了一首 VIP 歌（PlaybackStore 取链成功时调）：
    /// 只在同时满足三条时记一次「已验证有资格」——该平台可校验（曲目行带付费标记）、
    /// 这首是 VIP 歌（track.vip）、地址来自平台腿（via == "platform"，LX / 云盘 /
    /// 本地下载不算：那几条腿不经过平台的会员校验，给不出免费资格的证据）。
    /// 账号已有付费 VIP 时记 notNeeded（免费模式只给非会员，见文件头）。
    /// 其余平台（无法校验 / 没有此形态）直接 no-op，不编记录。
    func notePlatformGranted(track: Track, via: String) {
        let platform = track.platform
        let s = Self.spec(for: platform)
        guard s.verifiable, track.vip, via == "platform" else { return }
        if LoginStore.shared.isVip(platform: platform) {
            var rec = record(for: platform)
            guard rec.status != .notNeeded else { return }
            rec.status = .notNeeded
            rec.expiresAt = nil
            rec.lastVerifiedAt = Date()
            rec.evidence = "账号已有付费 VIP"
            save(rec)
            return
        }
        guard let window = s.grantWindowSeconds else { return }
        let now = Date()
        let rec = Eligibility(platform: platform, status: .active,
                              expiresAt: now.addingTimeInterval(window),
                              lastVerifiedAt: now,
                              evidence: "VIP 歌曲平台取链成功（\(track.id)）")
        save(rec)
        DiagLog.shared.recordPlaybackStep("videoreward granted source=\(platform) id=\(track.id)")
    }

    /// 平台腿以 reason `vip` 拒绝了 VIP 歌（PlaybackStore 取链失败时调）：
    /// 本地记的 active 与服务端矛盾 → 服务端为准，立即失效（只清 active，
    /// 其它状态不动，不编一条 none 记录出来）。
    func noteVIPRefusal(platform: String) {
        var rec = record(for: platform)
        guard rec.status == .active else { return }
        rec.status = .none
        rec.expiresAt = nil
        rec.lastVerifiedAt = Date()
        rec.evidence = "服务端拒绝 VIP 歌曲（reason=vip），资格已失效"
        save(rec)
        DiagLog.shared.recordPlaybackStep("videoreward refused source=\(platform)")
    }

    /// 主动再核验一次（账号详情页打开时调）：
    /// 刷一次平台登录态（`LoginStore.refresh(platform:)`，现有接口，只读）——
    /// 状态接口只回登录 / VIP，不回免费资格剩余，所以这里不编一个「资格查询接口」：
    /// 已是 VIP → notNeeded；本地 active 未过期 → 只更新核验时间；
    /// 其余状态原样不动（没有就还是没有，不编）。
    @discardableResult
    func verify(platform: String) async -> Eligibility {
        _ = await LoginStore.refresh(platform: platform)
        if LoginStore.shared.isVip(platform: platform) {
            var rec = record(for: platform)
            if rec.status != .notNeeded {
                rec.status = .notNeeded
                rec.expiresAt = nil
                rec.lastVerifiedAt = Date()
                rec.evidence = "账号已有付费 VIP"
                save(rec)
            }
            return rec
        }
        var rec = record(for: platform)
        if rec.status == .active {
            rec.lastVerifiedAt = Date()
            save(rec)
        }
        return rec
    }

    // MARK: - 只读展示（状态文案，不含任何领法、不含按钮文案）

    /// 账号详情页「免费播放资格」行的值（纯校验结果）。
    func statusText(platform: String) -> String {
        let rec = record(for: platform)
        switch rec.status {
        case .active:
            if let exp = rec.expiresAt {
                return "已验证有效至 \(Self.formatTime(exp))"
            }
            return "已验证有效"
        case .none:
            return "未验证到免费资格"
        case .notNeeded:
            return "已有付费会员"
        case .unverifiable:
            return "无法校验（无公开接口）"
        case .unsupported:
            let note = Self.spec(for: platform).unsupportedNote
            return note.isEmpty ? "该平台没有此资格" : note
        }
    }

    /// 同一行的补充说明（只说校验口径与失效规则，不说怎么领）。
    func statusFootnote(platform: String) -> String {
        let rec = record(for: platform)
        switch rec.status {
        case .active:
            return "校验结果来自平台服务端取链；过期或被拒即失效。"
        case .none:
            return "未验证到免费资格，按正常规则播放。"
        case .notNeeded:
            return "已有付费会员，无需免费资格。"
        case .unverifiable:
            return "该平台没有可调的资格状态接口，无法校验。"
        case .unsupported:
            return "该平台没有这种资格形态。"
        }
    }

    /// 到期时间显示：当天只写 HH:mm，跨天写 M 月 d 日 HH:mm。
    static func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M月d日 HH:mm"
        return f.string(from: date)
    }
}
