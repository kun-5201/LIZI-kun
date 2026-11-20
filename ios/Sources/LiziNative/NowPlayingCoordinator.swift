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
        if #available(iOS 26.0, *), animatedArtworkEnabled {
            let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
            let appleKey = AppleAnimatedArtworkProvider.shared.albumKey(for: track)
            let appleReady = appleKey.map { AppleAnimatedArtworkProvider.shared.isReady(key: $0) } ?? false
            if supported.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork) {
                if let key = appleKey, appleReady,
                   let art = AppleAnimatedArtworkProvider.shared.artwork(forKey: key, aspect: .portrait) {
                    info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = art
                    route3x4 = "B"
                } else if let animKey = animatedArtworkKeyForCurrentTrack(),
                          let art = AnimatedArtworkManager.shared.artwork(forKey: animKey, aspect: .portrait) {
                    info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = art
                    route3x4 = "A"
                }
            }
            if supported.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork) {
                if let key = appleKey, appleReady,
                   let art = AppleAnimatedArtworkProvider.shared.artwork(forKey: key, aspect: .square) {
                    info[MPNowPlayingInfoProperty1x1AnimatedArtwork] = art
                    route1x1 = "B"
                } else if let animKey = animatedArtworkKeyForCurrentTrack(),
                          let art = AnimatedArtworkManager.shared.artwork(forKey: animKey, aspect: .square) {
                    info[MPNowPlayingInfoProperty1x1AnimatedArtwork] = art
                    route1x1 = "A"
                }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastPlaying = store.isPlaying
        logAnimatedMountIfChanged(track: track, route3x4: route3x4, route1x1: route1x1,
                                  aKey: aKey, bKey: bKey, coverHost: coverHost)
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
    private func logAnimatedMountIfChanged(track: Track, route3x4: String, route1x1: String,
                                           aKey: String, bKey: String, coverHost: String) {
        let desc = "enabled=\(animatedArtworkEnabled) 3x4=\(route3x4) 1x1=\(route1x1) aKey=\(aKey) bKey=\(bKey)"
        guard lastMountDiagTrackId != track.id || lastMountDiagDesc != desc else { return }
        lastMountDiagTrackId = track.id
        lastMountDiagDesc = desc
        DiagLog.shared.recordLog(category: "animated-artwork",
            message: "lock screen artwork mounted track=\(track.title) artist=\(track.artist) platform=\(track.platform) coverHost=\(coverHost) \(desc)",
            fields: ["lane": "animated-mount", "route3x4": route3x4, "route1x1": route1x1,
                     "enabled": animatedArtworkEnabled, "platform": track.platform,
                     "trackId": track.id, "aKey": aKey, "bKey": bKey, "coverHost": coverHost])
    }

    /// 当前歌挂哪个动态视频：本歌的竖版视频就绪就挂本歌的；没就绪就挂上一首的缓存。
    /// 只看竖版就绪（锁屏用竖版；方形只是 1x1 备用，r20 之前要求两个尺寸都在，
    /// 方形一失败竖版也被拖死）。
    private func animatedArtworkKeyForCurrentTrack() -> String? {
        if let key = lastCoverKey, AnimatedArtworkManager.shared.isReady(key: key, aspect: .portrait) { return key }
        return AnimatedArtworkManager.shared.fallbackKey(for: lastCoverKey ?? "")
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
            let defaultSized = Self.lockScreenSized(defaultImage)
            lastArtwork = MPMediaItemArtwork(boundsSize: defaultSized.size) { _ in defaultSized }
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
        // 先走图片代理（进程内调 Proxies，含 mzstatic 白名单 + Referer）。
        let proxyReq = HttpRequest(method: "GET", path: "/api/img",
                                   query: ["url": urlString], headers: [:], body: Data())
        let proxyResp = await Proxies.proxyImage(proxyReq)
        if (200...299).contains(proxyResp.status) {
            image = UIImage(data: proxyResp.body)
        }
        if image == nil {
            // r24：走 Proxies.directImageData——同一个门、6s 上限、入口 https
            // 归一；旧写法 URLSession.shared.data(from:) 默认 60s。
            if let data = await Proxies.directImageData(url) {
                image = UIImage(data: data)
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
            // 现在：记一笔诊断；静态图清掉（别留上一首的封面）；路线 A 用
            // 默认白图生成兜底视频（路线 B 已在上面并行准备，不依赖封面）；
            // 10 秒后重试一次封面（仍是这首歌才拉，最多一次）。
            DiagLog.shared.recordLog(category: "animated-artwork",
                message: "cover download failed, fallback to default animated video track=\(track.title) platform=\(track.platform) host=\(url.host ?? "")",
                fields: ["lane": "cover-download-failed", "host": url.host ?? "", "platform": track.platform])
            // 先立失败标记再补写：writeNowPlaying 里 lastArtwork == nil 会触发
            // 重拉，标记必须在这之前立好，否则补写会立刻再拉一次、失败再补写，
            // 无限循环。重试只排一次：第二次失败（重试那次）不再排。
            let shouldRetry = coverFailedTrackId != track.id
            coverFailedTrackId = track.id
            lastArtwork = nil
            lastArtworkTrackId = nil
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
        let sized = Self.lockScreenSized(image)
        lastArtwork = MPMediaItemArtwork(boundsSize: sized.size) { _ in sized }
        lastArtworkTrackId = track.id
        lastCoverImage = image
        lastCoverImageTrackId = track.id
        DiagLog.shared.recordPlaybackStep("cover ready id=\(track.id) platform=\(track.platform) host=\(url.host ?? "")")
        writeNowPlaying()
        // 第 21 轮第 3 件：动态视频的 prepare 不再这里启动，等 startedTrackId
        // 再由 kickAnimatedPrepares 启动（图已暂存到 lastCoverImage）。
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
        DiagLog.shared.recordPlaybackStep("animated prepare kick id=\(track.id) platform=\(track.platform) key=\(animKey)")
        AppleAnimatedArtworkProvider.shared.prepare(for: track) { [weak self] ready in
            guard let self, ready else { return }
            Task { @MainActor in self.writeNowPlaying() }
        }
        if !AnimatedArtworkManager.shared.isReady(key: animKey) {
            AnimatedArtworkManager.shared.prepare(cover: coverImage, key: animKey) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    guard self.lastCoverKey == animKey else { return }
                    self.writeNowPlaying()
                }
            }
        } else {
            // 视频已就绪：直接重挂一次（没有 onReady 回调会再补写）。
            writeNowPlaying()
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

    /// 锁屏静态图尺寸（照抄壳版 ContentView.lockScreenSized）：最长边压到
    /// 1000px 再交给系统（全屏铺满要大图，但 3000px 原图没必要）；小图原样
    /// 返回——上游给的 240/300px 小封面（QQ 300）在这里不放大，
    /// 放大也补不出细节；全屏清晰度要靠上游给大图或动态视频（720x960）。
    private static func lockScreenSized(_ image: UIImage) -> UIImage {
        let maxEdge: CGFloat = 1000
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let scale = maxEdge / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(target, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: target))
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
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
