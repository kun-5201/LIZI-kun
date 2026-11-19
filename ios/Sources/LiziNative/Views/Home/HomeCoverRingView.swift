import SwiftUI
import UIKit

/// 首页 3D 封面环（r21）：平面跑马带常态 + 手势展开全屏 3D 圆环。
///
/// 视频逐帧规格（~/workspace/user/media_library/video/9e/9ee7dd02…3203.mp4，
/// 4.05s/30fps，逐帧图 ~/workspace/home3d-frames/f_001–f_041，10fps）：
/// - 0.0–0.9s：平面跑马带，两张大卡并排、歌名+歌手在下，自动向左慢滚
///   （实测 f_001→f_010：0.9s 左移 24 帧像素 ≈ 17pt ≈ 19pt/s；壳版
///   ring.js MARQUEE_SPEED=24，与原生跑马带默认 24→约 22px/s 同值）。
/// - 约 0.9–1.0s：上滑展开环（f_010 还是平面，f_011 环已展开约八成；
///   壳版 ring.js ENTER_MS=520 easeOutQuint，0.15s 即到 82%，吻合）。
/// - 1.0–1.5s：手指持续向左拖，环跟着转，中间依次是你的万水千山2026 →
///   南风北巷 → 荒 → 阴天快乐（每槽约 0.35–0.4s）。
/// - 约 1.5s 松手：惯性继续向左滑，约 2.1s 停在求你别离开我dj（动量
///   投影到目标槽位 + 弹簧吸附，见 releaseRing 一段）。
/// - 约 2.5s：松手 1s 到点，环 430ms 收回平面带（f_026 收回中，f_030
///   已回平面带）。
/// - 约 2.9s：点求你别离开我dj，播歌 + Hero 渐变成该首（f_030 渐变中，
///   f_034 完成）。
/// - 3.4s：用户切出 App。
/// - 环开着时全屏变暗：Hero 区平均亮度 63.2→38.1（约 0.60 倍），顶栏区
///   174.4→67.2（约 0.39 倍）——壳版 .mring 径向渐变（中心 0.40 →
///   56% 处 0.70 → 边缘 0.88）正好复现这个分布。
/// - 环卡下方每张都有歌名+歌手，底部居中提示「拖动旋转 · 点击播放 ·
///   松手收回」（视频原字；壳版 ring.js 的提示是「拖动旋转 · 点卡片播放」，
///   以视频为准）。
///
/// 壳版依据：public/m/ring.js（MobileRing）+ public/m/ring.css。运动模型
/// 原样照搬，只改视频里能量出来的两个尺寸（环卡、平面卡见下表）：
/// 平面带：MARQUEE_SPEED=24、松手 1200ms 后恢复、初画停 2.5s；
/// 开环：上滑（|dy|>|dx|×1.25 且 dy<0，超 10px），横向拖动只滚带；
/// 圆柱：pitch=卡宽×1.14（壳版）→ 视频实测 pitch≈卡宽（见下），R 取
/// 弦长公式；透视 P=3.2R；相机 translateZ(-R) rotateX(-5°)；
/// 拖动：每像素 180/(πR)×1.45 度；角速度取最近 110ms 采样，限幅
/// ±1400°/s；惯性 τ=1.08s，目标 = 离 (angle+v·τ·0.55) 最近的槽位；
/// 弹簧 118、阻尼 2√118（临界阻尼）；只露正面 facing≤0.06 藏，
/// 0.06–0.30 smoothstep 淡出；远端压暗 0.55·((1-facing)/2)^1.25；
/// 松手保持 1000ms 后收（430ms），点空白快收（220ms），明显下滑
/// （>90px）退出；点卡片播放并收回。
///
/// r20 与视频对不上的地方（本轮逐项改掉）：
/// 1. 常态：r20 永远是 3D 环；视频常态是平面跑马带，环只在手势期间出现。
/// 2. 自动滚动：r20 完全没有；视频平面态自动左滚。
/// 3. 触发：r20 横向滑动直接切歌（56px 阈值）；视频是上滑展开环，横向
///    拖动只滚跑马带。
/// 4. 环几何：r20 照抄播放页 CoverFlow（±40°/±50°、scale 0.91/0.85、
///    偏移 ±128/±224、带倒影）；视频是圆柱环、无倒影。
/// 5. 文字：r20 环上无任何文字；视频每张环卡下有歌名+歌手、底部有提示。
/// 6. 松手：r20 滑一下切一首、无惯性；视频松手惯性+弹簧吸附、保持 1s
///    后收回。
/// 7. 点封面：r20 点当前封面是播放/暂停切换、环不收回；视频点任意卡片
///    = 播放该首 + 收回环，Hero 渐变到该首。
/// 8. 顶部变暗：r20 没有；视频环开着时全屏径向变暗。
/// 9. 尺寸：r20 环卡 168/188/208（播放页 coverItem）；视频环卡约
///    0.39vw、平面卡约 0.51vw。
/// 10. 下滑退出：r20 无；视频/壳版环里明显下滑退出。
/// 11. 协调员小结的「圆环继续向左自动旋转」实为松手后的惯性滑向目标槽位
///     （1.5–2.2s）：壳版 ring.js 里环本身没有自动旋转，自动的只有平面
///     跑马带；本轮不给环加自动旋转。
///
/// 尺寸分档（r21：一档一套固定尺寸，不加任何 MagnificationGesture；
/// 视频实测，720px 原帧量取，档中宽 370/397/430pt）：
/// - 平面卡：卡宽 ≈ 0.51vw → compact 188 / standard 202 / large 220，
///   间距 16（f_001：两卡共占约 0.51vw，卡缝约 12–18px）。
/// - 环卡：卡宽 ≈ 0.39vw → compact 144 / standard 156 / large 168；
///   槽距 step 40°（侧卡实测倾角约 40°，f_014 左右卡均清晰可读，非
///   壳版公式在大卡下算出的 77°——视频版 R 更大）；pitch = 卡宽
///   （f_014 中心卡 231–513px、左右卡内缘距中心卡约 15–27px，无重叠）；
///   R = pitch / (2·sin 20°) ≈ 211 / 228 / 246。
/// - 7 个平台同一套环，不分平台分支。
///
/// 内容：队列优先、每日兜底（与 r20 同款），两份都空就不显示环、
/// 不编假封面；加载中 / 每日为空时显示与 DailyMarqueeView 同款文案。
/// 平面态保留原生浅色样式（DailyMarqueeView 同款：纸面底 + 墨字）——
/// 视频里深色每日卡是壳版样式，不在本轮改；环上不加「正在播」accent
/// 圈（视频里没有）。
/// HomeView 里的 DailyMarqueeView 调用已撤掉：环的平面态就是每日跑马带，
/// 两处并存会上下叠两条一样的带（DailyMarqueeView.swift 文件留着未删）。
///
/// 结构：状态机在 `HomeCoverRingModel`（HomeView 持有 @StateObject，
/// 平面带与全屏覆盖层共用）；`HomeCoverRingView` 只画平面带；
/// `HomeRingOverlayView` 是全屏覆盖层，由 HomeView 挂在根 VStack 的
/// `.overlay` 上（在 ScrollView 之外，变暗才能盖住 Hero/顶栏/平台条；
/// 挂在 ScrollView 里的子视图上会被 ScrollView 裁切）。
///
/// r22c 纠正（2026-11-20）：r21 的环只存在于代码里，真机上打不开——
/// 用户原话「没有这个功能，这个是以前网页套壳那个版本给你截图的」。
/// 根因（两处，都是手势在真机上根本到不了模型）：
/// 1. 平面带在竖向 ScrollView 里，上滑被 ScrollView 抢走去滚页面了：
///    SwiftUI `.simultaneousGesture` 拦不住 ScrollView 的竖滑。
///    壳版的等价物是 `.mstrip { touch-action: none; }`——带子拥有全部触摸。
///    本轮改成 UIKit `UIPanGestureRecognizer`（`StripTouchView`，见文件尾）：
///    `shouldBeRequiredToFailBy` 让 ScrollView 的 pan 等我们的 pan 先失败，
///    方向判定后下滑才自毁认输、把手势交还 ScrollView；上滑/横向由我们接管。
///    同一根手指从按下一路管到开环、转环、松手（壳版 window pointer 监听同款），
///    不再依赖「覆盖层半路出现后新 DragGesture 能接到旧触摸」这种不可靠行为。
/// 2. 覆盖层点卡用 `DragGesture(minimumDistance: 5)` 的 onEnded 判点按：
///    纯点按（位移 <5px）根本触发不了 DragGesture，点卡播歌是死的。
///    本轮点按改走 `.onTapGesture`（带位置），拖动仍走 DragGesture；
///    <5px=点按、≥5px=拖动，与壳版 RING_THRESHOLD=5 同款分界。
/// 另补两处截图对照：环卡歌名/歌手左对齐（r21 居中，截图 8 张全是左对齐，
/// 壳版 `.mring__name` 默认左对齐）；平面带下加可见入口（提示行 +「展开 3D 环」
/// 按钮，用户现在根本找不到环；按钮开环不接管手指，`beginDrag: false`）。
/// 拖动时顶部再暗一档（`isRingDragging` 驱动，视频：拖动时顶部大卡片变暗）。
/// 本轮只动本文件；播放页、闪退相关文件、HomeView.swift 一行不动。

