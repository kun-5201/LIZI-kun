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
///
/// r28（用户 2026-11-21 01:21–01:38 定稿）：删掉的 4 个来源加回，
/// 不再是 chips——每日推荐面板改成上下翻页（一次一个栏目，共 6 栏，
/// 见 `HomeRailPage`）：每日推荐 → 精选 → 用户收藏 → 喜欢的歌曲 →
/// 用户创建的歌单 → 电台。分页器状态（当前栏下标、6 栏顺序、各栏缓存）
/// 全放本文件；每日推荐那一栏仍走修好的 `loadDaily` 链路（两步守卫、
/// dailyTask、25s 超时壳一字不动），其余 5 栏首次访问时拉取、之后缓存。
/// r35：缓存升级成进程内单例 `HomeDataCache.shared`（见
/// HomeDataCache.swift）——切台/模型重建都不再清缓存，只拉一次。
/// 数据来源只认 NativeBridge 的已定接口，不编假数据：
/// - 每日推荐：`NativeBridge.dailyRecommend(platform:)`——netease 登录后
///   真每日推荐、未登录退到推荐新歌（personalized）；qq 登录后每日推荐、
///   未登录退到雷达推荐；qishui 走推荐流、bodian 走潮趣日推、kuwo /
///   kugou / applemusic 走各家公开推荐（r24 第 1 件逐平台核对，见
///   NativeBridge.dailyRecommend 注释；7 家都有每日内容，没有空接口）。
///
/// r30（用户 2026-11-21：首页 v4 图定稿）：r28 的上下翻页器整套撤掉——
/// `HomeRailPagerView.swift`（含 `HomeRailPageView`）删文件、`railPageIndex` /
/// `railPage` / `railPageTitle` / `showRailPage` / `moveRailPage` 全删；
/// 来源改成点平台条标题弹小菜单切（壳版 `#hall-src-menu` 思路），
/// 状态只剩 `selectedSource` + `selectSource(_:)`；取数层
/// （`railResults` / `loadRailPage` / `railEntries` / `railEmptyReason`）
/// 原样保留、只换触发点，`HomeRailPage` 枚举改叫来源列表（顺序与标题不变）。
/// 注：`selectedSource` / `selectSource` 的名字与 r26 删掉的旧
/// `Source` 枚举那套同名，但不是同一套——r26 那套是 chips 的
/// `Source` 枚举，r30 这套是 `HomeRailPage` 来源。
///
/// r31（用户 2026-11-21 06:02–06:05 决定，三件一起落地）：
/// - 「用户收藏」来源删掉，只剩 5 项（每日推荐 / 精选 / 我喜欢 / 我的歌单 /
///   电台）；它的数据全并进「我喜欢」（见 `RailsBridge.railLiked` 各平台
///   收藏合并：网易 subscribed 歌单、QQ 收藏歌单+专辑、酷狗非自有歌单+专辑、
///   汽水非自有歌单、波点收藏歌单+专辑；酷我/Apple Music 没有官方收藏接口，
///   只有本地星标，不编）。
/// - 「用户创建的歌单」改名「我的歌单」（只改名，入口和逻辑不动），里面只留
///   用户自建的歌单（各家按 subscribed / isOwned 标记分流，见
///   `RailsBridge.railMyPlaylists`）。
/// - 面板内打开歌单/专辑（`openedPlaylist` / `openedAlbum`，见本文件末尾）：
///   点「我的歌单」/「我喜欢」里的歌单或专辑卡，不跳详情页，面板原地换成
///   该集合的全部歌曲卡片（曲目走 `railPlaylistTracks` / `albumDetail`
///   全量取数），返回键回列表。
///
/// r31-daily（用户 2026-11-21 05:58 每日推荐无限转圈）：`loadDaily`
/// 改成 defer 结算 spinner（五条返回路径都落下）+ 用
/// `NativeBridge.dailyRecommend` 回的 `DailyResult`（曲目 + 空原因，
/// 未登录 / 没网说清）；超时壳改成弃子竞速（取数腿跑脱离 Task，
/// 壳里只竞 `task.value` 与 25s 睡眠），见两处函数头注释。
@MainActor
final class HomeViewModel: ObservableObject {
    // MARK: - 持久化键（原生版全部加 lizi.native 前缀，与壳版 localStorage 隔离）

    private static let platformKey = "lizi.native.hall.platform"
    /// r33 第 4 件：来源持久化键（存 HomeRailPage.rawValue Int；平台持久化
    /// 同款做法）。RootView 按 nav.current 切页会销毁 HomeView、回首页
    /// 新建 HomeViewModel，不持久化时 selectedSource 默认回 .daily，
    /// 播完/回首页就跳回每日推荐。
    private static let sourceKey = "lizi.native.hall.source"
    static let lastTrackKey = "lizi.native.hall.lastTrack"
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
    /// 每日推荐 spinner 是否可见（r35-9，P0-2：套壳 250ms 保留旧内容同款）：
    /// 加载开始先保留旧内容，250ms 后仍未回来才置 true 亮 spinner；
    /// 250ms 内回来全程不闪。视图只认这面旗子亮 spinner，不认 isLoadingDaily。
    @Published private(set) var dailySpinnerVisible = false
    /// 延迟亮 spinner 的代际（loadDaily 每次起手 +1；旧的延迟任务回来
    /// 对不上就不亮，不串味到下一单）。
    private var dailySpinnerEpoch = 0
    /// r37-6（每日推荐一直转圈）：本次每日加载的起始时间 + 看门狗代际。
    /// loadDaily 的 defer + 120 秒整链超时本应保证落下，但 defer 只在
    /// loadDaily 任务本身返回时跑——桥接层里若有不响应取消的挂起
    /// （或 .task 取消后孤儿任务丢了结算），isLoadingDaily 仍能永久
    /// 留在 true；看门狗是最后一道：起手 130 秒（整链 120 秒预算之外，
    /// 不推翻 r35-9 的每腿 60 秒/整链 120 秒），同代际仍在加载就强制
    /// 落到带文案的空态，绝不停在加载中。
    private var dailyLoadStartedAt: Date?
    private var dailyWatchdogEpoch = 0
    /// 每日推荐为空时的诚实原因（nil = 有数据或正在加载）。
    @Published var dailyEmptyReason: String?
    /// 排行榜目录（r35-10；r36：落点从面板内一块改成来源菜单里的一项，
    /// 用法改成排行榜来源面板；取数仍与每日推荐同批起、缓存照旧）。
    /// 没榜的平台（波点/汽水/Apple Music）不发请求，emptyReason 是
    /// NativeBridge.rankBoards 给的诚实文案，ViewModel 不走缓存。
    @Published var rankBoards: [RankBoard] = []
    @Published var isLoadingRank = false
    /// 排行榜 spinner 是否可见（r35-9 P0-2 同款 250ms 保留旧内容：
    /// 加载开始先保留旧榜，250ms 后仍未回来才置 true）。
    @Published private(set) var rankSpinnerVisible = false
    private var rankSpinnerEpoch = 0
    /// 排行榜为空/没榜时的诚实原因（nil = 有榜或正在加载）。
    @Published var rankEmptyReason: String?
    /// 进行中的排行榜加载句柄（切台时先 cancel 再起新的；dailyTask 同款）。
    private var rankTask: Task<Void, Never>?
    /// 上次播放的歌（PlaybackStore.currentTrack 为空时 Hero 显示它）。
    @Published var lastTrack: Track?
    @Published var lastPlayedAt: Date?

