import SwiftUI

/// 通用二维码登录视图（r23a 登录底座，供 r23b–r23e 各平台 flow 嵌用；
/// 各家 flow 目前是自己写的轮询，本视图是下一轮统一替换的目标——汽水 / 波点
/// 文件头已注明“r23a 的 QrLoginView 落盘后替换这一块，输入不变”）。
///
/// 对照壳版流程：QQ `startQr` / `check`（`public/app.js:3400–3650`）、网易
/// `pollQr`（`public/app.js:14618–14660`）、卡片兜底（`public/app.js:8649`）。
/// 壳版规则原样保留：
/// - 取码 → 2 秒轮询（QQ 2000ms、网易 2000ms、卡片 2200ms；底座取 2s），
///   上一轮没回来就跳过这一轮，不并发轮询；网络抖一下保持当前状态、下一轮再试。
/// - 视图消失必须取消轮询并调取消闭包（壳版 `pause()`：停轮询 + abort 在飞的
///   拿码请求 + 调 `qqQrCancel`，不然旧会话的驱动一直跑到过期）。
/// - 二维码优先用后端给的 `qrimg`（`data:image/png;base64,…`，本地解码成
///   `UIImage`，不引第三方二维码库）；后端没给时退回 qrserver.com 把登录链接
///   画成二维码（壳版 `app.js:8649` 同款 URL）。
///
/// 状态码绝不在本视图里写死：状态码映射由各平台 flow 传入
/// （`QrStatusMapping`）。`QrStatusMapping.standard800` 是 4 家扫码平台
/// （网易 / QQ / 汽水 / 波点）后端实际回的同一套 800/801/802/803
/// （网易 `NetEase.swift` normalize `login/qr/check`、QQ `checkQr`、
/// 汽水 / 波点 `loginQrCheck`），只是个现成的映射值，不写在转移逻辑里。
/// 不认识的状态保持等待（壳版 `app.js:3633` 注释同款规则），不编失败。

// MARK: - 输入 / 输出类型（flow 传入闭包用的就是这几个类型）

/// 取码结果：`key` + `qrimg`（`data:image/png;base64,…`，后端没给时 ""）+
/// `loginURL`（兜底画码用的登录链接；网易是
/// `https://music.163.com/login?codekey=<key>`，各家 flow 传自己的链接，
/// 传 "" 表示没有可画的链接）+ `error`（取码失败时的上游原话，成功时 ""）。
struct QrFetchResult {
    var key: String
    var qrimg: String
    var loginURL: String
    var error: String

    static let empty = QrFetchResult(key: "", qrimg: "", loginURL: "", error: "")
}

/// 轮询结果：flow 把各平台 `check` 接口的字典翻译成这个形状再交给视图
/// （`code` 是上游数字码，`status` 是上游状态字符串，两者都没有的平台
/// flow 只填能填的；`message` 是上游原话，`nickname` 是成功时上游带的昵称）。
struct QrPollResult {
    var code: Int?
    var status: String
    var message: String
    var nickname: String
    var avatar: String

    init(code: Int? = nil, status: String = "", message: String = "",
         nickname: String = "", avatar: String = "") {
        self.code = code
        self.status = status
        self.message = message
        self.nickname = nickname
        self.avatar = avatar
    }
}

/// 扫码状态机（`waiting` 等扫码 → `scanned` 已扫码待确认 → `success` /
/// `expired` 过期重取 / `failed`；`loading` 是取码中）。
enum QrLoginPhase {
    case loading
    case waiting
    case scanned
    case success
    case expired
    case failed
}

/// 状态码 → 通用状态的映射（各平台 flow 传入；本视图的转移逻辑只认这个映射，
/// 不认任何一家平台的具体数字）。
struct QrStatusMapping {
    var waitingCodes: Set<Int>
    var scannedCodes: Set<Int>
    var successCodes: Set<Int>
    var expiredCodes: Set<Int>
    var failedCodes: Set<Int>
    var waitingStatuses: Set<String>
    var scannedStatuses: Set<String>
    var successStatuses: Set<String>
    var expiredStatuses: Set<String>
    var failedStatuses: Set<String>

    /// 4 家扫码平台后端实际回的同一套码（见文件头出处）：
    /// 800 过期 / 801 等待 / 802 已扫码 / 803 成功；汽水用户拒绝是 804
    /// （`Qishui.swift` loginQrCheck：`status: "refused", code: 804`）。
    static let standard800 = QrStatusMapping(
        waitingCodes: [801], scannedCodes: [802], successCodes: [803],
        expiredCodes: [800], failedCodes: [804],
        waitingStatuses: ["waiting", "created"],
        scannedStatuses: ["scanned"],
        successStatuses: ["confirmed", "success"],
        expiredStatuses: ["expired"],
        failedStatuses: ["refused", "failed"])

