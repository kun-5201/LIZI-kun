import Foundation

/// 下载管理（r31，Moumusic 下载移植：只学流程和结构，按 Lizi 结构原生实现，
/// 不抄 Moumusic 代码，Moumusic 是 GPL-3.0）。
///
/// 原文确认（~/workspace/moumusic-check/platforms/ios/Sources/Kumone/Core/Storage/DownloadManager.swift
/// 全文已读，2026-11-21；研究员浏览器连挂 4 次没读到的那份，这里逐项对过）：
/// - 落盘：ApplicationSupport/Moumusic/Downloads/，文件名 `UUID.扩展名`，
///   记录是 ApplicationSupport/Moumusic/downloads.json（一份清单，Record 数组）。
/// - 会话：URLSessionConfiguration.default，**不是后台会话**；
///   timeoutIntervalForRequest = 30 秒、timeoutIntervalForResource = 1 小时。
/// - 并发：**不限**——downloadBatch 逐个起 Task，无信号量、无队列上限；
///   同一首去重（已有记录或任务在飞就忽略）。
/// - 断点续传：**没有**——普通 downloadTask，不存 resumeData。
/// - 失败重试：**没有**——失败只提示一次，不自动重下（点按重试是手动的）。
/// - 记录存储：downloads.json；启动 load 时过滤掉文件已不在的记录并回写。
/// - 去重：playbackKey（normalizedForLXPlayback().playbackKey）；Lizi 没有
///   这套归一化，用既有复合键（platform + id，见 key(for:)）。
/// - 实际音质：取链回的档位字符串原样存进 Record.quality，显示只认这个，
///   绝不显示请求的档位。
/// - 选档：默认档 = 全局默认音质；availableQualities 探该首实际可用的档，
///   选了不支持的档时 sheet 自动降到可用档里最高的一档。
/// - 播放优先本地：PlayerService 取链时先查 record(for:)，文件在就直接播
///   本地文件，来源标「本地下载」、音质取记录里的实际音质。
///
/// Lizi 落点（与 r27 旧下载的合并，**只留这一套下载**）：
/// - 落盘改到 ApplicationSupport/Lizi/Downloads/ + downloads.json（与原文
///   同结构，只换目录名）；文件名 `UUID.扩展名`；扩展名白名单与原文一致
///   （mp3/m4a/flac/wav/aac/ogg/opus，对不上回 m4a——原文默认值；
///   r27 旧版默认 mp3 已改，见交回）。
/// - **不再写进本地音乐**：r27 的下载走 LocalMusic.importFiles，下的歌混进
///   Documents/LocalMusic/ + index.json、在「本地音乐」里出现；按 Moumusic
///   口径（下载记录独立管理、不混进本地音乐库），r31 起新下载只进下载清单，
///   不进本地音乐列表。r27 已下载的歌仍由本地音乐管（见 legacy 兼容段），
///   不丢、不重复下。
/// - 取链：`PlaybackStore.resolveURLForDownload`（播放取链整条编排：
///   官方 → 云盘 → LX；全失败只回失败原因；试听片段 / 30 秒预览
///   （isTrial / isPreview）拒收，不把半首歌当整首存下来）。
///   所选档位经 forceQuality 同时进 LX 腿和平台腿（见 PlaybackStore）。
/// - 一首歌同时只下一个任务（重复点按忽略）；不同歌可并行（与原文一致，不限流）。
/// - 音质限制全去掉：下载不设会员/登录门，返回什么音质就下什么、显示实际下载音质；
///   「允许公开下载」不做。
/// - 默认档读取：`defaultDownloadQuality` 直接调
///   `SettingsStore.storedAudioQuality()`（r31 音质系统替换已落地，
///   键 `settings.audioQuality`，默认 exhigh；旧键 `lizi.native.quality`
///   已由 storedAudioQuality() 一次性迁入，这里不另读旧键）。
/// - r27 旧下载兼容（只读，不另起一套）：UserDefaults 旧映射
///   `lizi.native.downloadedTracks`（复合键 → 本地清单 entryId）仍认，
///   record(for:) / isDownloaded 命中旧映射且文件还在时同样算已下载、
///   播放同样优先本地；旧文件仍归本地音乐管（删文件走本地音乐行），
///   新下载绝不写旧映射、不进本地音乐清单。
final class DownloadStore: NSObject, ObservableObject {
    static let shared = DownloadStore()

