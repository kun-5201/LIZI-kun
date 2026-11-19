import SwiftUI
import UIKit

/// Lizi 原生版 App 入口（P1：播放核心接线）。
///
/// 只做接线，不做页面 UI：PlaybackStore（播放核心）+ NativeIslandCoordinator
/// （灵动岛）+ NowPlayingCoordinator（锁屏/远程命令）在 init 里建好并互相连上。
/// 不启动本地 HTTP 服务、不启动 WebView。
/// 终止处理照抄壳版 LiziAppDelegate：App 被关掉时岛必须马上消失（同步 end +
/// terminatedAt 标记）；切到后台不走这里，岛和音乐都还在。
@main
struct LiziNativeApp: App {
    @UIApplicationDelegateAdaptor(LiziNativeAppDelegate.self) var appDelegate

    @StateObject private var playback: PlaybackStore
    private let islandCoordinator: NativeIslandCoordinator
    private let nowPlayingCoordinator: NowPlayingCoordinator

    init() {
        let store = PlaybackStore()
        _playback = StateObject(wrappedValue: store)
        let island = NativeIslandCoordinator(store: store)
        let nowPlaying = NowPlayingCoordinator()
        nowPlaying.bind(store: store)
        self.islandCoordinator = island
        self.nowPlayingCoordinator = nowPlaying
        // 岛上控制直调播放器（不再点 DOM）：previous / togglePlay / next / toggleLike。
        // Intent 在 App 进程内执行；handler 同步返回 true（已接下），动作跳到主线程执行。
        IslandControlRelay.shared.handler = { [weak store] action in
            guard let store else { return false }
            Task { @MainActor in
                switch action {
                case .previous: store.previous()
                case .togglePlay: store.togglePlay()
                case .next: store.next()
                case .toggleLike: store.toggleLike()
                }
            }
            return true
        }
    }

    var body: some Scene {
        WindowGroup {
            NativeHomeView()
                .environmentObject(playback)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // 回前台：重读 Live Activities 授权态 + 复核一次远程命令
                    //（防系统把锁屏按钮回落到 ±10 秒）。
                    islandCoordinator.refreshAuthorization()
                    nowPlayingCoordinator.reassertRemoteCommands()
                }
        }
    }
}

/// App 终止处理（照抄壳版 LiziAppDelegate，第 12 轮 03:43）。
///
/// 注意区分：切到后台（按 Home、切别的 App）不算关——那时只走 scenePhase /
/// didEnterBackground，不进这里，岛和音乐都还在；只有 App 真正被关掉
/// （从后台划掉、进程结束）才走 applicationWillTerminate。
///
/// end 必须是同步落地的——fire-and-forget 的 Task 可能在进程死前根本没跑起来；
/// 这里调 LiveActivityManager.endAllActivitiesSynchronously，等 end 真正完成
/// （最多 2 秒）才返回，再记一笔终止标记供下次启动诊断。
/// 进程被 SIGKILL（没机会跑 willTerminate）的极端情况兜底：staleDate 已收紧到
/// 10 秒 + 启动时 LiveActivityManager.init 里清残留活动。
final class LiziNativeAppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        LiveActivityManager.endAllActivitiesSynchronously(timeout: 2)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lizi.island.terminatedAt")
    }
}
