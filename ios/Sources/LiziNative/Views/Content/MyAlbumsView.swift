import Foundation
import SwiftUI

/// 我的专辑 · 3D 陈列架（P2 工人 C）。
///
/// 数据：只读本地收藏 `AlbumShelfStore.load()`（本阶段未登录，不接服务端歌单，
/// 登录迁移是 P4 的事）。没有收藏时诚实空态，不编假专辑。
///
/// 形态（照抄壳版 `public/pages/myalbums.js` + `app.js` 约 4707–4721 行的
/// `lizi.myAlbums.form` 语义，键名按原生约定改为 `lizi.native.myAlbums.form`，
/// 值 `"spine"` / `"flow"`，缺省 spine；读不到 / 非 flow 一律 spine）：
/// - spine（默认 · 侧立 3D 架）：专辑像书一样侧立排布，书脊朝外；扇开角照抄壳版
///   REF 参数（fan ±22°、tanh 阻尼 0.85），整架 `rotation3DEffect` 透视 0.5。
/// - flow（正面 Cover Flow）：变换表、手势、倒影照抄 P1 播放页
///   `Views/Player/CoverFlowView.swift` 的做法（同一套数，不另起手势）：
///   中间正对最大、两侧 rotateY ±40°/±50°、倒影 `CoverReflectionView`、
///   滑动阈值 56px、点两侧切到中间、点中间进专辑页。
///
/// 导航约定（工人 A 在 `AppNavigation.swift` 里加，本文件只按约定引用，不改它）：
/// - `nav.show(.myAlbums)` 进本页；`nav.show(.album(platform:id:))` 进专辑页。
///   RootView 里这两个 case 的接线也是协调员 / 工人 A 的事。
/// - 本页自带回首页栏（照抄 RootView 的 `SearchViewWithBack` 样式），不依赖外包。
///
/// 约束：禁缩放（全页不加任何 magnification 手势，尺寸固定）；
/// 封面无图用 `CoverImageView` 的白色底 + 音符占位，不用金色；无强制解包。
/// 3D 手感只能真机确认，VM 上只做静态检查。
///
/// r24（2026-11-20，第 4 件，手势链重写——不是 P2 代码换参数：旧的
/// `shelfDragGesture`（容器 SwiftUI DragGesture，只有 onEnded）与各本的
/// `.onTapGesture` 全部删掉，改为 UIKit `ShelfTouchView` + 模型同一套
/// 新入口；用户原话「后面我会查看代码，不能拿以前的代码」）：
/// - 根因（静态核对，三条都坐实）：
///   1. 方向反了：旧手势 dx<0（左滑）调 `selectPrevious`——壳版
///      myalbums.js 是 `pos = from − dx/gap`、卡的 x = (i − pos) × gap，
///      左滑 pos 变大 = 下一张，手指往左、架子往右跳；架子抄了播放页
///      CoverFlow「左滑上一首」的方向，违背了自己的壳版对照物。
///   2. 拖动全程没反馈：旧手势只有 onEnded，手指在架子上划、架子一动不动，
///      松手才跳一档；到头（第 0 张左滑 / 最后一张右滑）还被 clamp 吞成
///      完全没反应。两点加起来就是用户说的「无法转动」。
///   3. 父子手势裁决：容器 `.gesture(DragGesture)` + 各本 `.onTapGesture`，
///      谁先拿到触摸全看 SwiftUI 的裁决，和首页环 r21/r22c 在 ScrollView
///      里丢手势是同一类失手；改成 UIKit 一对识别器（pan + tap，
///      tap require(toFail: pan)，与 StripTouchView 同款），触摸只归一处。
/// - 新链（对照壳版 myalbums.js stage 的 pointerdown/move/up）：
///   拖动跟手（dragOffset，内容跟手指走；到头 0.32 橡皮筋；一轮最多一档），
///   松手惯性（速度 × 260ms / 一档宽，四舍五入吸附到最近一档），
///   点按坐标命中（hitIndex `round(pos + (x − centerX)/gap)` 同款，
///   ≤8px 算点按）；spine 点本进专辑页、flow 点中间进专辑页、
///   点两侧切到中间——点按语义一字不动。
/// - 不动的部分：变换表（spine 扇开角 fan ±22°/tanh 0.85、flow metrics）、
///   形态切换与持久化、步进按钮、空态、数据（只读 AlbumShelfStore）。