// MARK: - 状态机

/// 首页环的状态机：平面跑马带 + 全屏圆环共用一份。
///
/// 手势入口有两处（同一根手指可以不断开）：平面带上的上滑（展开后继续拖
/// 就是转环，壳版 enterRing 同款）与覆盖层上的直接拖动；两处都调
/// `ringDragStart` / `ringDragMoved` / `ringDragEnded`。
@MainActor
final class HomeCoverRingModel: ObservableObject {
    enum RingPhase { case closed, open, closing }

    // MARK: 输入（HomeCoverRingView 从调用方同步进来）

    @Published var dailyTracks: [Track] = []
    @Published var queueTracks: [Track] = []
    @Published var isLoadingDaily = false
    @Published var dailyEmptyReason: String?
    @Published var marqueeSpeed: CGFloat = 24
    @Published var tier: PlayerTokens.PlayerSizeTier = .standard

    // MARK: 平面跑马带

    @Published var flatOffsetX: CGFloat = 0
    @Published var flatSetWidth: CGFloat = 0
    @Published var flatDragging = false
    @Published var flatDwellUntil = Date().addingTimeInterval(2.5)
    /// 平面带上的按压判定（非 Published：只在手势闭包里读写，不驱动渲染）。
    var stripPress: StripPress?

    // MARK: 环

    @Published var ringPhase: RingPhase = .closed
    /// 环转角（度）：0 = 锚点卡居中；向左拖为负，中心槽位随之向前。
    @Published var angle: CGFloat = 0
    /// 展开进度 0→1（ENTER_MS=520，easeOutQuint 近似）。
    @Published var entryT: CGFloat = 0
    /// 收回进度 0→1（CLOSE_MS=430 / 快收 220，easeInCubic 近似）。
    @Published var closeT: CGFloat = 0
    /// 覆盖层不透明度（展开 260ms 淡入，收回跟 closeT 走）。
    @Published var overlayOpacity: CGFloat = 0
    /// 平面带中心（"liziHome" 坐标空间 = 覆盖层本地坐标，用于环的纵向锚点）。
    @Published var stripCenter: CGPoint = .zero
    @Published var stripSize: CGSize = .zero

    /// 展开时的锚点卡下标（手指下最近的那张，壳版 nearestFlatIdx）。
    var anchorIndex = 0
    var ringDragging = false
    /// 正在拖动环（手指按下且在转环，或开环手指未抬起）：覆盖层顶部再暗一档。
    @Published var isRingDragging = false
    /// 开环时手指的纵坐标（平面带本地坐标），环里下滑退出用（>90px）。
    var ringOpenY: CGFloat = 0
    var ringStartAngle: CGFloat = 0
    var ringStartX: CGFloat = 0
    /// 最近 110ms 的（时间，转角）采样，用于松手角速度。
    var ringSamples: [(time: Date, angle: CGFloat)] = []
    /// 收回任务代号：新开环 / 新拖动即 +1，旧任务醒来发现代号变了就作废。
    var closeGeneration = 0

