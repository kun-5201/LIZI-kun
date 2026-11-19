import Foundation
import SwiftUI

/// 首页状态（P1-B）：平台选择、来源选择、每日推荐拉取、上次播放持久化。
///
/// 数据来源只认 NativeBridge 的已定接口；没有接口的来源一律空态，不编假数据：
/// - 每日推荐：`NativeBridge.dailyRecommend(platform:)`——netease 需登录，
///   qq / kugou / kuwo / applemusic 走公开推荐，qishui / bodian 没有官方接口 → 空。
/// - 精选 / 喜欢 / 我收藏的歌单 / 电台（P2）：`NativeBridge.railFeatured /
///   railLiked / railMyPlaylists / railRadio`（见 Views/Home/RailsBridge.swift），
///   逐平台映射照抄壳版 rail* 函数；喜欢 rail 的标题按平台取真名
///   （`RailKind.likedTitle(for:)`：网易 / 汽水「我喜欢的音乐」、
///   QQ「我喜欢」、波点未核实到保持「我的喜欢」、
///   酷狗 / 酷我 / Apple Music 无接口叫「本地星标收藏」）；
///   需要登录的 rail 在未登录态显示诚实空态
///   （登录迁移是 P4），没有接口的平台显示接口缺失原因，本地星标兜底的
///   平台（kugou / kuwo / applemusic 的喜欢）读 PlaybackStore.likedTracks()。
/// - 喜欢 rail：P2 起 PlaybackStore 同时持久化完整 Track
///   （键 "lizi.native.likedTracks"）；P2 之前点的星标只有 id，恢复不出来。
@MainActor
final class HomeViewModel: ObservableObject {
    /// 来源切换（P1 用横向 chips 简化；壳版的球面滚轮是 P3 打磨项）。
    enum Source: String, CaseIterable {
        case daily      // 每日推荐
        case featured   // 精选
        case liked      // 喜欢 rail（标题按平台取真名，见 title(for:)）
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

        /// 来源 chip 的展示标题：只有 liked 按当前平台取真名
        /// （`RailKind.likedTitle(for:)`，与 rail 行标题、详情页标题同一份
        /// 事实来源）；其余来源用固定 title。`title` 属性保留作通用回落
        /// （未用在 live 路径上，只剩死代码 SourceEmptyView 在用）。
        func title(for platform: String) -> String {
            self == .liked ? RailKind.likedTitle(for: platform) : title
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

        /// 该来源对应的 rail（daily 没有 rail，走每日推荐跑马带）。
        var railKind: RailKind? {
            switch self {
            case .daily: return nil
            case .featured: return .featured
            case .liked: return .liked
            case .playlists: return .playlists
            case .radio: return .radio
            }
        }
    }

    /// rail 详情页的打开目标（kind + 拉取时的平台）。
    /// 导航缝合：工人 A 落地 AppNavigation `.rail(kind:platform:)` 后，
    /// HomeView 把 sheet 改成 `nav.show(.rail(kind:platform:))`，本 struct
    /// 的字段名已按该约定取，详情页 RailDetailView 的初始化器不用改。
    struct RailSelection: Identifiable, Hashable {
        var kind: RailKind
        var platform: String

        var id: String { "\(kind.rawValue)|\(platform)" }
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
    /// 四条 rails 的拉取结果（按 kind 存；切台 / 切来源时按需加载）。
    @Published var rails: [RailKind: RailResult] = [:]
    /// 四条 rails 各自的加载态。
    @Published var railLoading: [RailKind: Bool] = [:]
    /// 正在打开的 rail 详情页（nil = 没打开；HomeView 用 sheet 呈现，
    /// 工人 A 落地导航 case 后改走 nav.show(.rail(...))，见 RailSelection）。
    @Published var selectedRail: RailSelection?

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
        if let kind = selectedSource.railKind {
            await loadRail(kind)
        }
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
            Task { await loadRail(.liked) }
        } else if let kind = source.railKind {
            Task { await loadRail(kind) }
        }
    }

    // MARK: - 四条 rails（P2）

    /// 拉一条 rail（当前平台；加载期间又切了台，旧结果直接丢掉，和 loadDaily 同款竞态处理）。
    func loadRail(_ kind: RailKind) async {
        let platform = selectedPlatform
        railLoading[kind] = true
        let result: RailResult
        switch kind {
        case .featured:
            result = await NativeBridge.railFeatured(platform: platform)
        case .liked:
            result = await NativeBridge.railLiked(platform: platform)
        case .playlists:
            result = await NativeBridge.railMyPlaylists(platform: platform)
        case .radio:
            result = await NativeBridge.railRadio(platform: platform)
        }
        guard platform == selectedPlatform else {
            railLoading[kind] = false
            return
        }
        rails[kind] = result
        railLoading[kind] = false
    }

    /// 打开一条 rail 的详情页（HomeView 用 sheet 呈现；导航 case 落地后改走 nav）。
    func openRail(_ kind: RailKind) {
        selectedRail = RailSelection(kind: kind, platform: selectedPlatform)
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
/// 图标方案见 PlatformStripView：真 logo（`Assets.xcassets` 里的
/// `Platform<Name>` imageset，由 `public/assets/platforms/*.svg` 渲染成
/// 48/96/144 PNG；酷狗用自含蓝底的 `kugou.svg`，不用纯白的
/// `kugou-mark.svg`）。`monogram` / `brandHex` 保留作兜底与平台管理文案，
/// 图标渲染本身不再用它们。
enum LiziPlatforms {
    struct Info {
        var id: String
        var name: String
        /// Asset Catalog 里的 logo 资源名。
        var assetName: String
        /// 瓷砖上的单字（旧 P1 方案，保留作兜底）。
        var monogram: String
        /// 品牌底色（取自各平台 svg / accounts.js accent；保留作兜底）。
        var brandHex: Int
        /// 瓷砖上的字色（亮底用墨色，暗底用白色；保留作兜底）。
        var onBrandLight: Bool
    }

    static let all: [Info] = [
        Info(id: "netease", name: "网易云", assetName: "PlatformNetease", monogram: "网", brandHex: 0xEA3E3C, onBrandLight: false),
        Info(id: "qq", name: "QQ 音乐", assetName: "PlatformQQ", monogram: "Q", brandHex: 0xF8C913, onBrandLight: true),
        Info(id: "kugou", name: "酷狗", assetName: "PlatformKugou", monogram: "K", brandHex: 0x2CA2F9, onBrandLight: false),
        Info(id: "qishui", name: "汽水", assetName: "PlatformQishui", monogram: "汽", brandHex: 0x111111, onBrandLight: false),
        Info(id: "bodian", name: "波点", assetName: "PlatformBodian", monogram: "波", brandHex: 0x04E3B4, onBrandLight: true),
        Info(id: "kuwo", name: "酷我音乐", assetName: "PlatformKuwo", monogram: "酷", brandHex: 0xF4D329, onBrandLight: true),
        Info(id: "applemusic", name: "Apple Music", assetName: "PlatformAppleMusic", monogram: "♪", brandHex: 0xFA2D48, onBrandLight: false),
    ]
}
