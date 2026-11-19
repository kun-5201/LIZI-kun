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
/// 两形态共用的滑动切张阈值（CoverFlowView 的 56px）。
private let shelfSwipeThreshold: CGFloat = 56
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

    /// 滑动切张（两形态共用；方向和播放页 CoverFlow / 首页大卡一致：
    /// 左滑上一张、右滑下一张；阈值 56px，8px 内死区不抢点按）。
    private var shelfDragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onEnded { value in
                let dx = value.translation.width
                guard abs(dx) > shelfSwipeThreshold, viewModel.albums.count >= 2 else { return }
                if dx < 0 {
                    viewModel.selectPrevious()
                } else {
                    viewModel.selectNext()
                }
            }
    }

    /// 点一张进专辑页（约定：工人 A 的 `.album(platform:id:)` 路由）。
    private func openAlbum(_ album: Album?) {
        guard let album else { return }
        nav.show(.album(platform: album.source, id: album.id))
    }

    // MARK: - spine：侧立 3D 书架

    /// 侧立架可见窗口：选中张前后各 6 本（再远的不渲染，收藏再多也不堆视图）。
    private var visibleSpineIndices: [Int] {
        viewModel.albums.indices.filter { abs($0 - viewModel.selectedIndex) <= 6 }
    }

    private var spineShelf: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                ForEach(visibleSpineIndices, id: \.self) { index in
                    let album = viewModel.albums[index]
                    let offset = index - viewModel.selectedIndex
                    SpineBookView(album: album)
                        .opacity(spineOpacity(for: offset))
                        .scaleEffect(spineScale(for: offset))
                        .rotation3DEffect(
                            .degrees(spineAngle(for: offset)),
                            axis: (x: 0, y: 1, z: 0),
                            perspective: shelfPerspective
                        )
                        .offset(x: CGFloat(offset) * spineSpacing)
                        .zIndex(Double(100 - abs(offset)))
                        .onTapGesture { openAlbum(album) }
                        .animation(.easeOut(duration: 0.38), value: viewModel.selectedIndex)
                }
            }
            .frame(height: spineHeight + 20)
            .contentShape(Rectangle())
            .gesture(shelfDragGesture)
            // 架板：书脊底部落在这条线上
            RoundedRectangle(cornerRadius: 3)
                .fill(LiziTokens.ink.opacity(0.14))
                .frame(height: 6)
                .padding(.horizontal, 20)
        }
        .padding(.top, 8)
    }

    /// 扇开角（壳版 REF：fan ±22°、tanh 阻尼 0.85；符号和 CoverFlow 一致：
    /// 左边 +、右边 −，整排像扇子一样张开）。
    private func spineAngle(for offset: Int) -> Double {
        -spineFan * tanh(spineDamp * Double(offset))
    }

    private func spineScale(for offset: Int) -> CGFloat {
        switch abs(offset) {
        case 0: return 1.05
        case 1: return 0.98
        default: return 0.94
        }
    }

    private func spineOpacity(for offset: Int) -> Double {
        switch abs(offset) {
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
        }
        .frame(height: flowTrackHeight)
        .contentShape(Rectangle())
        .gesture(shelfDragGesture)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func flowItem(offset: Int) -> some View {
        let index = viewModel.selectedIndex + offset
        let album = viewModel.albums.indices.contains(index) ? viewModel.albums[index] : nil
        let metrics = flowMetrics(for: offset)

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
        .onTapGesture {
            if offset == 0 {
                // 点中间那张进专辑页
                openAlbum(album)
            } else if viewModel.albums.indices.contains(index) {
                // 点两侧切到中间
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

// MARK: - 首页入口卡（工人 D 放进 HomeView；本文件只提供组件，不改 HomeView）

/// 「我的专辑」入口卡：显示收藏数量，点按走 `nav.show(.myAlbums)`。
/// 有收藏时缩略图用第一张收藏专辑的封面；没有收藏时用书架图标 + 空态文案。
struct MyAlbumsEntryView: View {
    @EnvironmentObject private var nav: AppNavigation
    @State private var count: Int = 0
    @State private var firstCoverURL: URL?

    var body: some View {
        Button(action: { nav.show(.myAlbums) }) {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text("我的专辑")
                        .font(.liziBody(size: LiziTokens.size16, weight: .semibold))
                        .foregroundColor(LiziTokens.ink)
                    Text(count == 0 ? "还没有收藏专辑" : "已收藏 \(count) 张专辑")
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(LiziTokens.ink3)
            }
            .padding(16)
            .background(LiziTokens.paper2)
            .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count == 0 ? "我的专辑，还没有收藏专辑" : "我的专辑，已收藏 \(count) 张专辑")
        .onAppear { refresh() }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if count > 0 {
            CoverImageView(url: firstCoverURL, placeholderIconSize: 20)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
        } else {
            ZStack {
                Color.white
                Image(systemName: "books.vertical")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(LiziTokens.ink3)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
        }
    }

    private func refresh() {
        let albums = AlbumShelfStore.load()
        count = albums.count
        firstCoverURL = albums.first?.coverURL
    }
}
