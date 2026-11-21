import SwiftUI

/// 播放队列面板（r20：由 `PlayerView` 叠在歌词区上打开/关闭，只盖住歌词区，
/// 绝不遮控制行和最底部细进度条；不用 sheet，sheet 会盖住整页）。
///
/// 点行切歌（`store.play(queueItem:)`；按 `queueId` 定位，同一首歌在队列里
/// 出现多次时点第几行就播第几行，r25-B2 U6；旧 `play(item.track)` 按
/// id+platform 找第一个匹配项，点第二行会播成第一行，已不用）。
/// 当前在播的行高亮 + 「正在播放」标记。
/// r31：`store.playNext(_:)` 插进来的歌在行右侧打「下一首」徽章（替代
/// 时长显示），头部再给一个「· 下一首 N 首」总数；起播后徽章即摘掉，
/// 那行改回「正在播放」。
/// 左滑删除单行（`store.removeFromQueue(at:)`）+ 头部「清空」按钮
/// （二次确认后 `store.clearQueue()`，清空并停止；r25-B2 U3）。
/// 列表用 List（swipeActions 只在 List 行上生效，ScrollView 里不生效），
/// 行背景透明 + 隐藏系统分隔线，沿用原来的自定义 Divider，外观不变。
///
/// 头部只留：清空（二次确认）+ 共 N 首 + 关闭 X。
/// 模式控制（循环 / 随机）不在这里——唯一入口是底部 v4 控制行
/// `PlayerBottomDock` 的模式键（`cycleDockMode`）；r29 task 3 删了
/// 头部重复的那两个按钮（用户真机报「为什么是 2 个控制器」）。
///
/// r35-3（用户 2026-11-21 18:36「新增搜索之后播放的歌单列表」，
/// 18:37 补「卡片形式一直从左到右滑动」，18:40 更正为「向左滚」、
/// 跟首页跑马带同方向）：搜完点歌立的队列带标题
/// （`store.queueTitle` = 「搜索：\(query)」）时，头部左端显示这个
/// 歌单名，列表区换成横排卡片跑马带（`SearchQueueMarqueeView`）——
/// 封面 + 歌名 + 歌手、首页跑马带同款式，卡片从右往左自动滑、滑到头
/// 循环回来，当前播的那首高亮，点任意一张卡切过去播
/// （`store.play(queueItem:)`）。标题为 nil 的队列（歌单 / 专辑 /
/// 首页点歌等其他来源）保持原来的 List，一字不动。
struct QueuePanelView: View {
    @EnvironmentObject private var store: PlaybackStore

    /// 关闭回调（`PlayerView` 的 showQueue；不传时不显示关闭按钮）。
    var onClose: (() -> Void)? = nil

    /// 清空队列二次确认弹窗。
    @State private var showClearConfirm = false