    /// 跑马带速度（px/s；r31 起 display link 每帧走 `速度 × 真实帧间隔 dt`，
    /// 见 HomeCoverRingView.tickFlat(dt:)，所以本值本身就是 px/s）。
    /// r28：壳版 app.js marqSpeedOf 的斜率是 0.011，默认 24 →
    /// (0.10 + 24×0.011)×60 = 21.84 px/s；规格（ring.js
    /// MARQUEE_SPEED）要 24 px/s，斜率改 0.0125：
    /// (0.10 + 24×0.0125)×60 = 0.40×60 = 24 px/s。
    /// 与壳版公式就此分叉（壳版仍是 0.011）；v=0 的下限 6 px/s 不变，
    /// v=100 的上限由 72 变 81 px/s。初画停 2.5s、松手 1.2s 恢复不动。
    var marqSpeedPxPerSecond: CGFloat {
        let v = UserDefaults.standard.object(forKey: Self.marqSpeedKey) as? Double ?? 24
        let clamped = max(0, min(100, v.isFinite ? v : 24))
        return CGFloat((0.10 + clamped * 0.0125) * 60)
    }

    /// 首页加载代际（Moumusic HomeViewModel.loadGeneration 同款，只管首页
    /// daily 加载的过期丢弃：每次切台 +1，旧加载回来对不上代际直接丢。
    /// 取链的 resolveGeneration 在 PlaybackStore（store 侧、闪退工人落地），
    /// 这里不另建取链计数器——两个计数器各管各的 owner，和 Moumusic 一致：
    /// HomeViewModel.loadGeneration 管首页，PlayerService.resolveGeneration 管取链）。
    private var homeLoadGeneration = 0
    /// 进行中的首页加载句柄（切台时先 cancel 再起新的；Moumusic loadTask 同款）。
    /// daily 一条；initialLoad 也经这里起（r28 之前首加载是直接 await，
    /// dailyTask 是 nil，切台取消不到它，旧单只能走到代际守卫丢掉）。
    private var dailyTask: Task<Void, Never>?
    /// 首页首加载防重入（r33 第 3 件 b）：HomeView .task 在视图重建时重跑，
    /// 首加载只跑一次，重建视图不再重拉每日推荐。
    private var didInitialLoad = false

    // MARK: - 启动

    func initialLoad() async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        loadPersistedSelection()
        // r35：模型重建不丢缓存——从进程内单例恢复该平台的栏缓存
        // （没拉过的平台是空字典）；daily 走 loadDaily 自己的缓存检查，不另写。
        railResults = HomeDataCache.shared.rails(platform: selectedPlatform)
        loadLastTrack()
        // r28：首加载也进 dailyTask——之前是直接 await，dailyTask 是 nil，
        // 首加载中点平台时 selectPlatform 第 2 步取消不到它，旧单与新单
        // 并发取数，旧单回来只能走代际守卫丢掉（见 loadDaily）。
        // Task 存下来再 await value：取消只影响本单的守卫判断，取数
        // 本身不停（链路里没有取消检查点），新加载照常接管。
        let task = Task { await loadDaily() }
        dailyTask = task
        await task.value
        // r35-10：排行榜目录与每日推荐同批起（不 await——榜单块在后台拉，
        // 每日推荐先出；切台时 rankTask 同 dailyTask 一起取消，见 selectPlatform）。
        rankTask = Task { await loadRankBoards() }
        // r35-9（P1-1）：首页挂载就预取网易每日推荐（套壳首页挂载就主动拉
        // 网易，不管当前在哪个平台）：当前平台不是网易时，后台再拉一份
        // 网易写进缓存（只写缓存，不碰任何 UI 状态），切到网易零请求；
        // 已有当日缓存或否定缓存时不拉。预取任务不进 dailyTask（不拦
        // 切台取消，不碰代际），取数走 dailyRecommend 自己的 120 秒壳。
        if selectedPlatform != "netease" {
            Task {
                guard HomeDataCache.shared.dailyIfFresh(platform: "netease") == nil,
                      HomeDataCache.shared.dailyNegativeIfFresh(platform: "netease") == nil else { return }
                let result = await NativeBridge.dailyRecommend(platform: "netease")
                HomeDataCache.shared.storeDaily(platform: "netease", tracks: result.tracks, emptyReason: result.emptyReason)
            }
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
        selectedSource = Self.initialSource()
    }

