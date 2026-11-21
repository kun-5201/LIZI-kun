import Foundation
import CommonCrypto
import Compression
import CoreImage
import UIKit

/// 酷狗音乐：Folia 酷狗实现的 Swift 移植（r24 新写）。
///
/// 对照出处（只学流程与接口，不抄代码；Folia 是 AGPL-3.0，本文件是
/// 照其接口与流程新写的 Swift 实现；协议常数注明来源）：
/// - 流程总纲：Folia `src/services/onlineMusic/kugou/kugouProvider.ts`
///   （搜索 / 取链降级 / 歌词两步 / 登录三步 / 歌单 / 每日 / 电台）。
/// - 直连端点：Folia `kugouTransport.ts`（匿名搜索、legacy playInfo 兜底）、
///   `kugouLyricProvider.ts`（歌词搜索 + 下载）。
/// - 网关协议（签名盐、appid、RSA 公钥、x-router、模块参数）：
///   KuGouMusicApi v1.6.0（MIT）`util/helper.js`、`util/request.js`、
///   `util/crypto.js`、`util/util.js`、`module/*.js`。
/// - KRC 解码：上游 `util/util.js` 的 decodeLyrics（XOR 16 字节密钥 +
///   跳过 `krc1` 头 + zlib 解压）；解出的 KRC 文本再经已有的
///   `krcToLrc` / `krcToYrc` 转 LRC / YRC（与汽水共用同一份转换）。
///
/// 登录态：`SessionStore.sidecarAuth("kugou")` 只收 token / userid /
/// vip_type / vip_token / dfid / webCookie；设备身份走 `sidecarAuth("kugou-device")`
///（guid / mid；GUID 32 位 hex 持久化，删了等于换设备）。
/// r31-cookie：`webCookie` 是扫码确认 / Cookie 导入时收割的整罐 web 会话
/// Cookie（不含 token/userid——发请求时 `webCookieHeader()` 再并进去，
/// Folia `getWebSessionCookie` 同款；KuGouMusicApi 各模块的 `cookie:`
/// 就是这罐，不带它用户歌单那路回 error_code 152）。
/// 二维码官方图记内存 Map（key → qrimg，最多 64 张；create 优先回官方图）。
///
/// 关键结论（Folia 流程 + 2026-11-20 VM 实测）：
/// - 匿名 `playInfo` 拿不到 URL：播放必须登录（网关 `/v5/url` 匿名回
///   20028「本次请求需要验证」）；20028 时先调 register_dev 再重试一次，
///   仍 20028 则回 `reason:"login"`，不再降档重试。
///   r28 修：`/v5/url` 的 20028 回包字段是 `errcode`（数字；无签名的
///   20006 回包里还是字符串 `"20006"`），不是 `error_code`——旧
///   `upstreamErrorCode` 只读 `error_code`，`needsVerify` 恒为假，
///   register_dev 重试从未真正触发过（2026-11-21 VM 实测：带签名的
///   匿名 `/v5/url` 回 `{"errcode":20028,"status":0,"error":"本次请求
///   需要验证"}`；不带签名回 `errcode:"20006" errmsg:"err signature"`，
///   所以签名必须带——上游 `song_url.js` 的 `notSign:true` 是死键，
///   `request.js` 只认 `notSignature`，照抄 `notSign` 反而会签错）。
///   另外：无 token 且整条链都没拿到地址时也回 `reason:"login"`
///  （Folia `kugouNoUrlError(noUrlSeen, signedOut:true)` 同款：未登录
///   + 没给地址 → 登录后可能能放）。
/// - 匿名搜索走 complexsearch/v2（Folia 用 http；本实现用 https，
///   VM 实测同一 host 的 https 同样回 200）。
/// - 登录态搜索走网关 `/v3/search/song`；首页回空时退回匿名再搜一次
///   并记住该关键词，后续页直接匿名（Folia 同款）。
/// - 取链降级（Folia `QUALITY_FALLBACKS`）：每档先试带 album_id /
///   album_audio_id 的 `song_url`，再试 hash-only；全部失败最后试一次
///   legacy playInfo；云盘曲目只走 `user_cloud_url`。
///
/// 全程 async：无同步阻塞、无强制解包、无空 Data 假设；KRC 解压等重活
/// 在 async 任务内做，不占主线程。
actor FoliaKugouService {

    // MARK: - 协议常数（KuGouMusicApi v1.6.0 util/config.json、util/helper.js）

    /// 网关基址（`util/request.js` 的默认 baseURL）。
    private static let gateway = "https://gateway.kugou.com"
    /// 概念版（lite）appid / clientver：Folia 走 lite
    ///（`process.env.platform = 'lite'`）。
    private static let liteAppid = "3116"
    private static let liteClientver = "11440"
    /// 标准版 appid / clientver：少数模块（search_lyric、top_playlist、
    /// personal_fm、fm_class、fm_songs、artist_audios、audio 等的 body）
    /// 直接取 `util` 导出的标准值，用这两个。
    private static let stdAppid = "1005"
    private static let stdClientver = "20489"
    private static let srcappid = "2919"
    /// Android-lite 签名盐（`util/helper.js` signatureAndroidParams）。
    private static let androidLiteSalt = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
    /// Android 标准版签名盐（`util/helper.js` signParamsKey 非 lite 分支）。
    private static let androidStdSalt = "OIlwieks28dk2k092lksi2UIkp"
    /// Web 签名盐（`util/helper.js` signatureWebParams）。
    private static let webSalt = "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt"
    /// register_dev 签名盐（`util/helper.js` signatureRegisterParams，
    /// 固定 "1014"）。
    private static let registerSalt = "1014"
    /// 通用 sign 盐（`util/helper.js` signParams）。
    private static let signParamsSalt = "R6snCXJgbCaj9WFRJKefTMIFp0ey6Gza"
    /// song_url 的 key 盐（lite，`util/helper.js` signKey）。
    private static let signKeyLiteSalt = "185672dd44712f60bb1736df5a377e82"
    /// 云盘 key 盐（`util/helper.js` signCloudKey）。
    private static let signCloudKeySalt = "ebd1ac3134c880bda6a2194537843caa0162e2e7"
    /// 网关 UA（`util/request.js`）。
    private static let gatewayUA = "Android15-1070-11083-46-0-DiscoveryDRADprotocol-wifi"
    /// 匿名搜索 UA（Folia `kugouTransport.ts`）。
    private static let anonSearchUA = "Android14-1070-11070-201-0-SearchSong-wifi"
    /// legacy playInfo UA（Folia `kugouTransport.ts`）。
    private static let legacyUA = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124.0.0.0 Mobile Safari/537.36"
    /// KRC XOR 密钥（上游 `util/util.js` decodeLyrics）。
    private static let krcKey: [UInt8] = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105]
    /// 封面标准尺寸（Folia `KUGOU_CANONICAL_COVER_SIZE = 1024`；
    /// `union_cover` 的 `{size}` 占位符换成它）。
    private static let coverSize = 1024
    /// 概念版 RSA 公钥（1024 位，`util/crypto.js` publicLiteRasKey，
    /// PEM 的 base64 体；SecKey 直接吃 SPKI DER，不用手拼）。
    private static let liteRSAPublicKeyB64 = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDECi0Np2UR87scwrvTr72L6oO01rBbbBPriSDFPxr3Z5syug0O24QyQO8bg27+0+4kBzTBTBOZ/WWU0WryL1JSXRTXLgFVxtzIY41Pe7lPOgsfTCn5kZcvKhYKJesKnnJDNr5/abvTGf+rHG3YRwsCHcQ08/q6ifSioBszvb3QiwIDAQAB"

    private let store = SessionStore.shared

    /// 匿名搜索回退过的关键词（Folia `kugouAnonymousSearchFallbackKeywords`
    /// 同款：登录态搜索首页回空后退回匿名并记住，后续页直接匿名）。
    private var anonFallbackKeywords: Set<String> = []

    // MARK: - 设备与登录态

    /// 设备身份：guid（UUID v4，去横线后 32 位 hex，持久化）与
    /// mid（`util/util.js` calculateMid：MD5(guid) 按 16 进制大整数
    /// 转十进制字符串）。dfid 来自登录态（register_dev 回填），没有为 "-"。
    /// r31-qqkg：本机 KugouSessionStore 同步的 deviceMid（毫秒时间戳，
    /// 存在 sidecar "kugou-device" 的 mid 字段里）优先用——本机与服务端
    /// 必须是同一台设备；没有才按旧法由 guid 算（向后兼容）。
    private func deviceIdentity() -> (guid: String, mid: String, dfid: String) {
        var guid = ""
        var mid = ""
        if let dev = store.sidecarAuth("kugou-device") {
            if let g = dev["guid"] as? String, !g.isEmpty { guid = g }
            if let m = dev["mid"] as? String, !m.isEmpty { mid = m }
            else if let m = dev["mid"] as? NSNumber { mid = m.stringValue }
        }
        if guid.isEmpty {
            guid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            var dev: [String: Any] = ["guid": guid]
            if !mid.isEmpty { dev["mid"] = mid }
            store.saveSidecarAuth("kugou-device", dev)
        }
        if mid.isEmpty { mid = Self.hexToDecimal(Crypto.md5Hex(guid)) }
        let dfid = (store.sidecarAuth("kugou")?["dfid"] as? String) ?? "-"
        return (guid, mid, dfid.isEmpty ? "-" : dfid)
    }

    /// 登录态（只读已存的 token / userid / vip_type / vip_token）。
    /// r31-cookie：多读 `webCookie`（扫码确认 / Cookie 导入时收割的整罐
    /// web 会话 Cookie，不含 token/userid 那两项——发请求时
    /// `webCookieHeader()` 再把 token/userid/dfid 并进去，Folia
    /// `getWebSessionCookie` 同款拼法）。
    private func loginState() -> (token: String, userid: String, vipType: String, vipToken: String, webCookie: String) {
        let a = store.sidecarAuth("kugou") ?? [:]
        let token = a["token"] as? String ?? ""
        let userid: String
        if let u = a["userid"] as? String { userid = u }
        else if let u = a["userid"] as? NSNumber { userid = u.stringValue }
        else { userid = "" }
        return (token, userid, a["vip_type"] as? String ?? "", a["vip_token"] as? String ?? "",
                a["webCookie"] as? String ?? "")
    }

    /// r31-cookie：发往上游的整罐 Cookie（Folia `kugouTransport.ts`
    /// `getWebSessionCookie` 同款）：先放存下来的 web 会话 Cookie 各条，
    /// 再用 dfid / token / userid 覆盖同名项（KuGouMusicApi
    /// `login_qr_check.js` 在 status 4 时就是往 cookie 数组里追加
    /// `token=` / `userid=` 两条；这里发请求时现拼，等价）。
    /// 空串 = 没登录过 / 没收割到，`gateway()` 不发 Cookie 头。
    private func webCookieHeader() -> String? {
        let login = loginState()
        var jar: [String: String] = [:]
        var order: [String] = []
        for seg in login.webCookie.split(separator: ";") {
            let kv = seg.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces)
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty, !v.isEmpty else { continue }
            if jar[k] == nil { order.append(k) }
            jar[k] = v
        }
        let dev = deviceIdentity()
        if !dev.dfid.isEmpty, dev.dfid != "-" { jar["dfid"] = dev.dfid; if !order.contains("dfid") { order.append("dfid") } }
        if !login.token.isEmpty { jar["token"] = login.token; if !order.contains("token") { order.append("token") } }
        if !login.userid.isEmpty { jar["userid"] = login.userid; if !order.contains("userid") { order.append("userid") } }
        guard !order.isEmpty else { return nil }
        return order.map { "\($0)=\(jar[$0]!)" }.joined(separator: "; ")
    }

    /// 保存登录态：只并入新给的字段，旧字段（dfid 等）保留。
    private func saveLoginState(token: String? = nil, userid: String? = nil,
                                vipType: String? = nil, vipToken: String? = nil, dfid: String? = nil,
                                webCookie: String? = nil) {
        var a = store.sidecarAuth("kugou") ?? [:]
        if let token { a["token"] = token }
        if let userid { a["userid"] = userid }
        if let vipType { a["vip_type"] = vipType }
        if let vipToken { a["vip_token"] = vipToken }
        if let dfid { a["dfid"] = dfid }
        if let webCookie { a["webCookie"] = webCookie }
        store.saveSidecarAuth("kugou", a)
    }

    private func clearLoginState() {
        store.clearSidecarAuth("kugou")
        anonFallbackKeywords.removeAll()
    }

    // MARK: - 有序 JSON（签名要与 body 字节一致）

    /// JS `JSON.stringify` 的顺序敏感写法：Swift 的 JSONSerialization
    /// 会按 key 排序，签不过——POST body 一律用这份有序模型拼串，
    /// 拼出的串既作 body 也作签名输入（`util/request.js` 的
    /// signatureAndroidParams(params, data) 同款：盐 + 参数串 + body 串 + 盐）。
    private indirect enum JVal {
        case s(String)
        case i(Int)
        case b(Bool)
        case n
        case a([JVal])
        case o([(String, JVal)])
    }

    private static func jsonString(_ v: JVal) -> String {
        switch v {
        case .s(let s):
            var out = "\""
            for ch in s {
                switch ch {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default: out.append(ch)
                }
            }
            return out + "\""
        case .i(let n): return String(n)
        case .b(let x): return x ? "true" : "false"
        case .n: return "null"
        case .a(let arr): return "[" + arr.map { jsonString($0) }.joined(separator: ",") + "]"
        case .o(let pairs): return "{" + pairs.map { jsonString(.s($0.0)) + ":" + jsonString($0.1) }.joined(separator: ",") + "}"
        }
    }

    // MARK: - MD5 与签名（util/helper.js）

    /// MD5（字节版）：Crypto.md5Hex 只接 String；POST 签名要对
    ///「盐 + 参数串 + body 字节 + 盐」整段取 MD5，这里直接拼 Data。
    private static func md5Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func md5Hex(parts: [Data]) -> String {
        var all = Data()
        for p in parts { all.append(p) }
        return md5Hex(all)
    }

    /// 参数串：key 排字母序，`key=value` 连起来（web / android 同款）。
    private static func sortedParamString(_ params: [String: String]) -> String {
        params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined()
    }

    /// Web 签名：MD5(盐 + 参数串 + 盐)。
    private static func webSignature(_ params: [String: String]) -> String {
        Crypto.md5Hex(webSalt + sortedParamString(params) + webSalt)
    }

    /// Android-lite 签名：MD5(盐 + 参数串 + body + 盐)；GET 时 body 为空。
    private static func androidSignature(_ params: [String: String], body: Data?) -> String {
        md5Hex(parts: [Data(androidLiteSalt.utf8), Data(sortedParamString(params).utf8),
                        body ?? Data(), Data(androidLiteSalt.utf8)])
    }

    /// register_dev 签名：只取参数值排字母序，MD5("1014" + 值串 + "1014")。
    private static func registerSignature(_ params: [String: String]) -> String {
        Crypto.md5Hex(registerSalt + params.values.sorted().joined() + registerSalt)
    }

    /// signParams：key 排字母序、`key+value`（无等号）连起来，
    /// MD5(参数串 + data + 盐)。
    private static func signParams(_ params: [String: String], data: String) -> String {
        let s = params.keys.sorted().map { "\($0)\(params[$0] ?? "")" }.joined()
        return Crypto.md5Hex(s + data + signParamsSalt)
    }

    /// signKey（lite）：MD5(hash + 盐 + appid + mid + userid)。
    private static func signKey(hash: String, mid: String, userid: String, appid: String) -> String {
        Crypto.md5Hex(hash + signKeyLiteSalt + appid + mid + (userid.isEmpty ? "0" : userid))
    }

    /// signCloudKey：MD5("musicclound" + hash + pid + 盐)。
    private static func signCloudKey(hash: String, pid: Int) -> String {
        Crypto.md5Hex("musicclound" + hash + String(pid) + signCloudKeySalt)
    }

    /// signParamsKey（标准默认）：MD5(appid + 盐 + clientver + data)。
    /// 库里 key 与 body 的 appid / clientver 必须同族（lite 环境全 lite、
    /// 标准环境全标准；`util/helper.js` 的默认值跟 `process.env.platform`
    /// 走）；本实现 body 一律标准 1005/20489，所以默认走标准族。
    /// VM 实测：fm.service 混用两族（body 标准 + lite key）报 20006，
    /// 全标准与全 lite 都通；kmr 容忍混用，但同样改标准族以求一致。
    private static func signParamsKey(data: String, appid: String? = nil, clientver: String? = nil) -> String {
        Crypto.md5Hex((appid ?? stdAppid) + androidStdSalt + (clientver ?? stdClientver) + data)
    }

    /// 16 进制 MD5 串按大整数转十进制（`util/util.js` calculateMid）。
    private static func hexToDecimal(_ hex: String) -> String {
        var digits: [Int] = [0]
        for ch in hex.lowercased() {
            guard let v = Int(String(ch), radix: 16) else { continue }
            var carry = v
            for i in (0..<digits.count).reversed() {
                let cur = digits[i] * 16 + carry
                digits[i] = cur % 10
                carry = cur / 10
            }
            while carry > 0 {
                digits.insert(carry % 10, at: 0)
                carry /= 10
            }
        }
        return digits.map(String.init).joined()
    }

    // MARK: - RSA / AES（util/crypto.js，概念版公钥）

    private static func litePublicKey() -> SecKey? {
        guard let der = Data(base64Encoded: liteRSAPublicKeyB64) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024,
        ]
        return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil)
    }

    /// 原始 RSA（`cryptoRSAEncrypt` 同款）：JSON 明文放进 128 字节缓冲的
    /// 头部、其余补零（库里就是左对齐、尾部补零），m^e mod n，回大写 hex。
    private func rsaRawEncryptUpperHex(_ json: String) -> String? {
        guard let key = Self.litePublicKey(),
              let plain = json.data(using: .utf8), plain.count <= 128 else { return nil }
        var buf = Data(count: 128)
        buf.replaceSubrange(0..<plain.count, with: plain)
        guard let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, buf as CFData, nil) as Data? else { return nil }
        return cipher.map { String(format: "%02X", $0) }.joined()
    }

    /// PKCS1 v1.5 RSA（`rsaEncrypt2` 同款）：JSON 明文直接加密，回小写 hex；
    /// 调用点要大写时自己 `.uppercased()`（playlist_del / user_cloud 同款）。
    private func rsaPKCS1EncryptHex(_ json: String) -> String? {
        guard let key = Self.litePublicKey(),
              let plain = json.data(using: .utf8) else { return nil }
        guard let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, plain as CFData, nil) as Data? else { return nil }
        return cipher.map { String(format: "%02x", $0) }.joined()
    }

    /// AES-128-CBC/PKCS7（`playlistAesEncrypt` 同款）：6 位小写随机 key；
    /// 加密 key = MD5(key)[0:16] 的 ASCII 字节，iv = MD5(key)[16:32]。
    /// 回 (key, base64 密文)。
    private static func aesEncrypt(_ json: String) -> (key: String, base64: String)? {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var key = ""
        for _ in 0..<6 { key.append(alphabet[Int.random(in: 0..<alphabet.count)]) }
        let md5 = Crypto.md5Hex(key)
        guard let keyData = String(md5.prefix(16)).data(using: .utf8),
              let ivData = String(md5.dropFirst(16).prefix(16)).data(using: .utf8),
              let plain = json.data(using: .utf8) else { return nil }
        var out = Data(count: plain.count + kCCBlockSizeAES128)
        var outLen = 0
        // r24 构建修（run 44658757593）：`out.count` 在
        // `out.withUnsafeMutableBytes` 闭包里读 `out`，与已借出的可变借用
        // 重叠，编译器报 overlapping accesses。先拷到局部量再进闭包。
        let outCapacity = out.count
        let status = keyData.withUnsafeBytes { kPtr in
            ivData.withUnsafeBytes { ivPtr in
                plain.withUnsafeBytes { pPtr in
                    out.withUnsafeMutableBytes { oPtr in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                kPtr.baseAddress, keyData.count, ivPtr.baseAddress,
                                pPtr.baseAddress, plain.count, oPtr.baseAddress, outCapacity, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLen
        return (key, out.base64EncodedString())
    }

    /// AES 解密（`playlistAesDecrypt` 同款）：base64 密文 → JSON 对象；
    /// 解不出回 nil。
    private static func aesDecryptJSON(_ base64: String, key: String) -> [String: Any]? {
        let md5 = Crypto.md5Hex(key)
        guard let keyData = String(md5.prefix(16)).data(using: .utf8),
              let ivData = String(md5.dropFirst(16).prefix(16)).data(using: .utf8),
              let cipher = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        var out = Data(count: cipher.count + kCCBlockSizeAES128)
        var outLen = 0
        // r24 构建修（run 44658757593）：同 aesEncrypt，`out.count` 先拷
        // 到局部量，避免与 withUnsafeMutableBytes 的可变借用重叠。
        let outCapacity = out.count
        let status = keyData.withUnsafeBytes { kPtr in
            ivData.withUnsafeBytes { ivPtr in
                cipher.withUnsafeBytes { cPtr in
                    out.withUnsafeMutableBytes { oPtr in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                kPtr.baseAddress, keyData.count, ivPtr.baseAddress,
                                cPtr.baseAddress, cipher.count, oPtr.baseAddress, outCapacity, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = outLen
        guard let text = String(data: out, encoding: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    // MARK: - KRC 解码与二维码

    /// KRC 解码（上游 decodeLyrics）：base64 → 跳过 `krc1` 头 4 字节 →
    /// XOR 16 字节密钥 → zlib 解压 → UTF-8 文本。
    private static func krcDecode(_ base64: String) -> String? {
        guard var bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              bytes.count > 4 else { return nil }
        bytes.removeFirst(4)
        var xored = [UInt8](bytes)
        for i in xored.indices { xored[i] ^= krcKey[i % krcKey.count] }
        guard let inflated = zlibInflate(Data(xored)) else { return nil }
        return String(data: inflated, encoding: .utf8)
    }

    /// zlib 解压（Kuwo.swift 的 zlibInflate 同款：缓冲不够就 ×4 再试）。
    private static func zlibInflate(_ data: Data) -> Data? {
        var size = max(data.count * 8, 65536)
        for _ in 0..<4 {
            var out = Data(count: size)
            var decoded = 0
            let ok: Bool = data.withUnsafeBytes { src in
                out.withUnsafeMutableBytes { dst in
                    guard let s = src.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
                    decoded = compression_decode_buffer(d, size, s, data.count, nil, COMPRESSION_ZLIB)
                    return decoded > 0
                }
            }
            if ok { return out.prefix(decoded) }
            size *= 4
        }
        return nil
    }

    // MARK: - 网关传输（util/request.js 的 createRequest 同款）

    private struct KGResponse {
        let httpStatus: Int
        let json: [String: Any]?
        let raw: Data
        /// r31-cookie：本次响应上游下发的 Set-Cookie（已按 `k=v` 拆干净，
        /// 属性段不要；扫码确认收割进登录态、`gateway` 不再丢）。
        /// 空数组 = 上游这次没下发。
        let setCookies: [String]
    }

    private enum KGEncrypt {
        case android, web, register, none
    }

    /// 网关调用：默认参数注入（dfid / mid / uuid / appid / clientver /
    /// clienttime，登录后加 token / userid）→ encryptKey（song_url 的 key）
    /// → 签名 → 请求头（dfid / clienttime / mid / kg-* / UA / x-router）
    /// → 发送 → 回 JSON（解不出时 json 为 nil，raw 留着给 AES 解密用）。
    /// `clearDefault` 为真时不注入默认参数（search_lyric、user_cloud 同款）。
    /// `skipSignature` 为真时不签名（user_cloud 同款，`notSignature: true`）。
    private func gateway(path: String, baseURL: String = gateway,
                        method: String = "GET",
                        params: [String: String] = [:],
                        body: JVal? = nil, bodyRaw: Data? = nil,
                        xRouter: String? = nil,
                        extraHeaders: [String: String] = [:],
                        encrypt: KGEncrypt = .android,
                        clearDefault: Bool = false,
                        skipSignature: Bool = false,
                        encryptKey: Bool = false) async throws -> KGResponse {
        let dev = deviceIdentity()
        let login = loginState()
        let clienttime = String(Int(Date().timeIntervalSince1970))
        var allParams: [String: String] = [:]
        if !clearDefault {
            allParams["dfid"] = dev.dfid
            allParams["mid"] = dev.mid
            allParams["uuid"] = "-"
            allParams["appid"] = Self.liteAppid
            allParams["clientver"] = Self.liteClientver
            allParams["clienttime"] = clienttime
            if !login.token.isEmpty { allParams["token"] = login.token }
            if !login.userid.isEmpty { allParams["userid"] = login.userid }
        }
        for (k, v) in params { allParams[k] = v }
        if encryptKey {
            allParams["key"] = Self.signKey(hash: (allParams["hash"] ?? "").lowercased(),
                                            mid: dev.mid, userid: login.userid,
                                            appid: allParams["appid"] ?? Self.liteAppid)
        }
        let bodyData: Data? = bodyRaw ?? (body.map { Data(Self.jsonString($0).utf8) })
        if !skipSignature {
            switch encrypt {
            case .android: allParams["signature"] = Self.androidSignature(allParams, body: bodyData)
            case .web: allParams["signature"] = Self.webSignature(allParams)
            case .register: allParams["signature"] = Self.registerSignature(allParams)
            case .none: break
            }
        }
        var comps = URLComponents(string: baseURL + path)
        comps?.queryItems = allParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps?.url else {
            throw NSError(domain: "FoliaKugou", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "bad url: \(path)"])
        }
        var headers: [String: String] = [
            "dfid": dev.dfid, "clienttime": clienttime, "mid": dev.mid,
            "kg-rc": "1", "kg-thash": "5d816a0", "kg-rec": "1",
            "kg-rf": "B9EDA08A64250DEFFBCADDEE00F8F25F",
            "User-Agent": Self.gatewayUA,
        ]
        if let xRouter { headers["x-router"] = xRouter }
        for (k, v) in extraHeaders { headers[k] = v }
        // r31-cookie：取数请求必须带上登录 Cookie（Folia `kugouTransport.ts`
        // `getWebSessionCookie` + KuGouMusicApi 各模块的 `cookie:` 同款：每
        // 次请求都带整罐 web 会话 Cookie；以前这里只发 token/userid 参数，
        // Cookie 头一次没发过——登录态接口（user_detail）认 token，但用户
        // 歌单 / 每日推荐那路只认 Cookie（无有效 Cookie 回 error_code 152），
        // 登录成功、歌单却永远拉不到，就是断在这里）。
        // 注意 `gateway()` 的默认参数已含 token/userid（见上面 allParams），
        // Cookie 头是另一路，两边都要，不互相代替。
        if let cookie = webCookieHeader(), !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        // axios 发对象 body 时默认 Content-Type: application/json；只有
        // 显式传了其它 Content-Type（fm_songs / audio）时才不盖。
        if method.uppercased() != "GET", body != nil, headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/json"
        }
        let (data, http) = try await Upstream.fetch(url, headers: headers, timeout: 20,
                                                    method: method, body: bodyData)
        // r31-cookie：收割本次响应的 Set-Cookie（登录确认时用；响应头可能
        // 把多条拼成一条，用逗号感知的 `parseSetCookieStrings` 拆）。
        var setCookies: [String] = []
        for (k, v) in http.allHeaderFields {
            guard let ks = k as? String, ks.lowercased() == "set-cookie",
                  let vs = v as? String else { continue }
            setCookies.append(contentsOf: SessionStore.parseSetCookieStrings([vs]).map { "\($0.key)=\($0.value)" })
        }
        return KGResponse(httpStatus: http.statusCode, json: Upstream.jsonObject(data), raw: data,
                          setCookies: setCookies)
    }

    /// 上游状态：`status` 为 0 或 `error_code`/`errcode` 非 0 即失败
    ///（`util/request.js` 的 502 判定同款；r28：`/v5/url` 只回 `errcode`，
    /// 不带 `error_code`，不读它会把 20028 当成功）。
    private static func upstreamStatus(_ json: [String: Any]?) -> Int {
        guard let json else { return 0 }
        if let s = json["status"] as? Int { return s }
        if let s = json["status"] as? NSNumber { return s.intValue }
        if let e = json["error_code"] as? Int { return e == 0 ? 1 : 0 }
        if let e = json["error_code"] as? NSNumber { return e.intValue == 0 ? 1 : 0 }
        if let e = json["errcode"] as? Int { return e == 0 ? 1 : 0 }
        if let e = json["errcode"] as? NSNumber { return e.intValue == 0 ? 1 : 0 }
        if let e = json["errcode"] as? String { return (Int(e) ?? 0) == 0 ? 1 : 0 }
        return 1
    }

    /// 上游错误码：`error_code` 与 `errcode` 都认，数字与字符串都认
    ///（r28：`/v5/url` 的 20028 是数字 `errcode`，20006 是字符串
    /// `errcode:"20006"`；旧实现只读数字 `error_code`，两个都漏）。
    private static func upstreamErrorCode(_ json: [String: Any]?) -> Int {
        guard let json else { return 0 }
        for key in ["error_code", "errcode"] {
            if let e = json[key] as? Int { return e }
            if let e = json[key] as? NSNumber { return e.intValue }
            if let e = json[key] as? String, let n = Int(e) { return n }
        }
        return 0
    }

    /// 20028「本次请求需要验证」（Folia `kugouTransport.ts` 的
    /// `isDeviceVerificationRequired` 同款：`errcode ?? error_code`
    /// 为 20028，或文案含「本次请求需要验证」）。
    private static func needsVerify(_ json: [String: Any]?) -> Bool {
        guard let json else { return false }
        guard upstreamStatus(json) == 0 else { return false }
        if upstreamErrorCode(json) == 20028 { return true }
        let msg = strField(json, "error", "error_msg", "msg")
        return msg.contains("本次请求需要验证")
    }

    /// 20028 重试：先调 register_dev 拿新 dfid，再原样重发一次
    ///（Folia transport 同款：清 dfid → register → 只重试一次）。
    private func withRegisterRetry(_ work: () async throws -> KGResponse) async throws -> KGResponse {
        let first = try await work()
        guard Self.needsVerify(first.json) else { return first }
        _ = await registerDevice()
        return try await work()
    }

    /// 设备注册（`module/register_dev.js`）：POST
    /// userservice.kugou.com/risk/v2/r_register_dev；body 是 AES 加密的
    /// 设备信息 JSON（base64 串原文）；`p` 是 RSA PKCS1 加密的
    /// {aes key, uid, token}（小写 hex）；回包同样 AES 解密，
    /// `data.dfid` 存进登录态。成功回 true。
    private func registerDevice() async -> Bool {
        let dev = deviceIdentity()
        let login = loginState()
        let info: JVal = .o([
            ("availableRamSize", .i(4983533568)),
            ("availableRomSize", .i(48114719)),
            ("availableSDSize", .i(48114717)),
            ("basebandVer", .s("")),
            ("batteryLevel", .i(100)),
            ("batteryStatus", .i(3)),
            ("brand", .s("Redmi")),
            ("buildSerial", .s("unknown")),
            ("device", .s("marble")),
            ("imei", .s(dev.guid)),
            ("imsi", .s("")),
            ("manufacturer", .s("Xiaomi")),
            ("uuid", .s(dev.guid)),
            ("accelerometer", .b(false)),
            ("accelerometerValue", .s("")),
            ("gravity", .b(false)),
            ("gravityValue", .s("")),
            ("gyroscope", .b(false)),
            ("gyroscopeValue", .s("")),
            ("light", .b(false)),
            ("lightValue", .s("")),
            ("magnetic", .b(false)),
            ("magneticValue", .s("")),
            ("orientation", .b(false)),
            ("orientationValue", .s("")),
            ("pressure", .b(false)),
            ("pressureValue", .s("")),
            ("step_counter", .b(false)),
            ("step_counterValue", .s("")),
            ("temperature", .b(false)),
            ("temperatureValue", .s("")),
        ])
        guard let aes = Self.aesEncrypt(Self.jsonString(info)) else { return false }
        let pJSON = Self.jsonString(.o([
            ("aes", .s(aes.key)),
            ("uid", .i(Int(login.userid) ?? 0)),
            ("token", .s(login.token)),
        ]))
        guard let p = rsaPKCS1EncryptHex(pJSON) else { return false }
        do {
            let res = try await gateway(path: "/risk/v2/r_register_dev",
                                        baseURL: "https://userservice.kugou.com",
                                        method: "POST",
                                        params: ["part": "1", "platid": "1", "p": p],
                                        bodyRaw: Data(aes.base64.utf8),
                                        encrypt: .android)
            guard let plain = Self.aesDecryptJSON(res.raw.base64EncodedString(), key: aes.key) else { return false }
            guard Self.upstreamStatus(plain) == 1,
                  let dfid = scDict(plain, "data")["dfid"] as? String, !dfid.isEmpty else { return false }
            saveLoginState(dfid: dfid)
            return true
        } catch {
            return false
        }
    }

    /// 从回包里取 `data`（字典或数组包在 data 里都认；Folia 的
    /// dataOf / listOf 同款宽容读法：先 data 再顶层）。
    private static func dataDict(_ json: [String: Any]?) -> [String: Any] {
        guard let json else { return [:] }
        if let d = json["data"] as? [String: Any] { return d }
        return json
    }

    /// 从回包里找第一支歌曲数组（Folia `songListOf` 同款：按
    /// song_list / songlist / songs / list / lists / info / items 的
    /// 顺序在 data 与顶层里找）。
    private static func firstSongArray(_ json: [String: Any]?) -> [[String: Any]] {
        let keys = ["song_list", "songlist", "songList", "songs", "audios", "list", "lists", "info", "items"]
        guard let json else { return [] }
        for holder in [json["data"], json] {
            guard let d = holder as? [String: Any] else { continue }
            for k in keys {
                if let arr = d[k] as? [[String: Any]], !arr.isEmpty { return arr }
            }
        }
        if let arr = json["data"] as? [[String: Any]] { return arr }
        return []
    }

    /// 从回包里找第一支通用列表（歌单 / 专辑 / 电台分类等用）。
    private static func firstListArray(_ json: [String: Any]?, keys: [String]) -> [[String: Any]] {
        guard let json else { return [] }
        for holder in [json["data"], json] {
            guard let d = holder as? [String: Any] else { continue }
            for k in keys {
                if let arr = d[k] as? [[String: Any]], !arr.isEmpty { return arr }
            }
        }
        if let arr = json["data"] as? [[String: Any]] { return arr }
        return []
    }

    // MARK: - 归一化（Folia kugouProvider.ts 的 normalizeKugouSong /
    // normalizeCollection / coverOf，新写的 Swift 版；字段取值顺序与
    // Folia 一致，输出是 Lizi 壳版 / 原生共用的 track / playlist 字典）

    /// 取第一个非空字段（Folia 的 valueOf 同款：按给定 key 顺序找）。
    private static func firstField(_ d: [String: Any], _ keys: String...) -> Any? {
        firstField(d, keys: keys)
    }

    /// 数组版 firstField（r24 构建修，run 44656645107）：strField / intField
    /// 里 `keys` 已是收集好的 [String]，不能直接塞进 `String...` 形参，
    /// 编译器报 "cannot pass array of type 'String...' as variadic
    /// arguments"。循环体搬到这里，可变参数版转调它；字面量调用点不动。
    private static func firstField(_ d: [String: Any], keys: [String]) -> Any? {
        for k in keys {
            guard let v = d[k] else { continue }
            if let s = v as? String, s.isEmpty { continue }
            return v
        }
        return nil
    }

    private static func strField(_ d: [String: Any], _ keys: String...) -> String {
        guard let v = firstField(d, keys: keys) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    private static func intField(_ d: [String: Any], _ keys: String...) -> Int {
        guard let v = firstField(d, keys: keys) else { return 0 }
        return scNum(v)
    }

    /// 多键取最大值（r31-membership：会员字段不能只取第一个在场的键——
    /// is_vip = 0 时 vip_type 可能 = 1，全扫取最大才不会把会员判成非会员）。
    private static func maxIntField(_ d: [String: Any], _ keys: String...) -> Int {
        var best = 0
        for k in keys {
            if let n = d[k] as? NSNumber { best = max(best, n.intValue) }
            else if let s = d[k] as? String, let n = Int(s) { best = max(best, n) }
        }
        return best
    }

    /// 酷狗资料接口的会员值：任一会员字段 > 0 即会员（is_vip / vip_type /
    /// svip_level / vip / m_type / su_vip / svip）。
    private static func kugouVIPValue(from profile: [String: Any]) -> Int {
        maxIntField(profile, "is_vip", "vip_type", "vipType", "vip", "m_type", "su_vip", "svip")
    }

    /// 酷狗 SVIP 值：svip_level / svip / su_vip 任一 > 0 即 SVIP。
    private static func kugouSuperVIPValue(from profile: [String: Any]) -> Int {
        maxIntField(profile, "svip_level", "svip", "su_vip")
    }

    /// union_vip 兜底（r31-membership）：GET kugouvip.kugou.com/v1/get_union_vip，
    /// vip_type 或 busi_vip 里任一 is_vip > 0 即会员。抛错 = 查不到。
    private func unionVIPBool() async throws -> Bool {
        let res = try await gateway(path: "/v1/get_union_vip",
                                    baseURL: "https://kugouvip.kugou.com",
                                    method: "GET", params: ["busi_type": "concept"])
        let data = Self.dataDict(res.json)
        var vipType = Self.maxIntField(data, "vip_type", "vipType", "is_vip")
        if vipType == 0,
           let busi = data["busi_vip"] as? [[String: Any]],
           busi.contains(where: { Self.maxIntField($0, "is_vip", "vip_type") > 0 }) {
            vipType = 1
        }
        return vipType > 0
    }

    /// 封面（Folia coverOf）：album_info / trans_param 的 union_cover
    /// 优先；`{size}` 换成 1024；纯数字文件名（8 位以上 + 图片后缀）
    /// 拼 `https://c1.kgimg.com/stdmusic/1024/<前8位>/<文件名>`；
    /// `//` 补 https，http 升 https。
    private static func coverOf(_ raw: [String: Any]) -> String {
        var value = ""
        if let albumInfo = raw["album_info"] as? [String: Any] {
            value = strField(albumInfo, "sizable_cover", "cover")
        }
        if value.isEmpty, let albumInfo = raw["albumInfo"] as? [String: Any] {
            value = strField(albumInfo, "sizable_cover", "cover")
        }
        if value.isEmpty {
            for key in ["audio_info", "audioInfo"] {
                if let ai = raw[key] as? [String: Any],
                   let tp = ai["trans_param"] as? [String: Any] ?? ai["transParam"] as? [String: Any] {
                    value = strField(tp, "union_cover")
                    if !value.isEmpty { break }
                }
            }
        }
        if value.isEmpty, let tp = raw["trans_param"] as? [String: Any] ?? raw["transParam"] as? [String: Any] {
            value = strField(tp, "union_cover")
        }
        if value.isEmpty {
            value = strField(raw, "sizable_cover", "Image", "image", "img", "pic", "picUrl", "cover", "coverUrl", "sizable_avatar")
        }
        guard !value.isEmpty else { return "" }
        let cover = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "{size}", with: String(coverSize))
        let lower = cover.lowercased()
        let isBareFile = (lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
                          || lower.hasSuffix(".png") || lower.hasSuffix(".webp"))
            && cover.count >= 8 && cover.prefix(8).allSatisfy({ $0.isNumber })
            && !cover.contains("/")
        if isBareFile {
            return "https://c1.kgimg.com/stdmusic/\(coverSize)/\(cover.prefix(8))/\(cover)"
        }
        if cover.hasPrefix("//") { return "https:" + cover }
        if cover.hasPrefix("http://") { return "https://" + cover.dropFirst("http://".count) }
        return cover
    }

    /// 头像 URL 归一（r31 头像修；coverOf 尾部同款逻辑，给 status 的回落字段
    /// 用）：{size} → 1024、// 补 https、http 升 https；imge.kugou.com
    /// 的 https 实测 200。非 https 回 ""。
    private static func upgradeAvatarURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "{size}", with: String(coverSize))
        guard !s.isEmpty else { return "" }
        if s.hasPrefix("//") { s = "https:" + s }
        else if s.hasPrefix("http://") { s = "https://" + s.dropFirst("http://".count) }
        guard s.hasPrefix("https://") else { return "" }
        return s
    }

    /// 歌手（Folia normalizeArtists）：Singers / singerinfo / authors /
    /// artists 数组取 name；没有数组时 SingerName / singername /
    /// author_name / Singer 按 、,&/ 切。
    private static func artistsOf(_ raw: [String: Any]) -> [String] {
        if let singers = firstField(raw, "Singers", "singers", "singerinfo", "authors", "artists") as? [[String: Any]] {
            return singers.compactMap { a in
                let base = (a["base"] as? [String: Any]) ?? a
                let n = strField(base, "name", "author_name", "singername")
                return n.isEmpty ? nil : n
            }
        }
        if let singers = firstField(raw, "Singers", "singers") as? [String] {
            return singers.filter { !$0.isEmpty }
        }
        let names = strField(raw, "SingerName", "singername", "author_name", "Singer")
        guard !names.isEmpty else { return [] }
        return names.components(separatedBy: CharacterSet(charactersIn: "、,&/"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 单曲归一化（Folia normalizeKugouSong）：id 即大写 hash；
    /// 歌名优先 SongName / OriSongName / FileName（无歌手字段时把
    /// FileName 的「歌手 - 歌名」拆开）；时长秒（<10000）转毫秒；
    /// 专辑 id / 名 / 封面；albumAudioId / mixSongId / fileId 另存，
    /// 供取链（song_url 的 album_id / album_audio_id）与歌词重试用。
    private static func kugouTrack(_ raw: [String: Any]) -> [String: Any]? {
        let base = (raw["base"] as? [String: Any]) ?? [:]
        let audioInfo = (raw["audio_info"] as? [String: Any]) ?? (raw["audioInfo"] as? [String: Any]) ?? [:]
        let hash = strField(raw, "FileHash", "fileHash", "hash", "Hash", "audio_hash", "audioHash", "kgHash").uppercased()
        let hash2 = strField(audioInfo, "hash", "hash_128").uppercased()
        let finalHash = hash.isEmpty ? hash2 : hash
        let nestedAlbum = (firstField(raw, "album_info", "albumInfo", "albuminfo", "album") as? [String: Any]) ?? [:]
        var albumIdFinal = strField(raw, "AlbumID", "album_id", "albumId")
        if albumIdFinal.isEmpty { albumIdFinal = strField(nestedAlbum, "album_id", "albumId") }
        if albumIdFinal.isEmpty { albumIdFinal = strField(base, "album_id", "albumId") }
        var albumNameFinal = strField(raw, "AlbumName", "album_name", "albumName", "albumname")
        if albumNameFinal.isEmpty { albumNameFinal = strField(nestedAlbum, "name", "album_name", "albumName") }
        if albumNameFinal.isEmpty { albumNameFinal = strField(base, "album_name", "albumName") }
        var duration = intField(raw, "Duration", "duration", "timelen", "timeLength", "timelength", "time_length")
        if duration == 0 { duration = intField(audioInfo, "duration", "timelength", "duration_128") }
        if duration > 0 && duration < 10000 { duration *= 1000 }
        var mixSongId = strField(raw, "MixSongID", "mixsongid", "mixSongId")
        if mixSongId.isEmpty { mixSongId = strField(base, "MixSongID", "mixsongid", "mixSongId") }
        var albumAudioId = strField(raw, "album_audio_id", "albumAudioId")
        if albumAudioId.isEmpty { albumAudioId = strField(base, "album_audio_id", "albumAudioId") }
        var rawTitle = strField(raw, "SongName", "songname", "songName", "ori_audio_name", "oriAudioName",
                                "OriSongName", "ori_song_name", "oriSongName", "FileName", "filename", "fileName",
                                "name", "audio_name")
        if rawTitle.isEmpty { rawTitle = strField(audioInfo, "ori_audio_name", "oriAudioName", "audio_name", "audioName") }
        if rawTitle.isEmpty { rawTitle = strField(base, "SongName", "songname", "songName", "audio_name", "audioName") }
        var artists = artistsOf(raw)
        var title = rawTitle
        if artists.isEmpty, let dash = rawTitle.range(of: " - ") {
            let left = String(rawTitle[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(rawTitle[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !left.isEmpty && !right.isEmpty {
                artists = left.components(separatedBy: CharacterSet(charactersIn: "、,&/"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                title = right
            }
        } else if !artists.isEmpty, let dash = rawTitle.range(of: " - ") {
            // 歌名带「歌手 - 」前缀时去掉（Folia 的 lyric-search 用标题清理同款）。
            let left = String(rawTitle[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            if artists.contains(left) {
                title = String(rawTitle[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        let suffix = strField(raw, "Suffix", "suffix")
        var originalName = strField(raw, "OriSongName", "ori_song_name", "oriSongName")
        if originalName.isEmpty { originalName = strField(base, "OriSongName", "ori_song_name", "oriSongName") }
        if originalName.isEmpty, !suffix.isEmpty, title.hasSuffix(suffix) {
            originalName = String(title.dropLast(suffix.count))
        }
        guard !finalHash.isEmpty || !title.isEmpty else { return nil }
        let id = finalHash.isEmpty ? title : finalHash
        // r30 路线 B：ISRC 透传（上游给才有；VM 实测酷狗 mobiles 搜索行
        // 全键无 isrc，详情 songinfo 走 gateway 需设备注册 + AES、VM 未
        // 直调，Folia 归一化亦无 isrc；本字段大概率恒为空，只是占位透传）。
        var isrc = strField(raw, "isrc", "ISRC", "Isrc")
        if isrc.isEmpty { isrc = strField(base, "isrc", "ISRC") }
        if isrc.isEmpty { isrc = strField(audioInfo, "isrc", "ISRC") }
        var track: [String: Any] = [
            "id": id, "source": "kugou", "name": title,
            "artists": artists.isEmpty ? "未知歌手" : artists.joined(separator: " / "),
            "album": albumNameFinal, "albumId": albumIdFinal,
            "albumIdNum": Int(albumIdFinal) ?? 0,
            "albumAudioId": Int(albumAudioId) ?? 0,
            "hash": finalHash, "cover": coverOf(raw),
            "duration": duration, "fee": 0,
        ]
        if !isrc.isEmpty { track["isrc"] = isrc }
        if !mixSongId.isEmpty { track["mixSongId"] = mixSongId }
        let fileId = strField(raw, "FileID", "fileid", "file_id")
        if !fileId.isEmpty { track["fileId"] = fileId }
        if !originalName.isEmpty, originalName != title { track["originalName"] = originalName }
        return track
    }

    /// 歌单 / 专辑 / 歌手归一化（Folia normalizeCollection）：
    /// 歌单 id 取 global_collection_id / specialid / id；
    /// 专辑 id 取 album_id / musiclib_id / list_create_listid；
    /// 封面走 coverOf；曲数取 song_count / count / m_count / total。
    private static func kugouCollection(_ raw: [String: Any], type: String, owned: Bool = false) -> [String: Any]? {
        let id: String
        switch type {
        case "album":
            id = strField(raw, "album_id", "AlbumID", "albumId", "musiclib_id", "musicLibId", "list_create_listid")
        case "artist":
            id = strField(raw, "author_id", "authorId")
        default:
            id = strField(raw, "global_collection_id", "globalCollectionId", "specialid", "specialId", "id")
        }
        guard !id.isEmpty else { return nil }
        let name = strField(raw, "name", "listname", "specialname", "album_name", "author_name")
        let desc = strField(raw, "intro", "description", "brief_desc", "briefDesc", "brief_description", "desc")
        let trackCount = intField(raw, "song_count", "count", "m_count", "total", "music_num")
        let playCount = intField(raw, "play_count", "playCount")
        var out: [String: Any] = [
            "id": id, "source": "kugou", "name": name, "type": type,
            "cover": coverOf(raw),
        ]
        if !desc.isEmpty { out["description"] = desc }
        if trackCount > 0 { out["trackCount"] = trackCount }
        if raw["play_count"] != nil || raw["playCount"] != nil { out["playCount"] = playCount }
        if owned { out["isOwned"] = true }
        let artists = artistsOf(raw)
        if !artists.isEmpty { out["artists"] = artists.joined(separator: " / ") }
        let listId = strField(raw, "listid", "list_id")
        if !listId.isEmpty { out["listId"] = listId }
        return out
    }

    /// 用户歌单行是歌单还是专辑（Folia getKugouUserCollectionType）：
    /// source == 2 或带 musiclib_id 即专辑，其余为歌单。
    private static func userCollectionType(_ raw: [String: Any]) -> String {
        if scNum(raw["source"]) == 2 { return "album" }
        if raw["musiclib_id"] != nil || raw["musicLibId"] != nil { return "album" }
        return "playlist"
    }

    /// 电台分类归一化（fm/class 的 class_list 项；字段名按回包宽容读）。
    /// 电台（Folia 无此归一化——`fm/class` 是库模块，Folia provider 未包；
    /// 按回包实测字段写）：class_list 的每项是分类 {classid, classname,
    /// fmlist}，电台在 fmlist 里 {fmid, fmname, fmtype, imgurl}，imgurl
    /// 带 {size} 占位、可取尺寸见 imgurl_size（"480,400,240,150"，取 240）。
    /// `fmClass` 先把各分类的 fmlist 展平成 stations 再调这里。
    private static func kugouStation(_ raw: [String: Any]) -> [String: Any]? {
        let id = strField(raw, "fmid", "fm_id", "id", "classid", "class_id")
        guard !id.isEmpty else { return nil }
        var cover = ""
        if let imgurl = raw["imgurl"] as? String, !imgurl.isEmpty {
            cover = imgurl.replacingOccurrences(of: "{size}", with: "240")
            if cover.hasPrefix("http://") { cover = "https://" + cover.dropFirst("http://".count) }
            if cover.hasPrefix("//") { cover = "https:" + cover }
        }
        if cover.isEmpty { cover = coverOf(raw) }
        return [
            "id": id, "source": "kugou",
            "name": strField(raw, "name", "title", "fmname", "fm_name", "classname", "class_name"),
            "cover": cover,
        ]
    }

    // MARK: - 路由

    func handle(_ req: HttpRequest) async -> HttpResponse {
        let part = String(req.path.dropFirst("/api/kugou/".count))
        do {
            switch part {
            case "", "health":
                return .json(200, ["code": 200, "ok": true, "audio": true, "login": "qr,cookie"])
            case "status", "login/status":
                return try await status()
            case "login/qr/key", "login/qr/create", "login/qr/check":
                // r31-qqkg：酷狗扫码登录已改为本机直连（KugouAPI），服务端
                // 桥接已废弃——410 明说，不再静默走旧路。旧客户端请升级。
                return .json(410, ["code": 410, "loggedIn": false,
                                   "error": "酷狗扫码登录已改为本机直连（KugouAPI），服务端桥接已废弃"])
            case "login/cookie":
                return await loginCookie(req)
            case "logout":
                clearLoginState()
                return .json(200, ["code": 200, "loggedIn": false])
            case "search":
                return try await search(req)
            case "song/url":
                return try await songUrl(req)
            case "lyric":
                return try await lyric(req)
            case "everyday/recommend":
                return try await everydayRecommend()
            case "everyday/history":
                return try await everydayHistory(req)
            case "top/songs":
                return try await topSongs(req)
            case "top/playlists":
                return try await topPlaylists(req)
            case "rank/list":
                return await rankList()
            case "rank/song":
                return await rankTracks(req)
            case "personal/fm":
                return try await personalFm()
            case "recommend/songs":
                return try await recommendSongs(req)
            case "recommend/playlists":
                return try await recommendPlaylists(req)
            case "fm/class":
                return try await fmClass()
            case "fm/songs":
                return try await fmSongs(req)
            case "user/playlists":
                return try await userPlaylists(req)
            case "playlist/tracks":
                return try await playlistTracks(req)
            case "playlist/detail":
                return try await playlistDetail(req)
            case "playlist/create":
                return try await playlistCreate(req)
            case "playlist/tracks/add":
                return try await playlistTracksAdd(req)
            case "playlist/tracks/del":
                return try await playlistTracksDel(req)
            case "playlist/del":
                return try await playlistDel(req)
            case "album/detail":
                return try await albumDetail(req)
            case "album/songs":
                return try await albumSongs(req)
            case "artist/detail":
                return try await artistDetail(req)
            case "artist/albums":
                return try await artistAlbums(req)
            case "artist/audios":
                return try await artistAudios(req)
            case "user/cloud":
                return try await userCloud(req)
            case "user/cloud_url":
                return try await userCloudUrl(req)
            case "user/listen":
                return try await userListen(req)
            case "user/vip":
                return try await userVip()
            case "song/climax":
                return try await songClimax(req)
            case "audio":
                return try await audioMeta(req)
            case "krm/audio":
                return try await krmAudio(req)
            default:
                return .json(404, ["code": 404, "error": "unknown kugou api: \(part)"])
            }
        } catch {
            return .json(502, ["code": 502, "error": error.localizedDescription])
        }
    }

    // MARK: - 登录态与扫码登录（Folia auth：login_qr_key → login_qr_create
    // → login_qr_check；状态 0 过期 / 1 等待 / 2,3 已扫码 / 4 或带 token 为确认）

    /// 登录态：有 token 时调 user_detail（`module/user_detail.js`）
    /// 验一次；拿不到昵称也以 token 为准（loggedIn 只认 token 在不在，
    /// 不认 user_detail 通不通——弱网下不把已登录判成未登录）。
    /// r31-membership：会员从资料接口实算（任一会员字段 > 0 即会员，
    /// svip_level / svip / su_vip > 0 即 SVIP；全 0 再补查 union_vip；
    /// 查不到时 vip 记 null = 未知，不当非会员）。
    private func status() async throws -> HttpResponse {
        let login = loginState()
        guard !login.token.isEmpty else {
            return .json(200, ["code": 200, "loggedIn": false, "nickname": "",
                               "avatar": "", "uid": "", "vip": false, "vipKnown": false])
        }
        var nickname = ""
        var avatar = ""
        var vip: Bool? = nil
        var isSuperVIP = false
        do {
            let clienttime = Int(Date().timeIntervalSince1970)
            let pJSON = Self.jsonString(.o([
                ("token", .s(login.token)),
                ("clienttime", .i(clienttime)),
            ]))
            guard let p = rsaRawEncryptUpperHex(pJSON) else {
                throw NSError(domain: "FoliaKugou", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "rsa failed"])
            }
            let body: JVal = .o([
                ("visit_time", .i(clienttime)),
                ("usertype", .i(1)),
                ("p", .s(p)),
                ("userid", .i(Int(login.userid) ?? 0)),
            ])
            let res = try await gateway(path: "/v3/get_my_info", method: "POST",
                                        params: ["plat": "1"], body: body,
                                        xRouter: "usercenter.kugou.com")
            // r31 登录态同尺子修：以前这里只认 token 在不在，user_detail 失败
            // 直接吞掉——token 过期/被顶掉时设置页照常显示「已登录」，歌单那路
            // 却拿不到数据（用户 2026-11-21 05:59 报的酷狗同款）。现在上游
            // 明确拒了（status 0 / errcode 非 0）就判未登录、带 stale（设置页
            // 显示未登录，不再两边各说各话）；transport 抛错（弱网）走外层
            // catch 仍认登录（断网 ≠ 登出），与本函数原有注释一致。
            guard Self.upstreamStatus(res.json) == 1 else {
                return .json(200, ["code": 200, "loggedIn": false, "stale": true,
                                   "nickname": "", "avatar": "", "uid": login.userid,
                                   "vip": NSNull(), "isSuperVIP": false, "vipKnown": false])
            }
            let data = Self.dataDict(res.json)
            // Folia normalizeUser：user_info / userinfo / profile / data 本体。
            let profile = (data["user_info"] as? [String: Any])
                ?? (data["userinfo"] as? [String: Any])
                ?? (data["profile"] as? [String: Any]) ?? data
            nickname = Self.strField(profile, "nickname", "nick_name", "username", "name")
            avatar = Self.coverOf(profile)
            if avatar.isEmpty {
                // r31 头像修：coverOf 之外的回落字段（avatar / pic / user_pic /
                // sizable_avatar）以前原样返回，http://imge.kugou.com/… 直接进
                // AsyncImage 会被真机 ATS -1022 拦掉（登录后头像拿不到）。
                // user_pic 是 Folia 注释里确认的酷狗头像字段（coverOf 故意不收它，
                // 那是给歌曲封面用的；这里是用户画像，收）。与 coverOf 同款升级。
                avatar = Self.upgradeAvatarURL(Self.strField(profile, "avatar", "pic", "user_pic", "sizable_avatar"))
            }
            let vipValue = Self.kugouVIPValue(from: profile)
            isSuperVIP = Self.kugouSuperVIPValue(from: profile) > 0
            if vipValue > 0 {
                vip = true
                saveLoginState(vipType: String(vipValue))
            } else if let union = try? await unionVIPBool() {
                vip = union
            } else {
                vip = nil
            }
        } catch {
            // user_detail 失败不推翻登录态：token 还在就认登录；
            // 会员态记未知（vip 仍是 nil），不拿 false 冒充非会员。
        }
        return .json(200, ["code": 200, "loggedIn": true, "nickname": nickname,
                           "avatar": avatar, "uid": login.userid,
                           "vip": vip.map { NSNumber(value: $0) } ?? NSNull(),
                           "isSuperVIP": isSuperVIP, "vipKnown": vip != nil])
    }

    /// 粘贴 Cookie 登录（r31-cookie：以前酷狗只有扫码，没有任何 Cookie
    /// 登录口——用户报「酷狗 Cookie 登录拉不到数据」时连贴的地方都没有）。
    /// 接受酷狗网页登录的整段 Cookie（`token` + `userid` 两项是账号对，
    /// 其余项是 web 会话罐；只贴裸 token 也认，userid 随后用 status 补）。
    /// 解析与酷我 `parseCookieInput` 同规则（`;` / 换行切、去 `cookie:`
    /// 前缀、JSON 对象 form、键小写、值 percent-decode）。
    /// 存法与网易 `session/import` 同款：快照 → 写进登录态 → `status()`
    /// 校验 → 不通过回滚，不留死 token。
    private func loginCookie(_ req: HttpRequest) async -> HttpResponse {
        guard req.method == "POST" else {
            return .json(405, ["code": 405, "error": "请用 POST 提交 Cookie"])
        }
        let raw = req.string("cookie").isEmpty ? req.string("value") : req.string("cookie")
        let pairs = Self.parseCookieInput(raw)
        // 裸值（没有 `=` 也没有 `;`）当 token。
        let token = pairs["token"] ?? (raw.contains("=") || raw.contains(";") ? "" : raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !token.isEmpty else {
            return .json(200, ["code": 400, "loggedIn": false,
                               "error": "Cookie 里没有 token：请在浏览器登录 www.kugou.com 后复制整段 Cookie"])
        }
        let userid = pairs["userid"] ?? pairs["user_id"] ?? ""
        let accountKeys: Set<String> = ["token", "userid", "user_id"]
        let jar = pairs.filter { !accountKeys.contains($0.key) }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        let prev = store.sidecarAuth("kugou")
        // 成对写：userid / webCookie 缺了就写空串清掉旧账号的残值，不留
        // 「新 token + 旧 userid」这种半对（Folia「不成对不写」同款）。
        // 校验失败时下面整份回滚旧态。
        saveLoginState(token: token, userid: userid, webCookie: jar)
        do {
            let st = try await status()
            guard st.status == 200,
                  let obj = try? JSONSerialization.jsonObject(with: st.body) as? [String: Any],
                  (obj["loggedIn"] as? NSNumber)?.boolValue == true else {
                // 校验没通过：恢复旧登录态（没有旧态就清掉刚写的）。
                if let prev { store.saveSidecarAuth("kugou", prev) } else { store.clearSidecarAuth("kugou") }
                return .json(200, ["code": 400, "loggedIn": false,
                                   "error": "这段 Cookie 无效或已过期（token 不是当前账号的，或已经登出过）"])
            }
            // status 补 userid：只贴了裸 token 时这里才有号。
            let uid = (obj["uid"] as? String) ?? ""
            if userid.isEmpty, !uid.isEmpty { saveLoginState(userid: uid) }
            return .json(200, ["code": 200, "loggedIn": true,
                               "nickname": (obj["nickname"] as? String) ?? "",
                               "avatar": (obj["avatar"] as? String) ?? "",
                               "uid": userid.isEmpty ? uid : userid])
        } catch {
            if let prev { store.saveSidecarAuth("kugou", prev) } else { store.clearSidecarAuth("kugou") }
            return .json(200, ["code": 400, "loggedIn": false,
                               "error": "校验登录态失败：\(error.localizedDescription)"])
        }
    }

    /// 粘贴 Cookie 的宽容解析（酷我 `KuwoService.parseCookieInput` 同规则，
    /// 不另起一套：`cookie:` 前缀、JSON 对象、`;` / 换行分隔、键小写归一化、
    /// 值 percent-decode、去首尾引号）。
    private static func parseCookieInput(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return out }
        if let r = text.range(of: #"^cookie\s*:\s*"#, options: .regularExpression) { text = String(text[r.upperBound...]) }
        if text.hasPrefix("{") {
            if let data = text.data(using: .utf8),
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in j where !k.isEmpty {
                    if let s = v as? String { out[k.lowercased()] = s.removingPercentEncoding ?? s }
                    else if let n = v as? NSNumber { out[k.lowercased()] = n.stringValue }
                }
                return out
            }
        }
        let seps = CharacterSet(charactersIn: ";\n\r")
        for part in text.components(separatedBy: seps) {
            guard let i = part.firstIndex(of: "="), i != part.startIndex else { continue }
            let k = part[..<i].trimmingCharacters(in: .whitespaces).lowercased()
            var v = part[part.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            v = v.removingPercentEncoding ?? v
            if !k.isEmpty { out[k] = v }
        }
        return out
    }

    // MARK: - 搜索（Folia search：登录态走网关 /v3/search/song，
    // 匿名走 complexsearch/v2；首页回空退回匿名并记住关键词）

    private func search(_ req: HttpRequest) async throws -> HttpResponse {
        let s = [req.string("s"), req.string("key"), req.string("keywords")]
            .first(where: { !$0.isEmpty }) ?? ""
        let sTrim = s.trimmingCharacters(in: .whitespaces)
        guard !sTrim.isEmpty else {
            return .json(200, ["code": 200, "source": "kugou", "tracks": [], "songCount": 0])
        }
        let limit = scClamp(req.int("limit", 20), 1, 50)
        let page = max(1, req.int("page", 1))
        let login = loginState()
        if !login.token.isEmpty, !anonFallbackKeywords.contains(sTrim) {
            do {
                let res = try await gateway(path: "/v3/search/song", method: "GET",
                                            params: ["albumhide": "0", "iscorrection": "1",
                                                     "keyword": sTrim, "nocollect": "0",
                                                     "page": String(page), "pagesize": String(limit),
                                                     "platform": "AndroidFilter"],
                                            xRouter: "complexsearch.kugou.com")
                let items = Self.firstSongArray(res.json)
                let tracks = items.compactMap { Self.kugouTrack($0) }
                if !(page == 1 && tracks.isEmpty) {
                    let total = Self.intField(Self.dataDict(res.json), "total")
                    return .json(200, ["code": 200, "source": "kugou", "tracks": tracks,
                                       "songCount": total != 0 ? total : tracks.count])
                }
                anonFallbackKeywords.insert(sTrim)
            } catch {
                // 登录态搜索抛错（弱网 / 上游 5xx）时退回匿名，不直接 502。
                // r24 U1 修：抛错是瞬时故障，不记 anonFallbackKeywords——
                // 记了会让该关键词整段登录会话都跳过登录态搜索（只走匿名），
                // 下次搜同一词仍应重试登录态。只有网关正常回空（第 1 页
                // 0 条）才记集合，那是服务端给出的确定答案。
            }
        }
        let (tracks, total) = try await anonymousSearch(keyword: sTrim, page: page, pagesize: limit)
        return .json(200, ["code": 200, "source": "kugou", "tracks": tracks,
                           "songCount": total != 0 ? total : tracks.count])
    }

    /// 匿名搜索（Folia `kugouTransport.ts` requestKugouAnonymousSearch）：
    /// mid 取 MD5(当前毫秒)，lite 盐签名；Folia 用 http，本实现用 https
    ///（VM 实测同一 host 的 https 同样回 200；App 内 ATS 拦 http）。
    private func anonymousSearch(keyword: String, page: Int, pagesize: Int) async throws -> ([[String: Any]], Int) {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let sec = ms / 1000
        var params: [String: String] = [
            "sorttype": "0", "keyword": keyword, "pagesize": String(pagesize), "page": String(page),
            "userid": "0", "appid": Self.liteAppid, "token": "", "clienttime": String(sec),
            "iscorrection": "1", "uuid": "-", "mid": Crypto.md5Hex(String(ms)),
            "dfid": "-", "clientver": "11070", "platform": "AndroidFilter",
        ]
        params["signature"] = Crypto.md5Hex(Self.androidLiteSalt + Self.sortedParamString(params) + Self.androidLiteSalt)
        var comps = URLComponents(string: "https://complexsearch.kugou.com/v2/search/song")
        comps?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps?.url else { return ([], 0) }
        let headers: [String: String] = [
            "User-Agent": Self.anonSearchUA, "KG-Rec": "1", "KG-RC": "1",
            "KG-CLIENTTIMEMS": String(ms), "mid": params["mid"] ?? "",
            "x-router": "complexsearch.kugou.com",
        ]
        let (data, _) = try await Upstream.fetch(url, headers: headers, timeout: 20)
        guard let json = Upstream.jsonObject(data) else { return ([], 0) }
        let items = Self.firstSongArray(json)
        let tracks = items.compactMap { Self.kugouTrack($0) }
        return (tracks, Self.intField(Self.dataDict(json), "total"))
    }

    // MARK: - 取链（Folia getAudioSource：档位降级 ladder；每档先带
    // album_id 再 hash-only；云盘只走 user_cloud_url；最后试 legacy
    // playInfo；401/403/152 立刻认登录失效；超时停链但仍试 legacy）

    /// 档位降级表（Folia `QUALITY_FALLBACKS` + `qualityValue`）：
    /// 入参既接 Lizi 的档位名（standard/higher/exhigh/lossless/hires/
    /// master），也接已换算过的网关值（128/320/flac/high）。
    private static func qualityTiers(_ q: String) -> [String] {
        switch q.trimmingCharacters(in: .whitespaces).lowercased() {
        case "128", "standard": return ["128"]
        case "320", "higher", "exhigh", "ultra": return ["320", "128"]
        case "flac", "lossless", "master", "surround", "dolby", "spatial": return ["flac", "320", "128"]
        case "high", "hires": return ["high", "flac", "320", "128"]
        default: return ["flac", "320", "128"]
        }
    }

    /// 取一条 URL（Folia audioUrlOf）：字符串或字符串数组，逗号分隔的
    /// 多地址拆开，取第一条 http(s) 链。
    private static func audioUrlOf(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        let values: [String]
        if let arr = raw as? [String] { values = arr }
        else if let s = raw as? String { values = [s] }
        else { return nil }
        for v in values {
            for part in v.components(separatedBy: ",") {
                let c = part.trimmingCharacters(in: .whitespaces)
                guard c.hasPrefix("http://") || c.hasPrefix("https://"),
                      URL(string: c) != nil else { continue }
                return c
            }
        }
        return nil
    }

    /// song_url 一次尝试（`module/song_url.js`）：GET /v5/url，
    /// x-router trackercdn.kugou.com，encryptKey（key=signKey）。
    /// 回 (url, authRequired, reason)：无 URL 时 reason 带上游状态，
    /// 401/403/errcode 152 时 authRequired 为真（Folia 立刻认登录失效）；
    /// register_dev 重试后仍是 20028 时同样 authRequired（文件头约定：
    /// 仍 20028 则回 `reason:"login"`，不再降档重试——换档位只会
    /// 再拿一次 20028，Folia 同款立刻抛 auth-required）。
    private func fetchSongURL(hash: String, quality: String, albumId: Int, albumAudioId: Int) async throws -> (url: String?, authRequired: Bool, reason: String) {
        let params: [String: String] = [
            "album_id": String(albumId), "area_code": "1", "hash": hash.lowercased(),
            "ssa_flag": "is_fromtrack", "version": "11430", "page_id": "967177915",
            "quality": quality, "album_audio_id": String(albumAudioId), "behavior": "play",
            "pid": "411", "cmd": "26", "pidversion": "3001", "IsFreePart": "0",
            "ppage_id": "356753938,823673182,967485191", "cdnBackup": "1",
            "module": "", "clientver": "11430",
        ]
        let res = try await withRegisterRetry {
            try await gateway(path: "/v5/url", method: "GET", params: params,
                              xRouter: "trackercdn.kugou.com", encryptKey: true)
        }
        if res.httpStatus == 401 || res.httpStatus == 403 || Self.upstreamErrorCode(res.json) == 152 {
            return (nil, true, "login")
        }
        if Self.needsVerify(res.json) {
            // withRegisterRetry 里已经 register_dev + 重试过一次，仍是
            // 20028：设备验证过不去，再换档位/变体也是同一答案，直接认
            // 需要登录（匿名设备未注册 / 登录态的 dfid 已失效都走这里）。
            return (nil, true, "login")
        }
        let rawData = res.json?["data"]
        var payload: [String: Any] = [:]
        if let arr = rawData as? [[String: Any]], let first = arr.first { payload = first }
        else if let d = rawData as? [String: Any] { payload = d }
        else if let d = res.json { payload = d }
        if let url = Self.audioUrlOf(payload["play_url"] ?? payload["playUrl"] ?? payload["url"]) {
            return (url, false, "")
        }
        if let arr = rawData as? [[String: Any]], let first = arr.first,
           let url = Self.audioUrlOf(first["url"] ?? first["play_url"]) {
            return (url, false, "")
        }
        let err = Self.strField(Self.dataDict(res.json), "error", "msg")
        return (nil, false, err.isEmpty ? "unavailable" : err)
    }

    /// 云盘取链（`module/user_cloud_url.js`）：GET
    /// /bsstrackercdngz/v2/query_musicclound_url，key=signCloudKey。
    private func fetchCloudURL(hash: String, albumAudioId: Int, audioId: Int, name: String) async throws -> String? {
        let h = hash.lowercased()
        let params: [String: String] = [
            "hash": h, "ssa_flag": "is_fromtrack", "version": "20102", "ssl": "0",
            "album_audio_id": String(albumAudioId), "pid": "20026", "audio_id": String(audioId),
            "kv_id": "2", "key": Self.signCloudKey(hash: h, pid: 20026),
            "bucket": "musicclound", "name": name, "with_res_tag": "0",
        ]
        let res = try await withRegisterRetry {
            try await gateway(path: "/bsstrackercdngz/v2/query_musicclound_url", method: "GET", params: params)
        }
        let d = Self.dataDict(res.json)
        return Self.audioUrlOf(d["url"] ?? d["play_url"])
    }

    /// legacy playInfo 兜底（Folia `kugouTransport.ts`
    /// requestKugouLegacyPlayInfo）：GET m.kugou.com/app/i/getSongInfo.php
    /// ?cmd=playInfo&hash=；url 为空时再看 backup_url。
    private func legacyPlayInfo(hash: String) async -> String? {
        var comps = URLComponents(string: "https://m.kugou.com/app/i/getSongInfo.php")
        comps?.queryItems = [URLQueryItem(name: "cmd", value: "playInfo"),
                             URLQueryItem(name: "hash", value: hash)]
        guard let url = comps?.url,
              let (data, http) = try? await Upstream.fetch(url, headers: ["User-Agent": Self.legacyUA], timeout: 20),
              (200..<300).contains(http.statusCode),
              let json = Upstream.jsonObject(data) else { return nil }
        let d = Self.dataDict(json)
        return Self.audioUrlOf(d["url"]) ?? Self.audioUrlOf(d["backup_url"])
    }

    private func songUrl(_ req: HttpRequest) async throws -> HttpResponse {
        let hash = (req.string("hash").isEmpty ? req.string("id") : req.string("hash")).uppercased()
        guard !hash.isEmpty else {
            return .json(200, ["code": 2, "reason": "unavailable", "error": "缺少 hash"])
        }
        let albumId = req.int("albumId", 0)
        let albumAudioId = req.int("albumAudioId", 0)
        if req.bool("cloud") {
            if let url = try? await fetchCloudURL(hash: hash, albumAudioId: albumAudioId,
                                                  audioId: req.int("audioId", 0), name: req.string("name")) {
                // r31 真实音质：云盘文件的实际档位未知，绝不硬编 "flac"——
                // 空串进桥后 canon 回 nil，UI 不挂徽章。
                return .json(200, ["code": 0, "url": url, "quality": "", "via": "kugou-cloud"])
            }
            return .json(200, ["code": 2, "reason": "unavailable", "error": "云盘取链失败"])
        }
        var noUrlReason = ""
        var chainStopped = false
        for tier in Self.qualityTiers(req.string("quality", "master")) {
            if chainStopped { break }
            var variants = [(albumId, albumAudioId)]
            if albumId != 0 || albumAudioId != 0 { variants.append((0, 0)) }
            for v in variants {
                do {
                    let r = try await fetchSongURL(hash: hash, quality: tier, albumId: v.0, albumAudioId: v.1)
                    if r.authRequired {
                        // 文案分两种：存过 token 是登录失效，没存过是根本没登
                        //（reason 都是 "login"，下游只认 reason，文案只进诊断）。
                        let loggedIn = !loginState().token.isEmpty
                        return .json(200, ["code": 401, "reason": "login",
                                           "error": loggedIn ? "酷狗登录已失效，请重新扫码登录" : "酷狗取链需要登录，请扫码登录酷狗后再播"])
                    }
                    if let url = r.url {
                        return .json(200, ["code": 0, "url": url, "quality": tier, "via": "kugou"])
                    }
                    if noUrlReason.isEmpty { noUrlReason = r.reason }
                } catch {
                    // 超时停链（Folia 同款）：剩下的档位不再等，但 legacy 仍试。
                    if (error as NSError).code == NSURLErrorTimedOut { chainStopped = true }
                    if noUrlReason.isEmpty { noUrlReason = error.localizedDescription }
                    break
                }
            }
        }
        if let url = await legacyPlayInfo(hash: hash) {
            return .json(200, ["code": 0, "url": url, "quality": "128", "via": "kugou-legacy"])
        }
        if noUrlReason.isEmpty { noUrlReason = "unavailable" }
        // Folia `kugouNoUrlError(noUrlSeen, signedOut)` 同款：整条链都没给
        // 地址 + 根本没登录 → 登录后可能能放，回 reason:"login"（不回
        // 上游原文，否则播放页只显示「暂时无法播放」，用户不知道要登录）。
        // 已登录还拿不到地址时保留上游原因（无版权 / status 3 之类），不谎
        // 报登录问题。
        if loginState().token.isEmpty {
            return .json(200, ["code": 2, "reason": "login", "error": "酷狗取链需要登录，请扫码登录酷狗后再播"])
        }
        return .json(200, ["code": 2, "reason": noUrlReason, "error": noUrlReason])
    }

    // MARK: - 歌词（Folia kugouLyricProvider.ts：search_lyric 取首候选 →
    // download 取 decodeContent；KRC 解码后转 LRC/YRC；官方无结果时
    // 再按 LRCLIB 兜底——兜底是 Lizi 壳版约定，非 Folia 流程）

    private func lyric(_ req: HttpRequest) async throws -> HttpResponse {
        let hash = (req.string("hash").isEmpty ? req.string("id") : req.string("hash")).uppercased()
        let title = req.string("s")
        let artist = req.string("artist")
        let album = req.string("album")
        let durationSec = req.int("duration", 0)
        let albumAudioId = req.int("albumAudioId", 0)
        if !hash.isEmpty {
            let keyword = artist.isEmpty ? title : "\(artist) - \(title)"
            if let hit = try? await fetchKugouLyric(hash: hash, keyword: keyword,
                                                    durationMs: durationSec * 1000, albumAudioId: albumAudioId) {
                return .json(200, ["code": 200, "lyric": hit.lrc, "yrc": hit.yrc,
                                   "format": "lrc", "source": "kugou"])
            }
        }
        for kw in [title, req.string("originalName")] where !kw.isEmpty {
            if let hit = try? await fetchKugouLyric(hash: nil, keyword: kw,
                                                    durationMs: durationSec * 1000) {
                return .json(200, ["code": 200, "lyric": hit.lrc, "yrc": hit.yrc,
                                   "format": "lrc", "source": "kugou"])
            }
        }
        if let fb = await Lrclib.fetch(artist: artist, track: title, album: album, duration: durationSec) {
            return .json(200, ["code": 200, "lyric": fb.lyric, "yrc": fb.yrc,
                               "format": "lrc", "source": "lrclib"])
        }
        return .json(200, ["code": 200, "lyric": "", "yrc": "", "format": "lrc",
                           "source": "kugou", "error": "没有找到歌词"])
    }

    /// 歌词两步：`search_lyric`（clearDefaultParams；appid / clientver
    /// 取标准值 1005 / 20489）取首候选 → `lyric` download
    ///（fmt krc；contenttype != 0 时 base64 直解，否则 KRC 解）。
    private func fetchKugouLyric(hash: String?, keyword: String?,
                                 durationMs: Int, albumAudioId: Int = 0) async throws -> (lrc: String, yrc: String)? {
        var params: [String: String] = [
            "album_audio_id": String(albumAudioId), "appid": Self.stdAppid,
            "clientver": Self.stdClientver, "duration": String(durationMs),
            "lrctxt": "1", "man": "no",
        ]
        if let hash { params["hash"] = hash }
        if let keyword, !keyword.isEmpty { params["keyword"] = keyword }
        let search = try await gateway(path: "/v1/search", baseURL: "https://lyrics.kugou.com",
                                       method: "GET", params: params, clearDefault: true)
        var candidates: [[String: Any]] = []
        if let arr = search.json?["candidates"] as? [[String: Any]] { candidates = arr }
        else if let d = search.json?["data"] as? [String: Any],
                let arr = d["candidates"] as? [[String: Any]] { candidates = arr }
        guard let best = candidates.first else { return nil }
        let id = Self.strField(best, "id")
        let accesskey = Self.strField(best, "accesskey")
        guard !id.isEmpty, !accesskey.isEmpty else { return nil }
        let dl = try await gateway(path: "/download", baseURL: "https://lyrics.kugou.com",
                                   method: "GET",
                                   params: ["ver": "1", "client": "android", "id": id,
                                            "accesskey": accesskey, "fmt": "krc", "charset": "utf8"])
        let d = Self.dataDict(dl.json)
        guard let content = d["content"] as? String, !content.isEmpty else { return nil }
        let text: String?
        if scNum(d["contenttype"]) != 0 {
            text = Data(base64Encoded: content, options: .ignoreUnknownCharacters)
                .flatMap { String(data: $0, encoding: .utf8) }
        } else {
            text = Self.krcDecode(content)
        }
        guard let krc = text, !krc.isEmpty else { return nil }
        return (krcToLrc(krc), krcToYrc(krc))
    }

    // MARK: - 每日 / 精选 / 电台（Folia library：everyday_recommend /
    // top_song / top_playlist / personal_fm / top_card_youth /
    // fm_class / fm_songs）

    private func requireLogin() -> (token: String, userid: String)? {
        let login = loginState()
        guard !login.token.isEmpty else { return nil }
        return (login.token, login.userid)
    }

    private func tracksResponse(_ res: KGResponse) -> HttpResponse {
        let items = Self.firstSongArray(res.json)
        let tracks = items.compactMap { Self.kugouTrack($0) }
        let total = Self.intField(Self.dataDict(res.json), "total")
        return .json(200, ["code": 200, "source": "kugou", "tracks": tracks,
                           "songCount": total != 0 ? total : tracks.count])
    }

    /// 每日推荐（`module/everyday_recommend.js`）：POST
    /// /everyday_song_recommend，params {platform: ios}，
    /// x-router everydayrec.service.kugou.com。
    private func everydayRecommend() async throws -> HttpResponse {
        let res = try await gateway(path: "/everyday_song_recommend", method: "POST",
                                    params: ["platform": "ios"],
                                    xRouter: "everydayrec.service.kugou.com")
        return tracksResponse(res)
    }

    /// 每日历史（`module/everyday_history.js`）：POST
    /// /everyday/api/v1/get_history，params {mode: list, platform: ios}。
    private func everydayHistory(_ req: HttpRequest) async throws -> HttpResponse {
        var params: [String: String] = ["mode": req.string("mode", "list"),
                                         "platform": req.string("platform", "ios")]
        if !req.string("history_name").isEmpty { params["history_name"] = req.string("history_name") }
        if !req.string("date").isEmpty { params["date"] = req.string("date") }
        let res = try await gateway(path: "/everyday/api/v1/get_history", method: "POST",
                                    params: params, xRouter: "everydayrec.service.kugou.com")
        return tracksResponse(res)
    }

    /// 新歌速递（`module/top_song.js`）：POST
    /// /musicadservice/container/v1/newsong_publish，body
    /// {rank_id（type 参数，默认 21608）, userid, page, pagesize, tags: []}。
    private func topSongs(_ req: HttpRequest) async throws -> HttpResponse {
        let login = loginState()
        let body: JVal = .o([
            ("rank_id", .i(req.int("type", 21608))),
            ("userid", .i(Int(login.userid) ?? 0)),
            ("page", .i(max(1, req.int("page", 1)))),
            ("pagesize", .i(scClamp(req.int("limit", req.int("pagesize", 30)), 1, 50))),
            ("tags", .a([])),
        ])
        let res = try await gateway(path: "/musicadservice/container/v1/newsong_publish",
                                    method: "POST", body: body)
        return tracksResponse(res)
    }

    /// 精选歌单（`module/top_playlist.js`）：POST /v2/special_recommend，
    /// body 里的 key = signParamsKey(秒时间戳)（标准 1005/20489，与 body 同族），
    /// x-router specialrec.service.kugou.com；回包 data.special_list。
    private func topPlaylists(_ req: HttpRequest) async throws -> HttpResponse {
        let dev = deviceIdentity()
        let login = loginState()
        let sec = String(Int(Date().timeIntervalSince1970))
        let body: JVal = .o([
            ("appid", .i(1005)),
            ("mid", .s(dev.mid)),
            ("clientver", .i(20489)),
            ("platform", .s("android")),
            ("clienttime", .s(sec)),
            ("userid", .i(Int(login.userid) ?? 0)),
            ("module_id", .i(1)),
            ("page", .i(max(1, req.int("page", 1)))),
            ("pagesize", .i(scClamp(req.int("limit", req.int("pagesize", 30)), 1, 50))),
            ("key", .s(Self.signParamsKey(data: sec))),
            ("special_recommend", .o([
                ("withtag", .i(1)), ("withsong", .i(1)), ("sort", .i(1)),
                ("ugc", .i(1)), ("is_selected", .i(0)), ("withrecommend", .i(1)),
                ("area_code", .i(1)), ("categoryid", .i(req.int("category_id", 0))),
            ])),
            ("req_multi", .i(1)),
            ("retrun_min", .i(5)),
            ("return_special_falg", .i(1)),
        ])
        let res = try await gateway(path: "/v2/special_recommend", method: "POST", body: body,
                                    xRouter: "specialrec.service.kugou.com")
        let items = Self.firstListArray(res.json, keys: ["special_list", "list", "lists"])
        let playlists = items.compactMap { Self.kugouCollection($0, type: "playlist") }
        return .json(200, ["code": 200, "source": "kugou", "playlists": playlists])
    }

    /// 推荐歌单（r33 新增；yueku 热门歌单，t=6 热门）：
    /// GET http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?
    /// is_ajax=1&cdn=cdn&t=6&c=&p=1，回 {special_db:[{specialid,
    /// global_collection_id, specialname, img, ...}]}；歌单 id 取
    /// global_collection_id（kugouCollection 同款），详情复用已有的
    /// playlist/detail + playlist/tracks（playlistTracks 按
    /// global_collection_id 取曲）。注意：https 不通（VM 实测 000），
    /// 只能 http；旧推荐端点 everyday_recommend 很可能已废弃（回 error
    /// 200101），每日推荐主腿先保留，合成腿只作它回空时的兜底。
    private func recommendPlaylists(_ req: HttpRequest) async throws -> HttpResponse {
        let limit = scClamp(req.int("limit", 12), 1, 50)
        guard let url = URL(string: "http://www2.kugou.kugou.com/yueku/v9/special/getSpecial?is_ajax=1&cdn=cdn&t=6&c=&p=1") else {
            return .json(200, ["code": 502, "source": "kugou", "playlists": [], "error": "酷狗推荐歌单请求构造失败"])
        }
        let (data, _) = try await Upstream.fetch(url, headers: ["User-Agent": "Mozilla/5.0"], timeout: 20)
        guard let json = Upstream.jsonObject(data) else {
            return .json(200, ["code": 502, "source": "kugou", "playlists": [], "error": "酷狗推荐歌单返回无法解析"])
        }
        let items = Self.firstListArray(json, keys: ["special_db", "list", "lists"])
        let playlists = items.compactMap { Self.kugouCollection($0, type: "playlist") }
        return .json(200, ["code": 200, "source": "kugou", "playlists": Array(playlists.prefix(limit))])
    }

    /// 排行榜目录（r35-10：mobilecdnbj rank/list，Moumusic kg/leaderboard.js
    /// getBoardsData 同款；VM 实测 2026-11-21：https 不通（000）、
    /// gateway.kugou.com 转发 502，只有 http 通（200，56 个榜、1 个
    /// isvol != 1）。所以这里走 http://mobilecdnbj.kugou.com，
    /// ATS 例外见 project.yml LiziNative 的 NSExceptionDomains
    /// （只放 mobilecdnbj.kugou.com 这一个 host，不放任意加载）。
    /// 回 { code, source, playlists: [{ id: rankid, name: rankname,
    /// cover: album_img_9 ?? banner_9（{size} 换 1024、http 升 https，
    /// 走 coverOf）}] }；只收 isvol == 1 的榜（Moumusic 同款过滤）。
    private func rankList() async -> HttpResponse {
        guard let url = URL(string: "http://mobilecdnbj.kugou.com/api/v5/rank/list?version=9108&plat=0&showtype=2&parentid=0&apiver=6&area_code=1&withsong=1") else {
            return .json(200, ["code": 502, "source": "kugou", "playlists": [], "error": "酷狗榜单目录请求构造失败"])
        }
        do {
            let (data, resp) = try await Upstream.fetch(url, headers: ["User-Agent": "Mozilla/5.0"], timeout: 20)
            guard (200...299).contains(resp.statusCode),
                  let json = Upstream.jsonObject(data) as? [String: Any],
                  scNum(json["errcode"]) == 0 else {
                return .json(200, ["code": 502, "source": "kugou", "playlists": [], "error": "酷狗榜单目录取不到"])
            }
            let info = scArr(Self.dataDict(json), "info")
            let playlists = info.compactMap { item -> [String: Any]? in
                guard scInt(item, "isvol") == 1 else { return nil }
                let rankId = scStrOrNum(item, "rankid")
                let name = scStr(item, "rankname")
                guard !rankId.isEmpty, !name.isEmpty else { return nil }
                let rawCover = scStr(item, "album_img_9").isEmpty ? scStr(item, "banner_9") : scStr(item, "album_img_9")
                return ["id": rankId, "name": name, "cover": Self.coverOf(["sizable_cover": rawCover]),
                        "source": "kugou"]
            }
            return .json(200, ["code": 200, "source": "kugou", "playlists": playlists])
        } catch {
            return .json(200, ["code": 502, "source": "kugou", "playlists": [], "error": "酷狗榜单目录取不到"])
        }
    }

    /// 榜单曲目（r35-10：mobilecdnbj rank/song，Moumusic kg/leaderboard.js
    /// getList 同款；VM 实测 2026-11-21：http 通，total 500（TOP500）。
    /// 一页最多 100 首，翻页由 NativeBridge.playlistAllTracks 做到 total
    /// 为止（最多 10 页）。回 { code, source, id, total, tracks }。
    private func rankTracks(_ req: HttpRequest) async -> HttpResponse {
        let rankId = req.string("id")
        guard !rankId.isEmpty else { return .json(400, ["code": 400, "error": "id required"]) }
        let page = max(1, req.int("page", 1))
        let limit = scClamp(req.int("limit", 100), 1, 100)
        guard let url = URL(string: "http://mobilecdnbj.kugou.com/api/v3/rank/song?version=9108&ranktype=1&plat=0&pagesize=\(limit)&area_code=1&page=\(page)&rankid=\(scURLEncode(rankId))&with_res_tag=0&show_portrait_mv=1") else {
            return .json(200, ["code": 502, "source": "kugou", "id": rankId, "tracks": [], "total": 0, "error": "酷狗榜单请求构造失败"])
        }
        do {
            let (data, resp) = try await Upstream.fetch(url, headers: ["User-Agent": "Mozilla/5.0"], timeout: 20)
            guard (200...299).contains(resp.statusCode),
                  let json = Upstream.jsonObject(data) as? [String: Any],
                  scNum(json["errcode"]) == 0 else {
                return .json(200, ["code": 502, "source": "kugou", "id": rankId, "tracks": [], "total": 0, "error": "酷狗榜单取不到"])
            }
            let d = Self.dataDict(json)
            let tracks = scArr(d, "info").compactMap { Self.kugouRankTrack($0) }
            return .json(200, ["code": 200, "source": "kugou", "id": rankId,
                               "total": scInt(d, "total"), "tracks": tracks])
        } catch {
            return .json(200, ["code": 502, "source": "kugou", "id": rankId, "tracks": [], "total": 0, "error": "酷狗榜单取不到"])
        }
    }

    /// 榜单曲目归一化：filename「歌手 - 歌名」拆歌手/歌名、320hash/sqhash
    /// 映射音质 hash、album_sizable_cover 作封面——Moumusic
    /// kg/leaderboard.js filterData 同款；其余字段走现成的 kugouTrack
    ///（它已处理 filename 拆分与 hash；album_sizable_cover 与 remark
    /// 先换成它认的键再调）。
    private static func kugouRankTrack(_ raw: [String: Any]) -> [String: Any]? {
        var shaped = raw
        let cover = strField(raw, "album_sizable_cover")
        if !cover.isEmpty { shaped["sizable_cover"] = cover }
        let remark = strField(raw, "remark")
        if !remark.isEmpty { shaped["album_name"] = remark }
        guard var track = kugouTrack(shaped) else { return nil }
        // 音质 hash 原样透传（取链按档位调 /v5/url 时用 base hash；
        // 320/sq 档的 hash 留给以后按档位直取，不编）。
        for key in ["320hash", "sqhash", "hash_high"] {
            let v = strField(raw, key)
            if !v.isEmpty { track[key] = v }
        }
        return track
    }

    /// 私人 FM（`module/personal_fm.js`）：POST /v2/personal_recommend，
    /// body 里的 key = signParamsKey(毫秒时间戳)，
    /// x-router persnfm.service.kugou.com。
    private func personalFm() async throws -> HttpResponse {
        let dev = deviceIdentity()
        let login = loginState()
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        var pairs: [(String, JVal)] = [
            ("appid", .i(1005)),
            ("clienttime", .i(ms)),
            ("mid", .s(dev.mid)),
            ("action", .s("play")),
            ("recommend_source_locked", .i(0)),
            ("song_pool_id", .i(0)),
            ("callerid", .i(0)),
            ("m_type", .i(1)),
            ("platform", .s("ios")),
            ("area_code", .i(1)),
            ("remain_songcnt", .i(0)),
            ("clientver", .i(20489)),
            ("is_overplay", .i(0)),
            ("mode", .s("normal")),
            ("fakem", .s("ca981cfc583a4c37f28d2d49000013c16a0a")),
            ("key", .s(Self.signParamsKey(data: String(ms)))),
        ]
        if !login.userid.isEmpty {
            pairs.append(("userid", .s(login.userid)))
            pairs.append(("kguid", .s(login.userid)))
        }
        if !login.token.isEmpty { pairs.append(("token", .s(login.token))) }
        if !login.vipType.isEmpty { pairs.append(("vip_type", .s(login.vipType))) }
        let res = try await gateway(path: "/v2/personal_recommend", method: "POST",
                                    body: .o(pairs), xRouter: "persnfm.service.kugou.com")
        return tracksResponse(res)
    }

    /// 推荐卡片（Folia `top_card_youth`，壳版无此路由、新开）：
    /// POST youth/v1/song/single_card_recommend，params
    /// {card_id（默认 3005 潮流尝鲜）, area_code 1, platform ios,
    /// module_id 1, ver v2, pagesize, clientver 11490}，
    /// body {tagid "", u_info "", source_mixsong ""}。
    private func recommendSongs(_ req: HttpRequest) async throws -> HttpResponse {
        let body: JVal = .o([
            ("tagid", .s(req.string("tagid"))),
            ("u_info", .s("")),
            ("source_mixsong", .s("")),
        ])
        let res = try await gateway(path: "/youth/v1/song/single_card_recommend",
                                    method: "POST",
                                    params: ["card_id": String(req.int("card_id", 3005)),
                                             "area_code": "1", "platform": "ios",
                                             "module_id": "1", "ver": "v2",
                                             "pagesize": String(scClamp(req.int("limit", req.int("pagesize", 30)), 1, 50)),
                                             "clientver": "11490"],
                                    body: body)
        return tracksResponse(res)
    }

    /// 电台分类（`module/fm_class.js`）：POST /v1/class_fm_song，
    /// body 里的 key = signParamsKey(毫秒时间戳)，
    /// x-router fm.service.kugou.com。
    private func fmClass() async throws -> HttpResponse {
        let dev = deviceIdentity()
        let login = loginState()
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let body: JVal = .o([
            ("kguid", .i(Int(login.userid) ?? 0)),
            ("clienttime", .i(ms)),
            ("mid", .s(dev.mid)),
            ("platform", .s("android")),
            ("clientver", .i(20489)),
            ("uid", .i(Int(login.userid) ?? 0)),
            ("get_tracker", .i(1)),
            ("key", .s(Self.signParamsKey(data: String(ms)))),
            ("appid", .i(1005)),
        ])
        let res = try await gateway(path: "/v1/class_fm_song", method: "POST", body: body,
                                    xRouter: "fm.service.kugou.com")
        // 回包是分类表 data.class_list，每类 {classid, classname, fmlist}；
        // 电台在各类的 fmlist 里——展平成 stations（分类本身不是电台，
        // 直接归一化会因无 fmid 被滤掉、rail 全空，见 VM 实测）。
        let classes = Self.firstListArray(res.json, keys: ["class_list", "list", "lists"])
        var stations: [[String: Any]] = []
        for c in classes {
            guard let fms = c["fmlist"] as? [[String: Any]] else { continue }
            for fm in fms {
                if let st = Self.kugouStation(fm) { stations.append(st) }
            }
        }
        return .json(200, ["code": 200, "source": "kugou", "stations": stations])
    }

    /// 电台曲目（`module/fm_songs.js`）：POST /v1/app_song_list_offset，
    /// body data [{fmid, fmtype 2, offset -1, size, singername ""}]，
    /// x-router fm.service.kugou.com，Content-Type application/json。
    private func fmSongs(_ req: HttpRequest) async throws -> HttpResponse {
        let dev = deviceIdentity()
        let login = loginState()
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let body: JVal = .o([
            ("appid", .i(1005)),
            ("area_code", .i(1)),
            ("clienttime", .i(ms)),
            ("clientver", .i(20489)),
            ("data", .a([.o([
                ("fmid", .s(req.string("fmid"))),
                ("fmtype", .i(req.int("fmtype", 2))),
                ("offset", .i(req.int("offset", -1))),
                ("size", .i(scClamp(req.int("limit", req.int("size", 20)), 1, 50))),
                ("singername", .s("")),
            ])])),
            ("get_tracker", .i(1)),
            ("key", .s(Self.signParamsKey(data: String(ms)))),
            ("mid", .s(dev.mid)),
            ("uid", .i(Int(login.userid) ?? 0)),
        ])
        let res = try await gateway(path: "/v1/app_song_list_offset", method: "POST", body: body,
                                    xRouter: "fm.service.kugou.com",
                                    extraHeaders: ["Content-Type": "application/json"])
        return tracksResponse(res)
    }

    // MARK: - 用户歌单 / 歌单读写（Folia library：user_playlist /
    // playlist_track_all / playlist_detail / playlist_add /
    // playlist_tracks_add / playlist_tracks_del / playlist_del）

    /// 我的歌单（`module/user_playlist.js`）：POST /v7/get_all_list，
    /// body {userid, token, total_ver 979, type 2, page, pagesize}，
    /// params {plat 1, userid, token}，x-router cloudlist.service.kugou.com。
    /// 未登录回 401（不编空歌单）。
    private func userPlaylists(_ req: HttpRequest) async throws -> HttpResponse {
        guard let login = requireLogin() else {
            return .json(200, ["code": 401, "source": "kugou", "playlists": [],
                               "error": "请先登录酷狗"])
        }
        let body: JVal = .o([
            ("userid", .s(login.userid)),
            ("token", .s(login.token)),
            ("total_ver", .i(979)),
            ("type", .i(2)),
            ("page", .i(max(1, req.int("page", 1)))),
            ("pagesize", .i(scClamp(req.int("limit", req.int("pagesize", 30)), 1, 50))),
        ])
        let res = try await gateway(path: "/v7/get_all_list", method: "POST",
                                    params: ["plat": "1", "userid": login.userid, "token": login.token],
                                    body: body, xRouter: "cloudlist.service.kugou.com")
        // r31 登录态同尺子修：token 死了时上游回 errcode 非 0；以前这里不验，
        // 直接按空列表回，面板只剩「酷狗没有返回歌单」，和设置页「已登录」
        // 对不上。HTTP 200 + 上游拒 = 登录失效（401，面板显示重登提示）；
        // HTTP 非 200 = 上游故障（502，不谎称登录失效）。
        guard Self.upstreamStatus(res.json) == 1 else {
            if res.httpStatus == 200 {
                return .json(200, ["code": 401, "source": "kugou", "playlists": [],
                                   "error": "酷狗登录已失效，请重新扫码登录"])
            }
            return .json(200, ["code": 502, "source": "kugou", "playlists": [],
                               "error": "酷狗歌单拉取失败"])
        }
        let items = Self.firstListArray(res.json, keys: ["info", "list", "lists"])
        var playlists: [[String: Any]] = []
        var albums: [[String: Any]] = []
        for item in items {
            let type = Self.userCollectionType(item)
            let owned = item["type"] == nil || scNum(item["type"]) == 0
            if let c = Self.kugouCollection(item, type: type, owned: owned) {
                if type == "album" { albums.append(c) } else { playlists.append(c) }
            }
        }
        return .json(200, ["code": 200, "source": "kugou", "playlists": playlists,
                           "albums": albums, "tracks": []])
    }

    /// 歌单曲目（`module/playlist_track_all.js`）：GET
    /// /pubsongs/v2/get_other_list_file_nofilt。
    private func playlistTracks(_ req: HttpRequest) async throws -> HttpResponse {
        let pagesize = scClamp(req.int("limit", req.int("pagesize", 30)), 1, 100)
        let page = max(1, req.int("page", 1))
        let params: [String: String] = [
            "area_code": "1", "begin_idx": String((page - 1) * pagesize),
            "plat": "1", "type": "1", "mode": "1", "personal_switch": "1",
            "extend_fields": "abtags,hot_cmt,popularization",
            "pagesize": String(pagesize),
            "global_collection_id": req.string("id"),
        ]
        let res = try await gateway(path: "/pubsongs/v2/get_other_list_file_nofilt",
                                    method: "GET", params: params)
        return tracksResponse(res)
    }

    /// 歌单详情（`module/playlist_detail.js`）：POST /v3/get_list_info，
    /// body {data: [{global_collection_id}], userid, token}，
    /// x-router pubsongs.kugou.com。
    private func playlistDetail(_ req: HttpRequest) async throws -> HttpResponse {
        let login = loginState()
        let body: JVal = .o([
            ("data", .a([.o([("global_collection_id", .s(req.string("id")))])])),
            ("userid", .s(login.userid)),
            ("token", .s(login.token)),
        ])
        let res = try await gateway(path: "/v3/get_list_info", method: "POST", body: body,
                                    xRouter: "pubsongs.kugou.com")
        var first: [String: Any]? = nil
        if let arr = res.json?["data"] as? [[String: Any]] { first = arr.first }
        else if let d = res.json?["data"] as? [String: Any] { first = d }
        guard let item = first, let c = Self.kugouCollection(item, type: "playlist") else {
            return .json(200, ["code": 502, "source": "kugou", "error": "歌单详情拿不到"])
        }
        return .json(200, ["code": 200, "source": "kugou", "playlist": c])
    }

    /// 新建歌单（`module/playlist_add.js`）：POST
    /// /cloudlist.service/v5/add_list；type == 0 时 params 带
    /// {last_time, last_area gztx, userid, token}。
    private func playlistCreate(_ req: HttpRequest) async throws -> HttpResponse {
        guard let login = requireLogin() else {
            return .json(200, ["code": 401, "error": "请先登录酷狗"])
        }
        let type = req.int("type", 0)
        let name = req.string("name")
        guard !name.isEmpty else {
            return .json(200, ["code": 400, "error": "缺少歌单名"])
        }
        let clienttime = Int(Date().timeIntervalSince1970)
        var pairs: [(String, JVal)] = [
            ("userid", .s(login.userid)),
            ("token", .s(login.token)),
            ("total_ver", .i(0)),
            ("name", .s(name)),
            ("type", .i(type)),
            ("source", .i(req.int("source", 1))),
            ("is_pri", .i(type == 0 ? req.int("is_pri", 0) : 0)),
        ]
        if !req.string("list_create_userid").isEmpty {
            pairs.append(("list_create_userid", .s(req.string("list_create_userid"))))
        }
        if !req.string("list_create_listid").isEmpty {
            pairs.append(("list_create_listid", .s(req.string("list_create_listid"))))
        }
        pairs.append(("list_create_gid", .s(req.string("list_create_gid"))))
        pairs.append(("from_shupinmv", .i(0)))
        let params: [String: String] = type == 0
            ? ["last_time": String(clienttime), "last_area": "gztx",
               "userid": login.userid, "token": login.token] : [:]
        let res = try await gateway(path: "/cloudlist.service/v5/add_list", method: "POST",
                                    params: params, body: .o(pairs))
        return .json(200, ["code": 200, "source": "kugou", "data": Self.dataDict(res.json)])
    }

    /// 往歌单加歌（`module/playlist_tracks_add.js`）：POST
    /// /cloudlist.service/v6/add_song；输入 `data` 为
    /// "name|hash|album_id|mixsongid" 逗号串（库格式），或 JSON body 的
    /// tracks 数组（原生调用方便）。
    private func playlistTracksAdd(_ req: HttpRequest) async throws -> HttpResponse {
        guard let login = requireLogin() else {
            return .json(200, ["code": 401, "error": "请先登录酷狗"])
        }
        var resource: [JVal] = []
        let bodyTracks = req.jsonBody()["tracks"] as? [[String: Any]] ?? []
        if !bodyTracks.isEmpty {
            resource = bodyTracks.map { t in
                .o([("number", .i(1)), ("name", .s(Self.strField(t, "name"))),
                    ("hash", .s(Self.strField(t, "hash"))), ("size", .i(0)),
                    ("sort", .i(0)), ("timelen", .i(0)), ("bitrate", .i(0)),
                    ("album_id", .i(Self.intField(t, "album_id", "albumId"))),
                    ("mixsongid", .i(Self.intField(t, "mixsongid", "mixSongId")))])
            }
        } else {
            for s in req.string("data").components(separatedBy: ",") where !s.isEmpty {
                let parts = s.components(separatedBy: "|")
                resource.append(.o([
                    ("number", .i(1)), ("name", .s(parts.count > 0 ? parts[0] : "")),
                    ("hash", .s(parts.count > 1 ? parts[1] : "")), ("size", .i(0)),
                    ("sort", .i(0)), ("timelen", .i(0)), ("bitrate", .i(0)),
                    ("album_id", .i(parts.count > 2 ? Int(parts[2]) ?? 0 : 0)),
                    ("mixsongid", .i(parts.count > 3 ? Int(parts[3]) ?? 0 : 0)),
                ]))
            }
        }
        guard !resource.isEmpty else {
            return .json(200, ["code": 400, "error": "缺少要加的歌曲"])
        }
        let clienttime = Int(Date().timeIntervalSince1970)
        let body: JVal = .o([
            ("userid", .s(login.userid)),
            ("token", .s(login.token)),
            ("listid", .s(req.string("listid"))),
            ("list_ver", .i(0)),
            ("type", .i(0)),
            ("slow_upload", .i(1)),
            ("scene", .s("false;null")),
            ("data", .a(resource)),
        ])
        let params: [String: String] = ["last_time": String(clienttime), "last_area": "gztx",
                                         "userid": login.userid, "token": login.token]
        let res = try await gateway(path: "/cloudlist.service/v6/add_song", method: "POST",
                                    params: params, body: body)
        return .json(200, ["code": 200, "source": "kugou", "data": Self.dataDict(res.json)])
    }

    /// 从歌单删歌（`module/playlist_tracks_del.js`）：POST
    /// /v4/delete_songs，x-router cloudlist.service.kugou.com；
    /// 输入 fileids 逗号串。
    private func playlistTracksDel(_ req: HttpRequest) async throws -> HttpResponse {
        guard let login = requireLogin() else {
            return .json(200, ["code": 401, "error": "请先登录酷狗"])
        }
        let fileids = req.string("fileids").components(separatedBy: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !fileids.isEmpty else {
            return .json(200, ["code": 400, "error": "缺少 fileids"])
        }
        let body: JVal = .o([
            ("listid", .s(req.string("listid"))),
            ("userid", .s(login.userid)),
            ("data", .a(fileids.map { .o([("fileid", .i($0))]) })),
            ("type", .i(0)),
            ("token", .s(login.token)),
            ("list_ver", .i(0)),
        ])
        let res = try await gateway(path: "/v4/delete_songs", method: "POST", body: body,
                                    xRouter: "cloudlist.service.kugou.com")
        return .json(200, ["code": 200, "source": "kugou", "data": Self.dataDict(res.json)])
    }

    /// 删歌单（`module/playlist_del.js`）：与 user_cloud 同一套 AES+RSA
    /// 流程——body 是 AES 密文原文；params 带 RSA PKCS1 加密的
    /// {aes, uid, token}（大写 hex）与 signParamsKey(秒时间戳)；
    /// 回包 AES 解密。
    private func playlistDel(_ req: HttpRequest) async throws -> HttpResponse {
        guard let login = requireLogin() else {
            return .json(200, ["code": 401, "error": "请先登录酷狗"])
        }
        let listid = req.int("listid", 0)
        guard listid != 0 else {
            return .json(200, ["code": 400, "error": "缺少 listid"])
        }
        let clienttime = Int(Date().timeIntervalSince1970)
        let dataJSON = Self.jsonString(.o([
            ("listid", .i(listid)),
            ("total_ver", .i(0)),
            ("type", .i(1)),
        ]))
        guard let aes = Self.aesEncrypt(dataJSON) else {
            return .json(200, ["code": 502, "error": "加密失败"])
        }
        let pJSON = Self.jsonString(.o([
            ("aes", .s(aes.key)),
            ("uid", .i(Int(login.userid) ?? 0)),
            ("token", .s(login.token)),
        ]))
        guard let p = rsaPKCS1EncryptHex(pJSON)?.uppercased() else {
            return .json(200, ["code": 502, "error": "加密失败"])
        }
        let params: [String: String] = [
            "clienttime": String(clienttime),
            "key": Self.signParamsKey(data: String(clienttime)),
            "last_area": "gztx",
            "clientver": Self.stdClientver,
            "appid": Self.stdAppid,
            "last_time": String(clienttime),
            "p": p,
        ]
        let res = try await gateway(path: "/v2/delete_list", method: "POST",
                                    params: params, bodyRaw: Data(aes.base64.utf8),
                                    xRouter: "cloudlist.service.kugou.com")
        guard let plain = Self.aesDecryptJSON(res.raw.base64EncodedString(), key: aes.key) else {
            return .json(200, ["code": 502, "error": "删歌单回包解不开"])
        }
        return .json(200, ["code": 200, "source": "kugou", "data": plain])
    }

    // MARK: - 专辑 / 歌手（Folia library：album_detail / album_songs /
    // artist_detail / artist_albums / artist_audios）

    /// 专辑详情（`module/album_detail.js`）：POST /kmr/v2/albums，
    /// x-router openapi.kugou.com，kg-tid 255。
    private func albumDetail(_ req: HttpRequest) async throws -> HttpResponse {
        let body: JVal = .o([
            ("data", .a([.o([("album_id", .s(req.string("id")))])])),
            ("is_buy", .i(req.int("is_buy", 0))),
            ("fields", .s("album_id,album_name,publish_date,sizable_cover,intro,language,is_publish,heat,type,quality,authors,exclusive,author_name,trans_param")),
        ])
        let res = try await gateway(path: "/kmr/v2/albums", method: "POST", body: body,
                                    xRouter: "openapi.kugou.com",
                                    extraHeaders: ["kg-tid": "255"])
        var first: [String: Any]? = nil
        if let arr = res.json?["data"] as? [[String: Any]] { first = arr.first }
        else if let d = res.json?["data"] as? [String: Any] { first = d }
        guard let item = first, let album = Self.kugouCollection(item, type: "album") else {
            return .json(200, ["code": 502, "source": "kugou", "error": "专辑详情拿不到"])
        }
        return .json(200, ["code": 200, "source": "kugou", "album": album])
    }

    /// 专辑曲目（`module/album_songs.js`）：POST /v1/album_audio/lite，
    /// kg-tid 255。
    private func albumSongs(_ req: HttpRequest) async throws -> HttpResponse {
        let body: JVal = .o([
            ("album_id", .s(req.string("id"))),
            ("is_buy", .s(req.string("is_buy"))),
            ("page", .i(max(1, req.int("page", 1)))),
            ("pagesize", .i(scClamp(req.int("limit", req.int("pagesize", 30)), 1, 50))),
        ])
        let res = try await gateway(path: "/v1/album_audio/lite", method: "POST", body: body,
                                    xRouter: "openapi.kugou.com",
                                    extraHeaders: ["kg-tid": "255"])
        return tracksResponse(res)
    }

    /// 歌手详情（`module/artist_detail.js`）：POST /kmr/v3/author，kg-tid 36。
    private func artistDetail(_ req: HttpRequest) async throws -> HttpResponse {
        let body: JVal = .o([("author_id", .s(req.string("id")))])
        let res = try await gateway(path: "/kmr/v3/author", method: "POST", body: body,
                                    xRouter: "openapi.kugou.com",
                                    extraHeaders: ["kg-tid": "36"])
        let d = Self.dataDict(res.json)
        guard let artist = Self.kugouCollection(d, type: "artist") else {
            return .json(200, ["code": 502, "source": "kugou", "error": "歌手详情拿不到"])
        }
        return .json(200, ["code": 200, "source": "kugou", "artist": artist])
    }

    /// 歌手专辑（`module/artist_albums.js`）：POST /kmr/v1/author/albums，
    /// kg-tid 36；sort hot→3 否则 1。
    private func artistAlbums(_ req: HttpRequest) async throws -> HttpResponse {
        let body: JVal = .o([
            ("author_id", .s(req.string("id"))),
            ("pagesize", .i(scClamp(req.int("limit", req.int("pagesize", 30)), 1, 50))),
            ("page", .i(max(1, req.int("page", 1)))),
            ("sort", .i(req.string("sort") == "hot" ? 3 : 1)),
            ("category", .i(1)),
            ("area_code", .s("all")),
        ])
        let res = try await gateway(path: "/kmr/v1/author/albums", method: "POST", body: body,
                                    xRouter: "openapi.kugou.com",
                                    extraHeaders: ["kg-tid": "36"])
        let items = Self.firstListArray(res.json, keys: ["albums", "list", "lists"])
        let albums = items.compactMap { Self.kugouCollection($0, type: "album") }
        return .json(200, ["code": 200, "source": "kugou", "albums": albums])
    }

    /// 歌手歌曲（`module/artist_audios.js`）：POST
    /// openapi.kugou.com/kmr/v1/audio_group/author，body 里的 key =
    /// signParamsKey(秒时间戳)，kg-tid 220；sort hot→1 否则 2。
    private func artistAudios(_ req: HttpRequest) async throws -> HttpResponse {
        let dev = deviceIdentity()
        let clienttime = Int(Date().timeIntervalSince1970)
        let body: JVal = .o([
            ("appid", .i(1005)),
            ("clientver", .i(20489)),
            ("mid", .s(dev.mid)),
            ("clienttime", .i(clienttime)),
            ("key", .s(Self.signParamsKey(data: String(clienttime)))),
            ("author_id", .s(req.string("id"))),
            ("pagesize", .i(scClamp(req.int("limit", req.int("pagesize", 30)), 1, 50))),
            ("page", .i(max(1, req.int("page", 1)))),
            ("sort", .i(req.string("sort") == "hot" ? 1 : 2)),
            ("area_code", .s("all")),
        ])
        let res = try await gateway(path: "/kmr/v1/audio_group/author",
                                    baseURL: "https://openapi.kugou.com",
                                    method: "POST", body: body,
                                    xRouter: "openapi.kugou.com",
                                    extraHeaders: ["kg-tid": "220"])
        return tracksResponse(res)
    }

    // MARK: - 云盘 / 最近 / 会员 / 高潮 / 元数据（Folia library：
    // user_cloud / user_cloud_url / user_listen / user_vip_detail /
    // song_climax / audio / krm_audio）

    /// 我的云盘（`module/user_cloud.js`）：与 playlist_del 同一套
    /// AES+RSA 流程——body 是 AES 密文原始字节（不是 base64 串），
    /// params 带 RSA PKCS1 大写 hex 的 p 与 signParamsKey(秒时间戳，
    /// 显传标准 appid 1005）；clearDefaultParams 且不签名；
    /// 回包 AES 解密。
    private func userCloud(_ req: HttpRequest) async throws -> HttpResponse {
        guard let login = requireLogin() else {
            return .json(200, ["code": 401, "error": "请先登录酷狗"])
        }
        let clienttime = Int(Date().timeIntervalSince1970)
        let dataJSON = Self.jsonString(.o([
            ("page", .i(max(1, req.int("page", 1)))),
            ("pagesize", .i(scClamp(req.int("limit", req.int("pagesize", 30)), 1, 50))),
            ("getkmr", .i(1)),
        ]))
        guard let aes = Self.aesEncrypt(dataJSON) else {
            return .json(200, ["code": 502, "error": "加密失败"])
        }
        let pJSON = Self.jsonString(.o([
            ("aes", .s(aes.key)),
            ("uid", .i(Int(login.userid) ?? 0)),
            ("token", .s(login.token)),
        ]))
        guard let p = rsaPKCS1EncryptHex(pJSON)?.uppercased(),
              let cipherBytes = Data(base64Encoded: aes.base64, options: .ignoreUnknownCharacters) else {
            return .json(200, ["code": 502, "error": "加密失败"])
        }
        let params: [String: String] = [
            "clienttime": String(clienttime),
            "mid": deviceIdentity().mid,
            "key": Self.signParamsKey(data: String(clienttime), appid: Self.stdAppid),
            "clientver": Self.stdClientver,
            "appid": Self.stdAppid,
            "p": p,
        ]
        let res = try await gateway(path: "/v1/get_list",
                                    baseURL: "https://mcloudservice.kugou.com",
                                    method: "POST", params: params,
                                    bodyRaw: cipherBytes,
                                    clearDefault: true, skipSignature: true)
        guard let plain = Self.aesDecryptJSON(res.raw.base64EncodedString(), key: aes.key) else {
            return .json(200, ["code": 502, "error": "云盘回包解不开"])
        }
        let items = Self.firstSongArray(plain)
        let tracks = items.compactMap { Self.kugouTrack($0) }
        return .json(200, ["code": 200, "source": "kugou", "tracks": tracks,
                           "songCount": tracks.count])
    }

    /// 云盘取链（`module/user_cloud_url.js`），见 fetchCloudURL。
    private func userCloudUrl(_ req: HttpRequest) async throws -> HttpResponse {
        let hash = (req.string("hash").isEmpty ? req.string("id") : req.string("hash")).uppercased()
        guard !hash.isEmpty else {
            return .json(200, ["code": 2, "reason": "unavailable", "error": "缺少 hash"])
        }
        if let url = try? await fetchCloudURL(hash: hash, albumAudioId: req.int("albumAudioId", 0),
                                              audioId: req.int("audioId", 0), name: req.string("name")) {
            // r31 真实音质：云盘文件的实际档位未知，绝不硬编 "flac"——
            // 空串进桥后 canon 回 nil，UI 不挂徽章。
            return .json(200, ["code": 0, "url": url, "quality": "", "via": "kugou-cloud"])
        }
        return .json(200, ["code": 2, "reason": "unavailable", "error": "云盘取链失败"])
    }

    /// 最近收听（`module/user_listen.js`）：POST
    /// listenservice.kugou.com/v2/get_list；body 的 p 是原始 RSA 加密的
    /// {clienttime, token}（大写 hex）；params {clienttime, plat 0}。
    private func userListen(_ req: HttpRequest) async throws -> HttpResponse {
        guard let login = requireLogin() else {
            return .json(200, ["code": 401, "error": "请先登录酷狗"])
        }
        let clienttime = Int(Date().timeIntervalSince1970)
        let pJSON = Self.jsonString(.o([
            ("clienttime", .i(clienttime)),
            ("token", .s(login.token)),
        ]))
        guard let p = rsaRawEncryptUpperHex(pJSON) else {
            return .json(200, ["code": 502, "error": "加密失败"])
        }
        let body: JVal = .o([
            ("t_userid", .s(login.userid)),
            ("userid", .s(login.userid)),
            ("list_type", .i(req.int("type", 0))),
            ("area_code", .i(1)),
            ("cover", .i(2)),
            ("p", .s(p)),
        ])
        let res = try await gateway(path: "/v2/get_list",
                                    baseURL: "https://listenservice.kugou.com",
                                    method: "POST",
                                    params: ["clienttime": String(clienttime), "plat": "0"],
                                    body: body)
        return tracksResponse(res)
    }

    /// 会员详情（`module/user_vip_detail.js`）：GET
    /// kugouvip.kugou.com/v1/get_union_vip，params {busi_type: concept}。
    /// vip 判定（Folia normalizeKugouVipType）：直读 vip_type / is_vip，
    /// 没有时看 busi_vip 里有没有 is_vip。r31-membership：多键全扫取最大
    /// （intField 只取第一个在场的键会漏），与 status() 同款。
    /// union 接口不报 SVIP 等级，这里不编 isSuperVIP 字段。
    private func userVip() async throws -> HttpResponse {
        let res = try await gateway(path: "/v1/get_union_vip",
                                    baseURL: "https://kugouvip.kugou.com",
                                    method: "GET", params: ["busi_type": "concept"])
        let data = Self.dataDict(res.json)
        var vipType = Self.maxIntField(data, "vip_type", "vipType", "is_vip")
        if vipType == 0,
           let busi = data["busi_vip"] as? [[String: Any]],
           busi.contains(where: { Self.maxIntField($0, "is_vip", "vip_type") > 0 }) {
            vipType = 1
        }
        return .json(200, ["code": 200, "source": "kugou", "vip": vipType > 0,
                           "vipType": vipType, "data": data])
    }

    /// 高潮片段（`module/song_climax.js`）：GET
    /// expendablekmrcdn.kugou.com/v1/audio_climax/audio，
    /// params {data: JSON([{hash}])}。
    private func songClimax(_ req: HttpRequest) async throws -> HttpResponse {
        let hashes = req.string("hash").components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let dataJSON = Self.jsonString(.a(hashes.map { .o([("hash", .s($0))]) }))
        let res = try await gateway(path: "/v1/audio_climax/audio",
                                    baseURL: "https://expendablekmrcdn.kugou.com",
                                    method: "GET", params: ["data": dataJSON])
        return .json(200, ["code": 200, "source": "kugou", "data": Self.dataDict(res.json)])
    }

    /// 单曲元数据（`module/audio.js`，Folia 的 `audio` 操作；getSongDetail
    /// 用它取曲目信息）：POST /v1/audio/audio，body 里的 key =
    /// signParamsKey(毫秒时间戳)。库里 baseURL 是 http://kmr.service.kugou.com；
    /// VM 实测该 host 的 443 端口根本不讲 TLS（Python 报 WRONG_VERSION_NUMBER，
    /// openssl 拿不到证书），https 直连必死、http 又撞 ATS——所以改走网关代发：
    /// POST https://gateway.kugou.com/v1/audio/audio + x-router
    /// kmr.service.kugou.com，VM 实测 HTTP 200 status 1（body 标准 1005/20489
    /// + lite key 的 mix 与全标准都通）。
    private func audioMeta(_ req: HttpRequest) async throws -> HttpResponse {
        let dev = deviceIdentity()
        let login = loginState()
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let dfid = dev.dfid
        var pairs: [(String, JVal)] = [
            ("appid", .i(1005)),
            ("clienttime", .i(ms)),
            ("clientver", .i(20489)),
            ("data", .a(req.string("hash").components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { .o([("hash", .s($0)), ("audio_id", .i(0))]) })),
            ("dfid", .s(dfid)),
            ("key", .s(Self.signParamsKey(data: String(ms)))),
            ("mid", .s(dev.mid)),
        ]
        if !login.token.isEmpty { pairs.append(("token", .s(login.token))) }
        if !login.userid.isEmpty { pairs.append(("userid", .s(login.userid))) }
        let res = try await gateway(path: "/v1/audio/audio",
                                    method: "POST", body: .o(pairs),
                                    xRouter: "kmr.service.kugou.com",
                                    extraHeaders: ["Content-Type": "application/json"])
        let items = Self.firstSongArray(res.json)
        if let first = items.first, let track = Self.kugouTrack(first) {
            return .json(200, ["code": 200, "source": "kugou", "track": track, "data": Self.dataDict(res.json)])
        }
        return .json(200, ["code": 200, "source": "kugou", "data": Self.dataDict(res.json)])
    }

    /// KRM 音频元数据（`module/krm_audio.js`）：POST /kmr/v2/audio，
    /// body {data: [{entity_id}], fields: base}，KG-TID 238。
    private func krmAudio(_ req: HttpRequest) async throws -> HttpResponse {
        let ids = req.string("album_audio_id").components(separatedBy: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let body: JVal = .o([
            ("data", .a(ids.map { .o([("entity_id", .i($0))]) })),
            ("fields", .s(req.string("fields", "base"))),
        ])
        let res = try await gateway(path: "/kmr/v2/audio", method: "POST", body: body,
                                    xRouter: "openapi.kugou.com",
                                    extraHeaders: ["KG-TID": "238"])
        return .json(200, ["code": 200, "source": "kugou", "data": Self.dataDict(res.json)])
    }
}