    /// r35-3：搜索歌单卡片带的驱动（归本面板所有，@StateObject——面板
    /// 打开时建、关掉时随视图一起释放；见文件底 `SearchQueueMarqueeDriver`）。
    @StateObject private var marqueeDriver = SearchQueueMarqueeDriver()

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if store.queue.isEmpty {
                VStack {
                    Spacer()
                    Text("队列是空的")
                        .font(.system(size: PlayerTokens.textMd))
                        .foregroundStyle(PlayerTokens.playerDim)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.queueTitle != nil {
                // r35-3：搜索歌单列表——横排卡片跑马带（向左自动滑、循环），
                // 不是下面的 List；其他来源的队列（标题为 nil）仍走 List。
                SearchQueueMarqueeView(driver: marqueeDriver)
            } else {
                List {
                    ForEach(Array(store.queue.enumerated()), id: \.element.id) { index, item in
                        VStack(spacing: 0) {
                            QueueRowView(item: item, isCurrent: index == store.currentIndex,
                                         isPlayNext: store.isPlayNext(queueId: item.queueId))
                                .onTapGesture { store.play(queueItem: item) }
                            Divider()
                                .background(Color.white.opacity(0.08))
                                .padding(.leading, 56)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.removeFromQueue(at: index)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .accessibilityLabel("从队列删除 \(item.track.title)")
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 毛玻璃卡片：盖在歌词区上时歌词不透出来干扰阅读。
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: PlayerTokens.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: PlayerTokens.radiusLg)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .alert("清空队列", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) {
                store.clearQueue()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空队列并停止播放，此操作无法撤销。")
        }
    }

    // MARK: - 头部：歌单名 + 清空 + 数量 + 关闭（r29 task 3：模式键只留底部 v4 dock）

    private var headerRow: some View {
        HStack(spacing: 8) {
            // r35-3：搜索歌单名（「搜索：\(query)」）放左端；其他来源的
            // 队列标题为 nil，不显示、不占地方，头部与原来一字不差。
            if let title = store.queueTitle {
                Text(title)
                    .font(.system(size: PlayerTokens.textMd, weight: .semibold))
                    .foregroundStyle(PlayerTokens.playerForeground)
                    .lineLimit(1)
            }

            Spacer()

            if !store.queue.isEmpty {
                Button {
                    showClearConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                        Text("清空")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.12), in: Capsule())
                }
                .accessibilityLabel("清空队列")

                Text("共 \(store.queue.count) 首")
                    .font(.system(size: PlayerTokens.textXs))
                    .foregroundStyle(PlayerTokens.playerDim)

                // r31：待播的下一首有几首（插进去的歌在面板里看得见：行上有
                // 「下一首」徽章，这里再给一个总数；为 0 时不显示，不占地方）。
                if store.playNextQueueIds.count > 0 {
                    Text("· 下一首 \(store.playNextQueueIds.count) 首")
                        .font(.system(size: PlayerTokens.textXs, weight: .medium))
                        .foregroundStyle(PlayerTokens.accent)
                }
            }

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PlayerTokens.playerForeground)
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.14), in: Circle())
                }
                .accessibilityLabel("关闭队列")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// 队列里的一行。
/// r31：`isPlayNext` 为真时（这首是「下一首播放」插进来的）在右侧打
/// 「下一首」徽章，替代时长显示——插进去的歌在面板里一眼看得见；
/// 起播后待播标记即摘掉（`play(queueItem:)` 里清），徽章随之消失，
/// 那行改回「正在播放」。
struct QueueRowView: View {
    let item: QueueItem
    let isCurrent: Bool
    let isPlayNext: Bool