// MARK: - 形态与固定尺寸（照抄壳版参数，见文件头）

/// 陈列架形态（壳版 `localStorage['lizi.myAlbums.form']` 的两个值）。
enum MyAlbumForm: String, CaseIterable {
    case spine
    case flow

    /// 形态名（壳版 `FORMS` 的中文名，一个字没改）。
    var label: String {
        switch self {
        case .spine: return "侧立 3D"
        case .flow: return "正面 Cover Flow"
        }
    }
}

/// 侧立架：单本书脊宽 / 高（固定尺寸，不随手势缩放）。
private let spineWidth: CGFloat = 46
private let spineHeight: CGFloat = 216
/// 侧立架：相邻书脊中心间距 = 脊宽 46 + 12 间隙（本尺寸下的取值；
/// 壳版 REF spacing 156 是按 420px 封面算的，本架书脊只有 46 宽，不直接等比）。
private let spineSpacing: CGFloat = 58
/// 侧立架扇开角上限（壳版 REF fan 22°）与 tanh 阻尼（壳版 REF damp 0.85）。
private let spineFan: Double = 22
private let spineDamp: Double = 0.85
/// 两形态共用的 SwiftUI 透视系数（CoverFlowView 的 perspective3D，近似 CSS 1100px）。
private let shelfPerspective: CGFloat = 0.5
/// 正面流：单张尺寸 / 轨道高（照抄 CoverFlowView / PlayerTokens，188 / 254）。
private let flowItemSize: CGFloat = 188
private let flowTrackHeight: CGFloat = 254

// MARK: - ViewModel

/// 我的专辑状态：收藏列表 + 当前选中下标 + 形态（持久化）。
final class MyAlbumsViewModel: ObservableObject {
    /// 形态持久化键（壳版 `lizi.myAlbums.form` 的原生版键名，含义照抄）。
    private static let formKey = "lizi.native.myAlbums.form"

    @Published private(set) var albums: [Album] = []
    @Published var selectedIndex: Int = 0
    @Published var form: MyAlbumForm = .spine {
        didSet { saveForm() }
    }

    init() {
        self.form = Self.loadForm()
        reload()
    }

    /// 当前选中的专辑（下标越界时为 nil，不崩）。
    var selectedAlbum: Album? {
        albums.indices.contains(selectedIndex) ? albums[selectedIndex] : nil
    }

