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
    private var lastCoverURL: String?
    private var lastCoverKey: String?
    private var lastTrackId: String?
    private var lastPlaying: Bool = false
    private var lastReassertAt: Date = .distantPast

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
        // 进度：Now Playing 的已播时间最多每 5 秒刷新一次（太密系统会节流）。
        store.$progress
            .throttle(for: .seconds(5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.writeNowPlaying() }
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
        if let art = lastArtwork, lastTrackId == track.id {
            info[MPMediaItemPropertyArtwork] = art
        }
        // iOS 26+ 动态封面：先问路线 B（Apple 官方真视频），就绪就挂真视频；
        // 未就绪（首次切歌专辑解析还没回来）直接走路线 A，不等。
        if #available(iOS 26.0, *), animatedArtworkEnabled,
           let appleKey = AppleAnimatedArtworkProvider.shared.albumKey(for: track),
           AppleAnimatedArtworkProvider.shared.isReady(key: appleKey) {
            let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
            if supported.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork),
               let art = AppleAnimatedArtworkProvider.shared.artwork(forKey: appleKey, aspect: .portrait) {
                info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = art
            }
            if supported.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork),
               let art = AppleAnimatedArtworkProvider.shared.artwork(forKey: appleKey, aspect: .square) {
                info[MPNowPlayingInfoProperty1x1AnimatedArtwork] = art
            }
        } else {
            // 路线 A：只挂 supportedAnimatedArtworkKeys 里在列的键；
            // 本歌视频没就绪就挂上一首的缓存，不要静默变回静态。
            if #available(iOS 26.0, *), animatedArtworkEnabled,
               let animKey = animatedArtworkKeyForCurrentTrack() {
                let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
                if supported.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork),
                   let art = AnimatedArtworkManager.shared.artwork(forKey: animKey, aspect: .portrait) {
                    info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = art
                }
                if supported.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork),
                   let art = AnimatedArtworkManager.shared.artwork(forKey: animKey, aspect: .square) {
                    info[MPNowPlayingInfoProperty1x1AnimatedArtwork] = art
                }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastPlaying = store.isPlaying
        // 封面还没到货（或换歌了）就去拉，到了补写一次。
        if lastTrackId != track.id || lastArtwork == nil {
            lastTrackId = track.id
            Task { await fetchArtwork(for: track) }
        }
    }

    /// 当前歌挂哪个动态视频：本歌的视频就绪就挂本歌的；没就绪就挂上一首的缓存。
    private func animatedArtworkKeyForCurrentTrack() -> String? {
        if let key = lastCoverKey, AnimatedArtworkManager.shared.isReady(key: key) { return key }
        return AnimatedArtworkManager.shared.fallbackKey(for: lastCoverKey ?? "")
    }

    /// 锁屏专辑图：先走 https 下整张原图；到货后写静态 artwork，并触发
    /// AnimatedArtworkManager 渲染动态视频（就绪后 onReady 回调补写 Now Playing）。
    private func fetchArtwork(for track: Track) async {
        guard let url = track.coverURL else {
            // 没封面的歌也动起来：用默认图（纯白，符合「无封面用白色」偏好）
            // 生成动态视频（AnimatedArtworkManager.defaultKey，所有没封面的歌共用）。
            lastCoverKey = AnimatedArtworkManager.defaultKey
            let key = AnimatedArtworkManager.defaultKey
            // 路线 B 并行准备真视频（匹配只用歌手+专辑名，不依赖封面）：
            // 就绪后回调里重写一次 Now Playing 挂上；无素材什么都不做。
            AppleAnimatedArtworkProvider.shared.prepare(for: track) { [weak self] ready in
                guard let self, ready else { return }
                Task { @MainActor in self.writeNowPlaying() }
            }
            if !AnimatedArtworkManager.shared.isReady(key: key) {
                AnimatedArtworkManager.shared.prepare(cover: defaultCoverImage(), key: key) { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        guard self.lastCoverKey == key else { return }
                        self.writeNowPlaying()
                    }
                }
            }
            return
        }
        let urlString = url.absoluteString
        lastCoverURL = urlString
        let key = AnimatedArtworkManager.key(forCoverURL: urlString)
        lastCoverKey = key
        var image: UIImage?
        // 先走图片代理（进程内调 Proxies，含 mzstatic 白名单 + Referer）。
        let proxyReq = HttpRequest(method: "GET", path: "/api/img",
                                   query: ["url": urlString], headers: [:], body: Data())
        let proxyResp = await Proxies.proxyImage(proxyReq)
        if (200...299).contains(proxyResp.status) {
            image = UIImage(data: proxyResp.body)
        }
        if image == nil {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                image = UIImage(data: data)
            } catch {
                image = nil
            }
        }
        guard let image, lastCoverURL == urlString else { return }
        lastArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        writeNowPlaying()
        // 路线 B 并行准备真视频：就绪后回调里重写一次 Now Playing 挂上；
        // 未就绪/无素材什么都不做（本歌继续用路线 A）。
        AppleAnimatedArtworkProvider.shared.prepare(for: track) { [weak self] ready in
            guard let self, ready else { return }
            Task { @MainActor in self.writeNowPlaying() }
        }
        // 动态视频：后台渲染，完了在主线程回调补写（渲染失败也回调，调用方用上一首缓存兜底）。
        AnimatedArtworkManager.shared.prepare(cover: image, key: key) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.lastCoverKey == key else { return }
                self.writeNowPlaying()
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