    var body: some View {
        HStack(spacing: 12) {
            CoverImageView(url: item.track.coverURL, placeholderIconSize: 14)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.track.title.isEmpty ? "未知标题" : item.track.title)
                    .font(.system(size: PlayerTokens.textMd, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? PlayerTokens.accent : PlayerTokens.playerForeground)
                    .lineLimit(1)
                Text(item.track.artist.isEmpty ? item.track.platform : item.track.artist)
                    .font(.system(size: PlayerTokens.textXs))
                    .foregroundStyle(PlayerTokens.playerDim)
                    .lineLimit(1)
            }

            Spacer()

            if isCurrent {
                Text("正在播放")
                    .font(.system(size: PlayerTokens.textXs, weight: .medium))
                    .foregroundStyle(PlayerTokens.accent)
            } else if isPlayNext {
                Text("下一首")
                    .font(.system(size: PlayerTokens.textXs, weight: .medium))
                    .foregroundStyle(PlayerTokens.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(
                        Capsule()
                            .stroke(PlayerTokens.accent.opacity(0.6), lineWidth: 1)
                    )
                    .accessibilityLabel("下一首播放 \(item.track.title)")
            } else {
                Text(PlayerTokens.formatDuration(item.track.durationSeconds))
                    .font(.system(size: PlayerTokens.textXs))
                    .foregroundStyle(PlayerTokens.playerDim)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - r35-3：搜索歌单卡片跑马带（向左自动滑，跟首页同方向）

/// 搜索歌单卡片带的驱动——首页 `HomeView.RailMarqueeDriver` 的同款机制，
/// 只改名、不改行（方向、速度、初画停、循环、拖动、看门狗全都不用改，
/// 用户 18:40 更正：向左滚，跟首页跑马带同方向）：
/// CADisplayLink + 真实帧间隔 dt，步长 = 速度 × dt；内容复制两份循环，
/// 偏移收进 (-setWidth, 0]，滚过一份宽度无缝回卷；初画停 2.5s；
/// 横向拖动时暂停，松手 1.2s 后恢复；拖动旗卡住 10s 自动清、
/// 偏移 3s 不动看门狗自己推一步。
/// 单独写一份而不是直接复用 `RailMarqueeDriver`，是因为那套类型是
/// `HomeView` 里的 `private` 嵌套类型、跨文件用不了，而 r35.cjs §H4
/// 把 `HomeView.swift` 钉死为与 r34 快照逐字节相同、不能为了抽它而动
/// 首页；机制一字照抄，只在看门狗里修了一个首页已知的缺陷（见
/// `watchdogTick` 注释：首页 `RailMarqueeDriver.watchdogTick` 的
/// 「拖动旗卡住恢复」写在 `guard !isDragging` 之后、到不了）。
final class SearchQueueMarqueeDriver: ObservableObject {
    @Published var offsetX: CGFloat = 0
    @Published var setWidth: CGFloat = 0
    @Published var isDragging = false

    /// 首页跑马带默认速度（`HomeViewModel.marqSpeedPxPerSecond` 默认 24；
    /// 队列面板不接首页的速度设置，就取这个默认值）。
    var speed: CGFloat = 24

    private var dwellUntil = Date().addingTimeInterval(2.5)
    private var dragBase: CGFloat = 0
    private var draggingSince: Date?
    private var displayLink: CADisplayLink?
    private var linkProxy: SearchQueueMarqueeLinkProxy?
    private var frameRateObserver: NSObjectProtocol?
    private var lastTimestamp: CFTimeInterval = 0
    private var marqueeWatchdog: Timer?
    private var lastOffsetX: CGFloat = 0
    private var lastOffsetChange = Date()
    private var watchdogLoggedStuck = false

    init() { start(); startWatchdog() }

    deinit {
        displayLink?.invalidate()
        marqueeWatchdog?.invalidate()
        if let frameRateObserver { NotificationCenter.default.removeObserver(frameRateObserver) }
    }

    /// 带宽兜底（首页 `RailMarqueeDriver.ensureSetWidth` 同款）：偏好
    /// 万一没到，只在 setWidth == 0 时按卡数×(卡宽+间距)补，不打架。
    func ensureSetWidth(cardCount: Int, cardWidth: CGFloat) {
        guard setWidth == 0, cardCount > 0 else { return }
        setWidth = CGFloat(cardCount) * (cardWidth + 16)
    }

    private func startWatchdog() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        marqueeWatchdog = timer
    }

    /// 看门狗每 0.1s 一跳：不该走时（拖动中 / dwell 未过 / 没内容）
    /// 只刷新基线，不误判；该走但偏移 3s 没变 → 记一次诊断 + 自己按
    /// 速度向左推一步（2.4px/步；link 活着时偏移每帧都在变，不会触发，
    /// 绝不与 link 打架）。
    /// 与首页 `RailMarqueeDriver.watchdogTick` 不同的是：拖动旗卡住的
    /// 恢复先判——`isDragging` 为真且 10s 无位移时当场清旗（linkFired
    /// 里同款 10s 规则的备份）；首页那份把 `isDragging = false` 写在
    /// `guard !isDragging` 之后，拖动旗真卡住时那行到不了、带子永远停
    /// （r34 交回里记的已知缺陷），这里不抄。
    private func watchdogTick() {
        guard setWidth > 0, Date() >= dwellUntil else {
            lastOffsetX = offsetX
            lastOffsetChange = Date()
            watchdogLoggedStuck = false
            return
        }
        if isDragging {
            if let since = draggingSince,
               Date().timeIntervalSince(since) > 10 {
                isDragging = false
                draggingSince = nil
                DiagLog.shared.recordLog(category: "marquee", message: "search queue belt drag flag stuck 10s, cleared", fields: ["setWidth": setWidth, "offsetX": offsetX])
            }
            lastOffsetX = offsetX
            lastOffsetChange = Date()
            return
        }
        if offsetX != lastOffsetX {
            lastOffsetX = offsetX
            lastOffsetChange = Date()
            watchdogLoggedStuck = false
            return
        }
        guard Date().timeIntervalSince(lastOffsetChange) >= 3 else { return }
        if !watchdogLoggedStuck {
            watchdogLoggedStuck = true
            DiagLog.shared.recordLog(category: "marquee", message: "search queue belt stuck 3s, watchdog driving", fields: ["setWidth": setWidth, "offsetX": offsetX, "speed": speed])
        }
        dwellUntil = Date()
        offsetX = normalized(offsetX - speed * 0.1)
        lastOffsetX = offsetX
    }

    func start() {
        guard displayLink == nil else { return }
        let proxy = SearchQueueMarqueeLinkProxy(driver: self)
        let link = CADisplayLink(target: proxy, selector: #selector(SearchQueueMarqueeLinkProxy.fired(_:)))
        // 帧率上限跟设置页「120Hz 高刷新率」开关走（首页同款）。
        link.preferredFrameRateRange = SettingsStore.frameRateRange()
        link.add(to: .main, forMode: .common)
        linkProxy = proxy
        displayLink = link
        frameRateObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.highRefreshRateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyFrameRateRange() }
            }
    }

    private func applyFrameRateRange() {
        displayLink?.preferredFrameRateRange = SettingsStore.frameRateRange()
    }

    /// 内容换了（搜新词点新歌、队列增减）：只把偏移收进新宽度，不归零、
    /// 不重停 dwell——带子接着滚，不停、不跳（首页同款）。
    func noteContentChanged() {
        offsetX = normalized(offsetX)
    }

    func dragBegan() {
        isDragging = true
        draggingSince = Date()
        dragBase = offsetX
    }

    func dragMoved(_ dx: CGFloat) {
        draggingSince = Date()
        offsetX = normalized(dragBase + dx)
    }

    func dragEnded() {
        isDragging = false
        draggingSince = nil
        dwellUntil = Date().addingTimeInterval(1.2)
    }

    /// 拖动被外力打断后的清理（首页 `RailMarqueeDriver.dragCancelled` 同款）。
    func dragCancelled() {
        isDragging = false
        draggingSince = nil
    }

    /// display link 回调（主线程）：步长 = 速度 × 真实帧间隔 dt；
    /// 向左滚（offsetX 减小），首页 `RailMarqueeDriver.linkFired` 同款。
    fileprivate func linkFired(_ link: CADisplayLink) {
        let dt: CFTimeInterval
        if lastTimestamp == 0 {
            dt = 1.0 / 60.0
        } else {
            dt = link.timestamp - lastTimestamp
        }
        lastTimestamp = link.timestamp
        if isDragging, let since = draggingSince,
           Date().timeIntervalSince(since) > 10 {
            isDragging = false
            draggingSince = nil
        }
        guard setWidth > 0, !isDragging, Date() >= dwellUntil else { return }
        let clamped = min(max(dt, 0), 0.1)
        guard clamped > 0 else { return }
        offsetX = normalized(offsetX - speed * CGFloat(clamped))
    }

    /// 把偏移收进 (-setWidth, 0]，两份循环无缝（首页同款）。
    private func normalized(_ x: CGFloat) -> CGFloat {
        guard setWidth > 0 else { return x }
        var v = x
        while v > 0 { v -= setWidth }
        while v <= -setWidth { v += setWidth }
        return v
    }
}

/// display link 回调代理（首页 `RailMarqueeLinkProxy` 同款：link 强持
/// target，代理只弱持驱动，不循环引用；回调已在主线程）。
private final class SearchQueueMarqueeLinkProxy: NSObject {
    weak var driver: SearchQueueMarqueeDriver?

    init(driver: SearchQueueMarqueeDriver) {
        self.driver = driver
    }

    @objc func fired(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            self.driver?.linkFired(link)
        }
    }
}

private struct SearchQueueMarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 搜索歌单卡片带：队列（`store.queue`，这次搜索的全部曲目）画成横排
/// 卡片，首页 `RailMarqueeView` 同款形态——卡片横向排、内容复制两份循环，
/// 滚过一份宽度无缝回卷；自动向左滚，速度 24px/s（首页默认值）；
/// 可横向拖动，拖动时暂停，松手 1.2s 后恢复；竖向滚动走
/// simultaneousGesture，不抢面板的竖滑（面板本身不竖滚，这里只是
/// 与首页同款、不把手势吃死）。
/// 卡片是 Button（点一张就播，走 `store.play(queueItem:)`，按 queueId
/// 定位，重复曲目点第几张播第几张）；当前播的那首高亮（封面 accent 描边
/// + 歌名 accent 加粗 + 「正在播放」小标）。
private struct SearchQueueMarqueeView: View {
    @EnvironmentObject private var store: PlaybackStore
    @ObservedObject var driver: SearchQueueMarqueeDriver

