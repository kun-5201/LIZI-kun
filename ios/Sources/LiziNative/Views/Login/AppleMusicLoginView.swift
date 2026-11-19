import SwiftUI

/// Apple Music 登录（r23e）：公开 API 匿名可用 + 开发者 token 粘贴入口。
///
/// 后端事实（AppleMusic.swift，不改）：
/// - 没有其他登录方式：token 入口是唯一登录方式。本视图只有 token
///   粘贴框 + 「保存 token」。
/// - GET /api/applemusic/status（或 login/status）：
///   loggedIn = 开发者 token 经 catalog 校验有效；vip = 订阅有效
///   （另需 user token）；无 token 时 loggedIn=false，但搜索/推荐/歌单/
///   歌词走公开 API，播放是 30 秒试听。
/// - POST /api/applemusic/login/token，body 字段 token（可另带 userToken）：
///   只做 JWT 三段格式校验，真校验走 status 的 catalog 调用；空 token、
///   非 JWT 格式都回 loggedIn:false + error。
/// - 开发者 token 是 ES256 JWT（kid + iss，6 个月 exp），用 Apple Developer
///   门户创建的 MusicKit key（.p8）签发，要付费开发者账号。
/// - 即使 token 有效，songUrl 回的仍是 30 秒试听（previewUrl）：
///   整首播放要原生 MusicKit 播放器，本轮未接——本视图绝不承诺整首播放。
/// - logout（/api/applemusic/logout）清掉开发者 token 和 user token。
///
/// 接口契约（r23a 共享底座提供，本文件只调用、不自建）：
/// - NativeBridge.call(path:method:body:)：带 JSON body 的重载，
///   body: [String: Any]。
/// - LoginStore.refresh(platform:)：保存 token 后刷新共享登录态。
/// - LoginStore.logout(platform:)：登出（调后端 /api/applemusic/logout）。
/// 登录态以 status 接口为准。token 只存后端 UserDefaults；UI 上绝不回显
/// 完整值，最多显示刚粘贴那一次的前 4 位 + 省略号。
struct AppleMusicLoginView: View {
    @State private var tokenText = ""
    @State private var savedTokenPrefix = ""
    @State private var message = ""
    @State private var messageIsError = false
    @State private var isBusy = false
    @State private var tokenValid = false
    @State private var subscriptionValid = false
    @State private var statusError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Music")
                .font(.headline)

            // 上段：当前状态（以 status 接口为准）
            VStack(alignment: .leading, spacing: 6) {
                Text("当前状态")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if tokenValid {
                    Text("开发者 token 有效（catalog 校验通过）")
                        .font(.caption)
                    Text(subscriptionValid ? "订阅有效" : "未验证到订阅")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !savedTokenPrefix.isEmpty {
                        Text("已保存 token（\(savedTokenPrefix)…）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("已保存开发者 token（本机保存，完整值不显示）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("搜索走 Apple Music catalog；播放仍是 30 秒试听，整首播放需要原生 MusicKit 播放器（本轮未接）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("未配置开发者 token（匿名可用）")
                        .font(.caption)
                    Text("可搜索、看推荐/歌单、看歌词；播放是 30 秒试听。整首播放需要 Apple Developer 账号的 MusicKit 开发者 token，现在没有。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !statusError.isEmpty {
                        Text(statusError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                if tokenValid {
                    Button("登出（清除已存 token）") { Task { await logout() } }
                        .disabled(isBusy)
                        .buttonStyle(.bordered)
                }
            }

            Divider()

            // 下段：token 粘贴入口
            VStack(alignment: .leading, spacing: 6) {
                Text("开发者 token")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                SecureField("粘贴 MusicKit 开发者 token（JWT，三段）", text: $tokenText)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)
                Text("开发者 token 是 ES256 JWT（kid + iss，6 个月有效期），用 Apple Developer 门户创建的 MusicKit key（.p8）签发，需要付费开发者账号。token 只存本机，不上传、不写日志；界面上最多显示前 4 位。没有 token 也可以用：留空，公开 API 照样能用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("保存 token") { Task { await saveToken() } }
                    .disabled(isBusy || tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(messageIsError ? .red : .green)
            }
        }
        .padding()
        .task { await refreshStatus() }
    }

    // MARK: - 状态（以 status 接口为准）

    private func refreshStatus() async {
        guard let d = await NativeBridge.call(path: "/api/applemusic/status") else {
            await MainActor.run {
                message = NativeBridge.searchErrorText
                messageIsError = true
            }
            return
        }
        await MainActor.run {
            tokenValid = (d["loggedIn"] as? Bool) ?? false
            subscriptionValid = (d["vip"] as? Bool) ?? false
            statusError = (d["error"] as? String) ?? ""
        }
    }

    // MARK: - 保存 token

    private func saveToken() async {
        let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            await MainActor.run {
                message = "开发者 token 是空的"
                messageIsError = true
            }
            return
        }
        // 与后端 loginToken 同规则：JWT 三段。格式不对先明说，不发请求。
        guard token.split(separator: ".").count == 3 else {
            await MainActor.run {
                message = "开发者 token 不是 JWT 格式（应为三段 base64，用 MusicKit 私钥签发）"
                messageIsError = true
            }
            return
        }
        await MainActor.run { isBusy = true }
        defer { Task { @MainActor in isBusy = false } }
        guard let d = await NativeBridge.call(
            path: "/api/applemusic/login/token", method: "POST", body: ["token": token]
        ) else {
            await MainActor.run {
                message = NativeBridge.searchErrorText
                messageIsError = true
            }
            return
        }
        if (d["loggedIn"] as? Bool) == true {
            let prefix = String(token.prefix(4))
            await LoginStore.refresh(platform: "applemusic")
            await MainActor.run {
                tokenText = ""
                savedTokenPrefix = prefix
                message = "开发者 token 已保存并验证有效"
                messageIsError = false
            }
            await refreshStatus()
        } else {
            await MainActor.run {
                message = (d["error"] as? String) ?? "保存失败，请检查 token 是否有效。"
                messageIsError = true
            }
        }
    }

    // MARK: - 登出（清掉已存 token）

    private func logout() async {
        await MainActor.run { isBusy = true }
        defer { Task { @MainActor in isBusy = false } }
        await LoginStore.logout(platform: "applemusic")
        await refreshStatus()
        await MainActor.run {
            if tokenValid {
                message = "登出后 token 仍有效，请重试"
                messageIsError = true
            } else {
                savedTokenPrefix = ""
                message = "已登出，token 已清除"
                messageIsError = false
            }
        }
    }
}
