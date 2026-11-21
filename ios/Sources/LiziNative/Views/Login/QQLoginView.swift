import SwiftUI
import UIKit

/// QQ 二维码登录（r31-qqkg：改走本机 QQMusicAPI，不再调服务端桥接）。
///
/// 流程（ptlogin 网页扫码）：qrCode 取码 → 每 2.5s 轮询 poll（66 等待 /
/// 67 已扫 / 65·68 过期 / 0 成功走完凭证交换）→ 成功后 signInFromQR
/// 写进钥匙串。连续错误容忍 8 次；过期自动刷新一次，第二次才显示过期态；
/// 取码重试 3 次（间隔 700ms）。成功后以 SessionStore 的登录态为准关弹窗，
/// 不再问服务端 status 接口。
/// Cookie / qrsig / musickey / uin 一律不打日志、不进诊断。
struct QQLoginView: View {
    private enum Phase: Equatable {
        case loading
        case waiting
        case scanned
        case expired
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var sessionStore: QQMusicSessionStore

    init(sessionStore: QQMusicSessionStore = .shared) {
        self.sessionStore = sessionStore
    }

    @State private var phase: Phase = .loading
    @State private var qrImage: UIImage?
    @State private var qrsig: String?
    @State private var pollTask: Task<Void, Never>?
    @State private var loginGeneration = UUID()
    @State private var didStart = false
    @State private var didAutoRefreshExpiredCode = false
    @State private var showWebLogin = false
    @State private var webLoginSuggested = false
    /// 粘贴 Cookie 登录（与网页登录同一个校验规则，先验再存钥匙串）。
    @State private var cookieText = ""
    @State private var cookieBusy = false
    @State private var cookieMessage = ""

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var pollInterval: TimeInterval { 2.5 } // Moumusic 同款

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

                if webLoginSuggested {
                    Button(action: { showWebLogin = true }) { webLoginLabel }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(action: { showWebLogin = true }) { webLoginLabel }
                        .buttonStyle(.bordered)
                }

                cookieImportSection
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
                guard !sessionStore.isLoggedIn else {
                    dismiss()
                    return
                }
                startLogin()
            }
            .onDisappear { cancelPolling() }
            .onChange(of: scenePhase) { newPhase in
                // 切回前台时轮询 Task 若已被挂起取消、而码还活着，续轮同一张码；
                // 码已过期/失败的不续（复用已作废的 qrsig 只会拿到假过期）。
                guard newPhase == .active, !sessionStore.isLoggedIn,
                      qrsig != nil, pollTask == nil || phase == .expired || isFailed else { return }
                startLogin(reusingCode: true)
            }
            .onChange(of: sessionStore.isLoggedIn) { loggedIn in
                guard loggedIn else { return }
                pollTask?.cancel()
                pollTask = nil
                dismiss()
            }
            .sheet(isPresented: $showWebLogin) {
                QQWebLoginSheet {
                    cancelPolling()
                    dismiss()
                }
            }
        }
    }

    /// 粘贴 Cookie 登录：浏览器里登好 y.qq.com 后从开发者工具 →
    /// Application → Cookies 复制整段 Cookie（要含 uin 与 qqmusic_key /
    /// p_skey）贴进来；要求 profile 通过才算登录成功。Cookie 只进钥匙串，
    /// 不打日志、不留存在输入框里（成功就清掉）。
    private var cookieImportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("或粘贴 Cookie 登录")
                .font(.subheadline.weight(.semibold))
            Text("在浏览器打开 y.qq.com 登录后，复制整段 Cookie 贴进来（要含 uin 与 qqmusic_key / p_skey）。")
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
                    Text("uin=…; qqmusic_key=…;（或整段 Cookie）")
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
        if let problem = QQMusicAPI.cookieProblem(raw) {
            cookieMessage = problem
            return
        }
        cookieBusy = true
        defer { cookieBusy = false }
        do {
            try await QQMusicSessionStore.shared.signIn(cookie: raw)
            cookieText = ""
            cancelPolling()
            dismiss()
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
        case .expired:
            Label("二维码已过期", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - 取码 + 轮询

    private func startLogin(reusingCode: Bool = false, automaticRefresh: Bool = false) {
        guard !sessionStore.isLoggedIn else {
            dismiss()
            return
        }
        pollTask?.cancel()
        let generation = UUID()
        loginGeneration = generation
        phase = .loading
        if !reusingCode {
            qrImage = nil
            qrsig = nil
            if !automaticRefresh {
                didAutoRefreshExpiredCode = false
            }
        }
        pollTask = Task { @MainActor in
            defer {
                if generation == loginGeneration { pollTask = nil }
            }
            do {
                let activeQRSig: String
                if reusingCode, let qrsig {
                    guard generation == loginGeneration else { return }
                    activeQRSig = qrsig
                    phase = .waiting
                } else {
                    let payload = try await requestQRCodeWithRetry()
                    guard generation == loginGeneration else { return }
                    activeQRSig = payload.qrsig
                    qrsig = payload.qrsig
                    guard let image = UIImage(data: payload.imageData) else {
                        throw QQMusicAPI.APIError.qrCodeUnavailable
                    }
                    qrImage = image
                    phase = .waiting
                }
                var errors = 0
                while !Task.isCancelled {
                    guard generation == loginGeneration else { return }
                    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                    do {
                        let status = try await QQMusicAPI.shared.poll(qrsig: activeQRSig)
                        guard generation == loginGeneration else { return }
                        switch status {
                        case .waiting:
                            phase = .waiting
                        case .scanned:
                            phase = .scanned
                        case .expired:
                            // 绝不让 scenePhase 复用一张已作废的码。
                            qrsig = nil
                            pollTask = nil
                            if !didAutoRefreshExpiredCode {
                                didAutoRefreshExpiredCode = true
                                phase = .loading
                                try? await Task.sleep(nanoseconds: 350_000_000)
                                guard !Task.isCancelled,
                                      generation == loginGeneration,
                                      !sessionStore.isLoggedIn else { return }
                                startLogin(automaticRefresh: true)
                            } else {
                                phase = .expired
                            }
                            return
                        case .success(let cookie):
                            try await QQMusicSessionStore.shared.signInFromQR(cookie: cookie)
                            guard generation == loginGeneration else { return }
                            pollTask = nil
                            dismiss()
                            return
                        }
                        errors = 0
                    } catch {
                        // 100035 这类服务端拦截：停下来指路网页登录，不再空转换码。
                        if case QQMusicAPI.APIError.oauthNeedsWebLogin = error {
                            webLoginSuggested = true
                            phase = .failed(error.localizedDescription)
                            return
                        }
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

    /// 取码重试 3 次（间隔 700ms）。
    private func requestQRCodeWithRetry() async throws -> QQMusicAPI.QRCodePayload {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await QQMusicAPI.shared.qrCode()
            } catch {
                lastError = error
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: 700_000_000)
                }
            }
        }
        throw lastError ?? QQMusicAPI.APIError.qrCodeUnavailable
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