    /// 下载完成通知（r28）：落盘 + 写清单成功后发一次，
    /// `LocalMusicSectionView` 订阅它刷新列表；失败 / 进度不发。
    /// userInfo：`["entryId": 新记录 id]`（r31 起 id 是复合键，不再是清单 entryId）。
    static let downloadCompletedNotification = Notification.Name("lizi.native.downloadCompleted")

    /// 一首歌的下载状态（UI 按它换图标：下载中是环形进度 + 百分比，
    /// 下完是勾，已下载态不重复下，失败是红三角、点按重试）。
    enum DownloadState: Equatable {
        case idle
        case downloading(Double) // 0…1
        case downloaded
        case failed(String)
    }

    /// 一条已下载记录（Moumusic Record 的结构：id / track / quality /
    /// fileName / createdAt；quality 是取链实际回的档位字符串）。
    struct Record: Codable, Identifiable, Hashable {
        let id: String
        let track: Track
        /// 实际下载音质：取链实际回的档位 rawValue；音源回了档位名但翻译不
        /// 出时（如 "192k"）存原文；两者都没有时存 ""（显示「未知」）。
        let quality: String
        let fileName: String
        let createdAt: Date
        /// 非常驻：r27 旧下载的文件还在 Documents/LocalMusic/ 里，
        /// fileURL 指过去；新下载恒为 nil。编码时不写（见 CodingKeys）。
        /// 默认 nil——合成 Codable 跳过不在 CodingKeys 里的属性要求它有默认值。
        var legacyFileURL: URL? = nil

        var fileURL: URL {
            legacyFileURL ?? DownloadStore.downloadDirectory.appendingPathComponent(fileName)
        }

        /// 记录里的实际档位（翻译得出时有值）。
        var actualQuality: AudioQuality? {
            quality.isEmpty ? nil : AudioQuality(rawValue: quality)
        }

        /// 记录里的档位原文（actualQuality 翻译不出时才有值）。
        var qualityLabel: String? {
            actualQuality == nil && !quality.isEmpty ? quality : nil
        }

        /// 管理页 / 播放页显示的实际音质：档位名优先，原文其次，都没有是「未知」。
        var displayQuality: String {
            actualQuality?.displayName ?? (quality.isEmpty ? "未知" : quality)
        }

        private enum CodingKeys: String, CodingKey {
            case id, track, quality, fileName, createdAt
        }
    }

    /// 一项正在下载（Moumusic ActiveDownload 的结构：id / track /
    /// requestedQuality / fraction；fraction 为 nil = 还没拿到总大小）。
    struct ActiveDownload: Identifiable {
        let id: String
        let track: Track
        let requestedQuality: AudioQuality
        var fraction: Double?
    }

    @Published private(set) var states: [String: DownloadState] = [:]
    /// 已下载记录（新下载专用；r27 旧下载不在这里面，见 record(for:) 的 legacy 分支）。
    @Published private(set) var records: [Record] = []
    /// 正在下载（key → ActiveDownload）。
    @Published private(set) var activeDownloads: [String: ActiveDownload] = [:]

    /// 全局默认下载档 = 全局默认播放档（SettingsStore.storedAudioQuality()，
    /// r31 音质系统替换已落地：键 `settings.audioQuality`，默认 exhigh；
    /// 旧键 `lizi.native.quality` 已由 storedAudioQuality() 一次性迁入，
    /// 这里不另读旧键、不另起默认档）。
    static var defaultDownloadQuality: AudioQuality {
        SettingsStore.storedAudioQuality()
    }

    /// 复合键 → 本地清单 entryId（r27 旧映射 `lizi.native.downloadedTracks`，
    /// 只读兼容用，新下载不再写它）。
    private static let downloadedKey = "lizi.native.downloadedTracks"

