import AVKit
import SwiftUI

/// 原生版导航壳根视图：按 AppNavigation.current 切三页（state 切换，
/// 不用 NavigationStack 嵌套）。
///
/// - `.home` → HomeView（P1-B 首页）。
/// - `.search` → SearchView（搜索工人已交付，RootView 只在外包一层返回栏）。
/// - `.player` → PlayerView（P1-D 播放页，P1 集成已接线）。
/// - AppNavigation 由这里以 @StateObject 持有，经 environmentObject 下发。
///
/// 深链（`lizinative://`）：
/// - `lizinative://airplay` → 打开 App 后弹系统音频路由选择页
///  （AVRoutePickerView sheet，照抄壳版 ContentView.AirPlayPickerSheet）。
/// r36：`now` 深链（灵动岛点按进播放页）随自定义岛一起删了。
struct RootView: View {
    @StateObject private var nav = AppNavigation()
    @StateObject private var stageForms = StageFormStore()
    @State private var showAirPlay = false
    /// r36 第 15 件首次弹窗（用户 2026-11-21 22:41 定）：免责声明接受状态，
    /// UserDefaults 持久化键 `lizi.disclaimerAccepted`（@AppStorage 直写
    /// UserDefaults，默认 false = 未接受）。只首次打开弹一次，点了确定
    /// 之后不再弹；键名与 HomeView 的 `lizi.local.show` 同款字面量风格。
    @AppStorage("lizi.disclaimerAccepted") private var disclaimerAccepted = false
    /// 首次启动弹窗的开关：onAppear 时未接受才置 true，全屏盖住主界面，
    /// 点了确定才放行；禁手势关闭，不点按钮进不了主界面。
    @State private var showFirstLaunchDisclaimer = false

    var body: some View {
        Group {
            switch nav.current {
            case .home:
                HomeView()
            case .search:
                SearchViewWithBack()
            case .player:
                PlayerView()
            case .stage(let formId, let openSettings):
                // r36-7 形态解析顺序：显式 formId（画廊「进入这个形态」/
                // 深链 `?id=`）> 本次播放器会话里切的形态
                // （AppNavigation.sessionStageFormId，内存，回首页即清）
                // > `StageCatalog.savedFormId()`（StageBridge 的回落：画廊
                // 上次选的 / 默认 001）。回首页后会话值已清，`.stage()` 不会
                // 把上个会话切的形态带回来；`savedFormId()` 本身一字不动。
                StageView(initialFormId: formId ?? nav.sessionStageFormId, openSettings: openSettings)
            case .playlist(let platform, let id, let isRank, let title, let coverURL):
                DetailWithBack {
                    PlaylistDetailView(platform: platform, id: id, isRank: isRank,
                                       title: title, coverURL: coverURL)
                }
            case .artist(let platform, let id):
                DetailWithBack {
                    ArtistView(platform: platform, id: id)
                }
            case .album(let platform, let id):
                DetailWithBack {
                    AlbumView(platform: platform, id: id)
                }
            case .myAlbums:
                DetailWithBack {
                    MyAlbumsView()
                }
            case .listeningRank(let platform):
                DetailWithBack {
                    ListeningRankView(platform: platform)
                }
            case .settings:
                DetailWithBack {
                    SettingsView()
                }
            case .rail(let kind, let platform):
                DetailWithBack {
                    RailDetailView(kind: RailKind(rawValue: kind) ?? .featured, platform: platform)
                }
            case .forms:
                DetailWithBack {
                    FormsGalleryView()
                }
            case .gallery:
                DetailWithBack {
                    SphereGalleryView()
                }
            }
        }
        .environmentObject(nav)
        .environmentObject(stageForms)
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .sheet(isPresented: $showAirPlay) {
            NativeAirPlayPickerSheet()
        }
        .onAppear {
            // r36 第 15 件首次弹窗：启动时先判接受状态，未接受就弹全屏
            // 免责声明挡住主界面；已接受（点了确定）直接进主界面，不再弹。
            if !disclaimerAccepted {
                showFirstLaunchDisclaimer = true
            }
        }
        .fullScreenCover(isPresented: $showFirstLaunchDisclaimer) {
            FirstLaunchDisclaimerView(
                onAccept: {
                    // 点「确定」才能进入软件：接受状态写盘，下次启动不再弹，
                    // 再关弹窗放行进主界面。
                    disclaimerAccepted = true
                    showFirstLaunchDisclaimer = false
                },
                onDecline: {
                    // 点「不确定」就退出软件，直接 terminate，不进主界面。
                    exit(0)
                }
            )
        }
    }

