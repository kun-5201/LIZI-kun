import SwiftUI
import UIKit

/// 酷狗扫码登录（r31-qqkg：改走本机 KugouAPI，不再调服务端桥接；
/// Folia 的 login_qr_key/create/check 流程废弃）。
///
/// 流程：qrCode 取码（二维码本地 CIFilter 生成）→ 每 2.5s 轮询 poll
/// （0 过期 / 1 等待 / 2·3 已扫 / 4 成功取 token + userid）→ 成功后
/// signInFromQR 写进钥匙串。连续错误容忍 8 次；过期不自动刷新，
/// 显示过期态等用户手动换一张。成功后以 SessionStore 的登录态为准
/// 关弹窗，不再问服务端 status 接口。
/// Cookie / token / userid 一律不打日志、不进诊断。
struct FoliaKugouLoginView: View {
    let onClose: () -> Void

    private enum Phase: Equatable {
        case loading
        case waiting
        case scanned
        case expired
        case failed(String)
    }

    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var sessionStore: KugouSessionStore

    @State private var phase: Phase = .loading
    @State private var qrImage: UIImage?
    @State private var qrKey = ""
    @State private var pollTask: Task<Void, Never>?
    @State private var loginGeneration = UUID()
    @State private var didStart = false
    @State private var showWebLogin = false
    /// 粘贴 Cookie 登录（浏览器里登好 www.kugou.com 后复制整段 Cookie，
    /// 要含 token 与 userid；要求 profile 通过才算登录成功）。
    @State private var cookieText = ""
    @State private var cookieBusy = false
    @State private var cookieMessage = ""

    init(onClose: @escaping () -> Void, sessionStore: KugouSessionStore = .shared) {
        self.onClose = onClose
        self.sessionStore = sessionStore
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var pollInterval: TimeInterval { 2.5 }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("使用酷狗音乐 App 扫码登录")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 16)

                Text("登录只用于同步酷狗音乐账号资料与歌单。Cookie 仅保存在本机，不会上传服务器。")
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

                Button(action: { showWebLogin = true }) {
                    Label("扫码遇到问题？用网页登录（兜底）", systemImage: "safari")
                }
                .buttonStyle(.bordered)

                Divider()
                cookieImportSection

                Button("取消") { cancelPolling(); onClose() }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 8)
            }
            .padding(.vertical, 8)
        }
        .onAppear {
            guard !didStart else { return }
            didStart = true
            guard !sessionStore.isLoggedIn else {
                onClose()
                return
            }
            startLogin()
        }
        .onDisappear { cancelPolling() }
        .onChange(of: scenePhase) { newPhase in
            // 切回前台时轮询 Task 若已被挂起取消、而码还活着，续轮同一张码；
            // 码已过期/失败的不续（复用已作废的 key 只会拿到假过期）。
            guard newPhase == .active, !sessionStore.isLoggedIn,
                  !qrKey.isEmpty, pollTask == nil || phase == .expired || isFailed else { return }
            startLogin(reusingCode: true)
        }
        .onChange(of: sessionStore.isLoggedIn) { loggedIn in
            guard loggedIn else { return }
            pollTask?.cancel()
            pollTask = nil
            onClose()
        }
        .sheet(isPresented: $showWebLogin) {
            KugouWebLoginSheet {
                cancelPolling()
                onClose()
            }
        }
    }

    /// 粘贴 Cookie 登录：浏览器里登好 www.kugou.com 后从开发者工具 →
    /// Application → Cookies 复制整段 Cookie（要含 token 与 userid）贴
    /// 进来；只贴裸 token 也认，userid 由画像补。成功后同样关弹窗；
    /// Cookie 只进钥匙串，成功就清掉输入框。
    private var cookieImportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("或粘贴 Cookie 登录")
                .font(.subheadline.weight(.semibold))
            Text("在浏览器打开 www.kugou.com 登录后，复制整段 Cookie 贴进来（要含 token 与 userid）。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $cookieText)
                    .frame(height: 64)
                    .font(.footnote.monospaced())
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                if cookieText.isEmpty {
                    Text("token=…; userid=…;（或整段 Cookie）")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 12) {
                Button(cookieBusy ? "导入中…" : "导入登录") { Task { await importCookie() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(cookieBusy || cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let paste = UIPasteboard.general.string, !paste.isEmpty {
                    Button("粘贴") { cookieText = paste }
                        .buttonStyle(.bordered)
                        .disabled(cookieBusy)
                }
            }
            if !cookieMessage.isEmpty {
                Text(cookieMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
    }

    private func importCookie() async {
        let raw = cookieText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            cookieMessage = "先把 Cookie 粘进来"
            return
        }
        if let problem = KugouAPI.cookieProblem(raw) {
            cookieMessage = problem
            return
        }
        cookieBusy = true
        defer { cookieBusy = false }
        do {
            try await sessionStore.signIn(cookie: raw)
            cookieText = ""
            cancelPolling()
            onClose()
        } catch {
            cookieMessage = error.localizedDescription
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
        .accessibilityLabel("酷狗音乐扫码登录二维码")
    }

    @ViewBuilder
    private var statusView: some View {
        switch phase {
        case .loading:
            Label("正在获取二维码…", systemImage: "arrow.triangle.2.circlepath")
        case .waiting:
            Label("打开酷狗音乐 App 扫一扫", systemImage: "qrcode.viewfinder")
        case .scanned:
            Label("已扫码，等待手机确认…", systemImage: "iphone")
        case .expired:
            Label("二维码已过期", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - 取码 + 轮询

    private func startLogin(reusingCode: Bool = false) {
        guard !sessionStore.isLoggedIn else {
            onClose()
            return
        }
        pollTask?.cancel()
        let generation = UUID()
        loginGeneration = generation
        phase = .loading
        if !reusingCode {
            qrImage = nil
            qrKey = ""
        }
        pollTask = Task { @MainActor in
            defer {
                if generation == loginGeneration { pollTask = nil }
            }
            do {
                let activeKey: String
                if reusingCode, !qrKey.isEmpty {
                    guard generation == loginGeneration else { return }
                    activeKey = qrKey
                    phase = .waiting
                } else {
                    let payload = try await KugouAPI.shared.qrCode()
                    guard generation == loginGeneration else { return }
                    activeKey = payload.key
                    qrKey = payload.key
                    guard let image = UIImage(data: payload.imageData) else {
                        throw KugouAPI.APIError.qrCodeUnavailable
                    }
                    qrImage = image
                    phase = .waiting
                }
                var errors = 0
                while !Task.isCancelled {
                    guard generation == loginGeneration else { return }
                    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    do {
                        let status = try await KugouAPI.shared.poll(key: activeKey)
                        guard generation == loginGeneration else { return }
                        switch status {
                        case .waiting:
                            phase = .waiting
                        case .scanned:
                            phase = .scanned
                        case .expired:
                            // 过期不自动刷新：显示过期态，等用户手动换一张。
                            qrKey = ""
                            pollTask = nil
                            phase = .expired
                            return
                        case .success(_, _, let sessionCookie):
                            try await sessionStore.signInFromQR(cookie: sessionCookie)
                            guard generation == loginGeneration else { return }
                            pollTask = nil
                            onClose()
                            return
                        }
                        errors = 0
                    } catch {
                        errors += 1
                        if errors >= 8 { throw error }
                    }
                }
            } catch {
                if !Task.isCancelled, generation == loginGeneration {
                    pollTask = nil
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - 取消

    private func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
        loginGeneration = UUID()
    }
}