    var isRingOpen: Bool { ringPhase == .open }

    // MARK: 常量（壳版 ring.js 原值，见文件头）

    static let dragThreshold: CGFloat = 10       // 平面带上超 10px 才判方向
    static let ringThreshold: CGFloat = 5        // 环里超 5px 才算拖动
    static let holdMs: Double = 1000            // 松手后环保持多久再收
    static let enterMs: Double = 520             // 环展开
    static let closeMs: Double = 430             // 自动收回
    static let quickCloseMs: Double = 220        // 点空白快收
    static let tau: CGFloat = 1.08               // 惯性时间常数
    static let springStiffness: CGFloat = 118    // 弹簧
    static let maxVelocity: CGFloat = 1400       // 角速度限幅（度/秒）
    static let sampleMs: Double = 0.110          // 角速度采样窗
    static let dragGain: CGFloat = 1.45          // 拖动增益
    static let resumeMs: Double = 1200           // 平面带松手后多久恢复自动走
    static let initialDwell: Double = 2.5        // 初画/回卷后停多久再走
    static let dragResumeDwell: Double = 1.0     // 平面带拖动松手后停多久再走
    static let closeResumeMs: Double = 220       // 收回后多久恢复自动走
    static let swipeDownExit: CGFloat = 90       // 环里下滑超 90px 退出

    // MARK: 内容（队列优先、每日兜底）

    var useQueue: Bool { !queueTracks.isEmpty }

    var tracks: [Track] { useQueue ? queueTracks : dailyTracks }

    /// 调用方数据同步进来；曲目 id 集合变了（切台/重拉）才重置，
    /// 点歌进队列不改变 id 集合，不重置（壳版 setItems 同款语义）。
    func syncInputs(daily: [Track], queue: [Track], isLoading: Bool,
                    emptyReason: String?, speed: CGFloat,
                    tier: PlayerTokens.PlayerSizeTier) {
        let oldIDs = tracks.map(\.id)
        dailyTracks = daily
        queueTracks = queue
        isLoadingDaily = isLoading
        dailyEmptyReason = emptyReason
        marqueeSpeed = speed
        self.tier = tier
        if tracks.map(\.id) != oldIDs {
            if ringPhase != .closed { closeRing() }
            flatOffsetX = 0
            flatDwellUntil = Date().addingTimeInterval(Self.initialDwell)
        }
    }

    // MARK: 尺寸（视频实测，见文件头分档表）

    /// 平面卡宽：compact 188 / standard 202 / large 220（≈0.51vw）。
    var flatCard: CGFloat {
        switch tier {
        case .compact: return 188
        case .standard: return 202
        case .large: return 220
        }
    }

    var flatGap: CGFloat { 16 }

    var flatPitch: CGFloat { flatCard + flatGap }

    /// 平面带高：卡 + 间距 7 + 歌名行 + 间距 7 + 歌手行。
    var flatHeight: CGFloat { flatCard + 49 }

    /// 环卡宽：compact 144 / standard 156 / large 168（≈0.39vw）。
    var ringCard: CGFloat {
        switch tier {
        case .compact: return 144
        case .standard: return 156
        case .large: return 168
        }
    }

    /// 相邻槽位夹角 40°（视频实测侧卡倾角）。
    var ringStep: CGFloat { 40 }

    /// 槽距 = 卡宽（视频实测：中心卡与侧卡内缘约 15–27px 间隙，无重叠）。
    var ringPitch: CGFloat { ringCard }

    /// 圆柱半径（弦长公式 pitch = 2R·sin(step/2)）。
    var ringRadius: CGFloat {
        ringPitch / (2 * sin(ringStep * .pi / 360))
    }

    /// 每像素转角度数（壳版：180/(πR)×1.45）。
    var ringPerPixel: CGFloat {
        (180 / (.pi * ringRadius)) * Self.dragGain
    }

    /// 环卡总高：封面 + 间距 5 + 歌名行 + 间距 2 + 歌手行。
    var ringCardHeight: CGFloat { ringCard + 35 }

    // MARK: 平面跑马带

    func tickFlat() {
        guard !tracks.isEmpty, flatSetWidth > 0, !flatDragging,
              ringPhase == .closed, Date() >= flatDwellUntil else { return }
        flatOffsetX = normalizedFlat(flatOffsetX - marqueeSpeed / 30)
    }

    /// 把偏移收进 (-setWidth, 0]，两份循环无缝（DailyMarqueeView 同款）。
    func normalizedFlat(_ x: CGFloat) -> CGFloat {
        guard flatSetWidth > 0 else { return x }
        var v = x
        while v > 0 { v -= flatSetWidth }
        while v <= -flatSetWidth { v += flatSetWidth }
        return v
    }

    /// 手指 x 处最近的平面卡下标（壳版 nearestFlatIdx）。
    func anchorNearestFlatCard(x: CGFloat) -> Int {
        guard !tracks.isEmpty, flatPitch > 0 else { return 0 }
        let pos = (x - flatCard / 2 - flatOffsetX) / flatPitch
        return mod(Int(pos.rounded()), tracks.count)
    }

    /// 平面带正中间那张卡的下标（入口按钮开环的锚点）。
    func centerCardIndex() -> Int {
        guard !tracks.isEmpty else { return 0 }
        let cx = stripSize.width > 0 ? stripSize.width / 2 : flatCard / 2
        return anchorNearestFlatCard(x: cx)
    }

    // MARK: 平面带触摸状态机（壳版 ring.js onPressMove strip 分支，
    // 由 StripTouchView 的 UIPanGestureRecognizer 驱动；x/y 均为平面带本地坐标）

