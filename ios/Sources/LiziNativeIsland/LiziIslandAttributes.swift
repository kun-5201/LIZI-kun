import ActivityKit
import Foundation

/// 原生版灵动岛属性（r35-11：按 Apple Music 那套重加，目标是 Lizi 原生版
/// lizi kun，不是 kun；不要歌词、不要紧凑态缩略图）。
///
/// - 标题/歌手/进度/播放态/时长/喜欢态/封面全在 ContentState 里（不放
///   Attributes）：切歌只是状态更新，不用 end + 重新 request，岛不闪；
///   只有音乐停了才 end（见 LiveActivityCoordinator）。
/// - 没有任何歌词字段：岛和锁屏都不放歌词（用户 19:30 明确要求）。
/// - 封面是 App 在推送前压到约 120px 的 JPEG（nil = 没封面 / 还没到货，
///   视图画默认音符，不留空白）。
/// - 本文件同时编进 App target 与扩展 target（project.yml 里 LiziNative
///   的 sources 显式列了这一份，扩展 target 编整个目录），两边必须同一份，
///   别复制两份；只依赖 ActivityKit/Foundation。
struct LiziIslandAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 歌名。
        var title: String
        /// 歌手（空时视图显示平台名兜底，不编）。
        var artist: String
        /// 播放进度 0...1（时长未知时为 0）。
        var progress: Double
        /// 是否正在播放（暂停 = false，协调器见到 false 就 end 活动）。
        var isPlaying: Bool
        /// 总时长（秒，未知时为 0）；驱动展开页进度条两端的时间。
        var duration: Double = 0
        /// 是否已喜欢（展开页星标实心/空心）。
        var isLiked: Bool = false
        /// 专辑封面（约 120px JPEG，nil = 无封面）。
        var coverData: Data? = nil
    }
}
