import SwiftUI
import UIKit

/// 网易云二维码登录（r23b，原生 UI；后端不动，只调已有接口）。
///
/// 后端事实（`NetEase.swift`，不改）：
///   - GET  /api/netease/login/qr/key    → { code: 200, key, qrimg, channel }
///     `qrimg` 是本地画的 `data:image/png;base64,…`（`neteaseQrKey`，
///     内容是 `https://music.163.com/login?codekey=<key>`），直接解
///     base64 成图，不走网络。
///   - GET  /api/netease/login/qr/check?key= → { code, message, … }
///     801 等待扫码 / 802 已扫码待确认 / 803 成功 / 800 过期。
///     803 时后端当场抓 cookie 并 harvest（`neteaseQrCheck`），响应里
///     直接带 `loggedIn` 与 `profile`。
///   - GET  /api/session → { loggedIn, profile? }，profile 形如
///     { userId, nickname, avatar, vipType }（`profileOf`）。
///     登录态以这个接口为准，不以 803 响应里的字段为准。
///   - 登出：`LoginStore.logout(platform: "netease")`，后端是通用
///     `/api/logout`（`handleApi` 路由表 `"logout"` → weapi `/logout`，
///     成功失败都本地 `session.clear()`）。注意没有
///     `/api/netease/logout` 这条路（`handleNetease` 没这个 case，
///     调了会 404），底座里网易登出必须走 `/api/logout`。
///
/// 后端缺口（本文件不改后端，记在这里交回）：
///   - 没有 `/api/netease/login/qr/create` 路由（壳版边车有
///     `/login/qr/create?qrimg=true`，原生 `handleNetease` 只有
///     key / check 两个 case）。本文件 qrimg 直接取 key 响应的，
///     不调 create；要补路由由后端轮次定。
///
/// 状态映射（`neteaseQrCheck` + 壳版 `public/app.js` pollQr 同款语义）：
///   - 801 = 等待扫码；802 = 已扫码待手机确认；803 = 成功；
///   - 800 = 过期：自动换一张，最多连续 3 次（壳版 `qrExpires > 3` 停手），
///     再过期就停下来留手动「重新获取二维码」；
///   - 其它 code / 空响应 / 传输失败：单次抖动继续等，连续 3 次才停手报错。
/// 成功后：`LoginStore.refresh(platform: "netease")`，再以 `/api/session`
/// 确认 `loggedIn` 才进已登录态（登录态以 status 接口为准）；确认不到就
/// 明说「已授权但登录态没写进来」，不静默、不自动关弹窗。
/// 轮询可取消：关弹窗/点取消时停掉轮询 Task（网易没有 cancel 接口，
/// 只停本地轮询）。Cookie / MUSIC_U 一律不打日志、不进诊断。
///
/// 依赖 r23a 底座（本文件不自建）：`LoginStore.refresh(platform:)`、
/// `LoginStore.logout(platform:)`（静态调用，与 Kuwo/AppleMusic 同款；
/// 注意 QQLoginView 用的是 `LoginStore.shared.refresh`，底座定稿时
/// 两处写法要统一成一种）、`NativeBridge.call(path:query:method:)`（已存在）。
struct NetEaseLoginView: View {
    private enum Phase: Equatable {
        case loading
        case waiting
        case scanned
        case expired
        case failed(String)
        case loggedIn
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
    @State private var consecutiveFails = 0
    @State private var imageErrorTries = 0
    /// 800 后自动换的新码：留着过期原因，别被等扫码文案盖掉（壳版 Q1b 同款）。
    @State private var expiredNotice = ""
    @State private var nickname = ""
    @State private var avatarURL: URL?
    @State private var avatarBroken = false
    @State private var logoutBusy = false

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var pollInterval: TimeInterval { 2 } // 壳版 pollQr 同款 2 秒

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("使用网易云音乐 App 扫码登录")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 16)

                Text("登录只用于同步网易云账号资料与歌单。Cookie 仅保存在本机，不会上传服务器。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)

                if phase == .loggedIn {
                    accountCard
                } else {
                    qrCard
                    statusView

                    if phase == .expired || isFailed {
                        Button("重新获取二维码") { startLogin() }
                            .buttonStyle(.borderedProminent)
                    }
                }

                if phase == .loggedIn {
                    HStack(spacing: 12) {
                        Button("退出登录") {
                            Task { @MainActor in await logout() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(logoutBusy)
                        Button("完成") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.vertical, 12)
            .navigationTitle("网易云音乐扫码登录")
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
                    // 已登录就直接进已登录态（显示昵称/头像 + 退出），不用再扫。
                    // 登录态以 status 接口为准。
                    let s = await Self.status()
                    if s.loggedIn {
                        nickname = s.nickname
                        avatarURL = URL(string: s.avatar)
                        avatarBroken = false
                        phase = .loggedIn
                        return
                    }
                    startLogin()
                }
            }
            .onDisappear { cancelPolling() }
            .onChange(of: scenePhase) { newPhase in
                // 后台回来时轮询 Task 若已被挂起取消、而码还活着，续轮同一张码；
                // 码已过期/失败的不续，等用户手动重取。
                guard newPhase == .active, pollTask == nil,
                      phase == .waiting || phase == .scanned,
                      !sessionKey.isEmpty else { return }
                resumePolling()
            }
        }
    }

