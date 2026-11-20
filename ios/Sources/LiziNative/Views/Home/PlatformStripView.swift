import SwiftUI
import UIKit

/// 平台条：模板 v2（~/workspace/lizi-home-template-portrait.png /
/// lizi-home-template-landscape.png）+ 壳版铺色面板顶部的 `.hall-plat__bar`。
///
/// - 模板 v2 头行（一行三列，左→右）：当前来源标题（「每日推荐」，
///   24pt 粗体——模板量：4 字占 92pt；壳版 `.pstrip__name` 是 13px，
///   模板把面板标题放大了，按已确认的模板做；要改回 13pt 改一行。
///   文本取 `Source.title(for:)`：每日推荐 / 精选 / 喜欢（按平台取真名）
///   / 我收藏的歌单 / 电台——壳版里左列根段默认就是「每日推荐」
///   （app.js `paintPlatBar` 注释 + `.pstrip__name.is-src`），
///   模板与壳版根段 precedent 一致）→ 7 个平台图标（22pt、间距 5，
///   模板量：每块 22×22、间距 5；壳版 `.pstrip__i` 是 32px，
///   模板把图标收小了才放得下大标题 + 搜索）→ 搜索
///   （壳版 `.pstrip__search` 在长条右列；模板右端也有放大镜）。
/// - 图标 22pt、圆角 28%（≈6pt），选中描 2pt 墨色圈（壳版
///   `0 0 0 2px currentColor`；原生浅色面板上 currentColor 就是墨色）。
///   图标下不再挂名字（名字只在左列出现一次——现在是来源标题）。
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
///   （`LoginStore` / `LoginSheetView`），登录态由 HomeView 的登录提示
///   与设置页账号行消费，不由平台条图标表达。
/// - 图标渲染：真 logo（`Assets.xcassets` 里的 `Platform<Name>` imageset，
///   由 `public/assets/platforms/*.svg` 渲染成 48/96/144 PNG）。图标本身自带圆角
///   底色与字形，这里只按 22pt 框定、描选中圈；不联网拉图。品牌色 +
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

    /// 当前来源标题实测宽（PreferenceKey 回写；初值 144 = 最长标题
    /// 「我喜欢的音乐」6 字 × 24pt 预估）。
    @State private var nameWidth: CGFloat = 144

    /// 当前来源标题（模板 v2 头行左列；喜欢按平台取真名）。
    /// r22j 原来是当前平台名；模板 v2 左列是「每日推荐」（来源标题），
    /// 平台名改由选中圈 + 面板底色表示（见 HomeView 文件头）。
    private var sourceTitle: String {
        viewModel.selectedSource.title(for: viewModel.selectedPlatform)
    }

    /// r22j 平台管理：平台条只显示设置 → 平台管理勾选的平台（顺序不变，
    /// 仍是 `LiziPlatforms.all` 的顺序）；不勾选的不显示。没存 = 全部
    /// （`visiblePlatforms` 读不到键时回落全部 7 个）。
    private var visiblePlatforms: [LiziPlatforms.Info] {
        LiziPlatforms.all.filter { viewModel.visiblePlatforms.contains($0.id) }
    }

    /// 图标自然宽 = 可见数 × 22 + (可见数 − 1) × 5（模板 v2：每块 22×22、
    /// 间距 5；全部勾选时 7×22 + 6×5 = 184；取消勾选后随可见数变小）。
    private var iconsNaturalWidth: CGFloat {
        let n = CGFloat(max(visiblePlatforms.count, 1))
        return n * 22 + (n - 1) * 5
    }

    /// 图标缩放（壳版 fitPlatBar：只收图标，下限 0.55；标题、搜索不动）。
    /// 可用宽 = 总宽 − 标题宽 − 搜索钮 32 − 三处间距 12×3。
    private func barScale(totalWidth: CGFloat) -> CGFloat {
        let avail = totalWidth - nameWidth - 32 - 36
        guard avail > 0 else { return 0.55 }
        return max(0.55, min(1, avail / iconsNaturalWidth))
    }

    var body: some View {
        GeometryReader { geo in
            let scale = barScale(totalWidth: geo.size.width)
            HStack(spacing: 12) {
                Text(sourceTitle)
                    .font(.liziBody(size: 24, weight: .bold))
                    .foregroundColor(LiziTokens.ink)
                    .lineLimit(1)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: PlatBarNameWidthKey.self,
                                value: proxy.size.width
                            )
                        }
                    )
                HStack(spacing: 5) {
                    ForEach(visiblePlatforms, id: \.id) { platform in
                        Button(action: { viewModel.selectPlatform(platform.id, playbackStore: playback) }) {
                            PlatformIconView(platform: platform, selected: platform.id == viewModel.selectedPlatform, size: 22)
                        }
                        .accessibilityLabel("切换到\(platform.name)")
                    }
                }
                .scaleEffect(scale, anchor: .leading)
                .frame(width: iconsNaturalWidth * scale, height: 22, alignment: .leading)
                Spacer()
                // 模板 v2 + 壳版 `.pstrip__search`：长条右端放大镜，点进搜索页。
                Button(action: { nav.show(.search) }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(LiziTokens.ink2)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("搜索")
            }
            .frame(height: 42) // 壳版 `.hall-plat__bar` 高 42px；图标 22 垂直居中。
        }
        .frame(height: 42)
        .onPreferenceChange(PlatBarNameWidthKey.self) { nameWidth = $0 }
    }
}

private struct PlatBarNameWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 144
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 单个平台图标：真 logo 图（默认 32pt，圆角 28% ≈ 9pt 框定；设置页平台管理
/// 行用 26pt、圆角 7pt，照抄壳版 `.pm__logo` 26×26 radius 7）；选中态描
/// 2pt 墨色圈。logo 资源缺失时（资源没进包）回落旧的品牌色 + 首字瓷砖，
/// 不空白。
struct PlatformIconView: View {
    let platform: LiziPlatforms.Info
    let selected: Bool
    /// 图标边长（默认 32；平台条传 22，设置行传 26）。
    var size: CGFloat = 32

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
                .stroke(LiziTokens.ink, lineWidth: selected ? 2 : 0)
        )
    }
}
