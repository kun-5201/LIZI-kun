import SwiftUI
import UIKit

/// 平台条：模板 v2（~/workspace/lizi-home-template-portrait.png /
/// lizi-home-template-landscape.png）+ 壳版铺色面板顶部的 `.hall-plat__bar`。
///
/// - 面板头行（一行三列，左→右）：标题（当前来源名，默认「每日推荐」，
///   r30：19pt 粗体——逐帧规格（verification/shell-video-39s-home-3d.md）
///   与 v4 图（~/workspace/lizi-home-daily-v4.png）量：约 36px ≈ 19pt；
///   旧模板 v2 的 24pt 已作废）→ 7 个平台图标（r30：26pt、间距 5，
///   逐帧规格每枚约 48px ≈ 26pt；旧 28pt 已作废）→ 搜索
///   （r30：字形 19pt，逐帧规格约 35px ≈ 19pt；旧 18pt 已作废）。
///   r30：标题是来源切换入口——点标题弹来源小菜单（壳版
///   `#hall-src-menu` 思路，浮层由 HomeView 挂），标题文案跟当前来源走
///   （`viewModel.sourceTitle`，默认「每日推荐」）；标题后挂一枚小
///   chevron.down（9pt）表示可点开菜单。图标点按仍是切平台，
///   与来源切换无关（平台 ≠ 来源：平台是 7 家音源，来源是面板里的
///   6 个栏目）。
/// - 图标 26pt、圆角 28%（≈7pt），选中描 2pt 圈（壳版
///   `0 0 0 2px currentColor`；浅场 currentColor 就是墨色）。
///   r28 tone-aware：面板跟专辑取色后深场时标题、搜索图标、选中圈
///   都改白色（`isDark` 由调用方 HomeView 的 panelTone 传入），
///   浅场保持墨色；图标 26pt、条高 48pt 不动。
///   图标下不再挂名字（名字只在左列出现一次——现在是「每日推荐」标题）。
/// - 不横向滚动：图标太宽时只收图标（壳版 `fitPlatBar`，缩放下限 0.55，
///   标题不动）；标题宽用 PreferenceKey 实测，初值按最长标题
///   「我喜欢的音乐」估 144，避免第一帧按 0 算出满宽溢出。
/// - 顺序与壳版 hall/accounts.js 注册表一致（7 个）：
///   网易云 / QQ 音乐 / 酷狗 / 汽水 / 波点 / 酷我音乐 / Apple Music。
///   酷狗走 Folia 实现：登录是 Folia 移植（`FoliaKugouLoginView`，
///   `kugouProvider.ts` auth），取链 / 每日推荐走 `/api/kugou/*`
///   Folia 接口（`NativeBridge` 里 kugou 分支）。
/// - 切台只换数据、不拆音频（见 HomeViewModel.selectPlatform 注释）。
///   未登录图标壳版是 opacity .45（`.pstrip__i.is-off`）；原生首页
///   平台条图标仍一律全亮度、不按登录态明暗区分（r22j 驱动 3h 的原决定，
///   现状仍如此）。登录本身已不是 P4：登录底座 r23 已落地
///   （`LoginStore` / `LoginSheetView`），登录态由设置页账号行消费，
///   不由平台条图标表达。
/// - 图标渲染：真 logo（`Assets.xcassets` 里的 `Platform<Name>` imageset，
///   由 `public/assets/platforms/*.svg` 渲染成 48/96/144 PNG）。图标本身自带圆角
///   底色与字形，这里只按 28pt 框定、描选中圈；不联网拉图。品牌色 +
///   首字 monogram 瓷砖是资源缺失时的兜底（字段在 `LiziPlatforms.Info`）。
/// - 封面只用真数据：图标是平台 logo 资源，跑马带封面是各平台每日推荐
///   的真封面；模板图里的示例封面不进包、不当数据。
struct PlatformStripView: View {
    @ObservedObject var viewModel: HomeViewModel
    /// App 根部经 .environmentObject 下发的 PlaybackStore（LiziNativeApp）；
    /// 切台时传给 selectPlatform 做 advanceGeneration()（取消在飞取链）。
    /// 本文件是 selectPlatform 的唯一调用点，所以接线只放这里。
    @EnvironmentObject private var playback: PlaybackStore
    /// 右端搜索钮用（模板 v2 + 壳版 `.pstrip__search`）。
    @EnvironmentObject private var nav: AppNavigation

    /// 标题实测宽（PreferenceKey 回写；初值 100 = 「每日推荐」4 字 × 19pt
    /// 预估 + chevron；最长来源「用户创建的歌单」约 133pt，实测后自纠）。
    @State private var nameWidth: CGFloat = 100

    /// r28 tone-aware：调用方（HomeView）按在播专辑取色 `panelTone.isDark`
    /// 传入——深场时标题、搜索图标、选中圈都用白色，浅场保持墨色。
    /// 默认 false（浅场），与改前行为一致。
    var isDark: Bool = false

    /// r30：点标题弹来源小菜单（调用方 HomeView 挂浮层；不传则标题不可点，
    /// 只显示当前来源名）。本条全仓只在 HomeView 用，调用方必传。
    var onSourceMenuTap: (() -> Void)? = nil

