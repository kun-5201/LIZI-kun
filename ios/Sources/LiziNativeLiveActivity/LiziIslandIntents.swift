import AppIntents
import Foundation

/// 灵动岛展开页上的控制按钮（第 12 轮第 15 件：按 03:41 展开页截图重做；
/// r22d：锁屏卡片已撤，按钮只剩岛的展开页在用，见 LiziLiveActivityViews.swift）。
///
/// 本文件同时编进 App target 与扩展 target（project.yml 里 Lizi target 的
/// sources 显式加了这一份）：扩展里只用它构造 Button(intent:)，
/// App 里跑 perform()。只依赖 AppIntents/Foundation，别引 WebKit。
///
/// 传输：LiveActivityIntent 在 App 进程内执行（iOS 17.2+），不打开 App；
/// perform() 只调同进程的 IslandControlRelay；handler 由 `LiziNativeApp`
/// 在 init 里注册（`LiziNativeApp.swift:48-59`），闭包直接调原生
/// `PlaybackStore`（previous / togglePlay / next / toggleLike），
/// 不经过 WebHost、不点 DOM 按钮、不执行 JS、不走 HTTP、不依赖本地服务
/// 端口，也不用 App Group（本工程没有）。
///
/// AirPlay 不走这里：第三方 Live Activity 里放不了 AVRoutePickerView
/// （UIKit 视图，Widget 只支持纯 SwiftUI），也没有公开 API 能在岛上
/// 原地弹出系统路由面板；展开页的 AirPlay 用 Link 到 lizinative://airplay，
/// 打开 App 并直接弹出系统路由选择页（见 ContentView.AirPlayPickerSheet）。
/// 锁屏系统播放器自带的 AirPlay 按钮是系统画的，不用 App 管。

/// 岛上控制动作。
enum IslandControlAction: String, AppEnum {
    case previous
    case togglePlay
    case next
    case toggleLike

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "岛上控制")
    }

    static var caseDisplayRepresentations: [IslandControlAction: DisplayRepresentation] {
        [
            .previous: DisplayRepresentation(title: "上一首"),
            .togglePlay: DisplayRepresentation(title: "播放/暂停"),
            .next: DisplayRepresentation(title: "下一首"),
            .toggleLike: DisplayRepresentation(title: "喜欢"),
        ]
    }
}

/// 岛上控制 Intent：点按钮 → 在 App 进程内执行 → 中继调原生播放器。
/// 不打开 App（openAppWhenRun = false）。
@available(iOS 17.2, *)
struct LiziIslandControlIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "岛上控制" }
    static var openAppWhenRun: Bool { false }

    // 注意：@Parameter 的初始化器不接受 wrappedValue，不能写
    // `@Parameter(title: "动作") var action: … = .togglePlay`
    //（编包会报 extra argument 'wrappedValue' in call）；默认值在 init() 里给。
    @Parameter(title: "动作") var action: IslandControlAction

    init() {
        self.action = .togglePlay
    }

    init(action: IslandControlAction) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        _ = await IslandControlRelay.dispatch(action)
        return .result()
    }
}

/// 同进程中继：Intent 与原生播放器之间唯一的口子。
/// handler 由 `LiziNativeApp` 在 init 里注册（`LiziNativeApp.swift:48-59`：
/// 闭包捕获 `PlaybackStore`，动作跳到主线程执行 previous / togglePlay /
/// next / toggleLike，同步返回 true 表示已接下）；Intent 侧只认这个闭包。
/// App 刚被 Intent 唤醒时 App 可能还没完成 init、handler 还没挂上，
/// dispatch 最多等 2 秒（每 50ms 查一次），等不到就返回 false（按钮这次没生效，
/// 岛还在，用户再点一次即可；App 播着歌时 handler 一直都在，不会走到这一步）。
final class IslandControlRelay {
    static let shared = IslandControlRelay()

    /// LiziNativeApp 注册：收到动作返回 true（已接下，动作跳到主线程执行）；
    /// handler 还没挂上时返回 false（dispatch 会等 2 秒再试）。
    var handler: ((IslandControlAction) -> Bool)?

    private init() {}

    static func dispatch(_ action: IslandControlAction) async -> Bool {
        for _ in 0..<40 {
            if let h = shared.handler, h(action) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}