    /// 平面带触摸的移动结果：`.failGesture` = 竖向占优且向下，
    /// 识别器自毁、把手势交还 ScrollView（壳版「下滑 = 交还页面」同款）。
    enum StripMoveOutcome {
        case handled
        case failGesture
    }

    /// 手指按下（pan .began）：记按压起点；旧 press 残留（上一根手势被系统
    /// 打断没走到 ended）直接作废重建，否则下次拖动会跳变。
    func stripTouchBegan(x: CGFloat, y: CGFloat) {
        guard ringPhase == .closed else { return }
        stripPress = StripPress(
            startX: x, startY: y,
            baseOffset: flatOffsetX, decided: .undecided
        )
    }

    /// 手指移动（pan .changed）：
    /// - 环已开（同一根手指）：先判下滑退出（相对开环点 dy>90 且竖向占优），
    ///   否则继续转环；
    /// - 10px 内不判方向；竖向占优（|dy|>|dx|×1.25）且向上 → 开环（锚点=
    ///   手指下最近的卡，手指不抬起继续拖就是转环）；竖向占优且向下 →
    ///   `.failGesture`（识别器自毁，ScrollView 接管滚页面）；
    /// - 横向占优 → 1:1 滚跑马带，不开环。
    func stripTouchMoved(x: CGFloat, y: CGFloat) -> StripMoveOutcome {
        if ringPhase == .open {
            if ringDragging {
                let dx = x - ringStartX
                let dy = y - ringOpenY
                if dy > Self.swipeDownExit, abs(dy) > abs(dx) * 1.25 {
                    closeRing()
                    return .handled
                }
            }
            ringDragMoved(toX: x)
            return .handled
        }
        guard ringPhase == .closed else { return .handled }
        if stripPress == nil {
            stripPress = StripPress(
                startX: x, startY: y,
                baseOffset: flatOffsetX, decided: .undecided
            )
            return .handled
        }
        guard var press = stripPress else { return .handled }
        let dx = x - press.startX
        let dy = y - press.startY
        if press.decided == .undecided {
            if hypot(dx, dy) < Self.dragThreshold { return .handled }
            if abs(dy) > abs(dx) * 1.25 {
                if dy < 0 {
                    let anchor = anchorNearestFlatCard(x: x)
                    openRing(anchor: anchor, atX: x, atY: y)
                    press.decided = .openedRing
                    stripPress = press
                } else {
                    press.decided = .vertical
                    stripPress = press
                    return .failGesture
                }
                return .handled
            }
            press.decided = .horizontal
            stripPress = press
        }
        if press.decided == .horizontal {
            flatDragging = true
            flatOffsetX = normalizedFlat(press.baseOffset + dx)
        }
        return .handled
    }

    /// 手指抬起 / 手势取消（pan .ended/.cancelled，壳版 onPressUp/onPressCancel
    /// strip 分支同款：环开着 = 松手走惯性+弹簧吸附，带子拖动 = 停 1.0s 再走）。
    func stripTouchEnded() {
        defer { stripPress = nil }
        if ringPhase == .open {
            ringDragEnded()
            return
        }
        if flatDragging {
            flatDragging = false
            flatDwellUntil = Date()
                .addingTimeInterval(Self.dragResumeDwell)
        }
    }

    // MARK: 开环 / 收回

