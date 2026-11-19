import SwiftUI

/// 原生版导航壳（P1-B 定死，搜索页 / 播放页工人共用同一个 AppNavigation）。
///
/// 约定：
/// - 视图只有三档：`home`（首页）/ `search`（搜索页）/ `player`（播放页）。
/// - 切换只改 `current` 一个 @Published 状态，不用 NavigationStack 嵌套，
///   避免壳版 WebView 时代那种「页里套页」的层级；返回首页就是 `show(.home)`。
/// - `AppView` 放顶层（不在类里嵌套），搜索 / 播放工人直接引用 `AppView.search`。
enum AppView: Hashable {
    case home
    case search
    case player
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