    /// 卡宽 120pt（面板比首页栏窄，卡片取小一档；间距 16 与首页一致）。
    /// 卡高 = 卡宽 + 52（封面 + 间距 7 + 16pt 名行 + 间距 7 + 14pt
    /// 副标题行，首页 `RailMarqueeView` 的 openedView 同款算法）。
    private let cardWidth: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if store.queue.isEmpty {
                    Color.clear
                } else {
                    marqueeContent
                }
            }
            .frame(height: cardWidth + 52, alignment: .top)
            .onAppear {
                driver.speed = 24
                driver.ensureSetWidth(cardCount: store.queue.count, cardWidth: cardWidth)
                driver.noteContentChanged()
            }
            .onDisappear { driver.dragCancelled() }
            .onChange(of: store.queue.map(\.queueId)) { _ in
                driver.ensureSetWidth(cardCount: store.queue.count, cardWidth: cardWidth)
                driver.noteContentChanged()
            }
            Spacer(minLength: 0)
        }
    }

    private var marqueeContent: some View {
        HStack(spacing: 16) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 16) {
                    ForEach(store.queue) { item in
                        SearchQueueMarqueeCardView(
                            item: item,
                            width: cardWidth,
                            isCurrent: store.queue.firstIndex(where: { $0.queueId == item.queueId }) == store.currentIndex
                        )
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SearchQueueMarqueeWidthKey.self, value: geo.size.width)
                    }
                )
            }
        }
        .offset(x: driver.offsetX)
        .onPreferenceChange(SearchQueueMarqueeWidthKey.self) { driver.setWidth = $0 + 16 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .local)
                .onChanged { value in
                    if !driver.isDragging {
                        driver.dragBegan()
                    }
                    driver.dragMoved(value.translation.width)
                }
                .onEnded { _ in driver.dragEnded() }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

