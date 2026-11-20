import Foundation

/// 下载到本地（r27，v4 底部三排下载键）。
///
/// 复用现有链路，不另造：
/// - 取链：`PlaybackStore.resolveURLForDownload`（播放取链整条编排：
///   官方 → 云盘 → LX；演示音不在取链里，全失败只回失败原因，下载永远
///   拿不到演示音；试听片段 / 30 秒预览（isTrial / isPreview）也拒收，
///   不把半首歌当整首存下来）。
/// - 落盘：`LocalMusic.importFiles`（Documents/LocalMusic/ + index.json，
///   与文件 App 导入同一套；导完自然出现在本地音乐列表里，可播）。
///   文件名用「歌手 - 歌名.扩展名」（去非法字符），标题优先读内嵌元数据，
///   读不到就用文件名——与 importOne 现有行为一致。
/// - 「已下载」判定：UserDefaults 记复合键（platform + id）→ 本地清单 entryId；
///   每次判定都对 `LocalMusic.list()`（已过滤掉被删的文件），清单里没有
///   就不算已下载，映射 stale 也不误判。本地平台（platform == "local"）
///   的歌本身就在清单里，直接算已下载。
/// - 一首歌同时只下一个任务（重复点按忽略）；不同歌可并行。
/// - 音频直链是 https 升级过的（取链已升）；个别平台直链可能仍需
///   Referer 才能拉（真机验，见交回）。
final class DownloadStore: NSObject, ObservableObject {
    static let shared = DownloadStore()

    /// 一首歌的下载状态（UI 按它换图标：下载中是环形进度 + 百分比，
    /// 下完是勾，已下载态不重复下，失败是红三角、点按重试）。
    enum DownloadState: Equatable {
        case idle
        case downloading(Double) // 0…1
        case downloaded
        case failed(String)
    }

    @Published private(set) var states: [String: DownloadState] = [:]

    /// 复合键 → 本地清单 entryId（`lizi.native.downloadedTracks`）。
    private static let downloadedKey = "lizi.native.downloadedTracks"

