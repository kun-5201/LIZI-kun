import Combine
import Foundation
import UIKit

/// 灵动岛接线（P1 新写）：PlaybackStore → LiveActivityManager。
///
/// 推送节流（照抄壳版 LiveActivityManager 的约定）：
/// - 切歌 / 播放切换 / 喜欢态变 → 立刻推；
/// - 进度 → 最多 5 秒推一次；
/// - 暂停 → 推一次暂停态，之后不再推，岛靠 staleDate（8 秒）自然消失；
/// - 岛上没有歌词（第 22 轮第 5 件：用户不要岛上歌词；ContentState 里
///   已无歌词字段，歌词行变不再触发岛更新——岛更新只剩切歌、播放切换、
///   喜欢态、5 秒进度四路；歌词只在播放页里显示，见 PlaybackStore.lyrics）。
/// - 封面：代理（/api/img 进程内调 Proxies，含 mzstatic 白名单）→ 直链 → 默认图
///   （nil，扩展画 ♪ 占位），下采样 120px JPEG。
///
/// 第 22 轮第 5 件（照 Moumusic NowPlayingManager）：@MainActor——岛状态
/// 只在主线程上变，不再和取链任务跨线程打架。
@MainActor
final class NativeIslandCoordinator: ObservableObject {
    private let store: PlaybackStore
    private let activityManager: LiveActivityManager
    private var cancellables: Set<AnyCancellable> = []

    /// 上次推进度的时间（节流用）。
    private var lastProgressPushAt: Date = .distantPast
    /// 当前歌推过岛的封面（按 track.id 缓存，避免每 5 秒重下一次）。
    private var coverCache: [String: Data] = [:]
    /// 当前在推的曲目 id。
    private var currentTrackId: String?

    init(store: PlaybackStore, activityManager: LiveActivityManager = LiveActivityManager()) {
        self.store = store
        self.activityManager = activityManager
        bind()
    }

    // MARK: - 订阅

