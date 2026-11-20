import SwiftUI

/// 球面画廊（原生）：壳版 stage-pick（舞台页「形态长廊」弹窗）的 SwiftUI 版。
///
/// 壳版行为对照（app.js stage-pick 一节）：
/// - 球面排布、拖动旋转、惯性、点中开预览、预览里「进入这个形态」进舞台——
///   全部原生做，不套网页。
/// - 每格在壳版里是一个 live iframe（正面最多 5 个手机 / 10 个桌面并发，
///   9 秒超时变编号空壳）；原生侧 85 个 WebView 跑不动，改成每格一张
///   forms-labs/previews/<id>.jpg 静态预览图（长廊页同款图），读不到时退回
///   文字格（壳版失败空壳同款：只剩编号）。
/// - tab：全部 / 精选 / 分类；搜索按「编号 / 名字 / 描述」过滤；打开时把当前
///   形态转到正面（centerOnCell）。
/// - 精选 / 分类在壳版里就是空态（STAGES 没有任何 meta），原生侧同样空态，
///   不编假数据。
/// - 点「进入这个形态」：StageCatalog.saveFormId(id) + nav.show(.stage)，
///   进的是 P3-A 的 StageView（HUD 舞台），不是本目录的占位宿主。
/// - 没有舞台文件的形态不给进入按钮（StageCatalog.isAvailable 为假时预览里
///   明示；发行版 85 个全有文件。r26 起目录里已无无文件形态，该分支不再触发、
///   仅作防线保留，见 StageCatalog.isAvailable）。
///
/// 目录一律复用 P3-A 的 StageCatalog（menuList / matches / isAvailable），
/// 本文件不另造目录。
final class SphereGalleryViewModel: ObservableObject {
    /// yaw（经度方向旋转，弧度，无限取模）、pitch（纬度方向，夹 ±80°）。
    @Published private(set) var yaw: Double = 0
    @Published private(set) var pitch: Double = 0
    @Published private(set) var isDragging = false

    private var velYaw: Double = 0
    private var velPitch: Double = 0
    private var inertiaTimer: Timer?
    /// 本次拖动的累计位移（点按与拖动用 6pt 阈值区分，照抄壳版）。
    private(set) var dragDistance: CGFloat = 0
    /// 拖完 360ms 内屏蔽点击（壳版 pickSuppressClick）。
    private var suppressTapUntil = Date.distantPast

    deinit {
        inertiaTimer?.invalidate()
    }

    /// 把指定槽位转到正面（壳版 centerOnCell：yaw = 该格经度，pitch = 纬度）。
    func centerOn(slot: SphereMath.Slot?) {
        stopInertia()
        guard let slot else { return }
        yaw = slot.lon
        pitch = SphereMath.clampedPitch(slot.lat)
        velYaw = 0
        velPitch = 0
    }

    /// 拖动开始（壳版 onPickPointerDown：清速度、记起点）。
    func dragStarted() {
        stopInertia()
        isDragging = true
        dragDistance = 0
        velYaw = 0
        velPitch = 0
    }

    /// 拖动中（壳版 onPickPointerMove：yaw += dx*灵敏度，pitch += dy*灵敏度，
    /// 速度按 0.6 旧 + 0.4 新混合，夹在 ±0.008/ms）。
    func dragMoved(dx: CGFloat, dy: CGFloat, viewport: CGSize) {
        dragDistance += hypot(dx, dy)
        let yawSens = SphereMath.yawSensitivity(viewportWidth: viewport.width)
        let pitchSens = SphereMath.pitchSensitivity(viewportHeight: viewport.height)
        yaw = SphereMath.normalizedYaw(yaw + Double(dx) * yawSens)
        pitch = SphereMath.clampedPitch(pitch + Double(dy) * pitchSens)
        // 16.7ms 一帧的近似速度（DragGesture 不给逐帧时间戳，用固定帧长算）。
        let dt = 16.7
        let vy = (Double(dx) * yawSens) / dt
        let vp = (Double(dy) * pitchSens) / dt
        velYaw = max(-0.008, min(0.008, velYaw * 0.6 + vy * 0.4))
        velPitch = max(-0.008, min(0.008, velPitch * 0.6 + vp * 0.4))
    }

