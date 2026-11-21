import SwiftUI

/// Apple Music 登录（r23e 建，r29 task 1 加 Apple ID 登录 + 整首播放）。
///
/// 后端事实（AppleMusic.swift，不改）：
/// - GET /api/applemusic/status（或 login/status）：
///   loggedIn = 开发者 token 经 catalog 校验有效；vip = 订阅有效
///   （另需 user token）；tokenSource = pasted（用户粘贴的）/ web
///   （网页播放器 token 兜底）/ ""（两种都没有）。r33 起：无已贴 token
///   时先用网页 token 兜底校验，两种 token 都没有时 loggedIn=false，
///   但搜索/推荐/歌单/歌词走公开 API，播放是 30 秒试听。
/// - POST /api/applemusic/login/token，body 字段 token（可另带 userToken）：
///   只做 JWT 三段格式校验，真校验走 status 的 catalog 调用；空 token、
///   非 JWT 格式都回 loggedIn:false + error。
/// - 开发者 token 是 ES256 JWT（kid + iss，6 个月 exp），用 Apple Developer
///   门户创建的 MusicKit key（.p8）签发，要付费开发者账号。
/// - r29 task 1：Apple ID 登录（r31 起 AppleMusicAuth 只走 StoreKit：先预读
///   授权状态，已授权直接取 user token，未定才弹框，被拒直接提示）+ 整首播放
///   （AppleMusicPlayer：applicationMusicPlayer 按 store id 建队列）。登录且
///   订阅有效时 Apple Music 的歌播整首，否则仍是 30 秒试听。
/// - logout（/api/applemusic/logout）清掉开发者 token 和 user token；
///   本视图登出时还调 AppleMusicAuth.signOut() 清内存里的 user token。
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
    // r33：token 来源（后端 status 的 tokenSource：pasted / web / ""），
    // 决定上段文案与登出后的提示（网页 token 兜底时登出后 tokenValid 仍
    // 为 true，不能再报「登出后 token 仍有效，请重试」）。
    @State private var tokenSource = ""
    // r29 task 1：Apple ID 登录态（user token 在盘上即 true；订阅现验）。
    @State private var appleIDLoggedIn = false
    @State private var appleIDSubscribed = false
    @State private var appleIDBusy = false

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
                    } else if tokenSource == "web" {
                        // r33：没粘贴过自己的 token，当前是网页播放器 token
                        // 在兜底校验——不要写成「已保存开发者 token」，会让
                        // 用户以为自己存过一个 token。
                        Text("当前用网页播放器 token 校验（未粘贴自己的 token）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("已保存开发者 token（本机保存，完整值不显示）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(appleIDLoggedIn && appleIDSubscribed
                        ? "已登录 Apple ID 且订阅有效：Apple Music 的歌走原生播放器播整首。"
                        : "搜索走 Apple Music catalog；播放仍是 30 秒试听，整首播放需要 Apple ID 登录 + 有效订阅（见下）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("未配置开发者 token（匿名可用）")
                        .font(.caption)
                    Text("可搜索、看推荐/歌单、看歌词；播放是 30 秒试听。整首播放需要 Apple ID 登录 + 有效订阅（见下）。")
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

            // 中段：Apple ID 登录（r29 task 1；r33 起开发者 token 不再必须
            // 粘贴——没贴时 App 用网页播放器 token 兜底校验，粘贴区在下面
            // 原样保留）。
            VStack(alignment: .leading, spacing: 6) {
                Text("Apple ID 登录")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if appleIDLoggedIn {
                    Text("Apple ID 已登录")
                        .font(.caption)
                    Text(appleIDSubscribed ? "订阅有效，可整首播放" : "未验证到订阅（整首播放不可用）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("未登录（整首播放需要 Apple ID 登录 + 有效订阅）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("直接向系统请求 Apple Music 访问授权（StoreKit；MusicKit 路已停用，未签名 IPA 没有 MusicKit 能力）。授权被拒时直接提示，不会闪退。登录只在本机存 user token，不上传、不显示完整值。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !appleIDLoggedIn {
                    Button("用 Apple ID 登录") { Task { await signInWithAppleID() } }
                        .disabled(isBusy || appleIDBusy)
                        .buttonStyle(.borderedProminent)
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
                Text("开发者 token 是 ES256 JWT（kid + iss，6 个月有效期），用 Apple Developer 门户创建的 MusicKit key（.p8）签发，需要付费开发者账号。token 只存本机，不上传、不写日志；界面上最多显示前 4 位。没有自己的 token 也不用贴：订阅校验用公开的网页播放器 token，留空就行；自己的 token 是可选项，只有公开 token 失效/过期时才需要贴；公开 API 照样能用。")
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
        .task {
            await refreshStatus()
            await syncAppleIDState()
        }
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
            tokenSource = (d["tokenSource"] as? String) ?? ""
        }
    }

    // MARK: - Apple ID 登录（r29 task 1）

    private func signInWithAppleID() async {
        // r31：同步防重入 guard——检查与置位之间无 await，主线程上连续执行，
        // 两次快点时第二个 Task 进来看到的已是 busy=true，直接返回，不会
        // 各起一个登录 Task；按钮的 .disabled(isBusy || appleIDBusy) 是第二层。
        guard !appleIDBusy && !isBusy else { return }
        appleIDBusy = true; isBusy = true
        defer { appleIDBusy = false; isBusy = false }
        let result = await AppleMusicAuth.shared.signIn()
        await refreshStatus()
        await MainActor.run {
            appleIDLoggedIn = AppleMusicAuth.shared.isLoggedIn
            appleIDSubscribed = AppleMusicAuth.shared.subscriptionValid
            message = result.message
            messageIsError = !result.success
        }
    }

    /// 同步 Apple ID 登录态（打开页 / 刷新后调：user token 在盘上时
    /// 登录态即 true；订阅现验一次，300 秒缓存内不重复发请求）。
    private func syncAppleIDState() async {
        let loggedIn = AppleMusicAuth.shared.isLoggedIn
        let sub = loggedIn ? await AppleMusicAuth.shared.verifySubscription() : false
        await MainActor.run {
            appleIDLoggedIn = loggedIn
            appleIDSubscribed = sub
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
        // 先清 Apple ID 登录态（user token：UserDefaults + 内存缓存），
        // 再走后端登出（同时清开发者 token 和 user token）。
        AppleMusicAuth.shared.signOut()
        await LoginStore.logout(platform: "applemusic")
        await refreshStatus()
        await MainActor.run {
            appleIDLoggedIn = false
            appleIDSubscribed = false
            // r33：登出后 tokenValid 仍为 true 有两种可能——粘贴的 token
            // 没清掉（后端登出失败，要重试），或当前是网页 token 兜底
            // （粘贴的 token 已清，网页 token 不是用户存的、清不掉也不用清）。
            // 用 tokenSource 区分，不误报。
            if tokenSource == "pasted" {
                message = "登出后 token 仍有效，请重试"
                messageIsError = true
            } else if tokenValid {
                savedTokenPrefix = ""
                message = "已登出，Apple ID 登录态已清除；网页 token 仍用于匿名校验"
                messageIsError = false
            } else {
                savedTokenPrefix = ""
                message = "已登出，token 已清除"
                messageIsError = false
            }
        }
    }
}
