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
        // 第 21 轮第 1 件：先上报上次死在哪一步（读干净退出旗标 + 快照面包屑
        // 最后一步），再干别的——DiagLog.shared 的 init 只读盘，不报死亡。
        DiagLog.shared.markLaunched()
        // 赞助版内置源：包内有 Resources/LXSponsored/linglan.js 时注册为
        //「聆澜音源（赞助版）」（默认启用、可关不可删）；包内没有时静默
        // 不出现。壳版包里没有该文件，调用是空操作。
        LXSourceRegistry.shared.registerBundledSponsoredSourceIfPresent()
        // 第 22 轮第 5 件（照 Moumusic 三件套 @MainActor）：PlaybackStore /
        // NativeIslandCoordinator / NowPlayingCoordinator 都是 @MainActor，
        // 在非隔离的 App.init 里只能用 MainActor.assumeIsolated 创建
        //（启动本来就在主线程，安全；Swift 5 语言模式下这是编译要求）。
        // r22l 编译修（第 2 推）：上一轮 let→var 是错的——var 未初始化就被
        // 闭包捕获、闭包之后又被使用，编译器定性初始化分析过不了。
        // 改用 assumeIsolated 的返回值形式，一次性把三个对象带出来，
        // 不再用外层未初始化变量接；创建方式与隔离都不变，仍在
        // MainActor.assumeIsolated 里建（启动本来就在主线程）。
        let (store, island, nowPlaying) = MainActor.assumeIsolated {
            let store = PlaybackStore()
            let island = NativeIslandCoordinator(store: store)
            let nowPlaying = NowPlayingCoordinator()
            nowPlaying.bind(store: store)
            return (store, island, nowPlaying)
        }
        _playback = StateObject(wrappedValue: store)
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
                    //（防系统把锁屏按钮回落到 ±10 秒）。两个协调器都是
                    // @MainActor（第 22 轮第 5 件），跳主线程再调。
                    Task { @MainActor in
                        islandCoordinator.refreshAuthorization()
                        nowPlayingCoordinator.reassertRemoteCommands()
                    }
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
/// 8 秒（第 22 轮第 5 件）+ 启动时 LiveActivityManager.init 里清残留活动。
final class LiziNativeAppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        LiveActivityManager.endAllActivitiesSynchronously(timeout: 2)
        // 第 21 轮第 1 件：干净退出记一笔，下次启动不再报死亡
        // （iOS 很少走这里，见 DiagLog.markLaunched 注释）。
        DiagLog.shared.markCleanExit()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lizi.island.terminatedAt")
    }
}