    /// 深链路由：只认 `lizinative` scheme；host 为 airplay/forms/gallery/stage，其他一律忽略。
    /// P3-B 增加：`lizinative://forms`（形态长廊）、`lizinative://gallery`
    /// （球面画廊）、`lizinative://stage?id=001`（进指定形态的舞台页）。
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "lizinative" else { return }
        switch url.host {
        case "airplay":
            showAirPlay = true
        case "forms":
            nav.show(.forms)
        case "gallery":
            nav.show(.gallery)
        case "stage":
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value
            nav.show(.stage(formId: id))
        default:
            break
        }
    }
}

/// P0 入口名保留：LiziNativeApp 仍以 NativeHomeView 启动，内部即 RootView，
/// 所以 LiziNativeApp.swift 一行不用改。
/// P0 脚手架那几行构建信息（LiziNativeBuildInfo）已撤下，
/// 构建信息改由 P3 设置页「关于 → 构建」展示。
struct NativeHomeView: View {
    var body: some View {
        RootView()
    }
}

// MARK: - 搜索页接线

/// 搜索页本身不建导航（见 SearchView.swift 文件头约定）：
/// RootView 在外包一层返回栏，点左上角回首页。
/// 搜索页工人如需改返回样式，改这里，不用动 SearchView。
private struct SearchViewWithBack: View {
    @EnvironmentObject var nav: AppNavigation

    var body: some View {
        VStack(spacing: 0) {
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            SearchView()
        }
        .background(LiziTokens.paper)
    }
}

/// P2 内容页通用返回栏（P2-A）：照抄 SearchViewWithBack 的样式——
/// 左上 chevron.left +「首页」，点回 .home。P2 五个新分支（歌单/歌手/
/// 专辑/我的专辑/rail）都在外包这一层；SearchViewWithBack 原样保留不动。
private struct DetailWithBack<Content: View>: View {
    @EnvironmentObject var nav: AppNavigation
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
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
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            content
        }
        .background(LiziTokens.paper)
    }
}

/// 系统路由选择器（AVRoutePickerView）。点这个按钮出系统设备列表 + 音量条——
/// 就是用户要的“系统自带那个 AirPlay 音量面板”。
struct NativeAirPlayPickerSheet: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("选择音频输出设备，点下面按钮弹出系统菜单，可切设备、调音量。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                NativeAirPlayPickerView()
                    .frame(width: 44, height: 44)
                Spacer()
            }
            .padding()
            .navigationTitle("音频输出")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// AVRoutePickerView 的 SwiftUI 包装（UIKit 视图，只能在 App 内用，扩展里放不了）。
struct NativeAirPlayPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView()
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - r36 第 15 件首次弹窗

/// 首次启动免责声明弹窗（用户 2026-11-21 22:41 定）：首次打开软件时全屏盖住
/// 主界面，内容就是 `liziDisclaimerText` 七条全文（SettingsView.swift 文件顶
/// 一处常量，这里只读它，不另写一份文案；标题「免责声明」是弹窗标题，不在正文里）。
/// 两个按钮——「确定」写接受状态放行进主界面，「不确定」直接退出（exit(0)）。
/// `.interactiveDismissDisabled()` 禁手势下滑关闭：不点按钮既进不了主界面，
/// 也关不掉弹窗。样式照抄设置页 `DisclaimerView` 全文页（纸面底 + 墨字 + 同字号）。
private struct FirstLaunchDisclaimerView: View {
    var onAccept: () -> Void
    var onDecline: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("免责声明")
                .font(.liziBody(size: LiziTokens.size16, weight: .semibold))
                .foregroundColor(LiziTokens.ink)
                .padding(.top, 20)
                .padding(.bottom, 12)
            ScrollView {
                Text(liziDisclaimerText)
                    .font(.liziBody(size: LiziTokens.size14))
                    .foregroundColor(LiziTokens.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            HStack(spacing: 12) {
                Button("不确定", action: onDecline)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("不确定，退出软件")
                Button("确定", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("确定，同意免责声明并进入软件")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(LiziTokens.paper)
        .interactiveDismissDisabled()
    }
}