    /// 读持久化来源的唯一入口（声明初值 + loadPersistedSelection 共用）：
    /// 键里有合法 rawValue 就用它，没有（新装 / 数据被清 / 旧值非法）才回落 .daily。
    private static func initialSource() -> HomeRailPage {
        if let raw = UserDefaults.standard.object(forKey: Self.sourceKey) as? Int,
           let page = HomeRailPage(rawValue: raw) {
            return page
        }
        return .daily
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
    /// 4. 恢复新平台的首页模型（Moumusic resetContent 同款位置，语义 r35
    ///    已改：不再清掉重拉——旧平台的内容当场换成新平台的缓存，
    ///    每日推荐是当日缓存、各栏是整份恢复；没拉过的才留空等新加载）。
    /// 5. 起新加载（只在缓存没命中时；命中时 resetHomeContent 已把数据
    ///    恢复进 daily，isLoadingDaily 是 false，不起任务、不闪 spinner；
    ///    带代际守卫；旧任务回来对不上代际直接丢）。
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
        rankTask?.cancel()
        rankTask = nil
        selectedPlatform = id
        UserDefaults.standard.set(id, forKey: Self.platformKey)
        resetHomeContent()
        // r35：缓存命中时 resetHomeContent 已把 daily 恢复好
        // （非空），不起 loadDaily 任务；没命中（daily 空且无空原因）
        // 才起新加载。
        if daily.isEmpty && dailyEmptyReason == nil {
            dailyTask = Task { await loadDaily(generation: generation) }
        }
        // r35-10：排行榜目录同批起（缓存命中时 resetHomeContent 已恢复，
        // 不起新加载；没命中才起）。
        if rankBoards.isEmpty && rankEmptyReason == nil {
            rankTask = Task { await loadRankBoards(generation: generation) }
        }
    }

    /// 切台时恢复新平台的首页模型（Moumusic resetContent 同款位置）：
    /// r35 起不再清缓存——每日推荐从当日缓存恢复（命中直接显示，
    /// 不起加载、不闪 spinner），各栏整份从缓存恢复（没拉过的平台
    /// 就是空字典）；都没命中时 daily 留空、isLoadingDaily 置 true，
    /// 等 selectPlatform 起的新 loadDaily 回来再落 false / 空原因。
    /// r30：切台回到每日推荐（第 1 个来源）。
    /// r33：切台回 .daily 时也写来源持久化键（与 selectSource 同款写点）。
    private func resetHomeContent() {
        if let cached = HomeDataCache.shared.dailyIfFresh(platform: selectedPlatform) {
            daily = cached.tracks
            dailyEmptyReason = cached.emptyReason
            isLoadingDaily = false
        } else if let neg = HomeDataCache.shared.dailyNegativeIfFresh(platform: selectedPlatform) {
            // r35-9：否定缓存命中（5 分钟内空过）——直接显示空态文案，
            // 不起新请求、不亮 spinner。
            daily = []
            dailyEmptyReason = neg.emptyReason ?? emptyReason(for: selectedPlatform)
            isLoadingDaily = false
        } else {
            daily = []
            dailyEmptyReason = nil
            isLoadingDaily = true
        }
        // r35-10：排行榜目录同款恢复（当日非空直接画；5 分钟内空过
        // 直接显示空态文案，不起新请求、不亮 spinner；没命中等
        // selectPlatform 起的新 loadRankBoards 回来再落）。
        // 没榜的平台（波点/汽水/Apple Music）不发请求、不走缓存，
        // 文案由 loadRankBoards 立刻填（见函数头的早期返回）。
        if let cached = HomeDataCache.shared.rankIfFresh(platform: selectedPlatform) {
            rankBoards = cached.boards
            rankEmptyReason = cached.emptyReason
            isLoadingRank = false
        } else if let neg = HomeDataCache.shared.rankNegativeIfFresh(platform: selectedPlatform) {
            rankBoards = []
            rankEmptyReason = neg.emptyReason
            isLoadingRank = false
        } else {
            rankBoards = []
            rankEmptyReason = nil
            isLoadingRank = false
        }
        selectedSource = .daily
        UserDefaults.standard.set(HomeRailPage.daily.rawValue, forKey: Self.sourceKey)
        closeOpened()
        railResults = HomeDataCache.shared.rails(platform: selectedPlatform)
        railLoadingPages = []
    }

    // MARK: - 每日推荐

