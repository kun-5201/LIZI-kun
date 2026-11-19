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
        lock.lock(); defer { lock.unlock() }
        diagLogReceived += 1
    }

    func recordLog(category: String, message: String, fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        var e: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "category": category,
            "message": message,
        ]
        for (k, v) in fields { if let safe = Self.jsonSafe(v) { e[k] = safe } }
        logs.append(e)
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
        persist()
    }

    func recordSearch(_ d: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        lastSearch = d
        persist()
    }

    func recordRequest(method: String, path: String, ms: Int, status: Int) {
        lock.lock(); defer { lock.unlock() }
        requests.append(["method": method, "path": path, "ms": ms, "status": status])
        if requests.count > 20 { requests.removeFirst(requests.count - 20) }
        persist()
    }

    func recordEvent(_ e: String) {
        lock.lock(); defer { lock.unlock() }
        events.append(e)
        if events.count > 20 { events.removeFirst(events.count - 20) }
        persist()
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
    private func persistBreadcrumb() {
        if let url = Self.breadcrumbFileURL(),
           let data = try? JSONSerialization.data(withJSONObject: breadcrumbSteps) {
            try? data.write(to: url, options: [.atomic])
        }
        // 兼容镜像：旧版只读 UserDefaults，文件坏了还能从这里兜底。
        UserDefaults.standard.set(breadcrumbSteps, forKey: "lizi.playbackBreadcrumb")
    }

    func recordPlaybackStep(_ step: String) {
        lock.lock(); defer { lock.unlock() }
        breadcrumbSteps.append("\(Int(Date().timeIntervalSince1970)) \(step)")
        if breadcrumbSteps.count > 30 { breadcrumbSteps.removeFirst(breadcrumbSteps.count - 30) }
        persistBreadcrumb()
    }

    // MARK: - 上次死亡上报（第 21 轮第 1 件）

    /// 上次启动是否干净退出（false = 上次没走 applicationWillTerminate；
    /// 见文件头注释：单独看不是闪退实锤，要和 lastDeathStep 一起读）。
    private(set) var previousRunClean: Bool = true
    /// 上次不干净退出时面包屑的最后一步（干净退出时保留上一次的快照）。
    private(set) var lastDeathStep: String = ""
    /// 上次不干净退出的发现时间（启动时刻，秒）。
    private(set) var lastDeathAt: Double = 0
    /// 发现上次不干净退出时本进程的常驻内存（MB；-1 = 读不到，仅作参考，
    /// 判断是不是内存被杀的旁证，不是定论）。
    private(set) var lastDeathMemoryMB: Int = -1

    private enum RunKey {
        static let hadRun = "lizi.runHadRun"
        static let cleanExit = "lizi.runCleanExit"
        static let lastDeathStep = "lizi.lastDeathStep"
        static let lastDeathAt = "lizi.lastDeathAt"
        static let lastDeathMemoryMB = "lizi.lastDeathMemoryMB"
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
            lastDeathStep = breadcrumbSteps.last ?? ""
            lastDeathAt = Date().timeIntervalSince1970
            lastDeathMemoryMB = Self.memoryFootprintMB()
            ud.set(lastDeathStep, forKey: RunKey.lastDeathStep)
            ud.set(lastDeathAt, forKey: RunKey.lastDeathAt)
            ud.set(lastDeathMemoryMB, forKey: RunKey.lastDeathMemoryMB)
        } else {
            previousRunClean = true
            lastDeathStep = ud.string(forKey: RunKey.lastDeathStep) ?? ""
            lastDeathAt = ud.double(forKey: RunKey.lastDeathAt)
            lastDeathMemoryMB = ud.integer(forKey: RunKey.lastDeathMemoryMB)
        }
        ud.set(true, forKey: RunKey.hadRun)
        ud.set(false, forKey: RunKey.cleanExit)
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

    func json() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["lastSearch": lastSearch, "requests": requests, "events": events, "logs": logs,
                "playbackBreadcrumb": breadcrumbSteps,
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
                "lastDeathMemoryMB": lastDeathMemoryMB]
    }
}
