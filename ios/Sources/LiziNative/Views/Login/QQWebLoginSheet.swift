import SwiftUI
import WebKit

/// 通用网页登录兜底（r31-qqkg：QQWebLoginSheet 改成 ProviderWebLoginSheet
/// 通用版，QQ 与酷狗共用同一组件，只换 loginURL）。
///
/// - WKWebView（非持久 store，每次全新）开登录页，桌面 UA + 桌面模式；
/// - 每 1s 读全部 Cookie，满足签入条件即自动签入；另有「登录完成」手动按钮；
/// - 只拷 Cookie 头进钥匙串（经各平台 SessionStore），不注入 JS、不读
///   输入框、不存账号密码。
/// QQ：https://y.qq.com/，签入条件（uin≠0 + 任一凭证）或（凭证 +
/// psrf_qqopenid）；酷狗：https://m3ws.kugou.com/loginReg.php?act=login，
/// 签入条件 token + identity 非空且 ≠0。
struct ProviderWebLoginSheet: View {
    enum Provider {
        case qq
        case kugou

        var loginURL: URL {
            switch self {
            case .qq: return URL(string: "https://y.qq.com")!
            case .kugou: return URL(string: "https://m3ws.kugou.com/loginReg.php?act=login")!
            }
        }

        var title: String {
            switch self {
            case .qq: return "QQ 网页登录"
            case .kugou: return "酷狗网页登录"
            }
        }

        var hint: String {
            switch self {
            case .qq: return "在网页里登录 QQ 音乐，登完点下面的「登录完成」，或等自动识别。"
            case .kugou: return "在网页里登录酷狗音乐，登完点下面的「登录完成」，或等自动识别。"
            }
        }

        /// 按域合并的优先级（后读到的同名 cookie 覆盖先读到的）。
        var domainOrder: [String] {
            switch self {
            case .qq: return ["qq.com", "ptlogin2.qq.com", "graph.qq.com", "y.qq.com"]
            case .kugou: return ["kugou.com", "m3ws.kugou.com", "www.kugou.com"]
            }
        }
    }

