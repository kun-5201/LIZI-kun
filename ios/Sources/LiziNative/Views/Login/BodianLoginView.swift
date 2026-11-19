import Foundation
import SwiftUI

/// 波点音乐二维码登录（r23d；r23 登录全套 P4）。
///
/// 波点**仅支持二维码登录，没有别的登录方式**（无账号密码、Cookie、token
/// 登录；壳版 `public/app.js:3924` note 只写「扫码登录」）。
/// 扫码应用：**波点音乐 App**（壳版 startQr 通用文案「用波点音乐 App 扫码」）。
///
/// 流程只走已有后端，不改后端（`ios/Sources/Lizi/Server/Bodian.swift`）：
/// - 取码：`GET /api/bodian/login/qr/key` → `{key}`，
///   key 即上游 `data.qrCode`，服务端待扫 5 分钟、同时最多 5 个；
///   **注意：key 响应里没有 qrimg，必须调 create 才能出图**；
/// - 出图：`GET /api/bodian/login/qr/create?key=` → `{qrimg, imageUrl}`，
///   二维码内容为服务端拼的登录页地址
///   `https://bodian-oia.kuwo.cn/bodian/download.html?pageName=login_pc&pt=3&id={key}`；
/// - 轮询：`GET /api/bodian/login/qr/check?key=`，2.2 秒一轮（壳版 2200ms），
///   取消：`GET /api/bodian/login/qr/cancel?key=`（尽力而为，不阻塞关弹窗）。
///
/// check 状态码映射（`Bodian.swift` loginQrCheck，约 275–325 行）：
/// | code | status   | 含义 | 本视图处理 |
/// |------|----------|------|-----------|
/// | 801  | waiting  | 等待扫码 | 继续轮询，文案「等待扫码」 |
/// | 802  | scanned  | 已扫码待确认（含上游 11027） | 继续轮询，文案「已扫码，请在手机上确认」 |
/// | 803  | confirmed | 已确认，服务端已换 token 存会话并清全部 QR 会话 | 停轮询 → `LoginStore.refresh` 确认 loggedIn → 成功 1.2 秒后关弹窗 |
/// | 800  | expired  | 二维码已过期 | 0.6 秒后自动换一张；连续 3 次以上过期则停手并报错 |
/// | —    | 请求本身失败（`NativeBridge.call` 回 nil） | 网络抖动 / 后端抛错（含未知 status） | 静默重试；连续 3 次失败则停手并报错 |
///
/// 波点**没有 804 refused**：`loginQrCheck` 只有 1/2/3 三档，未知 status
/// 直接抛 invalid-response（call 回 nil，走失败重试通道）。不要把汽水的
/// 804 映射抄过来。
///
/// 登录态以 status 接口为准：803 只代表扫码确认，**不直接当登录成功**；
/// 必须 `LoginStore.refresh(platform: "bodian")` 后直读
/// `/api/bodian/status` 的 `loggedIn` 为 true 才关弹窗，
/// 为 false 则留在页内报错、让用户点「换一张」重试。
/// 登出走 `LoginStore.logout(platform: "bodian")`（后端
/// `/api/bodian/logout` 已存在，清会话 + 全部 QR 会话），登出后再
/// 直读 status 一次确认回到未登录才显示「已退出登录」。
///
/// r23a 接线（共享底座由 r23a 建，本文件只用接口、不另建底座；与
/// Kugou/Kuwo/AppleMusic/NetEase 四家同款静态调用——注意 QQLoginView 用的是
/// `LoginStore.shared.refresh`，底座定稿时两处写法要统一成一种）：
/// - `LoginStore.refresh(platform:)`（静态）：重读 `/api/<platform>/status`
///   同步共享登录态；`LoginStore.logout(platform:)`（静态）：调后端 logout
///   并清本地态。refresh 不返回值，loggedIn 由本文件直读
///   `/api/bodian/status` 顶层 `loggedIn`（KugouLoginView.status() 同款写法，
///   call 回 nil 按未登录算）。
///   本文件不定义 `LoginStore`，也不定义 `QrLoginView` / `LoginSheetView`。
/// - 二维码区目前用原生 SwiftUI 直渲（`Image(uiImage:)`）；r23a 的
///   `QrLoginView` 落盘后，把 `qrImageView` 这一块换成它即可，
///   输入就是 qrImage / statusText / onRefresh / onCancel，状态机不动。
///
/// 未碰：PlaybackStore、selectPlatform、岛、播放页、首页、舞台、
/// SettingsView.swift、NativeBridge.swift、任何后端 Server 文件。
@MainActor
struct BodianLoginView: View {
    /// 宿主（LoginSheetView）传入的关闭回调；成功后由本视图在确认登录态后调用。
    var onClose: () -> Void = {}

    /// 轮询间隔：壳版 `app.js` check 的 2200ms。
    private static let pollIntervalNs: UInt64 = 2_200_000_000
    /// 过期后自动换一张的等待：壳版 600ms。
    private static let rekeyDelayNs: UInt64 = 600_000_000
    /// 登录成功后关弹窗的等待：壳版 1200ms。
    private static let successCloseDelayNs: UInt64 = 1_200_000_000
    /// 连续过期超过该次数就停手（壳版 `expired > 3`）。
    private static let maxExpiredRetries = 3
    /// 连续请求失败超过该次数就停手（网络抖动只静默重试，不立刻报错）。
    private static let maxConsecutiveFailures = 3

