import Foundation
import MediaPlayer

/// r29 task 1：Apple Music 整首播放器（MPMusicPlayerController.applicationMusicPlayer）。
///
/// 为什么用它：catalog API 只回 30 秒试听；iPhone 的 WKWebView 没有 EME，
/// MusicKit JS 在应用内播不了整首；applicationMusicPlayer 是系统级
/// Apple Music 播放器，不需要 MusicKit entitlement、不需要 App 自带
/// 开发者账号的 MusicKit 能力——只要用户 Apple ID 有订阅 + 有 user token
/// （AppleMusicAuth），按 store id 建队列就能播整首。
///
/// 归属：只播 Apple Music 的歌。队列由 PlaybackStore 拼（从当前下标起
/// 连续的、有 store id 的 Apple Music 曲目）；播完一段、切到非 AM 的歌、
/// 失败时都由 PlaybackStore 接管，不在这里编队列逻辑。
///
/// 状态同步（PlaybackStore 读这三个回调，不直接读 player）：
/// - onProgress：0.5s timer 轮询 currentPlaybackTime 推进度/时长；
/// - onNowPlayingItemChanged：AM 播完一首自动进下一首时，带新曲目的
///   store id 回来（nil = 队列播完、当前无曲目）；
/// - onPlaybackEnded：队列播完、playbackState 变 .stopped 时回来。
/// 显式 stop() 时不触发 onPlaybackEnded（调用方自己管状态，不编一次
/// “播完了”出来）。
@MainActor
final class AppleMusicPlayer {
    private let player = MPMusicPlayerController.applicationMusicPlayer

    /// 进度回调（当前秒，当前曲目总时长秒；时长未知时为 0）。
    var onProgress: ((TimeInterval, TimeInterval) -> Void)?
    /// 当前曲目变化回调（新曲目的 store id；nil = 队列播完无曲目）。
    var onNowPlayingItemChanged: ((String?) -> Void)?
    /// 队列播完回调（playbackState → .stopped；显式 stop() 不触发）。
    var onPlaybackEnded: (() -> Void)?

    private var progressTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// 显式 stop() 期间压住 .stopped 回调（否则 stop 也会触发一次“播完了”）。
    private var suppressEndedCallback = false

    init() {
        player.beginGeneratingPlaybackNotifications()
        let itemObserver = NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.onNowPlayingItemChanged?(self.nowPlayingStoreID) }
        }
        let stateObserver = NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange, object: player, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.player.playbackState == .stopped, !self.suppressEndedCallback {
                    self.onPlaybackEnded?()
                }
            }
        }
        observers = [itemObserver, stateObserver]
    }

    // 注意：没有 deinit——与 PlaybackStore 同款理由（App 生命周期单例，
    // @MainActor 隔离的状态在 Swift 6 下 deinit 里访问是硬错）；通知随
    // player 一起释放，不手动清理。

    /// 当前曲目的 store id（无曲目时为 nil）。
    var nowPlayingStoreID: String? {
        player.nowPlayingItem?.value(forProperty: MPMediaItemPropertyPlaybackStoreID) as? String
    }

    /// 是否正在播放。
    var isPlaying: Bool { player.playbackState == .playing }

    /// 当前进度（秒）。
    var currentPlaybackTime: TimeInterval { player.currentPlaybackTime }

    /// 按 store id 建队列并起播。返回 false = 起播失败（prepareToPlay
    /// 报错），调用方回落到 30 秒试听链。
    func play(storeIDs: [String], startAt index: Int) async -> Bool {
        guard !storeIDs.isEmpty, storeIDs.indices.contains(index) else { return false }
        suppressEndedCallback = false
        player.setQueue(with: storeIDs)
        if index > 0 {
            // setQueue 默认从第 0 首起播；startAt > 0 时先跳到目标下标
            // （PlaybackStore 拼队列时已从当前下标起切，正常走 index == 0）。
            for _ in 0..<index { player.skipToNextItem() }
        }
        let error: Error? = await withCheckedContinuation { continuation in
            player.prepareToPlay { error in
                continuation.resume(returning: error)
            }
        }
        if let error {
            DiagLog.shared.recordPlaybackStep("am player prepare FAIL error=\(error.localizedDescription)")
            return false
        }
        player.play()
        startProgressTimer()
        return true
    }

    /// 恢复播放。
    func resume() {
        player.play()
        startProgressTimer()
    }

    /// 暂停（队列保留，resume 可续播）。
    func pause() {
        player.pause()
    }

    /// 停止（清队列状态；不触发 onPlaybackEnded）。
    func stop() {
        suppressEndedCallback = true
        player.stop()
        stopProgressTimer()
        suppressEndedCallback = false
    }

    /// 跳到指定进度（秒）。
    func seek(to time: TimeInterval) {
        player.currentPlaybackTime = max(0, time)
    }

    // MARK: - 进度轮询

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let duration = self.player.nowPlayingItem?.playbackDuration ?? 0
                self.onProgress?(self.player.currentPlaybackTime, duration)
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
