import SwiftUI

/// 全功能模式登录提示（r23f）：需要登录的功能被点到时，未登录就弹提示，
/// 不直接闪退、不静默失败；提示写清是哪个平台、要登录才能用，并给
/// 「去登录」按钮直达该平台登录页。
///
/// r23a 接口约定（本文件只消费、不实现；`Views/Login/` 归 r23a–r23e）：
/// - `LoginStore.shared`：`@MainActor final class LoginStore: ObservableObject`。
/// - `.isLoggedIn(platform: String) -> Bool`——与
///   `SettingsStore.platformAccounts()` 同源（SessionStore.hasMusicU /
///   各平台 sidecarAuth / Apple Music token），两边不得各说各话。
/// - `.displayName(platform: String) -> String?`——已登录昵称，取不到为 nil。
/// - `.avatarURL(platform: String) -> URL?`——已登录头像，取不到为 nil。
/// - `.isVip(platform: String) -> Bool`——平台返回的 VIP 状态。
/// - `.refresh()`——重读各平台会话；登录/登出/刷新后必须发布变化
///   （`@Published`），设置页靠它重绘账号行。
/// - `.logout(platform: String)`——清掉该平台会话；必须发布变化。
/// - `LoginSheetView(platform: String): View`——该平台的登录流程
///   （r23b–r23e 按平台填流程）；未登录行点开的就是它。
///
/// 判定表只认原生已有的「需要登录」判定点（端点逐条注明出处），不新发明登录墙：
/// - liked（我喜欢的歌单）：netease / qq / qishui / bodian 调各平台自己的
///   用户喜欢接口（`RailsBridge.railLiked`：网易 specialType==5 歌单、
///   QQ dirid 201、汽水 type==1 歌单、波点 liked_songs）；kuwo /
///   applemusic 是本地星标兜底，不用登录 → 不设墙。
/// - playlists（我收藏的歌单）：netease / qq / qishui / bodian / kugou 调
///   各平台用户歌单接口（`RailsBridge.railMyPlaylists`）；kuwo 没有用户歌单
///   接口、applemusic 是公开热门歌单兜底 → 不设墙。
/// - cloudDrive（我的云盘）：只有网易有个人云盘取链口
///   （`NativeBridge` 云盘腿，未登录上游回 301）；原生暂无云盘入口，
///   判定先备好，入口落地时接线，不先占 UI。
/// - radio（电台）：原生 7 平台电台接口全是公开/目录类调用
///   （`RailsBridge.railRadio`，无一处有登录守卫；波点私人 FM 也是
///   无守卫直调），不设墙——若真机证明某电台入口确需登录，由平台工人
///   确认后往表里加一行，不由本文件猜。
/// - featured（精选）/ 每日推荐 / 公开内容：永远不设墙。
/// - 切台（`HomeViewModel.selectPlatform`）：绝不查登录（r22f 五步原样，
///   一个字不动）；点没登录的平台图标直接看公开内容（r14 已定）。
///
/// 接线（即插即用，调用方只需两行；r23f 不改 HomeView，见交回报告）：
/// ```swift
/// @State private var loginPrompt: LoginPrompt?
/// @State private var loginTarget: LoginSheetTarget?
/// // 点入口时：
/// if let p = LoginGate.prompt(forRail: kind, platform: viewModel.selectedPlatform) {
///     loginPrompt = p
/// } else {
///     viewModel.openRail(kind) // 或 viewModel.selectSource(source)
/// }
/// // 视图上挂：
/// .loginRequiredAlert(prompt: $loginPrompt, loginTarget: $loginTarget)
/// .sheet(item: $loginTarget) { LoginSheetView(platform: $0.platform) }
/// ```
/// 调用点：首页 rail 行「展开」/卡片（`HomeView` 的 `onExpand`）、
/// 来源 chips 切到 liked / playlists / radio（`SourceChipsView` 的
/// `selectSource`）；云盘入口落地时再接 `.cloudDrive`。

