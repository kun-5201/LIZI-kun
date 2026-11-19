import Foundation

/// 设置统一存储（P3-C，NATIVE-REWRITE-PLAN.md §5 缺口 7）。
///
/// 键名 = 壳版 localStorage 键名逐项迁移（壳版 `public/app.js` 各设置项注释
/// 里写的键），除非原生已有消费者在用另一把键——那时跟消费者走，并在下面
/// 逐项注明，避免「设置写 A、页面读 B、开关白拨」：
///
/// | 设置项 | 键 | 默认 | 备注 |
/// |---|---|---|---|
/// | 动画插图 | `lizi.animatedArtwork` | 开 | 与 NowPlayingCoordinator 同键，开关真生效 |
/// | LRCLIB 兜底 | `lizi.lrclib.enabled` | 开 | 与 Lrclib.enabledKey 同键 |
/// | 平台头像 | `lizi.hall.platAvatar` | 关 | 壳版键；原生大厅暂未消费（见 SettingsView 注释） |
/// | 平台颜色铺色 | `lizi.hall.platColor` | 关 | 壳版键；同上 |
/// | 大厅内容轨 | `lizi.hall.rail` | 开 | 壳版键；同上 |
/// | 本地音乐首页显示 | `lizi.local.show` | 开 | 壳版键；同上 |
/// | 播放页版式 | `lizi.now.layout` | `""`（默认） | 壳版 `player-layouts.js` 的键；PlayerView 暂未消费 |
/// | 平台管理（显示哪些平台） | `lizi.platforms.v1` | 全选（无键） | 壳版语义：没存 = 全部；全选 = 删键 |
/// | 我的专辑展示 | `lizi.native.myAlbums.form` | spine | 原生键：MyAlbumsView 读这把键，壳版键不跟 |
/// | 跑马带速度 | `lizi.native.hall.marq.speed` | 24 | 原生键：HomeViewModel 读这把键 |
/// | 音质 | `lizi.native.quality` | lossless | 经 PlaybackStore 读写，不在这里另起键 |
/// | LX 自动切换 | `lxAutoSwitch` | 关 | LXSourceRegistry 同键 |
///
/// 音质不由本 store 存：`PlaybackStore.setPreferredQuality` 是唯一写口，
/// 设置页只调它（取链档位当场生效，见 PlaybackStore.resolveURL）。
final class SettingsStore: ObservableObject {

    // MARK: - 开关（默认开的用「缺省 = 开」语义，默认关的用 bool 直读）

    /// 动画插图（壳版第 12 轮第 20 件）：开 = 锁屏专辑封面动态（本地生成，
    /// 每首歌都有）；关 = 整个动态封面关掉，锁屏回静态专辑图。默认开。
    @Published var animatedArtwork: Bool = SettingsStore.boolDefaultOn(key: "lizi.animatedArtwork") {
        didSet { UserDefaults.standard.set(animatedArtwork, forKey: "lizi.animatedArtwork") }
    }

    /// LRCLIB 歌词兜底（壳版第 13 轮第 20 件）：官方歌词优先；开后官方没有
    /// 歌词时才用 LRCLIB 兜底。默认开，与 Lrclib.isEnabled 同键同语义。
    @Published var lrclibEnabled: Bool = Lrclib.isEnabled {
        didSet { Lrclib.setEnabled(lrclibEnabled) }
    }

    /// 平台头像（壳版）：关时大厅平台方块只显示平台图标，不显示账号头像。默认关。
    @Published var platformAvatar: Bool = SettingsStore.boolDefaultOff(key: "lizi.hall.platAvatar") {
        didSet { UserDefaults.standard.set(platformAvatar, forKey: "lizi.hall.platAvatar") }
    }

    /// 用平台颜色铺色（壳版）：关时大厅铺色态取当前专辑封面颜色；开时回平台品牌色。默认关。
    @Published var platformColor: Bool = SettingsStore.boolDefaultOff(key: "lizi.hall.platColor") {
        didSet { UserDefaults.standard.set(platformColor, forKey: "lizi.hall.platColor") }
    }

    /// 大厅内容轨（壳版）：开 = 精选/喜欢/收藏直接在跑马带里切换；
    /// 关 = 恢复点卡片跳浏览页的旧交互。默认开。
    @Published var hallRail: Bool = SettingsStore.boolDefaultOn(key: "lizi.hall.rail") {
        didSet { UserDefaults.standard.set(hallRail, forKey: "lizi.hall.rail") }
    }

    /// 本地音乐在首页显示（壳版第 11 轮）：关后首页整块消失、不留占位；
    /// 只管显示/隐藏，不管导入。默认开。
    @Published var localMusicShown: Bool = SettingsStore.boolDefaultOn(key: "lizi.local.show") {
        didSet { UserDefaults.standard.set(localMusicShown, forKey: "lizi.local.show") }
    }

    // MARK: - 播放页版式（壳版 player-layouts.js，4 套）

    /// 播放页版式 id：`""` = 默认（现在的两栏）、`"02"` = 左右对半、
    /// `"04"` = 上下分屏、`"06"` = 极小封面。非法值回落默认。
    @Published var nowLayout: String = SettingsStore.readNowLayout() {
        didSet {
            let v = Self.normalizeLayout(nowLayout)
            if v != nowLayout { nowLayout = v; return }
            UserDefaults.standard.set(v, forKey: "lizi.now.layout")
        }
    }

    static let nowLayouts: [(id: String, name: String, desc: String)] = [
        ("", "默认", "现在的两栏"),
        ("02", "左右对半", "50/50 两列通高"),
        ("04", "上下分屏", "上半封面 · 下半歌词"),
        ("06", "极小封面", "96px 封面 · 大留白"),
    ]

    private static func normalizeLayout(_ id: String) -> String {
        nowLayouts.contains { $0.id == id } ? id : ""
    }

    private static func readNowLayout() -> String {
        normalizeLayout(UserDefaults.standard.string(forKey: "lizi.now.layout") ?? "")
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
    /// （照抄壳版 platSave）。注意：原生首页平台条本轮尚未消费这把键，
    /// 选择只做持久化，接线在 P3 打磨项；登录、播放不受影响。
    @Published var visiblePlatforms: Set<String> = SettingsStore.readVisiblePlatforms() {
        didSet { Self.writeVisiblePlatforms(visiblePlatforms) }
    }

    private static func readVisiblePlatforms() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: "lizi.platforms.v1"),
              let list = try? JSONDecoder().decode([String].self, from: data),
              !list.isEmpty else { return Set(platformIds) }
        return Set(list.filter { platformIds.contains($0) })
    }

    private static func writeVisiblePlatforms(_ set: Set<String>) {
        if set.count >= platformIds.count {
            UserDefaults.standard.removeObject(forKey: "lizi.platforms.v1")
        } else if let data = try? JSONEncoder().encode(Array(set)) {
            UserDefaults.standard.set(data, forKey: "lizi.platforms.v1")
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
    /// 注意：酷狗/汽水/波点的 `*-device` 设备号不是登录态，不算。
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

    /// LX 平台短码 → 设置页显示名（wy/tx/kg/kw/qs/mg；未知短码原样显示）。
    static func lxPlatformDisplayName(_ code: String) -> String {
        switch code {
        case "wy": return "网易云"
        case "tx": return "QQ"
        case "kg": return "酷狗"
        case "kw": return "酷我"
        case "qs": return "汽水"
        case "mg": return "咪咕"
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
}
