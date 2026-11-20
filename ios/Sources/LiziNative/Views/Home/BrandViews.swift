import SwiftUI

/// r31 品牌（LI 标记 + LIZI + kun，三部分同一基线，全部代码打上去，绝不贴图）：
/// 顶栏 `HomeView.topBar` 与设置关于页共用同一份 `BrandLockupView`，
/// 两处画出来的是同一枚品牌，不会再各画各的丢一件。
///
/// 尺寸定稿（r28，用户首页截图 1206×2622 @3x，÷3 为 pt）：
/// LI 16.7×11.7、LIZI 33.3×10.7、kun 宽 18.3、间距 LI→LIZI 9.3、LIZI→kun 9.7。
/// LI 与 LIZI 是 SwiftUI Path 按壳版内联 SVG 坐标照抄的矢量
/// （`public/index.html`，几何底本 `public/forms-labs/assets/logo.svg`）；
/// kun 是 Fraunces 斜体 11pt 真文字（`.tracking(1.1)`）。
/// 不是抠图、不是 PNG/JPG 图片资源——用户 2026-11-21 06:35 再明确：
/// 品牌是打上去而不是贴图。
///
/// r31 根因（LI 标记又丢了，用户 2026-11-21 06:33 报，顶栏只剩「LIZI kun」）：
/// `BrandMarkView` 的变换写的是
/// `CGAffineTransform(scaleX: 16.7/368, y: 11.7/366).concatenating(translate(-328,-329))`，
/// 即矩阵 S*T；按 Apple 文档 `concatenating` 是 t' = t1*t2、点是行向量
/// p' = p*M，S*T 的实际效果是先缩放、再平移 -328/-329（平移量不被缩放），
/// 墨迹落在 x -313.07…-296.45、y -318.46…-306.80——屏外，所以看不见。
/// r26 的「修复」是误诊：旧写法 `translation.scaledBy(...)` 按 Apple 头文件注释
/// t' = S*t，与新写法是同一个矩阵（数值验过，逐点包围盒完全相同），
/// 等于没改；r28 只改了缩放数值、没动顺序，r29/r30 没碰品牌，
/// 所以 LI 从 r25 起就一直画在屏外、从没回来过——不是 r29/r30 竖屏重排
/// 或顶栏三钮改动弄丢的。LIZI 没丢是因为 `BrandWordView` 只有纯缩放、
/// 没有平移，顺序问题碰不到它。
/// 修法：不再用 concatenating / scaledBy 拼顺序——直接写死合成矩阵
/// x' = (x-328)·16.7/368，y' = (y-329)·11.7/366，
/// 即 a=16.7/368、d=11.7/366、tx=-328·16.7/368、ty=-329·11.7/366；
/// 逐点算过，墨迹落在 x 0.04…16.66、y 0.02…11.68，正在 16.7×11.7 框内。
/// 断言见 verification/r31-brand.cjs（从源码里把矩阵数抠出来重算包围盒）。

/// 品牌三件套：LI 标记 + LIZI + kun，同一基线（HStack alignment: .center），
/// r28 定稿尺寸与间距。顶栏与设置关于页都用它。
struct BrandLockupView: View {
    var body: some View {
        // r28：间距按用户截图实测（1206×2622 @3x，÷3 为 pt）——
        // LI→LIZI 28px = 9.3pt；LIZI→kun 29px = 9.7pt，
        // 用 spacing 9.3 + kun 前 0.4pt 补齐（HStack 只有一个
        // spacing，两段不等距只能这样分）。kun 不加 `.offset(y:)`：
        // LIZI 10.7pt 高时 kun 不偏移，k 顶正在 LIZI 顶下 1.2pt
        // （图里 4px = 1.3pt），三部分同一基线对齐。
        HStack(alignment: .center, spacing: 9.3) {
            BrandMarkView()
            BrandWordView()
            Text("kun")
                .font(.custom("Fraunces", size: 11).italic().weight(.medium))
                // r28：字号仍 11pt（k 高 8.1pt ≈ 图里 7.7pt）；
                // tracking 0.22 → 1.1——图里 kun 宽 55px = 18.3pt，
                // 11pt Fraunces 斜体实测墨宽仅 ~16.3pt（见 r28 交回），
                // 字号加大到 12pt 会把 k 高顶到 8.7pt（超图 1.0pt），
                // 只能靠字距补宽：tracking 1.1 时墨宽 18.1～18.7pt。
                .tracking(1.1)
                .foregroundColor(LiziTokens.ink2)
                .padding(.leading, 0.4) // 补到 LIZI→kun 间距 9.7pt
        }
    }
}

