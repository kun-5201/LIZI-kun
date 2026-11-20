import Foundation
import SwiftUI

/// 首页状态：平台选择、每日推荐拉取、上次播放持久化。
///
/// r26（用户 2026-11-20 22:39–22:40 决定）：首页 5 个来源 chips 全删、
/// 只留每日推荐。来源切换（`Source` 枚举 / `selectedSource` /
/// `selectSource` / 四条 rails 的 `rails` / `railLoading` / `loadRail` /
/// `openRail` / `RailSelection`）随 chips 一起删掉；本文件只剩每日推荐
/// 一路。删掉的 4 个来源（精选 / 我的喜欢 / 我收藏的歌单 / 电台）的
/// 取数层（`RailsBridge.swift` 的 `railFeatured / railLiked /
/// railMyPlaylists / railRadio` + `RailDetailView` + 导航 `.rail`）保留，
/// 等图纸批了接新入口时复用，不在这里重写。
/// 数据来源只认 NativeBridge 的已定接口，不编假数据：
/// - 每日推荐：`NativeBridge.dailyRecommend(platform:)`——netease 登录后
///   真每日推荐、未登录退到推荐新歌（personalized）；qq 登录后每日推荐、
///   未登录退到雷达推荐；qishui 走推荐流、bodian 走潮趣日推、kuwo /
///   kugou / applemusic 走各家公开推荐（r24 第 1 件逐平台核对，见
///   NativeBridge.dailyRecommend 注释；7 家都有每日内容，没有空接口）。
@MainActor
final class HomeViewModel: ObservableObject {
    // MARK: - 持久化键（原生版全部加 lizi.native 前缀，与壳版 localStorage 隔离）

    private static let platformKey = "lizi.native.hall.platform"
    private static let lastTrackKey = "lizi.native.hall.lastTrack"
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
    @Published var daily: [DailyTrack] = []
    @Published var isLoadingDaily = false
    /// 每日推荐为空时的诚实原因（nil = 有数据或正在加载）。
    @Published var dailyEmptyReason: String?
    /// 上次播放的歌（PlaybackStore.currentTrack 为空时 Hero 显示它）。
    @Published var lastTrack: Track?
    @Published var lastPlayedAt: Date?

    /// 跑马带速度（px/帧，60fps 计）：照抄壳版 app.js marqSpeedOf，
    /// 默认 24 → 0.36 px/帧（比最初写死的 0.6 慢四成）。
    var marqSpeedPxPerSecond: CGFloat {
        let v = UserDefaults.standard.object(forKey: Self.marqSpeedKey) as? Double ?? 24
        let clamped = max(0, min(100, v.isFinite ? v : 24))
        return CGFloat((0.10 + clamped * 0.011) * 60)
    }

    /// 首页加载代际（Moumusic HomeViewModel.loadGeneration 同款，只管首页
    /// daily 加载的过期丢弃：每次切台 +1，旧加载回来对不上代际直接丢。
    /// 取链的 resolveGeneration 在 PlaybackStore（store 侧、闪退工人落地），
    /// 这里不另建取链计数器——两个计数器各管各的 owner，和 Moumusic 一致：
    /// HomeViewModel.loadGeneration 管首页，PlayerService.resolveGeneration 管取链）。
    private var homeLoadGeneration = 0
    /// 进行中的首页加载句柄（切台时先 cancel 再起新的；Moumusic loadTask 同款）。
    /// daily 一条；initialLoad 的直接 await 不走这里（启动时没东西可取消）。
    private var dailyTask: Task<Void, Never>?

    // MARK: - 启动

    func initialLoad() async {
        loadPersistedSelection()
        loadLastTrack()
        await loadDaily()
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
    /// 4. 立即重建首页模型（Moumusic resetContent）：旧平台的 daily
    ///    当场下掉，不等新数据回来才清。
    /// 5. 起新加载（带代际守卫；旧任务回来对不上代际直接丢）。
    /// 登录态：Moumusic 的 selectHomePlatform 不碰 AccountStore，登录态
    /// 只在 load 时当参数传进去（loadCurrentHome 传 account.isLoggedIn）；
    /// Lizi 同理——切台不查登录，各平台的登录分支在
    /// NativeBridge.dailyRecommend 内部（网易需登录才有每日推荐，
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
        selectedPlatform = id
        UserDefaults.standard.set(id, forKey: Self.platformKey)
        resetHomeContent()
        dailyTask = Task { await loadDaily(generation: generation) }
    }

    /// 立即清空首页模型（Moumusic resetContent 同款）：切台瞬间旧平台的
    /// 内容全部下掉；isLoadingDaily 置 true，等新 loadDaily 回来再落
    /// false / 空原因。
    private func resetHomeContent() {
        daily = []
        dailyEmptyReason = nil
        isLoadingDaily = true
    }

    // MARK: - 每日推荐

    /// 每日推荐。generation：调用方传入切台时定的代际（selectPlatform），
    /// 不传则取调用瞬间的 homeLoadGeneration（initialLoad）。
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