    private func bind() {
        // 切歌：起新岛（manager.startActivity 内部先 end 旧活动）。
        store.$currentTrack
            .removeDuplicates(by: { $0?.id == $1?.id && $0?.platform == $1?.platform })
            .sink { [weak self] track in
                guard let self else { return }
                Task { @MainActor in
                    guard let track else {
                        self.activityManager.endActivity()
                        self.currentTrackId = nil
                        return
                    }
                    await self.startForTrack(track)
                }
            }
            .store(in: &cancellables)

        // 播放切换：立刻推（暂停态也推一次，之后靠 staleDate 消失）。
        store.$isPlaying
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in await self.pushNow() }
            }
            .store(in: &cancellables)

        // 喜欢态变：立刻推（展开页星标实心/空心）。
        store.$isLiked
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in await self.pushNow() }
            }
            .store(in: &cancellables)

        // 进度：最多 5 秒推一次。
        store.$progress
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    guard self.currentTrackId != nil, self.store.isPlaying else { return }
                    guard Date().timeIntervalSince(self.lastProgressPushAt) >= 5 else { return }
                    await self.pushNow()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 推岛

    /// 切歌：先拿封面（缓存优先），再起活动。
    private func startForTrack(_ track: Track) async {
        currentTrackId = track.id
        lastProgressPushAt = .distantPast
        let cover = await coverData(for: track)
        let state = snapshot(coverData: cover)
        activityManager.startActivity(title: track.title, artist: track.artist, state: state)
        lastProgressPushAt = Date()
    }

    /// 推一次当前快照（没有在播的曲目时什么都不做）。
    private func pushNow() async {
        guard let track = store.currentTrack, currentTrackId == track.id else { return }
        let cover = coverCache[track.id]
        let state = snapshot(coverData: cover)
        activityManager.updateActivity(state: state)
        lastProgressPushAt = Date()
    }

    /// 当前快照（第 22 轮第 5 件：无歌词字段——歌名/歌手走 attributes，
    /// 岛上只剩封面 / 进度 / 播放态 / 喜欢态）。
    private func snapshot(coverData: Data?) -> LiziLyricsAttributes.ContentState {
        let track = store.currentTrack
        let duration = store.duration > 0 ? store.duration : (track?.durationSeconds ?? 0)
        let progress = duration > 0 ? max(0, min(1, store.progress / duration)) : 0
        return LiziLyricsAttributes.ContentState(
            progress: progress,
            isPlaying: store.isPlaying,
            duration: duration,
            isLiked: store.isLiked,
            coverData: coverData
        )
    }

    /// 供 App 终止 / 前台刷新时调：重新读一遍系统授权态。
    func refreshAuthorization() {
        activityManager.refreshAuthorization()
    }

    /// 供 App 终止时调：同步 end 全部活动由 AppDelegate 直接调
    /// LiveActivityManager.endAllActivitiesSynchronously，这里只清本端状态。
    func endIsland() {
        activityManager.endActivity()
        currentTrackId = nil
    }

    // MARK: - 封面（代理 → 直链 → 默认图，下采样 120px JPEG）

    private func coverData(for track: Track) async -> Data? {
        if let cached = coverCache[track.id] { return cached }
        guard let url = track.coverURL else { return nil }
        // 第 22 轮第 3 件：岛封面取回进面包屑（开始/结束各一步，via 记代理/
        // 直链/无）。这一步在 startForTrack 里跑在起岛之前、和 LX 取链并发，
        // 是死亡窗口前半段里唯一原来没有落盘点的活；下次死在取回里，
        // lastDeathStep 会停在 "island cover fetch start" 而不是 start ok。
        // 每首歌只取一次（缓存命中直接回），不刷面包屑。
        DiagLog.shared.recordPlaybackStep("island cover fetch start id=\(track.id) platform=\(track.platform)")
        var via = "none"
        defer {
            DiagLog.shared.recordPlaybackStep("island cover fetch end id=\(track.id) platform=\(track.platform) via=\(via)")
        }
        // 1) 走图片代理（进程内调 Proxies.proxyImage：白名单 + 防盗链 Referer，
        //    含第 15 轮的 .mzstatic.com；代理 403 时记诊断、不拦直链）。
        let proxyReq = HttpRequest(method: "GET", path: "/api/img",
                                   query: ["url": url.absoluteString], headers: [:], body: Data())
        let proxyResp = await Proxies.proxyImage(proxyReq)
        if (200...299).contains(proxyResp.status),
           let data = downsample(proxyResp.body) {
            coverCache[track.id] = data
            via = "proxy"
            return data
        }
        // 2) 直链（r24：走 Proxies.directImageData——同一个门、6s 上限、入口
        // https 归一；旧写法 URLSession.shared.data(from:) 默认 60s，
        // startForTrack 在起岛前等它，最坏 40s + 60s 才起岛）。
        if let data = await Proxies.directImageData(url),
           let down = downsample(data) {
            coverCache[track.id] = down
            via = "direct"
            return down
        }
        // 直链也失败：返回 nil，扩展画默认 ♪，不编封面。
        return nil
    }

    /// 下采样到 120px 宽的 JPEG（Live Activity 的 ContentState 有大小限制，
    /// 原图直接塞会超；照抄壳版「下采样 120px JPEG」的约定）。
    private func downsample(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let targetWidth: CGFloat = 120
        guard image.size.width > targetWidth else {
            // 第 20 轮：0.8 → 0.7（120px 实拍封面 q0.8 编后约 5.4KB 必超 4KB
            // 上限；最终预算由 LiveActivityManager.fittedState 强制执行）。
            return image.jpegData(compressionQuality: 0.7)
        }
        let scale = targetWidth / image.size.width
        let size = CGSize(width: targetWidth, height: image.size.height * scale)
        // r24：format.scale = 1（根因见 LiveActivityManager.thumbnail 注释——
        // 默认 format 用主屏 scale，@3x 手机上 "120px" 实际渲成 360px，
        // JPEG 约 25KB，进 fittedState 时原图档就必超 3800B 预算）。
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }
}
