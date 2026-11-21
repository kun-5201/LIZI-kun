import ActivityKit
import Combine
import Foundation
import UIKit

/// 原生版灵动岛协调器（r35-11：按 Apple Music 那套重加；只做岛的起/更/停，
/// 不画 UI、不碰锁屏系统卡——锁屏卡是 NowPlayingCoordinator 的
/// MPNowPlayingInfoCenter，两条线各管各的）。
///
/// 行为（用户 19:30–19:32 定稿）：
/// - 播起来就起岛（当前曲目 + 正在播放时 request；切歌只是 update，
///   标题/歌手/封面全在 ContentState 里，岛不闪、不重建）。
/// - 音乐停了岛跟着消失：isPlaying 变 false（暂停/播完/停）或当前曲目
///   没了 → 立刻 end（dismissalPolicy .immediate）。切歌不经过
///   isPlaying=false（PlaybackStore.next 直接起播），不会误杀。
/// - 进度只推 5 秒一跳（与 NowPlayingCoordinator 的 5 秒复写同 cadence；
///   Activity.update 有系统节流预算，太密会被丢）。
/// - 封面：按曲目拉一次（先走图片代理，失败走直连，与
///   NowPlayingCoordinator.fetchArtwork 同款两步），压到 120px JPEG
///   再推；没封面推 nil，视图画默认音符。
/// - 授权关了（设置里关了 Live Activities）就静默不做，不抛错、不记错
///   （r15 的教训：没 plist key 时 Activity.request 抛错，key 已在
///   project.yml 里恢复；这里再加 areActivitiesEnabled 守门，双保险）。
/// - 孤岛清理：bind 时若本进程没在播歌，把上次 App 被杀时留下的活动
///   一并 end 掉；App 终止时 delegate 调 endAll() 尽力清（iOS 很少走
///   applicationWillTerminate，清不掉的靠每次 update 的 staleDate
///   （15 分钟）变旧后由系统回收，见交回残留）。
@MainActor
final class LiveActivityCoordinator: ObservableObject {
    private weak var store: PlaybackStore?
    private var cancellables: Set<AnyCancellable> = []

    private var currentActivity: Activity<LiziIslandAttributes>?
    private var lastPushedState: LiziIslandAttributes.ContentState?
    private var lastUpdateAt = Date.distantPast
    private var requestFailedAt: Date?

    /// 当前曲目封面数据缓存（按曲目 id 认，只拉一次；切歌清掉重拉）。
    private var lastCoverDataTrackId: String?
    private var lastCoverData: Data?

