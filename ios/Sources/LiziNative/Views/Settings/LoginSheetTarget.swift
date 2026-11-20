import SwiftUI

/// 登录页打开目标（设置行共用；sheet 用 Identifiable）。
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
/// r26（用户 2026-11-20 22:39–22:40 决定）：首页 5 个来源 chips 全删、
/// 只留每日推荐，来源切换逻辑随 chips 一起删。本文件原来那套首页登录墙
/// （`LoginRequiredFeature` / `LoginPrompt` / `LoginGate` /
/// `.loginRequiredAlert`）只挂在来源 chips 与 rail 行上，调用点已全部删掉，
/// 这里一并删掉，不留死代码入口。登录流程本身不受影响：`LoginSheetView` /
/// `LoginStore` 仍由设置页账号行消费（`SettingsView` /
/// `AccountDetailView`），登录入口还在设置里。
/// 4 个删掉的来源（精选 / 我的喜欢 / 我收藏的歌单 / 电台）的新显示方法
/// 等图纸批了再接线，不在这里先占位置。
struct LoginSheetTarget: Identifiable {
    let platform: String
    var id: String { platform }
}
