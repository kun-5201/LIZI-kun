import SwiftUI

/// 登录弹窗宿主（r23a 登录底座；设置页 / 账号详情页 / 登录提示弹的就是它）。
///
/// 按平台 id 分发到各平台的 flow 视图（r23b–r23e 已建好，直接分发真视图，
/// 不是占位——原任务写“它们还没建”时 flow 还没落盘，现已全部落盘）：
/// - 网易 `NetEaseLoginView()`、酷狗 `KugouLoginView()`、QQ `QQLoginView()`、
///   酷我 `KuwoLoginView()`、Apple Music `AppleMusicLoginView()`：零参构造，
///   内部用 `@Environment(\.dismiss)` 关弹窗，登录态走静态
///   `LoginStore.refresh(platform:)` / `LoginStore.logout(platform:)`。
/// - 汽水 `QishuiLoginView(onClose:)`、波点 `BodianLoginView(onClose:)`：
///   `onClose` 接宿主的关闭（`onDone()` + `dismiss()`）。
/// - flow 视图与底座的调用形式已定稿为静态式（见 `LoginStore` 文件头），
///   本宿主不向 flow 传 store 实例；`store` 参数只留给调用方按任务接口
///   约定传入（`@ObservedObject LoginStore + onDone`），宿主用它观察登录态。
///
/// Sheet 标题用平台真名（`SettingsStore.platformNames`：网易云音乐 / QQ 音乐 /
/// 酷狗音乐 / 汽水音乐 / 波点音乐 / 酷我音乐 / Apple Music），关闭按钮常在
/// （导航栏取消按钮 + 各 flow 自己的取消 / 完成路径都走同一个 `close()`）。
struct LoginSheetView: View {
    let platform: String
    @ObservedObject var store: LoginStore
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// r23f 的调用点是 `LoginSheetView(platform:)`——store 默认共享底座，
    /// onDone 默认空（只关弹窗）；需要登录成功回调的调用方显式传 onDone。
    init(platform: String, store: LoginStore = .shared, onDone: @escaping () -> Void = {}) {
        self.platform = platform
        self.store = store
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            flowView
                .navigationTitle(platformName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { close() }
                    }
                }
        }
    }

    private var platformName: String {
        SettingsStore.platformNames[platform] ?? platform
    }

    /// 关弹窗：先调调用方的 onDone（登录成功回调等），再 dismiss。
    /// `.sheet(item:)` 弹出的本页调 `dismiss()` 会把绑定的 item 清掉。
    private func close() {
        onDone()
        dismiss()
    }

    @ViewBuilder
    private var flowView: some View {
        switch platform {
        case "netease":
            NetEaseLoginView()
        case "qq":
            QQLoginView()
        case "kugou":
            KugouLoginView()
        case "qishui":
            QishuiLoginView(onClose: close)
        case "bodian":
            BodianLoginView(onClose: close)
        case "kuwo":
            KuwoLoginView()
        case "applemusic":
            AppleMusicLoginView()
        default:
            // 未知平台 id：不编一个登录页，原样报出来。
            VStack(spacing: 12) {
                Text("未知平台：\(platform)")
                Text("没有这个平台的登录流程。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(20)
        }
    }
}