    /// 数字码优先于状态字符串；两者都对不上就保持等待，不编失败。
    func phase(for result: QrPollResult) -> QrLoginPhase {
        if let c = result.code {
            if successCodes.contains(c) { return .success }
            if scannedCodes.contains(c) { return .scanned }
            if expiredCodes.contains(c) { return .expired }
            if failedCodes.contains(c) { return .failed }
            if waitingCodes.contains(c) { return .waiting }
        }
        let st = result.status.lowercased()
        if !st.isEmpty {
            if successStatuses.contains(st) { return .success }
            if scannedStatuses.contains(st) { return .scanned }
            if expiredStatuses.contains(st) { return .expired }
            if failedStatuses.contains(st) { return .failed }
            if waitingStatuses.contains(st) { return .waiting }
        }
        return .waiting
    }
}

// MARK: - 状态机（可取消的取码 + 轮询；视图只负责画它）

/// 二维码登录的状态机。`cancel()` 是唯一出口：停轮询 + 调一次取消闭包
/// （把 key 交给 flow 去调服务端的 cancel 路由，如 QQ `login/qr/cancel`），
/// 视图消失 / 点取消 / 换一张时都走它。
@MainActor
final class QrLoginModel: ObservableObject {
    @Published private(set) var phase: QrLoginPhase = .loading
    @Published private(set) var qrImage: UIImage?
    @Published private(set) var qrFallbackURL: URL?
    @Published private(set) var message: String = ""
    @Published private(set) var nickname: String = ""

    /// 轮询间隔 2 秒（壳版 QQ / 网易同款；汽水 / 波点 flow 自家是 2.2 秒，
    /// 底座统一取 2 秒）。
    static let pollIntervalNs: UInt64 = 2_000_000_000

    private(set) var key: String = ""
    private let platform: String
    private let mapping: QrStatusMapping
    private let fetch: () async -> QrFetchResult
    private let poll: (String) async throws -> QrPollResult
    private let onCancel: (String) async -> Void
    private let onSuccess: () async -> Void

    private var pollTask: Task<Void, Never>?
    private var checking = false
    private var cancelled = false
    private var successReported = false

    init(platform: String, mapping: QrStatusMapping,
         fetch: @escaping () async -> QrFetchResult,
         poll: @escaping (String) async throws -> QrPollResult,
         onCancel: @escaping (String) async -> Void,
         onSuccess: @escaping () async -> Void) {
        self.platform = platform
        self.mapping = mapping
        self.fetch = fetch
        self.poll = poll
        self.onCancel = onCancel
        self.onSuccess = onSuccess
    }

    deinit { pollTask?.cancel() }

    /// 开始（或换一张）：先取消旧 key 的服务端会话（壳版 `startQr` 同款），
    /// 再取新码、开轮询。视图出现时调一次即可。
    func start() {
        cancel()
        cancelled = false
        successReported = false
        phase = .loading
        message = ""
        nickname = ""
        qrImage = nil
        qrFallbackURL = nil
        pollTask = Task { await self.loadAndPoll() }
    }

    /// 停止轮询并取消服务端会话（只调一次取消闭包）。视图消失 / 点取消时调。
    func cancel() {
        cancelled = true
        pollTask?.cancel()
        pollTask = nil
        checking = false
        let k = key
        key = ""
        if !k.isEmpty {
            Task { await self.onCancel(k) }
        }
    }

    private func loadAndPoll() async {
        let r = await fetch()
        guard !cancelled, !Task.isCancelled else { return }
        guard !r.key.isEmpty else {
            phase = .failed
            message = r.error.isEmpty ? "拿不到二维码" : r.error
            return
        }
        key = r.key
        if let img = Self.image(fromQrimg: r.qrimg) {
            qrImage = img
            qrFallbackURL = nil
        } else if let url = Self.qrServerURL(loginURL: r.loginURL) {
            qrFallbackURL = url
            qrImage = nil
        } else {
            phase = .failed
            message = r.error.isEmpty ? "拿不到二维码" : r.error
            return
        }
        phase = .waiting
        message = ""
        await pollLoop()
    }

