import SwiftUI
import UIKit

@main
struct LiziApp: App {
    @UIApplicationDelegateAdaptor(LiziAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// App 终止处理（第 12 轮 03:43：App 被关掉时灵动岛必须马上消失，一秒都不能留）。
///
/// 注意区分：切到后台（按 Home、切别的 App）不算关——那时只走 scenePhase /
/// didEnterBackground，不进这里，岛和音乐都还在；只有 App 真正被关掉
/// （从后台划掉、进程结束）才走 applicationWillTerminate。
///
/// kun #58 的教训：end 必须是同步落地的——fire-and-forget 的 Task 可能在
/// 进程死前根本没跑起来；这里调 LiveActivityManager.endAllActivitiesSynchronously，
/// 等 end 真正完成（最多 2 秒）才返回，再记一笔终止标记供下次启动诊断。
/// 进程被 SIGKILL（没机会跑 willTerminate）的极端情况兜底：staleDate 已收紧到
/// 10 秒 + 启动时 LiveActivityManager.init 里清残留活动。
final class LiziAppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        LiveActivityManager.endAllActivitiesSynchronously(timeout: 2)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lizi.island.terminatedAt")
    }
}
