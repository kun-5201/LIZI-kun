import SwiftUI
import UIKit

/// QQ 二维码登录（r23c，原生 UI；后端不动，只调已有接口）。
///
/// 流程照 Moumusic `QQMusicQRCodeLoginSheet` + 后端 `QQ.swift`（L-1124）：
/// ptqrshow 取 qrsig → ptqrlogin 轮询（ptqrtoken=hash33(qrsig)）→ check_sig
/// 取 p_skey → POST graph.qq.com 换 code → musicu.fcg 换 Credential。
/// 上面每一步都在后端 `QQ.swift` 里（`ptQrCode` / `ptPoll` / `ptCompleteOAuth` /
/// `loginExchange`），完整 cookie jar、不做白名单、码交换必须 POST（GET 会回
/// 100012）。本 UI 只调三个后端接口，不碰任何 QQ 上游：
///   - GET  /api/qq/login/qr/key    → { code, key, qrimg, channel, retryAfterMs?, error? }
///   - GET  /api/qq/login/qr/check?key= → 801 等待 / 802 已扫码 / 803 成功 / 800 过期或失败
///   - GET  /api/qq/login/qr/cancel?key= （关弹窗/取消时尽力清掉服务端会话）
/// `qrimg` 是 `data:image/png;base64,…`，直接解 base64 成图，不走网络。
///
/// 状态映射（`checkQr` / `ptPollOnce` 的返回语义）：
///   - 801 = 等待扫码；802 = 已扫码待手机确认（换凭证中也回 802，别当卡死）；
///   - 803 = 成功（`loggedIn: true`，可能带 nickname/avatar）；
///   - 800 = 过期或失败：无 `error` 是码真过期；带 `error` 是换凭证失败，
///     文案原样显示；`error` 里含「网页登录」（如 100035 用户未登录）时停下来
///     指路网页登录，不再空转换码；带 `retryAfterMs` 是上游 15 秒冷却，
///     等够了再换码（r22 修的前端冷却规则），别 600ms 后去撞 429。
/// 连续过期超过 3 次停手，留手动「重新获取二维码」+ 网页登录兜底入口。
///
/// 成功后：`LoginStore.refresh(platform: "qq")`，再以 `/api/qq/status` 接口
/// 为准确认 `loggedIn` 才关弹窗（登录态以 status 接口为准，不以本地为准）。
/// 轮询可取消：关弹窗/点取消时停掉轮询 Task 并尽力调 cancel 接口。
/// Cookie / qrsig / musickey / uin 一律不打日志、不进诊断。
///
/// 依赖 r23a 底座（本文件不自建）：静态 `LoginStore.refresh(platform:)`（与
/// Kuwo/AppleMusic/NetEase 同级文件同款写法）、
/// `NativeBridge.call(path:query:method:)`（已存在）与带 body 的
/// `NativeBridge.call(path:query:method:body:)`（r23a；body 是 [String: Any]，
/// 本文件只在网页登录导入时用，见 `QQWebLoginSheet`）。频道固定 `qqmusic`（后端 ptlogin 路；
/// `qq` / `wechat` 频道服务端有，但原生扫码页只出 QQ 音乐 App 扫码）。
struct QQLoginView: View {
    private enum Phase: Equatable {
        case loading
        case waiting
        case scanned
        case cooling(seconds: Int)
        case expired
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var phase: Phase = .loading
    @State private var qrImage: UIImage?
    @State private var sessionKey = ""
    @State private var pollTask: Task<Void, Never>?
    @State private var loginGeneration = UUID()
    @State private var didStart = false
    @State private var consecutiveExpired = 0
    @State private var autoCoolingTries = 0
    @State private var imageErrorTries = 0
    @State private var showWebLogin = false
    /// 800 的 error 含「网页登录」（如 100035）时置真：不再自动换码，突出兜底入口。
    @State private var webLoginSuggested = false
    @State private var nickname = ""

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var pollInterval: TimeInterval { 2.5 } // Moumusic 同款

    /// 网页登录兜底按钮的 label（两支 buttonStyle 共用，见 body 注释）。
    private var webLoginLabel: some View {
        Label(webLoginSuggested ? "扫码被 QQ 拒绝了，用网页登录（兜底）" : "扫码遇到问题？用网页登录（兜底）",
              systemImage: "safari")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("使用 QQ 音乐 App 扫码登录")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 16)

