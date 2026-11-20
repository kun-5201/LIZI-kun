import Foundation
import SwiftUI

/// 首页状态（P1-B）：平台选择、来源选择、每日推荐拉取、上次播放持久化。
///
/// 数据来源只认 NativeBridge 的已定接口；没有接口的来源一律空态，不编假数据：
/// - 每日推荐：`NativeBridge.dailyRecommend(platform:)`——netease 登录后
///   真每日推荐、未登录退到推荐新歌（personalized）；qq 登录后每日推荐、
///   未登录退到雷达推荐；qishui 走推荐流、bodian 走潮趣日推、kuwo /
///   kugou / applemusic 走各家公开推荐（r24 第 1 件逐平台核对，见
///   NativeBridge.dailyRecommend 注释；7 家都有每日内容，没有空接口）。
/// - 精选 / 喜欢 / 我收藏的歌单 / 电台（P2）：`NativeBridge.railFeatured /
///   railLiked / railMyPlaylists / railRadio`（见 Views/Home/RailsBridge.swift），
///   逐平台映射照抄壳版 rail* 函数；喜欢 rail 的标题按平台取真名
///   （`RailKind.likedTitle(for:)`：网易 / 汽水「我喜欢的音乐」、
///   QQ「我喜欢」、波点未核实到保持「我的喜欢」、
///   酷我 / 酷狗 / Apple Music 无接口叫「本地星标收藏」）；
///   需要登录的 rail 在未登录态显示诚实空态
///   （登录迁移是 P4），没有接口的平台显示接口缺失原因，本地星标兜底的
///   平台（kuwo / kugou / applemusic 的喜欢）读 PlaybackStore.likedTracks()。
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

    /// 当前平台（netease / qq / qishui / bodian / kuwo / applemusic）。
    ///
    /// r23h：不要写死 "netease"——RootView 按 nav.current 切页，进播放页
    /// 就销毁 HomeView、回首页新建一个 HomeViewModel；写死默认值会让每次
    /// 回首页的第一帧（以及持久化键缺失/非法时全程）都先变网易云红，
    /// 面板跟着变粉（07:09 真机）。声明时就读持久化值（initialPlatform()），
    /// loadPersistedSelection 再读一次同一份 helper，不另起事实来源。
    @Published var selectedPlatform: String = HomeViewModel.initialPlatform()

    /// r22j 平台管理：首页平台条显示的平台 = 设置 → 平台管理勾选的平台
    /// （默认全部 7 个）。只读 UserDefaults（`SettingsStore
    /// .readVisiblePlatforms`，壳版 `lizi.platforms.v1` 语义 + seen 表），
    /// 不写、不缓存——设置页改完回首页时 viewModel 新建，读到的就是最新
    /// 勾选。切台逻辑不动；选中平台被取消勾选时的自动切换在 HomeView
    /// .task 里调 selectPlatform（不另写切台）。
    var visiblePlatforms: Set<String> { SettingsStore.readVisiblePlatforms() }
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

    /// 首页加载代际（Moumusic HomeViewModel.loadGeneration 同款，只管首页
    /// daily/rail 加载的过期丢弃：每次切台 +1，旧加载回来对不上代际直接丢。
    /// 取链的 resolveGeneration 在 PlaybackStore（store 侧、闪退工人落地），
    /// 这里不另建取链计数器——两个计数器各管各的 owner，和 Moumusic 一致：
    /// HomeViewModel.loadGeneration 管首页，PlayerService.resolveGeneration 管取链）。
    private var homeLoadGeneration = 0
    /// 进行中的首页加载句柄（切台时先 cancel 再起新的；Moumusic loadTask 同款）。
    /// daily 一条、rail 按 kind 各一条；initialLoad 的直接 await 不走这里
    ///（启动时没东西可取消）。
    private var dailyTask: Task<Void, Never>?
    private var railTasks: [RailKind: Task<Void, Never>] = [:]

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

    /// 读持久化平台的唯一入口（声明初值 + initialLoad 共用）：键里有合法
    /// id 就用它，没有（新装 / 数据被清 / 旧值非法）才回落 "netease"。
    /// 播放路径不写这把键（全仓唯一写点是 selectPlatform），所以读到的
    /// 就是用户上次点的平台，不是播放后变的。
    private static func initialPlatform() -> String {
        if let p = UserDefaults.standard.string(forKey: Self.platformKey),
           LiziPlatforms.all.contains(where: { $0.id == p }) {
            return p
        }
        return "netease"
    }

    private func loadPersistedSelection() {
        selectedPlatform = Self.initialPlatform()
        if let raw = UserDefaults.standard.string(forKey: Self.sourceKey),
           let s = Source(rawValue: raw) {
            selectedSource = s
        }
    }

    // MARK: - 平台 / 来源切换（切台只换数据：Moumusic 切台不碰
    // PlayerService 的队列与当前曲目；唯一碰播放侧的动作是取消在飞的
    // 取链任务——经 playbackStore.advanceGeneration()，不停已在播的音频、
    // 不清队列、不 pause、不 stop）

    /// 切平台：唯一入口（PlatformStripView 点图标只调这里）。
    ///
    /// 照 Moumusic 的做法，分五步，顺序不能换：
    /// 1. 先取消取链：Moumusic PlayerService.startPlaying 1219–1221 行
    ///    新请求先 cancel 旧的 resolveTask/lyricsTask/translationTask，
    ///    1260 行 resolveGeneration += 1；切台同理，先调
    ///    `playbackStore.advanceGeneration()`（代际+1 并取消所有进行中的
    ///    取链/歌词/音质任务）。store 侧 API 由闪退工人补齐（见交回报告）；
    ///    未补齐前本调用编译不过。playbackStore 为 nil 时跳过取消
    ///    （只做首页侧的取消与重建，不拦切台）。
    /// 2. 取消进行中的首页加载 + 首页代际+1（Moumusic HomeViewModel.load：
    ///    loadTask?.cancel() 后 loadGeneration += 1）。
    /// 3. 再改平台并持久化（Moumusic selectHomePlatform：先写 mode 再写
    ///    platform，成对写完才触发加载；Lizi 只有一个 platform 值，
    ///    同样先写完再起加载，不存在半更新的一对）。
    /// 4. 立即重建首页模型（Moumusic resetContent）：旧平台的 daily /
    ///    rails / 详情页当场下掉，不等新数据回来才清。
    /// 5. 起新加载（带代际守卫；旧任务回来对不上代际直接丢）。
    /// 登录态：Moumusic 的 selectHomePlatform 不碰 AccountStore，登录态
    /// 只在 load 时当参数传进去（loadCurrentHome 传 account.isLoggedIn）；
    /// Lizi 同理——切台不查登录，各平台的登录分支在
    /// NativeBridge.dailyRecommend / rail* 内部（网易需登录才有每日推荐，
    /// 否则诚实空态），selectPlatform 不动它。
    /// 队列 / 正在播的歌：Moumusic 切台不碰 PlayerService，队列与当前曲目
    /// 原样保留（曲目自带来源，解析走选定的 LX 源）；Lizi 同理，这里不调
    /// stop()/clearQueue()/pause()，正在播的歌继续播。
    func selectPlatform(_ id: String, playbackStore: PlaybackStore? = nil) {
        guard id != selectedPlatform, LiziPlatforms.all.contains(where: { $0.id == id }) else { return }
        playbackStore?.advanceGeneration()
        homeLoadGeneration += 1
        let generation = homeLoadGeneration
        dailyTask?.cancel()
        dailyTask = nil
        railTasks.values.forEach { $0.cancel() }
        railTasks = [:]
        selectedPlatform = id
        UserDefaults.standard.set(id, forKey: Self.platformKey)
        selectedSource = .daily
        UserDefaults.standard.set(Source.daily.rawValue, forKey: Self.sourceKey)
        resetHomeContent()
        dailyTask = Task { await loadDaily(generation: generation) }
    }

    /// 立即清空首页模型（Moumusic resetContent 同款）：切台瞬间旧平台的
    /// 内容全部下掉；isLoadingDaily 置 true，等新 loadDaily 回来再落
    /// false / 空原因。selectedRail 一并关掉——详情页属于旧平台
    ///（RailSelection 里带旧 platform），留着会拿旧台数据继续展示。
    private func resetHomeContent() {
        daily = []
        rails = [:]
        railLoading = [:]
        dailyEmptyReason = nil
        selectedRail = nil
        isLoadingDaily = true
    }

    func selectSource(_ source: Source) {
        selectedSource = source
        UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
        if source == .daily {
            dailyTask?.cancel()
            dailyTask = Task { await loadDaily() }
        } else if source == .liked {
            refreshLikedCount()
            railTasks[.liked]?.cancel()
            railTasks[.liked] = Task { await loadRail(.liked) }
        } else if let kind = source.railKind {
            railTasks[kind]?.cancel()
            railTasks[kind] = Task { await loadRail(kind) }
        }
    }

    // MARK: - 四条 rails（P2）

    /// 拉一条 rail（当前平台；加载期间又切了台，旧结果直接丢掉，和 loadDaily 同款竞态处理）。
    /// 代际守卫：Moumusic loadOnce 里每个 await 后都查 generation，
    /// 对不上直接退、不碰任何状态（连 railLoading 也不碰——新加载自己会置）。
    func loadRail(_ kind: RailKind) async {
        let platform = selectedPlatform
        let generation = homeLoadGeneration
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
        guard generation == homeLoadGeneration, platform == selectedPlatform, !Task.isCancelled else {
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

    /// 每日推荐。generation：调用方传入切台时定的代际（selectPlatform），
    /// 不传则取调用瞬间的 homeLoadGeneration（selectSource / initialLoad）。
    /// 代际守卫：Moumusic loadOnce 里每个 await 后都查 generation，
    /// 对不上直接退、不碰任何状态。
    func loadDaily(generation: Int? = nil) async {
        let platform = selectedPlatform
        let generation = generation ?? homeLoadGeneration
        isLoadingDaily = true
        dailyEmptyReason = nil
        let tracks = await NativeBridge.dailyRecommend(platform: platform)
        // 切台竞态：加载期间又切了台（代际变了）或任务被取消，旧结果直接丢掉。
        guard generation == homeLoadGeneration, platform == selectedPlatform, !Task.isCancelled else { return }
        daily = tracks
        isLoadingDaily = false
        if tracks.isEmpty {
            dailyEmptyReason = emptyReason(for: platform)
        }
    }

    private func emptyReason(for platform: String) -> String {
        switch platform {
        case "netease":
            return "网易云每日推荐和推荐新歌都没返回内容（登录后是真每日推荐，未登录退到推荐新歌），请检查网络后重试。"
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

/// 六家平台清单（顺序与壳版 hall/accounts.js 注册表一致）。
/// 图标方案见 PlatformStripView：真 logo（`Assets.xcassets` 里的
/// `Platform<Name>` imageset，由 `public/assets/platforms/*.svg` 渲染成
/// 48/96/144 PNG）。`monogram` / `brandHex` 保留作兜底与平台管理文案，
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
        Info(id: "kugou", name: "酷狗", assetName: "PlatformKugou", monogram: "K", brandHex: 0x3D8BFA, onBrandLight: false),
        Info(id: "qishui", name: "汽水", assetName: "PlatformQishui", monogram: "汽", brandHex: 0x111111, onBrandLight: false),
        Info(id: "bodian", name: "波点", assetName: "PlatformBodian", monogram: "波", brandHex: 0x04E3B4, onBrandLight: true),
        Info(id: "kuwo", name: "酷我音乐", assetName: "PlatformKuwo", monogram: "酷", brandHex: 0xF4D329, onBrandLight: true),
        Info(id: "applemusic", name: "Apple Music", assetName: "PlatformAppleMusic", monogram: "♪", brandHex: 0xFA2D48, onBrandLight: false),
    ]
}
