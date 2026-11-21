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
/// dailyTask、25s 超时壳一字不动），其余 5 栏首次访问时拉取、之后缓存
/// （喜欢栏除外：本地星标一点就变，壳版 renderRailNode 同款不缓存，
/// 每次切回都重拉）。
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
        loadLastTrack()
        // r28：首加载也进 dailyTask——之前是直接 await，dailyTask 是 nil，
        // 首加载中点平台时 selectPlatform 第 2 步取消不到它，旧单与新单
        // 并发取数，旧单回来只能走代际守卫丢掉（见 loadDaily）。
        // Task 存下来再 await value：取消只影响本单的守卫判断，取数
        // 本身不停（链路里没有取消检查点），新加载照常接管。
        let task = Task { await loadDaily() }
        dailyTask = task
        await task.value
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
    /// r30：切台回到每日推荐（第 1 个来源），各栏缓存是分平台的、清掉重拉。
    /// r33：切台回 .daily 时也写来源持久化键（与 selectSource 同款写点）。
    private func resetHomeContent() {
        daily = []
        dailyEmptyReason = nil
        isLoadingDaily = true
        selectedSource = .daily
        UserDefaults.standard.set(HomeRailPage.daily.rawValue, forKey: Self.sourceKey)
        closeOpened()
        railResults = [:]
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
    func loadDaily(generation: Int? = nil) async {
        let platform = selectedPlatform
        let generation = generation ?? homeLoadGeneration
        isLoadingDaily = true
        dailyEmptyReason = nil
        defer {
            // r33：任何返回路径都无条件落下，除非更新的加载已接管
            // （代际比当前新，generation < homeLoadGeneration）。
            // 铁律：最终状态一定落到有数据或带文案的空态，绝不停在加载中。
            if generation >= homeLoadGeneration {
                isLoadingDaily = false
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
        daily = result.tracks
        if result.tracks.isEmpty {
            dailyEmptyReason = result.emptyReason ?? emptyReason(for: platform)
        }
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

    /// 切来源（菜单点选唯一入口；点当前来源也触发一次该栏拉取，
    /// 喜欢栏不缓存、每次切回都重拉，见 `loadRailPage`）。
    /// 切来源时关掉面板内打开的歌单/专辑（r31），回到该来源列表。
    /// r33：切来源写来源持久化键（lizi.native.hall.source）。
    func selectSource(_ page: HomeRailPage) {
        closeOpened()
        selectedSource = page
        UserDefaults.standard.set(page.rawValue, forKey: Self.sourceKey)
        loadRailPage(page)
    }

    /// 各栏取到的结果（首次访问该栏时拉取、之后缓存；切台时随
    /// resetHomeContent 清掉，各栏缓存是分平台的）。
    @Published private(set) var railResults: [HomeRailPage: RailResult] = [:]

    /// 正在拉取的栏（防重复请求；RailResult 自带 error / emptyReason，
    /// 加载态只记在飞、不另起结果结构）。
    @Published private(set) var railLoadingPages: Set<HomeRailPage> = []

    func isRailPageLoading(_ page: HomeRailPage) -> Bool { railLoadingPages.contains(page) }

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

    /// 首次访问该栏时拉取，之后用缓存（喜欢栏除外：本地星标一点就变，
    /// 壳版 renderRailNode 同款不缓存——每次切回喜欢栏都重拉）。
    /// 每栏加载/失败/空态走 RailDetailView 同款三态（RailResult.error /
    /// emptyReason，文案由 RailsBridge 原样给）。
    func loadRailPage(_ page: HomeRailPage, force: Bool = false) {
        guard page != .daily else { return }
        if page != .liked, !force, railResults[page] != nil { return }
        if railLoadingPages.contains(page) { return }
        railLoadingPages.insert(page)
        Task {
            let fetched: RailResult
            switch page {
            case .daily:
                railLoadingPages.remove(page)
                return
            case .featured:
                fetched = await NativeBridge.railFeatured(platform: selectedPlatform)
            case .liked:
                fetched = await NativeBridge.railLiked(platform: selectedPlatform)
            case .created:
                fetched = await NativeBridge.railMyPlaylists(platform: selectedPlatform)
            case .radio:
                fetched = await NativeBridge.railRadio(platform: selectedPlatform)
            }
            // 切台后旧结果回来直接丢（selectPlatform 已清缓存；
            // fetched.platform 是取数时的平台，对不上当前平台就是旧单）。
            guard selectedPlatform == fetched.platform else {
                railLoadingPages.remove(page)
                return
            }
            railResults[page] = fetched
            railLoadingPages.remove(page)
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
}

/// 每日推荐面板的 5 个来源（r28 定稿顺序，用户 2026-11-21 01:21–01:38 确认；
/// r30：上下翻页器撤掉，改点平台条标题弹菜单切来源，一次只显示一个来源；
/// r31：用户 2026-11-21 06:02 决定删掉「用户收藏」（数据并进「我喜欢」），
/// 「用户创建的歌单」改名「我的歌单」）。
enum HomeRailPage: Int, CaseIterable {
    case daily = 0
    case featured
    case liked
    case created
    case radio

    /// 栏目名（喜欢那栏按平台取真名，唯一事实来源 `RailKind.likedTitle(for:)`）。
    func title(platform: String) -> String {
        switch self {
        case .daily: return "每日推荐"
        case .featured: return "精选"
        case .liked: return RailKind.likedTitle(for: platform)
        case .created: return "我的歌单"
        case .radio: return "电台"
        }
    }

    /// 点「查看全部」进的详情页 kind（每日推荐没有详情页，返回 nil）。
    var railKind: RailKind? {
        switch self {
        case .daily: return nil
        case .featured: return .featured
        case .created: return .playlists
        case .liked: return .liked
        case .radio: return .radio
        }
    }

    /// 来源在菜单里的序号（1-based；r30：栏头「n/6」已随翻页器撤掉，
    /// r31 起是 5 个来源，序号只留作来源顺序的事实来源，不再显示）。
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
