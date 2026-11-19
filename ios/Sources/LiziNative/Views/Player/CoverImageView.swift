import SwiftUI

/// 专辑封面图（封面流 / dock / 背景共用）。
///
/// 有封面 URL 时用 `AsyncImage` 加载；无封面或加载失败时用白色占位
/// （MEMORY：没有封面用白色，不用金色；绝不用 ♪ 冒充内容 —— 占位只是一个
/// 静音的 music.note 图标，不是歌词也不是封面本身）。
struct CoverImageView: View {
    let url: URL?
    /// 占位图标大小（调用方按容器尺寸传）。
    var placeholderIconSize: CGFloat = 28

    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure, .empty:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.white
            Image(systemName: "music.note")
                .font(.system(size: placeholderIconSize, weight: .regular))
                .foregroundStyle(PlayerTokens.ink3)
        }
    }
}

/// 封面倒影：翻转的封面 + 渐变遮罩（壳版 `-webkit-box-reflect: below 8px
/// linear-gradient(transparent 62%, rgba(255,255,255,0.25))` 的原生模拟；
/// CSS 的 reflect 没有 SwiftUI 等价物，这是最接近的做法）。
struct CoverReflectionView: View {
    let url: URL?
    /// 倒影高度（壳版倒影约占封面的 30%）。
    var height: CGFloat = 56

    var body: some View {
        CoverImageView(url: url, placeholderIconSize: 16)
            .frame(height: height)
            .clipped()
            .scaleEffect(y: -1)
            .mask(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .white.opacity(0.25), location: 0),
                        .init(color: .white.opacity(0.10), location: 0.38),
                        .init(color: .clear, location: 1),
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .opacity(0.9)
    }
}
