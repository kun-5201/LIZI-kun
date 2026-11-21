import SwiftUI

/// QQ 音乐登录入口页（r31-qqkg：本机直连版）。
///
/// 三路并列：扫码登录（主按钮）/ 网页·手机号登录 / 粘贴 Cookie +
/// 「验证并登录」；Cookie 只存本机钥匙串。下方是当前状态区
/// （昵称 · 会员/非会员 + 绿勾），退出登录要二次确认。
struct QQMusicLoginSheet: View {
    @ObservedObject private var store: QQMusicSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var cookie = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var showQRCodeLogin = false
    @State private var showWebLogin = false
    @State private var showSignOutConfirm = false

    init(store: QQMusicSessionStore = .shared) {
        self.store = store
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("使用 QQ 音乐 Cookie 登录", systemImage: "person.badge.key.fill")
                            .font(.headline)
                        Text("扫码登录后，QQ 音乐歌曲可在官方账号模式下请求账号音源。Cookie 仅保存在本机钥匙串。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { showQRCodeLogin = true } label: {
                            Label("QQ 音乐扫码登录", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        Button { showWebLogin = true } label: {
                            Label("网页 / 手机号登录", systemImage: "safari")
                        }
                        .buttonStyle(.bordered)
                        TextEditor(text: $cookie)
                            .frame(minHeight: 110)
                            .font(.system(.footnote, design: .monospaced))
                            .privacySensitive()
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    Button { signIn() } label: {
                        HStack {
                            Spacer()
                            if isSigningIn { ProgressView().controlSize(.small); Text("正在验证…") }
                            else { Text("验证并登录").fontWeight(.semibold) }
                            Spacer()
                        }
                    }
                    .disabled(isSigningIn || cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minHeight: 44)
                }
                if store.isLoggedIn {
                    Section("当前状态") {
                        Label(statusText, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Button("退出登录", role: .destructive) { showSignOutConfirm = true }
                    }
                }
            }
            .navigationTitle("QQ 音乐登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .alert("登录失败", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "请稍后重试") }
            .confirmationDialog("退出 QQ 音乐登录？", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    Task { await store.signOut() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("退出后需要重新扫码或粘贴 Cookie 才能同步 QQ 音乐账号资料与歌单。")
            }
            .onChange(of: store.isLoggedIn) { loggedIn in
                guard loggedIn else { return }
                dismiss()
            }
            .sheet(isPresented: $showQRCodeLogin) {
                QQLoginView()
            }
            .sheet(isPresented: $showWebLogin) {
                QQWebLoginSheet { dismiss() }
                    .presentationDetents([.large])
            }
        }
    }

    private var statusText: String {
        let name = store.profileName ?? "QQ 音乐已登录"
        switch store.isVIP {
        case true: return "\(name) · \(store.isSuperVIP ? "SVIP" : "会员")"
        case false: return "\(name) · 非会员"
        case nil: return name
        }
    }

    private func signIn() {
        isSigningIn = true
        Task {
            do {
                try await store.signIn(cookie: cookie)
                cookie = ""
                isSigningIn = false
                dismiss()
            } catch {
                isSigningIn = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