/// 需要登录提示的功能（只有这四种；featured / 每日推荐不在其中）。
enum LoginRequiredFeature {
    case liked        // 我喜欢的歌单
    case playlists    // 我收藏的歌单
    case cloudDrive   // 我的云盘
    case radio        // 电台（判定表目前为空：原生电台接口无登录守卫，不设墙）
}

/// 登录提示（alert 用；「去登录」直达该平台登录页）。
struct LoginPrompt: Identifiable {
    let id = UUID()
    let platform: String
    let feature: LoginRequiredFeature
    var platformName: String {
        SettingsStore.platformNames[platform]
            ?? LiziPlatforms.all.first(where: { $0.id == platform })?.name ?? platform
    }
    var featureTitle: String { LoginGate.featureTitle(feature, platform: platform) }
    var title: String { "需要登录" }
    var message: String {
        "「\(featureTitle)」是\(platformName)的个人内容，需要登录\(platformName)后才能用。"
    }
}

/// 登录页打开目标（设置行 / 登录提示共用；sheet 用 Identifiable）。
struct LoginSheetTarget: Identifiable {
    let platform: String
    var id: String { platform }
}

/// 登录墙判定（纯表 + 登录态读数；不碰播放、不碰切台）。
enum LoginGate {

    /// 该功能在哪些平台上需要登录（其余平台不设墙，见文件头判定表）。
    static func gatedPlatforms(for feature: LoginRequiredFeature) -> Set<String> {
        switch feature {
        case .liked:
            return ["netease", "qq", "qishui", "bodian"]
        case .playlists:
            return ["netease", "qq", "qishui", "bodian", "kugou"]
        case .cloudDrive:
            return ["netease"]
        case .radio:
            return []
        }
    }

    /// 功能在提示里的展示名（喜欢按平台取真名，与 rail 行标题同一份
    /// 事实来源 `RailKind.likedTitle(for:)`）。
    static func featureTitle(_ feature: LoginRequiredFeature, platform: String) -> String {
        switch feature {
        case .liked: return RailKind.likedTitle(for: platform)
        case .playlists: return "我收藏的歌单"
        case .cloudDrive: return "我的云盘"
        case .radio: return "电台"
        }
    }

    /// 该平台点该功能时是否要弹登录提示：功能在判定表里、且当前平台
    /// 未登录 → 返回提示；否则返回 nil（调用方直接走原流程）。
    @MainActor
    static func prompt(for feature: LoginRequiredFeature, platform: String) -> LoginPrompt? {
        guard gatedPlatforms(for: feature).contains(platform) else { return nil }
        guard !LoginStore.shared.isLoggedIn(platform: platform) else { return nil }
        return LoginPrompt(platform: platform, feature: feature)
    }

    /// rail 行的便捷入口：featured（精选）永远不设墙 → nil；
    /// liked / playlists / radio 按各自判定表走。
    @MainActor
    static func prompt(forRail kind: RailKind, platform: String) -> LoginPrompt? {
        switch kind {
        case .liked: return prompt(for: .liked, platform: platform)
        case .playlists: return prompt(for: .playlists, platform: platform)
        case .radio: return prompt(for: .radio, platform: platform)
        case .featured: return nil
        }
    }
}

extension View {
    /// 登录提示 alert：标题「需要登录」+ 平台与功能写清的文案；
    /// 「去登录」把目标平台交给调用方的登录 sheet，「取消」只关提示。
    /// 调用方须另挂 `.sheet(item: $loginTarget) { LoginSheetView(platform: $0.platform) }`。
    func loginRequiredAlert(prompt: Binding<LoginPrompt?>,
                            loginTarget: Binding<LoginSheetTarget?>) -> some View {
        alert(item: prompt) { p in
            Alert(
                title: Text(p.title),
                message: Text(p.message),
                primaryButton: .default(Text("去登录")) {
                    loginTarget.wrappedValue = LoginSheetTarget(platform: p.platform)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }
}