    /// 面板标题：当前来源名（`viewModel.sourceTitle`，默认「每日推荐」；
    /// r26「固定每日推荐」已作废，r30 起跟来源切换走）。

    /// r22j 平台管理：平台条只显示设置 → 平台管理勾选的平台（顺序不变，
    /// 仍是 `LiziPlatforms.all` 的顺序）；不勾选的不显示。没存 = 全部
    /// （`visiblePlatforms` 读不到键时回落全部 7 个）。
    private var visiblePlatforms: [LiziPlatforms.Info] {
        LiziPlatforms.all.filter { viewModel.visiblePlatforms.contains($0.id) }
    }

    /// 图标自然宽 = 可见数 × 26 + (可见数 − 1) × 5（r30：每块 26×26、
    /// 间距 5；全部勾选时 7×26 + 6×5 = 212；取消勾选后随可见数变小）。
    private var iconsNaturalWidth: CGFloat {
        let n = CGFloat(max(visiblePlatforms.count, 1))
        return n * 26 + (n - 1) * 5
    }

    /// 图标缩放（壳版 fitPlatBar：只收图标，下限 0.55；标题、搜索不动）。
    /// 可用宽 = 总宽 − 标题宽 − 搜索钮 28 − 三处间距 8×3。
    private func barScale(totalWidth: CGFloat) -> CGFloat {
        let avail = totalWidth - nameWidth - 28 - 24
        guard avail > 0 else { return 0.55 }
        return max(0.55, min(1, avail / iconsNaturalWidth))
    }

    var body: some View {
        GeometryReader { geo in
            let scale = barScale(totalWidth: geo.size.width)
            HStack(spacing: 8) {
                // r30：标题是来源切换入口（点弹小菜单）；标题后小 chevron
                // 表示可点开。标题宽用 PreferenceKey 实测（见 Text 内）。
                Button(action: { onSourceMenuTap?() }) {
                    HStack(spacing: 4) {
                        Text(viewModel.sourceTitle)
                            .font(.liziBody(size: 19, weight: .bold))
                            .foregroundColor(isDark ? .white : LiziTokens.ink)
                            .lineLimit(1)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: PlatBarNameWidthKey.self,
                                        value: proxy.size.width
                                    )
                                }
                            )
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(isDark ? .white.opacity(0.8) : LiziTokens.ink2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(onSourceMenuTap == nil)
                .accessibilityLabel("来源：\(viewModel.sourceTitle)，点按切换来源")
                HStack(spacing: 5) {
                    ForEach(visiblePlatforms, id: \.id) { platform in
                        Button(action: { viewModel.selectPlatform(platform.id, playbackStore: playback) }) {
                            PlatformIconView(platform: platform, selected: platform.id == viewModel.selectedPlatform, size: 26, ringColor: isDark ? .white : LiziTokens.ink)
                        }
                        .accessibilityLabel("切换到\(platform.name)")
                    }
                }
                .scaleEffect(scale, anchor: .leading)
                .frame(width: iconsNaturalWidth * scale, height: 26, alignment: .leading)
                Spacer()
                // 模板 v2 + 壳版 `.pstrip__search`：长条右端放大镜，点进搜索页。
                // r30：字形 19pt（逐帧规格约 35px ≈ 19pt），触摸框 28×28。
                Button(action: { nav.show(.search) }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(isDark ? .white : LiziTokens.ink2)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("搜索")
            }
            .frame(height: 48) // 壳版 `.hall-plat__bar` 原高 42px；原生图标放大到 26 后条高 48，图标垂直居中，上下各留 11pt。
        }
        .frame(height: 48)
        .onPreferenceChange(PlatBarNameWidthKey.self) { nameWidth = $0 }
    }
}

private struct PlatBarNameWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 100
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 单个平台图标：真 logo 图（默认 32pt，圆角 28% ≈ 9pt 框定；设置页平台管理
/// 行用 26pt、圆角 7pt，照抄壳版 `.pm__logo` 26×26 radius 7）；选中态描
/// 2pt 圈（默认墨色；平台条深场时传白色，见 `ringColor`）。logo 资源缺失时（资源没进包）回落旧的品牌色 + 首字瓷砖，
/// 不空白。
struct PlatformIconView: View {
    let platform: LiziPlatforms.Info
    let selected: Bool
    /// 图标边长（默认 32；平台条传 26，设置行传 26）。
    var size: CGFloat = 32
    /// 选中圈颜色（默认墨色；r28 tone-aware：平台条深场时传白色）。
    /// 设置页 / 账号详情不传，保持墨色不变。
    var ringColor: Color = LiziTokens.ink

    var body: some View {
        ZStack {
            if UIImage(named: platform.assetName) != nil {
                Image(platform.assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
            } else {
                RoundedRectangle(cornerRadius: size * 0.28)
                    .fill(Color(hex: platform.brandHex))
                    .frame(width: size, height: size)
                Text(platform.monogram)
                    .font(.liziDisplay(size: size * 13 / 32))
                    .foregroundColor(platform.onBrandLight ? LiziTokens.ink : .white)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.28)
                .stroke(ringColor, lineWidth: selected ? 2 : 0)
        )
    }
}
