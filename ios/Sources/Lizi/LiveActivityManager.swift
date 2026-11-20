import ActivityKit
import Foundation
import UIKit

/// Drives the Dynamic Island / Live Activity (Apple Music 款：封面 /
/// 歌名+歌手 / 波形 / 进度 / 控制行，无歌词——第 22 轮第 5 件）。
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
/// - `staleDate` 是 islandStaleSeconds（8 秒），每次推送都带。岛的
///   正常更新是 5 秒一次（进度节流），8 秒 = 5 秒间隔 + 3 秒余量：
///   正常播放中途不会被杀；App 被挂起后划掉（iOS 直接 SIGKILL，不走
///   applicationWillTerminate，任何代码都跑不到）时，staleDate 是唯一能
///   清残岛的手段——8 秒是底线，再短会在更新被系统节流时误杀正常播放
///   的岛。（第 12 轮 03:43 从 15 秒收紧到 10 秒；第 22 轮第 5 件再收紧到 8 秒。）
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

    /// 残岛清理余量（第 22 轮第 5 件）：见文件头——5 秒进度推送间隔 + 3 秒余量。
    static let islandStaleSeconds: TimeInterval = 8

    /// startActivity 的代际（第 22 轮第 5 件）：快速切歌时两个
    /// startActivity 的 Task 会在 `await existing.end` 处交错——只清
    /// self.activity 那一份会漏掉另一个已请求的活动，留下一个没人管的
    /// 残岛。现在 Task 里先清系统全部活动，再查代际对不上就直接退，
    /// 交错的旧启动不会把刚被清掉的活动又起回来。
    private var startGeneration = 0

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
        // 第 22 轮第 3 件：起岛窗口里再加两步落盘——fittedState 之前记
        // "island start begin"，Activity.request 之前记 "island request begin"。
        // 死亡窗口（r21a：island start ok 之后、LX 返回之前约 2 秒）里，
        // 下次死时 lastDeathStep 能直接落在 payload 计算 / Activity.request
        // 这两步上，而不是只有一句 start ok。
        DiagLog.shared.recordPlaybackStep("island start begin")
        let fitted = Self.fittedState(state, title: title, artist: artist, log: true)
        lastTitle = title
        lastArtist = artist
        startGeneration += 1
        let gen = startGeneration
        Task { @MainActor in
            // 第 20 轮：后台 Activity.request 必抛 Target is not foreground
            //（r19 真机 5 次）。后台不请求、只暂存，回前台再起；同一首歌只记一次。
            guard UIApplication.shared.applicationState == .active else {
                self.deferStart(title: title, artist: artist, state: fitted)
                return
            }
            // 第 22 轮第 5 件：清系统里全部活动（不只 self.activity 那一份——
            // 快速切歌交错时另一个已请求的活动不在 self.activity 里，只清
            // 自己的那份会留孤儿残岛）；清完查代际，过期的启动直接退。
            for activity in Activity<LiziLyricsAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            self.activity = nil
            guard gen == self.startGeneration else { return }
            let attributes = LiziLyricsAttributes(title: title, artist: artist)
            let content = ActivityContent(state: fitted, staleDate: Date().addingTimeInterval(Self.islandStaleSeconds))
            DiagLog.shared.recordPlaybackStep("island request begin")
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

    /// 把 state 压进预算（第 22 轮第 3 件：先算预算再放封面，不再先做大再砍）。
    ///
    /// r20 的做法是先把 120px 封面原样编一次（真机每次先算到 40–80KB），
    /// 再逐档重压、最后丢封面——大封面的编解码与三次缩图全白跑。
    /// 现在反过来：先把不带封面的 state 编一次得 baseSize（词 + 进度，
    /// 只有一两百字节），剩余预算 = 3800 − baseSize；封面档位按剩余预算挑，
    /// 每档先按 base64 膨胀（data.count × 4/3 + 16 字节余量）估算，估算
    /// 进不去的档直接跳过（不编、不解），估算能进的才编一次确认；
    /// 没有任何档能进就直接不放封面。baseSize 自己就超预算时也直接不放。
    /// 起岛/更新都过这一道，所以两条组装路（原生协调器与网页桥）不用各自再算。
    /// log=true 只在起岛时记（更新每 5 秒一次，不记日志，免得刷诊断）；
    /// 但面包屑的 calc begin/end 只在 log=true 时记（起岛窗口才需要它，
    /// 更新路径只记 update begin/end，不再多占面包屑位置）。
    static func fittedState(_ state: LiziLyricsAttributes.ContentState, title: String, artist: String, log: Bool = false) -> LiziLyricsAttributes.ContentState {
        // 先算不带封面的 base：进度与播放态一定能推上去，封面只是添头。
        var noCover = state
        noCover.coverData = nil
        let baseSize = payloadSize(title: title, artist: artist, state: noCover)
        var calcOutcome = "dropped"
        let calcBaseForLog = baseSize
        if log {
            DiagLog.shared.recordPlaybackStep("island payload calc begin base=\(baseSize)")
        }
        defer {
            if log {
                DiagLog.shared.recordPlaybackStep("island payload calc end base=\(calcBaseForLog) cover=\(calcOutcome)")
            }
        }
        guard state.coverData != nil else {
            calcOutcome = "none"
            return state
        }
        guard baseSize <= islandPayloadBudget else {
            if log {
                DiagLog.shared.recordLog(category: "island",
                    message: "island payload base over budget bytes=\(baseSize) cover dropped (base over budget)",
                    fields: ["reason": "island-payload-base-over-budget", "lane": "island"])
            }
            calcOutcome = "dropped-base-over"
            return noCover
        }
        let remaining = islandPayloadBudget - baseSize
        if let data = state.coverData {
            // 原图（协调器已下采样到 120px）先试：能进预算就原样保留，
            // 不白白先压一档；进不去才往下走逐档重压。
            let estimatedOriginal = baseSize + data.count * 4 / 3 + 16
            if estimatedOriginal <= islandPayloadBudget {
                let size = payloadSize(title: title, artist: artist, state: state)
                if size <= islandPayloadBudget {
                    if log {
                        DiagLog.shared.recordLog(category: "island",
                            message: "island payload bytes=\(baseSize)->\(size) cover kept",
                            fields: ["reason": "island-payload-ok", "lane": "island"])
                    }
                    calcOutcome = "kept"
                    return state
                }
            }
        }
        // r24：档位 + 诊断。旧档止于 64px q0.5，但 08:30 诊断 remaining 3694
        // 时连它都进不去——本轮用真网易封面实测：64px q0.5 只要 1311B（估算
        // 1870B），预算根本不是问题；真正的原因是 thumbnail() 默认用主屏
        // scale 渲染（见该函数注释），@3x 手机上 "64px" 实际是 192px、约 6KB，
        // 三档全超。修法：thumbnail 里 scale=1（px 即像素）+ 补 48/32/24 三档
        // 兜底病态图；诊断里记 cover 字节数与最小档实测字节数，下次一眼分清
        // “解不出”还是“真超预算”。
        var smallestThumbBytes: Int?
        var smallestEstimated: Int?
        if let data = state.coverData, let image = UIImage(data: data) {
            for (px, quality) in [(96, CGFloat(0.6)), (80, CGFloat(0.5)), (64, CGFloat(0.5)),
                                  (48, CGFloat(0.5)), (32, CGFloat(0.4)), (24, CGFloat(0.35))] {
                guard let thumb = thumbnail(image, maxSide: CGFloat(px), quality: quality) else { continue }
                // 先估算再确认：base64 膨胀 + 16 字节余量，进不去直接跳过本档，
                // 不做整 state 的 JSON 编码；估算能进才编一次确认。
                let estimated = baseSize + thumb.count * 4 / 3 + 16
                smallestThumbBytes = thumb.count
                smallestEstimated = estimated
                guard estimated <= islandPayloadBudget else { continue }
                var candidate = state
                candidate.coverData = thumb
                let size = payloadSize(title: title, artist: artist, state: candidate)
                if size <= islandPayloadBudget {
                    if log {
                        DiagLog.shared.recordLog(category: "island",
                            message: "island payload bytes=\(baseSize)->\(size) cover down to \(px)px q\(quality)",
                            fields: ["reason": "island-payload-shrunk", "lane": "island"])
                    }
                    calcOutcome = "shrunk-\(px)px"
                    return candidate
                }
            }
        } else if let data = state.coverData {
            // coverData 在但解不出图（空数据 / 非图片体）：逐档循环一次都没跑，
            // 旧日志只写 cover dropped，分不清是解码失败还是预算不够。
            if log {
                DiagLog.shared.recordLog(category: "island",
                    message: "island payload cover undecodable bytes=\(data.count)",
                    fields: ["reason": "island-cover-undecodable", "lane": "island"])
            }
            calcOutcome = "dropped-undecodable"
            return noCover
        }
        let size = payloadSize(title: title, artist: artist, state: noCover)
        if log {
            DiagLog.shared.recordLog(category: "island",
                message: "island payload bytes=\(baseSize)->\(size) cover dropped (no tier fits, remaining=\(remaining) smallestThumb=\(smallestThumbBytes.map(String.init) ?? "-") smallestEstimated=\(smallestEstimated.map(String.init) ?? "-"))",
                fields: ["reason": "island-payload-cover-dropped", "lane": "island"])
        }
        calcOutcome = "dropped-no-tier-fits"
        return noCover
    }

    /// 等比缩到最长边 px，JPEG 重压（只在 fittedState 超预算时走，不常跑）。
    /// r24：format.scale = 1——px 在这里指像素。旧写法 `UIGraphicsImageRenderer(size:)`
    /// 用默认 format（主屏 scale），@3x 手机上 maxSide 64 实际渲成 192×192 像素，
    /// JPEG 约 6KB（真网易封面实测：192px q0.5 = 5990B，估算 8108B），96/80/64
    /// 三档全超 3800B 预算，岛封面必丢（08:30 诊断 bytes=106->106 的根因；
    /// 之前误以为是“预算不够”，实测 64px q0.5 只要 1311B，预算根本够）。
    /// 协调器的 downsample 同病（"120px" 实际 360px、约 25KB），那边一起改。
    private static func thumbnail(_ image: UIImage, maxSide: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = maxSide / max(size.width, size.height)
        let target = scale >= 1
            ? size
            : CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: quality)
    }

    /// Pushes a new state to the running activity. No-op when none is running.
    /// The coordinator throttles calls: only on track change / play-state
    /// change / liked change, or a progress refresh at most every 5 seconds
    ///（第 22 轮第 5 件：歌词行变不再推岛——ContentState 已无歌词字段）。
    func updateActivity(state: LiziLyricsAttributes.ContentState) {
        guard let activity else { return }
        // 第 22 轮第 3 件：更新也进面包屑（开始/结束各一步）。更新最多 5 秒
        // 一次，面包屑是滚动 30 条，死在更新里时最后一步就是这两句之一；
        // 起岛窗口（切歌后 2 秒内）最多只有一次更新，不会把取链的步挤掉。
        DiagLog.shared.recordPlaybackStep("island update begin")
        // 更新同样受 4KB 限制：超了整条更新被拒，先按预算压封面（不记日志）。
        let fitted = Self.fittedState(state, title: lastTitle, artist: lastArtist)
        Task { @MainActor in
            let content = ActivityContent(state: fitted, staleDate: Date().addingTimeInterval(Self.islandStaleSeconds))
            await activity.update(content)
            DiagLog.shared.recordPlaybackStep("island update end")
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
