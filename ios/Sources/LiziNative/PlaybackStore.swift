import AVFoundation
import Combine
import Foundation

/// 播放状态机（P1 填实）：AVPlayer 封装 + 队列 + 取链编排器。
///
/// 取链编排（照抄壳版 public/player.js fetchTrackUrl 的顺序）：
/// - 有会员（已登录 AND 有 VIP 信号）→ 平台官方 → 已登录个人云盘 → LX → 演示音
/// - 没会员（没登录 / 登录了但没会员 / 状态取不到）→ LX 先 → 平台 → 云盘 → 演示音
///   （LX 先是为了拿整首：没会员时官方常只给 30 秒试听；LX 拿不到再回官方，
///   但 VIP 歌的试听地址直接拒掉，不放试听片段）
/// - 波点 / Apple Music：LX 不支持它们，永远走老顺序；本地文件直接播文件 URL。
///
/// 第 16 轮教训：酷狗崩溃点在取到资源之后、播放启动那一段——播放启动路径
/// **不要留强制解包**，每一步调 `DiagLog.recordPlaybackStep`（文件落盘）。
/// 音频会话：AVAudioSession .playback 独占（不设 mixWithOthers），第一次真正
/// 播放时才激活（照抄壳版 ContentView 的做法，避免打开 App 就抢走别的 App 的声音）。
///
/// 注意：刻意不用 @MainActor（照抄壳版 LiveActivityManager 的做法）——
/// App.init（非隔离上下文）要同步创建它，且 IslandControlRelay / 远程命令
/// 的回调都在非隔离闭包里；主线程执行由各调用点的 Task { @MainActor in } 跳转
/// + AVPlayer 回调队列 .main 保证，不靠编译器隔离。
final class PlaybackStore: ObservableObject {
    // MARK: - 发布状态（UI 工人直接读这些）

    /// 当前曲目；未播放时为 nil。
    @Published private(set) var currentTrack: Track?
    /// 播放队列（当前曲目在其中；QueueItem 带 queueId，同一首歌可重复入队）。
    @Published private(set) var queue: [QueueItem] = []
    /// 当前曲目在队列里的下标；没有时为 -1。
    @Published private(set) var currentIndex: Int = -1
    /// 是否正在播放。
    @Published private(set) var isPlaying: Bool = false
    /// 当前进度（秒）。
    @Published private(set) var progress: TimeInterval = 0
    /// 当前曲目总时长（秒）；未知时为 0。
    @Published private(set) var duration: TimeInterval = 0
    /// 当前曲目是否已喜欢（星标）。
    @Published private(set) var isLiked: Bool = false
    /// 是否正在取链 / 加载。
    @Published private(set) var isLoading: Bool = false
    /// 播放失败时的原因（vip / unavailable / login / region / drm / network；
    /// 成功时为 nil）。UI 按它明示「为什么没声音」，不静默。
    @Published private(set) var errorMessage: String?
    /// 当前曲目的实际音质档位（显示音质 = 这个，绝不显示请求的档位）。
    @Published private(set) var actualQuality: AudioQuality?
    /// 是否正在放演示音（取链全失败时的最后一档；不是真歌，UI 要标出来）。
    @Published private(set) var isDemo: Bool = false
    /// 当前歌词行（官方 → LRCLIB；无词时为空，UI 显示歌名）。
    @Published private(set) var lyrics: [LyricLine] = []
    /// 当前歌词行下标；无词 / 还没开始时为 -1。
    @Published private(set) var currentLyricIndex: Int = -1
    /// 循环模式（顺序 / 全部循环 / 单曲循环；随机是独立开关）。
    @Published private(set) var repeatMode: RepeatMode = .off
    /// 随机播放开关。
    @Published private(set) var isShuffled: Bool = false
    /// 用户选的请求档位（默认无损；EQ 页 P4 负责改这里）。
    @Published private(set) var preferredQuality: AudioQuality = .lossless

    enum RepeatMode: String, Codable, CaseIterable {
        case off    // 顺序播完停
        case all    // 全部循环
        case one    // 单曲循环
    }

    // MARK: - 内部

    private let player = AVPlayer()
    private let proxyLoader = AudioProxyLoader()
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemObservers: [NSObjectProtocol] = []
    private var playToken = 0
    /// 在飞的点播任务（r20 集成 L①：`playCurrent` 的 resolve 段包进可存取的
    /// Task；新点播先取消旧的，旧任务的 resolve 被取消后立刻向上抛
    /// CancellationError，不再攒出多个无返回的挂死调用；取消时记一条
    /// `resolve superseded` 面包屑。next()/previous() 都走 play()，
    /// 所以这里是唯一的取消点）。
    private var playTask: Task<Void, Never>?
    private var lastFetchVia: String = ""
    private var lastFetchReason: String = ""
    private var proxyTried = false
    private var fallbackRetried = false
    private var demoTried = false
    private var currentAssetURL: URL?
    private var audioSessionActivated = false
    private var wasPlayingBeforeInterruption = false

