import Foundation

/// 落雪（LX）音源：只剩音源名映射与档位工具（自定义源注册表、脚本实例共用）。
/// 内置解析（oiapi/s0o1 等）已删——用户 2026-11-18 要求删掉「落雪音源」，
/// 取歌只走自定义源，拿不到就由 player.js 走平台接口备用。

enum LXResolver {
    /// liziair 的 source 名 -> LX 的 source 名。Spotify 没有 LX 解析；
    /// 汽水（qs）第 11 轮第 8/9 件接进来；酷狗（kg）r24 接回：赞助脚本的
    /// kg 入口已在构建机上剥掉（见工作流），这里的映射只服务用户自加的
    /// LX 自定义源（pdone 系等）作 LX 兜底。
    /// 波点（bd）r26 接进来：门先打开——LX 官方源只有 kw/kg/tx/wy/mg，
    /// 赞助源（聆澜）只扩展了 qs，两边今天都不声明 bd，所以波点 LX
    /// 目前仍无可用源、走不到真取链；但映射一开，用户以后加了声明 bd
    /// 的自定义源就能直接走通，不用再改三处关口。Apple Music 在 LX
    /// 生态里没有源 id（LX 脚本无法出 Apple Music 的链），不编 "am"
    /// 之类的假映射，见 NativeBridge.lxSongURL 的注释。
    static let sourceMap: [String: String] = [
        "netease": "wy", "qq": "tx", "kuwo": "kw", "kugou": "kg",
        // 汽水（qs）：第 11 轮第 8/9 件——新音源（聆澜音源赞助版 v9.0.1）上报 qs
        // 平台，取链实测通（320k）；App 之前把 qishui 拦在 LX 门外（""），
        // 平台拿不到地址时直接走演示音。
        "qishui": "qs", "bodian": "bd", "spotify": "",
    ]

    static func normalizeQuality(_ q: String?) -> String {
        guard let q, !q.isEmpty else { return "master" }
        let s = q.lowercased().replacingOccurrences(of: "[\\s_-]", with: "", options: .regularExpression)
        let map: [String: String] = [
            "jymaster": "master", "master": "master",
            "atmos": "atmos", "dolbyatmos": "atmos", "spatial": "atmos", "surround": "atmos",
            "jyeffect": "atmos", "hires": "hires", "flac24bit": "flac24bit", "24bit": "flac24bit",
            "flac": "flac", "lossless": "flac", "320k": "320k", "320": "320k", "exhigh": "320k",
            "128k": "128k", "128": "128k", "standard": "128k", "higher": "320k",
        ]
        return map[s] ?? "master"
    }
}
