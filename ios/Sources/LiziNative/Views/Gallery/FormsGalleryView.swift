import SwiftUI
import WebKit

/// 形态长廊整页（原生）：壳版 view-forms 的 WKWebView 版。
///
/// 壳版行为对照（app.js show('forms')，约 418、432 行）：
/// - 整页就是一个 iframe 指向 /forms-labs/；第一次进入才设 src，离开时置回
///   about:blank——画廊的 rAF / WebGL 不会在后台继续跑。
/// - 页面本体在 public/forms-labs/（WebGL 球面格网 + LIZI 白纸改造，每格一张
///   previews/<id>.jpg 静态图）；页内点「进入形态」走它自己的 stage-layer
///   iframe（../stages/<file>.html），不需要原生介入。
/// - 原生侧用 GalleryWebView（本文件底部的最小承载：只 loadFileURL，不建桥、
///   不发 init/tick）加载 bundle 里的 GalleryHTML/forms-labs/index.html；
///   不复用 public/ 拷贝与 LocalHttpServer，不走 http://127.0.0.1。
///   舞台页的承载是 P3-A 的 StageBridge + StageWebView——长廊页不是舞台，
///   不共用那套桥（它按 StageBridge.currentForm 换文档，长廊页不需要）。
/// - 懒加载与卸载照抄壳版：onAppear 才建 WebView，onDisappear 销毁
///   （WebGL 在后台不跑）；每次进入都重新加载（壳版每次 show('forms') 时
///   src 都是重新设的——离开时已被置回 about:blank）。
/// - 诚实边界：653 个形态里只有 66 个有 stages/*.html 文件（其余在壳版盘上
///   也没有）；长廊页内对无文件形态不显示「进入形态」按钮（forms-labs
///   app.js 的原有逻辑），点有文件的形态进 stage-layer，缺文件时页内自己
///   显示错误层 + 返回按钮。
struct FormsGalleryView: View {
    @EnvironmentObject var nav: AppNavigation
    @State private var loaded = false

    var body: some View {
        ZStack {
            Color(hex: 0xF7F6F4)
            if loaded,
               let fileURL = GalleryHTMLBundle.formsLabsIndexURL,
               let readAccessURL = GalleryHTMLBundle.rootURL {
                GalleryWebView(fileURL: fileURL, readAccessURL: readAccessURL)
            } else if loaded {
                // bundle 里找不到长廊页（打包漏了 GalleryHTML 资源时才出现）。
                VStack(spacing: 8) {
                    Text("形态长廊资源缺失")
                        .font(.liziBody(size: LiziTokens.size16, weight: .semibold))
                        .foregroundColor(LiziTokens.ink)
                    Text("bundle 里没有 GalleryHTML/forms-labs/index.html，检查构建资源的拷贝。")
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink2)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        // 球面画廊入口（P3 r19 集成）：首页工具区只放「形态长廊」一张卡，
        // 另一个画廊入口放在长廊页内——右下角悬浮按钮，不进 WebGL 页本身，
        // 不挡中间的球面格子与 caption。
        .overlay(alignment: .bottomTrailing) {
            if loaded {
                Button(action: { nav.show(.gallery) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 13, weight: .semibold))
                        Text("球面画廊")
                            .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                    }
                    .foregroundColor(LiziTokens.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(LiziTokens.paper)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
                }
                .accessibilityLabel("球面画廊")
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
        }
        .onAppear { loaded = true }
        .onDisappear { loaded = false }
    }
}

/// 最小本地 HTML 承载：只做 `loadFileURL`，不建消息桥、不发协议消息。
/// 长廊页（forms-labs）自己管一切（球面、曲率条、caption、stage-layer），
/// 原生侧只给它一个 file:// 的家。readAccess 给 bundle 资源根目录，
/// 这样页内的 `../../stages/...`（去重后单份 stages/）、`../vendor/...`
/// 相对路径都能解析；收窄到 GalleryHTML/ 会把 stage iframe 挡在外面。
struct GalleryWebView: UIViewRepresentable {
    /// 要加载的本地文件 URL（必须是 file://，且在 readAccessURL 之下）。
    let fileURL: URL
    /// 允许读取的根目录（bundle 资源根目录，见 GalleryHTMLBundle.rootURL）。
    let readAccessURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 只加载一次：SwiftUI 重绘不触发重载，避免 WebGL 球面反复白闪。
    }
}
