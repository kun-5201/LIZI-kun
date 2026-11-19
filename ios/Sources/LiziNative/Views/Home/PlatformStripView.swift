import SwiftUI
import UIKit

/// 平台条：7 家平台图标横排，点按切平台。
///
/// - 顺序与壳版 hall/accounts.js 注册表一致：
///   网易云 / QQ 音乐 / 酷狗 / 汽水 / 波点 / 酷我音乐 / Apple Music。
/// - 切台只换数据、不拆音频（不碰 PlaybackStore）；未登录点图标直接进该平台
///   公开内容（Folia 式全功能），登录提示只在用到登录功能时出现——
///   P1 先做到切台 + 拉公开内容（每日推荐），登录流程本身在 P4。
/// - 图标渲染：真 logo（`Assets.xcassets` 里的 `Platform<Name>` imageset，
///   由 `public/assets/platforms/*.svg` 渲染成 48/96/144 PNG；酷狗用自含
///   蓝底的 `kugou.svg`，不用纯白的 `kugou-mark.svg`）。图标本身自带圆角
///   底色与字形，这里只按 48pt 框定、描选中圈；不联网拉图。P1 的品牌色 +
///   首字 monogram 瓷砖已撤下（字段保留在 `LiziPlatforms.Info` 作兜底）。
struct PlatformStripView: View {
    @ObservedObject var viewModel: HomeViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(LiziPlatforms.all, id: \.id) { platform in
                    Button(action: { viewModel.selectPlatform(platform.id) }) {
                        VStack(spacing: 6) {
                            PlatformIconView(platform: platform, selected: platform.id == viewModel.selectedPlatform)
                            Text(platform.name)
                                .font(.liziBody(size: LiziTokens.size12, weight: .medium))
                                .foregroundColor(platform.id == viewModel.selectedPlatform ? LiziTokens.ink : LiziTokens.ink3)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityLabel("切换到\(platform.name)")
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// 单个平台图标：真 logo 图（48pt，圆角 14 框定）；选中态描网易云红圈。
/// logo 资源缺失时（资源没进包）回落旧的品牌色 + 首字瓷砖，不空白。
struct PlatformIconView: View {
    let platform: LiziPlatforms.Info
    let selected: Bool

    var body: some View {
        ZStack {
            if UIImage(named: platform.assetName) != nil {
                Image(platform.assetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius14))
            } else {
                RoundedRectangle(cornerRadius: LiziTokens.radius14)
                    .fill(Color(hex: platform.brandHex))
                    .frame(width: 48, height: 48)
                Text(platform.monogram)
                    .font(.liziDisplay(size: LiziTokens.size20))
                    .foregroundColor(platform.onBrandLight ? LiziTokens.ink : .white)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: LiziTokens.radius14)
                .stroke(LiziTokens.accent, lineWidth: selected ? 2.5 : 0)
        )
        .scaleEffect(selected ? 1.0 : 0.96)
        .animation(.easeOut(duration: 0.14), value: selected)
    }
}
