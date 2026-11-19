import SwiftUI

/// 舞台页 r20 分档尺寸表（只 StageView 用）。
///
/// 分档键：窄边 = min(宽, 高)。
/// - 竖屏时窄边 = 宽；横屏时窄边 = 高。同一台设备横竖屏落在同一档，
///   与机型档位一一对应（SE/mini、6.1 寸标准、Pro Max）。
/// - compact  窄边 ≤ 380：SE（375）、mini（360/375）
/// - standard 窄边 381–414：6.1 寸（390/393/402，含截图那台 402×874）
/// - large    窄边 ≥ 415：Pro Max（428/430）
///
/// 顶部一律走 safeAreaInsets，不写死数值：顶行 y = safeArea.top + topGap。
/// 横屏左右边距不用 safeArea.leading/trailing：横屏灵动岛在左右边中段
/// （约中点上下 ±20pt），顶行在屏幕顶部（y 约 20–70pt），纵向不相交；
/// 圆角清让由 28–36pt 的边距保证（16 Pro 圆角半径约 55pt，y=20 处屏边
/// 约在 x=13pt，32pt 边距仍有约 19pt 余量）。竖屏左右 safeArea 为 0，
/// 边距即 token 值。
///
/// 尺寸表（pt；P=竖屏，L=横屏；c/s/l = compact/standard/large 三档）：
/// | 项目               | P-c | P-s | P-l | L-c | L-s | L-l |
/// |--------------------|-----|-----|-----|-----|-----|-----|
/// | sideMargin         |  12 |  16 |  16 |  28 |  32 |  36 |
/// | topGap（安全区下） |  28 |  32 |  36 |  16 |  20 |  24 |
/// | topRowGap          |   8 |  10 |  10 |  12 |  14 |  16 |
/// | 圆按钮直径（竖屏） |  40 |  44 |  46 |   – |   – |   – |
/// | 返回胶囊宽（横屏） |   – |   – |   – |  80 |  84 |  88 |
/// | 设置/形态胶囊宽   |   – |   – |   – |  84 |  88 |  92 |
/// | 播放胶囊理想宽     |   – |   – |   – | 320 | 340 | 380 |
/// | 胶囊圆角           |  20 |  20 |  20 |  20 |  20 |  20 |
/// | 胶囊横向内边距    |  10 |  12 |  12 |  12 |  12 |  14 |
/// | 胶囊纵向内边距    |   8 |   8 |   8 |   5 |   6 |   6 |
/// | 封面边长           |  48 |  56 |  60 |  44 |  48 |  52 |
/// | 歌名字号           |  15 |  16 |  17 |  15 |  15 |  16 |
/// | 歌手字号           |  11 |  12 |  12 |  11 |  11 |  12 |
/// | 上/下一首按钮框    |  20 |  22 |  24 |  20 |  22 |  24 |
/// | 播放按钮框         |  24 |  26 |  28 |  24 |  26 |  28 |
/// | 时间字号           |  11 |  11 |  11 |  11 |  11 |  11 |
/// | 左下角歌词行字号   |  15 |  15 |  15 |  15 |  15 |  15 |
/// | 左下角歌手字号     |  12 |  12 |  12 |  12 |  12 |  12 |
/// | 左下角底部预留     | 18% | 18% | 18% | 17% | 17% | 17% |
/// （高度，胶囊高度由内容撑出，不写死：竖屏约 70pt，横屏约 54pt；
///  左下角底部预留 = 屏高 × 该比例，截图实测字块顶约在 75% 高处。）
///
/// 验算（胶囊不超宽、按钮不挤出、顶行不重叠，见 StageView 注释）：
/// - 竖屏 standard（390 宽）：内容宽 358，圆按钮 44×3 + 间距 10×3 = 162，
///   胶囊 196；胶囊内行一：封面 56 + 间距 10 + 文案 ≥22 + 间距 6 +
///   三键 78 + 内边距 24 = 196，刚好；进度行：196-24-56-10=106，
///   两时间 52 + 间距 12，Slider 剩 42pt。
/// - 横屏 standard（852×393）：内容宽 788，固定件 84+88+88 + 间距 14×2
///   （左段为居中留白）= 288，胶囊取理想 340；胶囊内行一：
///   封面 48 + 间距 10 + 文案 172 + 间距 8 + 三键 78 + 内边距 24 = 340。
enum StageSizeTier: String {
    case compact
    case standard
    case large
}

struct StageTokens {
    let tier: StageSizeTier
    let isLandscape: Bool

    // MARK: - 顶行

    let sideMargin: CGFloat
    let topGap: CGFloat
    let topRowGap: CGFloat
    /// 竖屏：返回 / 设置 / 九宫格三个圆按钮的直径。
    let roundButtonDiameter: CGFloat
    /// 横屏：三个胶囊按钮的固定宽（返回 / 设置 / 形态）。
    let backCapsuleWidth: CGFloat
    let settingsCapsuleWidth: CGFloat
    let pickerCapsuleWidth: CGFloat

