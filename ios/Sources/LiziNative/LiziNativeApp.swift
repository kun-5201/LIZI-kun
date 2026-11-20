import SwiftUI
import UIKit

/// Lizi 原生版 App 入口（P1：播放核心接线）。
///
/// 只做接线，不做页面 UI：PlaybackStore（播放核心）+ NowPlayingCoordinator
/// （锁屏/远程命令，经 MPNowPlayingInfoCenter 供系统锁屏卡）在 init 里建好并互相连上。
/// 不启动本地 HTTP 服务、不启动 WebView。
/// r28：灵动岛已整个移除（岛协调器、原生岛扩展、岛管理器接线全删）；锁屏只剩系统那张卡。
@main
struct LiziNativeApp: App {
    @UIApplicationDelegateAdaptor(LiziNativeAppDelegate.self) var appDelegate

    @StateObject private var playback: PlaybackStore
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
        // NowPlayingCoordinator 都是 @MainActor，
        // 在非隔离的 App.init 里只能用 MainActor.assumeIsolated 创建
        //（启动本来就在主线程，安全；Swift 5 语言模式下这是编译要求）。
        // r22l 编译修（第 2 推）：上一轮 let→var 是错的——var 未初始化就被
        // 闭包捕获、闭包之后又被使用，编译器定性初始化分析过不了。
        // 改用 assumeIsolated 的返回值形式，一次性把两个对象带出来，
        // 不再用外层未初始化变量接；创建方式与隔离都不变，仍在
        // MainActor.assumeIsolated 里建（启动本来就在主线程）。
        let (store, nowPlaying) = MainActor.assumeIsolated {
            let store = PlaybackStore()
            let nowPlaying = NowPlayingCoordinator()
            nowPlaying.bind(store: store)
            return (store, nowPlaying)
        }
        _playback = StateObject(wrappedValue: store)
        self.nowPlayingCoordinator = nowPlaying
    }

    var body: some Scene {
        WindowGroup {
            NativeHomeView()
                .environmentObject(playback)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // 回前台：复核一次远程命令（防系统把锁屏按钮回落到 ±10 秒）。
                    // 协调器是 @MainActor（第 22 轮第 5 件），跳主线程再调。
                    // r28：灵动岛已移除，不再重读 Live Activities 授权态。
                    Task { @MainActor in
                        nowPlayingCoordinator.reassertRemoteCommands()
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
/// r28：灵动岛已移除，终止时不再同步 end 任何 Live Activity；
/// 只记一笔干净退出供下次启动诊断。
final class LiziNativeAppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        // 第 21 轮第 1 件：干净退出记一笔，下次启动不再报死亡
        // （iOS 很少走这里，见 DiagLog.markLaunched 注释）。
        DiagLog.shared.markCleanExit()
    }
}