    private enum Phase {
        /// 正在 `refresh` 确认是否已登录。
        case checking
        /// 正在取 key / create，还没拿到二维码图。
        case loading
        /// 已登录：只显示已登录态 + 退出登录，不跑扫码流程。
        case loggedIn
        /// 二维码已出，等待扫码（statusText 为当前轮询文案）。
        case waiting
        /// 已扫码，等待手机上确认。
        case scanned
        /// 失败：statusText 为错误原因，留「换一张」重试。
        case failed
        /// 已确认 + refresh 回 true，1.2 秒后关弹窗。
        case succeeded
    }

    @State private var phase: Phase = .checking
    @State private var statusText: String = "正在确认登录状态…"
    @State private var qrKey: String = ""
    @State private var qrImage: UIImage?
    @State private var expiredCount = 0
    @State private var consecutiveFailures = 0
    /// 在飞的轮询任务；取消 / 成功 / 失败停手 / 视图消失时取消。
    @State private var pollTask: Task<Void, Never>?
    /// 取码代际：换一张 / 重新开始时 +1，旧轮询回来的结果直接丢弃。
    @State private var generation = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("波点音乐")
                .font(.title3.bold())
            Text("波点音乐仅支持二维码登录")
                .font(.footnote)
                .foregroundColor(.secondary)
            switch phase {
            case .checking, .loading:
                ProgressView()
                    .frame(width: 200, height: 200)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            case .loggedIn:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.green)
                Text("已登录波点音乐")
                    .font(.headline)
                Text("登录状态以服务端为准；退出后回到未登录。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("退出登录", role: .destructive) { logout() }
                    .buttonStyle(.bordered)
                Button("关闭") { onClose() }
                    .buttonStyle(.bordered)
            case .waiting, .scanned, .failed, .succeeded:
                qrImageView
                Text(statusText)
                    .font(.subheadline)
                    .foregroundColor(phase == .failed ? .red : .secondary)
                    .multilineTextAlignment(.center)
                if phase == .waiting || phase == .scanned {
                    Text("打开波点音乐 App 扫一扫")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 12) {
                    if phase == .waiting || phase == .scanned || phase == .failed {
                        Button("换一张") { startQr() }
                            .buttonStyle(.bordered)
                    }
                    if phase != .succeeded {
                        Button("取消") { cancelAndClose() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(24)
        .onAppear { checkLoginState() }
        .onDisappear { pollTask?.cancel() }
    }

    /// 二维码区：有图显示图（白底 + 圆角），没图显示占位。
    /// r23a 的 QrLoginView 落盘后替换这一块，输入不变。
    private var qrImageView: some View {
        Group {
            if let qrImage {
                Image(uiImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .background(Color.white)
                    .cornerRadius(12)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 200, height: 200)
                    .overlay(Text("二维码加载失败").font(.footnote).foregroundColor(.secondary))
            }
        }
    }

    // MARK: - 登录态确认与登出（refresh/logout 走 LoginStore，loggedIn 直读 status）

    /// 登录态以 `/api/bodian/status` 为准：顶层 `loggedIn`
    ///（KugouLoginView.status() 同款写法；call 回 nil 按未登录算）。
    private func statusLoggedIn() async -> Bool {
        guard let d = await NativeBridge.call(path: "/api/bodian/status") else { return false }
        return (d["loggedIn"] as? NSNumber)?.boolValue == true
    }

    /// 打开时先确认登录态：已登录就停在已登录页，未登录才开始扫码。
    private func checkLoginState() {
        phase = .checking
        statusText = "正在确认登录状态…"
        Task { @MainActor in
            await LoginStore.refresh(platform: "bodian")
            if await statusLoggedIn() {
                phase = .loggedIn
            } else {
                startQr()
            }
        }
    }

    /// 登出：走 `LoginStore.logout`，再直读 status 一次确认回到未登录；
    /// 仍登录则报错留在页内，不假装已退出。
    private func logout() {
        statusText = "正在退出登录…"
        Task { @MainActor in
            await LoginStore.logout(platform: "bodian")
            let stillLoggedIn = await statusLoggedIn()
            if stillLoggedIn {
                phase = .loggedIn
                statusText = "退出登录失败，请重试"
            } else {
                // 回到未登录：停在可重新扫码的入口，不自动取码。
                phase = .failed
                statusText = "已退出登录，点「换一张」重新扫码登录"
                qrImage = nil
                qrKey = ""
            }
        }
    }

    // MARK: - 取码

    /// 开始一轮扫码：停掉旧轮询 → key → create → 出图 → 起轮询。
    /// 波点 key 只回 key、没有 qrimg，create 是必经步骤，不可省略。
    private func startQr() {
        pollTask?.cancel()
        pollTask = nil
        generation += 1
        let gen = generation
        expiredCount = 0
        consecutiveFailures = 0
        qrImage = nil
        qrKey = ""
        phase = .loading
        statusText = "正在获取二维码…"
        Task { @MainActor in
            guard gen == generation else { return }
            guard let keyDict = await NativeBridge.call(path: "/api/bodian/login/qr/key"),
                  let key = keyDict["key"] as? String, !key.isEmpty else {
                guard gen == generation else { return }
                phase = .failed
                statusText = "拿不到二维码，请检查网络后点「换一张」重试"
                return
            }
            guard let createDict = await NativeBridge.call(
                path: "/api/bodian/login/qr/create", query: ["key": key]),
                  let qrimg = (createDict["qrimg"] as? String) ?? (createDict["imageUrl"] as? String),
                  let image = Self.imageFromDataURL(qrimg) else {
                guard gen == generation else { return }
                phase = .failed
                statusText = "二维码生成失败，请点「换一张」重试"
                return
            }
            guard gen == generation else { return }
            qrKey = key
            qrImage = image
            phase = .waiting
            statusText = "等待扫码"
            startPolling(key: key, gen: gen)
        }
    }

    // MARK: - 轮询

    /// 2.2 秒一轮；任务取消即停，绝不泄漏到视图消失后。
    private func startPolling(key: String, gen: Int) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollIntervalNs)
                if Task.isCancelled { return }
                guard gen == generation, key == qrKey else { return }
                await checkOnce(key: key, gen: gen)
                if Task.isCancelled { return }
            }
        }
    }

    /// 一轮 check：按 `Bodian.swift` loginQrCheck 的 code 语义映射。
    /// 波点没有 804 refused；未知 code 不编含义，有服务端文案就原样显示并继续轮询。
    private func checkOnce(key: String, gen: Int) async {
        guard gen == generation, key == qrKey else { return }
        guard let dict = await NativeBridge.call(
            path: "/api/bodian/login/qr/check", query: ["key": key]) else {
            // 请求本身失败：静默重试，连续 3 次才停手报错。
            consecutiveFailures += 1
            if consecutiveFailures >= Self.maxConsecutiveFailures {
                stopPolling()
                phase = .failed
                statusText = "网络异常，请检查网络后点「换一张」重试"
            }
            return
        }
        guard gen == generation, key == qrKey else { return }
        consecutiveFailures = 0
        let code = (dict["code"] as? NSNumber)?.intValue ?? -1
        let serverMessage = (dict["message"] as? String) ?? ""
        switch code {
        case 801: // waiting
            phase = .waiting
            statusText = serverMessage.isEmpty ? "等待扫码" : serverMessage
        case 802: // scanned（含上游 11027）
            phase = .scanned
            statusText = serverMessage.isEmpty ? "已扫码，请在手机上确认" : serverMessage
        case 803: // confirmed
            await finishConfirmed(gen: gen)
        case 800: // expired
            expiredCount += 1
            if expiredCount > Self.maxExpiredRetries {
                stopPolling()
                phase = .failed
                statusText = "二维码反复过期，稍后再试"
            } else {
                statusText = serverMessage.isEmpty ? "二维码已过期，换一张…" : serverMessage
                scheduleRekey(afterNs: Self.rekeyDelayNs, gen: gen)
            }
        default:
            // 未知 code：后端契约外的值，不编含义；有服务端文案就原样显示并继续轮询。
            if !serverMessage.isEmpty { statusText = serverMessage }
        }
    }

    /// 803 已确认：停轮询 → refresh + 直读 status 确认 loggedIn → 成功才关弹窗。
    private func finishConfirmed(gen: Int) async {
        stopPolling()
        phase = .succeeded
        statusText = "正在确认登录状态…"
        await LoginStore.refresh(platform: "bodian")
        let loggedIn = await statusLoggedIn()
        guard gen == generation else { return }
        if loggedIn {
            statusText = "登录成功"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.successCloseDelayNs)
                if generation == gen { onClose() }
            }
        } else {
            phase = .failed
            statusText = "已确认扫码，但登录状态校验失败，请点「换一张」重试"
        }
    }

    /// 过期后自动换一张：先停旧轮询，代际 +1 保证旧结果不回写。
    private func scheduleRekey(afterNs: UInt64, gen: Int) {
        stopPolling()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: afterNs)
            if generation == gen { startQr() }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 取消：停轮询，尽力而为调 cancel 让服务端删码，不阻塞关弹窗。
    private func cancelAndClose() {
        stopPolling()
        generation += 1
        let key = qrKey
        if !key.isEmpty {
            Task {
                _ = await NativeBridge.call(
                    path: "/api/bodian/login/qr/cancel", query: ["key": key])
            }
        }
        onClose()
    }

    /// `data:image/png;base64,…` → UIImage；不是 data URL 或解不出来回 nil。
    private static func imageFromDataURL(_ raw: String) -> UIImage? {
        let base64 = raw.contains(",") ? String(raw.split(separator: ",", maxSplits: 1).last ?? "") : raw
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let image = UIImage(data: data) else { return nil }
        return image
    }
}