/// 品牌 LI 标记：SwiftUI Path 按壳版 `public/index.html` 内联 SVG 照抄
/// （`viewBox="328 329 368 366"`，4 个 polygon，坐标一个数都不改；
/// Path 里的数字就是壳版原数）。
/// r28：缩放不再是等比 17pt——用户截图实测标记 50×35px = 16.7×11.7pt
/// （宽高比 1.43:1，不是壳版 SVG 的近正方形），按图横向缩 16.7/368、
/// 纵向缩 11.7/366，框 16.7×11.7；几何底本仍是
/// `public/forms-labs/assets/logo.svg`（已核对，4 个 polygon 与此处
/// 逐点一致，就是同一枚标记）。
/// 不是图片资源，不是抠图；填墨色（壳版 `.brand__mark` fill currentColor，
/// 浅色顶栏上就是墨色）。
struct BrandMarkView: View {
    var body: some View {
        Path { path in
            // polygon 1
            path.move(to: CGPoint(x: 328.94, y: 329.76))
            path.addLine(to: CGPoint(x: 396.71, y: 329.76))
            path.addLine(to: CGPoint(x: 396.71, y: 569.57))
            path.addLine(to: CGPoint(x: 458.02, y: 519.41))
            path.addLine(to: CGPoint(x: 458.02, y: 545.48))
            path.addLine(to: CGPoint(x: 328.94, y: 649.91))
            path.closeSubpath()
            // polygon 2
            path.move(to: CGPoint(x: 328.94, y: 672.81))
            path.addLine(to: CGPoint(x: 396.71, y: 617.97))
            path.addLine(to: CGPoint(x: 396.71, y: 630.67))
            path.addLine(to: CGPoint(x: 554.47, y: 630.67))
            path.addLine(to: CGPoint(x: 587.80, y: 694.32))
            path.addLine(to: CGPoint(x: 328.94, y: 694.32))
            path.closeSubpath()
            // polygon 3
            path.move(to: CGPoint(x: 627.86, y: 329.76))
            path.addLine(to: CGPoint(x: 695.15, y: 329.76))
            path.addLine(to: CGPoint(x: 695.15, y: 372.74))
            path.addLine(to: CGPoint(x: 627.86, y: 428.80))
            path.closeSubpath()
            // polygon 4
            path.move(to: CGPoint(x: 490.18, y: 566.83))
            path.addLine(to: CGPoint(x: 695.15, y: 395.57))
            path.addLine(to: CGPoint(x: 695.15, y: 694.32))
            path.addLine(to: CGPoint(x: 627.86, y: 694.32))
            path.addLine(to: CGPoint(x: 627.86, y: 479.80))
            path.addLine(to: CGPoint(x: 490.18, y: 595.37))
            path.closeSubpath()
        }
        // r31：直接写死合成矩阵，不再用 concatenating / scaledBy 拼顺序
        // （那两个的拼接顺序正好和字面相反，r26 就是这么被骗的，见文件头）。
        // x' = (x-328)·16.7/368，y' = (y-329)·11.7/366：
        // a = 16.7/368，d = 11.7/366，tx = -328·16.7/368，ty = -329·11.7/366。
        // 逐点算过：墨迹 x 0.04…16.66、y 0.02…11.68，正在 16.7×11.7 框内。
        .transform(CGAffineTransform(
            a: 16.7 / 368, b: 0, c: 0, d: 11.7 / 366,
            tx: -328 * 16.7 / 368, ty: -329 * 11.7 / 366))
        .fill(LiziTokens.ink)
        .frame(width: 16.7, height: 11.7)
    }
}

/// 品牌 LIZI 四个字母：SwiftUI Path 按壳版 `public/index.html` 内联 SVG
/// 照抄（`viewBox="0 0 224 100"`；L = polygon，I = rect，
/// Z = rect + polygon + rect，I = rect）。
/// r28：按用户截图实测 100×32px = 33.3×10.7pt 校准（壳版是 34×15，
/// 纵向压到约 0.71×）。只等比缩会让字母间距剩 2.7pt（图里 3.3pt），
/// 所以字母 x 坐标各右移——I +3、Z 组 +6、末 I +9（总宽 224→233
/// 单位，间距 18→21 单位），再非等比缩到 33.3×10.7；字形本身
/// （L 斜切脚、Z 斜笔）一个点都没改，只是整体平移。
/// 不是字体打出来的（壳版本来就不是字体，是多边形），不是图片资源。
/// 只有纯缩放、没有平移，r31 的顺序问题碰不到它，原样不动。
struct BrandWordView: View {
    var body: some View {
        Path { path in
            // L：polygon (0,0 19,0 19,81 47,81 66,100 0,100)——r28 未动
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 19, y: 0))
            path.addLine(to: CGPoint(x: 19, y: 81))
            path.addLine(to: CGPoint(x: 47, y: 81))
            path.addLine(to: CGPoint(x: 66, y: 100))
            path.addLine(to: CGPoint(x: 0, y: 100))
            path.closeSubpath()
            // I：rect x87 y0 w19 h100（r28：壳版 x84，+3 拉开字母间距）
            path.addRect(CGRect(x: 87, y: 0, width: 19, height: 100))
            // Z：rect(127,0,66,18) + polygon(175,18 193,18 145,82 127,82)
            //    + rect(127,82,66,18)（r28：壳版 x121，+6）
            path.addRect(CGRect(x: 127, y: 0, width: 66, height: 18))
            path.move(to: CGPoint(x: 175, y: 18))
            path.addLine(to: CGPoint(x: 193, y: 18))
            path.addLine(to: CGPoint(x: 145, y: 82))
            path.addLine(to: CGPoint(x: 127, y: 82))
            path.closeSubpath()
            path.addRect(CGRect(x: 127, y: 82, width: 66, height: 18))
            // I：rect x214 y0 w19 h100（r28：壳版 x205，+9）
            path.addRect(CGRect(x: 214, y: 0, width: 19, height: 100))
        }
        // r28：非等比缩到截图实测 33.3×10.7（总宽 233 单位：33.3/233；
        // 高 100 单位：10.7/100）。字母实测：L/Z 9.43、I 2.72、
        // 间距 3.00，相对图里 9.7 / 2.7 / 3.3 误差 ≤0.30pt。
        .transform(CGAffineTransform(scaleX: 33.3 / 233, y: 10.7 / 100))
        .fill(LiziTokens.ink)
        .frame(width: 33.3, height: 10.7)
    }
}