    /// 落盘目录（原文结构：ApplicationSupport/<App>/Downloads/）。
    nonisolated static var downloadDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lizi", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    /// 清单文件（原文结构：ApplicationSupport/<App>/downloads.json）。
    private nonisolated static var manifestURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lizi", isDirectory: true)
            .appendingPathComponent("downloads.json")
    }

    /// 在飞任务（delegate 在后台队列回调、start 在主线程调，用同一把锁保护）。
    private var tasks: [String: URLSessionDownloadTask] = [:]
    /// 待下载曲目（delegate 回调只有 task，没有 track；start 时暂存，
    /// 完成/失败时取出并清除）。
    private var pendingTracks: [String: Track] = [:]
    /// 待下载的档位信息（完成时写记录用：请求档 + 实际回档 + 原文）。
    private var pendingMeta: [String: (requested: AudioQuality, actual: AudioQuality?, label: String?)] = [:]
    /// 正在起步的 key（取链在 Task 里跑、任务还没建出来之前，
    /// 重复点按也忽略；取链结束（成功建任务 / 失败）时清掉）。
    private var startingKeys: Set<String> = []
    private let lock = NSLock()
    /// 原文会话：default 配置（不是后台会话），请求超时 30 秒、资源超时 1 小时。
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        try? FileManager.default.createDirectory(at: Self.downloadDirectory,
                                                 withIntermediateDirectories: true)
        load()
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

    /// 是否已下载（新记录 + r27 旧映射双重确认）。
    func isDownloaded(key: String) -> Bool {
        records.contains { $0.id == key && FileManager.default.fileExists(atPath: $0.fileURL.path) }
            || legacyRecord(forKey: key) != nil
    }

    /// 已下载记录（Moumusic record(for:) 同款：按复合键找，文件不在不算）。
    /// 先查新清单，再查 r27 旧映射（文件在 Documents/LocalMusic/ 里）。
    func record(for track: Track) -> Record? {
        let key = Self.key(for: track)
        if let record = records.first(where: { $0.id == key }),
           FileManager.default.fileExists(atPath: record.fileURL.path) {
            return record
        }
        return legacyRecord(forKey: key)
    }

    /// r27 旧下载的记录（只读兼容：文件仍归本地音乐管，这里只给
    /// record(for:) / isDownloaded / 播放优先本地用，不进 records、
    /// 不进管理页、不写清单）。
    private func legacyRecord(forKey key: String) -> Record? {
        guard let entryId = downloadedMap[key],
              let fileURL = LocalMusic.fileURL(id: entryId),
              FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        // 旧下载没记实际音质：track 从本地清单里只能拿到标题/歌手，
        // 这里用一个只有 id 的站位 track（播放优先本地只用 fileURL
        // 和 quality，标题/歌手走当前这首的 track，不走记录里的）。
        var record = Record(id: key, track: Track(id: entryId, platform: "local"),
                            quality: "", fileName: fileURL.lastPathComponent,
                            createdAt: Date(timeIntervalSince1970: 0))
        record.legacyFileURL = fileURL
        return record
    }

    /// 旧映射（只读；新下载不再写它）。
    private var downloadedMap: [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.downloadedKey) as? [String: String] ?? [:]
    }

    /// 重读清单缓存（下载完成 / 面板出现时调；不逐帧读盘）。
    /// r31：改读下载清单（原来读本地音乐清单）；旧映射不需要缓存，
    /// record(for:) 每次现查 LocalMusic.fileURL，文件删了即失效。
    func refreshDownloadedCache() {
        load()
    }

    /// 已下载总大小（字节；管理页 / 设置页摘要用，实读文件属性）。
    var totalSizeBytes: Int64 {
        records.reduce(0) { total, record in
            total + ((try? FileManager.default.attributesOfItem(atPath: record.fileURL.path)[.size] as? Int64) ?? 0)
        }
    }

    /// 摘要行（设置「存储与下载」分区 + 首页下载管理行共用）：
    /// 「已下载 N 首 · X MB」，没有时是「暂无下载」。
    var summaryText: String {
        guard !records.isEmpty else { return "暂无下载" }
        let size = ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
        return "已下载 \(records.count) 首 · \(size)"
    }

    /// 开始下载一首（r27 兼容口：默认档；调用方在 Task 里调）。
    /// fire-and-forget：取链在 Task 里跑，调完即回，不等下完。
    @MainActor
    func start(track: Track, store: PlaybackStore) async {
        download(track: track, store: store)
    }

    /// 开始下载一首（Moumusic download(track:quality:) 同款结构）：
    /// 默认档 = 全局默认音质（调用方不传时）；已下载 / 在飞 / 正在起步
    /// 的重复点按忽略；取链失败、试听片段都按失败处理，不落盘。
    func download(track: Track, quality: AudioQuality? = nil, store: PlaybackStore) {
        let key = Self.key(for: track)
        guard track.platform != "local" else { return }
        guard record(for: track) == nil else { return }
        lock.lock()
        let inFlight = tasks[key] != nil || startingKeys.contains(key)
        if !inFlight { startingKeys.insert(key) }
        lock.unlock()
        guard !inFlight else { return }
        let requested = quality ?? Self.defaultDownloadQuality
        setState(key: key, state: .downloading(0))
        DispatchQueue.main.async {
            self.activeDownloads[key] = ActiveDownload(id: key, track: track,
                                                        requestedQuality: requested, fraction: nil)
        }
        // 取链：整条播放编排（官方 → 云盘 → LX），所选档位同时进两条腿
        //（resolveURLForDownload 的 forceQuality）；不用平台腿单点。
        Task { @MainActor in
            defer {
                self.lock.lock(); self.startingKeys.remove(key); self.lock.unlock()
            }
            guard let result = await store.resolveURLForDownload(track: track, quality: requested),
                  let url = result.url else {
                self.setState(key: key, state: .failed("取链失败：\(self.downloadReasonText(store.errorMessage))"))
                self.removeActive(key: key)
                return
            }
            if result.isTrial || result.isPreview {
                self.setState(key: key, state: .failed("试听片段不能下载"))
                self.removeActive(key: key)
                return
            }
            let task = self.session.downloadTask(with: url)
            self.lock.lock()
            self.tasks[key] = task
            self.pendingTracks[key] = track
            self.pendingMeta[key] = (requested: requested, actual: result.actualQuality,
                                     label: result.servedLabel)
            self.lock.unlock()
            task.resume()
        }
    }

    /// 批量下载（Moumusic downloadBatch 同款：逐个起任务，不限流、不排队，
    /// 各首独立成功/失败；调完即回，不等全部下完）。
    func downloadBatch(_ tracks: [Track], quality: AudioQuality, store: PlaybackStore) {
        for track in tracks { download(track: track, quality: quality, store: store) }
    }

    /// 该首歌实际可用的档（Moumusic availableQualities 同款流程）：
    /// 逐档真探取链（每档都走 resolveURLForDownload 整条编排），
    /// 探到地址的档按实际回档收进结果（实际回档翻译不出时按请求档收）；
    /// 全探不到时回 [.standard]（原文同款兜底，下载时再按失败处理）。
    /// 注意：这是 9 档并行真探（每档都是一次完整取链），只在选音质 sheet
    /// 打开时跑一次，不常驻、不轮询。
    func availableQualities(for track: Track, store: PlaybackStore) async -> [AudioQuality] {
        let found = await withTaskGroup(of: AudioQuality?.self) { group in
            for tier in AudioQuality.allCases {
                group.addTask {
                    guard let result = await store.resolveURLForDownload(track: track, quality: tier),
                          result.url != nil else { return nil }
                    return result.actualQuality ?? tier
                }
            }
            var set = Set<AudioQuality>()
            for await quality in group {
                if let quality { set.insert(quality) }
            }
            return set
        }
        let sorted = found.sorted { $0.rank > $1.rank }
        return sorted.isEmpty ? [.standard] : sorted
    }

    /// 删除一条已下载记录（管理页左滑删除）：在飞任务取消、文件删除、
    /// 记录删除、清单回写。r27 旧下载不进管理页，不会走到这里；
    /// 万一传进来旧记录，只清旧映射、不动本地音乐的文件。
    /// r31 第三推构建修：run 44844080035 编译失败——`cancel(key:)` 是
    /// @MainActor，同步非隔离的 `delete` 调它报错；唯一调用方是 SwiftUI
    /// 管理页（已在主线程），直接把 `delete` 也标 @MainActor。
    @MainActor
    func delete(_ record: Record) {
        cancel(key: record.id)
        if record.legacyFileURL != nil {
            var map = downloadedMap
            map.removeValue(forKey: record.id)
            UserDefaults.standard.set(map, forKey: Self.downloadedKey)
            return
        }
        try? FileManager.default.removeItem(at: record.fileURL)
        records.removeAll { $0.id == record.id }
        save()
    }

    /// 取消（在飞任务取消 + 清状态；管理页删记录时调，下载中行不单独设取消键）。
    @MainActor
    func cancel(key: String) {
        lock.lock(); let task = tasks.removeValue(forKey: key); lock.unlock()
        task?.cancel()
        takePendingTrack(forKey: key)
        takePendingMeta(forKey: key)
        removeActive(key: key)
        if case .downloading = states[key] { setState(key: key, state: .idle) }
    }

    // MARK: - 清单读写（原文结构：downloads.json，启动过滤掉文件已不在的记录）

    private func load() {
        guard let data = try? Data(contentsOf: Self.manifestURL),
              let stored = try? JSONDecoder().decode([Record].self, from: data) else {
            records = []
            return
        }
        let kept = stored.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        records = kept
        if kept.count != stored.count { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: Self.manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: Self.manifestURL, options: .atomic)
    }

    // MARK: - 内部

    private func setState(key: String, state: DownloadState) {
        DispatchQueue.main.async { self.states[key] = state }
    }

    private func removeActive(key: String) {
        DispatchQueue.main.async { self.activeDownloads[key] = nil }
    }

    private func setActiveFraction(key: String, fraction: Double?) {
        DispatchQueue.main.async {
            guard var item = self.activeDownloads[key] else { return }
            item.fraction = fraction
            self.activeDownloads[key] = item
        }
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

    /// 扩展名：直链后缀在原文白名单里就用它，否则按 m4a 存（原文默认值）。
    private func fileExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["mp3", "m4a", "flac", "wav", "aac", "ogg", "opus"].contains(ext) ? ext : "m4a"
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

    private func takePendingMeta(forKey key: String) -> (requested: AudioQuality, actual: AudioQuality?, label: String?)? {
        lock.lock(); defer { lock.unlock() }
        return pendingMeta.removeValue(forKey: key)
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

    /// 下载完成：临时文件按 `UUID.扩展名` 挪进下载目录，写一条记录
    /// （实际音质 = 取链实际回的档位，翻译不出时存原文），清单回写。
    /// 不走 LocalMusic.importFiles——下载不再混进本地音乐清单。
    private func finishDownload(key: String, track: Track, location: URL, sourceURL: URL,
                                meta: (requested: AudioQuality, actual: AudioQuality?, label: String?)?) {
        let ext = fileExtension(for: sourceURL)
        let fileName = "\(UUID().uuidString).\(ext)"
        let destination = Self.downloadDirectory.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: Self.downloadDirectory,
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            setState(key: key, state: .failed("保存文件失败"))
            removeActive(key: key)
            return
        }
        // 实际音质：取链实际回的档位优先，翻译不出时存原文，都没有存 ""（显示「未知」）。
        // records 是 @Published：文件挪完后跳回主线程再写记录 / 发通知，
        // delegate 回调在后台队列，直接改会跨线程读写。
        let qualityString = meta?.actual?.rawValue ?? meta?.label ?? ""
        let record = Record(id: key, track: track, quality: qualityString,
                            fileName: fileName, createdAt: Date())
        Task { @MainActor in
            self.records.insert(record, at: 0)
            self.save()
            self.removeActive(key: key)
            self.setState(key: key, state: .downloaded)
            // 先写完记录 / 状态再发通知——订阅方收到就读清单，新记录已在里面。
            NotificationCenter.default.post(
                name: Self.downloadCompletedNotification,
                object: self,
                userInfo: ["entryId": record.id]
            )
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
        let meta = takePendingMeta(forKey: key)
        finishDownload(key: key, track: track, location: location,
                       sourceURL: downloadTask.originalRequest?.url ?? location, meta: meta)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let key = key(for: downloadTask) else { return }
        let progress = totalBytesExpectedToWrite > 0
            ? min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
            : nil
        if let progress {
            setState(key: key, state: .downloading(progress))
        }
        setActiveFraction(key: key, fraction: progress)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let key = takeTaskKey(for: downloadTask) else { return }
        takePendingTrack(forKey: key)
        takePendingMeta(forKey: key)
        // 成功时 didFinishDownloadingTo 已先调，这里只处理失败。
        // 原文：失败不自动重试（没有重试次数）；点按重试是手动的。
        if let error {
            let ns = error as NSError
            if ns.code == NSURLErrorCancelled { return }
            removeActive(key: key)
            setState(key: key, state: .failed("下载失败：\(error.localizedDescription)"))
        }
    }
}
