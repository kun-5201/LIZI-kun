import SwiftUI

/// 原生版导航壳（P1-B 定死，搜索页 / 播放页工人共用同一个 AppNavigation）。
///
/// 约定：
/// - 视图只有三档：`home`（首页）/ `search`（搜索页）/ `player`（播放页）。
/// - P2 内容页（P2-A 一次加全四工人共用）：`playlist`（歌单详情，A）、
///   `artist` / `album`（歌手/专辑页，B）、`myAlbums`（我的专辑，C）、
///   `rail`（精选/喜欢/收藏歌单/电台，D；kind 取 "featured"/"liked"/
///   "playlists"/"radio" 四个字符串字面量）。
/// - 切换只改 `current` 一个 @Published 状态，不用 NavigationStack 嵌套，
///   避免壳版 WebView 时代那种「页里套页」的层级；返回首页就是 `show(.home)`。
/// - `AppView` 放顶层（不在类里嵌套），搜索 / 播放工人直接引用 `AppView.search`。
enum AppView: Hashable {
    case home
    case search
    case player
    /// 歌单详情：platform 为平台 id；isRank 为真时酷我走榜单接口
    /// /api/kuwo/rank/tracks（见 NativeBridge.playlistDetail）。
    case playlist(platform: String, id: String, isRank: Bool = false)
    /// 歌手页（P2-B）。
    case artist(platform: String, id: String)
    /// 专辑页（P2-B）。
    case album(platform: String, id: String)
    /// 我的专辑 3D 陈列架（P2-C）。
    case myAlbums
    /// 精选/喜欢/收藏/电台 rail（P2-D）：
    /// kind = "featured" / "liked" / "playlists" / "radio"。
    case rail(kind: String, platform: String)
}

/// 全 App 唯一的导航状态机：由 RootView 以 @StateObject 持有，
/// 经 environmentObject 下发给首页 / 搜索 / 播放三页。
final class AppNavigation: ObservableObject {
    @Published var current: AppView = .home

    func show(_ view: AppView) {
        current = view
    }

    func goHome() {
        current = .home
    }
}
