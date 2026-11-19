import SwiftUI
import WebKit

/// QQ 网页登录兜底（r23c，原生 UI；后端不动，只调已有接口）。
///
/// 照 Moumusic `QQWebLoginSheet` / 壳版 `QQWebLoginSheet.swift` 的流程，不搬代码：
///  - WKWebView 打开 https://y.qq.com，用户在网页里登录；
///  - 点「同步登录状态」读 `WKWebsiteDataStore` 的全部 cookie，按域合并
///    （qq.com → ptlogin2.qq.com → graph.qq.com → y.qq.com，
///    y.qq.com 最后 = 优先级最高，同名以后读到的为准，空值跳过；
///    不在这四域里的先放最前面、优先级最低，不丢东西）；
///  - 整罐 cookie 发给后端 POST /api/qq/login/web（r23a 的带 body call），
///    后端校验（账号 id 取 uin/wxuin/p_uin/pt2gguin + 至少 1 个凭证 key）
///    后存进 QQ 会话存储；成功后 refresh + status 确认再关弹窗。
///
/// 账号密码：不在 WebView 里做任何账号密码的保存或记录——本页不注入任何
/// JS、不读输入框、不存任何凭证；只在用户点「同步登录状态」后读一次
/// cookie，且 cookie 字符串只进 POST body，不打日志、不进诊断、不落盘
/// （存是后端会话存储的事）。登录页用桌面版 UA + 桌面 contentMode，
/// 否则 y.qq.com 只给手机版登录页（壳版同款两道保险）。
///
/// 依赖 r23a 底座（本文件不自建）：静态 `LoginStore.refresh(platform:)`（与
/// Kuwo/AppleMusic 同级文件同款写法）、带 body 的
/// `NativeBridge.call(path:query:method:body:)`（body 是 [String: Any]）。
struct QQWebLoginSheet: View {
    /// 登录成功（refresh + status 已确认）后回调；调用方一般用它关掉外层扫码页。
    var onLoggedIn: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var status: String = "在网页里登录 QQ 音乐，登完点下面的「同步登录状态」。"
    @State private var syncing = false
    @State private var synced = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                QQWebLoginWebView(url: URL(string: "https://y.qq.com")!)
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
                        Button("关闭") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle("QQ 网页登录")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// 读整罐 cookie → 按域合并 → 客户端先验（与后端 `webLoginImport`
    /// 同规则，缺项直接报原因、不发请求）→ POST /api/qq/login/web →
    /// refresh + status 确认 → 回调 + 关弹窗。
    private func sync() {
        syncing = true
        status = "正在读取登录状态…"
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let merged = Self.mergedCookieString(cookies)
            guard !merged.isEmpty else {
                syncing = false
                status = "没读到任何 QQ 登录 Cookie：请确认已在网页里登录，再点一次。"
                return
            }
            if let problem = Self.cookieProblem(merged) {
                syncing = false
                status = problem
                return
            }
            Task { @MainActor in
                let resp = await NativeBridge.call(path: "/api/qq/login/web",
                                                   method: "POST", body: ["cookie": merged])
                guard let obj = resp,
                      (obj["code"] as? NSNumber)?.intValue == 200,
                      (obj["loggedIn"] as? NSNumber)?.boolValue == true else {
                    syncing = false
                    // 失败原因优先用本次响应自己的 error，没有就给通用文案；
                    // 不重复发请求。
                    status = (resp?["error"] as? String)
                        ?? "同步失败，请确认已在网页里登录，再点一次。"
                    return
                }
                // 后端已存凭证：refresh 后以 status 接口为准确认再关。
                _ = await LoginStore.refresh(platform: "qq")
                if await QQLoginView.isLoggedInViaStatus() {
                    synced = true
                    let nickname = (obj["nickname"] as? String) ?? ""
                    status = "登录成功" + (nickname.isEmpty ? "" : "：\(nickname)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        onLoggedIn?()
                        dismiss()
                    }
                } else {
                    syncing = false
                    status = "登录已导入，但状态确认失败，请重新打开登录页查看。"
                }
            }
        }
    }

    // MARK: - Cookie 合并与校验（与后端 webLoginImport 同规则）

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

    /// 把 `k=v; k=v`（也容忍按行复制的换行分隔）拆成小写键名字典；
    /// 值做 percent-decode（后端第 14 轮同款：只按 ';' 切会把票据吞进 uin）。
    static func cookieFields(_ raw: String) -> [String: String] {
        var fields: [String: String] = [:]
        for item in raw.components(separatedBy: CharacterSet(charactersIn: ";\n\r")) {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let k = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let v = pair[1].trimmingCharacters(in: .whitespacesAndNewlines).removingPercentEncoding
                ?? pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty && !v.isEmpty { fields[k] = v }
        }
        return fields
    }

    /// 账号 id 取 uin / p_uin / pt2gguin / qqmusic_uin / loginuin（p_uin 开头
    /// 的 "o" 去掉；"0" / "null" 不算）；凭证取第一个非空的 qqmusic_key /
    /// qm_keyst / musickey / music_key / p_skey / skey / psrf_access_token /
    /// psrf_qq_access_token。两样缺一不可，缺了返回后端同款中文原因。
    static func cookieProblem(_ raw: String) -> String? {
        let fields = cookieFields(raw)
        var uin = ""
        for key in ["uin", "p_uin", "pt2gguin", "qqmusic_uin", "loginuin"] {
            guard let v = fields[key], !v.isEmpty else { continue }
            let norm = v.hasPrefix("o") ? String(v.dropFirst()) : v
            if norm != "0" && norm.lowercased() != "null" && !norm.isEmpty { uin = norm; break }
        }
        guard !uin.isEmpty else {
            return "网页登录没拿到 QQ 号（缺 uin / p_uin）：请确认已在网页里登录，再点一次「同步登录状态」"
        }
        for key in ["qqmusic_key", "qm_keyst", "musickey", "music_key", "p_skey", "skey",
                    "psrf_access_token", "psrf_qq_access_token"] {
            if let v = fields[key], !v.isEmpty { return nil }
        }
        return "网页登录没拿到登录票据（缺 qqmusic_key / p_skey）：请确认已在网页里登录，再点一次「同步登录状态」"
    }
}

/// 只做登录页展示的 WKWebView：桌面 contentMode + 写死的 macOS Safari UA
/// 两道保险，只改这只登录 WebView，不动主 WebView；不注入 JS、不读输入框。
private struct QQWebLoginWebView: UIViewRepresentable {
    let url: URL

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
