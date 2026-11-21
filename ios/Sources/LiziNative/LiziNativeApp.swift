import SwiftUI
import UIKit

/// Lizi 原生版 App 入口（P1：播放核心接线）。
///
/// 只做接线，不做页面 UI：PlaybackStore（播放核心）+ NowPlayingCoordinator
/// （锁屏/远程命令，经 MPNowPlayingInfoCenter 供系统锁屏卡）+
/// LiveActivityCoordinator（灵动岛，r35-11 按 Apple Music 那套重加：
/// 播起来起岛、音乐停了岛消失；点岛进播放页）在 init 里建好并互相连上。
/// 不启动本地 HTTP 服务、不启动 WebView。
/// r28 曾整个移除灵动岛（岛协调器、原生岛扩展、岛管理器接线全删），
/// r35-11 按用户要求重加（只加原生版，壳版不动）。
@main
struct LiziNativeApp: App {
    @UIApplicationDelegateAdaptor(LiziNativeAppDelegate.self) var appDelegate

    @StateObject private var playback: PlaybackStore
    private let nowPlayingCoordinator: NowPlayingCoordinator
    private let liveActivityCoordinator: LiveActivityCoordinator

    init() {
        // 第 21 轮第 1 件：先上报上次死在哪一步（读干净退出旗标 + 快照面包屑
        // 最后一步），再干别的——DiagLog.shared 的 init 只读盘，不报死亡。
        DiagLog.shared.markLaunched()
        // r31：赞助版内置源已删，不再注册任何内置源；LX 兜底只走用户自加的自定义源。
        // 第 22 轮第 5 件（照 Moumusic 三件套 @MainActor）：PlaybackStore /
        // NowPlayingCoordinator 都是 @MainActor，
        // 在非隔离的 App.init 里只能用 MainActor.assumeIsolated 创建
        //（启动本来就在主线程，安全；Swift 5 语言模式下这是编译要求）。
        // r22l 编译修（第 2 推）：上一轮 let→var 是错的——var 未初始化就被
        // 闭包捕获、闭包之后又被使用，编译器定性初始化分析过不了。
        // 改用 assumeIsolated 的返回值形式，一次性把两个对象带出来，
        // 不再用外层未初始化变量接；创建方式与隔离都不变，仍在
        // MainActor.assumeIsolated 里建（启动本来就在主线程）。
        let (store, nowPlaying, liveActivity) = MainActor.assumeIsolated {
            let store = PlaybackStore()
            let nowPlaying = NowPlayingCoordinator()
            nowPlaying.bind(store: store)
            let liveActivity = LiveActivityCoordinator()
            liveActivity.bind(store: store)
            // r35-11：岛上控制 Intent 的中继——Intent 在 App 进程内执行，
            // 经这里调 PlaybackStore（不打开 App）。App 刚被 Intent 唤醒时
            // handler 可能还没挂好，dispatch 最多等 2 秒（见中继注释）。
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
            return (store, nowPlaying, liveActivity)
        }
        _playback = StateObject(wrappedValue: store)
        self.nowPlayingCoordinator = nowPlaying
        self.liveActivityCoordinator = liveActivity
    }

    var body: some Scene {
        WindowGroup {
            NativeHomeView()
                .environmentObject(playback)
                .task {
                    // r31-signin：启动时跑一次每日自动签到（开关开 +
                    // 今天没签过才真签；关/已签/未登录都在里面直接回）。
                    await SettingsStore.runAutoDailySignInIfNeeded()
                    // r31-qqkg：启动时跑一次 12h 静默刷新（QQ / 酷狗画像；
                    // 未到 12h 直接回，不发请求）。
                    await SessionRefreshCoordinator.shared.refreshIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // 回前台：复核一次远程命令（防系统把锁屏按钮回落到 ±10 秒）。
                    // 协调器是 @MainActor（第 22 轮第 5 件），跳主线程再调。
                    // 灵动岛不用在这里复核：LiveActivityCoordinator 的订阅
                    // 在状态变化时自己 sync，授权态在每次 sync 里都查
                    // areActivitiesEnabled。
                    Task { @MainActor in
                        nowPlayingCoordinator.reassertRemoteCommands()
                        // r31-signin：回前台复核一次自动签到（跨天后不用
                        // 重启也签；同一天已签过时日期守卫直接跳过，不重复签）。
                        await SettingsStore.runAutoDailySignInIfNeeded()
                        // r31-qqkg：回前台复核一次 12h 静默刷新。
                        await SessionRefreshCoordinator.shared.refreshIfNeeded()
                    }
                }
        }
    }
}

/// App 终止处理（照抄壳版 LiziAppDelegate，第 12 轮 03:43）。
///
/// 注意区分：切到后台（按 Home、切别的 App）不算关——那时只走 scenePhase /
/// didEnterBackground，不进这里，音乐还在；只有 App 真正被关掉
/// （从后台划掉、进程结束）才走 applicationWillTerminate。
///
/// r28 曾移除灵动岛，终止时不再同步 end 任何 Live Activity；
/// r35-11 重加后终止时尽力清岛（iOS 很少走这里，清不掉的靠
/// staleDate 回收，见 LiveActivityCoordinator）；只记一笔干净退出供下次启动诊断。
final class LiziNativeAppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        // 第 21 轮第 1 件：干净退出记一笔，下次启动不再报死亡
        // （iOS 很少走这里，见 DiagLog.markLaunched 注释）。
        DiagLog.shared.markCleanExit()
        LiveActivityCoordinator.endAll()
    }
}