    /// 在飞任务（delegate 在后台队列回调、start 在主线程调，用同一把锁保护）。
    private var tasks: [String: URLSessionDownloadTask] = [:]
    /// 待下载曲目（delegate 回调只有 task，没有 track；start 时暂存，
    /// 完成/失败时取出并清除）。
    private var pendingTracks: [String: Track] = [:]
    private let lock = NSLock()
    private var downloadedEntryIds: Set<String> = []
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        refreshDownloadedCache()
    }

    /// 喜欢同款复合键（platform + id；见 PlaybackStore.likeKey）。
    static func key(for track: Track) -> String {
        "\(track.platform)\u{1f}\(track.id)"
    }

    /// 当前状态（本地歌直接算已下载；映射在但清单里没了也不算）。
    func state(forKey key: String, track: Track? = nil) -> DownloadState {
        if track?.platform == "local" { return .downloaded }
        if let s = states[key] { return s }
        if isDownloaded(key: key) { return .downloaded }
        return .idle
    }

    /// 是否已下载（映射 + 清单双重确认）。
    func isDownloaded(key: String) -> Bool {
        guard let entryId = downloadedMap[key] else { return false }
        return downloadedEntryIds.contains(entryId)
    }

    /// 重读本地清单缓存（下载完成 / 面板出现时调；不逐帧读盘）。
    func refreshDownloadedCache() {
        downloadedEntryIds = Set(LocalMusic.list().map { $0.id })
    }

    private var downloadedMap: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.downloadedKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.downloadedKey) }
    }

    /// 开始下载（调用方在 Task 里调；演示音不进这里——取链本身不回演示音，
    /// 这里再守一道：store.isDemo 时直接失败，不发起请求）。
    @MainActor
    func start(track: Track, store: PlaybackStore) async {
        let key = Self.key(for: track)
        guard track.platform != "local" else { return }
        if case .downloading = states[key] { return }
        if isDownloaded(key: key) { return }
        // isDemo 是 @MainActor 状态，start 本身已是 @MainActor，直接读。
        guard !store.isDemo else {
            setState(key: key, state: .failed("演示音不能下载"))
            return
        }
        setState(key: key, state: .downloading(0))
        // 取链：整条播放编排（官方 → 云盘 → LX），不用平台腿单点。
        guard let result = await store.resolveURLForDownload(track: track),
              let url = result.url else {
            setState(key: key, state: .failed("取链失败：\(downloadReasonText(result?.reason ?? store.errorMessage))"))
            return
        }
        if result.isTrial || result.isPreview {
            setState(key: key, state: .failed("试听片段不能下载"))
            return
        }
        // via == "local" 走不到这里：本地歌在 start 开头已 return，
        // 非本地歌的取链不会回文件地址；不另分支。
        let task = session.downloadTask(with: url)
        lock.lock(); tasks[key] = task; lock.unlock()
        setPendingTrack(track, forKey: key)
        task.resume()
    }

    /// 取消（目前 UI 没放取消入口；任务完成/失败时自清，留给以后用）。
    @MainActor
    func cancel(key: String) {
        lock.lock(); let task = tasks.removeValue(forKey: key); lock.unlock()
        task?.cancel()
        takePendingTrack(forKey: key)
        if case .downloading = states[key] { setState(key: key, state: .idle) }
    }

    private func setPendingTrack(_ track: Track, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        pendingTracks[key] = track
    }

    /// 取出并清除（完成/失败时调一次）。
    private func takePendingTrack(forKey key: String) -> Track? {
        lock.lock(); defer { lock.unlock() }
        return pendingTracks.removeValue(forKey: key)
    }

    /// 按对象同一性找回 key 并移除任务（delegate 回调里用；同一时刻
    /// 多首歌并行，taskIdentifier 对不上 key）。
    private func takeTaskKey(for task: URLSessionDownloadTask) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let key = tasks.first(where: { $0.value === task })?.key else { return nil }
        tasks[key] = nil
        return key
    }

    /// 读当前进度用（不移除任务）。
    private func key(for task: URLSessionDownloadTask) -> String? {
        lock.lock(); defer { lock.unlock() }
        return tasks.first(where: { $0.value === task })?.key
    }

    // MARK: - 内部

    private func setState(key: String, state: DownloadState) {
        DispatchQueue.main.async { self.states[key] = state }
    }

    private func downloadReasonText(_ reason: String?) -> String {
        switch reason {
        case "vip": return "会员歌曲，无法下载整首"
        case "login": return "需要登录后才能下载"
        case "region": return "该歌曲在你所在的地区不可用"
        case "drm": return "该歌曲受版权保护，无法下载"
        case "network": return "网络有问题，稍后再试"
        default: return "暂时无法获取下载地址"
        }
    }

    /// 扩展名：直链后缀在白名单里就用它，否则按 mp3 存
    /// （AVPlayer 按内容嗅探，扩展名错了也能播，标题走元数据）。
    private func fileExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return LocalMusic.allowedExtensions.contains(ext) ? ext : "mp3"
    }

    private func sanitizedFileName(for track: Track, ext: String) -> String {
        let raw = "\(track.artist.isEmpty ? "未知歌手" : track.artist) - \(track.title.isEmpty ? "未知标题" : track.title)"
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let name = raw.components(separatedBy: bad).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "未知歌曲" : name) + ".\(ext)"
    }

    /// 下载完成：把临时文件按目标文件名挪到临时目录，再走
    /// LocalMusic.importFiles（拷进 LocalMusic/ + 写 index.json）。
    private func finishDownload(key: String, track: Track, location: URL, sourceURL: URL) {
        let fileName = sanitizedFileName(for: track, ext: fileExtension(for: sourceURL))
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + fileName)
        do {
            try FileManager.default.moveItem(at: location, to: tempURL)
        } catch {
            setState(key: key, state: .failed("保存文件失败"))
            return
        }
        Task.detached {
            let result = LocalMusic.importFiles(urls: [tempURL])
            try? FileManager.default.removeItem(at: tempURL)
            await MainActor.run {
                if let entry = result.imported.first {
                    var map = self.downloadedMap
                    map[key] = entry.id
                    self.downloadedMap = map
                    self.refreshDownloadedCache()
                    self.setState(key: key, state: .downloaded)
                } else {
                    self.setState(key: key, state: .failed("导入本地音乐失败"))
                }
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate（回调在后台队列，状态回主线程写）

extension DownloadStore: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // 按对象同一性找回 key（同一时刻多首歌并行，taskIdentifier 对不上 key）。
        guard let key = takeTaskKey(for: downloadTask),
              let track = takePendingTrack(forKey: key) else { return }
        finishDownload(key: key, track: track, location: location,
                       sourceURL: downloadTask.originalRequest?.url ?? location)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0,
              let key = key(for: downloadTask) else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        setState(key: key, state: .downloading(min(max(progress, 0), 1)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let key = takeTaskKey(for: downloadTask) else { return }
        takePendingTrack(forKey: key)
        // 成功时 didFinishDownloadingTo 已先调，这里只处理失败。
        if let error {
            let ns = error as NSError
            if ns.code == NSURLErrorCancelled { return }
            setState(key: key, state: .failed("下载失败：\(error.localizedDescription)"))
        }
    }
}