    /// 开环。
    /// - `beginDrag: true`（平面带上滑）：展开这根手指不用抬起，直接记为
    ///   拖动起点，继续拖就是转环（壳版 enterRing 同款；同一根手指的后续移动
    ///   由平面带的 `StripTouchView` 接着转发，不走覆盖层新挂的手势）。
    /// - `beginDrag: false`（入口按钮点按）：只展开、不接管手指；下一根
    ///   手指落在覆盖层上时由覆盖层手势重新 `ringDragStart`（liziHome 坐标，
    ///   与本轮的 `ringStartX` 不混用——一根拖动内的 x 必须同一坐标系）。
    func openRing(anchor: Int, atX x: CGFloat, atY y: CGFloat = 0, beginDrag: Bool = true) {
        guard ringPhase == .closed, !tracks.isEmpty else { return }
        anchorIndex = tracks.indices.contains(anchor) ? anchor : 0
        angle = 0
        entryT = 0
        closeT = 0
        overlayOpacity = 0
        ringPhase = .open
        ringDragging = false // 上次拖动若被系统打断残留了 true，先清掉再起新拖动
        isRingDragging = false
        ringOpenY = y
        closeGeneration += 1
        // 展开 520ms（easeOutQuint 近似 timingCurve(0.22,1,0.36,1)），
        // 覆盖层 260ms 淡入（壳版 .mring transition opacity .26s）。
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: Self.enterMs / 1000)) {
            entryT = 1
        }
        withAnimation(.easeOut(duration: 0.26)) {
            overlayOpacity = 1
        }
        // 展开这根手指不用抬起：直接记为拖动起点，继续拖就是转环。
        if beginDrag {
            ringDragStart(x: x)
        }
    }

    /// 收回：430ms（点空白 220ms 快收），收完 phase=.closed，平面带
    /// 220ms 后恢复自动走（壳版 finishClose 同款）。
    func closeRing(quick: Bool = false) {
        guard ringPhase == .open else { return }
        ringPhase = .closing
        closeGeneration += 1
        ringDragging = false
        isRingDragging = false
        closeT = 0
        let ms = quick ? Self.quickCloseMs : Self.closeMs
        withAnimation(.timingCurve(0.32, 0, 0.67, 0, duration: ms / 1000)) {
            closeT = 1
        }
        withAnimation(.easeOut(duration: ms / 1000)) {
            overlayOpacity = 0
        }
        let gen = closeGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000) + 140_000_000)
            guard gen == self.closeGeneration else { return }
            self.ringPhase = .closed
            self.entryT = 0
            self.closeT = 0
            self.flatDwellUntil = Date().addingTimeInterval(Self.closeResumeMs / 1000)
        }
    }

    // MARK: 环拖动 / 松手

    func ringDragStart(x: CGFloat) {
        guard ringPhase == .open, !ringDragging else { return }
        ringDragging = true
        isRingDragging = true
        ringStartAngle = angle
        ringStartX = x
        ringSamples = [(Date(), angle)]
        closeGeneration += 1
    }

    func ringDragMoved(toX x: CGFloat) {
        guard ringPhase == .open, ringDragging else { return }
        angle = ringStartAngle + (x - ringStartX) * ringPerPixel
        let now = Date()
        ringSamples.append((now, angle))
        while ringSamples.count > 2,
              now.timeIntervalSince(ringSamples[0].time) > Self.sampleMs {
            ringSamples.removeFirst()
        }
    }

    /// 松手：最近 110ms 角速度（限幅 ±1400°/s）投影目标槽位，
    /// 临界阻尼弹簧（stiffness 118 → response ≈ 2π/√118 ≈ 0.58s）
    /// 吸附到最近槽位中心；随后保持 1000ms 再收回。
    /// 与壳版唯一差别：SwiftUI spring 不吃初速度，初速度已折进目标槽位
    /// （projected），弹簧只负责走过去，不另做 overshoot。
    func ringDragEnded() {
        guard ringPhase == .open else { return }
        ringDragging = false
        isRingDragging = false
        let now = Date()
        var v: CGFloat = 0
        if ringSamples.count > 1 {
            while ringSamples.count > 2,
                  now.timeIntervalSince(ringSamples[0].time) > Self.sampleMs {
                ringSamples.removeFirst()
            }
            let first = ringSamples[0]
            let last = ringSamples[ringSamples.count - 1]
            let span = last.time.timeIntervalSince(first.time)
            let idle = now.timeIntervalSince(last.time)
            if idle <= 0.080, span > 0.008 {
                v = max(-Self.maxVelocity,
                        min(Self.maxVelocity, (last.angle - first.angle) / CGFloat(span)))
            }
        }
        var projected = angle + v * Self.tau * 0.55
        if abs(v) < 1 {
            let moved = angle - ringStartAngle
            if abs(moved) >= ringStep * 0.22 {
                projected += (moved > 0 ? 1 : -1) * ringStep * 0.28
            }
        }
        let targetAngle = -CGFloat(Int((-projected / ringStep).rounded())) * ringStep
        if abs(targetAngle - angle) < 1e-6, abs(v) < 1 {
            angle = targetAngle
        } else {
            withAnimation(.spring(response: 0.58, dampingFraction: 1.0)) {
                angle = targetAngle
            }
        }
        scheduleHoldClose()
    }

    /// 松手 1000ms 后收回；中途再拖动即作废（代号 +1）。
    func scheduleHoldClose() {
        closeGeneration += 1
        let gen = closeGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard gen == self.closeGeneration,
                  self.ringPhase == .open, !self.ringDragging else { return }
            self.closeRing()
        }
    }

    // MARK: 点播

    /// 点卡片播歌：队列模式只改下标（已在队列里不重建），每日模式整份
    /// 进队列从点中的起播（壳版 playQueue(items, i, true) 同款）。
    func playTrack(at index: Int, store: PlaybackStore) {
        guard tracks.indices.contains(index) else { return }
        if useQueue {
            store.play(tracks[index])
        } else {
            store.setQueue(tracks, startAt: index)
        }
    }

    /// 点环卡：播歌 + 收回环（壳版 selectItem 同款）。
    func tapRingCard(trackIndex: Int, store: PlaybackStore) {
        playTrack(at: trackIndex, store: store)
        closeRing()
    }

    // MARK: 环几何（纯函数，供覆盖层逐卡计算）

    struct RingSlot: Identifiable {
        var id: Int { s }
        /// 整数槽位（相对锚点）。
        let s: Int
        /// 该槽相对正前方的世界角（度），-86.5…+86.5。
        let world: CGFloat
        let trackIndex: Int
    }

    /// 可见槽位：|world| ≤ 86.5°（facing > 0.06），同一首歌只出现一次
    /// （曲目 < 5 首时不复制，壳版 n = min(曲数, 环容量) 同款）。
    func visibleSlots() -> [RingSlot] {
        guard !tracks.isEmpty else { return [] }
        let q = -angle / ringStep
        let center = Int(q.rounded())
        var seen = Set<Int>()
        var out: [RingSlot] = []
        for s in (center - 2)...(center + 2) {
            let world = (CGFloat(s) - q) * ringStep
            guard abs(world) <= 86.5 else { continue }
            let idx = mod(anchorIndex + s, tracks.count)
            guard !seen.contains(idx) else { continue }
            seen.insert(idx)
            out.append(RingSlot(s: s, world: world, trackIndex: idx))
        }
        return out
    }

    /// 展开/收回中的有效半径（壳版 renderRing：R·(0.42+0.58·entry)·(1-0.66·close)）。
    func effectiveRadius() -> CGFloat {
        ringRadius * (0.42 + 0.58 * entryT) * (1 - 0.66 * closeT)
    }

    /// 相机缩放（壳版：(0.74+0.26·entry)·(1-0.55·close)）。
    func cameraScale() -> CGFloat {
        (0.74 + 0.26 * entryT) * (1 - 0.55 * closeT)
    }

    /// 正面朝向 0…1（world=0 正对，world=±90 侧对）。
    func facing(forWorld world: CGFloat) -> CGFloat {
        cos(world * .pi / 180)
    }

    /// 背面藏、近背面 smoothstep 淡出（壳版 renderRing 同款）。
    func facingOpacity(facing: CGFloat) -> Double {
        if facing <= 0.06 { return 0 }
        if facing < 0.30 {
            let q = Double((facing - 0.06) / 0.24)
            return q * q * (3 - 2 * q)
        }
        return 1
    }

    /// 远端压暗（壳版：0.55·((1-facing)/2)^1.25）。
    func shadeOpacity(facing: CGFloat) -> Double {
        0.55 * pow(Double((1 - facing) / 2), 1.25)
    }

    /// 透视缩放 P=3.2R：scale = 3.2 / (3.2 + (1-facing))。
    func depthScale(facing: CGFloat) -> CGFloat {
        3.2 / (3.2 + (1 - facing))
    }

    /// 点按命中：取包含该点、离正前方最近的卡（壳版 onPressUp 点选同款，
    /// 用包围盒近似旋转后的卡）。
    func hitTestRingCard(at point: CGPoint, screenWidth: CGFloat) -> Int? {
        let cx = screenWidth / 2
        let cy = stripCenter.y
        let r = effectiveRadius()
        var best: (index: Int, world: CGFloat)?
        for slot in visibleSlots() {
            let x = cx + r * sin(slot.world * .pi / 180)
            let halfW = ringCard * 0.55
            let halfH = ringCardHeight / 2
            if abs(point.x - x) <= halfW, abs(point.y - cy) <= halfH {
                if best == nil || abs(slot.world) < abs(best!.world) {
                    best = (slot.trackIndex, slot.world)
                }
            }
        }
        return best?.index
    }

    private func mod(_ v: Int, _ m: Int) -> Int {
        ((v % m) + m) % m
    }
}

