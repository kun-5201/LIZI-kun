import SwiftUI

/// 听歌排行页（r31-rank）：只做网易服务端排行，全部真实现。
///
/// 入口：「我的」页（`AccountDetailView` 快捷入口行）→ `AppView.listeningRank`。
/// 列表结构照 Moumusic 的 `ListeningRankView`（只学流程和结构，不抄代码，
/// GPL-3.0）：排名 + 46pt 封面 + 歌名/歌手 + 胶囊条 + 右侧「N 次」，
/// 前 3 名用主题色；点一行把整榜当队列播那首。
/// Moumusic 当前版没有周/所有时间切换（只有最近一周），这里补上：
/// 顶部一段式切换（最近一周 / 所有时间），切了就重拉另一期真数据。
///
/// 状态（全真接线，没有一处是摆设）：
/// - 非网易平台（`platform != "netease"`）：其余 6 台没有等价服务端接口，
///   诚实空态、不发请求、不编数据。
/// - 网易未登录：空态 + 「登录网易云」按钮（弹 `LoginSheetView`）；登上后
///   `.task(id:)` 因登录态变化自动重拉，不用手动刷新。
/// - 加载中：首次拉取转圈；切周期 / 下拉时旧榜留着、新榜到了再换，不闪空页。
/// - 失败：显示原因 + 「重试」按钮（重试就是再调一次 `load()`）。
/// - 空榜：登录了但上游回空，「暂无排行，多听几首歌再来看看」。
/// - 下拉刷新：ScrollView 的 `.refreshable`，就是再调一次 `load()`。
///
/// 胶囊条：宽按上游 `score` 占榜首 `score` 的比例（Moumusic 同款）；
/// 上游没给 score（全 0）时退到按 `playCount` 占比，条子不凭空消失。
/// 榜单顺序就是上游回的顺序（已按热度排好），客户端不重排。
struct ListeningRankView: View {
    /// 榜单所属平台：网易 "netease" 走真榜；其余 6 台只给诚实空态。
    /// 默认网易；`AccountDetailView` 快捷入口按当前账号平台传。
    let platform: String

    @EnvironmentObject private var playback: PlaybackStore
    @ObservedObject private var loginStore = LoginStore.shared

    @State private var period: RankPeriod = .week
    @State private var records: [PlayRecord] = []
    @State private var totalCount = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// 服务端在加载途中回了 401（会话刚死、LoginStore 还没刷新）：
    /// 同样显示登录按钮，不把「会话已死」报成加载失败。
    @State private var serverSaidNotLoggedIn = false
    @State private var loginTarget: LoginSheetTarget?

    init(platform: String = "netease") {
        self.platform = platform
    }

    private var isNetease: Bool { platform == "netease" }
    /// 网易登录态（与设置页账号行同源：`LoginStore`）。
    private var loggedIn: Bool { loginStore.isLoggedIn(platform: "netease") }

    private var platformName: String {
        SettingsStore.platformNames[platform]
            ?? LiziPlatforms.all.first(where: { $0.id == platform })?.name ?? platform
    }

