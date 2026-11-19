import Foundation

/// 服务端诊断（给设置页 / 真机排障用，不含任何隐私内容）：
///  - lastSearch：最近一次网易搜索的上游端点、耗时、HTTP 状态、条数、错误；
///  - requests：最近 20 条本地请求（方法、路径、耗时、状态）。
/// 前端搜不到歌时，下一张截图只要带上 /api/diag/search 就能分清
/// 是本地服务挂了、上游挂了、还是解析挂了。
///
/// 第 14 轮（诊断是空的）：logs / requests / events / lastSearch 原来只放
/// 内存 —— 进程一死（闪退/被杀/升级重装不丢 UserDefaults 但丢内存）就全
/// 丢，重启后设置页只能看到「诊断日志（0 条）」。现在全部落盘到
/// UserDefaults（和 playbackBreadcrumb 同一级持久化，崩溃也还在），cap
/// 不变（logs 100 / requests 20 / events 20）。写失败只丢这次持久化，
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
    func recordPlaybackStep(_ step: String) {
        lock.lock(); defer { lock.unlock() }
        var steps = UserDefaults.standard.stringArray(forKey: "lizi.playbackBreadcrumb") ?? []
        steps.append("\(Int(Date().timeIntervalSince1970)) \(step)")
        if steps.count > 30 { steps.removeFirst(steps.count - 30) }
        UserDefaults.standard.set(steps, forKey: "lizi.playbackBreadcrumb")
    }

    func json() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["lastSearch": lastSearch, "requests": requests, "events": events, "logs": logs,
                "playbackBreadcrumb": UserDefaults.standard.stringArray(forKey: "lizi.playbackBreadcrumb") ?? [],
                // 第 15 轮第 4 件：挂起的 LX 取链任务数（>0 且一直不回零
                // 就是有脚本 Promise 不 settle、任务泄漏了）。
                "lxPendingCalls": LXScriptInstance.pendingMusicUrlCalls,
                // 第 15 轮第 6 件：服务端收到的诊断 POST 数（和 JS 侧
                // window.__liziDiagCounts().sent 对账）。
                "diagLogReceived": diagLogReceived]
    }
}
