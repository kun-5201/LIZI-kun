import Foundation
import SwiftUI

/// 首页状态（P1-B）：平台选择、来源选择、每日推荐拉取、上次播放持久化。
///
/// 数据来源只认 NativeBridge 的已定接口；没有接口的来源一律空态，不编假数据：
/// - 每日推荐：`NativeBridge.dailyRecommend(platform:)`——netease 需登录，
///   qq / kugou / kuwo / applemusic 走公开推荐，qishui / bodian 没有官方接口 → 空。
/// - 精选 / 我收藏的歌单 / 电台：原生桥暂无对应列表接口 → 空态（P2 按平台逐个接）。
/// - 我的喜欢：PlaybackStore 只把 id 存进 UserDefaults（见下面 likedKey），
///   没有曲目详情可恢复，P1 只显示已喜欢的首数，列表待 P2 补全。
@MainActor
final class HomeViewModel: ObservableObject {
    /// 来源切换（P1 用横向 chips 简化；壳版的球面滚轮是 P3 打磨项）。
    enum Source: String, CaseIterable {
        case daily      // 每日推荐
        case featured   // 精选
        case liked      // 我的喜欢
        case playlists  // 我收藏的歌单
        case radio      // 电台

        var title: String {
            switch self {
            case .daily: return "每日推荐"
            case .featured: return "精选"
            case .liked: return "我的喜欢"
            case .playlists: return "我收藏的歌单"
            case .radio: return "电台"
            }
        }

        var icon: String {
            switch self {
            case .daily: return "sun.max"
            case .featured: return "sparkles"
            case .liked: return "heart.fill"
            case .playlists: return "square.stack"
            case .radio: return "antenna.radiowaves.left.and.right"
            }
        }
    }

    // MARK: - 持久化键（原生版全部加 lizi.native 前缀，与壳版 localStorage 隔离）

    private static let platformKey = "lizi.native.hall.platform"
    private static let sourceKey = "lizi.native.hall.source"
    private static let lastTrackKey = "lizi.native.hall.lastTrack"
    /// 与 PlaybackStore.likedKey 同一个键（它在那边是 private，这里照抄字面量，
    /// 只读 id 列表，不改写）。
    private static let likedKey = "lizi.native.likedTrackIds"
    /// 跑马带速度：壳版 localStorage['lizi.hall.marq.speed'] 同款语义，
    /// 0–100，默认 24；可调 UI 放 P3，这里只读值。
    private static let marqSpeedKey = "lizi.native.hall.marq.speed"

    // MARK: - 状态

    /// 当前平台（netease / qq / kugou / qishui / bodian / kuwo / applemusic）。
    @Published var selectedPlatform: String = "netease"
    @Published var selectedSource: Source = .daily
    @Published var daily: [DailyTrack] = []
    @Published var isLoadingDaily = false
    /// 每日推荐为空时的诚实原因（nil = 有数据或正在加载）。
    @Published var dailyEmptyReason: String?
    /// 上次播放的歌（PlaybackStore.currentTrack 为空时 Hero 显示它）。
    @Published var lastTrack: Track?
    @Published var lastPlayedAt: Date?
    /// 已喜欢的曲目数（只有 id，没有详情，见文件头注释）。
    @Published var likedCount = 0

    /// 跑马带速度（px/帧，60fps 计）：照抄壳版 app.js marqSpeedOf，
    /// 默认 24 → 0.36 px/帧（比最初写死的 0.6 慢四成）。
    var marqSpeedPxPerSecond: CGFloat {
        let v = UserDefaults.standard.object(forKey: Self.marqSpeedKey) as? Double ?? 24
        let clamped = max(0, min(100, v.isFinite ? v : 24))
        return CGFloat((0.10 + clamped * 0.011) * 60)
    }

    // MARK: - 启动

    func initialLoad() async {
        loadPersistedSelection()
        loadLastTrack()
        refreshLikedCount()
        await loadDaily()
    }

    private func loadPersistedSelection() {
        if let p = UserDefaults.standard.string(forKey: Self.platformKey),
           LiziPlatforms.all.contains(where: { $0.id == p }) {
            selectedPlatform = p
        }
        if let raw = UserDefaults.standard.string(forKey: Self.sourceKey),
           let s = Source(rawValue: raw) {
            selectedSource = s
        }
    }

    // MARK: - 平台 / 来源切换（只换数据，不拆音频：不碰 PlaybackStore）

