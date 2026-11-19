import SwiftUI

/// Lizi 原生版 App 入口（P0 脚手架）。
///
/// 只做骨架：根视图是空态首页，不接任何页面功能，不启动本地 HTTP 服务，
/// 不启动灵动岛。页面功能、播放核心、岛/锁屏接线由 P1 起的工人接。
@main
struct LiziNativeApp: App {
    @StateObject private var playback = PlaybackStore()

    var body: some Scene {
        WindowGroup {
            NativeHomeView()
                .environmentObject(playback)
        }
    }
}
