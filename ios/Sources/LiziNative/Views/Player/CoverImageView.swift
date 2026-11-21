import SwiftUI

/// 专辑封面图（封面流 / dock / 背景共用）。
///
/// 取图走 `ProxyImageView`（进程内 `/api/img` 代理 → 直链 → 占位三级兜底，
/// 见 `CoverImageLoader.swift`）；无封面或加载失败时用深色默认封面
/// （`DefaultCoverArt`，r30 环内那款：深色渐变底 + music.note，
/// 绝不用 ♪ 冒充内容 —— 占位只是一个静音的 music.note 图标，不是歌词也不是封面本身）。
/// r36（第⑥件，用户 2026-11-21 21:20「歌曲封面为什么都是白的」）：
/// 默认占位从白色改成深色，全站统一——旧「没封面用白色，不用金色」
/// 作废；白底 + ♪ 让一次加载失败看着像整站没数据，根因见
/// `CoverImageLoader.swift` 文件头 r36 节（单次尝试永不重试）。
/// r36 之前只有环内传 `darkPlaceholder: true` 画深色，其余调用点一律白占位；
/// 现在默认就是深色，本参数只剩兼容调用点，不再改变渲染。
struct CoverImageView: View {
    let url: URL?
    /// 占位图标大小（调用方按容器尺寸传）。
    var placeholderIconSize: CGFloat = 28
    /// 深色占位（r33 起环内用；r36 起默认就是深色，见 placeholder——
    /// 本参数只剩兼容调用点，不再改变渲染）。
    var darkPlaceholder: Bool = false

    var body: some View {
        ProxyImageView(url: url) { placeholder }
    }

    // r36 修：两支（DefaultCoverArt vs 白底 ZStack）类型不同曾逼出
    // @ViewBuilder（r33 的编不过教训，run 44857131300）——现在两支
    // 同款，只剩一支，@ViewBuilder 照留（以后再分叉也不用重排类型）。
    @ViewBuilder
    private var placeholder: some View {
        DefaultCoverArt(iconSize: placeholderIconSize)
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
