import Combine
import Foundation
import MediaPlayer
import UIKit

/// 锁屏 / 控制中心接线（P1 新写）：MPNowPlayingInfoCenter + MPRemoteCommandCenter。
///
/// 照抄壳版 ContentView 的做法：
/// - Now Playing 写标题/歌手/时长/进度/封面 + iOS 26 动态封面挂接
///   AnimatedArtworkManager（「动画插图」开关默认开，关 = 锁屏回静态图；
///   开关存 UserDefaults `lizi.animatedArtwork`，默认 true）；
/// - 远程命令：play / pause / next / previous / togglePlayPause / like 开，
///   skipBackward / skipForward 强制关（removeTarget + isEnabled=false）；
/// - 每轮复核 reassert（重复 addTarget 会让一次按键触发多次，所以每次先
///   removeTarget 再 addTarget；壳版是每 2 秒 poll 复核一次，这里在状态变化 +
///   最多每 5 秒复核一次——原生没有 WebKit 重建 Now Playing 的问题，复核是防
///   系统回落到 ±10 秒的保险）。
///
/// 注意：刻意不用 @MainActor（见 PlaybackStore 的注释）——远程命令的回调闭包
/// 是非隔离的，直接调 store 的方法；主线程执行由 Task { @MainActor in } 保证。
/// 第 22 轮第 5 件（照 Moumusic NowPlayingManager）：@MainActor——
/// Now Playing 信息与封面只在主线程上变，不再和取链任务跨线程打架。
@MainActor
final class NowPlayingCoordinator: ObservableObject {
    private weak var store: PlaybackStore?
    private var cancellables: Set<AnyCancellable> = []

