import Foundation

/// 评论区后端（r27）：GET /api/comments?platform=&id=&key=&offset=&limit=
///
/// 只读，不发评论（发评论需登录，各平台发评接口未验证，本轮不做）。
/// 只接 2026-11-20 VM 实测通过的公开读接口：
/// - 网易云：GET https://music.163.com/api/v1/resource/comments/R_SO_4_{id}
///   （curl 实测回真实评论：hotComments 带 user.nickname/avatarUrl、
///   content、time、likedCount；匿名可读，无需登录）。
/// 其它平台一律回 HTTP 200 + {code: 501, error}（跟酷我登录的 501 写法
/// 同款，NativeBridge.call 只认 2xx + JSON，501 写在 body 里才传得到
/// 前端），绝不编假评论：
/// - QQ：c.y.qq.com fcg_global_comment_h5.fcg 匿名调回 code 0 但
///   commenttotal 恒为 0（晴天 0039MnYb0qxYhV 实测，两个端点都试过），
///   匿名拿不到列表；是否登录后能拿，未验证，不编。
/// - 酷我：www.kuwo.cn 评论接口要 csrf（匿名 curl 回 "The request is illegal!"），
///   comment.kuwo.cn 回 code 600「评论失败」；未验证出可用匿名接口。
/// - 酷狗：m.kugou.com/app/i/getSongComment.php 已死（"No Action Found!"），
///   mobilecdn 评论接口匿名无返回；FoliaKugou 里也没有评论口。
/// - 汽水 / 波点：无公开评论接口（App 内登录态接口，未验证）。
/// - Apple Music：本来就没有歌曲评论功能。
/// - 本地音乐：没有评论。
///
/// 成功回 {code: 0, platform, total, comments: [{nickname, avatar, content,
/// timeMs, likedCount}], hasMore}；hasMore = offset + 本次条数 < total。
enum CommentsService {
    static func handle(_ req: HttpRequest) async -> HttpResponse {
        let platform = req.string("platform")
        let id = req.string("id")
        let limit = min(max(req.int("limit", 20), 1), 50)
        let offset = max(req.int("offset", 0), 0)
        guard !platform.isEmpty, !id.isEmpty else {
            return .json(200, ["code": 400, "error": "platform / id 必填"])
        }
        switch platform {
        case "netease":
            return await neteaseComments(id: id, limit: limit, offset: offset)
        case "qq":
            return .json(200, ["code": 501, "error": "QQ 评论暂不支持：匿名接口拿不到评论列表（实测回 0 条），登录后是否能拿尚未验证"])
        case "kuwo":
            return .json(200, ["code": 501, "error": "酷我评论暂不支持：网页接口需要登录态（csrf），未验证出可用接口"])
        case "kugou":
            return .json(200, ["code": 501, "error": "酷狗评论暂不支持：已知公开评论接口已下线"])
        case "qishui":
            return .json(200, ["code": 501, "error": "汽水评论暂不支持：没有公开评论接口"])
        case "bodian":
            return .json(200, ["code": 501, "error": "波点评论暂不支持：没有公开评论接口"])
        case "applemusic":
            return .json(200, ["code": 501, "error": "Apple Music 没有歌曲评论功能"])
        case "local":
            return .json(200, ["code": 501, "error": "本地音乐没有评论"])
        default:
            return .json(200, ["code": 501, "error": "该平台暂无评论接口"])
        }
    }

    /// 网易云评论（公开接口，无需登录；热门评论在前，再接普通评论）。
    private static func neteaseComments(id: String, limit: Int, offset: Int) async -> HttpResponse {
        guard let songId = Int(id), songId > 0 else {
            return .json(200, ["code": 400, "error": "网易云歌曲 id 非法"])
        }
        let urlString = "https://music.163.com/api/v1/resource/comments/R_SO_4_\(songId)?limit=\(limit)&offset=\(offset)"
        guard let url = URL(string: urlString) else {
            return .json(200, ["code": 502, "error": "网易云评论地址拼不出来"])
        }
        do {
            let json = try await Upstream.fetchJSON(
                url,
                headers: ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"],
                timeout: 15
            )
            guard let d = json as? [String: Any] else {
                return .json(200, ["code": 502, "error": "网易云评论返回的不是 JSON"])
            }
            let code = (d["code"] as? NSNumber)?.intValue ?? -1
            guard code == 200 else {
                return .json(200, ["code": 502, "error": "网易云评论接口回 code \(code)"])
            }
            let total = (d["total"] as? NSNumber)?.intValue ?? 0
            var out: [[String: Any]] = []
            // 热门在前（offset 为 0 时才有 hotComments；翻页时只取 comments）。
            if offset == 0 {
                for c in (d["hotComments"] as? [[String: Any]] ?? []) {
                    if let item = normalizeNeteaseComment(c) { out.append(item) }
                }
            }
            for c in (d["comments"] as? [[String: Any]] ?? []) {
                if let item = normalizeNeteaseComment(c) { out.append(item) }
            }
            let hasMore = offset + out.count < total
            return .json(200, ["code": 0, "platform": "netease", "total": total,
                               "comments": out, "hasMore": hasMore])
        } catch {
            return .json(200, ["code": 502, "error": "网易云评论请求失败：\(error.localizedDescription)"])
        }
    }

    /// 网易云一条评论归一化（空内容不要；头像可能为空字符串）。
    private static func normalizeNeteaseComment(_ c: [String: Any]) -> [String: Any]? {
        let content = ((c["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        let user = (c["user"] as? [String: Any]) ?? [:]
        let nickname = (user["nickname"] as? String) ?? ""
        let avatar = (user["avatarUrl"] as? String) ?? ""
        let timeMs = (c["time"] as? NSNumber)?.intValue ?? 0
        let liked = (c["likedCount"] as? NSNumber)?.intValue ?? 0
        return [
            "nickname": nickname.isEmpty ? "匿名用户" : nickname,
            "avatar": avatar,
            "content": content,
            "timeMs": timeMs,
            "likedCount": liked,
        ]
    }
}