/// 平面带按压判定。
struct StripPress {
    var startX: CGFloat
    var startY: CGFloat
    var baseOffset: CGFloat
    var decided: StripDecision
}

enum StripDecision {
    case undecided
    case horizontal
    case vertical
    case openedRing
}

// MARK: - 平面带（常态）

struct HomeCoverRingView: View {
    @EnvironmentObject private var playback: PlaybackStore
    @ObservedObject var model: HomeCoverRingModel

    /// 每日推荐曲目（调用方传 `viewModel.daily.map { $0.track }`）。
    var dailyTracks: [Track] = []
    var isLoadingDaily = false
    var dailyEmptyReason: String?
    /// 跑马带速度（调用方传 `viewModel.marqSpeedPxPerSecond`，默认 24）。
    var marqueeSpeed: CGFloat = 24
    /// 尺寸档（调用方按实测屏宽经 `PlayerTokens.sizeTier(for:topInset:)` 传入）。
    var tier: PlayerTokens.PlayerSizeTier = .standard

    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if model.tracks.isEmpty {
                if model.isLoadingDaily {
                    loadingView
                } else {
                    emptyView
                }
            } else {
                // 平面带 + 入口提示行（r22c）：提示行与「展开 3D 环」按钮是环的
                // 可见入口——用户现在根本找不到环，光靠上滑手势不够。
                VStack(alignment: .leading, spacing: 6) {
                    flatStrip
                    entryHintRow
                }
            }
        }
        .onAppear { sync() }
        .onChange(of: dailyTracks.map(\.id)) { _ in sync() }
        .onChange(of: playback.queue.map { $0.track.id }) { _ in sync() }
        .onChange(of: isLoadingDaily) { _ in sync() }
        .onChange(of: dailyEmptyReason) { _ in sync() }
        .onChange(of: marqueeSpeed) { _ in sync() }
        .onChange(of: tier) { _ in sync() }
        .onReceive(timer) { _ in model.tickFlat() }
        .accessibilityLabel("封面环")
    }

    private func sync() {
        model.syncInputs(
            daily: dailyTracks,
            queue: playback.queue.map { $0.track },
            isLoading: isLoadingDaily,
            emptyReason: dailyEmptyReason,
            speed: marqueeSpeed,
            tier: tier
        )
    }

    // MARK: 加载 / 空态（DailyMarqueeView 同款文案）

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("正在拉取每日推荐…")
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
        }
        .frame(maxWidth: .infinity, minHeight: model.flatHeight, alignment: .center)
    }

    private var emptyView: some View {
        Text(model.dailyEmptyReason ?? "暂无推荐内容。")
            .font(.liziBody(size: LiziTokens.size13))
            .foregroundColor(LiziTokens.ink3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: model.flatHeight, alignment: .center)
            .padding(.horizontal, 24)
    }

    // MARK: 平面跑马带

    /// 平面带 + 入口提示行。
    ///
    /// 触摸走 `StripTouchView`（UIKit UIPanGestureRecognizer，见文件尾）：
    /// SwiftUI `.simultaneousGesture(DragGesture)` 在真机上拦不住 ScrollView
    /// 的竖滑——上滑开环的手势会被页面滚动抢走，环打不开（r21 的根因）。
    /// 触摸层盖在卡片上方（卡片不再是 Button，点按由识别器的 tap 接管，
    /// VoiceOver 激活走各卡的 `.accessibilityAction`）。
    private var flatStrip: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: model.flatGap) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: model.flatGap) {
                        ForEach(model.tracks.indices, id: \.self) { i in
                            FlatRingCard(track: model.tracks[i], width: model.flatCard) {
                                model.playTrack(at: i, store: playback)
                            }
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: FlatSetWidthKey.self, value: geo.size.width)
                        }
                    )
                }
            }
            .offset(x: model.flatOffsetX)
            .onPreferenceChange(FlatSetWidthKey.self) { model.flatSetWidth = $0 + model.flatGap }
            // 触摸层：盖住整条带，坐标与旧 DragGesture 的 .local 一致
            // （容器原点 = 带原点，卡片偏移由 flatOffsetX 换算，见 anchorNearestFlatCard）。
            StripTouchView(model: model) { idx in
                model.playTrack(at: idx, store: playback)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: model.flatHeight, alignment: .top)
        .clipped()
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: StripCenterKey.self,
                    value: proxy.frame(in: .named("liziHome"))
                )
            }
        )
        .onPreferenceChange(StripCenterKey.self) { rect in
            model.stripCenter = CGPoint(x: rect.midX, y: rect.midY)
            model.stripSize = rect.size
        }
    }

    /// 入口提示行：左 = 手势提示，右 = 点按入口（「展开 3D 环」按钮，
    /// 锚点 = 带子正中间那张卡；开环不接管手指，`beginDrag: false`）。
    private var entryHintRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .semibold))
            Text("上滑展开 3D 环 · 拖动旋转")
                .font(.liziBody(size: LiziTokens.size12))
            Spacer()
            Button(action: {
                model.openRing(anchor: model.centerCardIndex(), atX: 0, beginDrag: false)
            }) {
                HStack(spacing: 4) {
                    Text("展开 3D 环")
                        .font(.liziBody(size: LiziTokens.size12, weight: .medium))
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(LiziTokens.paper2)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("展开 3D 封面环")
        }
        .foregroundColor(LiziTokens.ink3)
    }
}

