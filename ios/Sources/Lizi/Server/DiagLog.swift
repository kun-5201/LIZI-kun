import Foundation
import MachO

/// 服务端诊断（给设置页 / 真机排障用，不含任何隐私内容）：
///  - lastSearch：最近一次网易搜索的上游端点、耗时、HTTP 状态、条数、错误；
///  - requests：最近 20 条本地请求（方法、路径、耗时、状态）。
/// 前端搜不到歌时，下一张截图只要带上 /api/diag/search 就能分清
/// 是本地服务挂了、上游挂了、还是解析挂了。
///
/// 第 14 轮（诊断是空的）：logs / requests / events / lastSearch 原来只放
/// 内存 —— 进程一死（闪退/被杀/升级重装不丢 UserDefaults 但丢内存）就全
/// 丢，重启后设置页只能看到「诊断日志（0 条）」。现在全部落盘到
/// UserDefaults（崩溃也还在），cap 不变（logs 100 / requests 20 / events 20）。
/// playbackBreadcrumb 更进一步：第 16 轮改成文件原子写（见 recordPlaybackStep），
/// UserDefaults 只留镜像。写失败只丢这次持久化，
/// 内存里的那份照常工作；读坏了就从空开始，不拦启动。
final class DiagLog {
    static let shared = DiagLog()
    private let lock = NSLock()
    private(set) var lastSearch: [String: Any] = [:]
    private var requests: [[String: Any]] = []
    private var events: [String] = []
    /// 前端上报的诊断日志（第 6 轮）：audio（播放失败 detail）/ cover（封面失败
    /// host+原因+栏位）/ probe（探活结果）。最近 100 条，设置页可查看/复制。
    private var logs: [[String: Any]] = []
    /// 服务端收到的诊断 POST 总数（第 15 轮第 6 件）：每次 /api/diag/log
    /// 成功入库 +1，和 JS 侧 window.__liziDiagCounts().sent 对账；
    /// sent 涨、received 不涨就是 POST 在路上丢了。只记内存数，不落盘。
    private(set) var diagLogReceived = 0

    private enum PersistKey {
        static let logs = "lizi.diagLogs"
        static let requests = "lizi.diagRequests"
        static let events = "lizi.diagEvents"
        static let lastSearch = "lizi.diagLastSearch"
    }

    private init() {
        loadPersisted()
    }

