import Foundation

/// 首页取数缓存（r35）：首页数据只拉一次、进程内缓存住；只有用户切到
/// 还没拉过的歌单/来源时才拉一次，切回来用缓存。
///
/// 之前（r34）：切平台时 `resetHomeContent` 把 `railResults = [:]` 全清、
/// `daily = []`，A→B→A 全部重拉；`loadRailPage` 的缓存守卫把 `.liked`
/// 排除在外，每次切回喜欢栏都重拉；HomeViewModel 是 HomeView 里的
/// @StateObject，RootView 切页销毁 HomeView、回首页新建模型，
/// `didInitialLoad` 守卫只在实例活着时有效，回首页就重拉每日推荐。
///
/// 本缓存是进程内单例（`static shared`），活得比 HomeViewModel 实例久，
/// 模型重建不丢；只在内存里，不落盘、不跨启动（下次启动重新拉取，
/// 服务端改了最多等到下次启动才看到，见交回残留）。
/// - 每日推荐：按平台存，Entry 带取数那天的 startOfDay；只在同一自然日
///   且 tracks 非空时命中。空结果存一份 5 分钟否定缓存（r35-9，见下）——
///   空平台每次回首页都重拉、每次最多转 25 秒，有效期内切回直接显示
///   空态文案，不起新请求、不亮 spinner；过期重拉；登录态变了最多
///   5 分钟就能拉到新数据（仓内没有登录态变化的通知可挂，只靠短 TTL，
///   见交回残留）。
/// - 排行榜目录（r35-10）：按平台存，Entry 带取数那天的 startOfDay；
///   只在同一自然日且 boards 非空时命中。空结果存一份 5 分钟否定缓存
///   （与每日推荐同款 negativeTTL，见下）；没榜的平台（波点/汽水/
///   Apple Music）不发请求、不缓存，文案直接由 NativeBridge.rankBoards
///   给出，ViewModel 不走缓存。
/// - 各栏：按（平台 → [栏: RailResult]）存；只存 error == nil 的结果。
///   失败的不缓存，下次访问重拉；重试按钮照常 force。
/// - 喜欢栏：星标变了才失效——`PlaybackStore.likedNeedsRefreshKey` 旗子
///   置起时 `loadRailPage` 绕开缓存重拉（见 HomeViewModel），缓存本身不
///   管旗子，只管存取。
/// - 缓存就是只拉一次：不做手动刷新（用户没要）。
@MainActor
final class HomeDataCache {
    static let shared = HomeDataCache()

    /// 否定缓存有效期（r35-9：报告给的 5–10 分钟取短端 5 分钟，登录态
    /// 变了最多 5 分钟就能拉到新数据；不要按自然日）。
    static let negativeTTL: TimeInterval = 300

    /// 一份每日推荐缓存：曲目 + 空原因 + 取数那天的 startOfDay。
    struct DailyEntry {
        var tracks: [DailyTrack]
        var emptyReason: String?
        var day: Date
    }

    /// 一份空结果否定缓存：空原因 + 存入时间（5 分钟内有效）。
    struct DailyNegativeEntry {
        var emptyReason: String?
        var storedAt: Date
    }

    private var dailyByPlatform: [String: DailyEntry] = [:]
    private var dailyNegativeByPlatform: [String: DailyNegativeEntry] = [:]
    private var railsByPlatform: [String: [HomeRailPage: RailResult]] = [:]
    /// 排行榜目录缓存（r35-10）：按平台存，boards + 空原因 + 取数那天。
    private var rankByPlatform: [String: RankEntry] = [:]
    private var rankNegativeByPlatform: [String: DailyNegativeEntry] = [:]

    private init() {}

    /// 一份排行榜目录缓存：榜单 + 空原因 + 取数那天的 startOfDay。
    struct RankEntry {
        var boards: [RankBoard]
        var emptyReason: String?
        var day: Date
    }