    func bind(store: PlaybackStore) {
        self.store = store
        store.$currentTrack
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.sync() }
            }
            .store(in: &cancellables)
        store.$isPlaying
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.sync() }
            }
            .store(in: &cancellables)
        store.$isLiked
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.sync() }
            }
            .store(in: &cancellables)
        // 进度：最多每 5 秒推一次（与 NowPlayingCoordinator 同 cadence）。
        store.$progress
            .throttle(for: .seconds(5), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.sync() }
            }
            .store(in: &cancellables)
        // 启动时清孤岛：本进程没在播歌，上次被杀留下的活动不能留着。
        if store.currentTrack == nil || !store.isPlaying {
            Self.endAll()
        }
        sync()
    }

    /// 终止 / 启动时尽力清掉所有本 App 的岛活动（fire-and-forget；
    /// applicationWillTerminate 很少走，清不掉的靠 staleDate 回收）。
    nonisolated static func endAll() {
        Task {
            for activity in Activity<LiziIslandAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: - 同步

    /// 按当前状态起 / 更 / 停岛。
    private func sync() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let store, let track = store.currentTrack, store.isPlaying else {
            endActivity()
            return
        }
        // request 刚失败过 60 秒内不重试（防进度 tick 每 5 秒刷一条失败日志）。
        if currentActivity == nil, let failedAt = requestFailedAt,
           Date().timeIntervalSince(failedAt) < 60 { return }
        let state = buildState(track: track)
        let now = Date()
        // 曲目/喜欢/播放态/封面变了立刻推；只剩进度变了要等满 5 秒。
        let force = lastPushedState == nil
            || lastPushedState?.title != state.title
            || lastPushedState?.artist != state.artist
            || lastPushedState?.isLiked != state.isLiked
            || lastPushedState?.isPlaying != state.isPlaying
            || lastPushedState?.coverData != state.coverData
        if !force {
            guard now.timeIntervalSince(lastUpdateAt) >= 5 else { return }
            guard lastPushedState != state else { return }
        }
        if let activity = currentActivity {
            lastPushedState = state
            lastUpdateAt = now
            Task {
                // r35-11 修正：Activity.update 没有 (state, staleDate:) 这个重载，
                // staleDate 要包进 ActivityContent（壳版 LiveActivityManager.swift:151
                // 同款写法，run 44901749397 编译错的根因）。
                let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(900))
                await activity.update(content)
            }
        } else {
            lastPushedState = state
            lastUpdateAt = now
            Task {
                do {
                    let activity = try Activity.request(
                        attributes: LiziIslandAttributes(),
                        contentState: state, pushType: nil)
                    await MainActor.run { self.currentActivity = activity }
                } catch {
                    await MainActor.run {
                        self.requestFailedAt = Date()
                        self.lastPushedState = nil
                    }
                    DiagLog.shared.recordLog(category: "live-activity",
                        message: "island request failed: \(error.localizedDescription)",
                        fields: ["lane": "island-request-failed"])
                }
            }
        }
        // 封面还没到货就去拉，到了再推一次（带封面）。
        if lastCoverDataTrackId != track.id {
            lastCoverDataTrackId = track.id
            Task { await fetchCover(for: track) }
        }
    }

    private func buildState(track: Track) -> LiziIslandAttributes.ContentState {
        guard let store else {
            return LiziIslandAttributes.ContentState(title: track.title, artist: track.artist,
                                                     progress: 0, isPlaying: false)
        }
        let duration = store.duration
        let progress = duration > 0 ? min(1, max(0, store.progress / duration)) : 0
        return LiziIslandAttributes.ContentState(
            title: track.title.isEmpty ? "未知标题" : track.title,
            artist: track.artist.isEmpty ? SearchViewModel.label(for: track.platform) : track.artist,
            progress: progress,
            isPlaying: store.isPlaying,
            duration: duration,
            isLiked: store.isLiked,
            coverData: lastCoverDataTrackId == track.id ? lastCoverData : nil)
    }

    private func endActivity() {
        guard let activity = currentActivity else { return }
        currentActivity = nil
        lastPushedState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// 封面：与 NowPlayingCoordinator.fetchArtwork 同款两步（图片代理 →
    /// 直连），压到 120px JPEG；到了就再推一次状态（带封面）。
    private func fetchCover(for track: Track) async {
        guard let url = track.coverURL, !url.absoluteString.isEmpty else { return }
        let urlString = url.absoluteString
        var image: UIImage?
        let proxyReq = HttpRequest(method: "GET", path: "/api/img",
                                   query: ["url": urlString], headers: [:], body: Data())
        let proxyResp = await Proxies.proxyImage(proxyReq)
        if (200...299).contains(proxyResp.status) {
            image = UIImage(data: proxyResp.body)
        }
        if image == nil, let data = await Proxies.directImageData(url) {
            image = UIImage(data: data)
        }
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        // 切歌了就丢掉（别把上一首的封面挂到新歌上）。
        guard store?.currentTrack?.id == track.id, lastCoverDataTrackId == track.id else { return }
        let target = CGSize(width: 120, height: 120)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = resized.jpegData(compressionQuality: 0.8) else { return }
        lastCoverData = data
        sync()
    }
}