    // MARK: - 播放胶囊

    let capsuleCornerRadius: CGFloat = 20
    let capsuleHPadding: CGFloat
    let capsuleVPadding: CGFloat
    let coverSize: CGFloat
    let coverCornerRadius: CGFloat = 10
    let titleFont: CGFloat
    let artistFont: CGFloat
    let skipButtonFrame: CGFloat
    let playButtonFrame: CGFloat
    let skipIconSize: CGFloat
    let playIconSize: CGFloat
    let transportSpacing: CGFloat
    let timeFont: CGFloat = 11
    /// 横屏播放胶囊的理想宽（实际取 min(理想宽, 可用宽)，居中放）。
    let idealCapsuleWidthLandscape: CGFloat

    // MARK: - 左下角

    let captionLyricFont: CGFloat = 15
    let captionArtistFont: CGFloat = 12
    let captionDividerWidth: CGFloat = 46
    /// 左下角字块下方预留的屏高比例（字块顶落在约 75% 高处，与截图一致，
    /// 且与 519 形态自带的 #meta（屏底 4.5vh，约 93% 高处）错开不重叠）。
    let captionBottomReserve: CGFloat

    /// safeArea 不进 token：顶行 y = safeArea.top + topGap，由 StageView 在
    /// 布局时把 geo.safeAreaInsets 加上，token 只管档位尺寸。
    static func `for`(size: CGSize) -> StageTokens {
        let narrow = min(size.width, size.height)
        let tier: StageSizeTier
        if narrow <= 380 {
            tier = .compact
        } else if narrow <= 414 {
            tier = .standard
        } else {
            tier = .large
        }
        return StageTokens(tier: tier, isLandscape: size.width > size.height)
    }

    private init(tier: StageSizeTier, isLandscape: Bool) {
        self.tier = tier
        self.isLandscape = isLandscape
        if isLandscape {
            roundButtonDiameter = 0
            switch tier {
            case .compact:
                sideMargin = 28; topGap = 16; topRowGap = 12
                backCapsuleWidth = 80; settingsCapsuleWidth = 84; pickerCapsuleWidth = 84
                capsuleHPadding = 12; capsuleVPadding = 5
                coverSize = 44; titleFont = 15; artistFont = 11
                skipButtonFrame = 20; playButtonFrame = 24
                skipIconSize = 16; playIconSize = 20; transportSpacing = 4
                idealCapsuleWidthLandscape = 320
            case .standard:
                sideMargin = 32; topGap = 20; topRowGap = 14
                backCapsuleWidth = 84; settingsCapsuleWidth = 88; pickerCapsuleWidth = 88
                capsuleHPadding = 12; capsuleVPadding = 6
                coverSize = 48; titleFont = 15; artistFont = 11
                skipButtonFrame = 22; playButtonFrame = 26
                skipIconSize = 18; playIconSize = 22; transportSpacing = 4
                idealCapsuleWidthLandscape = 340
            case .large:
                sideMargin = 36; topGap = 24; topRowGap = 16
                backCapsuleWidth = 88; settingsCapsuleWidth = 92; pickerCapsuleWidth = 92
                capsuleHPadding = 14; capsuleVPadding = 6
                coverSize = 52; titleFont = 16; artistFont = 12
                skipButtonFrame = 24; playButtonFrame = 28
                skipIconSize = 20; playIconSize = 24; transportSpacing = 6
                idealCapsuleWidthLandscape = 380
            }
            captionBottomReserve = 0.17
        } else {
            backCapsuleWidth = 0; settingsCapsuleWidth = 0; pickerCapsuleWidth = 0
            idealCapsuleWidthLandscape = 0
            switch tier {
            case .compact:
                sideMargin = 12; topGap = 28; topRowGap = 8
                roundButtonDiameter = 40
                capsuleHPadding = 10; capsuleVPadding = 8
                coverSize = 48; titleFont = 15; artistFont = 11
                skipButtonFrame = 20; playButtonFrame = 24
                skipIconSize = 16; playIconSize = 20; transportSpacing = 4
            case .standard:
                sideMargin = 16; topGap = 32; topRowGap = 10
                roundButtonDiameter = 44
                capsuleHPadding = 12; capsuleVPadding = 8
                coverSize = 56; titleFont = 16; artistFont = 12
                skipButtonFrame = 22; playButtonFrame = 26
                skipIconSize = 18; playIconSize = 22; transportSpacing = 4
            case .large:
                sideMargin = 16; topGap = 36; topRowGap = 10
                roundButtonDiameter = 46
                capsuleHPadding = 12; capsuleVPadding = 8
                coverSize = 60; titleFont = 17; artistFont = 12
                skipButtonFrame = 24; playButtonFrame = 28
                skipIconSize = 20; playIconSize = 24; transportSpacing = 6
            }
            captionBottomReserve = 0.18
        }
    }
}
