import SwiftUI
import UIKit

/// 设计令牌：照抄壳版 `public/tokens.css`，只做 SwiftUI 能用的近似。
///
/// - 字体：Fraunces（品牌 / 大标题）已随包提供（`Sources/LiziNative/Fonts/`
///   三档静态 TTF，`UIAppFonts` 注册；见 Fonts/README.md），
///   `liziDisplay` 用 `Font.custom("Fraunces")`，注册缺失时回落系统 serif；
///   中文不在 Fraunces 字库内，由系统字体兜底。Geist（正文）未随包提供，
///   仍用系统字体近似。
/// - 字号：12 / 13 / 14 / 16 / 20 / 25 / 31 / 39（tokens.css 的 1.25 级数）。
/// - 圆角：10 / 14 / 20 / 28。
/// - 颜色：浅色纸面 + 墨色文字；accent 只有一个——网易云红 #EA3E3C。
///   颜色值是 tokens.css 里 OKLCH 值的 sRGB 近似（Xcode 取色器量得），
///   不是另起的色板。
/// - 禁缩放：SwiftUI 原生没有缩放手势；全 App 不加任何 magnification 手势。
enum LiziTokens {
    // MARK: - 颜色（tokens.css --paper / --paper-2 / --ink / --ink-2 / --ink-3 / --accent）

    /// 纸面底色 --paper。
    static let paper = Color(hex: 0xF4F5F7)
    /// 次级纸面 --paper-2（卡片底）。
    static let paper2 = Color(hex: 0xFCFCFD)
    /// 墨色正文 --ink。
    static let ink = Color(hex: 0x1C1C22)
    /// 次级墨色 --ink-2。
    static let ink2 = Color(hex: 0x5A5B64)
    /// 三级墨色 --ink-3（次要文字）。
    static let ink3 = Color(hex: 0x8A8B94)
    /// 唯一 accent：网易云红 --accent。
    static let accent = Color(hex: 0xEA3E3C)
    /// accent 深色 --accent-ink。
    static let accentInk = Color(hex: 0xD23230)
    /// 分隔线 --rule。
    static let rule = Color(hex: 0x1C1C22).opacity(0.09)

    // MARK: - 字号（tokens.css --text-*，1.25 级数）

    static let size12: CGFloat = 12
    static let size13: CGFloat = 13
    static let size14: CGFloat = 14
    static let size16: CGFloat = 16
    static let size20: CGFloat = 20
    static let size25: CGFloat = 25
    static let size31: CGFloat = 31
    static let size39: CGFloat = 39

    // MARK: - 圆角（tokens.css --r-*）

    static let radius10: CGFloat = 10
    static let radius14: CGFloat = 14
    static let radius20: CGFloat = 20
    /// r22j：壳版 `.hall-plat` 铺色面板圆角 22px。
    static let radius22: CGFloat = 22
    static let radius28: CGFloat = 28
}

extension Color {
    /// 0xRRGGBB 六位十六进制初始化。
    init(hex: Int) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

extension Font {
    /// 品牌 / 大标题字体：tokens.css --font-display（Fraunces）。
    /// 字体已随包（Fraunces-Medium 500 / SemiBold 600 / Italic 500，
    /// `UIAppFonts` 注册）；字重透传，CoreText 按最近档匹配
    /// （.regular→500，.semibold→600）；中文等缺字由系统字体兜底。
    /// 字体未注册进包时（资源漏拷）回落系统 serif，不崩、不空白。
    static func liziDisplay(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        if UIFont(name: "Fraunces-Medium", size: size) != nil {
            return .custom("Fraunces", size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    /// 正文字体：tokens.css --font-body（Geist），
    /// 未随包提供时用系统字体近似。
    static func liziBody(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// 数字 / 时长字体：tokens.css --font-mono（Geist Mono），用系统等宽近似。
    static func liziMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
