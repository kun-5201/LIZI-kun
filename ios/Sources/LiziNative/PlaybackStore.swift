import Combine
import Foundation

/// 播放状态机骨架（P0：只有状态字段 + 空方法，P1 填音频引擎与取链编排）。
///
/// 状态字段按 NATIVE-REWRITE-PLAN.md §5-1：
/// 当前曲目 / 队列 / 播放态 / 进度 / 时长 / 喜欢态 / 加载态。
/// 任何方法现在都不产生副作用、不调服务、不碰 AVPlayer。
final class PlaybackStore: ObservableObject {
    /// 当前曲目；未播放时为 nil。
    @Published var currentTrack: Track?
    /// 播放队列（当前曲目在其中）。
    @Published var queue: [Track] = []
    /// 是否正在播放。
    @Published var isPlaying: Bool = false
    /// 当前进度（秒）。
    @Published var progress: TimeInterval = 0
    /// 当前曲目总时长（秒）；未知时为 0。
    @Published var duration: TimeInterval = 0
    /// 当前曲目是否已喜欢（星标）。
    @Published var isLiked: Bool = false
    /// 是否正在取链 / 加载。
    @Published var isLoading: Bool = false

    // MARK: - 控制方法（P0 空实现，P1 填充）

    /// 播放指定曲目（P1：走取链编排 → AVPlayer）。
    func play(_ track: Track) {
        // TODO(P1): 取链 + AVPlayer 播放 + 岛/锁屏更新。
    }

    /// 恢复播放（P1）。
    func resume() {
        // TODO(P1)
    }

    /// 暂停（P1）。
    func pause() {
        // TODO(P1)
    }

    /// 播放/暂停切换（P1）。
    func togglePlay() {
        // TODO(P1)
    }

    /// 下一首（P1）。
    func next() {
        // TODO(P1)
    }

    /// 上一首（P1）。
    func previous() {
        // TODO(P1)
    }

    /// 喜欢/取消喜欢当前曲目（P1）。
    func toggleLike() {
        // TODO(P1)
    }

    /// 跳到指定进度（秒）（P1）。
    func seek(to time: TimeInterval) {
        // TODO(P1)
    }
}