    /// 松手（壳版 onPickPointerUp：拖过就屏蔽 360ms 点击，惯性继续跑）。
    func dragEnded() {
        isDragging = false
        if dragDistance > 6 {
            suppressTapUntil = Date().addingTimeInterval(0.36)
        }
        startInertia()
    }

    /// 现在点按是否该被屏蔽（拖过 6pt 或拖完 360ms 内）。
    var tapSuppressed: Bool {
        Date() < suppressTapUntil || dragDistance > 6
    }

    private func startInertia() {
        stopInertia()
        guard abs(velYaw) > 0.00002 || abs(velPitch) > 0.00002 else { return }
        inertiaTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.inertiaStep()
        }
    }

    private func inertiaStep() {
        guard !isDragging else { stopInertia(); return }
        // 壳版 pickStep：每帧衰减 0.9^(dt/16.7)，速度归零即停。
        let dt = 1000.0 / 60
        yaw = SphereMath.normalizedYaw(yaw + velYaw * dt)
        pitch = SphereMath.clampedPitch(pitch + velPitch * dt)
        let decay = pow(0.9, dt / 16.7)
        velYaw *= decay
        velPitch *= decay
        if abs(velYaw) < 0.00002 { velYaw = 0 }
        if abs(velPitch) < 0.00002 { velPitch = 0 }
        if velYaw == 0 && velPitch == 0 { stopInertia() }
    }

    private func stopInertia() {
        inertiaTimer?.invalidate()
        inertiaTimer = nil
    }
}

struct SphereGalleryView: View {
    @EnvironmentObject private var nav: AppNavigation
    @EnvironmentObject private var store: StageFormStore
    @StateObject private var model = SphereGalleryViewModel()
    @State private var tab: GalleryTab = .all
    @State private var query = ""
    @State private var searchOpen = false
    @State private var previewing: StageForm?
    /// 本次拖动上一次的累计位移（DragGesture 只给累计值，逐帧增量要自己减）。
    @State private var lastTranslation: CGSize?

