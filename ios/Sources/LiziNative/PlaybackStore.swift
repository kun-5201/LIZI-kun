import AVFoundation
import Combine
import Foundation

/// 播放状态机（P1 填实）：AVPlayer 封装 + 队列 + 取链编排器。
///
/// 取链编排（照抄壳版 public/player.js fetchTrackUrl 的顺序）：
/// - 有会员（已登录 AND 有 VIP 信号）→ 平台官方 → 已登录个人云盘 → LX
/// - 没会员（没登录 / 登录了但没会员 / 状态取不到）→ LX 先 → 平台 → 云盘
///   （r31：提示音兜底已删，全失败直接报错，保持静默，不出声）
///   （LX 先是为了拿整首：没会员时官方常只给 30 秒试听；LX 拿不到再回官方，
///   但 VIP 歌的试听地址直接拒掉，不放试听片段）
/// - 波点：r26 起走 LX（bd 映射已开；但今天没有任何已注册源声明
///   bd，所以波点 LX 目前仍无可用源——有声明 bd 的自定义源加入后才真通，
///   见 LX.swift）。Apple Music：LX 生态里没有它的源，永远走老顺序
///   （公开 API 30 秒试听）；本地文件直接播文件 URL。
///
/// 第 16 轮教训：崩溃点在取到资源之后、播放启动那一段——播放启动路径
/// **不要留强制解包**，每一步调 `DiagLog.recordPlaybackStep`（文件落盘）。
/// 音频会话：AVAudioSession .playback 独占（不设 mixWithOthers），第一次真正
/// 播放时才激活（照抄壳版 ContentView 的做法，避免打开 App 就抢走别的 App 的声音）。
///
/// 第 22 轮第 5 件（照 Moumusic PlayerService）：状态全在 @MainActor 上——
/// 之前刻意不用 @MainActor（App.init 同步创建、远程命令闭包非隔离），但旧任务
/// 与新任务打架正是这么来的：非隔离的 store 任由旧 resolve / 旧歌词任务
/// 在新一代点播后继续改状态。Moumusic 的三件套是 PlayerService、NowPlayingManager、
/// AccountStore 全 @MainActor；这里同款：PlaybackStore、NowPlayingCoordinator
/// 全 @MainActor（r28：灵动岛已移除，岛协调器已删）。
/// App.init 里用 MainActor.assumeIsolated
/// 接线（启动本来就在主线程）；远程命令回调早已是 Task { @MainActor in }。
@MainActor
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
    /// r28：取链失败原因是登录时要弹登录入口的平台（目前只有酷狗会出
    /// reason "login"；nil = 不弹）。播放页读它弹
    /// `LoginSheetView(platform:)`（酷狗走 `FoliaKugouLoginView` 二维码），
    /// 关弹窗/登录成功后由调用方调 `dismissLoginPrompt()` 清掉；新点播
    /// 与停播时这里自动清。登录成功不自动重播——用户回播放页再点一次。
    @Published private(set) var loginPromptPlatform: String?
    /// 当前曲目的实际音质档位（显示音质 = 这个，绝不显示请求的档位）。
    @Published private(set) var actualQuality: AudioQuality?
    /// 当前歌词行（官方 → LRCLIB；无词时为空，UI 显示歌名）。
    @Published private(set) var lyrics: [LyricLine] = []
    /// 当前歌词行下标；无词 / 还没开始时为 -1。
    @Published private(set) var currentLyricIndex: Int = -1
    /// 循环模式（顺序 / 全部循环 / 单曲循环；随机是独立开关）。
    @Published private(set) var repeatMode: RepeatMode = .off
    /// 随机播放开关。
    @Published private(set) var isShuffled: Bool = false
    /// 应用内音量（0…1；只对本 App 的 AVPlayer 生效，不动系统音量；
    ///   当次会话有效，不持久化，重启回 1.0）。静音时 player.volume 为 0，
    ///   `volume` 本身保留静音前的档位，取消静音即恢复。
    @Published private(set) var volume: Double = 1.0
    /// 是否静音（单独的 UserDefaults 键持久化，不走 SettingsStore）。
    @Published private(set) var isMuted: Bool = false
    /// 用户选的请求档位（默认无损；EQ 页 P4 负责改这里）。
    @Published private(set) var preferredQuality: AudioQuality = .lossless

    enum RepeatMode: String, Codable, CaseIterable {
        case off    // 顺序播完停
        case all    // 全部循环
        case one    // 单曲循环
    }

    // MARK: - 内部

    private let player = AVPlayer()
    /// r29 task 1：Apple Music 整首播放引擎（applicationMusicPlayer）。
    /// r30（r29 闪退二次调查 D2）：改懒创建——r29 是启动时就建
    /// AppleMusicPlayer（init 里 beginGeneratingPlaybackNotifications +
    /// 两个通知订阅），每次非 AM 点播还调一次 stop()；6 个非 AM 平台
    /// 本不该碰 MediaPlayer 半下。现在只有 Apple Music 全曲真正起播
    /// 时才建，非 AM 全程不建、不调、不订阅。
    private var appleMusicPlayer: AppleMusicPlayer?
    /// 当前是否走 Apple Music 整首引擎（true 时 pause/resume/seek/进度都走它，
    /// AVPlayer 那边是停着的；切到非 AM 的歌 / 回落试听时清掉）。
    private var usingAppleMusicPlayer = false
    private let proxyLoader = AudioProxyLoader()
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemObservers: [NSObjectProtocol] = []
    /// 取链代际（第 22 轮第 5 件，照 Moumusic PlayerService.resolveGeneration）：
    /// 唯一的代际计数器，放在取链的 owner（PlaybackStore）这里，不各处各建。
    /// advanceGeneration() +1 并取消在飞的取链/歌词任务；取链链路的每一步
    /// await 之后都查 gen == resolveGeneration，对不上就退，不碰状态。
    /// currentPlayGeneration 是它的快照——开始播当前这首歌的那一代：
    /// 切台只 bump resolveGeneration，不动它，所以已在播的歌的生命周期
    /// （startItem / item 回调 / 失败兜底 / 播完切歌）不受切台影响，继续播；
    /// 取链链路（resolveURL 各腿、歌词）认 resolveGeneration，切台中途的
    /// 取链作废（见 advanceGeneration 注释的行为说明）。
    private(set) var resolveGeneration = 0
    /// 开始播当前这首歌的那一代（playCurrent 入口时置为当时的 resolveGeneration）。
    private var currentPlayGeneration = 0
    /// 在飞的点播任务（r20 集成 L①：`playCurrent` 的 resolve 段包进可存取的
    /// Task；新点播先取消旧的，旧任务的 resolve 被取消后立刻向上抛
    /// CancellationError，不再攒出多个无返回的挂死调用；取消时记一条
    /// `resolve superseded` 面包屑。next()/previous() 都走 play()，
    /// 所以这里是唯一的取消点）。
    private var playTask: Task<Void, Never>?
    /// 在飞的歌词任务（第 22 轮第 5 件，照 Moumusic lyricsTask：新点播 /
    /// 切台时 advanceGeneration() 一并取消；回来时还要再查代际，旧词
    /// 绝不盖到新歌头上。歌词只给播放页用，r28 已移除灵动岛）。
    private var lyricsTask: Task<Void, Never>?
    /// playTask 引用的那一代（defer 里只清自己这一代，不清新任务）。
    private var playTaskGen = 0
    /// 当前这代 playCurrent 是否正在跑（defer 里按代际清）。
    private var playCurrentActive = false
    /// 真正开始播放的那首歌（startItem 里 player.play() 之后才置；锁屏动态
    /// 封面只认它，不认“切歌了”——第 21 轮第 3 件：Route A/B 的准备工作
    /// 等它置起才启动，不再和挂死的 LX 取链挤在同一个窗口里）。
    @Published private(set) var startedTrackId: String?
    private var lastFetchVia: String = ""
    private var lastFetchReason: String = ""
    private var proxyTried = false
    private var fallbackRetried = false
    /// r26：LX 死链降档重试只做一次（见 handlePlaybackFailure 2a）。
    private var lxDowngradeRetried = false
    private var currentAssetURL: URL?
    private var audioSessionActivated = false
    private var wasPlayingBeforeInterruption = false
    /// 首次进度回调是否已记过面包屑（每首歌在 startItem 里清零；它是
    /// “声音真的出来了”的唯一落盘证据——play called 只证明调了 play）。
    private var didRecordFirstTimeUpdate = false

    private static let likedKey = "lizi.native.likedTrackIds"
    /// 喜欢身份 = id + platform 复合键（r25-B2：单用曲目 id 时跨平台数字 id
    /// 撞号，爱心与 liked rail 各说各话）。UserDefaults 里存
    /// "platform\u{1f}id" 字符串（\u{1f} 是控制字符，平台名与曲目 id 里
    /// 不会出现；键名仍是 lizi.native.likedTrackIds，HomeViewModel
    /// refreshLikedCount 只数条数，条数语义不变）。
    /// 旧单键数据见 init 里的 migrateLegacyLikedKeys()：likedTracks 里有
    /// 同一 id 的完整曲目就认它的 platform 补键，认不出就丢弃并记日志，不崩。
    private static let mutedKey = "lizi.native.player.isMuted"
    /// P2：星标完整曲目（[Track] JSON；liked rail 用）。旧的 id 集合键不动，
    /// 保证兼容——P2 之前点的星标只有 id、没有曲目详情，恢复不出来，
    /// 不编假曲目；重新点一次星标（取消再点）后才有完整记录。
    private static let likedTracksKey = "lizi.native.likedTracks"
    private static let qualityKey = "lizi.native.quality"
    /// r22：随机与循环重启后保留（与队列面板头部同一套状态，控制行两端按钮共用）。
    private static let repeatModeKey = "lizi.native.repeatMode"
    private static let shuffleKey = "lizi.native.isShuffled"
    /// 喜欢复合键集合（存 "platform\u{1f}id"；读到旧单键格式时
    /// migrateLegacyLikedKeys() 已在 init 里迁过，这里只认复合键）。
    private var likedIds: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: Self.likedKey) ?? []
            return Set(arr)
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.likedKey) }
    }

    /// 一首曲目的喜欢复合键。
    static func likeKey(for track: Track) -> String {
        "\(track.platform)\u{1f}\(track.id)"
    }

    /// 复合键是否合法（必须恰好含一个 \u{1f} 分隔符且两边非空）。
    private static func isCompositeLikeKey(_ key: String) -> Bool {
        let parts = key.components(separatedBy: "\u{1f}")
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    /// 旧单键喜欢数据迁移（init 里跑一次）：r25 之前 likedKey 存的是裸曲目 id，
    /// 平台未知。逐条认：likedTracks（完整曲目，带 platform）里有同一 id 的，
    /// 就按它的 platform 补成复合键；没有的丢弃（平台猜不出来，不编），
    /// 记一条 DiagLog（迁入数 / 丢弃数）。已是复合键的条目原样保留。
    /// 迁移后 likedTracks 本身不动（rail 仍按 platform 过滤读它）。
    private func migrateLegacyLikedKeys() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.likedKey) ?? []
        guard raw.contains(where: { !Self.isCompositeLikeKey($0) }) else { return }
        let known = Self.likedTracks()
        var kept = Set<String>()
        var migrated = 0
        var dropped = 0
        for entry in raw {
            if Self.isCompositeLikeKey(entry) {
                kept.insert(entry)
                continue
            }
            if let track = known.first(where: { $0.id == entry }) {
                kept.insert(Self.likeKey(for: track))
                migrated += 1
            } else {
                dropped += 1
            }
        }
        UserDefaults.standard.set(Array(kept), forKey: Self.likedKey)
        DiagLog.shared.recordPlaybackStep(
            "liked migrate legacy migrated=\(migrated) dropped=\(dropped) (dropped: old single-key ids with no matching liked track; platform unknown, not guessed)")
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.qualityKey),
           let q = AudioQuality(rawValue: raw) {
            preferredQuality = q
        }
        // r25-B2：旧单键喜欢数据迁移（只认 likedTracks 里能对上 id 的，
        // 认不出就丢弃并记日志，见 migrateLegacyLikedKeys）。
        migrateLegacyLikedKeys()
        // r25-B2 #4：静音状态恢复（自己的键，不走 SettingsStore）；
        // 音量当次会话有效，不持久化，重启回 1.0。
        isMuted = UserDefaults.standard.bool(forKey: Self.mutedKey)
        player.volume = isMuted ? 0 : Float(volume)
        // r22：随机与循环重启后保留（缺省：顺序、不随机；旧值非法时同样回落缺省）。
        if let raw = UserDefaults.standard.string(forKey: Self.repeatModeKey),
           let mode = RepeatMode(rawValue: raw) {
            repeatMode = mode
        }
        isShuffled = UserDefaults.standard.bool(forKey: Self.shuffleKey)
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
        if queue.indices.contains(currentIndex) {
            play(queueItem: queue[currentIndex])
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
            // r25-B2 U6：按 queueId 播（不用 play(track)，重复曲目会播错行）。
            play(queueItem: queue[currentIndex])
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

    /// 代际 +1，并取消所有进行中的取链/歌词任务（第 22 轮第 5 件，照
    /// Moumusic PlayerService 1219–1221 行一次全 cancel + 1260 行代际+1）。
    /// 唯一的代际入口：play()（新点播）、HomeViewModel.selectPlatform
    /// （切台，G1）、stop()（清空/停播，免得在飞的取链在停播后又把歌起播）
    /// 都走这里，不各自加一、不各自取消。
    /// 只取消在飞任务：不停已在播的音频（player 不动）、不清队列
    /// （queue / currentIndex 不动）、不动 currentPlayGeneration
    /// （已在播那首歌的生命周期继续走完，见 resolveGeneration 注释）。
    /// 行为说明（切台时）：切台瞬间正在取链的那首点播会被取消、不会出声，
    /// 需重按——这是代际契约本身（旧 resolve 作废），不是静默失败；
    /// 已在播的歌不受影响，继续播完、播完正常切下一首。
    func advanceGeneration() {
        resolveGeneration += 1
        if let old = playTask, !old.isCancelled {
            old.cancel()
        }
        lyricsTask?.cancel()
        lyricsTask = nil
        DiagLog.shared.recordPlaybackStep("resolve generation advanced gen=\(resolveGeneration)")
    }

    /// 播放指定曲目（不在队列里时先把它设为单首队列）。
    /// 注意：只按 id+platform 找第一个匹配项；队列里同一首歌出现多次时
    /// 点指定行请用 play(queueItem:)（按 queueId 定位），否则点第二行
    /// 会播成第一行（r25-B2 U6）。
    func play(_ track: Track) {
        if let idx = queue.firstIndex(where: { $0.track.id == track.id && $0.track.platform == track.platform }) {
            currentIndex = idx
        } else {
            queue = [QueueItem(track: track)]
            currentIndex = 0
        }
        startCurrentTrackPlay()
    }

    /// 按队列项播放（r25-B2 U6）：按 queueId 定位，队列里有重复曲目时
    /// 点第几行就播第几行。queueId 全程稳定（QueueItem 生成时一次定死，
    /// setQueue / appendToQueue 都不改它；removeFromQueue / clearQueue
    /// 只删项，不重排剩余项的 queueId）。该项已不在队列里（刚被删）时
    /// 退回按曲目播，不静默失败。
    func play(queueItem: QueueItem) {
        guard let idx = queue.firstIndex(where: { $0.queueId == queueItem.queueId }) else {
            play(queueItem.track)
            return
        }
        currentIndex = idx
        startCurrentTrackPlay()
    }

    /// 新点播的公共起播段（play(_:) / play(queueItem:) 共用；调用前
    /// currentIndex 必须已定位好）。代际 + 看门狗 + 起 playCurrent 任务。
    private func startCurrentTrackPlay() {
        guard let track = currentQueueTrack else { return }
        // r20 集成 L① + 第 22 轮第 5 件（Moumusic startPlaying 同款）：
        // 新点播先 advanceGeneration()：代际 +1，取消旧的在飞任务
        // （旧 resolve 被取消后立刻向上抛 CancellationError，不再攒出
        // 多个无返回的挂死调用），再起新任务。
        // r21a：superseded 只在旧任务真正在飞时才记（见 playCurrentActive
        // 注释）；`play tap` 每次都记（带 gen）——下次诊断里 5 次尝试若全是
        // “play tap priorInFlight=false 且无 superseded”，就是每次都是
        // 新进程（崩了重进），不是同进程重按。
        let wasInFlight = playCurrentActive
        advanceGeneration()
        let gen = resolveGeneration
        if wasInFlight {
            DiagLog.shared.recordPlaybackStep("resolve superseded source=\(track.platform) id=\(track.id)")
        }
        playTaskGen = gen
        DiagLog.shared.recordPlaybackStep("play tap source=\(track.platform) id=\(track.id) priorInFlight=\(wasInFlight) gen=\(gen)")
        // 第 22 轮第 5 件：看门狗——playCurrent 的第一步 "play start" 是
        // 在 Task 里记的；主线程若在 tap 到 Task 启动之间卡死（04:22 诊断：
        // tap 后 14 秒零记录），没有任何任务能记下这一步。看门狗跑在 detached
        // 后台任务里（不依赖主线程），3 秒 / 8 秒后各查一次面包屑里有没有
        // 这一代的 "play start source="；没有就记一笔，下次诊断直接分清
        // “主线程卡死”还是“playCurrent 里某一步 trap”。已启动就静默。
        Task.detached {
            for waitSeconds in [3, 8] {
                try? await Task.sleep(nanoseconds: UInt64(waitSeconds) * 1_000_000_000)
                let crumbs = (DiagLog.shared.json()["playbackBreadcrumb"] as? [String]) ?? []
                let started = crumbs.contains {
                    $0.contains("play start source=") && $0.contains("gen=\(gen)")
                }
                if started { break }
                DiagLog.shared.recordPlaybackStep("play start MISSING after \(waitSeconds)s gen=\(gen) (main stall suspected)")
            }
        }
        playTask = Task { @MainActor in await playCurrent(gen: gen) }
    }

    /// 恢复播放（按当前引擎分流：AM 整首引擎 / AVPlayer）。
    func resume() {
        guard currentTrack != nil else { return }
        activateSessionOnce()
        if usingAppleMusicPlayer {
            appleMusicPlayer?.resume()
        } else {
            player.play()
        }
        isPlaying = true
    }

    /// 暂停（锁屏系统卡保留暂停态；r28 已移除灵动岛，无活动可 end）。
    /// AM 引擎播完队列后无当前曲目：resume 已无东西可续，引擎就此脱离，
    /// 后续 resume 走 AV 路径（不编一次从头重播）。
    func pause() {
        if usingAppleMusicPlayer {
            appleMusicPlayer?.pause()
            if appleMusicPlayer?.nowPlayingStoreID == nil {
                stopAppleMusicEngine()
            }
        } else {
            player.pause()
        }
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
        if queue.indices.contains(currentIndex) { play(queueItem: queue[currentIndex]) }
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
        if queue.indices.contains(currentIndex) { play(queueItem: queue[currentIndex]) }
    }

    /// 喜欢/取消喜欢当前曲目（持久化到 UserDefaults；锁屏星标由 NowPlayingCoordinator 同步）。
    /// P2：id 集合之外，同时持久化完整 Track（liked rail 直接读，不用再反查）。
    /// r25-B2：喜欢身份是 id+platform 复合键（likeKey(for:)），三处同步：
    /// 这里、likedIds 存取、playCurrent 里的 isLiked 赋值；liked rail
    /// （RailsBridge 读 likedTracks() 再按 platform 过滤）本身已是 Track
    /// 全量 + platform，无需改。
    func toggleLike() {
        guard let track = currentTrack else { return }
        let key = Self.likeKey(for: track)
        var ids = likedIds
        if ids.contains(key) { ids.remove(key) } else { ids.insert(key) }
        likedIds = ids
        isLiked = ids.contains(key)
        var tracks = Self.likedTracks()
        if ids.contains(key) {
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

    /// 跳到指定进度（秒；按当前引擎分流）。
    func seek(to time: TimeInterval) {
        if usingAppleMusicPlayer {
            appleMusicPlayer?.seek(to: time)
            progress = max(0, min(time, duration))
            return
        }
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let target = CMTime(seconds: max(0, min(time, duration)), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.progress = time }
        }
    }

    /// 循环模式切换（顺序 → 全部循环 → 单曲循环；r22：切完即写盘，重启保留）。
    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        UserDefaults.standard.set(repeatMode.rawValue, forKey: Self.repeatModeKey)
    }

    /// 随机开关（r22：切完即写盘，重启保留）。
    func setShuffled(_ on: Bool) {
        isShuffled = on
        UserDefaults.standard.set(on, forKey: Self.shuffleKey)
    }

    /// 请求档位（EQ 页 P4 改这里；显示的永远是实际返回档位，不是这个）。
    func setPreferredQuality(_ q: AudioQuality) {
        preferredQuality = q
        UserDefaults.standard.set(q.rawValue, forKey: Self.qualityKey)
    }

    // MARK: - 应用内音量 / 静音（r25-B2 #4）

    /// 设应用内音量（0…1；只改本 App 的 AVPlayer 音量，不动系统音量；
    /// 当次会话有效，不持久化）。拖动滑条到 >0 时自动取消静音（静音键
    /// 仍是独立开关，见 setMuted）。
    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        if volume > 0, isMuted {
            isMuted = false
            UserDefaults.standard.set(false, forKey: Self.mutedKey)
        }
        player.volume = Float(volume)
    }

    /// 设静音（状态用自己的 UserDefaults 键持久化，不走 SettingsStore）。
    /// 静音只把 player.volume 置 0，`volume` 本身保留，取消静音即恢复。
    func setMuted(_ muted: Bool) {
        isMuted = muted
        UserDefaults.standard.set(muted, forKey: Self.mutedKey)
        player.volume = muted ? 0 : Float(volume)
    }

    /// 静音开关。
    func toggleMute() {
        setMuted(!isMuted)
    }

    /// 停止（播完 / 清空队列用；r28 已移除灵动岛，无需 end 任何活动）。
    /// 第 22 轮第 5 件：停播先 advanceGeneration()——在飞的取链若不作废，
    /// 它 resolve 回来还会调 startItem 把歌重新起播，停播等于没停。
    func stop() {
        advanceGeneration()
        stopAppleMusicEngine()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isLoading = false
        loginPromptPlatform = nil
        progress = 0
        currentTrack = nil
    }

    /// 停掉 Apple Music 整首引擎（切歌到非 AM / 回落试听 / 停播时调）；
    /// 不动队列与当前曲目，只清引擎标记。
    private func stopAppleMusicEngine() {
        appleMusicPlayer?.stop()
        usingAppleMusicPlayer = false
    }

    /// 关掉登录提示信号（登录弹窗关掉 / 登录成功后调用方调；不碰播放状态）。
    func dismissLoginPrompt() {
        loginPromptPlatform = nil
    }

    // MARK: - 播放主流程（第 16 轮教训：全程无强制解包）

    private func playCurrent(gen: Int) async {
        guard let track = currentQueueTrack else { return }
        playCurrentActive = true
        defer {
            // 只清自己这一代：旧任务被取消后 unwind 时，新任务的引用已就位，
            // 不能把新任务的 playTask 也清掉（否则下次重按取消不到它，
            // superseded 面包屑也丢了——正是 02:54 诊断要分清的那种情况）。
            if playTaskGen == gen {
                playCurrentActive = false
                playTask = nil
            }
        }
        currentPlayGeneration = gen
        proxyTried = false
        fallbackRetried = false
        lxDowngradeRetried = false
        // 第 22 轮第 5 件：入口第一步就记 "play start"（带 gen）——之前它
        // 记在 @Published 赋值之后，tap→entry 之间是黑洞；现在分两步：
        // entry（Task 调度到了）与 state set（赋值完成），死在哪一段
        // 下次诊断直接看得到；看门狗（play() 里）就查这一句。
        DiagLog.shared.recordPlaybackStep("play start source=\(track.platform) id=\(track.id) gen=\(gen)")
        isLoading = true
        errorMessage = nil
        loginPromptPlatform = nil
        actualQuality = nil
        progress = 0
        duration = track.durationSeconds
        currentTrack = track
        isLiked = likedIds.contains(Self.likeKey(for: track))
        lyrics = []
        currentLyricIndex = -1
        DiagLog.shared.recordPlaybackStep("play state set source=\(track.platform) id=\(track.id) gen=\(gen)")

        // 歌词并行拉（不阻塞取链；句柄留给 advanceGeneration() 取消，
        // 回来时再查代际，旧词绝不盖到新歌头上）。
        lyricsTask = Task { @MainActor in
            let parsed = await NativeBridge.lyrics(for: track)
            guard gen == self.resolveGeneration, !Task.isCancelled else { return }
            self.lyrics = parsed.lines
            self.currentLyricIndex = LyricsParser.currentLineIndex(lines: parsed.lines, atMs: 0)
        }

        // r29 task 1：Apple Music 全曲播放（条件：applemusic + Apple ID
        // 已登录 + 订阅有效 + store id 非空；readyForFullPlayback 里
        // 订阅缓存过期时先现验一次，重启后也能直接播整首）。起播成功
        // 直接 return，不走 30 秒试听链；失败（起播失败等）回落到现有
        // resolveURL → AVPlayer 试听流程，绝不崩、绝不卡在 isLoading。
        // r30（D2 限流）：AM 分支只在 Apple Music 平台才进——非 AM 的歌
        // 连 readyForFullPlayback 都不调；停 AM 引擎也只在上一首真走
        // AM 引擎时（usingAppleMusicPlayer）才调。非 AM 点播路径至此
        // 与 r28 一字相同，全程不碰 MediaPlayer。
        if track.platform == "applemusic",
           await AppleMusicAuth.shared.readyForFullPlayback(track: track) {
            if await startAppleMusicTrack(track: track, gen: gen) { return }
            DiagLog.shared.recordPlaybackStep("am fulltrack fallback to preview source=\(track.platform) id=\(track.id) gen=\(gen)")
        }
        // 非 AM 全曲路径：先停掉另一个播放器（AM 引擎可能还在播上一首 AM 的歌）。
        // r30：只有真走过 AM 引擎时才停；没建过引擎时不调 stop()。
        if usingAppleMusicPlayer {
            stopAppleMusicEngine()
        }

        let result = await resolveURL(for: track, gen: gen)
        // 第 22 轮第 5 件：resolve 回来先查代际（Moumusic 同款守卫）——
        // 新一代已来 / 任务已取消时直接退，不碰状态、不起播；之前这里
        // 只有 token 检查且静默 return，死在取链里时诊断里看不出是哪一代。
        guard gen == resolveGeneration, !Task.isCancelled else {
            DiagLog.shared.recordPlaybackStep("resolve stale gen=\(gen) current=\(resolveGeneration) source=\(track.platform) id=\(track.id)")
            return
        }
        guard let result, let url = result.url else {
            // 取链全失败：直接报错（r31：提示音兜底已删，失败即静默报错，不出声）。
            isLoading = false
            isPlaying = false
            errorMessage = result?.reason ?? "unavailable"
            lastFetchReason = result?.reason ?? "unavailable"
            // r28：酷狗取链报 login 时立登录提示信号（播放页据此弹二维码
            // 登录入口；其它原因不立，不把每种失败都变成登录弹窗）。
            loginPromptPlatform = lastFetchReason == "login" ? track.platform : nil
            DiagLog.shared.recordPlaybackStep("resolve url FAIL source=\(track.platform) id=\(track.id) reason=\(lastFetchReason)")
            return
        }
        lastFetchVia = result.via
        lastFetchReason = result.reason
        actualQuality = result.actualQuality
        if result.isTrial || result.isPreview {
            currentTrack?.isTrial = true
        }
        DiagLog.shared.recordPlaybackStep("url ok source=\(track.platform) id=\(track.id) via=\(result.via) scheme=\(url.scheme ?? "-")")

        activateSessionOnce()
        await startItem(url: url, track: track, gen: gen)
    }

    /// 把地址交给 AVPlayer 并起播（token 抢占丢弃点 + 状态观察都落在这里）。
    /// 第 21 轮第 3 件：取链成功之后、真正开始播放那一刻的每一步都有落盘
    /// 面包屑（startItem begin / set src / play called / item ready /
    /// item failed / 首次进度），崩在播放启动段时下次诊断直接定位到步；
    /// 非 http(s)/代理/file 的地址直接拒掉（LX 只回 http(s)，平台只回
    /// http(s)，本地文件是 file——别的 scheme 进 AVPlayer 没有意义，
    /// 只会把失败推迟到 item failed，还不如在这里明说）。
    private func startItem(url: URL, track: Track, gen: Int) async {
        // 播放生命周期认 currentPlayGeneration（开始播那首歌的那一代），
        // 不认 resolveGeneration——切台只 bump 后者，已起播的歌不受影响。
        guard gen == currentPlayGeneration else { return }
        DiagLog.shared.recordPlaybackStep("startItem begin source=\(track.platform) id=\(track.id) via=\(lastFetchVia) scheme=\(url.scheme ?? "-")")
        guard url.scheme == "http" || url.scheme == "https"
                || url.scheme == AudioProxyLoader.scheme || url.isFileURL else {
            DiagLog.shared.recordPlaybackStep("startItem bad scheme source=\(track.platform) id=\(track.id) scheme=\(url.scheme ?? "-")")
            isLoading = false
            isPlaying = false
            errorMessage = "unavailable"
            return
        }
        currentAssetURL = url
        let asset: AVURLAsset
        if url.scheme == AudioProxyLoader.scheme {
            asset = AVURLAsset(url: url)
            asset.resourceLoader.setDelegate(proxyLoader, queue: DispatchQueue.main)
        } else {
            asset = AVURLAsset(url: url)
        }
        let item = AVPlayerItem(asset: asset)
        observe(item: item, gen: gen)
        DiagLog.shared.recordPlaybackStep("set src via=\(lastFetchVia) source=\(track.platform) id=\(track.id)")
        player.replaceCurrentItem(with: item)
        // r25-B2 #4：换 item 不重置 AVPlayer.volume，但这里再应用一次
        // 应用内音量/静音（静音时 0），防止任何外部复位把音量带跑。
        player.volume = isMuted ? 0 : Float(volume)
        player.play()
        DiagLog.shared.recordPlaybackStep("play called source=\(track.platform) id=\(track.id)")
        // 真正起播的信号：锁屏动态封面只认它（见 startedTrackId 注释）。
        startedTrackId = track.id
        didRecordFirstTimeUpdate = false
        isLoading = false
        isPlaying = true
    }

    // MARK: - Apple Music 整首播放（r29 task 1）

    /// 用 applicationMusicPlayer 起播一首 Apple Music 全曲。
    /// 返回 true = 已起播（调用方直接 return，不走试听链）；false =
    /// 起播失败，调用方回落 resolveURL → AVPlayer 试听。
    /// isTrial 绝不给整首播放的歌打上（全曲不是试听）；actualQuality
    /// 不填（AM 全曲的实际档位播放器不回，不编）。
    private func startAppleMusicTrack(track: Track, gen: Int) async -> Bool {
        guard gen == currentPlayGeneration else { return false }
        let storeID = AppleMusicAuth.storeID(for: track)
        guard !storeID.isEmpty else { return false }
        // 队列里从当前下标起连续的、有 store id 的 Apple Music 曲目拼成
        // AM 队列；遇到非 AM / 无 store id 的歌就断开——AM 播完这段即停，
        // onPlaybackEnded 再按 PlaybackStore 自己的队列逻辑走 next()。
        var ids: [String] = []
        for item in queue.dropFirst(max(currentIndex, 0)) {
            let sid = AppleMusicAuth.storeID(for: item.track)
            guard item.track.platform == "applemusic", !sid.isEmpty else { break }
            ids.append(sid)
        }
        guard !ids.isEmpty, ids[0] == storeID else { return false }
        // 切引擎：先停 AVPlayer 那边（两个播放器绝不同时出声）。
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        DiagLog.shared.recordPlaybackStep("am player start source=\(track.platform) id=\(track.id) storeID=\(storeID) queueCount=\(ids.count) gen=\(gen)")
        // r30（D2）：引擎懒创建——第一次 AM 全曲起播时才建 AppleMusicPlayer，
        // 之前是 PlaybackStore 启动时就建。非 AM 点播永远到不了这里。
        if appleMusicPlayer == nil { appleMusicPlayer = AppleMusicPlayer() }
        guard let amPlayer = appleMusicPlayer else { return false }
        wireAppleMusicCallbacks(gen: gen)
        let ok = await amPlayer.play(storeIDs: ids, startAt: 0)
        guard ok, gen == currentPlayGeneration else {
            DiagLog.shared.recordPlaybackStep("am player start FAIL source=\(track.platform) id=\(track.id) gen=\(gen)")
            return false
        }
        usingAppleMusicPlayer = true
        activateSessionOnce()
        startedTrackId = track.id
        didRecordFirstTimeUpdate = false
        isLoading = false
        isPlaying = true
        DiagLog.shared.recordPlaybackStep("am player started source=\(track.platform) id=\(track.id) gen=\(gen)")
        return true
    }

    /// 接 AM 播放器的三个回调（每首 AM 全曲起播时重接；回调里先查代际，
    /// 旧一代的回调绝不碰新歌的状态）。
    private func wireAppleMusicCallbacks(gen: Int) {
        // r30（D2）：引擎懒创建后这里才有实例；没建过时直接回（调用方
        // startAppleMusicTrack 已先建好，正常到不了这句）。
        guard let amPlayer = appleMusicPlayer else { return }
        amPlayer.onProgress = { [weak self] time, dur in
            guard let self else { return }
            Task { @MainActor in
                guard self.usingAppleMusicPlayer, gen == self.currentPlayGeneration else { return }
                guard time.isFinite else { return }
                if !self.didRecordFirstTimeUpdate, time > 0 {
                    self.didRecordFirstTimeUpdate = true
                    DiagLog.shared.recordPlaybackStep("am playback time update first source=\(self.currentTrack?.platform ?? "-") id=\(self.currentTrack?.id ?? "-")")
                }
                self.progress = time
                if dur.isFinite, dur > 0 { self.duration = dur }
                let idx = LyricsParser.currentLineIndex(lines: self.lyrics, atMs: Int(time * 1000))
                if idx != self.currentLyricIndex { self.currentLyricIndex = idx }
            }
        }
        amPlayer.onNowPlayingItemChanged = { [weak self] storeID in
            guard let self else { return }
            Task { @MainActor in
                guard self.usingAppleMusicPlayer, gen == self.currentPlayGeneration else { return }
                guard let storeID, !storeID.isEmpty else { return } // nil = 队列播完，等 onPlaybackEnded
                guard let current = self.currentTrack,
                      AppleMusicAuth.storeID(for: current) != storeID else { return } // 仍是当前这首
                guard let idx = self.queue.firstIndex(where: { AppleMusicAuth.storeID(for: $0.track) == storeID }) else { return }
                let track = self.queue[idx].track
                DiagLog.shared.recordPlaybackStep("am player auto-advance source=\(track.platform) id=\(track.id) gen=\(gen)")
                self.currentIndex = idx
                self.currentTrack = track
                self.progress = 0
                self.duration = track.durationSeconds
                self.isLiked = self.likedIds.contains(Self.likeKey(for: track))
                self.startedTrackId = track.id
                self.didRecordFirstTimeUpdate = false
                self.lyrics = []
                self.currentLyricIndex = -1
                self.lyricsTask?.cancel()
                self.lyricsTask = Task { @MainActor in
                    let parsed = await NativeBridge.lyrics(for: track)
                    guard gen == self.currentPlayGeneration, !Task.isCancelled else { return }
                    self.lyrics = parsed.lines
                    self.currentLyricIndex = LyricsParser.currentLineIndex(lines: parsed.lines, atMs: 0)
                }
            }
        }
        amPlayer.onPlaybackEnded = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.usingAppleMusicPlayer, gen == self.currentPlayGeneration else { return }
                DiagLog.shared.recordPlaybackStep("am player queue ended gen=\(gen)")
                if self.repeatMode == .one {
                    self.seek(to: 0)
                    self.resume()
                } else {
                    self.next()
                }
            }
        }
    }

    /// 监听当前 item 的状态与结束事件（每次换 item 都重建观察，避免旧观察串台）。
    /// 第 21 轮第 1 件：ready/failed 都落盘——之前只有失败重试链记步，
    /// item 进了播放器后是 ready 还是 failed、失败原因是什么，诊断里看不到。
    private func observe(item: AVPlayerItem, gen: Int) {
        itemStatusObservation?.invalidate()
        for o in itemObservers { NotificationCenter.default.removeObserver(o) }
        itemObservers = []
        var readyRecorded = false
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor in
                guard gen == self.currentPlayGeneration else { return }
                if item.status == .failed {
                    let reason = item.error?.localizedDescription ?? "-"
                    DiagLog.shared.recordPlaybackStep("item failed source=\(self.currentTrack?.platform ?? "-") id=\(self.currentTrack?.id ?? "-") error=\(reason)")
                    await self.handlePlaybackFailure(gen: gen)
                } else if item.status == .readyToPlay {
                    let d = item.asset.duration.seconds
                    if d.isFinite, d > 0 { self.duration = d }
                    self.isLoading = false
                    if !readyRecorded {
                        readyRecorded = true
                        DiagLog.shared.recordPlaybackStep("item ready source=\(self.currentTrack?.platform ?? "-") id=\(self.currentTrack?.id ?? "-")")
                    }
                }
            }
        }
        let endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard gen == self.currentPlayGeneration else { return }
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
                guard gen == self.currentPlayGeneration else { return }
                await self.handlePlaybackFailure(gen: gen)
            }
        }
        itemObservers = [endObserver, failObserver]
    }

    /// 地址进了播放器才发现是死的（代理 502/403、解码失败）时的重试链
    /// （照抄 player.js tryProxyFallback + retryWithFallback；
    /// r31：提示音兜底已删）：
    /// 1) 同一条地址走音频代理再试一次（每首只一次）；
    /// 2a：LX 死链降一档再试 LX（r26：QQ 的 flac24bit 链实测 403、320k
    ///   是活的；旧代码重跑同档只会拿到同一条死链，再直接报错）；
    /// 2b：按优先级往下一档重试一次（platform → cloud/LX；LX 死链且无档
    ///   可降时走平台腿——lx-first 时平台腿还没跑过，只跳 LX 不跳平台）；
    /// 3) 再失败直接报错（errorMessage 显示真正原因，保持静默，不出声）。
    private func handlePlaybackFailure(gen: Int) async {
        guard gen == currentPlayGeneration, let track = currentTrack else { return }
        // 1) 代理兜底（直链失败可能是 CDN 临时抽风 / CORS 抖动）。
        if !proxyTried, let url = currentAssetURL, url.scheme != AudioProxyLoader.scheme {
            proxyTried = true
            DiagLog.shared.recordPlaybackStep("direct play FAIL, try proxy source=\(track.platform) id=\(track.id) via=\(lastFetchVia)")
            let proxyURL = proxyLoader.proxyURL(for: url, source: track.platform)
            await startItem(url: proxyURL, track: track, gen: gen)
            return
        }
        // 2a：LX 死链降档重试（每首只一次）：实际回档往下降一档再取 LX，
        //   降档后 LX 仍是第一档（平台腿还没跑过，跳过平台/云盘，只跑 LX）。
        if lastFetchVia == "lx", !lxDowngradeRetried,
           let degraded = Self.degradedLXQuality(below: actualQuality) {
            lxDowngradeRetried = true
            let skips = SkipSet(skipPlatform: true, skipCloud: true, skipLX: false)
            DiagLog.shared.recordPlaybackStep("play FAIL, retry lx one tier down source=\(track.platform) id=\(track.id) from=\(actualQuality?.rawValue ?? "-") to=\(degraded.rawValue)")
            if let result = await resolveURL(for: track, gen: gen, skips: skips, quality: degraded),
               let url = result.url, gen == currentPlayGeneration {
                lastFetchVia = result.via
                lastFetchReason = result.reason
                actualQuality = result.actualQuality
                await startItem(url: url, track: track, gen: gen)
                return
            }
        }
        // 2b：往下一档重试一次（已证实是死的那一档直接跳过）。
        if !fallbackRetried, (lastFetchVia == "platform" || lastFetchVia == "cloud" || lastFetchVia == "lx") {
            fallbackRetried = true
            // LX 死链时走平台腿（lx-first 时平台腿还没跑过）；平台/云盘
            // 死链时走老路（跳平台、留 LX）。
            let skips = lastFetchVia == "lx"
                ? SkipSet(skipPlatform: false, skipCloud: false, skipLX: true)
                : SkipSet(skipPlatform: true,
                          skipCloud: lastFetchVia == "cloud",
                          skipLX: false)
            DiagLog.shared.recordPlaybackStep("play FAIL, retry next tier source=\(track.platform) id=\(track.id) via=\(lastFetchVia)")
            if let result = await resolveURL(for: track, gen: gen, skips: skips),
               let url = result.url, gen == currentPlayGeneration {
                lastFetchVia = result.via
                lastFetchReason = result.reason
                actualQuality = result.actualQuality
                await startItem(url: url, track: track, gen: gen)
                return
            }
        }
        // 3) r31：提示音兜底已删——全档重试耗尽后不再合成/播放任何提示音，
        // 直接落到下面的失败终态（isPlaying = false + errorMessage = 真正
        // 原因，PlayerView 红字照常显示），保持静默。
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

    /// LX 死链降档（r26）：实际回档往下降一档（LX 档位顺序 master →
    /// atmos → hires → flac24bit → 320k → 128k，按 canon 回的档位映射，
    /// 不是通用 rank——surround/spatial 在 lx canon 里不会出现）。
    /// 已是最低档（128k）/ 回档未知时回 nil，不降档，直接走平台腿。
    private static func degradedLXQuality(below actual: AudioQuality?) -> AudioQuality? {
        switch actual {
        case .master: return .spatial     // lx: master → atmos
        case .dolby: return .hires       // lx: atmos → hires
        case .hires: return .lossless     // lx: hires → flac24bit
        case .lossless: return .exhigh    // lx: flac24bit → 320k
        case .exhigh: return .standard    // lx: 320k → 128k
        default: return nil
        }
    }

    /// 取链编排（player.js fetchTrackUrl 的顺序；每一档只在上一档明确拿不到
    /// 地址时才跑）。返回 nil = 各档都拿不到（调用方按 reason 报错，不编地址）。
    /// 第 22 轮第 5 件：每腿 await 之后都查代际（Moumusic 同款守卫）——
    /// 新一代已来 / 任务已取消时立刻回 nil，不再往下烧平台请求、不把旧地址
    /// 交给新一代；7 个平台都走这同一条编排（平台腿在 NativeBridge.songURL
    /// 里按平台分，LX 腿只覆盖有 LX 解析的平台，见 lxSupported）。
    /// `quality`（r26）：只给 LX 死链降档重试用（handlePlaybackFailure
    /// 2a）；不传时 LX 腿用 preferredQuality，平台腿永远用 preferredQuality。
    private func resolveURL(for track: Track, gen: Int, skips: SkipSet = SkipSet(), quality: AudioQuality? = nil) async -> NativeBridge.SongURLResult? {
        DiagLog.shared.recordPlaybackStep("resolve start source=\(track.platform) id=\(track.id) gen=\(gen)")
        // 本地文件：地址就是文件 URL，不走 LX、不走平台接口。
        if track.platform == "local" {
            if let fileURL = LocalMusic.fileURL(id: track.id) {
                return NativeBridge.SongURLResult(url: fileURL, via: "local")
            }
            return NativeBridge.SongURLResult(reason: "unavailable", via: "local")
        }
        let lxSupported = ["netease", "qq", "kuwo", "qishui", "kugou", "bodian"].contains(track.platform)
        let member = await NativeBridge.isMember(platform: track.platform)
        guard gen == resolveGeneration, !Task.isCancelled else {
            DiagLog.shared.recordPlaybackStep("resolve stale gen=\(gen) leg=member source=\(track.platform) id=\(track.id)")
            return nil
        }
        // 没会员 → LX 先（拿整首）；有会员 → 平台先。
        // r26：LX 腿用 quality（降档重试传进来的档位）或 preferredQuality。
        let lxQuality = quality ?? preferredQuality
        let lxFirst = !skips.skipLX && lxSupported && !member
        var lastReason = ""
        if lxFirst, let lx = await NativeBridge.lxSongURL(track: track, quality: lxQuality) {
            guard gen == resolveGeneration, !Task.isCancelled else {
                DiagLog.shared.recordPlaybackStep("resolve stale gen=\(gen) leg=lx-first source=\(track.platform) id=\(track.id)")
                return nil
            }
            DiagLog.shared.recordPlaybackStep("resolve lx-first ok source=\(track.platform) id=\(track.id)")
            return lx
        }
        guard gen == resolveGeneration, !Task.isCancelled else {
            DiagLog.shared.recordPlaybackStep("resolve stale gen=\(gen) leg=lx-first source=\(track.platform) id=\(track.id)")
            return nil
        }
        if !skips.skipPlatform {
            let r = await NativeBridge.songURL(track: track, quality: preferredQuality)
            guard gen == resolveGeneration, !Task.isCancelled else {
                DiagLog.shared.recordPlaybackStep("resolve stale gen=\(gen) leg=platform source=\(track.platform) id=\(track.id)")
                return nil
            }
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
            guard gen == resolveGeneration, !Task.isCancelled else {
                DiagLog.shared.recordPlaybackStep("resolve stale gen=\(gen) leg=cloud source=\(track.platform) id=\(track.id)")
                return nil
            }
            DiagLog.shared.recordPlaybackStep("resolve cloud ok id=\(track.id)")
            return cloud
        }
        guard gen == resolveGeneration, !Task.isCancelled else {
            DiagLog.shared.recordPlaybackStep("resolve stale gen=\(gen) leg=cloud source=\(track.platform) id=\(track.id)")
            return nil
        }
        if !lxFirst, !skips.skipLX, lxSupported,
           let lx = await NativeBridge.lxSongURL(track: track, quality: lxQuality) {
            guard gen == resolveGeneration, !Task.isCancelled else {
                DiagLog.shared.recordPlaybackStep("resolve stale gen=\(gen) leg=lx-fallback source=\(track.platform) id=\(track.id)")
                return nil
            }
            DiagLog.shared.recordPlaybackStep("resolve lx fallback ok source=\(track.platform) id=\(track.id)")
            return lx
        }
        return NativeBridge.SongURLResult(reason: lastReason.isEmpty ? "unavailable" : lastReason,
                                          via: "platform")
    }

    /// r27 下载用：复用播放取链整条编排（resolveURL：官方 → 云盘 → LX；
    /// 取链全失败时只回失败原因、不回地址，下载按失败处理）。
    /// 不推进代际（不取消在播任务）：用当前 resolveGeneration 快照；
    /// 取链中途切歌导致代际变化时 resolveURL 因 gen 对不上回 nil，
    /// 下载按失败处理，用户重试。质量走 preferredQuality（resolveURL 内定）。
    func resolveURLForDownload(track: Track) async -> NativeBridge.SongURLResult? {
        await resolveURL(for: track, gen: resolveGeneration, quality: preferredQuality)
    }

    // MARK: - 进度（AVPlayer periodic time observer 驱动）

    private func handleTimeUpdate(_ time: CMTime) {
        // AM 整首引擎期间进度由 AppleMusicPlayer 的 0.5s timer 推，这里不碰。
        guard !usingAppleMusicPlayer else { return }
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        if !didRecordFirstTimeUpdate, seconds > 0 {
            didRecordFirstTimeUpdate = true
            DiagLog.shared.recordPlaybackStep("playback time update first source=\(currentTrack?.platform ?? "-") id=\(currentTrack?.id ?? "-")")
        }
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