    let provider: Provider
    /// 登录成功（已写进钥匙串 + 画像刷新已排队）后回调；调用方一般用它关掉外层登录页。
    var onLoggedIn: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var status: String = ""
    @State private var syncing = false
    @State private var synced = false
    @State private var dataStore: WKWebsiteDataStore?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProviderWebLoginWebView(url: provider.loginURL) { store in
                    if dataStore == nil { dataStore = store }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    Text(status.isEmpty ? provider.hint : status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button(syncing ? "同步中…" : "登录完成") { Task { await syncNow(manual: true) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(syncing || synced)
                        Button("关闭") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle(provider.title)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: dataStore != nil) {
                guard dataStore != nil else { return }
                await pollLoop()
            }
        }
    }

    /// 每 1s 读一次整罐 Cookie，满足签入条件就自动签入；不满足就继续等。
    /// 自动轮询里不报失败原因（网页还没登完是常态），只在手动点「登录完成」时报。
    private func pollLoop() async {
        guard let store = dataStore else { return }
        while !Task.isCancelled, !synced {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, !synced else { return }
            let cookies = await Self.allCookies(from: store)
            _ = await trySignIn(with: cookies, manual: false)
        }
    }

    private func syncNow(manual: Bool) async {
        guard let store = dataStore, !syncing, !synced else { return }
        syncing = true
        defer { syncing = false }
        let cookies = await Self.allCookies(from: store)
        _ = await trySignIn(with: cookies, manual: manual)
    }

    /// 读到的 Cookie 够签入就签入（写钥匙串），回 true；不够回 false。
    /// 手动触发时把缺项原因写进 status；自动轮询时静默等下一轮。
    private func trySignIn(with cookies: [HTTPCookie], manual: Bool) async -> Bool {
        let merged = Self.mergedCookieString(cookies, domainOrder: provider.domainOrder)
        guard !merged.isEmpty else {
            if manual { status = "没读到任何登录 Cookie：请确认已在网页里登录，再点一次。" }
            return false
        }
        switch provider {
        case .qq:
            let fields = LiziKeychain.cookieFields(merged)
            guard QQMusicAPI.webLoginSignedIn(fields: fields) else {
                if manual { status = QQMusicAPI.cookieProblem(merged) ?? "还没读到登录状态，请确认已在网页里登录，再点一次。" }
                return false
            }
            do {
                try await QQMusicSessionStore.shared.signInFromWeb(cookie: merged)
            } catch {
                if manual { status = error.localizedDescription }
                return false
            }
        case .kugou:
            let norm = KugouAPI.normalizeWebCookie(merged)
            guard KugouAPI.webLoginSignedIn(token: norm.token, userid: norm.userid) else {
                if manual { status = KugouAPI.cookieProblem(merged) ?? "还没读到登录状态，请确认已在网页里登录，再点一次。" }
                return false
            }
            do {
                try await KugouSessionStore.shared.signInFromWeb(cookie: merged)
            } catch {
                if manual { status = error.localizedDescription }
                return false
            }
        }
        synced = true
        status = "登录成功"
        try? await Task.sleep(nanoseconds: 600_000_000)
        onLoggedIn?()
        dismiss()
        return true
    }

    private static func allCookies(from store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            store.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
    }

    // MARK: - Cookie 合并（与服务端 webLoginImport 同规则）

    /// 按域合并：domainOrder 里的域按顺序排，后读到的同名 cookie 覆盖
    /// 先读到的，空值跳过；不在表里的域放最前面（优先级最低，不丢东西）。
    static func mergedCookieString(_ cookies: [HTTPCookie], domainOrder: [String]) -> String {
        func bucket(_ domain: String) -> Int {
            let d = domain.lowercased().trimmingCharacters(in: .init(charactersIn: "."))
            for (i, base) in domainOrder.enumerated() where d == base || d.hasSuffix("." + base) { return i }
            return -1
        }
        let sorted = cookies.sorted { bucket($0.domain) < bucket($1.domain) }
        var merged: [String: String] = [:]
        var keys: [String] = []
        for c in sorted where !c.value.isEmpty {
            if merged[c.name] == nil { keys.append(c.name) }
            merged[c.name] = c.value
        }
        return keys.map { "\($0)=\(merged[$0] ?? "")" }.joined(separator: "; ")
    }
}

/// 只做登录页展示的 WKWebView：非持久 store（每次全新）+ 桌面
/// contentMode + 写死的 macOS Safari UA 三道保险，只改这只登录
/// WebView，不动主 WebView；不注入 JS、不读输入框。
private struct ProviderWebLoginWebView: UIViewRepresentable {
    let url: URL
    let onStoreReady: (WKWebsiteDataStore) -> Void

    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    func makeUIView(context: Context) -> WKWebView {
        let store = WKWebsiteDataStore.nonPersistent()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let prefs = WKWebpagePreferences()
        prefs.preferredContentMode = .desktop
        config.defaultWebpagePreferences = prefs
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.desktopUserAgent
        webView.load(URLRequest(url: url))
        DispatchQueue.main.async { onStoreReady(store) }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 旧名薄包装（QQWebLoginSheet 原来的调用点都走这里）

/// QQ 网页登录（旧名保留）：内部就是 ProviderWebLoginSheet(provider: .qq)。
struct QQWebLoginSheet: View {
    var onLoggedIn: (() -> Void)? = nil

    var body: some View {
        ProviderWebLoginSheet(provider: .qq, onLoggedIn: onLoggedIn)
    }

    /// 旧静态工具的转发（新代码用 QQMusicAPI.cookieProblem / LiziKeychain）：
    /// 把 `k=v; k=v`（也容忍按行复制的换行分隔）拆成小写键名字典。
    static func cookieFields(_ raw: String) -> [String: String] {
        LiziKeychain.cookieFields(raw)
    }

    /// 旧静态校验的转发（新代码用 QQMusicAPI.cookieProblem）。
    static func cookieProblem(_ raw: String) -> String? {
        QQMusicAPI.cookieProblem(raw)
    }

    /// 旧合并函数的转发（新代码用 ProviderWebLoginSheet.mergedCookieString）。
    static func mergedCookieString(_ cookies: [HTTPCookie]) -> String {
        ProviderWebLoginSheet.mergedCookieString(cookies, domainOrder: ["qq.com", "ptlogin2.qq.com", "graph.qq.com", "y.qq.com"])
    }
}

/// 酷狗网页登录（旧名无此类型，新建的薄包装）：内部就是
/// ProviderWebLoginSheet(provider: .kugou)。
struct KugouWebLoginSheet: View {
    var onLoggedIn: (() -> Void)? = nil

    var body: some View {
        ProviderWebLoginSheet(provider: .kugou, onLoggedIn: onLoggedIn)
    }
}
