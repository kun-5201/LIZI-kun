import Foundation
import SwiftUI
import WebKit

/// QQ 网页登录兜底（第 12 轮第 10 件）：扫码链走不通时（腾讯服务端拦 100035
/// 之类），让用户直接在网页里登录，再把整罐 cookie 同步回来。
///
/// 流程只照 Moumusic QQWebLoginSheet.swift + Lulumusic02 的做法，不搬代码：
///  - WKWebView 打开 https://y.qq.com，用户在网页里登录；
///  - 点「同步登录状态」读 WKWebsiteDataStore 的全部 cookie，按域合并
///    （qq.com → ptlogin2.qq.com → graph.qq.com → y.qq.com，
///    y.qq.com 最后 = 优先级最高，同名以后读到的为准，空值跳过）；
///  - 整罐发给本地服务 POST /api/qq/web-login，服务端校验（uin + 票据）
///    后存进 QQ 会话存储；成功后关掉 Sheet 并通知前端刷新登录态。
/// Cookie 值、qrsig、musickey、uin 一律不打日志、不进诊断。
///
/// 触发：前端 window.webkit.messageHandlers.liziQQLogin.postMessage({type:'qqWebLogin'})。
/// 成功通知：主 webView 里派发 lizi:qq-web-logged-in 事件（带 nickname）。
final class QQWebLoginBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    /// 本地服务端口（WebHost 启动后填，默认 18791）。
    var portProvider: () -> Int = { 18791 }
    private var sheetPresented = false

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "liziQQLogin",
              let body = message.body as? [String: Any],
              body["type"] as? String == "qqWebLogin" else { return }
        presentSheet()
    }

    private func presentSheet() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.presentSheet() }
            return
        }
        guard !sheetPresented else { return }
        guard let presenter = topViewController() else { return }
        sheetPresented = true
        let view = QQWebLoginView(
            portProvider: portProvider,
            onLoggedIn: { [weak self] nickname in
                self?.sheetPresented = false
                self?.notifyLoggedIn(nickname: nickname)
            },
            onClosed: { [weak self] in self?.sheetPresented = false }
        )
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .pageSheet
        presenter.present(host, animated: true)
    }

    private func topViewController() -> UIViewController? {
        var top = webView?.window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    private func notifyLoggedIn(nickname: String) {
        let safe = nickname.replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        let js = "window.dispatchEvent(new CustomEvent('lizi:qq-web-logged-in', { detail: { nickname: '\(safe)' } }))"
        webView?.evaluateJavaScript(js)
    }
}

// MARK: - Sheet 界面

private struct QQWebLoginView: View {
    var portProvider: () -> Int
    var onLoggedIn: (String) -> Void
    var onClosed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status: String = "在网页里登录 QQ 音乐，登完点下面的「同步登录状态」。"
    @State private var syncing = false
    @State private var synced = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                QQWebView(url: URL(string: "https://y.qq.com")!)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button(syncing ? "同步中…" : "同步登录状态") { sync() }
                            .buttonStyle(.borderedProminent)
                            .disabled(syncing || synced)
                        Button("关闭") { onClosed(); dismiss() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle("QQ 网页登录")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// 读整罐 cookie → 按域合并 → 发给本地服务校验导入。
    private func sync() {
        syncing = true
        status = "正在读取登录状态…"
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let merged = QQWebLoginView.mergedCookieString(cookies)
            guard !merged.isEmpty else {
                syncing = false
                status = "没读到任何 QQ 登录 Cookie：请确认已在网页里登录，再点一次。"
                return
            }
            let port = portProvider()
            guard let url = URL(string: "http://127.0.0.1:\(port)/api/qq/web-login") else {
                syncing = false
                status = "本地服务地址异常，请重试。"
                return
            }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["cookie": merged])
            URLSession.shared.dataTask(with: req) { data, _, _ in
                DispatchQueue.main.async {
                    syncing = false
                    guard let data,
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          (obj["code"] as? Int) == 200,
                          (obj["loggedIn"] as? Bool) == true else {
                        let reason = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["error"] as? String)
                            ?? "同步失败，请重试。"
                        status = reason
                        return
                    }
                    synced = true
                    let nickname = (obj["nickname"] as? String) ?? ""
                    status = "登录成功" + (nickname.isEmpty ? "" : "：\(nickname)")
                    // 留半秒让用户看到成功，再关。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        onLoggedIn(nickname)
                        dismiss()
                    }
                }
            }.resume()
        }
    }

    /// 按域合并：qq.com → ptlogin2.qq.com → graph.qq.com → y.qq.com，
    /// 后读到的同名 cookie 覆盖先读到的，空值跳过；不在这四域里的先放最前面
    /// （优先级最低，不丢东西）。
    static func mergedCookieString(_ cookies: [HTTPCookie]) -> String {
        let order = ["qq.com", "ptlogin2.qq.com", "graph.qq.com", "y.qq.com"]
        func bucket(_ domain: String) -> Int {
            let d = domain.lowercased().trimmingCharacters(in: .init(charactersIn: "."))
            for (i, base) in order.enumerated() where d == base || d.hasSuffix("." + base) { return i }
            return -1
        }
        let sorted = cookies.sorted { bucket($0.domain) < bucket($1.domain) }
        var merged: [String: String] = [:]
        var keys: [String] = []
        for c in sorted where !c.value.isEmpty {
            if merged[c.name] == nil { keys.append(c.name) }
            merged[c.name] = c.value
        }
        return keys.map { "\($0)=\(merged[$0]!)" }.joined(separator: "; ")
    }
}

private struct QQWebView: UIViewRepresentable {
    let url: URL

    /// 第 13 轮第 6 件：强制电脑版。裸 WKWebView() 用默认 iOS 移动端 Safari UA，
    /// y.qq.com 就给手机版登录页。桌面 contentMode（iOS 15+，本 App minOS 16.2）
    /// + 写死的 macOS Safari UA 两道保险，只改这只登录 WebView，不动主 WebView。
    /// 登录流程不动：cookie 仍从默认 WKWebsiteDataStore 读，不受 UA 影响。
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.preferredContentMode = .desktop
        config.defaultWebpagePreferences = prefs
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.desktopUserAgent
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