    /// 重读本地收藏（从专辑页收藏 / 取消收藏回来时，onAppear 会调一次）。
    func reload() {
        albums = AlbumShelfStore.load()
        if albums.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(max(selectedIndex, 0), albums.count - 1)
        }
    }

    /// 选中某一张（夹在 0..<count，不越界；架子有两头，不像播放队列那样循环）。
    func select(index: Int) {
        guard !albums.isEmpty else { return }
        selectedIndex = min(max(index, 0), albums.count - 1)
    }

    func selectPrevious() { select(index: selectedIndex - 1) }
    func selectNext() { select(index: selectedIndex + 1) }

    // MARK: - r24 手势链（新写，第 4 件；对照壳版 public/pages/myalbums.js）

    /// 拖动中的跟手偏移（pt；+ = 内容跟着手指往右；松手即清零，
    /// 壳版 S.pos 的点数版：pos = from − dx/gap，卡的 x = (i − pos) × gap）。
    @Published var dragOffset: CGFloat = 0

    /// 一档的拖动距离（pt）：spine = 书脊间距 58；flow = 单张边长 188
    /// （CoverFlowView 的 dragProgress 分母 itemSize 同款）。
    var stepPx: CGFloat { form == .spine ? spineSpacing : flowItemSize }

    /// 拖动中的分数位置（壳版 S.pos：选中下标 − dx/gap；扇开角/透明度/
    /// 缩放都按它算，松手吸附到最近整数）。
    var dragPosition: CGFloat {
        CGFloat(selectedIndex) - dragOffset / stepPx
    }

    /// 手指落下（ShelfTouchView touchesBegan）：新一轮拖动，跟手偏移清零。
    func shelfDragBegan() {
        dragOffset = 0
    }

    /// 手指移动（ShelfTouchView pan .changed；壳版 pointermove 同款）：
    /// 内容跟手；到头再拖按 0.32 橡皮筋（壳版 `raw < 0 → raw *= 0.32`
    /// 同款）；一轮最多一档（CoverFlowView dragProgress 夹 ±1 同款）。
    func shelfDragMoved(dx: CGFloat) {
        guard !albums.isEmpty else { return }
        var offset = dx
        let last = albums.count - 1
        if (selectedIndex <= 0 && dx > 0) || (selectedIndex >= last && dx < 0) {
            offset = dx * 0.32
        }
        dragOffset = max(-stepPx, min(stepPx, offset))
    }

    /// 手指抬起（ShelfTouchView pan .ended；壳版 pointerup 同款）：
    /// 松手速度（pt/s）× 0.26s 换算成像素再除以一档宽（壳版
    /// `S.vel * 260 / gapPx()` 同款，速度单位已换算成 pt/s），
    /// 加到已拖距离上、四舍五入到最近一档、夹在两头；方向是壳版的
    /// 方向——左滑下一张、右滑上一张（旧代码反了：dx<0 调 selectPrevious，
    /// 手指往左、架子往右跳，第 4 件「转不动」的另一半根因）。
    /// 没过半档就回弹（dragOffset 清零 + 0.38s easeOut）。
    func shelfDragEnded(dx: CGFloat, velocity: CGFloat) {
        guard !albums.isEmpty else { return }
        let projected = dx + velocity * 0.26
        let steps = max(-1, min(1, Int((projected / stepPx).rounded())))
        let target = min(max(selectedIndex - steps, 0), albums.count - 1)
        withAnimation(.easeOut(duration: 0.38)) {
            selectedIndex = target
            dragOffset = 0
        }
    }

    /// 切换形态并持久化（下次启动保持）。
    func toggleForm() {
        form = (form == .spine) ? .flow : .spine
    }

    /// 读形态：只有 `"flow"` 是 flow，其余（缺省 / 损坏 / 其他值）一律 spine，
    /// 和壳版 `maForm()` 的容错读法一致。
    private static func loadForm() -> MyAlbumForm {
        UserDefaults.standard.string(forKey: formKey) == "flow" ? .flow : .spine
    }

    private func saveForm() {
        UserDefaults.standard.set(form.rawValue, forKey: Self.formKey)
    }
}

// MARK: - 我的专辑页