    private static let likedKey = "lizi.native.likedTrackIds"
    /// P2：星标完整曲目（[Track] JSON；liked rail 用）。旧的 id 集合键不动，
    /// 保证兼容——P2 之前点的星标只有 id、没有曲目详情，恢复不出来，
    /// 不编假曲目；重新点一次星标（取消再点）后才有完整记录。
    private static let likedTracksKey = "lizi.native.likedTracks"
    private static let qualityKey = "lizi.native.quality"
    private var likedIds: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: Self.likedKey) ?? []
            return Set(arr)
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.likedKey) }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.qualityKey),
           let q = AudioQuality(rawValue: raw) {
            preferredQuality = q
        }
        configureAudioSession()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in self.handleTimeUpdate(time) }
        }
        _ = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { @MainActor in self.handleInterruption(note) }
        }
    }

    // 注意：没有 deinit——PlaybackStore 是 App 生命周期单例（StateObject），
    // 随 App 消亡；time observer / KVO 观察随 player / item 一起释放，不用手动清理。
    // deinit 里访问 @MainActor 隔离的状态在 Swift 6 下是硬错，这里直接不写 deinit。

    // MARK: - 音频会话

    /// 类别 .playback 独占：不设 mixWithOthers（混音会把双音频问题带回来），
    /// 启动时只设类别、不激活（第一次真正播放时才激活，见 activateSessionOnce）。
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        } catch {
            DiagLog.shared.recordPlaybackStep("audiosession category FAIL: \(error.localizedDescription)")
        }
    }

    private func activateSessionOnce() {
        guard !audioSessionActivated else { return }
        audioSessionActivated = true
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            DiagLog.shared.recordPlaybackStep("audiosession activate ok (first play)")
        } catch {
            DiagLog.shared.recordPlaybackStep("audiosession activate FAIL (first play): \(error.localizedDescription)")
            // 激活失败也不拦着播；媒体播放时系统自己也会激活。
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            pause()
        case .ended:
            if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume),
               wasPlayingBeforeInterruption {
                resume()
            }
        @unknown default:
            break
        }
    }

    // MARK: - 队列

    /// 整队替换并从指定下标开始播（搜索结果 / 歌单点歌用）。
    func setQueue(_ tracks: [Track], startAt index: Int) {
        queue = tracks.map { QueueItem(track: $0) }
        currentIndex = queue.indices.contains(index) ? index : (queue.isEmpty ? -1 : 0)
        if let track = currentQueueTrack {
            play(track)
        }
    }

    /// 追加到队尾（不切歌）。
    func appendToQueue(_ track: Track) {
        queue.append(QueueItem(track: track))
    }

    /// 从队列里删一项（删的是当前在播的就切到下一首）。
    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let wasCurrent = index == currentIndex
        queue.remove(at: index)
        if queue.isEmpty {
            stop()
            return
        }
        if wasCurrent {
            currentIndex = min(index, queue.count - 1)
            if let track = currentQueueTrack { play(track) }
        } else if index < currentIndex {
            currentIndex -= 1
        }
    }

    /// 清空队列并停止。
    func clearQueue() {
        stop()
        queue = []
        currentIndex = -1
    }

    private var currentQueueTrack: Track? {
        guard currentIndex >= 0, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex].track
    }

    // MARK: - 控制

    /// 播放指定曲目（不在队列里时先把它设为单首队列）。
    func play(_ track: Track) {
        if let idx = queue.firstIndex(where: { $0.track.id == track.id && $0.track.platform == track.platform }) {
            currentIndex = idx
        } else {
            queue = [QueueItem(track: track)]
            currentIndex = 0
        }
        // r20 集成 L①：新点播先取消旧的在飞任务（旧 resolve 被取消后
        // 立刻向上抛 CancellationError，不再挂死），再起新任务。
        if let old = playTask, !old.isCancelled {
            old.cancel()
            DiagLog.shared.recordPlaybackStep("resolve superseded source=\(track.platform) id=\(track.id)")
        }
        playTask = Task { @MainActor in await playCurrent() }
    }

    /// 恢复播放。
    func resume() {
        guard currentTrack != nil else { return }
        activateSessionOnce()
        player.play()
        isPlaying = true
    }

    /// 暂停（岛/锁屏保留暂停态，staleDate 到时自然消失；不主动 end 活动）。
    func pause() {
        player.pause()
        isPlaying = false
    }

    /// 播放/暂停切换。
    func togglePlay() {
        if isPlaying { pause() } else { resume() }
    }

    /// 下一首（随机开时随机挑一首不一样的；循环关且到队尾时停）。
    func next() {
        guard !queue.isEmpty else { return }
        if isShuffled, queue.count > 1 {
            var idx = currentIndex
            while idx == currentIndex { idx = Int.random(in: 0..<queue.count) }
            currentIndex = idx
        } else if currentIndex + 1 < queue.count {
            currentIndex += 1
        } else if repeatMode == .all {
            currentIndex = 0
        } else {
            // 播完队尾：停在原地（不自动重播、不静默切歌）。
            pause()
            return
        }
        if let track = currentQueueTrack { play(track) }
    }

    /// 上一首（进度超过 3 秒时先回到开头，照常见播放器做法；否则切上一首）。
    func previous() {
        guard !queue.isEmpty else { return }
        if progress > 3 {
            seek(to: 0)
            return
        }
        if isShuffled, queue.count > 1 {
            var idx = currentIndex
            while idx == currentIndex { idx = Int.random(in: 0..<queue.count) }
            currentIndex = idx
        } else if currentIndex > 0 {
            currentIndex -= 1
        } else if repeatMode == .all {
            currentIndex = queue.count - 1
        } else {
            seek(to: 0)
            return
        }
        if let track = currentQueueTrack { play(track) }
    }

    /// 喜欢/取消喜欢当前曲目（持久化到 UserDefaults；锁屏星标由 NowPlayingCoordinator 同步）。
    /// P2：id 集合之外，同时持久化完整 Track（liked rail 直接读，不用再反查）。
    func toggleLike() {
        guard let track = currentTrack else { return }
        var ids = likedIds
        if ids.contains(track.id) { ids.remove(track.id) } else { ids.insert(track.id) }
        likedIds = ids
        isLiked = ids.contains(track.id)
        var tracks = Self.likedTracks()
        if ids.contains(track.id) {
            if !tracks.contains(where: { $0.id == track.id && $0.platform == track.platform }) {
                tracks.append(track)
            }
        } else {
            tracks.removeAll { $0.id == track.id && $0.platform == track.platform }
        }
        Self.saveLikedTracks(tracks)
    }

    /// 已喜欢的完整曲目列表（按点星标顺序；调用方按 platform 过滤）。
    /// 只有 P2 之后点的星标才有完整记录，旧的 id 只有 id、恢复不出来，不编。
    static func likedTracks() -> [Track] {
        guard let data = UserDefaults.standard.data(forKey: likedTracksKey),
              let tracks = try? JSONDecoder().decode([Track].self, from: data) else { return [] }
        return tracks
    }

    private static func saveLikedTracks(_ tracks: [Track]) {
        if let data = try? JSONEncoder().encode(tracks) {
            UserDefaults.standard.set(data, forKey: likedTracksKey)
        }
    }

    /// 跳到指定进度（秒）。
    func seek(to time: TimeInterval) {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let target = CMTime(seconds: max(0, min(time, duration)), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.progress = time }
        }
    }

    /// 循环模式切换（顺序 → 全部循环 → 单曲循环）。
    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    /// 随机开关。
    func setShuffled(_ on: Bool) { isShuffled = on }

    /// 请求档位（EQ 页 P4 改这里；显示的永远是实际返回档位，不是这个）。
    func setPreferredQuality(_ q: AudioQuality) {
        preferredQuality = q
        UserDefaults.standard.set(q.rawValue, forKey: Self.qualityKey)
    }

    /// 停止（播完 / 清空队列用；不 end 灵动岛，岛靠暂停态 + staleDate 自然消失）。
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isLoading = false
        progress = 0
        currentTrack = nil
    }

    // MARK: - 播放主流程（第 16 轮教训：全程无强制解包）

    private func playCurrent() async {
        guard let track = currentQueueTrack else { return }
        playToken += 1
        let token = playToken
        proxyTried = false
        fallbackRetried = false
        demoTried = false
        isLoading = true
        errorMessage = nil
        isDemo = false
        actualQuality = nil
        progress = 0
        duration = track.durationSeconds
        currentTrack = track
        isLiked = likedIds.contains(track.id)
        lyrics = []
        currentLyricIndex = -1

        DiagLog.shared.recordPlaybackStep("play start source=\(track.platform) id=\(track.id)")
        // 歌词并行拉（不阻塞取链；切歌时 token 变了就丢弃）。
        Task { @MainActor in
            let parsed = await NativeBridge.lyrics(for: track)
            guard token == self.playToken else { return }
            self.lyrics = parsed.lines
            self.currentLyricIndex = LyricsParser.currentLineIndex(lines: parsed.lines, atMs: 0)
        }

        let result = await resolveURL(for: track)
        guard token == playToken else { return }
        guard let result, let url = result.url else {
            // 取链全失败：不放演示音冒充，直接报错（演示音只在播放阶段兜底，见 handlePlaybackFailure）。
            isLoading = false
            isPlaying = false
            errorMessage = result?.reason ?? "unavailable"
            lastFetchReason = result?.reason ?? "unavailable"
            DiagLog.shared.recordPlaybackStep("resolve url FAIL source=\(track.platform) id=\(track.id) reason=\(lastFetchReason)")
            return
        }
        lastFetchVia = result.via
        lastFetchReason = result.reason
        actualQuality = result.actualQuality
        if result.isTrial || result.isPreview {
            currentTrack?.isTrial = true
        }
        DiagLog.shared.recordPlaybackStep("url ok source=\(track.platform) id=\(track.id) via=\(result.via)")

        activateSessionOnce()
        await startItem(url: url, track: track, token: token)
    }

    /// 把地址交给 AVPlayer 并起播（token 抢占丢弃点 + 状态观察都落在这里）。
    private func startItem(url: URL, track: Track, token: Int) async {
        guard token == playToken else { return }
        currentAssetURL = url
        let asset: AVURLAsset
        if url.scheme == AudioProxyLoader.scheme {
            asset = AVURLAsset(url: url)
            asset.resourceLoader.setDelegate(proxyLoader, queue: DispatchQueue.main)
        } else {
            asset = AVURLAsset(url: url)
        }
        let item = AVPlayerItem(asset: asset)
        observe(item: item, token: token)
        DiagLog.shared.recordPlaybackStep("set src via=\(lastFetchVia) source=\(track.platform) id=\(track.id)")
        player.replaceCurrentItem(with: item)
        player.play()
        DiagLog.shared.recordPlaybackStep("play called source=\(track.platform) id=\(track.id)")
        isLoading = false
        isPlaying = true
    }

    /// 监听当前 item 的状态与结束事件（每次换 item 都重建观察，避免旧观察串台）。
    private func observe(item: AVPlayerItem, token: Int) {
        itemStatusObservation?.invalidate()
        for o in itemObservers { NotificationCenter.default.removeObserver(o) }
        itemObservers = []
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                guard token == self.playToken else { return }
                if item.status == .failed {
                    await self.handlePlaybackFailure()
                } else if item.status == .readyToPlay {
                    let d = item.asset.duration.seconds
                    if d.isFinite, d > 0 { self.duration = d }
                    self.isLoading = false
                }
            }
        }
        let endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard token == self.playToken else { return }
                if self.repeatMode == .one {
                    self.seek(to: 0)
                    self.resume()
                } else {
                    self.next()
                }
            }
        }
        let failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard token == self.playToken else { return }
                await self.handlePlaybackFailure()
            }
        }
        itemObservers = [endObserver, failObserver]
    }

    /// 地址进了播放器才发现是死的（代理 502/403、解码失败）时的重试链
    /// （照抄 player.js tryProxyFallback + retryWithFallback + 演示音兜底）：
    /// 1) 同一条地址走音频代理再试一次（每首只一次）；
    /// 2) 按优先级往下一档重试一次（platform → cloud/LX）；
    /// 3) 再失败放演示音（界面照常走完，角标 reason 说清真正原因）。
    private func handlePlaybackFailure() async {
        guard let track = currentTrack else { return }
        let token = playToken
        // 1) 代理兜底（直链失败可能是 CDN 临时抽风 / CORS 抖动）。
        if !proxyTried, let url = currentAssetURL, url.scheme != AudioProxyLoader.scheme {
            proxyTried = true
            DiagLog.shared.recordPlaybackStep("direct play FAIL, try proxy source=\(track.platform) id=\(track.id) via=\(lastFetchVia)")
            let proxyURL = proxyLoader.proxyURL(for: url, source: track.platform)
            await startItem(url: proxyURL, track: track, token: token)
            return
        }
        // 2) 往下一档重试一次（已证实是死的那一档直接跳过）。
        if !fallbackRetried, (lastFetchVia == "platform" || lastFetchVia == "cloud") {
            fallbackRetried = true
            let skips = SkipSet(skipPlatform: true,
                                skipCloud: lastFetchVia == "cloud",
                                skipLX: false)
            DiagLog.shared.recordPlaybackStep("play FAIL, retry next tier source=\(track.platform) id=\(track.id) via=\(lastFetchVia)")
            if let result = await resolveURL(for: track, skips: skips),
               let url = result.url, token == playToken {
                lastFetchVia = result.via
                lastFetchReason = result.reason
                actualQuality = result.actualQuality
                await startItem(url: url, track: track, token: token)
                return
            }
        }
        // 3) 演示音兜底（第 11 轮第 8 件：取链失败走演示音、播放失败也走演示音）。
        // demoTried 护栏：演示音本身播失败时不再重进这一档，否则死循环。
        if !demoTried, let demoURL = DemoTone.url(), token == playToken {
            demoTried = true
            DiagLog.shared.recordPlaybackStep("play FAIL, fallback to demo source=\(track.platform) id=\(track.id) reason=\(lastFetchReason)")
            isDemo = true
            actualQuality = nil
            errorMessage = nil
            await startItem(url: demoURL, track: track, token: token)
            return
        }
        isLoading = false
        isPlaying = false
        errorMessage = lastFetchReason.isEmpty ? "unavailable" : lastFetchReason
        DiagLog.shared.recordPlaybackStep("play FAIL all tiers source=\(track.platform) id=\(track.id) reason=\(lastFetchReason)")
    }

    // MARK: - 取链编排器

    private struct SkipSet {
        var skipPlatform = false
        var skipCloud = false
        var skipLX = false
    }

    /// 取链编排（player.js fetchTrackUrl 的顺序；每一档只在上一档明确拿不到
    /// 地址时才跑）。返回 nil = 各档都拿不到（调用方按 reason 报错，不编地址）。
    private func resolveURL(for track: Track, skips: SkipSet = SkipSet()) async -> NativeBridge.SongURLResult? {
        DiagLog.shared.recordPlaybackStep("resolve start source=\(track.platform) id=\(track.id)")
        // 本地文件：地址就是文件 URL，不走 LX、不走平台接口。
        if track.platform == "local" {
            if let fileURL = LocalMusic.fileURL(id: track.id) {
                return NativeBridge.SongURLResult(url: fileURL, via: "local")
            }
            return NativeBridge.SongURLResult(reason: "unavailable", via: "local")
        }
        let lxSupported = ["netease", "qq", "kugou", "kuwo", "qishui"].contains(track.platform)
        let member = await NativeBridge.isMember(platform: track.platform)
        // 没会员 → LX 先（拿整首）；有会员 → 平台先。
        let lxFirst = !skips.skipLX && lxSupported && !member
        var lastReason = ""
        if lxFirst, let lx = await NativeBridge.lxSongURL(track: track, quality: preferredQuality) {
            DiagLog.shared.recordPlaybackStep("resolve lx-first ok source=\(track.platform) id=\(track.id)")
            return lx
        }
        if !skips.skipPlatform {
            let r = await NativeBridge.songURL(track: track, quality: preferredQuality)
            lastReason = r.reason
            if let url = r.url {
                // 没会员 + LX 已先跑过且没拿到时，官方的试听地址直接拒掉（不放试听片段）。
                if lxFirst && r.isTrial {
                    lastReason = "vip"
                    DiagLog.shared.recordPlaybackStep("resolve platform trial rejected source=\(track.platform) id=\(track.id)")
                } else {
                    DiagLog.shared.recordPlaybackStep("resolve platform ok source=\(track.platform) id=\(track.id) via=platform")
                    return r
                }
            }
        }
        if !skips.skipCloud, track.platform == "netease",
           let cloud = await NativeBridge.cloudSongURL(track: track) {
            DiagLog.shared.recordPlaybackStep("resolve cloud ok id=\(track.id)")
            return cloud
        }
        if !lxFirst, !skips.skipLX, lxSupported,
           let lx = await NativeBridge.lxSongURL(track: track, quality: preferredQuality) {
            DiagLog.shared.recordPlaybackStep("resolve lx fallback ok source=\(track.platform) id=\(track.id)")
            return lx
        }
        return NativeBridge.SongURLResult(reason: lastReason.isEmpty ? "unavailable" : lastReason,
                                          via: "platform")
    }

    // MARK: - 进度（AVPlayer periodic time observer 驱动）

    private func handleTimeUpdate(_ time: CMTime) {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        progress = seconds
        if duration <= 0 {
            let d = item.asset.duration.seconds
            if d.isFinite, d > 0 { duration = d }
        }
        let atMs = Int(seconds * 1000)
        let idx = LyricsParser.currentLineIndex(lines: lyrics, atMs: atMs)
        if idx != currentLyricIndex {
            currentLyricIndex = idx
        }
    }
}