    /// 切平台：换台就回到新台的每日推荐（照抄壳版 Hall 换台即 railReset 的行为）。
    func selectPlatform(_ id: String) {
        guard id != selectedPlatform, LiziPlatforms.all.contains(where: { $0.id == id }) else { return }
        selectedPlatform = id
        UserDefaults.standard.set(id, forKey: Self.platformKey)
        selectedSource = .daily
        UserDefaults.standard.set(Source.daily.rawValue, forKey: Self.sourceKey)
        Task { await loadDaily() }
    }

    func selectSource(_ source: Source) {
        selectedSource = source
        UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
        if source == .daily {
            Task { await loadDaily() }
        } else if source == .liked {
            refreshLikedCount()
        }
    }

    // MARK: - 每日推荐

    func loadDaily() async {
        let platform = selectedPlatform
        isLoadingDaily = true
        dailyEmptyReason = nil
        let tracks = await NativeBridge.dailyRecommend(platform: platform)
        // 切台竞态：加载期间又切了台，旧结果直接丢掉。
        guard platform == selectedPlatform else { return }
        daily = tracks
        isLoadingDaily = false
        if tracks.isEmpty {
            dailyEmptyReason = emptyReason(for: platform)
        }
    }

    private func emptyReason(for platform: String) -> String {
        switch platform {
        case "netease":
            return "网易云每日推荐需要登录（登录流程在 P4），未登录时这里是空的。"
        case "qishui":
            return "汽水没有每日推荐官方接口，这里是空的，不编假数据。"
        case "bodian":
            return "波点没有每日推荐官方接口，这里是空的，不编假数据。"
        default:
            return "该平台今日没有返回推荐内容。"
        }
    }

    // MARK: - 上次播放（照抄壳版 lizi.hall.lastTrack：重启还在）

    private struct SavedLastTrack: Codable {
        var track: Track
        var at: Date
    }

    /// 当前在播的歌变化时由 HomeView 调入，记下曲目 + 时间。
    func notePlayed(_ track: Track) {
        lastTrack = track
        lastPlayedAt = Date()
        let saved = SavedLastTrack(track: track, at: lastPlayedAt ?? Date())
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.lastTrackKey)
        }
    }

    private func loadLastTrack() {
        guard let data = UserDefaults.standard.data(forKey: Self.lastTrackKey),
              let saved = try? JSONDecoder().decode(SavedLastTrack.self, from: data) else { return }
        lastTrack = saved.track
        lastPlayedAt = saved.at
    }

    func refreshLikedCount() {
        likedCount = UserDefaults.standard.stringArray(forKey: Self.likedKey)?.count ?? 0
    }
}

/// 七家平台清单（顺序与壳版 hall/accounts.js 注册表一致）。
/// 图标方案见 PlatformStripView：品牌色 + 首字 monogram 瓷砖；
/// public/assets/platforms/*.svg 的 iconfont 路径数据约 1KB/个，
/// 手抄进 SwiftUI Path 容易抄错字形，P1 不逐字转录，P3 再以 PDF/PNG 资源替换。
enum LiziPlatforms {
    struct Info {
        var id: String
        var name: String
        /// 瓷砖上的单字。
        var monogram: String
        /// 品牌底色（取自各平台 svg / accounts.js accent）。
        var brandHex: Int
        /// 瓷砖上的字色（亮底用墨色，暗底用白色）。
        var onBrandLight: Bool
    }

    static let all: [Info] = [
        Info(id: "netease", name: "网易云", monogram: "网", brandHex: 0xEA3E3C, onBrandLight: false),
        Info(id: "qq", name: "QQ 音乐", monogram: "Q", brandHex: 0xF8C913, onBrandLight: true),
        Info(id: "kugou", name: "酷狗", monogram: "K", brandHex: 0x2CA2F9, onBrandLight: false),
        Info(id: "qishui", name: "汽水", monogram: "汽", brandHex: 0x111111, onBrandLight: false),
        Info(id: "bodian", name: "波点", monogram: "波", brandHex: 0x04E3B4, onBrandLight: true),
        Info(id: "kuwo", name: "酷我音乐", monogram: "酷", brandHex: 0xF4D329, onBrandLight: true),
        Info(id: "applemusic", name: "Apple Music", monogram: "♪", brandHex: 0xFA2D48, onBrandLight: false),
    ]
}
