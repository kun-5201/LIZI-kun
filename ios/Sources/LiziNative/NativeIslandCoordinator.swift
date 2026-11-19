import Combine
import Foundation
import UIKit

/// 灵动岛接线（P1 新写）：PlaybackStore → LiveActivityManager。
///
/// 推送节流（照抄壳版 LiveActivityManager 的约定）：
/// - 行变 / 切歌 / 播放切换 → 立刻推；
/// - 进度 → 最多 5 秒推一次；
/// - 暂停 → 推一次暂停态，之后不再推，岛靠 staleDate（10 秒）自然消失；
/// - 无词显示歌名（currentLyric 回落到标题），绝不用 ♪ 作假歌词；
/// - 封面：代理（/api/img 进程内调 Proxies，含 mzstatic 白名单）→ 直链 → 默认图
///   （nil，扩展画 ♪ 占位），下采样 120px JPEG。
///
/// 注意：刻意不用 @MainActor（见 PlaybackStore 的注释）——订阅回调与
/// LiveActivityManager 的调用都在主线程上跑（调用点 Task { @MainActor in }）。
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
    /// 最近一次推过的歌词行下标（行没变不重复推）。
    private var lastLyricIndex: Int = -2

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

        // 行变：立刻推。
        store.$currentLyricIndex
            .sink { [weak self] idx in
                guard let self else { return }
                Task { @MainActor in
                    guard self.currentTrackId != nil, idx != self.lastLyricIndex else { return }
                    self.lastLyricIndex = idx
                    await self.pushNow()
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
        lastLyricIndex = -2
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

    /// 当前快照：无词显示歌名（currentLyric 回落到标题）。
    private func snapshot(coverData: Data?) -> LiziLyricsAttributes.ContentState {
        let track = store.currentTrack
        let lines = store.lyrics
        let idx = store.currentLyricIndex
        let current = (idx >= 0 && idx < lines.count) ? lines[idx].text : (track?.title ?? "")
        let prev = (idx > 0 && idx - 1 < lines.count) ? lines[idx - 1].text : nil
        let next = (idx >= 0 && idx + 1 < lines.count) ? lines[idx + 1].text : nil
        let duration = store.duration > 0 ? store.duration : (track?.durationSeconds ?? 0)
        let progress = duration > 0 ? max(0, min(1, store.progress / duration)) : 0
        return LiziLyricsAttributes.ContentState(
            currentLyric: current,
            prevLyric: prev,
            nextLyric: next,
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
        // 1) 走图片代理（进程内调 Proxies.proxyImage：白名单 + 防盗链 Referer，
        //    含第 15 轮的 .mzstatic.com；代理 403 时记诊断、不拦直链）。
        let proxyReq = HttpRequest(method: "GET", path: "/api/img",
                                   query: ["url": url.absoluteString], headers: [:], body: Data())
        let proxyResp = await Proxies.proxyImage(proxyReq)
        if (200...299).contains(proxyResp.status),
           let data = downsample(proxyResp.body) {
            coverCache[track.id] = data
            return data
        }
        // 2) 直链。
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let down = downsample(data) {
                coverCache[track.id] = down
                return down
            }
        } catch {
            // 直链也失败：返回 nil，扩展画默认 ♪，不编封面。
        }
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
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }
}