    private func loadPersisted() {
        loadBreadcrumb()
        loadActivity()
        loadPlayStartByGen()
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: PersistKey.logs),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            logs = arr
        }
        if let data = ud.data(forKey: PersistKey.requests),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            requests = arr
        }
        if let data = ud.data(forKey: PersistKey.events),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            events = arr
        }
        if let data = ud.data(forKey: PersistKey.lastSearch),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lastSearch = dict
        }
    }

    /// 只存 JSON 能表示的值（String/数字/Bool/数组/字典），其它类型直接丢掉，
    /// 别让一次奇怪的字段值把整份持久化写坏。
    private static func jsonSafe(_ v: Any) -> Any? {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n
        case let b as Bool: return b
        case let a as [Any]: return a.compactMap { jsonSafe($0) }
        case let d as [String: Any]:
            var out: [String: Any] = [:]
            for (k, val) in d { if let safe = jsonSafe(val) { out[k] = safe } }
            return out
        default: return nil
        }
    }

    private func persist() {
        let ud = UserDefaults.standard
        if let data = try? JSONSerialization.data(withJSONObject: logs) {
            ud.set(data, forKey: PersistKey.logs)
        }
        if let data = try? JSONSerialization.data(withJSONObject: requests) {
            ud.set(data, forKey: PersistKey.requests)
        }
        if let data = try? JSONSerialization.data(withJSONObject: events) {
            ud.set(data, forKey: PersistKey.events)
        }
        if let data = try? JSONSerialization.data(withJSONObject: Self.jsonSafe(lastSearch) ?? [:]) {
            ud.set(data, forKey: PersistKey.lastSearch)
        }
    }

    /// 服务端收到一条诊断 POST 就 +1（第 15 轮第 6 件对账用），
    /// 在 recordLog 之前调（400 的不算，见 Router）。
    func noteDiagLogReceived() {
        // r63：持锁计时（见 noteSlowDiagLock 注释）。
        let lockStart = CFAbsoluteTimeGetCurrent()
        lock.lock()
        diagLogReceived += 1
        lock.unlock()
        noteSlowDiagLock(method: "noteDiagLogReceived", start: lockStart)
    }

    func recordLog(category: String, message: String, fields: [String: Any] = [:]) {
        // r63：持锁计时（见 noteSlowDiagLock 注释）。
        let lockStart = CFAbsoluteTimeGetCurrent()
        lock.lock()
        var e: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "category": category,
            "message": message,
        ]
        for (k, v) in fields { if let safe = Self.jsonSafe(v) { e[k] = safe } }
        logs.append(e)
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
        persist()
        lock.unlock()
        noteSlowDiagLock(method: "recordLog", start: lockStart)
    }

    func recordSearch(_ d: [String: Any]) {
        // r63：持锁计时（见 noteSlowDiagLock 注释）。
        let lockStart = CFAbsoluteTimeGetCurrent()
        lock.lock()
        lastSearch = d
        persist()
        lock.unlock()
        noteSlowDiagLock(method: "recordSearch", start: lockStart)
    }

    func recordRequest(method: String, path: String, ms: Int, status: Int) {
        // r63：持锁计时（见 noteSlowDiagLock 注释）。
        let lockStart = CFAbsoluteTimeGetCurrent()
        lock.lock()
        requests.append(["method": method, "path": path, "ms": ms, "status": status])
        if requests.count > 20 { requests.removeFirst(requests.count - 20) }
        persist()
        lock.unlock()
        noteSlowDiagLock(method: "recordRequest", start: lockStart)
    }

    func recordEvent(_ e: String) {
        // r63：持锁计时（见 noteSlowDiagLock 注释）。
        let lockStart = CFAbsoluteTimeGetCurrent()
        lock.lock()
        events.append(e)
        if events.count > 20 { events.removeFirst(events.count - 20) }
        persist()
        lock.unlock()
        noteSlowDiagLock(method: "recordEvent", start: lockStart)
    }

    /// 播放链面包屑（第 10 轮）：进程被杀后仍在，下次启动可从 /api/diag/search 看到崩前最后一步。
    /// 只记步骤与结果（OK/EMPTY/主机名），不记完整直链（LX 直链可能含 key）。
    ///
    /// 第 16 轮第 3 件（落盘核实结果）：原来只写 UserDefaults.set——
    /// set 只改内存 + 通知 cfprefsd 异步刷盘，App 在刷盘窗口内闪退/
    /// 被杀时最后一步可能没上盘，重启后诊断页看到的是旧的最后一步。
    /// 现在双写：内存数组 + Application Support 下的 JSON 文件（.atomic
    /// 原子写，同步落盘），UserDefaults 只留作兼容镜像；读端以文件为准。
    /// 下次用户复现闪退重开 App，诊断页直接看到崩溃前最后一步。
    ///
    /// 第 21 轮第 1 件（上次死亡上报）：光有面包屑还不够——下次启动要直接
    /// 回答「上次死在哪一步」。markLaunched()/markCleanExit() 记一个干净退出
    /// 旗标：启动时先读上次的旗标，不干净就把当时的面包屑最后一步 + 内存占用
    /// 快照成 lastDeathStep/lastDeathAt/lastDeathMemoryMB，进 /api/diag/search
    /// 的 json()。注意：iOS 很少走 applicationWillTerminate（挂起后被 SIGKILL
    /// 是常态），所以 previousRunClean==false 单独看 ≠ 闪退实锤，必须和
    /// lastDeathStep + 用户当时正在操作（而非后台挂起）一起读；它回答的是
    /// 「进程没走正常退出、死在某一步」，不是「崩溃堆栈」。
    private var breadcrumbSteps: [String] = []
    private static let breadcrumbFileName = "lizi.playbackBreadcrumb.json"
    private static func breadcrumbFileURL() -> URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(breadcrumbFileName)
    }
    private func loadBreadcrumb() {
        if let url = Self.breadcrumbFileURL(),
           let data = try? Data(contentsOf: url),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            breadcrumbSteps = Array(arr.suffix(30))
            return
        }
        breadcrumbSteps = UserDefaults.standard.stringArray(forKey: "lizi.playbackBreadcrumb") ?? []
    }

    /// r57-④：UserDefaults 镜像写节流——每次 record 都写镜像会立刻触发
    /// UserDefaults.didChangeNotification；r55 的 NowPlayingCoordinator
    /// 订阅它且不节流：写盘 → writeNowPlaying →（守门恒真时）再起 fetch
    /// → 再记面包屑 → 再写盘，形成自反馈（diag-20261123-2221：同首歌
    /// 11 次取封面，死前一秒）。文件才是诊断真相（同步原子写，读端以
    /// 文件为准），镜像只是文件坏了的兜底读——镜像最多 1 秒写一次，
    /// 1 秒内的记录只在文件里，兜底读最多丢 1 秒；didChange 的燃料降
    /// 到 ≤1 次/秒。只用于已有文件兜底的两处（面包屑/活动日志）；
    /// persist()（日志/请求/事件，无文件备份）与 playStart 表、干净退
    /// 出旗标不动——它们不是环路的燃料，丢 1 秒反而丢诊断。
    /// 调用方已持 lock，只读/写本字段，不另加锁。
    private var lastMirrorWriteAt: Date = .distantPast
    private static let mirrorMinInterval: TimeInterval = 1.0
    private func mirrorThrottled(_ write: () -> Void) {
        guard Date().timeIntervalSince(lastMirrorWriteAt) >= Self.mirrorMinInterval else { return }
        lastMirrorWriteAt = Date()
        write()
    }

    private func persistBreadcrumb() {
        if let url = Self.breadcrumbFileURL(),
           let data = try? JSONSerialization.data(withJSONObject: breadcrumbSteps) {
            try? data.write(to: url, options: [.atomic])
        }
        // 兼容镜像：旧版只读 UserDefaults，文件坏了还能从这里兜底。
        // r57-④：镜像写节流（见 mirrorThrottled 注释）——文件已同步写完，
        // 镜像只是兜底读，晚 1 秒无妨。
        mirrorThrottled {
            UserDefaults.standard.set(breadcrumbSteps, forKey: "lizi.playbackBreadcrumb")
        }
    }

    func recordPlaybackStep(_ step: String) {
        // r63：持锁计时（见 noteSlowDiagLock 注释）。
        let lockStart = CFAbsoluteTimeGetCurrent()
        lock.lock()
        // r56：时间戳改毫秒（与 recordLog 的 ts 同款；秒级分辨不出 16 次
        // 取封面风暴里同秒的先后）。读侧按空格切前缀：public/app.js 已改
        // 成按前缀长度认秒/毫秒，老版本写的文件照样能读。
        breadcrumbSteps.append("\(Int(Date().timeIntervalSince1970 * 1000)) \(step)")
        if breadcrumbSteps.count > 30 { breadcrumbSteps.removeFirst(breadcrumbSteps.count - 30) }
        persistBreadcrumb()
        lock.unlock()
        noteSlowDiagLock(method: "recordPlaybackStep", start: lockStart)
    }

    // MARK: - r55 活动日志（UI/导航活动）

    /// 崩在播放之前时面包屑是空的（r55 诊断：lastDeathStep=""）——活动日志
    /// 是唯一的死亡线索。只记步骤/标题/平台，不记 token/直链/密码。
    /// 与面包屑同款落盘：Application Support 下 lizi.activityLog.json
    /// 原子写 + UserDefaults 镜像，cap 30 条，`ts 步骤` 同格式。
    private var activityLog: [String] = []
    private static let activityFileName = "lizi.activityLog.json"
    private static func activityFileURL() -> URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(activityFileName)
    }
    private func loadActivity() {
        if let url = Self.activityFileURL(),
           let data = try? Data(contentsOf: url),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            activityLog = Array(arr.suffix(30))
            return
        }
        activityLog = UserDefaults.standard.stringArray(forKey: "lizi.activityLog") ?? []
    }
    private func persistActivity() {
        if let url = Self.activityFileURL(),
           let data = try? JSONSerialization.data(withJSONObject: activityLog) {
            try? data.write(to: url, options: [.atomic])
        }
        // r57-④：同 persistBreadcrumb，镜像写节流（见 mirrorThrottled）。
        mirrorThrottled {
            UserDefaults.standard.set(activityLog, forKey: "lizi.activityLog")
        }
    }

    func recordActivity(_ step: String) {
        // r63：持锁计时（见 noteSlowDiagLock 注释）。
        let lockStart = CFAbsoluteTimeGetCurrent()
        lock.lock()
        // r56：时间戳改毫秒（同 recordPlaybackStep；秒级看不出同秒内
        // closeOpened 与重起的先后）。读侧只整条展示，不解析前缀。
        activityLog.append("\(Int(Date().timeIntervalSince1970 * 1000)) \(step)")
        if activityLog.count > 30 { activityLog.removeFirst(activityLog.count - 30) }
        persistActivity()
        lock.unlock()
        noteSlowDiagLock(method: "recordActivity", start: lockStart)
    }

    // MARK: - r49 各代 play start 独立索引

    /// 各代 play start 时间戳（gen → 秒）：面包屑只有最近 30 条，快速
    /// 连点 4–5 次就能把旧代 play start 顶出窗口，看门狗在窗口里
    /// contains 会误报 MISSING。play start 在哪一代发生就记在哪一代，
    /// 看门狗只查这张表，不再扫 30 条滑动窗口。recordPlaybackStep 的
    /// 同步落盘写法一字不动；这张表只作看门狗判断 + 诊断展示，走
    /// UserDefaults 镜像（只留最近 50 代，防无限涨）。
    private var playStartByGen: [Int: Double] = [:]
    private static let playStartByGenKey = "lizi.playStartByGen"

    private func loadPlayStartByGen() {
        let ud = UserDefaults.standard
        guard let data = ud.data(forKey: Self.playStartByGenKey),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return }
        playStartByGen = Dictionary(uniqueKeysWithValues: raw.compactMap { (k, v) in
            Int(k).map { ($0, v) }
        })
    }

    private func persistPlayStartByGen() {
        let raw = Dictionary(uniqueKeysWithValues: playStartByGen.map { (String($0.key), $0.value) })
        if let data = try? JSONSerialization.data(withJSONObject: raw) {
            UserDefaults.standard.set(data, forKey: Self.playStartByGenKey)
        }
    }

    /// playCurrent 入口记 "play start" 时同步记这一代（与面包屑同行，
    /// 但不进 30 条窗口）。看门狗只认这张表。
    func recordPlayStart(gen: Int) {
        // r63：持锁计时（见 noteSlowDiagLock 注释）。
        let lockStart = CFAbsoluteTimeGetCurrent()
        lock.lock()
        playStartByGen[gen] = Date().timeIntervalSince1970
        if playStartByGen.count > 50 {
            for g in playStartByGen.keys.sorted().dropLast(50) { playStartByGen.removeValue(forKey: g) }
        }
        persistPlayStartByGen()
        lock.unlock()
        noteSlowDiagLock(method: "recordPlayStart", start: lockStart)
    }

    /// 这一代记过 play start 吗（看门狗用）。
    func hasPlayStart(gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return playStartByGen[gen] != nil
    }

    // MARK: - r63 慢锁事件 + 触摸面包屑（与 DiagLog.lock 解耦）

    /// 持锁 >50ms 的事件（DiagLog 自身 9 个方法 + DiskCache 都记这里）。
    /// 只用 slowLock 守，绝不进 DiagLog.lock（NSLock 不可重入）；json() 读它
    /// 时同样只拿 slowLock——DiagLog.lock → slowLock 单向嵌套，
    /// recordSlowLock 从不反向拿 DiagLog.lock，不成环。
    private let slowLock = NSLock()
    private var slowLockEvents: [String] = []

    /// 慢锁事件入口（DiskCache 静态方法也调这里）：调用方必须在相关锁
    /// 解锁之后再调（两把锁绝不嵌套）。event 全文由调用方拼好，
    /// 格式 `"<ms>ms <来源>.<方法名>"`，如 `"63ms DiagLog.recordLog"`。
    func recordSlowLock(_ event: String) {
        slowLock.lock(); defer { slowLock.unlock() }
        slowLockEvents.append(event)
        if slowLockEvents.count > 30 { slowLockEvents.removeFirst(slowLockEvents.count - 30) }
    }

    private func slowLockEventsSnapshot() -> [String] {
        slowLock.lock(); defer { slowLock.unlock() }
        return slowLockEvents
    }

    /// 本文件 9 个持锁方法的计时出口：lock 之前记 start，unlock 之后调这里，
    /// >50ms 才记一笔。只读 slowLock，不进 DiagLog.lock。
    private func noteSlowDiagLock(method: String, start: CFAbsoluteTime) {
        let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        guard ms > 50 else { return }
        recordSlowLock("\(ms)ms DiagLog.\(method)")
    }

    /// 触摸面包屑（r63，第 5 件）：touchesBegan / handleTap 记在比点按链更早
    /// 更外层的位置；与 DiagLog.lock 解耦——独立文件
    /// Application Support/lizi.touchBreadcrumb.json + 独立 touchLock，
    /// 照抄心跳文件（heartbeatFileURL / writeHeartbeatSample）的写法。
    /// 主线程冻住时 DiagLog.lock 可能正被别的线程持着，触摸埋点走这里才落得下盘。
    private var touchBreadcrumbSteps: [String] = []
    private let touchLock = NSLock()
    private static let touchBreadcrumbFileName = "lizi.touchBreadcrumb.json"
    private static func touchBreadcrumbFileURL() -> URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(touchBreadcrumbFileName)
    }

    func recordTouchStep(_ step: String) {
        touchLock.lock(); defer { touchLock.unlock() }
        touchBreadcrumbSteps.append("\(Int(Date().timeIntervalSince1970 * 1000)) \(step)")
        if touchBreadcrumbSteps.count > 30 { touchBreadcrumbSteps.removeFirst(touchBreadcrumbSteps.count - 30) }
        if let url = Self.touchBreadcrumbFileURL(),
           let data = try? JSONSerialization.data(withJSONObject: touchBreadcrumbSteps) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// json() / markLaunched 读触摸面包屑：只拿 touchLock 读内存数组，
    /// 绝不在持 DiagLog.lock 时读文件。
    private func touchBreadcrumbSnapshot() -> [String] {
        touchLock.lock(); defer { touchLock.unlock() }
        return touchBreadcrumbSteps
    }

    // MARK: - 上次死亡上报（第 21 轮第 1 件）

    /// 上次启动是否干净退出（false = 上次没走 applicationWillTerminate；
    /// 见文件头注释：单独看不是闪退实锤，要和 lastDeathStep 一起读）。
    private(set) var previousRunClean: Bool = true
    /// 上次不干净退出时面包屑的最后一步（干净退出时保留上一次的快照）。
    /// r55：面包屑空时回落到活动日志最后一步（见 markLaunched）。
    private(set) var lastDeathStep: String = ""
    /// 上次不干净退出时活动日志的最后一步（全文；面包屑空时它是
    /// lastDeathStep 的回落来源）。
    private(set) var lastDeathActivity: String = ""
    /// 上次不干净退出的发现时间（启动时刻，秒）。
    private(set) var lastDeathAt: Double = 0
    /// 发现上次不干净退出时本进程的常驻内存（MB；-1 = 读不到，仅作参考，
    /// 判断是不是内存被杀的旁证，不是定论）。
    /// r55：注意——这是**重起时新进程**的内存，不是死亡时内存（r55 诊断
    /// 的 6MB 是刚启动的常驻内存，说明不了死亡时的内存压力）。
    private(set) var lastDeathMemoryMB: Int = -1
    /// 重起时本进程的 bundle 版本（shortVersion + build；与死的那轮同版，
    /// 除非中间升级过——r55 诊断里没有版本号字段，无法确认用户装的是哪版，
    /// 从 r55 起死亡快照里补版本）。
    private(set) var lastDeathVersion: String = ""
    /// r63：上次不干净退出时面包屑 + 触摸面包屑的全量快照
    ///（markLaunched 的不干净分支里 `breadcrumbSteps + touchBreadcrumbSteps`，
    /// 两份各自 cap 30，不再截；干净退出分支从 UD 读回）。
    private(set) var lastDeathBreadcrumb: [String] = []

    // MARK: - r58 心跳鉴别器（死因三分：同步 trap / 看门狗冻主线程 / jetsam）
    //
    // 背景：r55 与 r57 两份诊断都只有「最后一步是 closeOpened / 封面 ready」
    // 这一级线索，.ips 拿不到，三种死法分不开——r57 的修没拦住，不能再靠猜。
    // 本心跳是唯一的鉴别手段：
    // - 后台 detached 任务每 1 秒写一个样本 [tsMs, 常驻内存 MB, 主线程 tickMs]
    //   到 Application Support/lizi.heartbeat.json（最多 30 个样本，约 30 秒窗），
    //   原子写，不走 DiagLog 的 NSLock、不碰任何被怀疑的路径；
    // - 主线程 tick：每秒向主队列 fire-and-forget 发一个小 block，跑到就记
    //   mainTickAt（不 await——主线程卡住时 await 会把心跳任务也挂住，
    //   文件就停了，分辨力全丢）；
    // - 下次启动 markLaunched 读这份文件快照：
    //   lastMainTickAgeMs 大（>5000，主线程死前已卡住数秒）+ 内存平 → 看门狗/冻主线程；
    //   lastMainTickAgeMs 小（<2000，主线程死前还活着）+ 内存平 → 同步 trap；
    //   maxHeartbeatMemoryMB 大或一路爬升 → jetsam（内存被杀）。
    // 代价：每秒 1 次主队列投递 + 1 次约 2KB 原子写，可忽略。
    // 注意：心跳文件只在不干净退出时才有诊断意义；干净退出/首次启动没有
    // 上次心跳时四项全回 -1。
    /// 上次心跳样本距发现死亡的时间（ms；<2000 说明死前心跳还在走）。
    private(set) var lastHeartbeatAgeMs: Int = -1
    /// 上次心跳样本里的常驻内存（MB）。
    private(set) var lastHeartbeatMemoryMB: Int = -1
    /// 心跳窗口（死前约 30 秒）里的最大常驻内存（MB；一路爬升 → jetsam 嫌疑）。
    private(set) var maxHeartbeatMemoryMB: Int = -1
    /// 主线程最后一次 tick 距发现死亡的时间（ms；>5000 说明死前主线程已卡住数秒）。
    private(set) var lastMainTickAgeMs: Int = -1

    private static let heartbeatFileName = "lizi.heartbeat.json"
    private static let heartbeatMaxSamples = 30
    private let heartbeatLock = NSLock()
    private var heartbeatStarted = false
    private var heartbeatMainTickMs: Int = 0

    private static func heartbeatFileURL() -> URL? {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(heartbeatFileName)
    }

    /// 读上次心跳文件，快照四项（markLaunched 的不干净分支调；必须在
    /// startHeartbeat 覆盖文件之前读）。文件坏/没有回全 -1。
    private func snapshotHeartbeat() {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        guard let url = Self.heartbeatFileURL(),
              let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[Int]],
              let last = arr.last, last.count == 3 else {
            lastHeartbeatAgeMs = -1; lastHeartbeatMemoryMB = -1
            maxHeartbeatMemoryMB = -1; lastMainTickAgeMs = -1
            return
        }
        lastHeartbeatAgeMs = nowMs - last[0]
        lastHeartbeatMemoryMB = last[1]
        maxHeartbeatMemoryMB = arr.map { $0[1] }.max() ?? last[1]
        lastMainTickAgeMs = nowMs - last[2]
    }

    /// 启动心跳（markLaunched 末尾调一次；重复调无害）。进程生命周期内一直跑。
    func startHeartbeat() {
        heartbeatLock.lock()
        guard !heartbeatStarted else { heartbeatLock.unlock(); return }
        heartbeatStarted = true
        heartbeatLock.unlock()
        heartbeatMainTickMs = Int(Date().timeIntervalSince1970 * 1000)
        Task.detached { [weak self] in
            while true {
                // 主线程 tick：fire-and-forget，绝不 await。
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.heartbeatLock.lock()
                    self.heartbeatMainTickMs = Int(Date().timeIntervalSince1970 * 1000)
                    self.heartbeatLock.unlock()
                }
                self?.writeHeartbeatSample()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func writeHeartbeatSample() {
        heartbeatLock.lock()
        let tick = heartbeatMainTickMs
        heartbeatLock.unlock()
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let mem = Self.memoryFootprintMB()
        guard let url = Self.heartbeatFileURL() else { return }
        var samples: [[Int]] = []
        if let data = try? Data(contentsOf: url),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[Int]] {
            samples = arr
        }
        samples.append([nowMs, mem, tick])
        if samples.count > Self.heartbeatMaxSamples { samples.removeFirst(samples.count - Self.heartbeatMaxSamples) }
        if let data = try? JSONSerialization.data(withJSONObject: samples) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private enum RunKey {
        static let hadRun = "lizi.runHadRun"
        static let cleanExit = "lizi.runCleanExit"
        static let lastDeathStep = "lizi.lastDeathStep"
        static let lastDeathActivity = "lizi.lastDeathActivity"
        static let lastDeathAt = "lizi.lastDeathAt"
        static let lastDeathMemoryMB = "lizi.lastDeathMemoryMB"
        static let lastDeathVersion = "lizi.lastDeathVersion"
        static let lastDeathBreadcrumb = "lizi.lastDeathBreadcrumb"
        static let lastHeartbeatAgeMs = "lizi.lastHeartbeatAgeMs"
        static let lastHeartbeatMemoryMB = "lizi.lastHeartbeatMemoryMB"
        static let maxHeartbeatMemoryMB = "lizi.maxHeartbeatMemoryMB"
        static let lastMainTickAgeMs = "lizi.lastMainTickAgeMs"
    }

    /// 本进程 bundle 版本（shortVersion + build，如 "1.0(12)"；读不到回 ""）。
    static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        if short.isEmpty && build.isEmpty { return "" }
        return build.isEmpty ? short : "\(short)(\(build))"
    }

    /// App 启动第一时间调（LiziNativeApp.init 首行）：读上次的干净退出旗标，
    /// 不干净就把面包屑最后一步快照下来，再把旗标翻回 false（活着就先算
    /// “不干净”，只有真正走完 applicationWillTerminate 才算干净）。
    func markLaunched() {
        lock.lock(); defer { lock.unlock() }
        let ud = UserDefaults.standard
        let hadRun = ud.bool(forKey: RunKey.hadRun)
        let wasClean = ud.bool(forKey: RunKey.cleanExit)
        if hadRun && !wasClean {
            previousRunClean = false
            // r55：死亡快照回落——面包屑最后一步 ?? 活动最后一步 ?? ""。
            // r55 诊断的教训：崩在播放之前时面包屑是空的，lastDeathStep=""
            // 什么都说明不了；活动日志（打开歌单/搜索/切页）是唯一的线索。
            lastDeathActivity = activityLog.last ?? ""
            lastDeathStep = breadcrumbSteps.last ?? lastDeathActivity
            lastDeathAt = Date().timeIntervalSince1970
            lastDeathMemoryMB = Self.memoryFootprintMB()
            lastDeathVersion = Self.appVersion()
            // r63：死亡快照全量——面包屑 + 触摸面包屑（两份各自 cap 30，不再截）。
            lastDeathBreadcrumb = breadcrumbSteps + touchBreadcrumbSnapshot()
            // r58 心跳：必须在 startHeartbeat 覆盖文件之前快照。
            snapshotHeartbeat()
            ud.set(lastDeathStep, forKey: RunKey.lastDeathStep)
            ud.set(lastDeathActivity, forKey: RunKey.lastDeathActivity)
            ud.set(lastDeathAt, forKey: RunKey.lastDeathAt)
            ud.set(lastDeathMemoryMB, forKey: RunKey.lastDeathMemoryMB)
            ud.set(lastDeathVersion, forKey: RunKey.lastDeathVersion)
            if let data = try? JSONSerialization.data(withJSONObject: lastDeathBreadcrumb) {
                ud.set(data, forKey: RunKey.lastDeathBreadcrumb)
            }
            ud.set(lastHeartbeatAgeMs, forKey: RunKey.lastHeartbeatAgeMs)
            ud.set(lastHeartbeatMemoryMB, forKey: RunKey.lastHeartbeatMemoryMB)
            ud.set(maxHeartbeatMemoryMB, forKey: RunKey.maxHeartbeatMemoryMB)
            ud.set(lastMainTickAgeMs, forKey: RunKey.lastMainTickAgeMs)
        } else {
            previousRunClean = true
            lastDeathStep = ud.string(forKey: RunKey.lastDeathStep) ?? ""
            lastDeathActivity = ud.string(forKey: RunKey.lastDeathActivity) ?? ""
            lastDeathAt = ud.double(forKey: RunKey.lastDeathAt)
            lastDeathMemoryMB = ud.integer(forKey: RunKey.lastDeathMemoryMB)
            lastDeathVersion = ud.string(forKey: RunKey.lastDeathVersion) ?? ""
            // r63：干净退出分支从 UD 读回上次死亡面包屑全量快照。
            if let data = ud.data(forKey: RunKey.lastDeathBreadcrumb),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                lastDeathBreadcrumb = arr
            }
            lastHeartbeatAgeMs = ud.integer(forKey: RunKey.lastHeartbeatAgeMs)
            lastHeartbeatMemoryMB = ud.integer(forKey: RunKey.lastHeartbeatMemoryMB)
            maxHeartbeatMemoryMB = ud.integer(forKey: RunKey.maxHeartbeatMemoryMB)
            lastMainTickAgeMs = ud.integer(forKey: RunKey.lastMainTickAgeMs)
        }
        ud.set(true, forKey: RunKey.hadRun)
        ud.set(false, forKey: RunKey.cleanExit)
        startHeartbeat()
    }

    /// 正常退出时调（applicationWillTerminate）：下次启动不再报死亡。
    func markCleanExit() {
        UserDefaults.standard.set(true, forKey: RunKey.cleanExit)
    }

    /// 本进程常驻内存（MB；task_info 读数，失败回 -1，不抛错）。
    static func memoryFootprintMB() -> Int {
        var info = task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.resident_size) / 1024 / 1024
    }

    // MARK: - r31 日志清空（设置 → 关于 → 诊断日志 → 展开后底部的「清空日志」）

    /// 把当前诊断日志全部清掉——内存里的 logs（100 条）/ requests（20 条）/
    /// events（20 条）/ lastSearch / 播放面包屑 / 活动日志（r55）/ 上次死亡快照 /
    /// 诊断 POST 计数 + 落盘的 UserDefaults 四个键（lizi.diagLogs / lizi.diagRequests /
    /// lizi.diagEvents / lizi.diagLastSearch）+ 面包屑 JSON 文件
    /// （Application Support/lizi.playbackBreadcrumb.json）+ 活动日志 JSON 文件
    /// （Application Support/lizi.activityLog.json）+ 面包屑与死亡
    /// 快照的 UserDefaults 镜像。清完不留一条「已清空」记录（留了就不是
    /// 空的）；调用方（设置页）用 Notice 告诉用户「日志已清空」。
    /// r63：上次死亡面包屑全量快照（lastDeathBreadcrumb 内存 + UD 键）也清。
    /// 运行期旗标 hadRun/cleanExit 不动（markLaunched 的判断还靠它们），
    /// 只是内存里的 previousRunClean 已随快照一起翻回 true。
    func clearAllLogs() {
        lock.lock(); defer { lock.unlock() }
        logs = []
        requests = []
        events = []
        lastSearch = [:]
        breadcrumbSteps = []
        activityLog = []
        playStartByGen = [:]
        diagLogReceived = 0
        previousRunClean = true
        lastDeathStep = ""
        lastDeathActivity = ""
        lastDeathAt = 0
        lastDeathMemoryMB = -1
        lastDeathVersion = ""
        // r63：上次死亡面包屑全量快照（内存 + UD 键）一起清。
        lastDeathBreadcrumb = []
        // r58 心跳：快照四项归 -1（心跳任务本身不停，下次启动重写文件）。
        lastHeartbeatAgeMs = -1
        lastHeartbeatMemoryMB = -1
        maxHeartbeatMemoryMB = -1
        lastMainTickAgeMs = -1
        let ud = UserDefaults.standard
        ud.removeObject(forKey: PersistKey.logs)
        ud.removeObject(forKey: PersistKey.requests)
        ud.removeObject(forKey: PersistKey.events)
        ud.removeObject(forKey: PersistKey.lastSearch)
        ud.removeObject(forKey: "lizi.playbackBreadcrumb")
        ud.removeObject(forKey: "lizi.activityLog")
        ud.removeObject(forKey: Self.playStartByGenKey)
        ud.removeObject(forKey: RunKey.lastDeathStep)
        ud.removeObject(forKey: RunKey.lastDeathActivity)
        ud.removeObject(forKey: RunKey.lastDeathAt)
        ud.removeObject(forKey: RunKey.lastDeathMemoryMB)
        ud.removeObject(forKey: RunKey.lastDeathVersion)
        ud.removeObject(forKey: RunKey.lastDeathBreadcrumb)
        if let url = Self.breadcrumbFileURL() {
            try? FileManager.default.removeItem(at: url)
        }
        if let url = Self.activityFileURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func json() -> [String: Any] {
        // r63：持锁计时（见 noteSlowDiagLock 注释）。
        let lockStart = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let out: [String: Any] = ["lastSearch": lastSearch, "requests": requests, "events": events, "logs": logs,
                "playbackBreadcrumb": breadcrumbSteps,
                // r49：各代 play start 时间戳（gen → 秒，看门狗的判断表）。
                "playStartByGen": Dictionary(uniqueKeysWithValues: playStartByGen.map { (String($0.key), $0.value) }),
                // 第 15 轮第 4 件：挂起的 LX 取链任务数（>0 且一直不回零
                // 就是有脚本 Promise 不 settle、任务泄漏了）。
                "lxPendingCalls": LXScriptInstance.pendingMusicUrlCalls,
                // 第 15 轮第 6 件：服务端收到的诊断 POST 数（和 JS 侧
                // window.__liziDiagCounts().sent 对账）。
                "diagLogReceived": diagLogReceived,
                // 第 21 轮第 1 件：上次死亡上报（见 markLaunched 注释）。
                "previousRunClean": previousRunClean,
                "lastDeathStep": lastDeathStep,
                "lastDeathAt": lastDeathAt,
                "lastDeathMemoryMB": lastDeathMemoryMB,
                // r55：死亡快照回落 + 版本（见 markLaunched 注释）。
                "lastDeathActivity": lastDeathActivity,
                "lastDeathVersion": lastDeathVersion,
                // r58 心跳鉴别器：死前主线程 tick 与内存（见文件内注释）。
                "lastHeartbeatAgeMs": lastHeartbeatAgeMs,
                "lastHeartbeatMemoryMB": lastHeartbeatMemoryMB,
                "maxHeartbeatMemoryMB": maxHeartbeatMemoryMB,
                "lastMainTickAgeMs": lastMainTickAgeMs,
                "activityLog": activityLog,
                // r63：触摸面包屑（touchLock 下读内存数组，不读文件）+
                // 慢锁事件（slowLock 下读）+ 上次死亡面包屑全量快照。
                "touchBreadcrumb": touchBreadcrumbSnapshot(),
                "slowLockEvents": slowLockEventsSnapshot(),
                "lastDeathBreadcrumb": lastDeathBreadcrumb,
                "appVersion": Self.appVersion()]
        lock.unlock()
        noteSlowDiagLock(method: "json", start: lockStart)
        return out
    }
}
