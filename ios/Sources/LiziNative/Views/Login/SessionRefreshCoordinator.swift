import Foundation

/// QQ/酷狗 12h 静默刷新协调器（r31-qqkg）。
///
/// QQ/酷狗都没有刷新接口，Cookie 长期有效；每 12h 静默跑一次
/// refreshProfile（画像续期 + 酷狗设备重注册），场景激活时跑。
/// iOS 可能挂起任意后台网络工作，所以启动与回前台都调一次；
/// 12h 内只刷一次，不重复打上游。
#if os(iOS)
@MainActor
final class SessionRefreshCoordinator {
    static let shared = SessionRefreshCoordinator()

    private let interval: TimeInterval = 12 * 60 * 60
    private let lastRefreshKey = "lizi.qqkg.lastSilentRefresh"
    private var isRefreshing = false

    private init() {}

    /// r31 第三推：Cookie 每天最多续期一次（照 Moumusic auth.lastCookieRefresh，
    /// 按自然日记上次续期日）。12h 间隔一天内可跑两次，日上限把它压到一次。
    /// 今天已续过就不再续——硬性上限，force 也不绕过（续期是静默后台行为，
    /// 不是用户点按，同一天内重复续没有意义）。
    private let lastCookieRefreshDayKey = "lizi.qqkg.lastCookieRefreshDay"
    private func cookieRefreshDoneToday() -> Bool {
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return UserDefaults.standard.double(forKey: lastCookieRefreshDayKey) == today
    }
    private func markCookieRefreshedToday() {
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        UserDefaults.standard.set(today, forKey: lastCookieRefreshDayKey)
    }

    func refreshIfNeeded(force: Bool = false) async {
        guard !isRefreshing else { return }
        let last = UserDefaults.standard.double(forKey: lastRefreshKey)
        guard force || last == 0 || Date().timeIntervalSince1970 - last >= interval else { return }
        guard !cookieRefreshDoneToday() else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await QQMusicSessionStore.shared.refreshProfile()
        await KugouSessionStore.shared.refreshProfile()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRefreshKey)
        markCookieRefreshedToday()
    }
}
#endif
