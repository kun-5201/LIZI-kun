import SwiftUI

/// 酷我登录（r23e）：只支持粘贴 Cookie 登录。
///
/// 后端事实（Kuwo.swift，不改）：
/// - 后端 login/qr/* 一律回 501。本视图只有一处粘贴框 + 「导入登录」。
/// - POST /api/kuwo/login/cookie，body 字段 cookie（或 value），要求
///   userid + sid（sid 或 websid）；缺了回 loggedIn:false + error。
/// - statusBody：vip 硬编码 false；登录后也按普通用户、播放走 LX。
/// - 酷我 Web 没有可用的登录校验接口，登录态只来自粘贴的 Cookie。
///
/// 接口契约（r23a 共享底座提供，本文件只调用、不自建）：
/// - NativeBridge.call(path:method:body:)：带 JSON body 的重载，
///   body: [String: Any]。
/// - LoginStore.refresh(platform:)：登录成功后刷新共享登录态。
/// - LoginStore.logout(platform:)：登出（调后端 /api/kuwo/logout）。
/// 登录态以 status 接口（GET /api/kuwo/status）为准。
struct KuwoLoginView: View {
    @State private var cookieText = ""
    @State private var message = ""
    @State private var messageIsError = false
    @State private var isBusy = false
    @State private var loggedIn = false
    @State private var uid = ""
    @State private var statusNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("酷我音乐")
                .font(.headline)

            if loggedIn {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已登录")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    if !uid.isEmpty {
                        Text("uid：\(uid)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("登录态来自粘贴的 Cookie；酷我 Web 没有可用的校验接口，播放时会自动带上。登录后仍按普通用户播放，走 LX 取链。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("登出") { Task { await logout() } }
                        .disabled(isBusy)
                        .buttonStyle(.bordered)
                }
            } else {
                Text("只能粘贴 Cookie 登录。先在浏览器打开 www.kuwo.cn 登录，再从开发者工具 → Application → Cookies 复制整段 Cookie（要含 userid 和 sid），粘贴到下面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $cookieText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                        )
                    if cookieText.isEmpty {
                        Text("userid=…; sid=…;（或整段 Cookie）")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                }

                HStack(spacing: 12) {
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { cookieText = first }
                    }
                    .buttonStyle(.bordered)
                    .labelStyle(.titleOnly)

                    Button("导入登录") { Task { await importLogin() } }
                        .disabled(isBusy || cookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .buttonStyle(.borderedProminent)
                }
            }

            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(messageIsError ? .red : .green)
            }
            if !statusNote.isEmpty && !loggedIn {
                Text(statusNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task { await refreshStatus() }
    }

    // MARK: - 状态（以 status 接口为准）

    private func refreshStatus() async {
        guard let d = await NativeBridge.call(path: "/api/kuwo/status") else {
            await MainActor.run {
                message = NativeBridge.searchErrorText
                messageIsError = true
            }
            return
        }
        await MainActor.run {
            loggedIn = (d["loggedIn"] as? Bool) ?? false
            uid = (d["uid"] as? String) ?? ""
            statusNote = (d["note"] as? String) ?? ""
        }
    }

    // MARK: - 导入登录

    private func importLogin() async {
        let raw = cookieText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            await MainActor.run {
                message = "先把 Cookie 粘进来"
                messageIsError = true
            }
            return
        }
        // 先在客户端按后端 parseCookieInput 的同一规则查缺项，缺哪项就明说，
        // 不等后端那句不分缺哪项的笼统 error。
        let missing = Self.missingFields(in: raw)
        if !missing.isEmpty {
            let detail: String
            if missing.contains("userid") && missing.contains("sid") {
                detail = "Cookie 里缺 userid 和 sid（或 websid），请复制整段 Cookie"
            } else if missing.contains("userid") {
                detail = "Cookie 里缺 userid，请复制整段 Cookie"
            } else {
                detail = "Cookie 里缺 sid（或 websid），请复制整段 Cookie"
            }
            await MainActor.run {
                message = detail
                messageIsError = true
            }
            return
        }
        await MainActor.run { isBusy = true }
        defer { Task { @MainActor in isBusy = false } }
        guard let d = await NativeBridge.call(
            path: "/api/kuwo/login/cookie", method: "POST", body: ["cookie": raw]
        ) else {
            await MainActor.run {
                message = NativeBridge.searchErrorText
                messageIsError = true
            }
            return
        }
        if (d["loggedIn"] as? Bool) == true {
            await LoginStore.refresh(platform: "kuwo")
            await MainActor.run {
                cookieText = ""
                message = "登录成功"
                messageIsError = false
            }
            await refreshStatus()
        } else {
            await MainActor.run {
                message = (d["error"] as? String) ?? "导入失败，请检查 Cookie 是否完整。"
                messageIsError = true
            }
        }
    }

    // MARK: - 登出

    private func logout() async {
        await MainActor.run { isBusy = true }
        defer { Task { @MainActor in isBusy = false } }
        await LoginStore.logout(platform: "kuwo")
        await refreshStatus()
        await MainActor.run {
            if loggedIn {
                message = "登出后状态仍是已登录，请重试"
                messageIsError = true
            } else {
                message = "已登出"
                messageIsError = false
            }
        }
    }

    // MARK: - Cookie 缺项判定（与 KuwoService.parseCookieInput 同规则）

    /// 返回缺的项（"userid" / "sid" 的子集）。规则照抄后端：
    /// 去首尾空白、去 `cookie:` 前缀；`{` 开头按 JSON 解析（键小写归一化，
    /// 值 percent-decode）；否则按 `;` / 换行切 `k=v`（键小写归一化，
    /// 值去首尾空白、去成对引号、percent-decode）。
    /// userid 认 userid / uid；sid 认 sid / websid。
    static func missingFields(in raw: String) -> [String] {
        var parsed: [String: String] = [:]
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ["userid", "sid"] }
        if let r = text.range(of: #"^cookie\s*:\s*"#, options: .regularExpression) {
            text = String(text[r.upperBound...])
        }
        if text.hasPrefix("{") {
            if let data = text.data(using: .utf8),
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in j where !k.isEmpty {
                    if let s = v as? String {
                        parsed[k.lowercased()] = s.removingPercentEncoding ?? s
                    }
                }
            }
        } else {
            let seps = CharacterSet(charactersIn: ";\n\r")
            for part in text.components(separatedBy: seps) {
                guard let i = part.firstIndex(of: "="), i != part.startIndex else { continue }
                let k = part[..<i].trimmingCharacters(in: .whitespaces).lowercased()
                var v = part[part.index(after: i)...].trimmingCharacters(in: .whitespaces)
                if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                    v = String(v.dropFirst().dropLast())
                }
                v = v.removingPercentEncoding ?? v
                if !k.isEmpty { parsed[k] = v }
            }
        }
        var missing: [String] = []
        let uid = parsed["userid"] ?? parsed["uid"] ?? ""
        let sid = parsed["sid"] ?? parsed["websid"] ?? ""
        if uid.isEmpty { missing.append("userid") }
        if sid.isEmpty { missing.append("sid") }
        return missing
    }
}
