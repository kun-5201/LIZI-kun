import ActivityKit
import Foundation
import UIKit

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

    /// 后台起岛被拦下时暂存的启动请求（回前台再起；第 20 轮）。
    private struct PendingStart {
        let title: String
        let artist: String
        let state: LiziLyricsAttributes.ContentState
    }
    private let pendingLock = NSLock()
    private var pendingStart: PendingStart?
    /// 上次因后台记过“推迟”日志的曲目 key（同一首歌后台反复推只记一次，不刷屏）。
    private var lastDeferKey: String?
    private var foregroundObserver: NSObjectProtocol?
    /// 最近一次起岛的曲名/歌手（只作 updateActivity 时 payload 预算的估算用）。
    private var lastTitle = ""
    private var lastArtist = ""

    init() {
        refreshAuthorization()
        // Clear any activity left over from a previous launch.
        Task { @MainActor in await self.endAllActivities() }
        // 第 20 轮：后台暂存的起岛请求回前台再发（见 retryPendingStart）。
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.retryPendingStart() }
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
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
        // 第 20 轮：ContentState 超 4KB 必被 ActivityKit 拒（r19 真机 15 次
        // Payload maximum size exceeded）；先按预算压封面，仍超就去掉封面。
        let fitted = Self.fittedState(state, title: title, artist: artist, log: true)
        lastTitle = title
        lastArtist = artist
        Task { @MainActor in
            // 第 20 轮：后台 Activity.request 必抛 Target is not foreground
            //（r19 真机 5 次）。后台不请求、只暂存，回前台再起；同一首歌只记一次。
            guard UIApplication.shared.applicationState == .active else {
                self.deferStart(title: title, artist: artist, state: fitted)
                return
            }
            if let existing = self.activity {
                await existing.end(nil, dismissalPolicy: .immediate)
                self.activity = nil
            }
            let attributes = LiziLyricsAttributes(title: title, artist: artist)
            let content = ActivityContent(state: fitted, staleDate: Date().addingTimeInterval(10))
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
                // 后台竞态（检查完才切后台）：同样暂存等回前台，不刷屏。
                if error.localizedDescription.localizedCaseInsensitiveContains("not foreground") {
                    self.deferStart(title: title, artist: artist, state: fitted)
                    return
                }
                DiagLog.shared.recordPlaybackStep("island start FAIL: \(error.localizedDescription)")
                DiagLog.shared.recordLog(category: "island",
                    message: "灵动岛 Activity.request 抛错（auth=\(authDesc)）：\(error.localizedDescription)",
                    fields: ["reason": "island-request-failed", "lane": "island"])
            }
        }
    }

    /// 后台暂存一次启动请求（同一首歌只记一次日志/面包屑，不刷屏）。
    private func deferStart(title: String, artist: String, state: LiziLyricsAttributes.ContentState) {
        let key = "\(title)\n\(artist)"
        pendingLock.lock()
        let isNew = lastDeferKey != key || pendingStart == nil
        pendingStart = PendingStart(title: title, artist: artist, state: state)
        if isNew { lastDeferKey = key }
        pendingLock.unlock()
        guard isNew else { return }
        DiagLog.shared.recordPlaybackStep("island start deferred (background)")
        DiagLog.shared.recordLog(category: "island",
            message: "灵动岛启动推迟：App 在后台，回前台再起",
            fields: ["reason": "island-deferred-background", "lane": "island"])
    }

    /// 回前台时把暂存的启动请求发出去（仍在后台就留着下次再试）。
    @MainActor
    private func retryPendingStart() {
        pendingLock.lock()
        let pending = pendingStart
        pendingLock.unlock()
        guard let pending else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        pendingLock.lock()
        pendingStart = nil
        lastDeferKey = nil
        pendingLock.unlock()
        startActivity(title: pending.title, artist: pending.artist, state: pending.state)
    }

    // MARK: - Payload 预算（第 20 轮）

    /// ActivityKit 单条推送上限约 4KB；JSON 编码后的 state + attributes
    /// 按这个预算卡（实测：120px JPEG q0.8 的实拍封面编后约 5.4KB，必超；
    /// q0.7 约 4.5KB 仍超，q0.6 约 3.9KB 无余量——只靠固定档位不够，
    /// 必须运行时量、逐档压、仍超就去封面）。
    static let islandPayloadBudget = 3800

    /// state + attributes 的 JSON 编码字节数（ContentState 里的 Data 按
    /// base64 计，和实际推送体同量级；作预算代理，不追求逐字节相等）。
    static func payloadSize(title: String, artist: String, state: LiziLyricsAttributes.ContentState) -> Int {
        let encoder = JSONEncoder()
        var size = 0
        if let data = try? encoder.encode(state) { size += data.count }
        if let data = try? encoder.encode(LiziLyricsAttributes(title: title, artist: artist)) { size += data.count }
        return size
    }

    /// 把 state 压进预算：先原样试；超了就把封面按 (96px, 0.6) → (80px, 0.5)
    /// → (64px, 0.5) 逐档重压；仍超就去掉封面（词和进度一定能推上去）。
    /// 起岛/更新都过这一道，所以两条组装路（原生协调器与网页桥）不用各自再算。
    /// log=true 只在起岛时记（更新每 5 秒一次，不记，免得刷诊断）。
    static func fittedState(_ state: LiziLyricsAttributes.ContentState, title: String, artist: String, log: Bool = false) -> LiziLyricsAttributes.ContentState {
        let originalSize = payloadSize(title: title, artist: artist, state: state)
        guard state.coverData != nil, originalSize > islandPayloadBudget else {
            if log, state.coverData != nil {
                DiagLog.shared.recordLog(category: "island",
                    message: "island payload bytes=\(originalSize) cover kept",
                    fields: ["reason": "island-payload-ok", "lane": "island"])
            }
            return state
        }
        if let data = state.coverData, let image = UIImage(data: data) {
            for (px, quality) in [(96, CGFloat(0.6)), (80, CGFloat(0.5)), (64, CGFloat(0.5))] {
                guard let thumb = thumbnail(image, maxSide: CGFloat(px), quality: quality) else { continue }
                var candidate = state
                candidate.coverData = thumb
                let size = payloadSize(title: title, artist: artist, state: candidate)
                if size <= islandPayloadBudget {
                    if log {
                        DiagLog.shared.recordLog(category: "island",
                            message: "island payload bytes=\(originalSize)->\(size) cover down to \(px)px q\(quality)",
                            fields: ["reason": "island-payload-shrunk", "lane": "island"])
                    }
                    return candidate
                }
            }
        }
        var dropped = state
        dropped.coverData = nil
        let size = payloadSize(title: title, artist: artist, state: dropped)
        if log {
            DiagLog.shared.recordLog(category: "island",
                message: "island payload bytes=\(originalSize)->\(size) cover dropped (still over budget)",
                fields: ["reason": "island-payload-cover-dropped", "lane": "island"])
        }
        return dropped
    }

    /// 等比缩到最长边 px，JPEG 重压（只在 fittedState 超预算时走，不常跑）。
    private static func thumbnail(_ image: UIImage, maxSide: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = maxSide / max(size.width, size.height)
        let target = scale >= 1
            ? size
            : CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: quality)
    }

    /// Pushes a new state to the running activity. No-op when none is running.
    /// The coordinator throttles calls: only on lyric-line / track change,
    /// or a progress refresh at most every 5 seconds.
    func updateActivity(state: LiziLyricsAttributes.ContentState) {
        guard let activity else { return }
        // 更新同样受 4KB 限制：超了整条更新被拒，先按预算压封面（不记日志）。
        let fitted = Self.fittedState(state, title: lastTitle, artist: lastArtist)
        Task { @MainActor in
            let content = ActivityContent(state: fitted, staleDate: Date().addingTimeInterval(10))
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