    /// 「动画插图」开关（默认开；关 = 整个动态封面跳过，锁屏回静态图）。
    var animatedArtworkEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.animatedArtworkKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.animatedArtworkKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.animatedArtworkKey) }
    }
    private static let animatedArtworkKey = "lizi.animatedArtwork"

    private var lastArtwork: MPMediaItemArtwork?
    /// lastArtwork 属于哪首歌（r20：之前只凭 lastTrackId == track.id 认，
    /// 但 lastTrackId 在 writeNowPlaying 末尾就先推进到新歌、封面下载还没完，
    /// 5 秒进度复写会在新歌下载窗口里把上一首的静态图挂到新歌头上——
    /// 静态图没有“上一首兜底”的需求，错挂就是错歌的封面，必须按归属认）。
    private var lastArtworkTrackId: String?
    private var lastCoverURL: String?
    private var lastCoverKey: String?
    /// r49 R1：上一次成功挂进 nowPlayingInfo 的路线 A 动态键（本歌 own-A
    /// 或上一首 fallback-A 都记）。本歌视频未就绪时 writeNowPlaying 不再
    /// 把动态键从 info 里拿掉，而是保留这把键、只更新标题/进度/静态图，
    /// 等 onReady 回调再写一次换成本歌视频——同一首歌挂载只 none → A 单调，
    /// 绝不 A → none。
    private var lastMountedAnimKey: String?
    /// r50：第 3 件——回退（上一首的旧视频）只在「本歌视频正在生成」的
    /// 短暂过渡内用，每首歌最多 30 秒（渲染正常几秒到二十秒，见
    /// AnimatedArtworkManager 的注释；10 秒封面重试 + 慢渲染也基本
    /// 在窗内）。超时本歌仍未就绪就不再挂旧视频，改回静态封面，等
    /// onReady 再换成本歌——挂错歌的画面比静态更错。上一轮「绝不
    /// A→none」只对本歌 own-A 成立，不保护回退键。
    private static let fallbackWindowSeconds: TimeInterval = 30
    /// 当前这首歌第一次挂上回退键的时间（换歌时清掉；同一首歌内绝不
    /// 刷新，否则窗口永远不到期）。
    private var fallbackMountTrackId: String?
    private var fallbackMountStartedAt: Date?
    /// 已对哪首歌记过一次「回退过期」（每首只记一次，别让 5 秒进度复写刷屏）。
    private var fallbackExpiredLoggedTrackId: String?
    private var lastTrackId: String?
    private var lastPlaying: Bool = false
    private var lastReassertAt: Date = .distantPast
    /// 挂载诊断上次记过的值（只在曲目或挂载结果变化时记，避免 5 秒进度
    /// 复写把 DiagLog（上限 100 条）刷满）。
    private var lastMountDiagTrackId: String?
    private var lastMountDiagDesc: String?
    /// 封面拉取已耗尽的曲目（下载失败 + 10 秒重试也失败）：writeNowPlaying
    /// 不再为它重拉（lastArtwork == nil 时每 5 秒进度复写都会触发重拉，
    /// 会无限重试）；切走再切回（lastTrackId 变化）仍会重拉。
    private var coverFailedTrackId: String?
    /// 第 21 轮第 3 件：动态封面准备（Route A 编码 + Route B token 抓取）
    /// 是崩溃窗口里最重的两件并发工作，原来切歌就并行启动、和挂死的 LX
    /// 挤在同一个窗口里。改成等 startedTrackId（startItem 里 player.play()
    /// 之后才置）再启动：没声之前只挂静态封面，动效晚到几秒、不丢；
    /// LX 挂死时 A/B 根本不启动，窗口里只剩取链本身。以下三件为此服务：
    /// 已对哪首歌启动过准备（每首只启动一次）、到货的封面图暂存（启动时用）、
    /// 启动入口 kickAnimatedPrepares / maybeKickAnimatedPrepares。
    private var artworkPrepareKickedTrackId: String?
    /// r49 R4：kicked 那次准备用的是哪个封面键。封面 10 秒重试成功后
    /// lastCoverKey 变了（失败那轮曾被置成 defaultKey），只凭 trackId
    /// 守门会把真封面的准备永远挡住；键变了就清掉 kicked 标记再 kick。
    private var artworkPrepareKickedKey: String?
    /// r49 R5：路线 A 生成失败后已安排过延迟重准备的键（每键最多 1 次，
    /// 避免失败反复重试烧电；键是封面 URL 的哈希，新封面不在集合里）。
    private var routeARepreparedKeys: Set<String> = []
    private var lastCoverImage: UIImage?
    private var lastCoverImageTrackId: String?

    func bind(store: PlaybackStore) {
        self.store = store
        // 切歌 / 播放切换 / 喜欢态变 → 重写 Now Playing + 复核命令。
        store.$currentTrack
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.writeNowPlaying() }
            }
            .store(in: &cancellables)
        store.$isPlaying
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.writeNowPlaying() }
            }
            .store(in: &cancellables)
        store.$isLiked
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.syncLikeCommand() }
            }
            .store(in: &cancellables)
        // 第 21 轮第 3 件：真正开始播放才启动动态封面准备（见
        // artworkPrepareKickedTrackId 注释）。startedTrackId 只在 startItem
        // 里 player.play() 之后置，LX 挂死时它永远不置，A/B 就不启动。
        store.$startedTrackId
            .sink { [weak self] id in
                guard let self, let id,
                      let track = self.store?.currentTrack, track.id == id else { return }
                Task { @MainActor in self.kickAnimatedPrepares(for: track) }
            }
            .store(in: &cancellables)
        // 进度：Now Playing 的已播时间最多每 5 秒刷新一次（太密系统会节流）。
        store.$progress
            .throttle(for: .seconds(5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.writeNowPlaying() }
            }
            .store(in: &cancellables)
        // r33：设置里「动画插图」开关（lizi.animatedArtwork）拨动时立刻重写
        // Now Playing——之前 bind 只订阅切歌/播放/进度，暂停时拨开关没有任何
        // 写操作：关掉后旧动态键一直挂在 nowPlayingInfo 里（播放时最多等 5 秒
        // 进度复写才掉，暂停时永远不掉），开/关都不同步。UserDefaults 变化就
        // 全量重写一次：writeNowPlaying 从空字典重建 info，关时动态键自然掉、
        // 静态图挂上；开时已就绪的动态视频重新挂上（没就绪的顺手补启动一次，
        // maybeKick 内部有 startedTrackId + 每首只启动一次的去重，不会多跑）。
        // 重写是幂等的：封面已到货时不重拉（lastArtwork 非空 + lastTrackId 未变
        // 不触发 fetchArtwork），远程命令也有 5 秒节流。
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.writeNowPlaying()
                    if let track = self.store?.currentTrack, self.animatedArtworkEnabled {
                        self.maybeKickAnimatedPrepares(for: track)
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Now Playing

    /// 按当前状态写一次 Now Playing（封面到货时也走这里补写）。
    func writeNowPlaying() {
        guard let store, let track = store.currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        reassertRemoteCommandsIfNeeded()
        // r20 切歌埋点：只在曲目变化的那一次记（lastTrackId 在本函数末尾才
        // 推进，后续 5 秒进度复写不再重复记）。track id / 封面 host / 本歌
        // 的 A 键与 B 键一次记全，下次真机复现直接定位到最后一步。
        let coverHost = track.coverURL?.host ?? "-"
        let aKey: String
        if let url = track.coverURL, !url.absoluteString.isEmpty {
            aKey = AnimatedArtworkManager.key(forCoverURL: url.absoluteString)
        } else {
            aKey = AnimatedArtworkManager.defaultKey
        }
        let bKey = AppleAnimatedArtworkProvider.shared.albumKey(for: track) ?? "-"
        if lastTrackId != track.id {
            // r50：换歌了，回退计时与过期记录按新歌重算（重播同一首也一样）。
            fallbackMountTrackId = nil
            fallbackMountStartedAt = nil
            fallbackExpiredLoggedTrackId = nil
            DiagLog.shared.recordLog(category: "animated-artwork",
                message: "track changed id=\(track.id) platform=\(track.platform) title=\(track.title) coverHost=\(coverHost) aKey=\(aKey) bKey=\(bKey)",
                fields: ["lane": "track-changed", "platform": track.platform, "trackId": track.id,
                         "coverHost": coverHost, "aKey": aKey, "bKey": bKey])
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPNowPlayingInfoPropertyPlaybackRate: store.isPlaying ? 1.0 : 0.0,
        ]
        if !track.artist.isEmpty { info[MPMediaItemPropertyArtist] = track.artist }
        if !track.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = track.album }
        if store.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = store.duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = store.progress
        }
        // 静态图只挂归属本歌的那一张（r20：见 lastArtworkTrackId 注释，
        // 之前按 lastTrackId 认会在新歌下载窗口里错挂上一首的静态图）。
        if let art = lastArtwork, lastArtworkTrackId == track.id {
            info[MPMediaItemPropertyArtwork] = art
        }
        // iOS 26+ 动态封面：3x4 与 1x1 两个键各自先问路线 B（Apple 官方真视频），
        // B 没挂上再走路线 A（本地生成）；两个键都挂不上才回静态。
        // 不用整段 if/else——B 竖版就绪但方形缺失的半截状态不能把 A 也挡掉（r20）：
        // r19 的写法是 B 分支一旦进入（isReady 为真）就不再试 A，B 只挂上一个键
        // 或一个键都没挂上时，另一个键本可以由 A 补上却被跳过。
        var route3x4 = "none"
        var route1x1 = "none"
        // r49 R3：实际写入的键与来源（own-A / fallback-A / own-B / none），
        // 诊断直接写挂的是哪把键、哪条路线，不再只记本歌的 aKey/bKey。
        var mountedKey3x4 = "-"
        var mountedSource3x4 = "none"
        var mountedKey1x1 = "-"
        var mountedSource1x1 = "none"
        if #available(iOS 26.0, *), animatedArtworkEnabled {
            let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
            let appleKey = AppleAnimatedArtworkProvider.shared.albumKey(for: track)
            let appleReady = appleKey.map { AppleAnimatedArtworkProvider.shared.isReady(key: $0) } ?? false
            if supported.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork) {
                if let key = appleKey, appleReady,
                   let art = AppleAnimatedArtworkProvider.shared.artwork(forKey: key, aspect: .portrait) {
                    info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = art
                    route3x4 = "B"
                    mountedKey3x4 = key
                    mountedSource3x4 = "own-B"
                } else if AnimatedArtworkManager.shared.isReady(key: aKey, aspect: .portrait),
                          let art = AnimatedArtworkManager.shared.artwork(forKey: aKey, aspect: .portrait) {
                    // r50：本歌 own-A 直查——按本歌自己的 aKey 问磁盘，不经过
                    // lastCoverKey（取封面失败时它会被置成默认键，本歌视频即使
                    // 已在磁盘也挂不上；切歌后它还是上一首的键）。磁盘已有
                    // （重播 / 上一轮已渲染好）时切歌当下就挂本歌，不用等封面
                    // 下载 + kick + onReady。
                    info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = art
                    route3x4 = "A"
                    mountedKey3x4 = aKey
                    mountedSource3x4 = "own-A"
                    lastMountedAnimKey = aKey
                } else if let animKey = animatedArtworkKeyForCurrentTrack(),
                          let art = AnimatedArtworkManager.shared.artwork(forKey: animKey, aspect: .portrait) {
                    // r50：回退键只在过渡窗内挂（见 fallbackAllowed）。本歌视频
                    // 正在生成时顶 30 秒，超时仍未就绪就不再挂旧视频，改回静态，
                    // 等 onReady 再换成本歌。
                    if fallbackAllowed(for: track.id) {
                        info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = art
                        route3x4 = "A"
                        mountedKey3x4 = animKey
                        // r49 R1：挂 A 成功时记下这把键；own 与 fallback 按本歌
                        // 自己的 aKey 认（不用 lastCoverKey——切歌后它还没翻转，
                        // 会把上一首的键误认成 own）。
                        mountedSource3x4 = (animKey == aKey) ? "own-A" : "fallback-A"
                        lastMountedAnimKey = animKey
                        if animKey != aKey { stampFallback(for: track.id) }  // r50：只有挂回退键才计时
                    } else {
                        expireFallback(for: track, key: animKey)  // r50：记一笔过期，不挂
                    }
                } else if let retained = lastMountedAnimKey,
                          let art = AnimatedArtworkManager.shared.artwork(forKey: retained, aspect: .portrait) {
                    // r49 R1：本歌视频未就绪、连回退键都没有时，不把动态键
                    // 从 info 里拿掉——保留上一次成功挂载的键，只更新标题/
                    // 歌手/进度/静态图；生成完 onReady 回调再写一次换成本歌视频。
                    // r50：保留分支同样只在过渡窗内挂——上一轮「绝不 A→none」
                    // 只对本歌 own-A 成立；挂着上一首的旧视频无限续下去不是
                    // 修好，是把错歌的画面当成本歌的。超时后改回静态。
                    if fallbackAllowed(for: track.id) {
                        info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = art
                        route3x4 = "A"
                        mountedKey3x4 = retained
                        mountedSource3x4 = "fallback-A"
                        stampFallback(for: track.id)  // r50
                    } else {
                        expireFallback(for: track, key: retained)  // r50：记一笔过期，不挂
                    }
                }
            }
            if supported.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork) {
                if let key = appleKey, appleReady,
                   let art = AppleAnimatedArtworkProvider.shared.artwork(forKey: key, aspect: .square) {
                    info[MPNowPlayingInfoProperty1x1AnimatedArtwork] = art
                    route1x1 = "B"
                    mountedKey1x1 = key
                    mountedSource1x1 = "own-B"
                } else if AnimatedArtworkManager.shared.isReady(key: aKey, aspect: .square),
                          let art = AnimatedArtworkManager.shared.artwork(forKey: aKey, aspect: .square) {
                    // r50：同 3x4，本歌 own-A 方形直查（见上）。
                    info[MPNowPlayingInfoProperty1x1AnimatedArtwork] = art
                    route1x1 = "A"
                    mountedKey1x1 = aKey
                    mountedSource1x1 = "own-A"
                    lastMountedAnimKey = aKey
                } else if let animKey = animatedArtworkKeyForCurrentTrack(),
                          let art = AnimatedArtworkManager.shared.artwork(forKey: animKey, aspect: .square) {
                    // r50：回退键只在过渡窗内挂（见 fallbackAllowed）。
                    if fallbackAllowed(for: track.id) {
                        info[MPNowPlayingInfoProperty1x1AnimatedArtwork] = art
                        route1x1 = "A"
                        mountedKey1x1 = animKey
                        mountedSource1x1 = (animKey == aKey) ? "own-A" : "fallback-A"
                        lastMountedAnimKey = animKey
                        if animKey != aKey { stampFallback(for: track.id) }  // r50：只有挂回退键才计时
                    } else {
                        expireFallback(for: track, key: animKey)  // r50：记一笔过期，不挂
                    }
                } else if let retained = lastMountedAnimKey,
                          let art = AnimatedArtworkManager.shared.artwork(forKey: retained, aspect: .square) {
                    // r49 R1：同上，1x1 槽也保留上一次成功挂载的键。
                    // r50：保留分支同样只在过渡窗内挂（见 3x4 的说明）。
                    if fallbackAllowed(for: track.id) {
                        info[MPNowPlayingInfoProperty1x1AnimatedArtwork] = art
                        route1x1 = "A"
                        mountedKey1x1 = retained
                        mountedSource1x1 = "fallback-A"
                        stampFallback(for: track.id)  // r50
                    } else {
                        expireFallback(for: track, key: retained)  // r50：记一笔过期，不挂
                    }
                }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastPlaying = store.isPlaying
        logAnimatedMountIfChanged(track: track, route3x4: route3x4, route1x1: route1x1,
                                  aKey: aKey, bKey: bKey, coverHost: coverHost,
                                  mountedKey: mountedKey3x4, mountedSource: mountedSource3x4,
                                  mountedKey1x1: mountedKey1x1, mountedSource1x1: mountedSource1x1)
        // 封面还没到货（或换歌了）就去拉，到了补写一次。封面已拉取失败耗尽的
        // 歌不再重拉（coverFailedTrackId 守门，见上）；切歌时 lastTrackId 变化
        // 仍会重拉。
        if lastTrackId != track.id || (lastArtwork == nil && coverFailedTrackId != track.id) {
            lastTrackId = track.id
            Task { await fetchArtwork(for: track) }
        }
    }

    /// 锁屏挂载诊断：曲目或挂载结果变化时记一条（路线/开关/键），静态还是
    /// 动态、走的哪条路线，下次真机复现直接从设置 → 诊断日志看最后一步。
    /// r20：desc 里带本歌的 A 键与 B 键——挂载从“上一首兜底”切到“本歌”
    /// 的那一次会再记一条，锁屏上到底挂的是哪首歌的视频一眼能对上。
    /// r49 R3：desc 与 fields 增加 mountedKey / mountedSource（实际写入的
    /// animKey 或 appleKey + own-A / fallback-A / own-B / none）：单条 none
    /// 不再推不出写了几次、A 不再推不出是本歌视频还是上一首回退；挂载键一变
    /// desc 就变，去重不再把“换键”吞掉。
    private func logAnimatedMountIfChanged(track: Track, route3x4: String, route1x1: String,
                                           aKey: String, bKey: String, coverHost: String,
                                           mountedKey: String, mountedSource: String,
                                           mountedKey1x1: String, mountedSource1x1: String) {
        let desc = "enabled=\(animatedArtworkEnabled) 3x4=\(route3x4) 1x1=\(route1x1) aKey=\(aKey) bKey=\(bKey) mountedKey=\(mountedKey) mountedSource=\(mountedSource) mountedKey1x1=\(mountedKey1x1) mountedSource1x1=\(mountedSource1x1)"
        guard lastMountDiagTrackId != track.id || lastMountDiagDesc != desc else { return }
        lastMountDiagTrackId = track.id
        lastMountDiagDesc = desc
        DiagLog.shared.recordLog(category: "animated-artwork",
            message: "lock screen artwork mounted track=\(track.title) artist=\(track.artist) platform=\(track.platform) coverHost=\(coverHost) \(desc)",
            fields: ["lane": "animated-mount", "route3x4": route3x4, "route1x1": route1x1,
                     "enabled": animatedArtworkEnabled, "platform": track.platform,
                     "trackId": track.id, "aKey": aKey, "bKey": bKey, "coverHost": coverHost,
                     "mountedKey": mountedKey, "mountedSource": mountedSource,
                     "mountedKey1x1": mountedKey1x1, "mountedSource1x1": mountedSource1x1])
    }

    // r50：回退窗口的三件套。fallbackAllowed 没挂过回退就放行，挂过就
    // 看 30 秒窗；stampFallback 只在第一次挂回退时记起点；expireFallback
    // 窗口过了记一笔就停（每首一次）。
    private func fallbackAllowed(for trackId: String) -> Bool {
        guard let startedAt = fallbackMountStartedAt, fallbackMountTrackId == trackId else { return true }
        return Date().timeIntervalSince(startedAt) <= Self.fallbackWindowSeconds
    }

    private func stampFallback(for trackId: String) {
        if fallbackMountTrackId != trackId {
            fallbackMountTrackId = trackId
            fallbackMountStartedAt = Date()
        }
    }

    private func expireFallback(for track: Track, key: String) {
        guard fallbackExpiredLoggedTrackId != track.id else { return }
        fallbackExpiredLoggedTrackId = track.id
        DiagLog.shared.recordLog(category: "animated-artwork",
            message: "lock screen fallback expired track=\(track.title) platform=\(track.platform) fallbackKey=\(key) windowSec=\(Int(Self.fallbackWindowSeconds))",
            fields: ["lane": "animated-fallback-expired", "trackId": track.id, "platform": track.platform, "fallbackKey": key])
    }

    /// 当前歌挂哪个动态视频：本歌的竖版视频就绪就挂本歌的；没就绪就挂上一首的缓存。
    /// 只看竖版就绪（锁屏用竖版；方形只是 1x1 备用，r20 之前要求两个尺寸都在，
    /// 方形一失败竖版也被拖死）。
    // r50：本歌 own-A 由调用方先按 aKey 直查，这里实际只出回退键（上一首 / 上次挂载）。
    private func animatedArtworkKeyForCurrentTrack() -> String? {
        if let key = lastCoverKey, AnimatedArtworkManager.shared.isReady(key: key, aspect: .portrait) { return key }
        if let fallback = AnimatedArtworkManager.shared.fallbackKey(for: lastCoverKey ?? "") { return fallback }
        // r49 R2：lastGoodKey 也丢了时（kick 的已就绪分支曾绕过 prepare，
        // lastGoodKey 永远没补上），再退到上一次成功挂载的键（R1 的
        // lastMountedAnimKey），须竖版就绪。放 coordinator 侧做，不动
        // manager 的 fallbackKey、不跨文件传参、不循环依赖。
        if let retained = lastMountedAnimKey, AnimatedArtworkManager.shared.isReady(key: retained, aspect: .portrait) { return retained }
        return nil
    }

    /// 锁屏专辑图：先走 https 下整张原图；到货后写静态 artwork，并触发
    /// AnimatedArtworkManager 渲染动态视频（就绪后 onReady 回调补写 Now Playing）。
    private func fetchArtwork(for track: Track) async {
        // 换歌了，上一首的失败标记清掉（重试只针对同一首歌耗尽时守门）。
        if coverFailedTrackId != track.id { coverFailedTrackId = nil }
        // 第 21 轮第 3 件：路线 B 的 prepare 不再这里启动——它要抓苹果网页
        // token（2.4MB 首页 + 3.3MB JS + 正则），和挂死的 LX 挤在同一个
        // 窗口里。改成等 startedTrackId 再由 kickAnimatedPrepares 启动
        // （见 artworkPrepareKickedTrackId 注释）；匹配只用歌手+专辑名，
        // 不依赖封面，所以启动时机挪后不影响匹配结果。
        DiagLog.shared.recordPlaybackStep("cover fetch start id=\(track.id) platform=\(track.platform)")
        guard let url = track.coverURL, !url.absoluteString.isEmpty else {
            // 没封面的歌也动起来：用默认图（纯白，符合「无封面用白色」偏好）
            // 生成动态视频（AnimatedArtworkManager.defaultKey，所有没封面的歌共用）。
            // r20：Track.from 可能造出非 nil 的空 URL（URL(string: "")），
            // 之前 guard let 直接放行、走下载再失败——无封面的歌被当成“下载
            // 失败”，白白记一条失败日志、排一次 10 秒重试、还立 coverFailed
            // 标记；空串现在直接走这条干净的默认分支。
            // 静态图也上默认白图（别留上一首的），归属记成本歌；lastArtwork
            // 非空后本分支末尾的 writeNowPlaying 不会再触发重拉（见下）。
            let defaultImage = defaultCoverImage()
            lastArtwork = Self.lockScreenArtwork(from: defaultImage)
            lastArtworkTrackId = track.id
            lastCoverKey = AnimatedArtworkManager.defaultKey
            lastCoverImage = defaultImage
            lastCoverImageTrackId = track.id
            // 第 21 轮第 3 件：默认视频的 prepare 也不在这里启动，等
            // startedTrackId 再由 kickAnimatedPrepares 启动（同文件头注释）。
            // default 视频已就绪时上面没有 onReady 会再补写：这里直接重挂一次，
            // 否则暂停态（无 5 秒进度复写）的无封面歌会一直挂着上一首的视频。
            writeNowPlaying()
            maybeKickAnimatedPrepares(for: track)
            return
        }
        let urlString = url.absoluteString
        lastCoverURL = urlString
        let key = AnimatedArtworkManager.key(forCoverURL: urlString)
        lastCoverKey = key
        var image: UIImage?
        // r48-11：磁盘缓存优先——上次加载过直接读本地，不联网；联网取到再写盘。
        if let cached = DiskCache.data(kind: .cover, key: DiskCache.coverKey(for: url)) {
            image = UIImage(data: cached)
        }
        if image == nil {
            // 先走图片代理（进程内调 Proxies，含 mzstatic 白名单 + Referer）。
            let proxyReq = HttpRequest(method: "GET", path: "/api/img",
                                       query: ["url": urlString], headers: [:], body: Data())
            let proxyResp = await Proxies.proxyImage(proxyReq)
            if (200...299).contains(proxyResp.status) {
                image = UIImage(data: proxyResp.body)
                if image != nil { DiskCache.store(proxyResp.body, kind: .cover, key: DiskCache.coverKey(for: url)) }
            }
        }
        if image == nil {
            // r24：走 Proxies.directImageData——同一个门、6s 上限、入口 https
            // 归一；旧写法 URLSession.shared.data(from:) 默认 60s。
            if let data = await Proxies.directImageData(url) {
                image = UIImage(data: data)
                if image != nil { DiskCache.store(data, kind: .cover, key: DiskCache.coverKey(for: url)) }
            }
        }
        // 第 21 轮第 3 件：零尺寸图（坏数据解出来 0x0）按下载失败处理，
        // 不进 lockScreenSized / prepare（见 AnimatedArtwork 的注释）。
        if let img = image, img.size.width <= 0 || img.size.height <= 0 {
            DiagLog.shared.recordLog(category: "animated-artwork",
                message: "cover zero-size image track=\(track.title) platform=\(track.platform) host=\(url.host ?? "")",
                fields: ["lane": "cover-zero-size", "host": url.host ?? "", "platform": track.platform])
            image = nil
        }
        guard let image else {
            // 歌已经切走了：旧下载丢弃，新歌那轮自己会拉。
            guard lastCoverURL == urlString else { return }
            // 封面没拉到 ≠ 锁屏只能静态（r20 之前的根因：这里直接 return，
            // 两条 prepare 都没跑；lastTrackId 已推进、lastArtwork 非空时
            // 后续 writeNowPlaying 再也不会重拉——整首歌静态，且无任何记录；
            // 壳版 ContentView 同样位置是记 DiagLog + 上默认图兜底）。
            // 现在：记一笔诊断；静态图上默认白图（别留上一首的封面，也别留空——
            // r33：开关关时锁屏要点专辑铺满，静态图不能为空；之前这里 lastArtwork
            // 置 nil，关掉动画插图后锁屏根本没有专辑图可点）；路线 A 用默认白图
            // 生成兜底视频（路线 B 已在上面并行准备，不依赖封面）；10 秒后重试
            // 一次封面（仍是这首歌才拉，最多一次），重试成功真封面会盖掉白图。
            DiagLog.shared.recordLog(category: "animated-artwork",
                message: "cover download failed, fallback to default animated video track=\(track.title) platform=\(track.platform) host=\(url.host ?? "")",
                fields: ["lane": "cover-download-failed", "host": url.host ?? "", "platform": track.platform])
            // 先立失败标记再补写：标记是“只重试一次”的开关（shouldRetry 靠它
            // 区分首次失败与重试失败），必须在补写之前立好；补写后 lastArtwork
            // 已非空（默认白图），后续 5 秒进度复写不再触发重拉，不会无限循环。
            let shouldRetry = coverFailedTrackId != track.id
            coverFailedTrackId = track.id
            lastArtwork = Self.lockScreenArtwork(from: defaultCoverImage())
            lastArtworkTrackId = track.id
            lastCoverKey = AnimatedArtworkManager.defaultKey
            lastCoverImage = nil
            lastCoverImageTrackId = track.id
            DiagLog.shared.recordPlaybackStep("cover fetch fail id=\(track.id) platform=\(track.platform) host=\(url.host ?? "")")
            writeNowPlaying()
            // 第 21 轮第 3 件：默认视频的 prepare 也不在这里启动，等
            // startedTrackId 再由 kickAnimatedPrepares 启动（无图时它用默认白图）。
            maybeKickAnimatedPrepares(for: track)
            if shouldRetry {
                Task.detached {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    await MainActor.run {
                        guard self.lastCoverURL == urlString,
                              self.store?.currentTrack?.id == track.id else { return }
                        Task { await self.fetchArtwork(for: track) }
                    }
                }
            }
            return
        }
        guard lastCoverURL == urlString else { return }
        coverFailedTrackId = nil
        lastArtwork = Self.lockScreenArtwork(from: image)
        lastArtworkTrackId = track.id
        lastCoverImage = image
        lastCoverImageTrackId = track.id
        DiagLog.shared.recordPlaybackStep("cover ready id=\(track.id) platform=\(track.platform) host=\(url.host ?? "")")
        writeNowPlaying()
        // 第 21 轮第 3 件：动态视频的 prepare 不再这里启动，等 startedTrackId
        // 再由 kickAnimatedPrepares 启动（图已暂存到 lastCoverImage）。
        // r49 R4：封面 10 秒重试成功后 lastCoverKey 变了（失败那轮曾被置成
        // defaultKey、且那轮已 kick 过），只凭 trackId 守门会把真封面的准备
        // 永远挡住。键变了就清掉 kicked 标记再 kick；键没变说明这把键已
        // kick 过，仍挡住。
        if lastCoverKey != artworkPrepareKickedKey {
            artworkPrepareKickedTrackId = nil
            artworkPrepareKickedKey = nil
        }
        maybeKickAnimatedPrepares(for: track)
    }

    /// 封面到货后补启动动态准备：只有已经真正起播（startedTrackId 是这首）
    /// 才启动；还没起播时什么都不做，等 startedTrackId 的订阅来启动。
    private func maybeKickAnimatedPrepares(for track: Track) {
        guard store?.startedTrackId == track.id else { return }
        kickAnimatedPrepares(for: track)
    }

    /// 动态封面准备的唯一启动点（第 21 轮第 3 件，见
    /// artworkPrepareKickedTrackId 注释）：Route B（不依赖封面，先启动；
    /// prepare 内部有去重 + 否定缓存）+ Route A（要图：有现成图就用，
    /// 无封面/下载失败的歌用默认白图；有封面但图还没到的歌这次跳过、
    /// 不记 kicked，等图到了 fetchArtwork 再调 maybeKick 补启动）。
    /// 每首只启动一次；失败也只启动一次（Route A 内部有重试一次，
    /// Route B 的否定缓存管重复查；重启动不会把视频变回来，只会多烧一轮）。
    private func kickAnimatedPrepares(for track: Track) {
        // r45-2：开关关了 / iOS 26 以下时不准备——挂载（writeNowPlaying）
        // 本来就只在 `if #available(iOS 26.0, *), animatedArtworkEnabled`
        // 里挂动态视频，准备了也挂不上；之前这里不查，开关关掉、26
        // 以下也每首歌全量跑路线 A 编码 + 路线 B 抓 token，白白烧电。
        guard animatedArtworkEnabled else { return }
        guard #available(iOS 26.0, *) else { return }
        guard artworkPrepareKickedTrackId != track.id else { return }
        guard store?.startedTrackId == track.id else { return }
        guard let animKey = lastCoverKey else { return }
        let image: UIImage?
        if animKey == AnimatedArtworkManager.defaultKey {
            image = defaultCoverImage()
        } else if lastCoverImageTrackId == track.id {
            image = lastCoverImage
        } else {
            return
        }
        guard let coverImage = image else { return }
        artworkPrepareKickedTrackId = track.id
        artworkPrepareKickedKey = animKey  // r49 R4
        DiagLog.shared.recordPlaybackStep("animated prepare kick id=\(track.id) platform=\(track.platform) key=\(animKey)")
        AppleAnimatedArtworkProvider.shared.prepare(for: track) { [weak self] ready in
            guard let self, ready else { return }
            Task { @MainActor in self.writeNowPlaying() }
        }
        if !AnimatedArtworkManager.shared.isReady(key: animKey) {
            AnimatedArtworkManager.shared.prepare(cover: coverImage, key: animKey) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    // r50：只认「还是这首歌」，不再认 lastCoverKey——它是取
                    // 封面状态（失败会翻成默认键），与本歌视频就绪无关；已就绪
                    // 的本歌视频不该因它翻过就被丢掉，writeNowPlaying 会按
                    // 本歌 aKey 直查挂上。
                    guard self.store?.currentTrack?.id == track.id else { return }
                    self.writeNowPlaying()
                    // r49 R5：生成失败后补挂载——onReady 回调时视频仍未就绪
                    // （renderWithRetry 两次都失败），且仍是当前歌：5 秒后
                    // 重准备一次，每键最多 1 次（routeARepreparedKeys 守门），
                    // 避免无限重试烧电。重准备走 prepare（内部仍有重试一次），
                    // 成功后它的 onReady 再补写一次 Now Playing 换成本歌视频。
                    if !AnimatedArtworkManager.shared.isReady(key: animKey),
                       !self.routeARepreparedKeys.contains(animKey) {
                        self.routeARepreparedKeys.insert(animKey)
                        Task.detached {
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            await MainActor.run {
                                guard self.store?.currentTrack?.id == track.id,
                                      self.lastCoverKey == animKey,
                                      self.animatedArtworkEnabled else { return }
                                AnimatedArtworkManager.shared.prepare(cover: coverImage, key: animKey) { [weak self] in
                                    guard let self else { return }
                                    Task { @MainActor in
                                        // r50：同上，只认「还是这首歌」。
                                        guard self.store?.currentTrack?.id == track.id else { return }
                                        self.writeNowPlaying()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            // r49 R2：已就绪也走 prepare()——它内部的 isReady 分支会同步置
            // lastGoodKey 并立即回调；之前这里只 writeNowPlaying()、绕过
            // prepare()，lastGoodKey 永远不补，下一首切来 fallbackKey 因
            // lastGoodKey == nil 返回 nil → 锁屏掉回 none。
            AnimatedArtworkManager.shared.prepare(cover: coverImage, key: animKey) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    // r50：只认「还是这首歌」，不再认 lastCoverKey（见上）。
                    guard self.store?.currentTrack?.id == track.id else { return }
                    self.writeNowPlaying()
                }
            }
        }
    }

    /// 默认封面图：720x720 纯白（无封面时的白色占位；动态视频从它生成）。
    private func defaultCoverImage() -> UIImage {
        let size = CGSize(width: 720, height: 720)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// 锁屏静态图尺寸（r33：不再照抄壳版只压不放）：
    /// 全屏铺满时系统拿这张静态图当整屏背景，图太小（QQ 300px）即使能展开也糊、
    /// 还可能不够系统展开的门槛，所以最长边归一到 [1200, 1600]：小于 1200 放大
    /// 到 1200，大于 1600 压到 1600，中间原样返回。放大补不出细节，但能让系统
    /// 拿到一张全屏尺寸的图（iPhone 屏宽约 1170–1320px）；1600 上限控内存。
    /// 默认白图 720x720 也走这里，放大到 1200x1200。scale 固定 1.0（与旧的
    /// UIGraphicsBeginImageContextWithOptions(..., 1.0) 同义）：sized.size 的
    /// 点数就是像素数，MPMediaItemArtwork 的 boundsSize 与像素一致。
    private static func lockScreenSized(_ image: UIImage) -> UIImage {
        let minEdge: CGFloat = 1200
        let maxEdge: CGFloat = 1600
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return image }
        guard longest < minEdge || longest > maxEdge else { return image }
        let targetEdge = min(max(longest, minEdge), maxEdge)
        let scale = targetEdge / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// 锁屏静态 artwork（r36：第 12 轮目标 + r33 未生效的真根因）：
    /// r33 只把方形图的边长归一到 [1200, 1600]，三处创建点仍是
    /// `{ _ in <同一张方形图> }`——闭包完全忽略系统要的尺寸。点专辑铺满
    /// 全屏时系统要的是一张竖屏矩形图（用户截屏 1206x2622px，即
    /// 402x874pt @3x）；方形图永远盖不住竖屏矩形，系统拿不到可铺满的
    /// 图就不展开，只剩圆角卡片 + 上下棕色底（用户 22:11 截图正是这个
    /// 状态；封面本身已挂真图、切歌也更新，源图分辨率不是卡点：酷狗
    /// coverOf 本来就要 1024px，见 FoliaKugou coverSize）。
    /// 所以 handler 按请求尺寸现裁：方形请求等比缩放、竖屏请求把方形封面
    /// center-crop（aspect-fill）裁成竖版填满请求矩形；裁切走原图（非
    /// lockScreenSized 压过的），细节不丢；boundsSize 仍用 r33 归一后的
    /// 方形（1200–1600），只作系统参考的最大方形尺寸。
    /// 开关关时只剩这张静态图（动态键整段跳过），开时动态路线 A/B 不动。
    private static func lockScreenArtwork(from source: UIImage) -> MPMediaItemArtwork {
        let base = lockScreenSized(source)
        let scale = UIScreen.main.scale
        // 每张 artwork 一份尺寸缓存（NSCache 线程安全；handler 可能在
        // 非主线程被系统调，普通字典会数据竞争）。缓存跟 artwork 对象同寿，
        // 切歌建新 artwork 时旧缓存一起丢，不会把上一首的图供到新歌。
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        return MPMediaItemArtwork(boundsSize: base.size) { requested in
            Self.artworkImage(for: requested, from: source, fallback: base, scale: scale, cache: cache)
        }
    }

    /// 按请求尺寸供图：aspect-fill 裁成请求尺寸（点数；像素 = 点数 x 建
    /// artwork 时抓的屏幕 scale）。请求尺寸非法（<=0/NaN）回方形保底；
    /// 像素最长边封顶 3000（本机锁屏全屏 1206x2622px 也在内，不截断）。
    private static func artworkImage(for requested: CGSize, from source: UIImage,
                                     fallback: UIImage, scale: CGFloat,
                                     cache: NSCache<NSString, UIImage>) -> UIImage {
        guard requested.width > 0, requested.height > 0,
              requested.width.isFinite, requested.height.isFinite,
              source.size.width > 0, source.size.height > 0 else { return fallback }
        let key = "\(Int(requested.width.rounded()))x\(Int(requested.height.rounded()))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var target = requested
        let pixelLongest = max(target.width, target.height) * scale
        if pixelLongest > 3000 {
            let shrink = 3000 / pixelLongest
            target = CGSize(width: target.width * shrink, height: target.height * shrink)
        }
        let drawScale = max(target.width / source.size.width, target.height / source.size.height)
        let drawSize = CGSize(width: source.size.width * drawScale, height: source.size.height * drawScale)
        let drawOrigin = CGPoint(x: (target.width - drawSize.width) / 2, y: (target.height - drawSize.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let rendered = renderer.image { _ in
            source.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
        cache.setObject(rendered, forKey: key)
        return rendered
    }

    // MARK: - 远程命令（照抄壳版 ContentView.reassertRemoteCommands）

    /// 复核一次（状态变化时调；距上次不足 5 秒且不是切歌时跳过，避免刷屏）。
    private func reassertRemoteCommandsIfNeeded() {
        let now = Date()
        let trackChanged = store?.currentTrack?.id != lastTrackId
        guard trackChanged || now.timeIntervalSince(lastReassertAt) >= 5 else { return }
        lastReassertAt = now
        reassertRemoteCommands()
    }

    /// 强制复核（App 回前台 / 切歌时调）：先 removeTarget 再 addTarget，
    /// skipBackward/skipForward 显式关死，上一首/下一首/播放/暂停/喜欢显式打开。
    func reassertRemoteCommands() {
        guard let store else { return }
        let center = MPRemoteCommandCenter.shared()
        center.skipBackwardCommand.removeTarget(nil)
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.removeTarget(nil)
        center.skipForwardCommand.isEnabled = false
        center.playCommand.removeTarget(nil)
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak store] _ in
            Task { @MainActor in store?.resume() }
            return .success
        }
        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak store] _ in
            Task { @MainActor in store?.pause() }
            return .success
        }
        center.nextTrackCommand.removeTarget(nil)
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak store] _ in
            Task { @MainActor in store?.next() }
            return .success
        }
        center.previousTrackCommand.removeTarget(nil)
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak store] _ in
            Task { @MainActor in store?.previous() }
            return .success
        }
        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak store] _ in
            Task { @MainActor in store?.togglePlay() }
            return .success
        }
        center.likeCommand.removeTarget(nil)
        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = "喜欢"
        center.likeCommand.addTarget { [weak store] _ in
            Task { @MainActor in store?.toggleLike() }
            return .success
        }
        syncLikeCommand()
        lastReassertAt = Date()
        // 复核后记一条诊断（各命令实际启用状态）：状态与预期不符时下次报告能看到。
        let mismatch = !center.playCommand.isEnabled || !center.pauseCommand.isEnabled
            || !center.nextTrackCommand.isEnabled || !center.previousTrackCommand.isEnabled
            || center.skipBackwardCommand.isEnabled || center.skipForwardCommand.isEnabled
        if mismatch {
            DiagLog.shared.recordLog(category: "remote-commands",
                message: "remote commands reasserted MISMATCH: play=\(center.playCommand.isEnabled) pause=\(center.pauseCommand.isEnabled) next=\(center.nextTrackCommand.isEnabled) prev=\(center.previousTrackCommand.isEnabled) skipBwd=\(center.skipBackwardCommand.isEnabled) skipFwd=\(center.skipForwardCommand.isEnabled)",
                fields: ["reason": "remote-commands-mismatch", "lane": "remote-commands"])
        }
    }

    /// 锁屏星标实心/空心与喜欢态同步。
    private func syncLikeCommand() {
        guard let store else { return }
        MPRemoteCommandCenter.shared().likeCommand.isActive = store.isLiked
    }
}
