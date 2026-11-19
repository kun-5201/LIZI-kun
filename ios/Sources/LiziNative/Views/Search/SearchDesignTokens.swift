import SwiftUI

/// 搜索页设计令牌（照抄壳版 public/tokens.css；oklch 值换算成近似 sRGB）。
///
/// 字号 12 / 13 / 14 / 16 / 20 / 25 / 31 / 39；圆角 10 / 14 / 20 / 28；
/// 浅色纸面 + 墨色文字；唯一 accent 是网易云红。
/// 禁缩放：SwiftUI 视图本身没有捏合/双击缩放手势，字号全部用固定 pt，
/// 不跟随系统缩放手势变化。
/// 前缀 Search* 是为了不和首页/播放页工人可能建的同名令牌撞符号。
enum SearchDesignTokens {
    // MARK: - 颜色（tokens.css --paper / --paper-2 / --ink / --ink-2 / --ink-3 / --accent）

    /// 纸面底色。
    static let paper = Color(red: 0.965, green: 0.965, blue: 0.973)
    /// 卡片/输入框底色。
    static let paper2 = Color(red: 0.99, green: 0.99, blue: 0.995)
    /// 墨色文字（#17171a 近似）。
    static let ink = Color(red: 0.09, green: 0.09, blue: 0.10)
    /// 次级文字。
    static let ink2 = Color(red: 0.42, green: 0.42, blue: 0.45)
    /// 弱化文字 / 提示文字。
    static let ink3 = Color(red: 0.56, green: 0.56, blue: 0.59)
    /// 唯一 accent：网易云红。
    static let accent = Color(red: 0.89, green: 0.10, blue: 0.16)
    /// accent 的深色版（正在播的行歌名也可用它；本页直接用 accent）。
    static let accentInk = Color(red: 0.76, green: 0.05, blue: 0.12)
    /// 细分割线。
    static let rule = Color.black.opacity(0.08)
    /// 行按下/悬停底色。
    static let rowHighlight = Color.black.opacity(0.04)
    /// 无封面占位底色。
    static let coverPlaceholder = Color.black.opacity(0.07)

    // MARK: - 字号（tokens.css --text-*）

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
    static let radius28: CGFloat = 28

    // MARK: - 便捷字体

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// 等宽数字（时长用，壳版 .track__dur 是等宽字体）。
    static func monoFont(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }
}
