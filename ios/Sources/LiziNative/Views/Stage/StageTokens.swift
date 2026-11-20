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
/// r26 修正：StageView 的根 GeometryReader 与内层 VStack 都挂了
/// `.ignoresSafeArea()`（StageView.swift:90/93），运行时
/// `geo.safeAreaInsets.top` 是 0——公式退化为「顶行 y = topGap」，
/// 这就是 2026-11-20 22:25 截图里顶栏压住状态栏时间的根因
/// （59 → 91pt 或 124 → 156pt 都落不到时间行上，只有 0 → 32pt
///  对得上截图）。r26 不改公式（改 key window 口径会一下冲到约 91pt，
///  违背「只下移一点」），只把竖屏 topGap 每档 +7。
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
/// | topGap（屏顶起算，见上） |  48 |  52 |  56 |  16 |  20 |  24 |
///   （r26：竖屏 28/32/36 → 35/39/43，每档 +7；r27：竖屏 35/39/43 → 48/52/56，
///   顶边脱开岛底 48pt；横屏 16/20/24 一字不动。）
/// | topRowGap          |   8 |  10 |  10 |  12 |  14 |  16 |
/// | 圆按钮直径（竖屏） |  36 |  40 |  42 |   – |   – |   – |
/// | 返回胶囊宽（横屏） |   – |   – |   – |  76 |  80 |  84 |
/// | 设置/形态胶囊宽   |   – |   – |   – |  80 |  84 |  88 |
/// | 胶囊高（横屏）     |   – |   – |   – |  36 |  36 |  36 |
/// （r28：三按钮各缩一档——竖屏圆钮 40/44/46 → 36/40/42，横屏胶囊宽
///   各 −4、胶囊高 40 → 36，图标/文字字号等比缩，见 StageView；
///   topRowGap / sideMargin / topGap 一律不动。）
/// | 播放胶囊理想宽（横屏）|   – |   – |   – | 320 | 340 | 380 |
/// | 顶行紧凑胶囊封面（v5 竖屏）| 32 | 36 | 40 |   – |   – |   – |
///   （v5：竖屏胶囊收进顶行，只能占返回与设置/形态之间的槽位——
///   standard：390 − 边距 32 − 返回 40 − 齿轮 40 − 九宫格 40 − 间距 30
///   = 208pt；按图上比例硬取 280 居中会压住右组（右组左缘 284，
///   280 宽胶囊右缘 335），所以竖屏胶囊不定宽、HStack 填槽，
///   内部同步缩小两档（封面 56→36、歌名 16→14、三键 78→68、
///   横向内边距 12→10、进度条去时间只留细条），歌名栏剩约 70pt，
///   5 字歌名 14pt（约 70）刚好放下；再大一档就只剩 56pt、歌名截成 4 字。
///   图上约 48% 屏宽是示意比例，不按像素定宽。横屏理想宽 320/340/380
///   不动，本来就是约 40–46% 屏宽，与 v5 横屏图一致，内容也不缩。）
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
/// （高度，胶囊高度由内容撑出，不写死：竖屏紧凑胶囊约 56pt，横屏约 60pt；
///  左下角底部预留 = 屏高 × 该比例，截图实测字块顶约在 75% 高处。）
///
/// 验算（v5：胶囊收进顶行，竖屏/横屏同一排，不再叠页面竖直中央）：
/// - 竖屏 standard（390 宽）：顶行 HStack = 边距 16 + 返回圆钮 40 +
///   间距 10 + 紧凑胶囊（填槽，208）+ 间距 10 + 齿轮 40 + 间距 10 +
///   九宫格 40 + 边距 16；胶囊内行：内边距 20 + 封面 36 + 间距 8 +
///   文案 70 + 间距 6 + 三键 68 = 208，5 字歌名 14pt（约 70）放得下；
///   胶囊顶 = topGap 52，岛底约 48，露出 4pt 不盖岛；胶囊高约 56
///   （12 + 文案栈 44，与封面 36 取大），圆钮在行内垂直居中。
/// - 横屏 standard（852×393）：顶行贴顶，topGap 20；胶囊 340 放屏正中间，
///   左右缘 256/596；返回 80 贴左墙（右缘 ≤ 59 + 80 = 139），设置 84 +
///   间距 14 + 形态 84 = 182 贴右墙（左缘 ≥ 852 − 59 − 182 = 611），
///   两端都不碰胶囊；胶囊内行一：封面 48 +
///   间距 10 + 文案 172 + 间距 8 + 三键 78 + 内边距 24 = 340。
/// （r28 旧验算：胶囊叠页面竖直中央，v5 已作废。）
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
    /// 三个顶栏按钮的高：竖屏 = 圆钮直径，横屏 = 胶囊高 36。
    /// （横屏三胶囊按钮的 frame 高走它；浮层锚定改走 topRowCapsuleHeight，
    ///  v5 顶行高 = 胶囊实高，别再拿它当行高。）
    let topCapsuleHeight: CGFloat

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
    // MARK: - 顶行紧凑胶囊（v5 竖屏：胶囊收进顶行填两组按钮之间的槽位，
    //   内部同步缩小；横屏不用这套，沿用上面的正常尺寸）。
    /// 紧凑胶囊纵向内边距（固定 6；进度条去时间只留细条，与 v5 图一致）。
    let topCapsuleVPadding: CGFloat = 6
    /// 紧凑胶囊横向内边距（8/10/10；正常胶囊 10/12/12，竖屏槽位挤不下）。
    let topCapsuleHPadding: CGFloat
    let topCoverSize: CGFloat
    let topTitleFont: CGFloat
    let topArtistFont: CGFloat
    let topSkipButtonFrame: CGFloat
    let topPlayButtonFrame: CGFloat
    let topSkipIconSize: CGFloat
    let topPlayIconSize: CGFloat
    /// 顶行胶囊的实际高度（浮层锚定用）：纵向内边距 ×2 + 封面与文案栈取大；
    /// 文案栈 = 歌名 + 间距 1 + 歌手 + 间距 2 + 进度条 16。
    var topRowCapsuleHeight: CGFloat {
        if isLandscape {
            return capsuleVPadding * 2
                + max(coverSize, titleFont + 1 + artistFont + 2 + 16)
        }
        return topCapsuleVPadding * 2
            + max(topCoverSize, topTitleFont + 1 + topArtistFont + 2 + 16)
    }

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
            topCapsuleHeight = 36
            // 横屏不用紧凑尺寸，走正常胶囊尺寸（字段照常赋值，避免未初始化）。
            topCapsuleHPadding = 0
            topCoverSize = 0; topTitleFont = 0; topArtistFont = 0
            topSkipButtonFrame = 0; topPlayButtonFrame = 0
            topSkipIconSize = 0; topPlayIconSize = 0
            switch tier {
            case .compact:
                sideMargin = 28; topGap = 16; topRowGap = 12
                backCapsuleWidth = 76; settingsCapsuleWidth = 80; pickerCapsuleWidth = 80
                capsuleHPadding = 12; capsuleVPadding = 5
                coverSize = 44; titleFont = 15; artistFont = 11
                skipButtonFrame = 20; playButtonFrame = 24
                skipIconSize = 16; playIconSize = 20; transportSpacing = 4
                idealCapsuleWidthLandscape = 320
            case .standard:
                sideMargin = 32; topGap = 20; topRowGap = 14
                backCapsuleWidth = 80; settingsCapsuleWidth = 84; pickerCapsuleWidth = 84
                capsuleHPadding = 12; capsuleVPadding = 6
                coverSize = 48; titleFont = 15; artistFont = 11
                skipButtonFrame = 22; playButtonFrame = 26
                skipIconSize = 18; playIconSize = 22; transportSpacing = 4
                idealCapsuleWidthLandscape = 340
            case .large:
                sideMargin = 36; topGap = 24; topRowGap = 16
                backCapsuleWidth = 84; settingsCapsuleWidth = 88; pickerCapsuleWidth = 88
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
                sideMargin = 12; topGap = 48; topRowGap = 8
                roundButtonDiameter = 36
                topCapsuleHeight = 36
                capsuleHPadding = 10; capsuleVPadding = 8
                coverSize = 48; titleFont = 15; artistFont = 11
                skipButtonFrame = 20; playButtonFrame = 24
                skipIconSize = 16; playIconSize = 20; transportSpacing = 4
                // v5 紧凑胶囊（顶行填槽用）：封面 32、三键 16/18/16。
                topCapsuleHPadding = 8
                topCoverSize = 32; topTitleFont = 14; topArtistFont = 11
                topSkipButtonFrame = 16; topPlayButtonFrame = 18
                topSkipIconSize = 13; topPlayIconSize = 15
            case .standard:
                sideMargin = 16; topGap = 52; topRowGap = 10
                roundButtonDiameter = 40
                topCapsuleHeight = 40
                capsuleHPadding = 12; capsuleVPadding = 8
                coverSize = 56; titleFont = 16; artistFont = 12
                skipButtonFrame = 22; playButtonFrame = 26
                skipIconSize = 18; playIconSize = 22; transportSpacing = 4
                // v5 紧凑胶囊（顶行填槽用）：封面 36、三键 18/20/18。
                topCapsuleHPadding = 10
                topCoverSize = 36; topTitleFont = 14; topArtistFont = 11
                topSkipButtonFrame = 18; topPlayButtonFrame = 20
                topSkipIconSize = 15; topPlayIconSize = 17
            case .large:
                sideMargin = 16; topGap = 56; topRowGap = 10
                roundButtonDiameter = 42
                topCapsuleHeight = 42
                capsuleHPadding = 12; capsuleVPadding = 8
                coverSize = 60; titleFont = 17; artistFont = 12
                skipButtonFrame = 24; playButtonFrame = 28
                skipIconSize = 20; playIconSize = 24; transportSpacing = 6
                // v5 紧凑胶囊（顶行填槽用）：封面 40、三键 20/22/20。
                topCapsuleHPadding = 10
                topCoverSize = 40; topTitleFont = 15; topArtistFont = 11
                topSkipButtonFrame = 20; topPlayButtonFrame = 22
                topSkipIconSize = 16; topPlayIconSize = 19
            }
            captionBottomReserve = 0.18
        }
    }
}