struct MyAlbumsView: View {
    @EnvironmentObject private var nav: AppNavigation
    @StateObject private var viewModel = MyAlbumsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            backBar
            titleRow
            if viewModel.albums.isEmpty {
                emptyState
            } else {
                formPicker
                shelfArea
                selectedCaption
                steppers
                Spacer(minLength: 0)
            }
        }
        .background(LiziTokens.paper)
        .onAppear { viewModel.reload() }
    }

    // MARK: - 顶栏 / 标题 / 形态切换

    /// 回首页栏（照抄 RootView 的 SearchViewWithBack 样式，本页自带）。
    private var backBar: some View {
        HStack {
            Button(action: { nav.show(.home) }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("首页")
                        .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                }
                .foregroundColor(LiziTokens.ink2)
            }
            .accessibilityLabel("回首页")
            Spacer()
            Text("\(viewModel.albums.count) 张")
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var titleRow: some View {
        HStack {
            Text("我的专辑")
                .font(.liziDisplay(size: LiziTokens.size25))
                .foregroundColor(LiziTokens.ink)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    /// 两种形态切换（分段选择器；改动即写 UserDefaults，下次启动保持）。
    private var formPicker: some View {
        Picker("展示形态", selection: $viewModel.form) {
            ForEach(MyAlbumForm.allCases, id: \.self) { form in
                Text(form.label).tag(form)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - 架子（两种形态共用同一份选中态与手势方向）

    @ViewBuilder
    private var shelfArea: some View {
        switch viewModel.form {
        case .spine:
            spineShelf
        case .flow:
            flowShelf
        }
    }

    /// 点按命中（r24，第 4 件；壳版 hitIndex
    /// `round(pos + (x − centerX) / gap)` 同款）：spine 按书脊间距换算，
    /// flow 按最近一张卡中心换算；点在架子外面（算出来越界）回 nil = 空白，
    /// 不动作。调用方按形态执行点按语义（spine 点本进专辑页；
    /// flow 点中间进专辑页、点两侧切到中间）。
    private func shelfHitIndex(x: CGFloat, centerX: CGFloat) -> Int? {
        guard !viewModel.albums.isEmpty else { return nil }
        if viewModel.form == .spine {
            let idx = Int((viewModel.dragPosition + (x - centerX) / spineSpacing).rounded())
            return viewModel.albums.indices.contains(idx) ? idx : nil
        }
        var best: (index: Int, distance: CGFloat)?
        for offset in flowOffsets {
            let index = viewModel.selectedIndex + offset
            guard viewModel.albums.indices.contains(index) else { continue }
            let cx = centerX + flowMetrics(for: offset).offsetX
            let d = abs(x - cx)
            if best == nil || d < best!.distance {
                best = (index, d)
            }
        }
        guard let best, best.distance <= flowItemSize / 2 else { return nil }
        return best.index
    }

    /// 点一张进专辑页（约定：工人 A 的 `.album(platform:id:)` 路由）。
    private func openAlbum(_ album: Album?) {
        guard let album else { return }
        nav.show(.album(platform: album.source, id: album.id))
    }

    // MARK: - spine：侧立 3D 书架

    /// 侧立架可见窗口：选中张前后各 6 本（再远的不渲染，收藏再多也不堆视图；
    /// r24：拖动中按分数位置取整，窗口跟着手指走，边缘一本跨过半档才换，
    /// 不在拖动中途闪现/消失）。
    private var visibleSpineIndices: [Int] {
        let center = Int(viewModel.dragPosition.rounded())
        return viewModel.albums.indices.filter { abs($0 - center) <= 6 }
    }

    private var spineShelf: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                ForEach(visibleSpineIndices, id: \.self) { index in
                    let album = viewModel.albums[index]
                    // r24：分数偏移（壳版 d = i − S.pos）：拖动中扇开角/透明度/
                    // 缩放/横坐标都跟着手指连续变，松手才吸附到整数（旧代码只用
                    // 整数偏移，拖动全程画面一动不动）。
                    let offset = CGFloat(index) - viewModel.dragPosition
                    SpineBookView(album: album)
                        .opacity(spineOpacity(for: offset))
                        .scaleEffect(spineScale(for: offset))
                        .rotation3DEffect(
                            .degrees(spineAngle(for: offset)),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: shelfPerspective
                        )
                        .offset(x: offset * spineSpacing)
                        .zIndex(Double(100 - abs(offset)))
                        // 点按不再走各本的 .onTapGesture（已删，见文件头）：
                        // 触摸层盖在上面，VoiceOver 激活走这里。
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("专辑：\(album.title)")
                        .accessibilityAction { openAlbum(album) }
                        .animation(.easeOut(duration: 0.38), value: viewModel.selectedIndex)
                }
                // r24：触摸层（ShelfTouchView，UIKit，文件尾）盖在最上层——
                // 拖动跟手 + 点按命中都归它（旧的 .gesture(shelfDragGesture)
                // 与各本的 .onTapGesture 已删，第 4 件根因见文件头）。
                ShelfTouchView(viewModel: viewModel) { x, centerX in
                    if let idx = shelfHitIndex(x: x, centerX: centerX) {
                        openAlbum(viewModel.albums[idx])
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: spineHeight + 20)
            .contentShape(Rectangle())
            // 架板：书脊底部落在这条线上
            RoundedRectangle(cornerRadius: 3)
                .fill(LiziTokens.ink.opacity(0.14))
                .frame(height: 6)
                .padding(.horizontal, 20)
        }
        .padding(.top, 8)
    }

    /// 扇开角（壳版 REF：fan ±22°、tanh 阻尼 0.85；符号和 CoverFlow 一致：
    /// 左边 +、右边 −，整排像扇子一样张开；r24：入参改成分数偏移，
    /// 拖动中角度连续跟手）。
    private func spineAngle(for offset: CGFloat) -> Double {
        -spineFan * tanh(spineDamp * Double(offset))
    }

    private func spineScale(for offset: CGFloat) -> CGFloat {
        switch abs(Int(offset.rounded())) {
        case 0: return 1.05
        case 1: return 0.98
        default: return 0.94
        }
    }

    private func spineOpacity(for offset: CGFloat) -> Double {
        switch abs(Int(offset.rounded())) {
        case 0: return 1
        case 1: return 0.92
        default: return 0.78
        }
    }

    // MARK: - flow：正面 Cover Flow（照抄 CoverFlowView 的变换表）

    /// 显示的 5 个位置：相对选中下标的偏移 -2…+2（两头处自然变少，不补假数据）。
    private var flowOffsets: [Int] {
        guard !viewModel.albums.isEmpty else { return [] }
        return (-2...2).filter { viewModel.albums.indices.contains(viewModel.selectedIndex + $0) }
    }

    private var flowShelf: some View {
        ZStack(alignment: .top) {
            ForEach(flowOffsets, id: \.self) { offset in
                flowItem(offset: offset)
                    .zIndex(flowZIndex(for: offset))
            }
            // r24：触摸层（ShelfTouchView，UIKit，文件尾）盖在最上层——
            // 拖动跟手 + 点按命中都归它（旧的 .gesture(shelfDragGesture)
            // 与各张的 .onTapGesture 已删，第 4 件根因见文件头）。
            ShelfTouchView(viewModel: viewModel) { x, centerX in
                if let idx = shelfHitIndex(x: x, centerX: centerX) {
                    if idx == viewModel.selectedIndex {
                        // 点中间那张进专辑页
                        openAlbum(viewModel.albums[idx])
                    } else {
                        // 点两侧切到中间
                        viewModel.select(index: idx)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: flowTrackHeight)
        .contentShape(Rectangle())
        .padding(.top, 8)
    }

    @ViewBuilder
    private func flowItem(offset: Int) -> some View {
        let index = viewModel.selectedIndex + offset
        let album = viewModel.albums.indices.contains(index) ? viewModel.albums[index] : nil
        // r24：拖动跟手——有效档位 = offset − dragProgress
        // （CoverFlowView r23j 同款插值；dragProgress = dragOffset / 单张边长，
        // 夹 ±1；手指停封面就停，dragOffset 不挂动画；旧代码拖动全程
        // 画面一动不动，松手才跳一档）。
        let dragProgress = max(-1, min(1, viewModel.dragOffset / flowItemSize))
        let metrics = flowMetrics(forEffectiveOffset: Double(offset) - Double(dragProgress))

        VStack(spacing: 8) {
            CoverImageView(url: album?.coverURL, placeholderIconSize: 64)
                .frame(width: flowItemSize, height: flowItemSize)
                .clipShape(RoundedRectangle(cornerRadius: PlayerTokens.radiusMd))
                .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: PlayerTokens.radiusMd)
                        .stroke(Color.white.opacity(0.14), lineWidth: offset == 0 ? 1 : 0)
                )
            CoverReflectionView(url: album?.coverURL, height: flowItemSize * 0.3)
                .frame(width: flowItemSize)
        }
        .frame(width: flowItemSize)
        .opacity(metrics.opacity)
        .scaleEffect(metrics.scale)
        .rotation3DEffect(
            .degrees(metrics.rotateY),
            axis: (x: 0, y: 1, z: 0),
            perspective: shelfPerspective
        )
        .offset(x: metrics.offsetX)
        // 点按不再走各张的 .onTapGesture（已删，见文件头）：
        // 触摸层盖在上面，VoiceOver 激活走这里（语义与旧点按一字不动）。
        .accessibilityElement(children: .combine)
        .accessibilityLabel(offset == 0 ? "打开专辑：\(album?.title ?? "专辑")" : "切换到专辑：\(album?.title ?? "专辑")")
        .accessibilityAction {
            if offset == 0 {
                openAlbum(album)
            } else if viewModel.albums.indices.contains(index) {
                viewModel.select(index: index)
            }
        }
        .animation(.easeOut(duration: 0.38), value: viewModel.selectedIndex)
    }

    /// 变换表（照抄 CoverFlowView.metrics：两侧 ±128px/±224px、rotateY ±40°/±50°、
    /// 纵深缩放 scale = 1100 / (1100 + |translateZ|)，即 -110 → 0.91、-200 → 0.85）。
    private struct FlowMetrics {
        var offsetX: CGFloat
        var scale: CGFloat
        var rotateY: Double
        var opacity: Double
    }

    private func flowMetrics(for offset: Int) -> FlowMetrics {
        switch offset {
        case 0:
            return FlowMetrics(offsetX: 0, scale: 1.04, rotateY: 0, opacity: 1)
        case -1:
            return FlowMetrics(offsetX: -128, scale: 1100 / (1100 + 110), rotateY: 40, opacity: 0.88)
        case 1:
            return FlowMetrics(offsetX: 128, scale: 1100 / (1100 + 110), rotateY: -40, opacity: 0.88)
        case -2:
            return FlowMetrics(offsetX: -224, scale: 1100 / (1100 + 200), rotateY: 50, opacity: 0.5)
        case 2:
            return FlowMetrics(offsetX: 224, scale: 1100 / (1100 + 200), rotateY: -50, opacity: 0.5)
        default:
            return FlowMetrics(offsetX: 0, scale: 1, rotateY: 0, opacity: 0)
        }
    }

    /// 相邻两档 metrics 间插值（CoverFlowView.metrics(forEffectiveOffset:)
    /// 同款；拖动时封面在两档之间跟手走，不跳变）。
    private func flowMetrics(forEffectiveOffset effective: Double) -> FlowMetrics {
        let clamped = min(2, max(-2, effective))
        let lo = Int(floor(clamped))
        let hi = min(2, lo + 1)
        let f = clamped - Double(lo)
        let a = flowMetrics(for: lo)
        let b = flowMetrics(for: hi)
        return FlowMetrics(
            offsetX: a.offsetX + (b.offsetX - a.offsetX) * CGFloat(f),
            scale: a.scale + (b.scale - a.scale) * CGFloat(f),
            rotateY: a.rotateY + (b.rotateY - a.rotateY) * f,
            opacity: a.opacity + (b.opacity - a.opacity) * f
        )
    }

    private func flowZIndex(for offset: Int) -> Double {
        switch abs(offset) {
        case 0: return 5
        case 1: return 4
        default: return 3
        }
    }

    // MARK: - 选中说明 / 步进 / 空态

    /// 选中专辑的标题 + 歌手 + 曲目数（曲目数未知为 0 时不显示，不编数字）。
    private var selectedCaption: some View {
        VStack(spacing: 4) {
            if let album = viewModel.selectedAlbum {
                Text(album.title)
                    .font(.liziDisplay(size: LiziTokens.size20))
                    .foregroundColor(LiziTokens.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !album.artist.isEmpty {
                        Text(album.artist)
                            .font(.liziBody(size: LiziTokens.size14))
                            .foregroundColor(LiziTokens.ink2)
                            .lineLimit(1)
                    }
                    if album.trackCount > 0 {
                        Text("共 \(album.trackCount) 首")
                            .font(.liziBody(size: LiziTokens.size14))
                            .foregroundColor(LiziTokens.ink3)
                    }
                }
            }
        }
        .frame(height: 56)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// 上一张 / 下一张（两头禁用；计数 `n / 总数`，方便确认位置）。
    private var steppers: some View {
        HStack(spacing: 24) {
            Button(action: { viewModel.selectPrevious() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(LiziTokens.ink2)
                    .frame(width: 40, height: 40)
                    .background(LiziTokens.paper2)
                    .clipShape(Circle())
            }
            .disabled(viewModel.selectedIndex <= 0)
            .accessibilityLabel("上一张")
            Text("\(viewModel.selectedIndex + 1) / \(viewModel.albums.count)")
                .font(.liziMono(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
            Button(action: { viewModel.selectNext() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(LiziTokens.ink2)
                    .frame(width: 40, height: 40)
                    .background(LiziTokens.paper2)
                    .clipShape(Circle())
            }
            .disabled(viewModel.selectedIndex >= viewModel.albums.count - 1)
            .accessibilityLabel("下一张")
        }
        .padding(.top, 4)
    }

    /// 无收藏空态（诚实文案，不编假专辑）。
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(LiziTokens.ink3)
            Text("还没有收藏专辑")
                .font(.liziDisplay(size: LiziTokens.size20))
                .foregroundColor(LiziTokens.ink)
            Text("在专辑页点「收藏」，专辑就会出现在这里。")
                .font(.liziBody(size: LiziTokens.size14))
                .foregroundColor(LiziTokens.ink2)
                .multilineTextAlignment(.center)
            Text("现在只保存本机收藏；服务端同步等登录迁移（P4）后再接。")
                .font(.liziBody(size: LiziTokens.size12))
                .foregroundColor(LiziTokens.ink3)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 侧立架单本：书脊

/// 一本侧立的专辑：书脊朝外（小封面徽章 + 竖排标题 + 书页边），
/// 扇开角与透视由外层 `spineShelf` 给整本加 `rotation3DEffect`。
private struct SpineBookView: View {
    let album: Album

    var body: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(LiziTokens.paper2)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(LiziTokens.rule, lineWidth: 1)
                )
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    // 书脊徽章：壳版 .ma-item__sbadge（小封面，约脊宽的 72%）
                    CoverImageView(url: album.coverURL, placeholderIconSize: 14)
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    // 竖排标题：先定横向框再旋转，旋转后占 16×150
                    Text(album.title)
                        .font(.liziBody(size: LiziTokens.size12, weight: .medium))
                        .foregroundColor(LiziTokens.ink)
                        .lineLimit(1)
                        .frame(width: 150, height: 16)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 16, height: 150)
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
                .frame(width: spineWidth - 5)
                // 书页边：5pt 暗条，暗示书的厚度
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 5)
            }
        }
        .frame(width: spineWidth, height: spineHeight)
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 6)
    }
}

// MARK: - 架子触摸层（r24，第 4 件，新写）

/// 架子的触摸层：一个透明 UIView，盖在书脊 / 封面卡上方，接管架子上的
/// 全部触摸（壳版 myalbums.js 里 stage 的 pointerdown + pointermove +
/// pointerup 同款——一根手指从按下一路管到松手，手指不抬起、没有
/// SwiftUI 手势半路接力；setPointerCapture 的等价物就是 UIKit 里
/// 同一根触摸序列固定发给同一个视图）。
///
/// 为什么重写（第 4 件根因，见文件头）：方向反了、拖动全程没反馈、
/// 到头被 clamp 吞掉、父子 SwiftUI 手势裁决不可靠。新写只动这一条链：
/// 变换表（spine 扇开角 / flow metrics）、形态切换、点按语义
/// （spine 点本进专辑页、flow 点中间进专辑页、点两侧切到中间）一字不动。
struct ShelfTouchView: UIViewRepresentable {
    @ObservedObject var viewModel: MyAlbumsViewModel
    /// 点按命中某张（x = 触摸点本地横坐标，centerX = 架子中心横坐标；
    /// 调用方用 shelfHitIndex 换算下标、按形态执行点按语义）。
    var onTap: (CGFloat, CGFloat) -> Void

    @MainActor
    func makeUIView(context: Context) -> ShelfTouchUIView {
        let view = ShelfTouchUIView()
        view.model = viewModel
        view.onTap = onTap
        return view
    }

    @MainActor
    func updateUIView(_ uiView: ShelfTouchUIView, context: Context) {
        uiView.model = viewModel
        uiView.onTap = onTap
    }
}

/// 架子的 UIKit 宿主视图（主线程；手势回调都在主线程进模型）。
@MainActor
final class ShelfTouchUIView: UIView, UIGestureRecognizerDelegate {
    weak var model: MyAlbumsViewModel?
    var onTap: ((CGFloat, CGFloat) -> Void)?

    /// 本次触摸起点横坐标（touchesBegan 记，pan 的 .began 要等到第一下
    /// 移动才回调，等不及——起点丢了，跟手偏移就从错的位置起算）。
    private var startX: CGFloat = 0
    /// 本次拖动累计的最大位移（壳版 `S.drag.moved`：≤8px = 点按，>8px = 拖动）。
    private var moved: CGFloat = 0
    /// 最近 110ms 的（时间，x）采样，松手速度用（ring.js SAMPLE_MS 同款）。
    private var samples: [(time: Date, x: CGFloat)] = []

    private lazy var pan: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var tap: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        recognizer.delegate = self
        // 点按只在 pan 没认出来时才算（带一点位移的轻触按拖动走，不双重触发；
        // 与 StripTouchView 同款）。
        recognizer.require(toFail: pan)
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    /// 手指刚落下：记起点、清采样、模型跟手偏移清零（新一轮拖动）。
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }
        startX = touch.location(in: self).x
        moved = 0
        samples = [(Date(), startX)]
        model?.shelfDragBegan()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let model else { return }
        let x = recognizer.location(in: self).x
        switch recognizer.state {
        case .changed:
            let dx = x - startX
            moved = max(moved, abs(dx))
            let now = Date()
            samples.append((now, x))
            while samples.count > 2, now.timeIntervalSince(samples[0].time) > 0.110 {
                samples.removeFirst()
            }
            model.shelfDragMoved(dx: dx)
        case .ended, .cancelled:
            guard moved > 8 else { return }
            let dx = x - startX
            var velocity: CGFloat = 0
            if samples.count > 1 {
                let first = samples[0]
                let last = samples[samples.count - 1]
                let span = last.time.timeIntervalSince(first.time)
                if span > 0.008 {
                    velocity = max(-3000, min(3000, (last.x - first.x) / CGFloat(span)))
                }
            }
            model.shelfDragEnded(dx: dx, velocity: velocity)
        default:
            break
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let location = recognizer.location(in: self)
        onTap?(location.x, bounds.width / 2)
    }
}
