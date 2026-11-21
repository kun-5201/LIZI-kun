import Foundation

/// 听歌排行模型（r31-rank）：只做网易服务端排行。
///
/// 数据链（全真实现，不摆架子）：
/// - 上游：网易 weapi POST `/v1/play/record`（`{uid, type, limit}`），
///   服务端见 `NetEaseService.neteasePlayRecord`（`Server/NetEase.swift`）；
///   回包 `weekData` / `allData`，单条 `{playCount, score, song}`，
///   另有 `weekDataSize` / `allDataSize` 真实总数。
/// - uid 不由客户端传：`LoginStore.LoginState` 里没有 uid 字段（只有
///   昵称 / 头像 / vip），服务端用本次登录会话的 `sessionVerify()` 取
///   `profile.userId`（与 `/api/session` 同源），客户端传 uid 既没处取、
///   也不可信；未登录时服务端回 code 401，客户端按未登录处理。
/// - 列表结构照 Moumusic 的 `ListeningRankView`（只学流程和结构，不抄
///   代码，GPL-3.0）：排名 + 46pt 封面 + 歌名/歌手 + 胶囊条 + 右侧「N 次」，
///   前 3 名用主题色；Moumusic 当前版只有最近一周、没有周/所有时间切换，
///   Lizi 把切换做出来（`RankPeriod`）。
/// - 其余 6 平台没有等价服务端接口：本文件不给它们编任何数据，
///   视图层直接给诚实空态（见 `ListeningRankView`）。
///
/// 曲目归一化复用 `Track.from(dict:platform:)`（网易 song 行的
/// `ar` / `al` / `dt` 字段它本来就认），不另写一套解析。
struct PlayRecord: Identifiable, Hashable {
    var id: String { track.id }
    /// 榜上的曲目（网易 song 行归一化来的 Track，platform 为 "netease"）。
    let track: Track
    /// 上游记的播放次数（`playCount`）。
    let playCount: Int
    /// 上游的热度权重（`score`）：胶囊条按它定宽。
    let score: Int

    /// 上游单条 `{playCount, score, song}` → PlayRecord。
    /// song 行缺 id 或缺歌名时 `Track.from` 回 nil，整条丢弃（不补假歌）。
    init?(dict: [String: Any], platform: String) {
        guard let songDict = dict["song"] as? [String: Any],
              let track = Track.from(dict: songDict, platform: platform) else { return nil }
        self.track = track
        self.playCount = Self.intValue(dict["playCount"])
        self.score = Self.intValue(dict["score"])
    }

    /// 数字容错读：JSONSerialization 给的是 NSNumber，也可能是数字字符串；
    /// 读不到回 0，不抛错、不编数。
    static func intValue(_ v: Any?) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let n = Int(s) { return n }
        return 0
    }
}

/// 排行周期：最近一周 / 所有时间。
///
/// - `rawValue` 就是上游的 `type`（1 = 最近一周，0 = 所有时间），
///   直接进 `/api/netease/play/record` 的 query，不另映射。
/// - `limit` 照 Moumusic 兼容版：周榜取 100、总榜取 1000；
///   上游另有 `*DataSize` 真实总数，不够时视图写清「显示前 N 首」。
enum RankPeriod: Int, CaseIterable {
    case week = 1
    case all = 0

    var title: String {
        switch self {
        case .week: return "最近一周"
        case .all: return "所有时间"
        }
    }

    /// 回包里本周期对应的数组键。
    var dataKey: String {
        switch self {
        case .week: return "weekData"
        case .all: return "allData"
        }
    }

    /// 回包里本周期对应的总数键。
    var sizeKey: String {
        switch self {
        case .week: return "weekDataSize"
        case .all: return "allDataSize"
        }
    }

    var limit: Int {
        switch self {
        case .week: return 100
        case .all: return 1000
        }
    }
}

/// 取榜失败的原因（视图按它分流，不拿一个笼统文案盖掉）：
/// - `notLoggedIn`：服务端回 401（没登录 / 会话已死）→ 显示登录按钮；
/// - `upstream`：上游回了非 200 的业务码 → 显示上游原话 + 重试；
/// - `transport`：`NativeBridge.call` 回 nil（请求本身没通）→ 显示断网文案 + 重试。
enum ListeningRankError: Error {
    case notLoggedIn
    case upstream(String)
    case transport
}

/// 听歌排行取数（纯逻辑，无 UI；视图只消费它的 Result）。
enum ListeningRankService {
    /// 拉一期榜：成功回（榜单，真实总数）；失败回原因。
    /// 总数取上游的 `*DataSize`，没有时回实际条数，不编。
    static func fetch(period: RankPeriod) async -> Result<(records: [PlayRecord], total: Int), ListeningRankError> {
        guard let d = await NativeBridge.call(
            path: "/api/netease/play/record",
            query: ["type": "\(period.rawValue)", "limit": "\(period.limit)"]
        ) else {
            return .failure(.transport)
        }
        let code = PlayRecord.intValue(d["code"])
        if code == 401 { return .failure(.notLoggedIn) }
        guard code == 200 else {
            let message = (d["error"] as? String) ?? (d["msg"] as? String) ?? ""
            return .failure(.upstream(message.isEmpty ? "上游返回 \(code)" : message))
        }
        let rows = (d[period.dataKey] as? [[String: Any]]) ?? []
        let records = rows.compactMap { PlayRecord(dict: $0, platform: "netease") }
        let total = PlayRecord.intValue(d[period.sizeKey])
        return .success((records, total > 0 ? total : records.count))
    }
}
