import ActivityKit
import Foundation

/// Drives the Dynamic Island / Live Activity that shows the synced lyric
/// of the song playing in the Lizi web player.
///
/// Adapted from island-lyrics, but deliberately NOT @MainActor: the Lizi
/// WebHost that owns this manager is not MainActor-isolated, and Swift
/// rejects creating a MainActor object as a default property value in a
/// nonisolated context. ActivityKit calls are hopped to the main actor
/// internally, so the actual island updates still run on the main thread.
///
/// Hard rules (learned from the sibling kun project):
/// - Starting requires ONLY `areActivitiesEnabled`. A switched-off
///   "More Frequent Updates" (frequentPushesEnabled, iOS 17.2+) is a warning,
///   never a gate — otherwise the island silently stays black.
/// - `staleDate` is 10 seconds on every push, so the island disappears
///   shortly after playback stops. (第 12 轮 03:43 收紧：原来 15 秒。)
/// - Ending uses dismissalPolicy `.immediate`.
final class LiveActivityManager {

    enum IslandAuthorization {
        /// System Live Activities are on. Frequent updates may still be off;
        /// that is reported separately as a warning.
        case allowed
        /// System Live Activities are off; nothing can be started.
        case notAllowed
        /// Live Activities are on, but "More Frequent Updates" is off.
        /// Starting still works; updates may be throttled by the system.
        case frequentUpdatesOffWarning
    }

    private(set) var isRunning: Bool = false
    private(set) var lastError: String?
    private(set) var authorization: IslandAuthorization = .notAllowed

    private var activity: Activity<LiziLyricsAttributes>?

    init() {
        refreshAuthorization()
        // Clear any activity left over from a previous launch.
        Task { @MainActor in await self.endAllActivities() }
    }

    /// Re-reads the system authorization state. Call when the app returns
    /// to the foreground.
    func refreshAuthorization() {
        let info = ActivityAuthorizationInfo()
        if !info.areActivitiesEnabled {
            authorization = .notAllowed
        } else if !info.frequentPushesEnabled {
            authorization = .frequentUpdatesOffWarning
        } else {
            authorization = .allowed
        }
    }

    /// Starts (or restarts) the island activity for a track.
    /// If an activity is already running it is ended first.
    func startActivity(title: String, artist: String, state: LiziLyricsAttributes.ContentState) {
        refreshAuthorization()
        // 第 15 轮第 3 件：启动失败原来全是静默（未允许只写 lastError，
        // 全仓无任何 UI 或诊断引用；Activity.request 抛错同样静默），
        // 岛起不来时诊断里一行都没有。现在两条失败路都记 DiagLog，
        // 并把 Live Activities 权限状态写进去，下次报告能看到系统允不允许。
        let authDesc: String
        switch authorization {
        case .allowed: authDesc = "allowed"
        case .notAllowed: authDesc = "notAllowed"
        case .frequentUpdatesOffWarning: authDesc = "frequentUpdatesOff"
        }
        guard authorization != .notAllowed else {
            lastError = "系统未允许 Live Activities，请在 iOS 设置中开启"
            // 第 16 轮第 3 件：岛启动/结束点进面包屑——崩在起岛时最后一步在这里。
            DiagLog.shared.recordPlaybackStep("island start blocked (notAllowed)")
            DiagLog.shared.recordLog(category: "island",
                message: "灵动岛启动失败：系统未允许 Live Activities（auth=\(authDesc)）",
                fields: ["reason": "island-not-allowed", "lane": "island"])
            return
        }
        Task { @MainActor in
            if let existing = self.activity {
                await existing.end(nil, dismissalPolicy: .immediate)
                self.activity = nil
            }
            let attributes = LiziLyricsAttributes(title: title, artist: artist)
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(10))
            do {
                let newActivity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                self.activity = newActivity
                self.isRunning = true
                self.lastError = nil
                // 第 16 轮第 3 件：岛启动成功记一步（扩展更新点）。
                DiagLog.shared.recordPlaybackStep("island start ok")
            } catch {
                self.lastError = "启动灵动岛失败：\(error.localizedDescription)"
                self.isRunning = false
                DiagLog.shared.recordPlaybackStep("island start FAIL: \(error.localizedDescription)")
                DiagLog.shared.recordLog(category: "island",
                    message: "灵动岛 Activity.request 抛错（auth=\(authDesc)）：\(error.localizedDescription)",
                    fields: ["reason": "island-request-failed", "lane": "island"])
            }
        }
    }

    /// Pushes a new state to the running activity. No-op when none is running.
    /// The coordinator throttles calls: only on lyric-line / track change,
    /// or a progress refresh at most every 5 seconds.
    func updateActivity(state: LiziLyricsAttributes.ContentState) {
        guard let activity else { return }
        Task { @MainActor in
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(10))
            await activity.update(content)
        }
    }

    /// Ends the activity immediately. No-op when none is running.
    func endActivity() {
        guard let activity else { return }
        self.activity = nil
        isRunning = false
        // 第 16 轮第 3 件：岛结束点（停歌/切歌重起时）。
        DiagLog.shared.recordPlaybackStep("island end")
        Task { @MainActor in
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// 终止路径专用（第 12 轮 03:43：App 被关掉时岛必须马上消失，一秒都不能留）：
    /// 同步结束所有活动——等 end 真正完成才返回（最多 timeout 秒），不走
    /// fire-and-forget 的 Task。kun #58 的教训：进程死前 Task 可能根本没跑起来，
    /// end 必须落在日志/返回之前。applicationWillTerminate 里调；
    /// 平时暂停走异步 endActivity 就够了（App 还活着，Task 一定会跑）。
    /// 切到后台不走这里：后台只进 scenePhase / didEnterBackground，岛和音乐都还在。
    static func endAllActivitiesSynchronously(timeout: TimeInterval = 2) {
        let activities = Activity<LiziLyricsAttributes>.activities
        guard !activities.isEmpty else { return }
        // 第 16 轮第 3 件：终止路径点——App 被关前最后一步，文件落盘后还在。
        DiagLog.shared.recordPlaybackStep("island end-all (terminate)")
        let group = DispatchGroup()
        for activity in activities {
            group.enter()
            // 不加 @MainActor：end 不要求主线程；group.wait 本来就占着主线程，
            // Task 要是也等主线程就死锁了。kun #58 同款写法（.userInitiated）。
            Task(priority: .userInitiated) {
                await activity.end(nil, dismissalPolicy: .immediate)
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
    }

    /// Ends every live activity of this type, including ones left over from
    /// a previous launch. (In this SDK `Activity.activities` is a plain
    /// array, not an async sequence.)
    private func endAllActivities() async {
        for activity in Activity<LiziLyricsAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        if activity == nil {
            isRunning = false
        }
    }
}