/// 卡片带里的一张卡：封面 + 歌名 + 歌手（首页 `RailMarqueeCardView`
/// 同款形状：封面正方形 + 16pt 名 + 14pt 副标题，间距 7）。
/// 没封面用 `DefaultCoverArt` 深色默认图（首页卡片同款）；当前播的那首
/// 封面描 accent 边、歌名 accent 加粗、副标题行后跟「正在播放」小标。
private struct SearchQueueMarqueeCardView: View {
    @EnvironmentObject private var store: PlaybackStore
    let item: QueueItem
    let width: CGFloat
    let isCurrent: Bool

    var body: some View {
        Button {
            store.play(queueItem: item)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                coverArt
                    .frame(width: width, height: width)
                    .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
                    .overlay(
                        RoundedRectangle(cornerRadius: LiziTokens.radius10)
                            .stroke(isCurrent ? PlayerTokens.accent : Color.clear, lineWidth: 2)
                    )
                Text(item.track.title.isEmpty ? "未知标题" : item.track.title)
                    .font(.system(size: 16, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(isCurrent ? PlayerTokens.accent : PlayerTokens.playerForeground)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.track.artist.isEmpty ? item.track.platform : item.track.artist)
                        .font(.system(size: 14))
                        .foregroundStyle(PlayerTokens.playerDim)
                        .lineLimit(1)
                    if isCurrent {
                        Text("正在播放")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PlayerTokens.accent)
                    }
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCurrent ? "正在播放 \(item.track.title)" : "播放 \(item.track.title)")
    }

    @ViewBuilder
    private var coverArt: some View {
        if item.track.coverURL == nil {
            DefaultCoverArt(iconSize: 64)
        } else {
            CoverImageView(url: item.track.coverURL, placeholderIconSize: 64)
        }
    }
}