    /// 当日缓存的排行榜目录（同一自然日且 boards 非空才返回；否则 nil）。
    func rankIfFresh(platform: String) -> RankEntry? {
        guard let entry = rankByPlatform[platform], !entry.boards.isEmpty else { return nil }
        guard Calendar.current.isDate(entry.day, inSameDayAs: Date()) else { return nil }
        return entry
    }

    /// 有效期内的榜单否定缓存（空结果 + 空原因；没有或过期返回 nil）。
    func rankNegativeIfFresh(platform: String) -> RankEntry? {
        guard let neg = rankNegativeByPlatform[platform],
              Date().timeIntervalSince(neg.storedAt) < Self.negativeTTL else { return nil }
        return RankEntry(boards: [], emptyReason: neg.emptyReason,
                         day: Calendar.current.startOfDay(for: Date()))
    }

    /// 存排行榜目录：非空存当日缓存（同时清掉该平台的否定缓存）；
    /// 空结果存一份 5 分钟否定缓存（不碰当日非空缓存）。
    func storeRank(platform: String, boards: [RankBoard], emptyReason: String?) {
        if boards.isEmpty {
            rankNegativeByPlatform[platform] = DailyNegativeEntry(
                emptyReason: emptyReason, storedAt: Date())
            return
        }
        rankNegativeByPlatform[platform] = nil
        rankByPlatform[platform] = RankEntry(
            boards: boards,
            emptyReason: emptyReason,
            day: Calendar.current.startOfDay(for: Date()))
    }

    /// 当日缓存的每日推荐（同一自然日且 tracks 非空才返回；否则 nil）。
    func dailyIfFresh(platform: String) -> DailyEntry? {
        guard let entry = dailyByPlatform[platform], !entry.tracks.isEmpty else { return nil }
        guard Calendar.current.isDate(entry.day, inSameDayAs: Date()) else { return nil }
        return entry
    }

    /// 有效期内的否定缓存（空结果 + 空原因，复用 DailyEntry 形状，
    /// tracks 为空；没有或过期返回 nil）。
    func dailyNegativeIfFresh(platform: String) -> DailyEntry? {
        guard let neg = dailyNegativeByPlatform[platform],
              Date().timeIntervalSince(neg.storedAt) < Self.negativeTTL else { return nil }
        return DailyEntry(tracks: [], emptyReason: neg.emptyReason,
                          day: Calendar.current.startOfDay(for: Date()))
    }

    /// 存每日推荐：非空存当日缓存（同时清掉该平台的否定缓存）；
    /// 空结果存一份 5 分钟否定缓存（不碰当日非空缓存——同日已有非空
    /// 数据时，空结果不该把它顶掉，loadDaily 查缓存时非空优先）。
    func storeDaily(platform: String, tracks: [DailyTrack], emptyReason: String?) {
        if tracks.isEmpty {
            dailyNegativeByPlatform[platform] = DailyNegativeEntry(
                emptyReason: emptyReason, storedAt: Date())
            return
        }
        dailyNegativeByPlatform[platform] = nil
        dailyByPlatform[platform] = DailyEntry(
            tracks: tracks,
            emptyReason: emptyReason,
            day: Calendar.current.startOfDay(for: Date()))
    }

    /// 某平台某栏的缓存结果（没有返回 nil）。
    func rail(platform: String, page: HomeRailPage) -> RailResult? {
        railsByPlatform[platform]?[page]
    }

    /// 某平台整份栏缓存（恢复 `railResults` 用；没拉过的平台是空字典）。
    func rails(platform: String) -> [HomeRailPage: RailResult] {
        railsByPlatform[platform] ?? [:]
    }

    /// 存一栏结果：只存 error == nil 的结果（失败的不缓存）。
    func storeRail(platform: String, page: HomeRailPage, result: RailResult) {
        guard result.error == nil else { return }
        railsByPlatform[platform, default: [:]][page] = result
    }
}