/// 平面带里的一张卡：封面 + 歌名 + 歌手（DailyMarqueeView.MarqueeCard 同款，
/// 宽按档走 188/202/220）。
///
/// 不是 Button：带子的触摸层（`StripTouchView`，盖在卡片上方）统一接管点按；
/// Button 和识别器的 tap 会双重触发。VoiceOver 激活走 `.accessibilityAction`。
private struct FlatRingCard: View {
    let track: Track
    let width: CGFloat
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            CoverImageView(url: track.coverURL, placeholderIconSize: 64)
                .frame(width: width, height: width)
                .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
            Text(track.title)
                .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                .foregroundColor(LiziTokens.ink)
                .lineLimit(1)
            Text(track.artist)
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("播放：\(track.title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
    }
}

private struct FlatSetWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct StripCenterKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - 全屏环覆盖层（展开态）

/// 全屏环覆盖层（壳版 .mring：position:fixed inset:0）。
/// 由 HomeView 挂在根 VStack 的 `.overlay` 上（ScrollView 之外），
/// 内容：径向变暗 + 圆柱环（中心对准平面带原位置）+ 底部提示。
struct HomeRingOverlayView: View {
    @EnvironmentObject private var playback: PlaybackStore
    @ObservedObject var model: HomeCoverRingModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 全屏径向变暗（壳版 .mring 背景；中心 50% 48%）。
                radialScrim(size: geo.size)
                // 拖动时顶部再暗一档（视频：拖动时顶部大卡片变暗；常态开环
                // 已有上面的径向变暗，这一层只在手指转环时出现）。
                LinearGradient(
                    gradient: Gradient(colors: [
                        .black.opacity(0.14), .black.opacity(0.0),
                    ]),
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: geo.size.height * 0.55)
                .frame(maxHeight: .infinity, alignment: .top)
                .opacity(model.isRingDragging ? 1 : 0)
                // 圆柱环。
                ringLayer(screenWidth: geo.size.width, screenHeight: geo.size.height)
                // 底部提示（视频原字；壳版 .mring__hint：bottom max(16, safe+10)）。
                VStack {
                    Spacer()
                    Text("拖动旋转 · 点击播放 · 松手收回")
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.74))
                        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 1)
                        .padding(.bottom, max(16, geo.safeAreaInsets.bottom + 10))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .opacity(model.overlayOpacity)
            .gesture(ringGesture(screenWidth: geo.size.width))
            // 点按走 TapGesture（带位置）：r21 的 DragGesture(minimumDistance: 5)
            // 的 onEnded 判点按是死的——纯点按（位移 <5px）根本触发不了
            // DragGesture，点卡播歌到不了模型。<5px=点按、≥5px=拖动，
            // 与壳版 RING_THRESHOLD=5 同款分界；两者互斥，不会双重触发。
            .onTapGesture(count: 1, coordinateSpace: .named("liziHome")) { location in
                guard model.ringPhase == .open else { return }
                if let idx = model.hitTestRingCard(at: location, screenWidth: geo.size.width) {
                    model.tapRingCard(trackIndex: idx, store: playback)
                } else {
                    model.closeRing(quick: true)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func radialScrim(size: CGSize) -> some View {
        let dark = Color(red: 9 / 255, green: 10 / 255, blue: 16 / 255)
        let darker = Color(red: 5 / 255, green: 6 / 255, blue: 10 / 255)
        return RadialGradient(
            gradient: Gradient(stops: [
                .init(color: dark.opacity(0.40), location: 0),
                .init(color: dark.opacity(0.70), location: 0.56),
                .init(color: darker.opacity(0.88), location: 1),
            ]),
            center: UnitPoint(x: 0.5, y: 0.48),
            startRadius: 0,
            endRadius: max(size.width, size.height) * 0.62
        )
    }

    /// 圆柱环：容器框在环中心（平面带中心），卡按世界角排布；
    /// 容器整体 rotateX(-5°)（壳版 camera 同款），转轴就是环中心。
    private func ringLayer(screenWidth: CGFloat, screenHeight: CGFloat) -> some View {
        let cy = model.stripCenter.y > 0 ? model.stripCenter.y : screenHeight * 0.62
        let cx = screenWidth / 2
        let r = model.effectiveRadius()
        let cam = model.cameraScale()
        return ZStack {
            ForEach(model.visibleSlots()) { slot in
                let track = model.tracks[slot.trackIndex]
                let facing = model.facing(forWorld: slot.world)
                let x = cx + r * sin(slot.world * .pi / 180)
                RingCardView(
                    track: track,
                    width: model.ringCard,
                    shadeOpacity: model.shadeOpacity(facing: facing)
                )
                .scaleEffect(model.depthScale(facing: facing) * cam)
                .rotation3DEffect(
                    .degrees(-Double(slot.world)),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.5
                )
                .opacity(model.facingOpacity(facing: facing))
                .position(x: x, y: model.ringCardHeight / 2)
                .zIndex(Double(100 - abs(slot.world)))
                .accessibilityLabel("播放：\(track.title)")
            }
        }
        .frame(width: screenWidth, height: model.ringCardHeight)
        .rotation3DEffect(
            .degrees(-5),
            axis: (x: 1, y: 0, z: 0),
            perspective: 0.5
        )
        .position(x: cx, y: cy)
    }

    /// 环手势（壳版 ring.js onPressMove/onPressUp ring 分支）：
    /// - 5px 死区；明显下滑（dy>90 且 |dy|>|dx|×1.25）→ 退出环；
    /// - 横向拖动 → 转环（松手走惯性+弹簧吸附，见 model.ringDragEnded）；
    /// - 点按不走这里（见 `.onTapGesture`）：DragGesture 的 onEnded 收不到
    ///   <5px 的纯点按，r21 在这里判点按是死的，本轮删掉。
    /// 坐标空间用 .named("liziHome")：点按位置与环锚点 stripCenter
    /// 在同一坐标系里比（.global 在有导航栏偏移时会错位）。
    private func ringGesture(screenWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("liziHome"))
            .onChanged { value in
                guard model.ringPhase == .open else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if !model.ringDragging {
                    if dy > HomeCoverRingModel.swipeDownExit,
                       abs(dy) > abs(dx) * 1.25 {
                        model.closeRing()
                        return
                    }
                    if hypot(dx, dy) < HomeCoverRingModel.ringThreshold { return }
                    model.ringDragStart(x: value.location.x)
                }
                model.ringDragMoved(toX: value.location.x)
            }
            .onEnded { _ in
                guard model.ringPhase == .open else { return }
                if model.ringDragging {
                    model.ringDragEnded()
                }
            }
    }
}

