import SwiftUI

/// 平台条：7 家平台图标横排，点按切平台。
///
/// - 顺序与壳版 hall/accounts.js 注册表一致：
///   网易云 / QQ 音乐 / 酷狗 / 汽水 / 波点 / 酷我音乐 / Apple Music。
/// - 切台只换数据、不拆音频（不碰 PlaybackStore）；未登录点图标直接进该平台
///   公开内容（Folia 式全功能），登录提示只在用到登录功能时出现——
///   P1 先做到切台 + 拉公开内容（每日推荐），登录流程本身在 P4。
/// - 图标渲染：品牌色 + 首字 monogram 瓷砖（48pt，圆角 14）。
///   public/assets/platforms/*.svg 是 iconfont 路径（每条约 1KB），
///   手抄进 SwiftUI Path 容易抄错字形，P1 不逐字转录；
///   P3 以 PDF/PNG 资源替换时只改 PlatformIconView，不动调用方。
///   不联网拉图。
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

/// 单个平台图标：品牌色圆角瓷砖 + 首字；选中态描网易云红圈。
struct PlatformIconView: View {
    let platform: LiziPlatforms.Info
    let selected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: LiziTokens.radius14)
                .fill(Color(hex: platform.brandHex))
                .frame(width: 48, height: 48)
            Text(platform.monogram)
                .font(.liziDisplay(size: LiziTokens.size20))
                .foregroundColor(platform.onBrandLight ? LiziTokens.ink : .white)
        }
        .overlay(
            RoundedRectangle(cornerRadius: LiziTokens.radius14)
                .stroke(LiziTokens.accent, lineWidth: selected ? 2.5 : 0)
        )
        .scaleEffect(selected ? 1.0 : 0.96)
        .animation(.easeOut(duration: 0.14), value: selected)
    }
}
