import Foundation
import Security

/// 登录 Cookie 的本机钥匙串底座（r31-qqkg：QQ/酷狗登录改本机直连）。
///
/// 只做一件事：把整段 Cookie 字符串存进钥匙串（service 按平台区分，
/// account 固定 "cookie"，iOS 上 AfterFirstUnlockThisDeviceOnly）。
/// 不存账号密码，不打日志，不把 Cookie 写进任何文件或诊断。
/// 未签名 IPA 上钥匙串可能写失败（errSec*），调用方要把失败翻译成
/// 明白话告诉用户，不要只报 "保存失败"。
enum LiziKeychain {
    enum KeychainError: LocalizedError {
        case storageFailed(OSStatus)
        var errorDescription: String? {
            switch self {
            case .storageFailed:
                return "钥匙串写不进去（未签名安装包常见）：登录状态这次只保存在内存里，重启 App 后要重新登录；签名安装后就好了"
            }
        }
    }

    static func readCookie(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "cookie",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func writeCookie(_ cookie: String, service: String) throws {
        let data = Data(cookie.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "cookie",
        ]
        var attributes: [String: Any] = [kSecValueData as String: data]
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.storageFailed(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.storageFailed(status)
        }
    }

    static func deleteCookie(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "cookie",
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Cookie 文本工具（QQ/酷狗两家共用；只做解析，不发网）

    /// 去 `cookie:` 前缀、换行压成空格、连续空白压成一个空格。
    static func normalizedCookie(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "cookie:", options: [.caseInsensitive, .anchored]) {
            value.removeSubrange(range)
        }
        value = value.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 像一段 Cookie 吗（有 `k=v` 的段；长度上限 32000）。
    static func looksLikeCookie(_ value: String) -> Bool {
        guard value.count <= 32_000, value.contains("=") else { return false }
        return value.split(separator: ";").contains {
            $0.split(separator: "=", maxSplits: 1).count == 2
        }
    }

    /// `k=v; k=v`（也容忍换行分隔、JSON 对象）→ 小写键名字典；
    /// 值做 percent-decode。键名小写归一化，调用方按小写键查。
    static func cookieFields(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return out }
        if text.hasPrefix("{"),
           let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in obj where !k.isEmpty {
                if let s = v as? String { out[k.lowercased()] = s.removingPercentEncoding ?? s }
                else if let n = v as? NSNumber { out[k.lowercased()] = n.stringValue }
            }
            return out
        }
        for part in text.components(separatedBy: CharacterSet(charactersIn: ";\n\r")) {
            guard let i = part.firstIndex(of: "="), i != part.startIndex else { continue }
            let k = part[..<i].trimmingCharacters(in: .whitespaces).lowercased()
            var v = part[part.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            v = v.removingPercentEncoding ?? v
            if !k.isEmpty, !v.isEmpty { out[k] = v }
        }
        return out
    }

    /// 字典拼回 `k=v; k=v`（按 key 排序，稳定输出）。
    static func cookieString(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }
}