    private func pollLoop() async {
        while !cancelled, !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.pollIntervalNs)
            } catch {
                return
            }
            guard !cancelled, !Task.isCancelled, !key.isEmpty, !checking else { continue }
            checking = true
            do {
                let res = try await poll(key)
                checking = false
                guard !cancelled, !Task.isCancelled else { return }
                apply(res)
                if phase == .success || phase == .expired || phase == .failed { return }
            } catch {
                // 网络抖一下：保持当前状态，下一轮再试（壳版 check() catch 同款）。
                checking = false
            }
        }
    }

    private func apply(_ res: QrPollResult) {
        switch mapping.phase(for: res) {
        case .success:
            phase = .success
            nickname = res.nickname
            message = res.nickname.isEmpty ? "登录成功" : "登录成功：\(res.nickname)"
            stopPollingOnly()
            if !successReported {
                successReported = true
                Task { await self.onSuccess() }
            }
        case .scanned:
            phase = .scanned
            message = "已扫码，请在手机上确认"
        case .expired:
            phase = .expired
            message = res.message.isEmpty ? "二维码已过期，请换一张" : res.message
            stopPollingOnly()
        case .failed:
            phase = .failed
            message = res.message.isEmpty ? "登录失败，请重试" : res.message
            stopPollingOnly()
        case .waiting:
            phase = .waiting
            if !res.message.isEmpty { message = res.message }
        case .loading:
            break
        }
    }

    private func stopPollingOnly() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - 二维码图（纯函数；不引第三方二维码库）

    /// `data:image/png;base64,…`（或裸 base64）解码成 UIImage；解不出回 nil。
    static func image(fromQrimg qrimg: String) -> UIImage? {
        guard !qrimg.isEmpty else { return nil }
        let b64: String
        if let comma = qrimg.firstIndex(of: ",") {
            b64 = String(qrimg[qrimg.index(after: comma)...])
        } else {
            b64 = qrimg
        }
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              !data.isEmpty else { return nil }
        return UIImage(data: data)
    }

    /// 兜底：后端没给 qrimg 时，把登录链接画成二维码（壳版 `app.js:8649`
    /// 同款 URL：`size=180x180&margin=0`）。没有链接时回 nil，不编链接。
    static func qrServerURL(loginURL: String) -> URL? {
        guard !loginURL.isEmpty else { return nil }
        var c = URLComponents(string: "https://api.qrserver.com/v1/create-qr-code/")
        c?.queryItems = [URLQueryItem(name: "size", value: "180x180"),
                         URLQueryItem(name: "margin", value: "0"),
                         URLQueryItem(name: "data", value: loginURL)]
        return c?.url
    }
}

// MARK: - 视图

/// 通用二维码登录视图。
///
/// - `platform`：平台 id（netease / qq / kugou / qishui / bodian）。
/// - `fetch`：取码闭包，返回 key + qrimg + 登录链接（兜底画码用）。
/// - `poll`：轮询闭包，key → `QrPollResult`；抛错 = 网络抖动，本轮跳过、
///   下一轮再试（不进 failed）。
/// - `onCancel`：取消闭包，key → flow 调服务端 cancel 路由；视图消失、
///   点取消、换一张时调（只调一次）。
/// - `onSuccess`：成功时调一次（flow 在里面 `LoginStore.refresh` 确认
///   loggedIn，再关弹窗；确认失败 flow 自己留在页内报错，不由本视图关）。
/// - `onDismiss`：本视图的取消 / 完成按钮要关掉宿主时调（宿主决定怎么关；
///   flow 嵌用时一般接自己的关闭回调）。
struct QrLoginView: View {
    @StateObject private var model: QrLoginModel
    private let platform: String
    private let onDismiss: () -> Void

    init(platform: String, mapping: QrStatusMapping = .standard800,
         fetch: @escaping () async -> QrFetchResult,
         poll: @escaping (String) async throws -> QrPollResult,
         onCancel: @escaping (String) async -> Void,
         onSuccess: @escaping () async -> Void = {},
         onDismiss: @escaping () -> Void = {}) {
        self.platform = platform
        self.onDismiss = onDismiss
        _model = StateObject(wrappedValue: QrLoginModel(
            platform: platform, mapping: mapping, fetch: fetch, poll: poll,
            onCancel: onCancel, onSuccess: onSuccess))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("\(platformName)扫码登录")
                .font(.headline)
            qrArea
            Text(statusText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            buttons
        }
        .padding(20)
        // .task 的闭包是 @Sendable，不继承 MainActor：调 MainActor 隔离的
        // model.start() 必须经 MainActor.run（直接调编不过）。
        .task { await MainActor.run { model.start() } }
        .onDisappear { model.cancel() }
    }

    private var platformName: String {
        SettingsStore.platformNames[platform] ?? platform
    }

    @ViewBuilder
    private var qrArea: some View {
        if let img = model.qrImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: 220, height: 220)
        } else if let url = model.qrFallbackURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                        .frame(width: 220, height: 220)
                case .failure:
                    Text("二维码图片加载失败")
                        .frame(width: 220, height: 220)
                default:
                    ProgressView()
                        .frame(width: 220, height: 220)
                }
            }
        } else {
            Text(model.phase == .loading ? "正在获取二维码…" : "拿不到二维码")
                .frame(width: 220, height: 220)
        }
    }

    private var statusText: String {
        switch model.phase {
        case .loading: return "正在获取二维码…"
        case .waiting: return model.message.isEmpty ? "用\(platformName) App 扫码" : model.message
        case .scanned: return "已扫码，请在手机上确认"
        case .success: return model.message
        case .expired, .failed: return model.message
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .waiting, .scanned:
            Button("取消") {
                model.cancel()
                onDismiss()
            }
        case .expired, .failed:
            HStack(spacing: 16) {
                Button("换一张") { model.start() }
                Button("取消") {
                    model.cancel()
                    onDismiss()
                }
            }
        case .success:
            Button("完成") { onDismiss() }
        }
    }
}
