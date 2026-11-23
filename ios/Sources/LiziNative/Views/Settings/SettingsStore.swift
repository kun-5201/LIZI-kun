import Foundation
import QuartzCore

/// 设置统一存储（P3-C，NATIVE-REWRITE-PLAN.md §5 缺口 7）。
///
/// 键名 = 壳版 localStorage 键名逐项迁移（壳版 `public/app.js` 各设置项注释
/// 里写的键），除非原生已有消费者在用另一把键——那时跟消费者走，并在下面
/// 逐项注明，避免「设置写 A、页面读 B、开关白拨」：
///
/// | 设置项 | 键 | 默认 | 备注 |
/// |---|---|---|---|
/// | 动画插图 | `lizi.animatedArtwork` | 开 | 与 NowPlayingCoordinator 同键，开关真生效 |
/// | LRCLIB 兜底 | 旧兜底键 | — | r55 已删：旧兜底库全删，官方无词时走跨平台自动匹配 |
/// （r31-settings-organization 已删：平台头像 `lizi.hall.platAvatar` /
/// 平台颜色 `lizi.hall.platColor` / 大厅内容轨 `lizi.hall.rail` 三开关
/// 只写键、原生大厅从不读，拨了无效；壳版 public/app.js 仍自带这三项，
/// 原生包不走那条路。大厅消费对应键后再加回。）
/// | 本地音乐首页显示 | `lizi.local.show` | 开 | 壳版键；HomeView 已消费（r25） |
/// （r35-6 已删：播放页版式只留默认，`lizi.now.layout` 键已清、PlayerView 的 02/04/06 三套版式全删；旧值残留再也不会被读到。）
/// | 形态歌词 | `lizi.stage.lyricMode` | `orig`（原文） | 壳版键（安卓快照 `app.js:1901-1905`，`#set-stage-lyric`）；三档非开关：`orig` 原文 / `both` 双文 / `trans` 译文；StageBridge 已消费（r25） |
/// | 平台管理（显示哪些平台） | `lizi.platforms.v1` | 全选（无键） | 壳版语义：没存 = 全部；全选 = 删键 |
/// | 我的专辑展示 | `lizi.native.myAlbums.form` | spine | 原生键：MyAlbumsView 读这把键，壳版键不跟 |
/// | 跑马带速度 | `lizi.native.hall.marq.speed` | 24 | 原生键：HomeViewModel 读这把键 |
/// | 背景模式 | `lizi.background.mode` | `none`（默认背景） | r31-imagebg：`none` 默认 / `image` 静态图片 / `video` 动态壁纸（视频）；BackgroundStore 持有，HomeBackgroundView 消费；图片文件在 Application Support/lizi.background/background-image.jpg（无键，模式键即开关） |
/// | 背景视频文件名 | `lizi.background.videoFile` | `background-video.mov` | r31-imagebg：视频原扩展名保存（mov/mp4/m4v），文件在 Application Support/lizi.background/ |
/// | 默认音质 | `settings.audioQuality` | exhigh | r31：SettingsStore 持有（旧键 lizi.native.quality 一次性迁入，"spatial" 迁 .surround） |
/// | 播放来源 | `settings.playbackSourceMode` | automatic | r31：三段（自动/账号优先/第三方优先），只定优先顺序，不硬隔离 |
/// | 音质降级时提示 | `settings.qualityDowngradeNotice` | 开 | r31：实际档位低于请求档时，降级提示文案进选择器；关时只记日志 |
/// | LX 自动切换 | `lxAutoSwitch` | 关 | LXSourceRegistry 同键 |
/// | 120Hz 高刷 | `lizi.display.highRefreshRate` | 开 | r31-settings-sections：只控两处 CADisplayLink 的 `preferredFrameRateRange` 上限（开 120 / 关 60）；plist 的 CADisableMinimumFrameDurationOnPhone 是编译期解锁，运行时关不掉 |
/// | 每日自动签到 | `lizi.dailySignin.auto` | 关 | r31-signin：开 = 每天自动签一次（仅网易有签到接口）；默认关（现有签到是手动的，见下方网易每日签到区注释） |
///
/// 音质由本 store 存（r31 起）：默认档 / 播放来源 / 降级提示开关都在
/// 这里；`PlaybackStore.setPreferredQuality` 是全局默认档的写口
/// （写 settings.audioQuality），播放页选档是单曲覆盖，走
/// `PlaybackStore.setTrackQualityOverride`（不写盘，切歌清掉）。
/// 全 App 共用一个实例（`SettingsStore.shared`）：设置页与 PlaybackStore
/// 读同一份 @Published，拨动当场刷新，不各建各的。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    /// r35-6：播放页排版只留默认——旧键 `lizi.now.layout` 在这里启动时删掉，
    /// 旧设备上残留的 "02"/"04"/"06" 旧值再也不会被任何代码读到，不留死值。
    init() {
        UserDefaults.standard.removeObject(forKey: "lizi.now.layout")
    }

    // MARK: - 音乐与音质（r31 音质系统替换：Moumusic 的结构、Lizi 的语义）

    /// 全局默认档的键（Moumusic settings.audioQuality 同款键名）。
    static let audioQualityKey = "settings.audioQuality"
    /// 播放来源三段的键（Moumusic settings.playbackSourceMode 同款键名）。
    static let playbackSourceModeKey = "settings.playbackSourceMode"
    /// 降级提示开关的键（Moumusic qualityDowngradeNotice 同款键名）。
    static let qualityDowngradeNoticeKey = "settings.qualityDowngradeNotice"

    /// 读全局默认档（静态口，供 PlaybackStore 取链时读：它不持有
    /// SettingsStore 实例）。默认 exhigh；旧键 lizi.native.quality
    /// 有值时一次性迁入（"spatial" 是已删的档位，迁成最接近的
    /// .surround；非法值丢弃），迁完删旧键。
    static func storedAudioQuality() -> AudioQuality {
        if let raw = UserDefaults.standard.string(forKey: audioQualityKey),
           let q = AudioQuality(rawValue: raw) { return q }
        if let raw = UserDefaults.standard.string(forKey: "lizi.native.quality") {
            let migrated: AudioQuality? = raw == "spatial" ? .surround : AudioQuality(rawValue: raw)
            UserDefaults.standard.removeObject(forKey: "lizi.native.quality")
            if let q = migrated {
                UserDefaults.standard.set(q.rawValue, forKey: audioQualityKey)
                return q
            }
        }
        return .exhigh
    }

    /// 读播放来源三段（静态口，供 PlaybackStore 取链时读）。默认自动。
    static func storedPlaybackSourceMode() -> PlaybackSourceMode {
        if let raw = UserDefaults.standard.string(forKey: playbackSourceModeKey),
           let mode = PlaybackSourceMode(rawValue: raw) { return mode }
        return .automatic
    }

    /// 读降级提示开关（静态口，供 PlaybackStore 记降级时读）。默认开。
    static func storedQualityDowngradeNotice() -> Bool {
        if UserDefaults.standard.object(forKey: qualityDowngradeNoticeKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: qualityDowngradeNoticeKey)
    }

    // MARK: - 本地缓存上限（r48-12/13）
    // r48-12：缓存上限开关——默认 16GB、用户可调、重启保留。

    /// 本地缓存上限的键（DiskCache.limitKey 同键）：封面 + 歌词 + 音频信息
    /// 三路共用一个池。默认 **16384 MB（16GB）**，开箱即是；用户可调，
    /// 最小 512MB、最大 16GB；存在 UserDefaults，重启保留。
    static let coverDiskCacheLimitKey = DiskCache.limitKey
    /// 缓存上限档位（MB）：512MB / 1GB / 2GB / 4GB / 8GB / 16GB。
    static let coverDiskCacheLimitOptions = [512, 1024, 2048, 4096, 8192, 16384]

    /// 读缓存上限（MB，静态口，供 DiskCache 读）：非法/缺失回默认 16GB，
    /// 夹到 [512, 16384]。
    static func storedCoverDiskCacheLimitMB() -> Int {
        let raw = UserDefaults.standard.object(forKey: coverDiskCacheLimitKey) as? Int
        let mb = raw ?? DiskCache.defaultLimitMB
        return min(max(mb, DiskCache.minLimitMB), DiskCache.maxLimitMB)
    }

    /// 缓存上限显示串（512 MB / 1 GB / 2 GB / 4 GB / 8 GB / 16 GB）。
    static func coverDiskCacheLimitText(_ mb: Int) -> String {
        mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB"
    }

    /// 本地缓存上限（MB；默认 16GB；调小后多出的缓存立即清掉，调大不丢已有缓存）。
    // r48-12：didSet 写 UserDefaults + 调 pruneIfNeeded（调小清多余、调大保留）。
    @Published var coverDiskCacheLimitMB: Int = SettingsStore.storedCoverDiskCacheLimitMB() {
        didSet {
            let clamped = min(max(coverDiskCacheLimitMB, DiskCache.minLimitMB), DiskCache.maxLimitMB)
            if clamped != coverDiskCacheLimitMB { coverDiskCacheLimitMB = clamped; return }
            UserDefaults.standard.set(coverDiskCacheLimitMB, forKey: Self.coverDiskCacheLimitKey)
            // 调小上限后多出的缓存立即按 LRU 清掉（DiskCache.pruneIfNeeded
            // 按当前上限清到 80% 水位）；调大只改上限，已有缓存一律保留。
            DiskCache.pruneIfNeeded()
        }
    }

    /// 全局默认档（默认 exhigh；9 档全列，不探测、不设限——R3 已删，
    /// 选什么档都直发音源，返回什么播什么）。
    @Published var audioQuality: AudioQuality = SettingsStore.storedAudioQuality() {
        didSet { UserDefaults.standard.set(audioQuality.rawValue, forKey: Self.audioQualityKey) }
    }

    /// 播放来源三段（默认自动；只定腿的优先顺序，不硬隔离——R7 已删，
    /// 任一段拿不到时另一段都可兜底）。
    @Published var playbackSourceMode: PlaybackSourceMode = SettingsStore.storedPlaybackSourceMode() {
        didSet { UserDefaults.standard.set(playbackSourceMode.rawValue, forKey: Self.playbackSourceModeKey) }
    }

    /// 音质降级时提示（默认开；关时实际档位低于请求档只记 DiagLog，
    /// 选择器里不弹提示文案）。
    @Published var qualityDowngradeNotice: Bool = SettingsStore.storedQualityDowngradeNotice() {
        didSet { UserDefaults.standard.set(qualityDowngradeNotice, forKey: Self.qualityDowngradeNoticeKey) }
    }

    // MARK: - 开关（默认开的用「缺省 = 开」语义，默认关的用 bool 直读）

    /// 动画插图（壳版第 12 轮第 20 件）：开 = 锁屏专辑封面动态（本地生成，
    /// 每首歌都有）；关 = 整个动态封面关掉，锁屏回静态专辑图。默认开。
    @Published var animatedArtwork: Bool = SettingsStore.boolDefaultOn(key: "lizi.animatedArtwork") {
        didSet { UserDefaults.standard.set(animatedArtwork, forKey: "lizi.animatedArtwork") }
    }

    // r55 Folia 歌词：LRCLIB 歌词兜底开关已删（
    // 旧兜底库全删；官方无词时走跨平台自动匹配，不再走 LRCLIB）。

    // r31-settings-organization：平台头像 / 平台颜色铺色 / 大厅内容轨
    // 三开关已删（只写键、原生大厅从不读，拨了无效；见文件头键表注）。

    // MARK: - 显示与性能 — 120Hz 高刷（r31-settings-sections）
    //
    // 开关只控运行时帧率：plist 的 CADisableMinimumFrameDurationOnPhone
    // 是编译期解锁（120Hz 工 project.yml 双写），运行时关不掉；开关控
    // 的是两处 CADisplayLink 的 preferredFrameRateRange（HomeCoverRingView
    // startFlatTimer + HomeView RailMarqueeDriver.start，经下面
    // frameRateRange() 取值；开关拨动时通知回调当场重算已建好的 link）：
    // 开 = maximum/preferred 120，关 = maximum/preferred 60。
    // 默认开——120Hz 工落地时两处就是硬编码 120（r31-120hz.cjs §2），
    // 开关默认开 = 既有行为不变，不擅自改默认。
    // 60Hz 机型：maximum 120 本就是无操作（屏最高 60），拨动无影响。
    // WKWebView 里的舞台/画廊 HTML requestAnimationFrame 仍封顶 60Hz
    //（Apple 无公开绕法，见 r31-120hz.cjs 诚实残留），开关管不到那里；
    // SphereGalleryView / DailyMarqueeView 的 1/120 Timer 也不是 vsync，
    // 不跟开关走（只改步进 cadence，不改刷新上限）。

    /// 120Hz 高刷开关的键（原生键；无键 = 开，与既有行为一致）。
    static let highRefreshRateKey = "lizi.display.highRefreshRate"
    /// 开关拨动时发的通知：两处 CADisplayLink 驱动已建好的 link
    /// 当场重算 preferredFrameRateRange，不用等下次回首页重建。
    static let highRefreshRateDidChangeNotification =
        Notification.Name("lizi.display.highRefreshRateDidChange")

    /// 120Hz 高刷新率静态读法（供 Home 的两个驱动用：它们不持有
    /// SettingsStore 实例，与 HomeViewModel 只读 UserDefaults 读
    /// localMusicShown 同款做法）。无键 = 开。
    static var highRefreshRateEnabled: Bool {
        boolDefaultOn(key: highRefreshRateKey)
    }

    /// 两处 CADisplayLink 共用的帧率范围（唯一取值口，不在各处另算，
    /// 免得两处 drift）：开 = 30–120/首选 120，关 = 30–60/首选 60。
    /// minimum 30 不动（允许 ProMotion 空闲降频，不强制常驻高刷）。
    static func frameRateRange() -> CAFrameRateRange {
        let max: Float = highRefreshRateEnabled ? 120 : 60
        return CAFrameRateRange(minimum: 30, maximum: max, preferred: max)
    }

    /// 120Hz 高刷新率开关：开 = 两处 display link 上限 120，
    /// 关 = 上限 60。默认开（见本区文件头注释）。
    /// didSet：写 UserDefaults（重启保留）+ 发通知（已建好的
    /// link 当场重算）；开关本身不碰 plist key（编译期，运行时关不掉）。
    @Published var highRefreshRate: Bool = SettingsStore.highRefreshRateEnabled {
        didSet {
            UserDefaults.standard.set(highRefreshRate, forKey: Self.highRefreshRateKey)
            NotificationCenter.default.post(name: Self.highRefreshRateDidChangeNotification, object: nil)
        }
    }

    /// 本地音乐在首页显示（壳版第 11 轮）：关后首页整块消失、不留占位；
    /// 只管显示/隐藏，不管导入。默认开。
    @Published var localMusicShown: Bool = SettingsStore.boolDefaultOn(key: "lizi.local.show") {
        didSet { UserDefaults.standard.set(localMusicShown, forKey: "lizi.local.show") }
    }

    // MARK: - 形态歌词（壳版 `#set-stage-lyric`，三档，不是开关）

    /// 形态歌词显示档：`orig` 原文 / `both` 双文（原文 ｜ 译文同排）/
    /// `trans` 译文。只改形态（可视化）里显示的字，播放页歌词不动；
    /// 没有译文的行照旧显示原文。键与默认值照抄壳版（安卓快照
    /// `app.js:1901-1905`：`lizi.stage.lyricMode`，默认 `orig`；
    /// 当前 `public/` 里这节已被删，只剩安卓快照与对照表可考）。
    /// 非法值回落 `orig`。
    @Published var stageLyricMode: String = SettingsStore.readStageLyricMode() {
        didSet {
            let v = Self.normalizeStageLyricMode(stageLyricMode)
            if v != stageLyricMode { stageLyricMode = v; return }
            UserDefaults.standard.set(v, forKey: Self.stageLyricModeKey)
        }
    }

    static let stageLyricModeKey = "lizi.stage.lyricMode"

    static let stageLyricModes: [(id: String, name: String)] = [
        ("orig", "原文"),
        ("both", "双文"),
        ("trans", "译文"),
    ]

    static func normalizeStageLyricMode(_ id: String) -> String {
        stageLyricModes.contains { $0.id == id } ? id : "orig"
    }

    static func readStageLyricMode() -> String {
        normalizeStageLyricMode(UserDefaults.standard.string(forKey: stageLyricModeKey) ?? "orig")
    }

    // MARK: - 我的专辑展示形态（壳版 `lizi.myAlbums.form` 语义，原生键）

    /// `spine` = 侧立 3D 架，`flow` = 正面 Cover Flow。默认 spine。
    /// 键用 `lizi.native.myAlbums.form`：MyAlbumsView 读这把键。
    @Published var myAlbumsForm: String = UserDefaults.standard.string(forKey: "lizi.native.myAlbums.form") == "flow" ? "flow" : "spine" {
        didSet { UserDefaults.standard.set(myAlbumsForm, forKey: "lizi.native.myAlbums.form") }
    }

    // MARK: - 跑马带速度（壳版 `lizi.hall.marq.speed` 语义，原生键）

    /// 大厅铺色态「每日推荐」跑马带速度，0–100，默认 24。HomeViewModel 读
    /// `lizi.native.hall.marq.speed` 这把键。
    @Published var marqueeSpeed: Double = {
        let v = UserDefaults.standard.object(forKey: "lizi.native.hall.marq.speed") as? Double ?? 24
        return min(100, max(0, v))
    }() {
        didSet { UserDefaults.standard.set(marqueeSpeed, forKey: "lizi.native.hall.marq.speed") }
    }

    var marqueeSpeedLabel: String {
        switch marqueeSpeed {
        case 0..<20: return "很慢"
        case 20..<40: return "慢"
        case 40..<70: return "适中"
        default: return "快"
        }
    }

    // MARK: - 平台管理（壳版 `lizi.platforms.v1` 语义）

    /// 7 平台 id（顺序 = 设置页平台账号行的顺序）。
    static let platformIds = ["netease", "qq", "kugou", "qishui", "bodian", "kuwo", "applemusic"]

    /// 大厅「我的」和顶部平台条里显示的平台。没存 = 全部；全选 = 删键
    /// （照抄壳版 platSave）。r22j：首页平台条已消费这把键
    /// （PlatformStripView 按它过滤；登录、播放不受影响）。
    /// seen 表（壳版 `lizi.platforms.v1.seen`，第 14 轮）：保存时写全部
    /// 平台 id；读时把「没见过」的 id（上次保存后才加入的新平台）默认
    /// 并入勾选；见过表缺失时，见过 = 已存列表本身。
    @Published var visiblePlatforms: Set<String> = SettingsStore.readVisiblePlatforms() {
        didSet { Self.writeVisiblePlatforms(visiblePlatforms) }
    }

    static func readVisiblePlatforms() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: "lizi.platforms.v1"),
              let list = try? JSONDecoder().decode([String].self, from: data),
              !list.isEmpty else { return Set(platformIds) }
        let stored = Set(list.filter { platformIds.contains($0) })
        guard !stored.isEmpty else { return Set(platformIds) }
        // 新平台默认并入：见过表里没有的 id = 上次保存后才加入的平台。
        let seen = readSeenPlatforms() ?? stored
        return stored.union(Set(platformIds).subtracting(seen))
    }

    /// 读「见过」表（缺失返回 nil，调用方按「见过 = 已存列表本身」处理）。
    private static func readSeenPlatforms() -> Set<String>? {
        guard let data = UserDefaults.standard.data(forKey: "lizi.platforms.v1.seen"),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(list.filter { platformIds.contains($0) })
    }

    private static func writeVisiblePlatforms(_ set: Set<String>) {
        if set.count >= platformIds.count {
            UserDefaults.standard.removeObject(forKey: "lizi.platforms.v1")
        } else if let data = try? JSONEncoder().encode(Array(set)) {
            UserDefaults.standard.set(data, forKey: "lizi.platforms.v1")
        }
        // 写勾选的同时写「见过」表（这次见过的全部平台 id），下次有新平台
        // 加入时才分得清「新平台」和「用户主动取消的平台」。
        if let seen = try? JSONEncoder().encode(platformIds) {
            UserDefaults.standard.set(seen, forKey: "lizi.platforms.v1.seen")
        }
    }

    var visiblePlatformsSummary: String {
        visiblePlatforms.count >= Self.platformIds.count
            ? "全部 7 个" : "已选 \(visiblePlatforms.count) 个"
    }

    // MARK: - 读值小工具

    private static func boolDefaultOn(key: String) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    private static func boolDefaultOff(key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    // MARK: - 平台账号登录态（只读聚合；登录流程本身是 P4）

    /// 一行一个平台的登录态快照。原生版无 App Group、与壳版不共享登录态，
    /// 首次启动全是未登录；状态直接读各平台在本 App 沙盒里的会话残留，
    /// 不编、不猜：
    /// - 网易云：SessionStore.hasMusicU（MUSIC_U Cookie）
    /// - QQ / 酷狗 / 汽水 / 波点 / 酷我：各平台 sidecarAuth（登录后才有）
    /// - Apple Music：开发者 token / 用户 token 任一已保存
    /// 注意：汽水/波点/酷狗的 `*-device` 设备号不是登录态，不算。
    struct PlatformAccount: Identifiable {
        let id: String
        let name: String
        /// 壳版行里写的限制，原样照搬。
        let limit: String
        let loggedIn: Bool
        var statusText: String { loggedIn ? "已登录" : "未连接" }
    }

    static let platformLimits: [String: String] = [
        "netease": "登录后可同步歌单与收藏",
        "qq": "播放需登录 · 第三方协议",
        "kugou": "播放需登录",
        "qishui": "未登录只有 30 秒试听",
        "bodian": "未登录只有 30 秒试听 · 仅大陆网络",
        "kuwo": "没有扫码登录 · 粘贴 Cookie",
        "applemusic": "公开 API 匿名可用 · 播放 30 秒试听",
    ]

    static let platformNames: [String: String] = [
        "netease": "网易云音乐",
        "qq": "QQ 音乐",
        "kugou": "酷狗音乐",
        "qishui": "汽水音乐",
        "bodian": "波点音乐",
        "kuwo": "酷我音乐",
        "applemusic": "Apple Music",
    ]

    /// 每次进设置页重读一次（登录态可能在别处变了）；不缓存、不推断。
    func platformAccounts() -> [PlatformAccount] {
        let store = SessionStore.shared
        let loggedIn: [String: Bool] = [
            "netease": store.hasMusicU,
            "qq": !(store.sidecarAuth("qq") ?? [:]).isEmpty,
            "kugou": !(store.sidecarAuth("kugou") ?? [:]).isEmpty,
            "qishui": !(store.sidecarAuth("qishui") ?? [:]).isEmpty,
            "bodian": !(store.sidecarAuth("bodian") ?? [:]).isEmpty,
            "kuwo": !(store.sidecarAuth("kuwo") ?? [:]).isEmpty,
            // AppleMusic.devTokenKey / userTokenKey（见 AppleMusic.swift）：
            // 任一 token 已保存 = 已配置登录态。
            "applemusic": !(UserDefaults.standard.string(forKey: "lizi.applemusic.devtoken") ?? "").isEmpty
                || !(UserDefaults.standard.string(forKey: "lizi.applemusic.usertoken") ?? "").isEmpty,
        ]
        return Self.platformIds.map { id in
            PlatformAccount(id: id,
                            name: Self.platformNames[id] ?? id,
                            limit: Self.platformLimits[id] ?? "",
                            loggedIn: loggedIn[id] ?? false)
        }
    }

    // MARK: - 本地音乐数量（只读；导入流程是 P4）

    /// 已导入的本地音频文件数（LocalMusic 清单里磁盘文件还在的条目）。
    var localMusicCount: Int { LocalMusic.list().count }

    var localMusicSummary: String {
        localMusicCount == 0 ? "未导入" : "已导入 \(localMusicCount) 首"
    }

    // MARK: - 网易每日签到（r25 #45：只做应用内入口，后端路由已有）
    //
    // r31-signin：每日自动签到开关 + 每天只签一次。
    // 现有行为（r30 基线核查）：签到是手动的——唯一调用点是设置页
    // 「签到」按钮（SettingsView），启动/回前台没有任何自动调用；
    // 壳版 public/api.js 也只接了调用、无界面入口。所以开关默认关，
    // 不擅自改默认。
    // 平台（7 个逐个核查，2026-11-21）：只有网易有可用签到接口
    // （weapi /point/dailyTask，Server/NetEase.swift 的 daily/signin）；
    // QQ、酷狗（主 App）、汽水、波点、酷我均未核实到可用签到接口，
    // Apple Music 根本没有签到机制；酷狗概念版 /youth/vip 是另一套
    // 账号/签名体系，Lizi 的酷狗登录不兼容，不接。自动签只签网易，
    // 不编其它平台的签到。

    /// 每日自动签到开关的键（原生键；无键 = 关）。
    static let autoDailySignInKey = "lizi.dailySignin.auto"
    /// 上次签到成功的日期键（`yyyy-MM-dd`，本地日历日；手动/自动共用
    /// 一把键——每天签到一次就行，不分手动自动）。
    static let lastSignedDateKey = "lizi.dailySignin.lastDate"
    /// 最近一次签到结果文案的键（成功/失败都写，重启保留，进设置页
    /// 就能看到，不静默）。
    static let lastSigninStatusKey = "lizi.dailySignin.lastStatus"

    /// 每日自动签到：开 = 每天自动签到一次；关 = 不自动签到。
    /// 默认关（现有行为是手动签，见本区文件头注释）。
    @Published var autoDailySignIn: Bool = SettingsStore.boolDefaultOff(key: SettingsStore.autoDailySignInKey) {
        didSet { UserDefaults.standard.set(autoDailySignIn, forKey: Self.autoDailySignInKey) }
    }

    /// 最近一次签到结果文案（自动/手动共用；从 UserDefaults 读，
    /// 重启保留；自动签在后台跑完后设置页 onAppear 时重读刷新）。
    @Published var lastSigninStatus: String = UserDefaults.standard.string(forKey: SettingsStore.lastSigninStatusKey) ?? "" {
        didSet { UserDefaults.standard.set(lastSigninStatus, forKey: Self.lastSigninStatusKey) }
    }

    /// 今天（本地日历日，`yyyy-MM-dd`）。
    static func todayString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// 今天已经签过没有（上次签到成功的日期 == 今天）。
    static func hasSignedInToday() -> Bool {
        UserDefaults.standard.string(forKey: lastSignedDateKey) == todayString()
    }

    /// 记下今天已签到（只在服务端确认签到成功后调；失败不记，
    /// 下次启动/回前台可再试）。
    static func recordSignedToday() {
        UserDefaults.standard.set(todayString(), forKey: lastSignedDateKey)
    }

    /// 设置页 onAppear 时重读最近一次签到结果（自动签可能在后台跑完，
    /// 本实例的 @Published 值还是旧的；只读 UserDefaults，不动其它设置）。
    func refreshSigninStatus() {
        lastSigninStatus = UserDefaults.standard.string(forKey: Self.lastSigninStatusKey) ?? ""
    }

    /// 调一次网易每日签到（`POST /api/daily/signin` → 服务端
    /// `Server/NetEase.swift` 的 `daily/signin`：weapi `/point/dailyTask`，
    /// type 0 安卓 + type 1 网页各一次；code 200 累加点数，code -2 当天已签
    /// 也算成功；两次都失败才算失败；未登录不调上游、直接回 code 301）。
    /// 返回（结果文案，是否签到成功）：成功含「当天已签过」（服务端
    /// code -2）——服务端已认今天签过，也记日期，不再重复调。
    /// 结果文案写进 lastSigninStatus（成功/失败都写，不静默）；
    /// 成功才记日期，失败不记。
    /// 回包里 `signedIn` / `alreadySigned` / `point` / `message`
    /// 原样转述；`point` 是服务端回包字段名，文案里只叫「点」，不另起名。
    static func performDailySignIn() async -> (text: String, signed: Bool) {
        guard let d = await NativeBridge.call(path: "/api/daily/signin") else {
            let text = "签到失败：服务端无响应（上游无响应）。"
            UserDefaults.standard.set(text, forKey: lastSigninStatusKey)
            return (text, false)
        }
        let code = (d["code"] as? NSNumber)?.intValue ?? -1
        let signedIn = (d["signedIn"] as? NSNumber)?.boolValue ?? false
        let alreadySigned = (d["alreadySigned"] as? NSNumber)?.boolValue ?? false
        let point = (d["point"] as? NSNumber)?.intValue ?? 0
        let message = d["message"] as? String ?? ""
        let text: String
        let signed: Bool
        if code == 301 || !signedIn {
            text = message.isEmpty ? "签到失败：需要登录网易云音乐后才能签到。" : message
            signed = false
        } else if alreadySigned {
            text = point > 0
                ? "今天已签到（之前已签过），共获得 \(point) 点。"
                : "今天已签到（之前已签过）。"
            signed = true
        } else {
            text = "签到成功，本次共获得 \(point) 点。"
            signed = true
        }
        UserDefaults.standard.set(text, forKey: lastSigninStatusKey)
        if signed { recordSignedToday() }
        return (text, signed)
    }

    /// 手动签到（设置页「签到」按钮，r25 #45 原签名不动）：
    /// 调一次，文案同步到 lastSigninStatus；成功也记日期——
    /// 手动签过了今天就算签过，自动签不再重复签。
    func dailySignIn() async -> String {
        let (text, _) = await Self.performDailySignIn()
        lastSigninStatus = text
        return text
    }

    /// 自动签到进行中守卫（启动 .task 与回前台可能交错触发；都在
    /// @MainActor 上下文串行跑，Bool 够用）：跑着就不再起第二趟，
    /// 绝不一次启动签两次。
    private static var autoSigninRunning = false

    /// 每日自动签到入口（启动 + 回前台调；LiziNativeApp 接线）：
    /// - 开关关 → 不签，直接回（用户明确选择，不打扰、不写状态）。
    /// - 今天已签过（手动/自动任一）→ 跳过，不重复调接口。
    /// - 未登录网易 → 不调服务端，写明「未登录」，不记日期。
    /// - 其余 → 签一次；成功记日期，失败写明原因、不记日期。
    /// 日期键是全局单键，与当前选中平台无关——切平台不重置；
    /// 跨天（日期字符串变了）才再签；重启 App 读同一把键，不重复签。
    static func runAutoDailySignInIfNeeded() async {
        guard UserDefaults.standard.bool(forKey: autoDailySignInKey) else { return }
        guard !hasSignedInToday() else { return }
        guard !autoSigninRunning else { return }
        autoSigninRunning = true
        defer { autoSigninRunning = false }
        guard SessionStore.shared.hasMusicU else {
            UserDefaults.standard.set("自动签到未执行：未登录网易云音乐，请先登录后再签到。",
                                      forKey: lastSigninStatusKey)
            return
        }
        _ = await performDailySignIn()
    }

    // MARK: - LX 自定义源（读/写 LXSourceRegistry 已有存储，不改取链逻辑）

    @Published private(set) var lxSources: [LXSourceMeta] = []
    @Published private(set) var lxAutoSwitch: Bool = LXSourceRegistry.shared.autoSwitchEnabled
    /// 最近一次 LX 操作的结果文案（成功/失败原因），显示在列表下方。
    @Published var lxStatus: String = ""

    func refreshLXSources() {
        lxSources = LXSourceRegistry.shared.list()
        lxAutoSwitch = LXSourceRegistry.shared.autoSwitchEnabled
    }

    func setLXAutoSwitch(_ on: Bool) {
        LXSourceRegistry.shared.setAutoSwitch(on)
        lxAutoSwitch = on
    }

    func setLXEnabled(id: String, enabled: Bool) {
        LXSourceRegistry.shared.setEnabled(id: id, enabled: enabled)
        refreshLXSources()
    }

    func deleteLXSource(id: String) {
        let ok = LXSourceRegistry.shared.delete(id: id)
        refreshLXSources()
        lxStatus = ok ? "已删除该源。" : "删不掉：该源不存在，或是内置源（内置源只能关，不能删）。"
    }

    /// 刷新 URL 导入的源（重新拉取最新脚本；本地导入的源没有刷新）。
    func refreshLXSource(id: String) async {
        do {
            let (meta, changed) = try await LXSourceRegistry.shared.refresh(id: id)
            await MainActor.run {
                refreshLXSources()
                lxStatus = changed ? "「\(meta.name)」已更新到新版本。" : "「\(meta.name)」已是最新。"
            }
        } catch {
            await MainActor.run { lxStatus = "刷新失败：\(error.localizedDescription)" }
        }
    }

    /// 从 URL 导入（GitHub/Gitee blob 链接自动转 raw，见 LXSourceStore）。
    func importLXSourceFromURL(_ urlString: String) async {
        let url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            await MainActor.run { lxStatus = "先输入脚本 URL。" }
            return
        }
        do {
            let meta = try await LXSourceRegistry.shared.importFromURL(url)
            await MainActor.run {
                refreshLXSources()
                lxStatus = "已导入「\(meta.name)」。"
            }
        } catch {
            await MainActor.run { lxStatus = "导入失败：\(error.localizedDescription)" }
        }
    }

    /// 从本地 .js 文件导入（文件选择器读到的文本原样交 registry 校验）。
    func importLXSourceFromFile(name: String, content: String) {
        do {
            let meta = try LXSourceRegistry.shared.importFile(name: name, content: content)
            refreshLXSources()
            lxStatus = "已导入「\(meta.name)」。"
        } catch {
            lxStatus = "导入失败：\(error.localizedDescription)"
        }
    }

    /// 批量导入本地 .js 文件（文件选择器可多选）：逐个校验注册，汇总结果，
    /// 不静默丢掉多选里除第一个以外的文件。
    func importLXSourceFiles(_ files: [(name: String, content: String)]) {
        guard !files.isEmpty else { return }
        var imported: [String] = []
        var failed: [String] = []
        for file in files {
            do {
                let meta = try LXSourceRegistry.shared.importFile(name: file.name, content: file.content)
                imported.append(meta.name)
            } catch {
                failed.append("\(file.name)：\(error.localizedDescription)")
            }
        }
        refreshLXSources()
        var parts: [String] = []
        if !imported.isEmpty { parts.append("已导入「\(imported.joined(separator: "」「"))」。") }
        if !failed.isEmpty { parts.append("失败 \(failed.count) 个：\(failed.joined(separator: "；"))") }
        lxStatus = parts.joined(separator: " ")
    }

    /// LX 平台短码 → 设置页显示名（wy/tx/kw/kg/qs/mg；未知短码原样显示）。
    static func lxPlatformDisplayName(_ code: String) -> String {
        switch code {
        case "wy": return "网易云"
        case "tx": return "QQ"
        case "kw": return "酷我"
        case "kg": return "酷狗"
        case "qs": return "汽水"
        case "mg": return "咪咕"
        case "bd": return "波点"
        case "local": return "本地"
        default: return code
        }
    }

    /// 一条源覆盖的平台显示名（逗号分隔，供设置页列表行用）。
    static func lxPlatformsDisplay(_ platforms: [String]) -> String {
        platforms.map { lxPlatformDisplayName($0) }.joined(separator: "、")
    }

    /// 给没有 sourceUrl 的旧记录补绑 URL（绑定后出现 URL 标记和刷新按钮）。
    func bindLXSourceURL(id: String, urlString: String) async {
        do {
            let meta = try await LXSourceRegistry.shared.bindURL(id: id, urlString: urlString)
            await MainActor.run {
                refreshLXSources()
                lxStatus = "「\(meta.name)」已绑定 URL。"
            }
        } catch {
            await MainActor.run { lxStatus = "绑定失败：\(error.localizedDescription)" }
        }
    }

    // MARK: - 诊断日志（关于 → 诊断日志，读 DiagLog 已有记录）

    /// DiagLog 全部记录的 JSON 文本（最近请求 + 事件 + 封面/音频/探活日志
    /// + 播放面包屑）。设置页只读不写。
    func diagnosticsText() -> String {
        let dict = DiagLog.shared.json()
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                      options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "诊断日志读不出来。"
        }
        return text
    }

    /// r31 日志清空：真清 DiagLog（内存 + 落盘全清，见 DiagLog.clearAllLogs），
    /// 返回清完后重读的诊断文本（空 JSON），供设置页当场刷新展开的日志区。
    /// 不是摆样子：清完 diagnosticsText() 里 logs/requests/events/
    /// playbackBreadcrumb 全是空数组，重启后读盘也是空的。
    func clearDiagnostics() -> String {
        DiagLog.shared.clearAllLogs()
        return diagnosticsText()
    }
}
