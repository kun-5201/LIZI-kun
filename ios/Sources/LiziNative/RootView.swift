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
/// 深链（`lizinative://`，扩展岛/锁屏点过来，见 LiziLiveActivityViews）：
/// - `lizinative://now` → 打开播放页。
/// - `lizinative://airplay` → 打开 App 后弹系统音频路由选择页
///  （AVRoutePickerView sheet，照抄壳版 ContentView.AirPlayPickerSheet；
///   扩展里放不了这个视图，也没有 API 能在岛上原地弹面板，所以多一次点击，
///   平台限制）。
struct RootView: View {
    @StateObject private var nav = AppNavigation()
    @State private var showAirPlay = false

    var body: some View {
        Group {
            switch nav.current {
            case .home:
                HomeView()
            case .search:
                SearchViewWithBack()
            case .player:
                PlayerView()
            }
        }
        .environmentObject(nav)
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .sheet(isPresented: $showAirPlay) {
            NativeAirPlayPickerSheet()
        }
    }

    /// 深链路由：只认 `lizinative` scheme；host 为 now/airplay，其他一律忽略。
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "lizinative" else { return }
        switch url.host {
        case "now":
            nav.show(.player)
        case "airplay":
            showAirPlay = true
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

/// 音频路由选择页（照抄壳版 ContentView.AirPlayPickerSheet，P1 集成接线）：
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
