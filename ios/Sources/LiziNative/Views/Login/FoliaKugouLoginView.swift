import SwiftUI

/// 酷狗扫码登录（r24 新写；删掉的 `KugouLoginView` 只是薄包装，这里不复用它）。
///
/// 按 r23a 通用二维码模式（`QrLoginView` + `QrStatusMapping.standard800`）
/// + Folia 登录流程（`kugouProvider.ts` auth：`login_qr_key` →
/// `login_qr_create` → `login_qr_check`，状态 0 过期 / 1 等待 / 2,3 已扫码 /
/// 4 或带 token 为确认）新写：
///
/// - 取码：`GET /api/kugou/login/qr/key` → `{ key, qrimg? }`；官方图
///   （login_qr_key 回的 `qrcode_img`）由服务端记在内存 Map 里，
///   create 优先回它，没有才按登录链接现画。
/// - 成码：`GET /api/kugou/login/qr/create?key=` → `{ key, qrimg, url }`。
/// - 轮询：`GET /api/kugou/login/qr/check?key=`，2 秒一轮（底座统一间隔）；
///   803 成功时先调一次 `/api/kugou/status` 确认 `loggedIn`（QQ flow
///   `confirmLogin` 同款），确认失败回 804（不报假成功；文案与 QQ 同款）。
/// - 取消：酷狗没有取消扫码的服务端接口（Folia 的 logout 只清本地登录态，
///   库里也没有 logout 模块），key 自然过期；`onCancel` 什么都不做。
/// - 成功：调 `LoginStore.refresh(platform: "kugou")` 刷新共享登录态，
///   设置页账号行随之重绘。
struct FoliaKugouLoginView: View {
    let onClose: () -> Void

    var body: some View {
        QrLoginView(
            platform: "kugou",
            fetch: {
                guard let d = await NativeBridge.call(path: "/api/kugou/login/qr/key") else {
                    return QrFetchResult(key: "", qrimg: "", loginURL: "",
                                        error: "拿不到二维码，请检查网络后重试")
                }
                let key = (d["key"] as? String) ?? ""
                let qrimg = (d["qrimg"] as? String) ?? ""
                let url = (d["url"] as? String) ?? ""
                let error = (d["error"] as? String) ?? ""
                guard !key.isEmpty else {
                    return QrFetchResult(key: "", qrimg: "", loginURL: "",
                                        error: error.isEmpty ? "拿不到二维码" : error)
                }
                return QrFetchResult(key: key, qrimg: qrimg, loginURL: url, error: "")
            },
            poll: { key in
                guard let d = await NativeBridge.call(path: "/api/kugou/login/qr/check",
                                                     query: ["key": key]) else {
                    // 这一轮没回来（网络抖）：抛错让底座跳过本轮、下一轮再试，不进 failed。
                    throw NSError(domain: "FoliaKugouLogin", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "check failed"])
                }
                let code = (d["code"] as? NSNumber)?.intValue ?? 0
                let message = (d["message"] as? String) ?? ""
                let nickname = (d["nickname"] as? String) ?? ""
                let avatar = (d["avatar"] as? String) ?? ""
                if code == 803 {
                    // 成功先确认登录态（QQ confirmLogin 同款）：status 说已登录
                    // 才报成功；否则报 804，不报假成功。
                    if let st = await NativeBridge.call(path: "/api/kugou/status"),
                       (st["loggedIn"] as? NSNumber)?.boolValue == true {
                        return QrPollResult(code: 803, status: "confirmed",
                                            message: nickname.isEmpty ? "登录成功" : "登录成功：\(nickname)",
                                            nickname: nickname, avatar: avatar)
                    }
                    return QrPollResult(code: 804, status: "failed",
                                        message: "登录已完成，但状态确认失败，请重新打开登录页查看")
                }
                return QrPollResult(code: code, status: "",
                                    message: message, nickname: nickname, avatar: avatar)
            },
            onCancel: { _ in
                // 酷狗没有取消扫码的服务端接口，key 自然过期；什么都不做。
            },
            onSuccess: {
                _ = await LoginStore.refresh(platform: "kugou")
            },
            onDismiss: onClose
        )
    }
}