/// 环里的一张卡：封面 + 歌名 + 歌手（壳版 .mring__card：封面下只写歌名；
/// 视频里歌名下还有歌手，加一行；压暗只盖封面，文字保持可读）。
///
/// r22c：文字左对齐——8 张截图里每张环卡的歌名/歌手都从卡片左缘起
/// （r21 的居中与截图不符；壳版 `.mring__name` 也是默认左对齐）。
private struct RingCardView: View {
    let track: Track
    let width: CGFloat
    let shadeOpacity: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            CoverImageView(url: track.coverURL, placeholderIconSize: 48)
                .frame(width: width, height: width)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(shadeOpacity))
                )
                .shadow(color: .black.opacity(0.8), radius: 26, x: 0, y: 12)
            Text(track.title)
                .font(.liziBody(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.55), radius: 8, x: 0, y: 1)
            Text(track.artist)
                .font(.liziBody(size: 11))
                .foregroundColor(.white.opacity(0.62))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.55), radius: 8, x: 0, y: 1)
        }
        .frame(width: width, alignment: .leading)
    }
}

// MARK: - 平面带触摸层（r22c，UIKit）

/// 平面带的触摸层：一个透明 UIView，盖在跑马带卡片上方，接管带子上的
/// 全部触摸（点按 + 横向滚带 + 上滑开环 + 开环后继续转环）。
///
/// 为什么不用 SwiftUI DragGesture（r21 的教训）：带子在竖向 ScrollView 里，
/// `.simultaneousGesture(DragGesture)` 在真机上拦不住 ScrollView 的竖滑——
/// 上滑开环的手势会被页面滚动抢走，`openRing` 根本到不了，环打不开。
/// 壳版的等价物是 `.mstrip { touch-action: none; }`（见 public/m/m.css），
/// 即带子拥有全部触摸；这里用 UIKit 识别器复刻同一条语义：
/// - `shouldBeRequiredToFailBy`：ScrollView 的 pan 必须等我们的 pan 先失败
///   才开始滚页面——上滑/横向由我们接管，页面滚不动；
/// - 方向判定后是竖向下滑：我们的 pan 自毁（`isEnabled` 开关一次），
///   ScrollView 接管，页面接着滚（壳版「下滑 = 交还页面」同款）；
/// - 同一根手指从按下一路管到开环、转环、松手（壳版 window pointer 监听
///   同款），不依赖「覆盖层半路出现后新 DragGesture 能接到旧触摸」。
///
/// 坐标：识别器报的是本视图本地坐标，与旧 DragGesture 的 `.local` 一致
/// （容器原点 = 带原点；卡片偏移由 `flatOffsetX` 换算，见 `anchorNearestFlatCard`）。
struct StripTouchView: UIViewRepresentable {
    @ObservedObject var model: HomeCoverRingModel
    /// 点按某张卡（下标由识别器用 `anchorNearestFlatCard` 算出）。
    var onTapCard: (Int) -> Void

    @MainActor
    func makeUIView(context: Context) -> StripTouchUIView {
        let view = StripTouchUIView()
        view.model = model
        view.onTapCard = onTapCard
        return view
    }

    @MainActor
    func updateUIView(_ uiView: StripTouchUIView, context: Context) {
        uiView.model = model
        uiView.onTapCard = onTapCard
    }
}

/// 平面带触摸的 UIKit 宿主视图（主线程；手势回调都在主线程进模型）。
@MainActor
final class StripTouchUIView: UIView, UIGestureRecognizerDelegate {
    weak var model: HomeCoverRingModel?
    var onTapCard: ((Int) -> Void)?

    private lazy var pan: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var tap: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        recognizer.delegate = self
        // 点按只在 pan 没认出来时才算（带一点位移的轻触按拖动走，不双重触发）。
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

    // MARK: 识别器委托

    /// ScrollView 的 pan 必须等我们的 pan 先失败：上滑/横向由我们接管，
    /// 页面滚不动；只有我们判定为竖向下滑而自毁后，页面才接着滚。
    /// （壳版 `.mstrip { touch-action: none; }` 的 UIKit 等价物。）
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === pan,
              otherGestureRecognizer is UIPanGestureRecognizer,
              otherGestureRecognizer.view is UIScrollView
        else { return false }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    // MARK: 手势回调

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let model else { return }
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            model.stripTouchBegan(x: location.x, y: location.y)
        case .changed:
            if model.stripTouchMoved(x: location.x, y: location.y) == .failGesture {
                // 竖向占优且向下：自毁、把手势交还 ScrollView（壳版 detachPress 同款）。
                model.stripTouchEnded()
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
        case .ended, .cancelled:
            model.stripTouchEnded()
        default:
            break
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let model, recognizer.state == .ended else { return }
        let location = recognizer.location(in: self)
        onTapCard?(model.anchorNearestFlatCard(x: location.x))
    }
}
