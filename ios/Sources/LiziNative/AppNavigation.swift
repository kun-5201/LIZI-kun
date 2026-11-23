import SwiftUI

/// 原生版导航壳（P1-B 定死，搜索页 / 播放页工人共用同一个 AppNavigation）。
///
/// 约定：
/// - 视图只有三档：`home`（首页）/ `search`（搜索页）/ `player`（播放页）。
/// - P2 内容页（P2-A 一次加全四工人共用）：`playlist`（歌单详情，A）、
///   `artist` / `album`（歌手/专辑页，B）、`myAlbums`（我的专辑，C）、
///   `rail`（精选/喜欢/收藏歌单/电台，D；kind 取 "featured"/"liked"/
///   "playlists"/"radio" 四个字符串字面量）。
/// - P3-B 画廊：`forms`（形态长廊整页）、`gallery`（球面画廊）。
///   舞台页路由 `stage` 是 P3-A 的，进的是 StageView（HUD 舞台），
///   画廊「进入这个形态」直接走它，不另建宿主。
/// - 切换只改 `current` 一个 @Published 状态，不用 NavigationStack 嵌套，
///   避免壳版 WebView 时代那种「页里套页」的层级；返回首页就是 `show(.home)`。
/// - `AppView` 放顶层（不在类里嵌套），搜索 / 播放工人直接引用 `AppView.search`。
enum AppView: Hashable {
    case home
    case search
    case player
    /// 舞台页（P3-A）：formId 为空时用上次的形态（`StageCatalog.savedFormId()`）。
    /// r35-7：openSettings 为真时进页即打开设置浮层（传统横屏「舞台控制」钮）；
    /// 默认 false，进页不自动开浮层（旧行为一字不动）。
    case stage(formId: String? = nil, openSettings: Bool = false)
    /// 歌单详情：platform 为平台 id；isRank 为真时酷我走榜单接口
    /// /api/kuwo/rank/tracks（见 NativeBridge.playlistDetail）。
    /// r35-10：title / coverURL 是排行榜块点卡时传的种子（详情页第一
    /// 阶段先用它们显示头部，第二阶段回来保留真名真封面只补曲目，
    /// 见 PlaylistDetailViewModel）。r36（用户 21:43）：行首排名数字
    /// 作废，showRankNumbers 参数已删。title / coverURL 都是可选参数，
    /// 旧调用点走默认值不动。
    case playlist(platform: String, id: String, isRank: Bool = false,
                  title: String? = nil, coverURL: URL? = nil)
    /// 歌手页（P2-B）。
    case artist(platform: String, id: String)
    /// 专辑页（P2-B）。
    case album(platform: String, id: String)
    /// 我的专辑 3D 陈列架（P2-C）。
    case myAlbums
    /// 听歌排行（r31-rank）：只做网易服务端排行；platform 传当前账号平台，
    /// 非网易平台进页后给诚实空态（不编数据）。
    case listeningRank(platform: String)
    /// 设置页（P3-C）：7 分区全做，见 Views/Settings/SettingsView.swift。
    case settings
    /// 精选/喜欢/收藏/电台 rail（P2-D）：
    /// kind = "featured" / "liked" / "playlists" / "radio"。
    case rail(kind: String, platform: String)
    /// 形态长廊整页（P3-B）：WKWebView 承载 bundle 里的 forms-labs/index.html。
    case forms
    /// 球面画廊（P3-B）：原生球面 + 大预览，点中进 P3-A 的舞台页。
    case gallery
}

/// 全 App 唯一的导航状态机：由 RootView 以 @StateObject 持有，
/// 经 environmentObject 下发给首页 / 搜索 / 播放三页。
final class AppNavigation: ObservableObject {
    @Published var current: AppView = .home

    /// r36-7 本次播放器会话里选中的舞台形态（只放内存，不写 UserDefaults）。
    ///
    /// 语义：舞台形式只在本次进入播放器内切换时有效——舞台页里切形态
    /// （StageView 选择器 → `noteStageFormSelected`）只记在这里，不再写
    /// `lizi.native.playerMode`（见 StageBridge.load 的 r36-7 注释）；
    /// 回首页即重置（`show(.home)` / `goHome` 里清掉），下次进播放器是
    /// 传统播放器、再点舞台也不会把上个会话切的形态带回来。
    /// `.stage()` 无 formId 时 RootView 用它做第一回落（见 RootView
    /// `.stage` 分支）；它为空时再走 `StageCatalog.savedFormId()`（画廊
    /// 上次选的 / 默认 001），`savedFormId()` 本身一字不动。
    @Published private(set) var sessionStageFormId: String? = nil

    func show(_ view: AppView) {
        // r55：活动日志（死亡快照回落用；目标页截断 120 字）。
        DiagLog.shared.recordActivity("nav \(String(String(describing: view).prefix(120)))")
        // r36-7：回首页 = 本次播放器会话结束，会话级舞台选择清掉；
        // 所有回首页的路（舞台页返回、播放页返回、详情页返回栏……）都走
        // show(.home)，重置只放这一处，不用每个调用点各自清。
        if view == .home {
            sessionStageFormId = nil
        }
        current = view
    }

    /// 舞台页里切了形态：只记本次会话，不写持久化键（见上）。
    func noteStageFormSelected(_ id: String) {
        sessionStageFormId = id
    }

    /// 进传统播放器（r20 首页大卡片单击 / 双击共用）。
    ///
    /// 就是 `show(.player)`：RootView 的 `.player` 分支永远渲染传统
    /// PlayerView，从不读 `lizi.native.playerMode`，所以进传统不需要、也
    /// 不应该改持久化键——写 "classic" 反而坏事（`StageCatalog.isAvailable`
    /// 对 classic 恒为 false，`savedFormId()` 会回落到默认 "001"，下次点
    /// 舞台就丢了用户上次的形态）。舞台页里点「形态」仍走 `.stage()` 读保存的
    /// 形态，页内切换的持久化不受影响（顶栏纠正：r22a 的九宫格做法作废，
    /// 播放页顶栏的齿轮（控制舞台）按钮走 `.stage()`，不带 formId，读保存的
    /// 形态；九宫格只在舞台页，不在播放页；齿轮不进设置页、不在播放页弹调节面板）。
    /// 单独成一个方法，只为让“强制传统”这个意图在代码里可 grep、可验。
    func showClassicPlayer() {
        show(.player)
    }

    func goHome() {
        // r36-7：经 show(.home) 走，会话级舞台选择随之清掉（见 show）。
        show(.home)
    }
}