                Text("登录只用于同步 QQ 音乐账号资料与歌单。Cookie 仅保存在本机，不会上传服务器。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)

                qrCard
                statusView

                if phase == .expired || isFailed {
                    Button("重新获取二维码") { startLogin() }
                        .buttonStyle(.borderedProminent)
                }

                // 兜底入口常驻；失败/过期或后端明确指路（100035）时更醒目。
                // 注意：.borderedProminent 与 .bordered 是两种不同具体类型，
                // 三元写进 .buttonStyle() 编译不过（r23 首推 run 44634984120
                // Archive 失败：ButtonStyle has no member），必须分两支写。
                if webLoginSuggested {
                    Button(action: { showWebLogin = true }) { webLoginLabel }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(action: { showWebLogin = true }) { webLoginLabel }
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.vertical, 12)
            .navigationTitle("QQ 音乐扫码登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancelAndDismiss() }
                }
            }
            .onAppear {
                guard !didStart else { return }
                didStart = true
                Task { @MainActor in
                    // 已登录就不用再扫：登录态以 status 接口为准。
                    if await QQLoginView.isLoggedInViaStatus() {
                        dismiss()
                        return
                    }
                    startLogin()
                }
            }
            .onDisappear { cancelPolling() }
            .onChange(of: scenePhase) { newPhase in
                // 后台回来时轮询 Task 若已被挂起取消、而码还活着，续轮同一张码；
                // 码已过期/失败的不续，等用户手动重取（复用已作废的 qrsig 只会
                // 拿到假过期，Moumusic 同款教训）。
                guard newPhase == .active, pollTask == nil,
                      phase == .waiting || phase == .scanned,
                      !sessionKey.isEmpty else { return }
                resumePolling()
            }
            .sheet(isPresented: $showWebLogin) {
                QQWebLoginSheet {
                    // 网页登录成功：本页也关掉（登录态已由 QQWebLoginSheet 内
                    // refresh + status 确认过）。
                    cancelPolling()
                    dismiss()
                }
            }
        }
    }

    private var qrCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white)
                .frame(width: 272, height: 272)
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            if let qrImage {
                Image(uiImage: qrImage)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 232, height: 232)
                    .opacity(phase == .expired ? 0.25 : 1)
            } else if isFailed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.orange)
                    Text("二维码暂时不可用")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
            if phase == .expired || phase == .scanned {
                VStack(spacing: 8) {
                    Image(systemName: phase == .expired ? "arrow.clockwise.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(phase == .expired ? .orange : .green)
                    Text(phase == .expired ? "二维码已失效" : "已扫码，请在手机上确认")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("QQ 音乐扫码登录二维码")
    }

    @ViewBuilder
    private var statusView: some View {
        switch phase {
        case .loading:
            Label("正在获取二维码…", systemImage: "arrow.triangle.2.circlepath")
        case .waiting:
            Label("打开 QQ 音乐 App 扫一扫", systemImage: "qrcode.viewfinder")
        case .scanned:
            Label("已扫码，等待手机确认…", systemImage: "iphone")
        case .cooling(let seconds):
            Label("二维码过期，\(seconds) 秒后自动换一张…", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .expired:
            Label("二维码已过期", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - 取码 + 轮询

    /// 取一张新码并开始轮询。`auto` 为真 = 800/冷却后的自动换码（不重置
    /// 连续过期计数与手动重试状态，只清当前码图）。
    private func startLogin(auto: Bool = false) {
        cancelPolling(cancelServerSession: false)
        let generation = UUID()
        loginGeneration = generation
        phase = .loading
        qrImage = nil
        webLoginSuggested = false
        if !auto {
            consecutiveExpired = 0
            autoCoolingTries = 0
            imageErrorTries = 0
        }
        pollTask = Task { @MainActor in
            defer {
                if generation == loginGeneration { pollTask = nil }
            }
            guard let keyDict = await NativeBridge.call(path: "/api/qq/login/qr/key",
                                                        query: ["channel": "qqmusic"]),
                  generation == loginGeneration else {
                if generation == loginGeneration {
                    phase = .failed("拿不到二维码，请检查网络后重试")
                }
                return
            }
            let code = (keyDict["code"] as? NSNumber)?.intValue ?? 0
            let key = (keyDict["key"] as? String) ?? ""
            let qrimg = (keyDict["qrimg"] as? String) ?? ""
            guard code == 200, !key.isEmpty, !qrimg.isEmpty,
                  let image = Self.image(from: qrimg) else {
                if generation != loginGeneration { return }
                // 后端 15 秒冷却：retryAfterMs 在就等够了再自动换码（r22 规则），
                // 最多再等 3 轮；没带就直接报原因 + 手动重试。
                let retryAfterMs = (keyDict["retryAfterMs"] as? NSNumber)?.intValue ?? 0
                let backendError = (keyDict["error"] as? String) ?? ""
                if auto, retryAfterMs > 0, autoCoolingTries < 3 {
                    autoCoolingTries += 1
                    phase = .cooling(seconds: (retryAfterMs + 999) / 1000)
                    try? await Task.sleep(nanoseconds: UInt64(retryAfterMs + 500) * 1_000_000)
                    guard !Task.isCancelled, generation == loginGeneration else { return }
                    startLogin(auto: true)
                    return
                }
                if code == 200, qrimg.isEmpty || Self.image(from: qrimg) == nil,
                   imageErrorTries < 2, !qrimg.isEmpty {
                    // 图坏了（base64 解不出来）：换一张码再试，最多 2 次。
                    imageErrorTries += 1
                    startLogin(auto: true)
                    return
                }
                let wait = retryAfterMs > 0 ? "（约 \((retryAfterMs + 999) / 1000) 秒后再试）" : ""
                phase = .failed((backendError.isEmpty ? "拿不到二维码" : backendError) + wait)
                return
            }
            sessionKey = key
            qrImage = image
            phase = .waiting
            autoCoolingTries = 0
            await pollLoop(generation: generation)
        }
    }

    /// 只续轮同一张还活着的码（后台回来、轮询 Task 丢了时用）；不重新取码。
    private func resumePolling() {
        let generation = UUID()
        loginGeneration = generation
        pollTask = Task { @MainActor in
            defer {
                if generation == loginGeneration { pollTask = nil }
            }
            await pollLoop(generation: generation)
        }
    }

    /// 2.5 秒一轮的 check 轮询。返回即停（成功 / 过期换码 / 失败停手 /
    /// 任务取消）；换码由 startLogin 接手，不在这里递归取码。
    private func pollLoop(generation: UUID) async {
        while !Task.isCancelled {
            guard generation == loginGeneration else { return }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            guard !Task.isCancelled, generation == loginGeneration else { return }
            guard let d = await NativeBridge.call(path: "/api/qq/login/qr/check",
                                                  query: ["key": sessionKey]),
                  generation == loginGeneration else {
                // 这一轮没回来（网络抖）：下一轮再试，不记失败。
                continue
            }
            let code = (d["code"] as? NSNumber)?.intValue ?? 0
            switch code {
            case 801:
                phase = .waiting
            case 802:
                // 已扫码待确认；换凭证中也回 802，不是卡死。
                consecutiveExpired = 0
                phase = .scanned
            case 803:
                nickname = (d["nickname"] as? String) ?? ""
                await confirmLogin(generation: generation)
                return
            case 800:
                let error = (d["error"] as? String) ?? ""
                if error.contains("网页登录") || error.contains("100035") {
                    // 换凭证走到 100035 这类服务端拦截：再换码也没用，停下来
                    // 指路网页登录，别空转（壳版 app.js 同款分支）。
                    webLoginSuggested = true
                    phase = .failed(error)
                    return
                }
                consecutiveExpired += 1
                if consecutiveExpired > 3 {
                    phase = .failed("二维码反复过期，稍后再点「登录」")
                    return
                }
                let retryAfterMs = (d["retryAfterMs"] as? NSNumber)?.intValue ?? 0
                if retryAfterMs > 0 {
                    // 冷却期内后端不给新码：等够了再换（r22），最多再等 3 轮。
                    if autoCoolingTries >= 3 {
                        phase = .failed("二维码过期，请稍后再试")
                        return
                    }
                    autoCoolingTries += 1
                    phase = .cooling(seconds: (retryAfterMs + 999) / 1000)
                    try? await Task.sleep(nanoseconds: UInt64(retryAfterMs + 500) * 1_000_000)
                    guard !Task.isCancelled, generation == loginGeneration else { return }
                    startLogin(auto: true)
                    return
                }
                phase = .expired
                // 无冷却：600ms 后自动换一张（壳版同款）；连续过期计数不清零。
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled, generation == loginGeneration else { return }
                startLogin(auto: true)
                return
            default:
                // 不认识的状态码：当等待处理，下一轮再试。
                phase = .waiting
            }
        }
    }

    /// 803 之后：刷新登录态，再以 status 接口为准确认 loggedIn 才关弹窗。
    /// 状态确认失败时先等 1.5 秒重试一次（画像接口偶尔比凭证慢半拍，
    /// Moumusic signInFromQR 同款：画像滞后不等于登录失败）。
    private func confirmLogin(generation: UUID) async {
        _ = await LoginStore.refresh(platform: "qq")
        guard generation == loginGeneration else { return }
        if await Self.isLoggedInViaStatus() {
            pollTask = nil
            dismiss()
            return
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled, generation == loginGeneration else { return }
        if await Self.isLoggedInViaStatus() {
            pollTask = nil
            dismiss()
            return
        }
        phase = .failed("登录已完成，但状态确认失败，请重新打开登录页查看")
    }

    /// 登录态以 status 接口为准：`/api/qq/status` 的 `loggedIn` 字段。
    static func isLoggedInViaStatus() async -> Bool {
        guard let d = await NativeBridge.call(path: "/api/qq/status") else { return false }
        return (d["loggedIn"] as? NSNumber)?.boolValue == true
    }

    /// `data:image/png;base64,…`（或 jpeg）→ UIImage；解不出来返回 nil。
    static func image(from qrimg: String) -> UIImage? {
        let b64 = qrimg.split(separator: ",", maxSplits: 1).last.map(String.init) ?? qrimg
        guard let data = Data(base64Encoded: b64), !data.isEmpty else { return nil }
        return UIImage(data: data)
    }

    // MARK: - 取消

    private func cancelPolling(cancelServerSession: Bool = true) {
        pollTask?.cancel()
        pollTask = nil
        loginGeneration = UUID()
        if cancelServerSession, !sessionKey.isEmpty {
            let key = sessionKey
            Task {
                _ = await NativeBridge.call(path: "/api/qq/login/qr/cancel", query: ["key": key])
            }
        }
    }

    private func cancelAndDismiss() {
        cancelPolling()
        dismiss()
    }
}