    /// 每日推荐。generation：调用方传入切台时定的代际（selectPlatform），
    /// 不传则取调用瞬间的 homeLoadGeneration（initialLoad）。
    /// 代际守卫：Moumusic loadOnce 里每个 await 后都查 generation；
    /// r28：对不上（被新加载取代）才直接退、不碰状态，对得上时
    /// 加载态归本加载负责落下（见下面两步守卫的注释）。
    /// r31-daily（用户 2026-11-21 05:58 “每日推荐一直拉取不到数据，
    /// 面板一直在转圈圈”，不是空态）：根因不是登录——登录态每条请求
    /// 都带上了（网易 Cookie 头、QQ 凭证 Cookie，见 NativeBridge
    /// dailyRecommend 注释与驱动 §6），未登录也有匿名兜底
    /// （personalized / 雷达），登录 alone 造不出无限转圈；根因是
    /// 加载活性的两个单点：(1) r28 的 25s 壳把取数腿本身放进任务组，
    /// 超时后群组退出要等腿完成，腿里不响应取消的挂起能让群组一直等，
    /// loadDaily 永远到不了落 spinner 的那行（壳已改成弃子竞速，见
    /// NativeBridge.dailyRecommend）；(2) 本函数代际守卫那步 return
    /// 不碰任何状态，只在“新加载已接管”时才成立，却没有任何代码核实
    /// 接管者真的在飞、真的会落下来。所以本函数改成 defer 结算：
    /// 五条返回路径（成功 / 空 / 超时 / 取消 / 代际守卫）都经过同一
    /// 个落点；当前代际的加载一定落下，旧加载只在代际没变时才落下，
    /// 代际已变（有更新的加载已接管）时不碰状态、不抢新加载的状态。
    /// r33：defer 条件从「代际相等或 dailyTask 已空」改成
    /// 「generation >= homeLoadGeneration」——无接管者时旧加载也落下，
    /// 不再有不落的出口。
    func loadDaily(generation: Int? = nil, force: Bool = false) async {
        let platform = selectedPlatform
        let generation = generation ?? homeLoadGeneration
        // r35：先查缓存（在 isLoadingDaily = true 之前，命中不闪 spinner）；
        // 代际/平台守卫照旧：对不上就不写。
        // r48-7：第 7 件——force（下拉刷新）时跳过两道缓存直查新数；
        // 不 force 时走原有缓存（r35「只拉一次」不动）。
        if !force, let cached = HomeDataCache.shared.dailyIfFresh(platform: platform) {
            guard generation == homeLoadGeneration, platform == selectedPlatform else { return }
            daily = cached.tracks
            dailyEmptyReason = cached.emptyReason
            isLoadingDaily = false
            dailySpinnerVisible = false
            return
        }
        // r35-9：否定缓存命中（5 分钟内空过）——直接显示空态文案，
        // 不起新请求、不亮 spinner。r48-7：force 时跳过（同上）。
        if !force, let neg = HomeDataCache.shared.dailyNegativeIfFresh(platform: platform) {
            guard generation == homeLoadGeneration, platform == selectedPlatform else { return }
            daily = []
            dailyEmptyReason = neg.emptyReason ?? emptyReason(for: platform)
            isLoadingDaily = false
            dailySpinnerVisible = false
            return
        }
        isLoadingDaily = true
        dailySpinnerVisible = false
        dailyEmptyReason = nil
        // r35-9（P0-2）：250ms 后仍未回来才亮 spinner（套壳 250ms 保留旧内容
        // 同款）——250ms 内回来全程不闪。epoch 防旧任务串味：新加载起手
        // +1，旧的延迟任务回来对不上 epoch 就不亮。
        dailySpinnerEpoch += 1
        let spinnerEpoch = dailySpinnerEpoch
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if spinnerEpoch == dailySpinnerEpoch, isLoadingDaily {
                dailySpinnerVisible = true
            }
        }
        // r37-6：看门狗（见 dailyWatchdogEpoch 注释）：130 秒后同代际
        // 仍在加载，就当桥接腿挂死了，强制落到带文案的空态。看门狗只清
        // 加载态、不写缓存——一次挂死不是空数据，不进 r35-1 的否定缓存，
        // 下次访问照常重拉；新加载起手 epoch +1，旧看门狗回来对不上
        // 就空转，不误伤新单。
        dailyWatchdogEpoch += 1
        let watchdogEpoch = dailyWatchdogEpoch
        dailyLoadStartedAt = Date()
        Task {
            try? await Task.sleep(nanoseconds: 130_000_000_000)
            guard watchdogEpoch == dailyWatchdogEpoch,
                  generation == homeLoadGeneration,
                  isLoadingDaily, daily.isEmpty else { return }
            isLoadingDaily = false
            dailySpinnerVisible = false
            dailyEmptyReason = "每日推荐拉取超时（130 秒无响应），请检查网络后重试。"
        }
        defer {
            // r33：任何返回路径都无条件落下，除非更新的加载已接管
            // （代际比当前新，generation < homeLoadGeneration）。
            // 铁律：最终状态一定落到有数据或带文案的空态，绝不停在加载中。
            if generation >= homeLoadGeneration {
                isLoadingDaily = false
                dailySpinnerVisible = false
            }
        }
        let result = await NativeBridge.dailyRecommend(platform: platform)
        // r28 根因（a）：旧写法三条件一个 guard、早退不碰任何状态——
        // 代际变了（切台）或任务被取消时直接 return，isLoadingDaily
        // 永远留在 true，环永远停在「正在拉取每日推荐…」，歌单永不显示。
        // 分两步：代际变了说明新加载已接管 isLoadingDaily（它起手就置
        // true、回来再落 false），旧加载才不碰状态；代际没变时加载态
        // 归本加载负责——无论取消还是平台已变，先落 false 再退，
        // 绝不把 spinner 留给 UI。平台只在 selectPlatform 里变，
        // 那里必先代际 +1，所以「同代际但平台变了」到不了这里，
        // 第二个 guard 只是兜底。r31-daily：上面两步 guard 仍在，但
        // 落 spinner 的责任已交给 defer——即使走到这里 return，
        // defer 也按“当前代际或无接管者”规则结算，不再有不落的出口。
        guard generation == homeLoadGeneration else { return }
        guard platform == selectedPlatform, !Task.isCancelled else { return }
        // r48-7：第 7 件——force 刷新失败（空结果）且旧内容还在时，旧内容
        // 保留：daily 与 dailyEmptyReason 都不动（旧 daily 非空时原因必
        // 是 nil——起手已清、填 daily 的那单没设原因），也不写否定缓存
        // （storeDaily 的空结果会写 5 分钟否定缓存，下次无缓存加载会把
        // 内存里的旧内容清掉）。只清加载态（defer）。旧内容为空时走原有
        // 逻辑（空态 + 原因）。
        if force, result.tracks.isEmpty, !daily.isEmpty {
            return
        }
        daily = result.tracks
        if result.tracks.isEmpty {
            dailyEmptyReason = result.emptyReason ?? emptyReason(for: platform)
        }
        // r35-9：结果无论空不空都写缓存（storeDaily 里分流：非空写当日缓存，
        // 空写 5 分钟否定缓存；旧「空结果不缓存」作废——空平台每次回首页
        // 都重拉、每次最多转 25 秒，就是这句的代价）。
        HomeDataCache.shared.storeDaily(platform: platform, tracks: result.tracks, emptyReason: result.emptyReason)
    }

    /// 排行榜目录（r35-10）。缓存优先（当日非空直接画；5 分钟内空过
    /// 直接显示空态文案，不起新请求、不亮 spinner）；没命中才起新请求
    /// （各走独立 60 秒预算，见 NativeBridge.rankBoards）。代际守卫与
    /// loadDaily 同款（切台 +1，旧加载回来对不上直接丢）。
    func loadRankBoards(generation: Int? = nil, force: Bool = false) async {
        let platform = selectedPlatform
        let generation = generation ?? homeLoadGeneration
        // 没榜的平台（波点/汽水/Apple Music）：不发请求、不走缓存，
        // 文案直接给（NativeBridge.rankBoards 里是固定事实）。
        if platform == "bodian" || platform == "qishui" || platform == "applemusic" {
            guard generation == homeLoadGeneration, platform == selectedPlatform else { return }
            rankBoards = []
            rankEmptyReason = (await NativeBridge.rankBoards(platform: platform)).emptyReason
            isLoadingRank = false
            rankSpinnerVisible = false
            return
        }
        // r48-7：第 7 件——force（下拉刷新）时跳过两道缓存直查新数；
        // 不 force 时走原有缓存（loadDaily 同款）。
        if !force, let cached = HomeDataCache.shared.rankIfFresh(platform: platform) {
            guard generation == homeLoadGeneration, platform == selectedPlatform else { return }
            rankBoards = cached.boards
            rankEmptyReason = cached.emptyReason
            isLoadingRank = false
            rankSpinnerVisible = false
            return
        }
        // r48-7：第 7 件——force 时跳过否定缓存（同上）。
        if !force, let neg = HomeDataCache.shared.rankNegativeIfFresh(platform: platform) {
            guard generation == homeLoadGeneration, platform == selectedPlatform else { return }
            rankBoards = []
            rankEmptyReason = neg.emptyReason
            isLoadingRank = false
            rankSpinnerVisible = false
            return
        }
        isLoadingRank = true
        rankSpinnerVisible = false
        rankEmptyReason = nil
        // 250ms 后仍未回来才亮 spinner（loadDaily 同款 epoch 防串味）。
        rankSpinnerEpoch += 1
        let spinnerEpoch = rankSpinnerEpoch
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if spinnerEpoch == rankSpinnerEpoch, isLoadingRank {
                rankSpinnerVisible = true
            }
        }
        defer {
            if generation >= homeLoadGeneration {
                isLoadingRank = false
                rankSpinnerVisible = false
            }
        }
        let result = await NativeBridge.rankBoards(platform: platform)
        guard generation == homeLoadGeneration else { return }
        guard platform == selectedPlatform, !Task.isCancelled else { return }
        // r48-7：第 7 件——force 刷新失败（空榜单）且旧内容还在时，旧内容
        // 保留（loadDaily 同款：不盖、不写否定缓存；只清加载态，defer）。
        // 旧内容为空时走原有逻辑（空态 + 原因）。
        if force, result.boards.isEmpty, !rankBoards.isEmpty {
            return
        }
        rankBoards = result.boards
        rankEmptyReason = result.emptyReason
        HomeDataCache.shared.storeRank(platform: platform, boards: result.boards, emptyReason: result.emptyReason)
    }

    private func emptyReason(for platform: String) -> String {
        switch platform {
        case "netease":
            return "网易云每日推荐和推荐新歌都没返回内容（登录后是真每日推荐，未登录退到推荐新歌），请检查网络后重试。"
        case "qq":
            // r31-daily：QQ 也有登录分支的诚实文案（旧写法只有网易分支，
            // 其余全走一句通用话，未登录的用户看不出要登录）。
            return "QQ 音乐每日推荐和雷达推荐都没返回内容（登录后是真每日推荐，未登录只有雷达推荐），请检查网络后重试。"
        default:
            return "该平台今日没有返回推荐内容。"
        }
    }

    // MARK: - 面板来源（r30，见文件头）

    /// 当前来源（默认 `.daily` = 每日推荐；点平台条标题弹菜单切）。
    /// r33 第 4 件：声明时就读持久化值（initialSource()），loadPersistedSelection
    /// 再读一次同一份 helper，不另起事实来源（平台 initialPlatform() 同款）。
    @Published var selectedSource: HomeRailPage = HomeViewModel.initialSource()

    /// 当前来源的标题（喜欢栏按平台取真名，唯一事实来源
    /// `RailKind.likedTitle(for:)`）。
    var sourceTitle: String { selectedSource.title(platform: selectedPlatform) }

    /// r37-6：保证每日推荐有一单在飞或已落下（selectSource 两路共用）。
    /// - 空 + 无原因 + 没在加载 → 起一单 loadDaily。
    /// - 空 + 无原因 + 在加载，但起始时间超过 130 秒（看门狗都没把它
    ///   落下，说明结算路径已丢）→ 先强制结算旧单（落加载态 + 超时文案），
    ///   再起一单新的 loadDaily；不无限重起（新单自己带看门狗）。
    /// - 有数据 / 有空原因 → 什么都不做。
    private func ensureDailyLoaded() {
        guard daily.isEmpty, dailyEmptyReason == nil else { return }
        if isLoadingDaily {
            if let startedAt = dailyLoadStartedAt,
               Date().timeIntervalSince(startedAt) > 130 {
                isLoadingDaily = false
                dailySpinnerVisible = false
                dailyEmptyReason = "每日推荐拉取超时（130 秒无响应），请检查网络后重试。"
                Task { await loadDaily() }
            }
            return
        }
        Task { await loadDaily() }
    }

    /// 切来源（菜单点选唯一入口；点当前来源且数据已在就直接 return，
    /// 什么都不做，见函数体 r35 分支；喜欢栏星标旗置起时重拉，
    /// 见 `loadRailPage`）。
    /// 切来源时关掉面板内打开的歌单/专辑（r31），回到该来源列表。
    /// r33：切来源写来源持久化键（lizi.native.hall.source）。
    /// r36：排行榜（.rank）不走 `loadRailPage`——榜单目录与每日推荐
    /// 同批起、缓存已恢复（见 initialLoad / selectPlatform /
    /// resetHomeContent），切过去直接画；没拉到且不在加载中才补一次
    /// `loadRankBoards()`。点当前来源且榜单已在时直接 return。
    /// r38-1：正在播放（.nowPlaying）同款——不取数，只切来源+写持久化键；
    /// 内容是直播队列，HomeView 直接读 `playback.queue`，点当前来源直接 return。
    func selectSource(_ page: HomeRailPage) {
        closeOpened()
        // r38-1：正在播放单独走（不进下面 loadRailPage 那条路，不取数）。
        if page == .nowPlaying {
            if page == selectedSource { return }
            selectedSource = page
            UserDefaults.standard.set(page.rawValue, forKey: Self.sourceKey)
            return
        }
        // r36：排行榜单独走（不进下面 loadRailPage 那条路）。
        if page == .rank {
            if page == selectedSource {
                if !rankBoards.isEmpty || rankEmptyReason != nil { return }
                if !isLoadingRank {
                    Task { await loadRankBoards() }
                }
                return
            }
            selectedSource = page
            UserDefaults.standard.set(page.rawValue, forKey: Self.sourceKey)
            if rankBoards.isEmpty && rankEmptyReason == nil && !isLoadingRank {
                Task { await loadRankBoards() }
            }
            return
        }
        // r35：点当前来源且数据已在就直接 return（持久化键本来就已是
        // 该值，不用重写）；.daily 还没拉到（空且没原因）且不在加载中
        // 时补一次 loadDaily；其余栏没缓存时走下面现有 loadRailPage。
        if page == selectedSource {
            if page == .daily {
                if !daily.isEmpty || dailyEmptyReason != nil { return }
                // r37-6：同源点每日推荐时也走 ensureDailyLoaded——旧写法
                // 只在 !isLoadingDaily 时补拉；若 isLoadingDaily 被一次
                // 孤儿加载永久置起（r36 复现），这里直接 return、
                // 面板永远转圈。卡死超 130 秒就强制结算旧单再重拉。
                ensureDailyLoaded()
                return
            }
            if railResults[page] != nil,
               page != .liked || !UserDefaults.standard.bool(forKey: PlaybackStore.likedNeedsRefreshKey) {
                return
            }
        }
        selectedSource = page
        UserDefaults.standard.set(page.rawValue, forKey: Self.sourceKey)
        // r37-6：跨来源切回每日推荐也要保证有单——旧写法只调
        // loadRailPage(page)，而 loadRailPage 开头就 guard 掉 .daily，
        // 切过来后若每日是空且无原因、又没在加载，面板永远是旧的加载态。
        if page == .daily { ensureDailyLoaded() }
        loadRailPage(page)
    }

    /// 各栏取到的结果（首次访问该栏时拉取、之后缓存；r35 起缓存在
    /// 进程内单例 `HomeDataCache.shared` 里分平台存，切台/模型重建
    /// 不再清掉，切回来直接用）。
    @Published private(set) var railResults: [HomeRailPage: RailResult] = [:]

    /// 正在拉取的栏（防重复请求；RailResult 自带 error / emptyReason，
    /// 加载态只记在飞、不另起结果结构）。
    @Published private(set) var railLoadingPages: Set<HomeRailPage> = []

    func isRailPageLoading(_ page: HomeRailPage) -> Bool { railLoadingPages.contains(page) }

    /// 该栏的 spinner 是否可见（r35-9，P0-2：套壳 250ms 同款——栏在拉取中
    /// 且没旧内容时，250ms 内只留空白，之后才亮 spinner；有旧内容时
    /// 视图直接留旧内容，不看这面旗子）。
    @Published private(set) var railSpinnerVisiblePages: Set<HomeRailPage> = []

    func isRailSpinnerVisible(_ page: HomeRailPage) -> Bool { railSpinnerVisiblePages.contains(page) }

    /// 该栏在面板里显示的条目（groupHeader 不可点，只做分组说明）。
    /// - 每日推荐：不在这里取（走修好的 loadDaily 链路）。
    /// - 我的歌单：网易按 subscribed 分两组，只取「我创建的歌单」那组
    ///   （groupHeader 切分；其余平台 railMyPlaylists 已按 subscribed /
    ///   isOwned 标记只留自建，直接取全量）。
    func railEntries(for page: HomeRailPage) -> [RailEntry] {
        guard let result = railResults[page] else { return [] }
        guard page == .created else { return result.entries }
        guard selectedPlatform == "netease" else { return result.entries }
        let entries = result.entries
        let mineIdx = entries.firstIndex(where: isMineGroupHeader)
        let subIdx = entries.firstIndex(where: isSubGroupHeader)
        if let mineIdx {
            return Array(entries[mineIdx..<(subIdx ?? entries.endIndex)])
        }
        return []
    }

    /// 该栏的空态文案（面板内显示）：结果本身的 emptyReason 优先；
    /// 网易自建分组切完后为空时，给该组的诚实原因（不是取数失败）。
    /// 结果还没回来时返回 nil（调用方先看加载态）。
    func railEmptyReason(for page: HomeRailPage) -> String? {
        guard let result = railResults[page] else { return nil }
        if let reason = result.emptyReason { return reason }
        if result.entries.isEmpty { return "这一栏没有内容。" }
        if page == .created, selectedPlatform == "netease", railEntries(for: page).isEmpty {
            return "还没有创建歌单。"
        }
        return nil
    }

    /// 首次访问该栏时拉取，之后用缓存（含 .liked：r35 起喜欢栏也缓存，
    /// 只有星标旗 `PlaybackStore.likedNeedsRefreshKey` 置起时才绕开
    /// 缓存重拉一次——本地星标一点就变，r33 的旗子机制保留，不用每次
    /// 切回都重拉）。
    /// 每栏加载/失败/空态走 RailDetailView 同款三态（RailResult.error /
    /// emptyReason，文案由 RailsBridge 原样给）。
    /// r36：排行榜（.rank）不走这里（见 selectSource：榜单与每日推荐
    /// 同批起、切过去直接画），guard 与 switch 里都拦住。
    /// r38-1：正在播放（.nowPlaying）也不走这里（内容是直播队列，不取数），
    /// guard 与 switch 里同款拦住。
    /// r35-9：整栏包一层 60s 硬超时（`NativeBridge.legTimeout`，
    /// 与每日推荐每条腿同一把尺子，套壳每腿 60 秒同款；旧 25 秒作废）：
    /// 之前这里没有超时壳，腿一挂起（慢网 / 上游不回），`railLoadingPages`
    /// 永远不清，面板就一直转圈——每日推荐在 r31/r33 修的是同一毛病，
    /// 栏这里是漏网的。
    /// 超时按失败处理（`error` 带文案，面板显示红字原因，不留 spinner）。
    /// r48-7：第 7 件——preserveOldOnError（只下拉刷新传 true）：新结果
    /// 带错、旧结果有内容时，不用错误结果盖掉旧内容（面板的 error 分支
    /// 会整块替换成错误页，旧卡片就没了）；只清加载态。旧结果本身就是
    /// 错/空时照常盖（旧态已是错误态，新错即原有错误态）。其余调用点
    /// （selectSource、喜欢栏星标重拉、重试按钮）默认 false，行为不动。
    func loadRailPage(_ page: HomeRailPage, force: Bool = false, preserveOldOnError: Bool = false) {
        guard page != .daily, page != .rank, page != .nowPlaying else { return } // r38-1：正在播放不取数
        // r35：缓存守卫对所有栏生效（含 .liked）。喜欢栏例外：星标旗
        // 置起（播放页点了星标）时不走缓存、要重拉看新星标；旗子等到
        // 真的开始拉取时才清——在飞的请求挡住时不清旗，下次出现再拉。
        let likedNeedsRefresh = page == .liked &&
            UserDefaults.standard.bool(forKey: PlaybackStore.likedNeedsRefreshKey)
        if !force, !likedNeedsRefresh, railResults[page] != nil { return }
        if railLoadingPages.contains(page) { return }
        if likedNeedsRefresh {
            UserDefaults.standard.set(false, forKey: PlaybackStore.likedNeedsRefreshKey)
        }
        railLoadingPages.insert(page)
        Task {
            let platform = selectedPlatform
            // r35-9（P0-2）：250ms 后仍在拉取才亮 spinner（没旧内容时；
            // 有旧内容时视图留旧内容，不看这面旗子）。250ms 内回来不闪。
            Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if railLoadingPages.contains(page) {
                    railSpinnerVisiblePages.insert(page)
                }
            }
            let fetched: RailResult
            do {
                fetched = try await NativeBridge.withTimeout(seconds: NativeBridge.legTimeout) {
                    switch page {
                    case .daily, .rank, .nowPlaying:
                        // 上面 guard 已拦 daily、rank 与 nowPlaying，这里到不了；穷举 switch 用。
                        return RailResult(kind: .featured, platform: platform)
                    case .featured:
                        return await NativeBridge.railFeatured(platform: platform)
                    case .liked:
                        return await NativeBridge.railLiked(platform: platform)
                    case .created:
                        return await NativeBridge.railMyPlaylists(platform: platform)
                    case .radio:
                        return await NativeBridge.railRadio(platform: platform)
                    }
                }
            } catch {
                fetched = RailResult(kind: page.railKind ?? .featured, platform: platform,
                                     error: "该栏拉取超时（60 秒无响应），请检查网络后重试。")
            }
            // 切台后旧结果回来直接丢（selectPlatform 已换平台；
            // fetched.platform 是取数时的平台，对不上当前平台就是旧单）。
            guard selectedPlatform == fetched.platform else {
                railLoadingPages.remove(page)
                railSpinnerVisiblePages.remove(page)
                return
            }
            // r48-7：第 7 件——下拉刷新失败时旧内容保留（见函数头
            // preserveOldOnError）；不写缓存（失败本来就不缓存）。
            if preserveOldOnError, fetched.error != nil,
               let old = railResults[page], !old.entries.isEmpty {
                // 旧内容保留：不写 railResults、不写缓存。
            } else {
                railResults[page] = fetched
                // r35：成功（error == nil）才写缓存；失败的不缓存，
                // 下次访问重拉（重试按钮照常 force）。
                if fetched.error == nil {
                    HomeDataCache.shared.storeRail(platform: platform, page: page, result: fetched)
                }
            }
            railLoadingPages.remove(page)
            railSpinnerVisiblePages.remove(page)
        }
    }

    /// r48-7：第 7 件——首页下拉刷新：重新拉取当前模式的内容。
    /// 走现有取数链路（loadDaily / loadRankBoards / loadRailPage），
    /// 不另写一套取数；force: true 绕开缓存（不绕就命中缓存直接返回，
    /// 等于没刷）。不丢在播的歌（只写本模式的 daily/rankBoards/
    /// railResults，不碰 PlaybackStore 队列与当前曲目）、不换模式
    /// （不调 selectSource、不写 selectedSource）、不重置带子位置
    /// （不碰 flatOffsetX/selectedFlatIndex；内容真换了时带子按 r48-3
    /// 的跟随落在播的那首上、不是从头，不换内容时带子一动不动）。
    /// 正在播放是直播队列、不取数，直接返回。失败时旧内容保留（见
    /// loadDaily/loadRankBoards/loadRailPage 的 force 失败分支），
    /// 只清加载态。竖屏横屏共用同一个外层 ScrollView，.refreshable
    /// 挂在它上面，两向都能用。
    func refreshCurrentSource() async {
        switch selectedSource {
        case .daily:
            await loadDaily(force: true)
        case .rank:
            await loadRankBoards(force: true)
        case .nowPlaying:
            return
        case .featured, .liked, .created, .radio:
            loadRailPage(selectedSource, force: true, preserveOldOnError: true)
            // loadRailPage 是 fire-and-forget（内部起 Task）；下拉指示
            // 要等到取数落下再消失，等 railLoadingPages 清掉这栏（60 秒
            // 腿超时同款上限 + 5 秒余量；栏已在拉取中时等在飞的那单；
            // insert 在 Task 之前同步发生，无竞态）。
            let deadline = Date().addingTimeInterval(NativeBridge.legTimeout + 5)
            while railLoadingPages.contains(selectedSource), Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    // MARK: - 面板内打开歌单 / 专辑（r31）

    /// 面板内打开的歌单（点「我的歌单」/「我喜欢」里的歌单卡后，面板原地
    /// 换成该歌单的全部歌曲卡片，不跳详情页；`nil` = 没打开歌单）。
    @Published var openedPlaylist: Playlist?
    /// 面板内打开的专辑（同上，点专辑卡后原地换成专辑全部歌曲卡片）。
    @Published var openedAlbum: Album?
    /// 打开的集合的全部曲目（全量取数，见 `openPlaylist` / `openAlbum`）。
    @Published var openedTracks: [Track] = []
    /// 打开的集合的标题（歌单名 / 专辑名，面板内打开态的栏头用）。
    @Published var openedTitle = ""
    /// 打开的集合正在拉取曲目。
    @Published var openedLoading = false
    /// 打开的集合拉取失败的原因（nil = 没失败）。
    @Published var openedError: String?
    /// 打开的集合拉取成功但没有曲目时的诚实原因（nil = 有曲目或未取完）。
    @Published var openedEmptyReason: String?

    /// 是否正打开着一个歌单或专辑（面板显示集合曲目而不是来源列表）。
    var isOpenedCollection: Bool { openedPlaylist != nil || openedAlbum != nil }

    /// 点歌单卡：在面板内打开它，显示全部歌曲卡片（曲目走
    /// `railPlaylistTracks` 全量翻页取数，50 首以上也不截断）。
    func openPlaylist(_ playlist: Playlist) {
        openedPlaylist = playlist
        openedAlbum = nil
        openedTitle = playlist.title
        openedTracks = []
        openedError = nil
        openedEmptyReason = nil
        openedLoading = true
        Task {
            let result = await NativeBridge.railPlaylistTracks(platform: playlist.source, playlist: playlist)
            guard openedPlaylist?.id == playlist.id, openedPlaylist?.source == playlist.source else { return }
            openedLoading = false
            if let error = result.error {
                openedError = error
            } else if let reason = result.emptyReason {
                openedEmptyReason = reason
            } else {
                openedTracks = result.tracks
            }
        }
    }

    /// 点专辑卡：在面板内打开它，显示全部歌曲卡片（曲目走 `albumDetail`；
    /// 网易/酷我/QQ/酷狗/波点有专辑取曲接口，汽水/Apple Music 没有，
    /// 取不到时按诚实空态显示，不编曲目）。
    func openAlbum(_ album: Album) {
        openedAlbum = album
        openedPlaylist = nil
        openedTitle = album.title
        openedTracks = []
        openedError = nil
        openedEmptyReason = nil
        openedLoading = true
        Task {
            let detail = await NativeBridge.albumDetail(platform: album.source, id: album.id)
            guard openedAlbum?.id == album.id, openedAlbum?.source == album.source else { return }
            openedLoading = false
            if detail.tracks.isEmpty {
                openedEmptyReason = "这张专辑没有曲目"
            } else {
                openedTracks = detail.tracks
            }
        }
    }

    /// 关掉面板内打开的歌单/专辑，回到该来源列表（返回键 / 切来源 / 切台时调）。
    func closeOpened() {
        openedPlaylist = nil
        openedAlbum = nil
        openedTracks = []
        openedTitle = ""
        openedLoading = false
        openedError = nil
        openedEmptyReason = nil
    }

    private func isMineGroupHeader(_ entry: RailEntry) -> Bool {
        if case .groupHeader(let text) = entry { return text == "我创建的歌单" }
        return false
    }

    private func isSubGroupHeader(_ entry: RailEntry) -> Bool {
        if case .groupHeader(let text) = entry { return text == "我收藏的歌单" }
        return false
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

    /// r45-5：给 PlaybackStore 读上次播放（退出重进恢复队列用）——
    /// 键与结构与 notePlayed/loadLastTrack 同一份，不另起键。
    static func savedLastTrack() -> Track? {
        guard let data = UserDefaults.standard.data(forKey: Self.lastTrackKey),
              let saved = try? JSONDecoder().decode(SavedLastTrack.self, from: data) else { return nil }
        return saved.track
    }
}

/// 每日推荐面板的 7 个来源（r28 定稿顺序，用户 2026-11-21 01:21–01:38 确认；
/// r30：上下翻页器撤掉，改点平台条标题弹菜单切来源，一次只显示一个来源；
/// r31：用户 2026-11-21 06:02 决定删掉「用户收藏」（数据并进「我喜欢」），
/// 「用户创建的歌单」改名「我的歌单」；
/// r36：用户 2026-11-21 21:09 定落点——排行榜加进来源菜单，与其余 5 项并列
/// （菜单第 6 行，点它切到排行榜面板）；`case rank` 追加在末尾，已有
/// 0–4 的 rawValue 不动，已持久化的来源键兼容；取数不走 rails，
/// 见 `selectSource` 的 rank 分支与 `loadRankBoards`）。
/// r38-1：用户 2026-11-22 定稿（稿图 lizi-now-playing-menu-mockup.png）——
/// 菜单加「正在播放」（菜单第 2 行，点它切到当前播单面板）；`case nowPlaying`
/// 追加在末尾（rawValue 6），0–5 不动，已持久化的来源键兼容；内容就是直播
/// 队列 `PlaybackStore.queue`，不取数，见 `selectSource` 的 nowPlaying 分支
/// 与 HomeView 的 nowPlayingRingContent。
enum HomeRailPage: Int, CaseIterable {
    case daily = 0
    case featured
    case liked
    case created
    case radio
    case rank
    case nowPlaying

    /// 菜单显示顺序（r38-1：与 rawValue 顺序不同——「正在播放」排第 2，
    /// 在每日推荐之后、精选之前；rawValue 顺序不动，只影响菜单排列）。
    static var menuOrder: [HomeRailPage] = [.daily, .nowPlaying, .featured, .liked, .created, .radio, .rank]

    /// r47-4：菜单按播/停两种顺序排——在播时「正在播放」置顶第一排，
    /// 其余顺序不动；不在播时恢复正常顺序（`menuOrder`：每日推荐第一、
    /// 「正在播放」第 2）。`menuOrder` 本身不动（正常顺序的事实来源，
    /// 见 r45 §K1，仍锁它）；菜单 ForEach 改走这里。菜单里不写「置顶」二字，
    /// 置顶只用第一排的位置表示，当前模式的勾照常显示。
    static func menuOrderFor(isPlaying: Bool) -> [HomeRailPage] {
        isPlaying ? [.nowPlaying, .daily, .featured, .liked, .created, .radio, .rank] : menuOrder
    }

    /// 栏目名（喜欢那栏按平台取真名，唯一事实来源 `RailKind.likedTitle(for:)`）。
    func title(platform: String) -> String {
        switch self {
        case .daily: return "每日推荐"
        case .featured: return "精选"
        case .liked: return RailKind.likedTitle(for: platform)
        case .created: return "我的歌单"
        case .radio: return "电台"
        case .rank: return "排行榜"
        case .nowPlaying: return "正在播放" // r38-1
        }
    }

    /// 点「查看全部」进的详情页 kind（每日推荐、排行榜与正在播放没有详情页，
    /// 返回 nil；排行榜点卡直接进榜单详情，见 HomeView.rankCards）。
    var railKind: RailKind? {
        switch self {
        case .daily: return nil
        case .featured: return .featured
        case .created: return .playlists
        case .liked: return .liked
        case .radio: return .radio
        case .rank: return nil
        case .nowPlaying: return nil // r38-1
        }
    }

    /// 来源在菜单里的序号（1-based；r30：栏头「n/6」已随翻页器撤掉，
    /// r31 起是 5 个来源，r36 加排行榜成 6 个，r38-1 加正在播放成 7 个，
    /// 序号只留作来源顺序的事实来源，不再显示）。
    var position: Int { rawValue + 1 }
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