    /// 胶囊条分母：榜首的 score；全 0 时退到榜首的 playCount。
    private var barMax: (score: Int, count: Int) {
        (records.map(\.score).max() ?? 0, records.map(\.playCount).max() ?? 0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("听歌排行")
                    .font(.liziDisplay(size: LiziTokens.size20))
                    .foregroundColor(LiziTokens.ink)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                if !isNetease {
                    unsupportedState
                } else if !loggedIn || serverSaidNotLoggedIn {
                    loginState
                } else {
                    rankContent
                }
            }
            .padding(.bottom, 32)
        }
        .background(LiziTokens.paper)
        .onAppear { loginStore.refresh() }
        .task(id: "\(period.rawValue)-\(loggedIn)-\(platform)") { await load() }
        .refreshable { await load() }
        .sheet(item: $loginTarget) { target in
            LoginSheetView(platform: target.platform)
        }
    }

    // MARK: - 榜单区（网易 + 已登录）

    private var rankContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("排行周期", selection: $period) {
                ForEach(RankPeriod.allCases, id: \.self) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            if totalCount > 0 {
                Text(totalCount > records.count
                     ? "共 \(totalCount) 首 · 显示前 \(records.count) 首"
                     : "共 \(totalCount) 首")
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
                    .padding(.horizontal, 16)
            }
            if isLoading && records.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else if let errorMessage, records.isEmpty {
                errorState(message: errorMessage)
            } else if records.isEmpty {
                emptyState(icon: "chart.bar", title: "暂无排行",
                           subtitle: "多听几首歌再来看看")
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(Array(records.enumerated()), id: \.offset) { index, record in
                        Button {
                            // 整榜当队列，从点的这行开始播（不是只播这一首）。
                            playback.setQueue(records.map(\.track), startAt: index)
                        } label: {
                            rankRow(index: index, record: record)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("播放\(record.track.title)")
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// 榜单行：排名 + 46pt 封面 + 歌名/歌手 + 胶囊条 + 右侧「N 次」。
    private func rankRow(index: Int, record: PlayRecord) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(index < 3 ? LiziTokens.accent : LiziTokens.ink3)
                .frame(width: 30)
            CoverImageView(url: record.track.coverURL, placeholderIconSize: 16)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.track.title)
                    .font(.liziBody(size: 15, weight: .semibold))
                    .foregroundColor(LiziTokens.ink)
                    .lineLimit(1)
                Text(record.track.artist)
                    .font(.liziBody(size: 12))
                    .foregroundColor(LiziTokens.ink3)
                    .lineLimit(1)
                GeometryReader { proxy in
                    Capsule()
                        .fill(LiziTokens.accent.opacity(0.25))
                        .frame(width: max(0, proxy.size.width * barRatio(for: record)), height: 3)
                }
                .frame(height: 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if record.playCount > 0 {
                Text("\(record.playCount) 次")
                    .font(.liziBody(size: 12))
                    .monospacedDigit()
                    .foregroundColor(LiziTokens.ink3)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// 胶囊条宽度占比：score 有值按 score，没给 score 按 playCount。
    private func barRatio(for record: PlayRecord) -> CGFloat {
        if barMax.score > 0 { return CGFloat(record.score) / CGFloat(barMax.score) }
        guard barMax.count > 0 else { return 0 }
        return CGFloat(record.playCount) / CGFloat(barMax.count)
    }

    // MARK: - 状态页

    /// 其余 6 平台：没有等价服务端接口，诚实空态，不发请求、不编数据。
    private var unsupportedState: some View {
        emptyState(icon: "chart.bar", title: "\(platformName)没有服务端听歌排行",
                   subtitle: "该平台没有提供等价的服务端听歌排行接口，这里不编数据；网易云登录后可看。")
    }

    /// 网易未登录：空态 + 登录按钮（弹网易登录流程）。
    private var loginState: some View {
        VStack(spacing: 16) {
            emptyState(icon: "chart.bar", title: "登录网易云查看听歌排行",
                       subtitle: "排行来自网易云账号的真实播放记录")
            Button(action: { loginTarget = LoginSheetTarget(platform: "netease") }) {
                Text("登录网易云")
                    .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(LiziTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .accessibilityLabel("登录网易云查看听歌排行")
        }
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 16) {
            emptyState(icon: "exclamationmark.triangle", title: "排行暂时无法读取",
                       subtitle: message)
            Button(action: { Task { await load() } }) {
                Text("重试")
                    .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                    .foregroundColor(LiziTokens.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(LiziTokens.paper2)
                    .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .accessibilityLabel("重试加载听歌排行")
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(LiziTokens.ink3)
            Text(title)
                .font(.liziBody(size: LiziTokens.size14, weight: .semibold))
                .foregroundColor(LiziTokens.ink)
            Text(subtitle)
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(.horizontal, 32)
    }

    // MARK: - 取数

    @MainActor private func load() async {
        guard isNetease, loginStore.isLoggedIn(platform: "netease") else {
            records = []
            return
        }
        isLoading = true
        errorMessage = nil
        serverSaidNotLoggedIn = false
        defer { isLoading = false }
        switch await ListeningRankService.fetch(period: period) {
        case .success(let result):
            records = result.records
            totalCount = result.total
        case .failure(let error):
            switch error {
            case .notLoggedIn:
                records = []
                serverSaidNotLoggedIn = true
                loginStore.refresh()
            case .upstream(let message):
                errorMessage = message
            case .transport:
                errorMessage = "网络没通，请检查网络后重试"
            }
        }
    }
}
