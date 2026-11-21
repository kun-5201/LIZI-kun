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
///   且 tracks 非空时命中。空结果不缓存——登录态变了之后回首页要能拉到
///   新数据，空态留着旧行为。
/// - 各栏：按（平台 → [栏: RailResult]）存；只存 error == nil 的结果。
///   失败的不缓存，下次访问重拉；重试按钮照常 force。
/// - 喜欢栏：星标变了才失效——`PlaybackStore.likedNeedsRefreshKey` 旗子
///   置起时 `loadRailPage` 绕开缓存重拉（见 HomeViewModel），缓存本身不
///   管旗子，只管存取。
/// - 缓存就是只拉一次：不做手动刷新（用户没要）。
@MainActor
final class HomeDataCache {
    static let shared = HomeDataCache()

    /// 一份每日推荐缓存：曲目 + 空原因 + 取数那天的 startOfDay。
    struct DailyEntry {
        var tracks: [DailyTrack]
        var emptyReason: String?
        var day: Date
    }

    private var dailyByPlatform: [String: DailyEntry] = [:]
    private var railsByPlatform: [String: [HomeRailPage: RailResult]] = [:]

    private init() {}

    /// 当日缓存的每日推荐（同一自然日且 tracks 非空才返回；否则 nil）。
    func dailyIfFresh(platform: String) -> DailyEntry? {
        guard let entry = dailyByPlatform[platform], !entry.tracks.isEmpty else { return nil }
        guard Calendar.current.isDate(entry.day, inSameDayAs: Date()) else { return nil }
        return entry
    }

    /// 存每日推荐：只存 tracks 非空的结果（空结果不缓存）。
    func storeDaily(platform: String, tracks: [DailyTrack], emptyReason: String?) {
        guard !tracks.isEmpty else { return }
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