    /// 已登录态：昵称 + 头像（status 接口 profile 里取，没有就不显示，不编）。
    private var accountCard: some View {
        VStack(spacing: 12) {
            if let avatarURL, !avatarBroken {
                AsyncImage(url: avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView()
                }
                .frame(width: 72, height: 72)
                .clipShape(Circle())
                .onAppear { avatarBroken = false }
            }
            Text(nickname.isEmpty ? "已登录" : "已登录：\(nickname)")
                .font(.headline)
            Text("网易云音乐")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
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
        .accessibilityLabel("网易云音乐扫码登录二维码")
    }

    @ViewBuilder
    private var statusView: some View {
        switch phase {
        case .loading:
            Label("正在获取二维码…", systemImage: "arrow.triangle.2.circlepath")
        case .waiting:
            // 800 后刚换的新码在等扫码时别盖掉过期提示。
            Label(expiredNotice.isEmpty ? "打开网易云音乐 App 扫一扫" : expiredNotice,
                  systemImage: "qrcode.viewfinder")
        case .scanned:
            Label("已扫码，等待手机确认…", systemImage: "iphone")
        case .expired:
            Label("二维码已过期，正在自动换一张…", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .loggedIn:
            EmptyView()
        }
    }

    // MARK: - 取码 + 轮询

    /// 取一张新码并开始轮询。`auto` 为真 = 800 过期后的自动换码（不重置
    /// 连续过期计数，只清当前码图）。
    private func startLogin(auto: Bool = false) {
        cancelPolling()
        let generation = UUID()
        loginGeneration = generation
        phase = .loading
        qrImage = nil
        if !auto {
            consecutiveExpired = 0
            consecutiveFails = 0
            imageErrorTries = 0
            expiredNotice = ""
        }
        pollTask = Task { @MainActor in
            defer {
                if generation == loginGeneration { pollTask = nil }
            }
            guard let keyDict = await NativeBridge.call(path: "/api/netease/login/qr/key"),
                  generation == loginGeneration else {
                if generation == loginGeneration {
                    phase = .failed(NativeBridge.searchErrorText)
                }
                return
            }
            let code = (keyDict["code"] as? NSNumber)?.intValue ?? 0
            let key = (keyDict["key"] as? String) ?? ""
            // qrimg 在 key 响应里直接带（后端没有 login/qr/create 路由，见文件头）。
            let qrimg = (keyDict["qrimg"] as? String) ?? ""
            guard code == 200, !key.isEmpty, !qrimg.isEmpty,
                  let image = Self.image(from: qrimg) else {
                if generation != loginGeneration { return }
                if code == 200, !qrimg.isEmpty, imageErrorTries < 2 {
                    // 图坏了（base64 解不出来）：换一张码再试，最多 2 次。
                    imageErrorTries += 1
                    startLogin(auto: true)
                    return
                }
                let backendMessage = (keyDict["message"] as? String) ?? ""
                phase = .failed(backendMessage.isEmpty ? "拿不到二维码，请检查网络后重试" : backendMessage)
                return
            }
            sessionKey = key
            qrImage = image
            phase = .waiting
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

    /// 2 秒一轮的 check 轮询。返回即停（成功 / 过期换码 / 失败停手 /
    /// 任务取消）；换码由 startLogin 接手，不在这里递归取码。
    private func pollLoop(generation: UUID) async {
        while !Task.isCancelled {
            guard generation == loginGeneration else { return }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            guard !Task.isCancelled, generation == loginGeneration else { return }
            guard let d = await NativeBridge.call(path: "/api/netease/login/qr/check",
                                                  query: ["key": sessionKey]),
                  generation == loginGeneration else {
                // 这一轮没回来（网络抖）：记一次，连续 3 次才停手。
                consecutiveFails += 1
                if consecutiveFails >= 3 {
                    phase = .failed("网络一直不通，轮询已停止，点「重新获取二维码」再试")
                    return
                }
                continue
            }
            // code 可能是数字也可能是字符串 "803"，两种都认（壳版同款）。
            let code: Int
            if let n = d["code"] as? NSNumber { code = n.intValue }
            else if let s = d["code"] as? String { code = Int(s) ?? 0 }
            else { code = 0 }
            switch code {
            case 801:
                consecutiveFails = 0
                phase = .waiting
            case 802:
                // 已扫码待确认：这张码是活的，连续过期/失败计数清零。
                consecutiveExpired = 0
                consecutiveFails = 0
                expiredNotice = ""
                phase = .scanned
            case 803:
                consecutiveFails = 0
                await confirmLogin(generation: generation)
                return
            case 800:
                consecutiveExpired += 1
                if consecutiveExpired > 3 {
                    phase = .failed("二维码反复过期，稍后再点「登录」")
                    return
                }
                expiredNotice = "二维码过期，已换一张新码，请重新扫码"
                phase = .expired
                // 600ms 后自动换一张（壳版同款）；连续过期计数不清零。
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled, generation == loginGeneration else { return }
                startLogin(auto: true)
                return
            default:
                // 其它一切（500 / 风控 / 空 body…）都不能继续装作在等确认，
                // 但单次抖动不停：连续 3 次才停轮询。
                consecutiveFails += 1
                if consecutiveFails >= 3 {
                    let shown = (d["message"] as? String) ?? ""
                    phase = .failed("网易云返回了异常状态：\(code)" + (shown.isEmpty ? "" : "（\(shown)）") + "，点「重新获取二维码」再试")
                    return
                }
            }
        }
    }

    /// 803 之后：刷新登录态，再以 `/api/session` 为准确认 loggedIn 才进
    /// 已登录态。状态确认失败时等 1.5 秒重试一次（画像接口偶尔比凭证慢
    /// 半拍，QQLoginView 同款）；两次都确认不到就明说，不自动关弹窗。
    private func confirmLogin(generation: UUID) async {
        await LoginStore.refresh(platform: "netease")
        guard generation == loginGeneration else { return }
        if await enterLoggedInState() {
            pollTask = nil
            return
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled, generation == loginGeneration else { return }
        if await enterLoggedInState() {
            pollTask = nil
            return
        }
        phase = .failed("手机已授权，但登录态没写进来（803 已回、/api/session 未登录），点「重新获取二维码」再扫一次")
    }

    /// 以 status 接口为准读登录态；已登录就填昵称/头像进已登录态。
    /// 返回 true = 已登录且已进已登录态。
    private func enterLoggedInState() async -> Bool {
        let s = await Self.status()
        guard s.loggedIn else { return false }
        nickname = s.nickname
        avatarURL = URL(string: s.avatar)
        avatarBroken = false
        phase = .loggedIn
        return true
    }

    /// 登录态以 `/api/session` 为准：`loggedIn` + profile{nickname, avatar}。
    static func status() async -> (loggedIn: Bool, nickname: String, avatar: String) {
        guard let d = await NativeBridge.call(path: "/api/session") else {
            return (false, "", "")
        }
        let loggedIn = (d["loggedIn"] as? NSNumber)?.boolValue == true
        let profile = d["profile"] as? [String: Any] ?? [:]
        return (loggedIn,
                (profile["nickname"] as? String) ?? "",
                (profile["avatar"] as? String) ?? "")
    }

    // MARK: - 登出

    /// 登出走 `LoginStore.logout`（后端 `/api/logout`），再以 status 接口
    /// 为准确认已变回未登录；还登着就明说失败，不回扫码页。
    private func logout() async {
        logoutBusy = true
        await LoginStore.logout(platform: "netease")
        let s = await Self.status()
        logoutBusy = false
        if s.loggedIn {
            phase = .failed("退出失败，账号还是登录状态，请重试")
            return
        }
        nickname = ""
        avatarURL = nil
        avatarBroken = false
        startLogin()
        // startLogin(auto: false) 会清 expiredNotice，退出提示要写在它后面。
        expiredNotice = "已退出登录"
    }

    /// `data:image/png;base64,…`（或 jpeg）→ UIImage；解不出来返回 nil。
    static func image(from qrimg: String) -> UIImage? {
        let b64 = qrimg.split(separator: ",", maxSplits: 1).last.map(String.init) ?? qrimg
        guard let data = Data(base64Encoded: b64), !data.isEmpty else { return nil }
        return UIImage(data: data)
    }

    // MARK: - 取消

    private func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
        loginGeneration = UUID()
    }

    private func cancelAndDismiss() {
        cancelPolling()
        dismiss()
    }
}