    /// tab + 搜索过滤后的列表（壳版 applyPickFilter：过滤后重建整颗球）。
    private var filteredForms: [StageForm] {
        let list = store.displayList.filter { tab.matches($0) }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return list }
        return list.filter { StageCatalog.matches($0, query: query) }
    }

    /// 副标题（壳版 updatePickSub 的两句文案原样搬）。
    private var subtitle: String {
        if tab == .all && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(store.displayList.count) 个形态 · 拖动旋转"
        }
        return "共 \(store.displayList.count) 个 · 匹配 \(filteredForms.count) 个"
    }

    /// 「全部」版的总数（P3-A menuList 全集，不含 classic）。
    private var allCount: Int {
        StageCatalog.menuList(includeClassic: false, releaseOnly: false).count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            sphereArea
        }
        .background(LiziTokens.paper)
        .onAppear {
            // 打开时把当前形态转到正面（壳版 applyPickFilter center:true）。
            let slots = SphereMath.slots(count: filteredForms.count)
            let idx = filteredForms.firstIndex { $0.formId == store.selectedFormId } ?? 0
            model.centerOn(slot: slots.indices.contains(idx) ? slots[idx] : nil)
        }
        .overlay {
            if let form = previewing {
                GalleryPreviewView(form: form) {
                    previewing = nil
                } onEnter: {
                    previewing = nil
                    store.select(form)
                    nav.show(.stage(formId: form.formId))
                }
            }
        }
    }

    // MARK: - 页头（tab / 搜索 / 版本开关 / 计数）

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text("形态长廊")
                    .font(.liziDisplay(size: LiziTokens.size20))
                    .foregroundColor(LiziTokens.ink)
                Spacer()
                Button(action: { searchOpen.toggle() }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(searchOpen ? LiziTokens.accent : LiziTokens.ink2)
                }
                .accessibilityLabel("搜索形态")
            }
            Text(subtitle)
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("形态筛选", selection: $tab) {
                ForEach(GalleryTab.allCases, id: \.self) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            Picker("版本", selection: $store.edition) {
                Text(GalleryEdition.release.title).tag(GalleryEdition.release)
                Text("\(GalleryEdition.dev.title) \(allCount) 个").tag(GalleryEdition.dev)
            }
            .pickerStyle(.segmented)
            if searchOpen {
                TextField("编号 / 名字 / 描述", text: $query)
                    .font(.liziBody(size: LiziTokens.size14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(LiziTokens.paper2)
                    .cornerRadius(LiziTokens.radius10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    // MARK: - 球面

    private var sphereArea: some View {
        GeometryReader { geometry in
            let viewport = geometry.size
            let slots = SphereMath.slots(count: filteredForms.count)
            ZStack {
                // 深色球场（壳版画廊是深色舞台，格子是亮面）。
                Color(hex: 0x0B0C12)
                if filteredForms.isEmpty {
                    VStack(spacing: 8) {
                        Text(tab.emptyTitle)
                            .font(.liziBody(size: LiziTokens.size16, weight: .semibold))
                            .foregroundColor(.white)
                        Text(tab.emptyDetail)
                            .font(.liziBody(size: LiziTokens.size13))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding()
                } else {
                    ForEach(Array(slots.enumerated()), id: \.element.formIndex) { index, slot in
                        let form = filteredForms[index]
                        let projection = SphereMath.project(
                            slot: slot, yaw: model.yaw, pitch: model.pitch, viewport: viewport)
                        if projection.visible {
                            SphereCellView(
                                form: form,
                                projection: projection,
                                isCurrent: form.formId == store.selectedFormId
                            ) {
                                guard !model.tapSuppressed else { return }
                                previewing = form
                            }
                            .position(projection.center)
                            .zIndex(projection.zIndex)
                        }
                    }
                }
            }
            .clipped()
            // simultaneousGesture：拖动与格子点按同时识别，点按与拖动靠
            // ViewModel 的 6pt 阈值 + 360ms 屏蔽区分（照抄壳版的 pointer 逻辑）；
            // 用 .gesture 会把格子的 Button 点按吞掉。
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !model.isDragging { model.dragStarted() }
                        model.dragMoved(dx: value.translation.width - (lastTranslation?.width ?? 0),
                                        dy: value.translation.height - (lastTranslation?.height ?? 0),
                                        viewport: viewport)
                        lastTranslation = value.translation
                    }
                    .onEnded { _ in
                        lastTranslation = nil
                        model.dragEnded()
                    }
            )
        }
    }
}

/// 球面上的一个格子：静态预览图 + 名字 / 编号（壳版 pickcell 的内容结构）。
/// 壳版格子是 live iframe；原生侧用长廊同款静态预览图，读不到图时退回文字格。
private struct SphereCellView: View {
    let form: StageForm
    let projection: SphereMath.Projection
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                if let image = form.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(hex: 0x23242E)
                }
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .top, endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(form.name)
                        .font(.liziBody(size: LiziTokens.size13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(form.formId)
                        .font(.liziMono(size: LiziTokens.size12))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(8)
                if !StageCatalog.isAvailable(form) {
                    Text("无文件")
                        .font(.liziBody(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: projection.size.width, height: projection.size.height)
            .clipped()
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isCurrent ? LiziTokens.accent : Color.white.opacity(0.25),
                            lineWidth: isCurrent ? 2 : 1)
            )
            .opacity(projection.opacity)
            .rotation3DEffect(
                .degrees(projection.rotateYDegrees),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.6
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(form.formId) · \(form.name)")
    }
}
