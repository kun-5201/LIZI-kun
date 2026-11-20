import SwiftUI

/// 账号详情（r23f）：设置页 → 平台账号行（已登录）点进来。
///
/// 显示：平台 logo + 名字 + 限制说明、昵称、头像、VIP 状态；底部
/// 「退出登录」按钮 → 二次确认 → `LoginStore.logout(platform:)` → 关页，
/// 关页后设置行立即变回「未登录」。
///
/// 数据全取自 r23a 共享底座 `LoginStore`（`Views/Login/`，只消费、不实现，
/// 接口约定见 `LoginSheetTarget.swift` 文件头的「r23a 接口约定」）：
/// 昵称取不到时写「未获取到昵称」、头像取不到时不显示头像、VIP 状态
/// 未返回时显示「非 VIP」——一律不编。
/// 未登录的行不会进这里（设置行未登录时直接弹登录页）；这里仍留一条
/// 防御分支：万一进来时已是未登录态，显示未登录 + 「去登录」按钮。
struct AccountDetailTarget: Identifiable {
    let platform: String
    var id: String { platform }
}

struct AccountDetailView: View {
    let platform: String

    @ObservedObject private var loginStore = LoginStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showLogoutConfirm = false
    @State private var loginTarget: LoginSheetTarget?
    /// r31：头像加载超时标记——旧写法是两闭包 `AsyncImage`（成功才有图，
    /// 失败也一直显示 `ProgressView`），头像 URL 死链/挂起时转圈永不停
    /// （用户 2026-11-21 05:59 报的 QQ 头像一直转圈）。现在按 phase 分流：
    /// 成功显示图、失败显示占位人像、加载中才转圈；10 秒还没回来也切占位，
    /// 不无限等（已加载成功的不受超时影响，见 `avatarLoaded`）。
    @State private var avatarTimedOut = false
    @State private var avatarLoaded = false

    private var platformName: String {
        SettingsStore.platformNames[platform] ?? LiziPlatforms.all.first(where: { $0.id == platform })?.name ?? platform
    }

    private var platformLimit: String {
        SettingsStore.platformLimits[platform] ?? ""
    }

    private var platformInfo: LiziPlatforms.Info? {
        LiziPlatforms.all.first(where: { $0.id == platform })
    }

    /// 登录态以 LoginStore 为准（与设置行同源：r23a 约定 LoginStore
    /// 与 SettingsStore.platformAccounts() 读同一份会话，不得各说各话）。
    private var loggedIn: Bool { loginStore.isLoggedIn(platform: platform) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                detailCard
                if loggedIn {
                    logoutButton
                } else {
                    loginButton
                }
                Text("退出登录只清掉该平台在本 App 里的登录会话，不删歌单、不删本地星标、不影响正在播的歌。")
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(LiziTokens.paper)
        .navigationTitle(platformName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loginStore.refresh() }
        .alert("退出登录", isPresented: $showLogoutConfirm) {
            Button("退出登录", role: .destructive) {
                loginStore.logout(platform: platform)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要退出\(platformName)的登录吗？退出后「我喜欢的歌单」「我收藏的歌单」等需要登录的内容将无法查看。")
        }
        .sheet(item: $loginTarget) { target in
            LoginSheetView(platform: target.platform)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let info = platformInfo {
                PlatformIconView(platform: info, selected: false, size: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(platformName)
                    .font(.liziDisplay(size: LiziTokens.size20))
                    .foregroundColor(LiziTokens.ink)
                if !platformLimit.isEmpty {
                    Text(platformLimit)
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink3)
                }
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LiziTokens.paper2)
        .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius14))
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            detailRow(label: "登录状态", value: loggedIn ? "已登录" : "未登录")
            Divider()
            detailRow(label: "昵称",
                      value: loggedIn
                        ? (loginStore.displayName(platform: platform) ?? "未获取到昵称")
                        : "未登录")
            Divider()
            HStack {
                Text("头像")
                    .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                    .foregroundColor(LiziTokens.ink)
                Spacer()
                if let url = loginStore.avatarURL(platform: platform), !avatarTimedOut {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                                .onAppear { avatarLoaded = true }
                        case .failure:
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 48))
                                .foregroundColor(LiziTokens.ink3)
                        case .empty:
                            ProgressView()
                        @unknown default:
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 48))
                                .foregroundColor(LiziTokens.ink3)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                    .task {
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        if !avatarLoaded { avatarTimedOut = true }
                    }
                } else {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(LiziTokens.ink3)
                }
            }
            Divider()
            detailRow(label: "VIP 状态",
                      value: loggedIn
                        ? (loginStore.isVip(platform: platform) ? "VIP" : "非 VIP")
                        : "未登录")
            if loggedIn {
                Text("VIP 状态来自登录时平台返回的信息，未返回时显示为非 VIP。")
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LiziTokens.paper2)
        .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius14))
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                .foregroundColor(LiziTokens.ink)
            Spacer()
            Text(value)
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink2)
                .lineLimit(1)
        }
    }

    private var logoutButton: some View {
        Button(action: { showLogoutConfirm = true }) {
            Text("退出登录")
                .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                .foregroundColor(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(LiziTokens.paper2)
                .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("退出\(platformName)登录")
    }

    private var loginButton: some View {
        Button(action: { loginTarget = LoginSheetTarget(platform: platform) }) {
            Text("去登录")
                .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                .foregroundColor(LiziTokens.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(LiziTokens.paper2)
                .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("去登录\(platformName)")
    }
}
