import SwiftUI
import UniformTypeIdentifiers

/// 设置页（P3-C，屏幕 11）：对照壳版 `public/index.html` 的 `#view-settings`
/// 整页 + `app.js` 设置逻辑，8 分区全做（r25 加形态歌词），不漏分区、
/// 不自造不存在的开关。
///
/// 对照表（壳版行 → 原生实现）：
/// 1. 平台账号：7 行平铺（网易云/QQ/酷狗/汽水/波点/酷我/Apple Music），
///    顺序与 `SettingsStore.platformIds` 一致；每行左边是平台小 logo
///    （`PlatformIconView` 26pt，r22j 平台管理行同款）+ 名字 + 限制说明
///    （照抄 `SettingsStore.platformLimits`，不改字）；右边是登录状态
///    （已登录显示昵称、取不到昵称显示「已登录」，未登录显示「未登录」）。
///    点整行：未登录 → 弹 `LoginSheetView`（r23a 底座，该平台登录流程，
///    r23b–e 填）；已登录 → 进 `AccountDetailView`（昵称/头像/VIP 状态 +
///    「退出登录」，退出前二次确认，走 `LoginStore.logout`）。
///    登录态以 `LoginStore` 为准（与 `platformAccounts()` 同源，见
///    `LoginSheetTarget.swift` 文件头的 r23a 接口约定）；设置页出现时
///    调 `LoginStore.refresh()`，登录/登出成功后底座发布变化、账号行
///    立即重绘。切台不碰登录态（`selectPlatform` 五步原样，一个字不动）。
/// 2. 自定义源管理：LXSourceRegistry 已有存储，列表/添加（URL + 本地文件）
///    /删除/开关/刷新/补绑 URL/自动切换，全接真接口；不改 LX 取链逻辑。
/// 3. 本地音乐：数量实读 LocalMusic 清单；在首页显示开关真持久化；
///    导入按钮接首页同款导入器（系统文件选择器，UTType.audio 多选，
///    `LocalMusic.importFiles`），导入后数量当场刷新（r25 #47）。
/// 4. 音效：9 档音质真选（调 PlaybackStore.setPreferredQuality，当场影响
///    取链档位）；均衡器细调（10 套预设 + 7 段 EQ）是 P4，本轮只做入口行
///    + 空态提示。壳版第 9 档 DTS:X 无上游流，原生不提供，不编。
/// 5. 播放页排版：4 套版式（默认/左右对半/上下分屏/极小封面）真持久化
///    `lizi.now.layout`；PlayerView r25 已按版式重排（对照见 PlayerView
///    文件头）。LRCLIB 兜底开关真生效（Lrclib.isEnabled 同键）。
/// 5b. 形态歌词（r25 #31）：原文 / 双文 / 译文三档（壳版 `#set-stage-lyric`，
///    键 `lizi.stage.lyricMode`，默认原文），只改形态里显示的字；
///    StageBridge 按档出词。
/// 6. 外观：平台头像/平台颜色/大厅内容轨/动画插图（默认开，`lizi.animatedArtwork`，
///    与 NowPlayingCoordinator 同键）/我的专辑展示/跑马带速度，全真持久化；
///    主页背景与大厅背景效果原生本轮做不了，只做诚实空态行 + 提示；
///    字体选择/快捷键壳版本身就是「待开放」，原样照搬为静态行；开场引导
///    壳版已隐藏（hidden），不复刻。
/// 7. 关于：版本（Bundle）、构建（LiziNativeBuildInfo，CI 生成）、诊断日志
///    （查看/复制，读 DiagLog）、QQ 群、赞助（支付宝收款码链接，均照抄壳版）。
///
/// 注意：`LiziNativeBuildInfo` 由构建工作流 `ipa-native` job 的
/// 「Write native build info」一步在构建机上生成
/// `ios/Sources/LiziNative/BuildInfo.generated.swift`（不进 git）；本地
/// 磁盘上没有这个文件是正常的，代码直接引用该类型即可，CI 生成后才编译。
/// P2 报告说它因无 UI 引用被 strip 掉——本页真实引用它（短 commit + build
/// 号 + 日期），让它进包。
struct SettingsView: View {
    @EnvironmentObject var playback: PlaybackStore
    @StateObject private var settings = SettingsStore()
    /// r23f：登录底座（r23a，`Views/Login/`）——设置页只消费它的接口
    /// （约定见 `LoginSheetTarget.swift` 文件头）；登录/登出成功后它发布
    /// 变化，账号行随之重绘。未落地前本引用编译不过（见 r23f 驱动 GAP）。
    @ObservedObject private var loginStore = LoginStore.shared

    /// 未登录行点开的登录页目标；账号详情里防御分支的「去登录」也用它。
    @State private var loginTarget: LoginSheetTarget?
    /// 已登录行点开的账号详情目标。
    @State private var accountDetailTarget: AccountDetailTarget?

    @State private var notice: Notice?
    @State private var showPlatformManager = false
    @State private var lxURLInput = ""
    @State private var showLXFileImporter = false
    @State private var rebindId: String?
    @State private var rebindURLInput = ""
    @State private var showDiagnostics = false
    @State private var diagnosticsText = ""
    /// r25 #47：本地导入文件选择器 + 导入结果行（导入后数量显示当场刷新）。
    @State private var showLocalImporter = false
    @State private var localImportStatus: String? = nil
    /// r25 #45：网易每日签到结果行 + 进行中态。
    @State private var dailySigninStatus = ""
    @State private var isSigningIn = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                accountSection
                lxSection
                localMusicSection
                audioSection
                nowLayoutSection
                stageLyricSection
                appearanceSection
                aboutSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(LiziTokens.paper)
        .onAppear {
            settings.refreshLXSources()
            // r23f：设置页出现时刷新登录态（登录/登出可能发生在别处——
            // 登录页、账号详情页；回来时行状态必须是最新的）。
            loginStore.refresh()
        }
        .sheet(item: $loginTarget) { target in
            LoginSheetView(platform: target.platform)
        }
        .sheet(item: $accountDetailTarget) { target in
            AccountDetailView(platform: target.platform)
        }
        .alert(item: $notice) { n in
            Alert(title: Text(n.title), message: Text(n.message),
                  dismissButton: .default(Text("知道了")))
        }
        .fileImporter(isPresented: $showLXFileImporter,
                      allowedContentTypes: [UTType(filenameExtension: "js") ?? .plainText],
                      allowsMultipleSelection: true) { result in
            handleLXFileImport(result)
        }
    }

    // MARK: - 通用小组件

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private func sectionCard<Content: View>(title: String, note: String? = nil,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.liziDisplay(size: LiziTokens.size20))
                .foregroundColor(LiziTokens.ink)
            if let note {
                Text(note)
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LiziTokens.paper2)
        .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius14))
    }

    private func rowLabel(_ text: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                .foregroundColor(LiziTokens.ink)
            if let hint {
                Text(hint)
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
            }
        }
    }

    private func toggleRow(_ label: String, hint: String, isOn: Binding<Bool>) -> some View {
        HStack {
            rowLabel(label, hint: hint)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    private func openExternal(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - 1. 平台账号

    private var accountSection: some View {
        sectionCard(title: "平台账号", note: "七家平台平级，登录方式各不相同，限制都写在自己那一行里。") {
            ForEach(settings.platformAccounts()) { account in
                // r23f：真入口（占位文案已删）。登录态取 platformAccounts()
                // 的实读会话（与 LoginStore 同源）；昵称取自 LoginStore，
                // 取不到昵称的已登录态显示「已登录」，不编昵称。
                let info = LiziPlatforms.all.first(where: { $0.id == account.id })
                let nickname = account.loggedIn
                    ? loginStore.displayName(platform: account.id) : nil
                Button(action: {
                    if account.loggedIn {
                        accountDetailTarget = AccountDetailTarget(platform: account.id)
                    } else {
                        loginTarget = LoginSheetTarget(platform: account.id)
                    }
                }) {
                    HStack(spacing: 10) {
                        if let info {
                            PlatformIconView(platform: info, selected: false, size: 26)
                        }
                        rowLabel(account.name, hint: account.limit)
                        Spacer()
                        Text(nickname ?? (account.loggedIn ? "已登录" : "未登录"))
                            .font(.liziBody(size: LiziTokens.size13))
                            .foregroundColor(account.loggedIn ? .green : LiziTokens.ink3)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(LiziTokens.ink3)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(account.loggedIn
                    ? "\(account.name)，已登录，查看账号详情"
                    : "\(account.name)，未登录，点此登录")
                Divider()
            }
            // r25 #45：网易每日签到入口（后端路由已有：
            // `Server/NetEase.swift` 的 `daily/signin`，weapi /point/dailyTask，
            // type 0 安卓 + type 1 网页各一次）。未登录网易时走现有登录 sheet
            // 去登录（本页已有的 loginTarget）；登录后点签到才调接口，
            // 结果如实显示在下面这行，不编点数、不编成功。
            HStack {
                rowLabel("每日签到", hint: "网易云音乐每日任务（安卓端 + 网页端各一次）")
                Spacer()
                if isSigningIn {
                    ProgressView()
                } else {
                    Button("签到") {
                        if !loginStore.isLoggedIn(platform: "netease") {
                            loginTarget = LoginSheetTarget(platform: "netease")
                        } else {
                            isSigningIn = true
                            Task {
                                dailySigninStatus = await settings.dailySignIn()
                                isSigningIn = false
                            }
                        }
                    }
                    .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                    .foregroundColor(LiziTokens.ink2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(LiziTokens.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .accessibilityLabel("网易云音乐每日签到")
            if !dailySigninStatus.isEmpty {
                Text(dailySigninStatus)
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink2)
            }
            Button(action: { showPlatformManager.toggle() }) {
                HStack {
                    rowLabel("平台管理", hint: "勾选要在大厅「我的」和顶部平台条里显示的平台；登录、播放不受影响")
                    Spacer()
                    Text(settings.visiblePlatformsSummary)
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink2)
                    Image(systemName: showPlatformManager ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(LiziTokens.ink3)
                }
            }
            .buttonStyle(.plain)
            if showPlatformManager {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(SettingsStore.platformIds, id: \.self) { id in
                        Button(action: {
                            if settings.visiblePlatforms.contains(id) {
                                if settings.visiblePlatforms.count > 1 {
                                    settings.visiblePlatforms.remove(id)
                                }
                            } else {
                                settings.visiblePlatforms.insert(id)
                            }
                        }) {
                            HStack {
                                Image(systemName: settings.visiblePlatforms.contains(id)
                                      ? "checkmark.square.fill" : "square")
                                    .foregroundColor(LiziTokens.ink2)
                                // r22j 平台管理：每行左边放该平台小 logo（26pt、
                                // 圆角 7，照抄壳版 `.pm__logo` 26×26 radius 7；
                                // 顺序与壳版 `#plat-list` 一致：checkbox → logo → 名字）。
                                if let info = LiziPlatforms.all.first(where: { $0.id == id }) {
                                    PlatformIconView(platform: info, selected: false, size: 26)
                                }
                                Text(SettingsStore.platformNames[id] ?? id)
                                    .font(.liziBody(size: LiziTokens.size14))
                                    .foregroundColor(LiziTokens.ink)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Text("至少保留一个；全部勾上就是全部显示。选择已保存，首页平台条实时跟着变（回首页即生效）。")
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink3)
                }
            }
        }
    }

    // MARK: - 2. 自定义源管理（LX）

    private var lxSection: some View {
        sectionCard(title: "自定义源管理",
                    note: "导入落雪音源脚本（LX Music 源），播放时按列表顺序依次尝试；拿不到时走平台接口。搜索与歌词仍走平台接口。") {
            toggleRow("自动切换音源",
                      hint: "开启后，当前音源播放失败时自动搜索并切换到其他可用音源播放；关闭时只试列表里第一个可用的音源，失败即走平台接口。",
                      isOn: Binding(
                        get: { settings.lxAutoSwitch },
                        set: { settings.setLXAutoSwitch($0) }))
            if settings.lxSources.isEmpty {
                Text("还没有导入自定义源。内置源已按用户要求全部删掉，只保留自定义源接口。")
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
            }
            ForEach(settings.lxSources, id: \.id) { source in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        rowLabel(source.name,
                                 hint: "\(source.author) · v\(source.version) · \(SettingsStore.lxPlatformsDisplay(source.platforms))")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { source.enabled },
                            set: { settings.setLXEnabled(id: source.id, enabled: $0) }))
                            .labelsHidden()
                    }
                    HStack(spacing: 12) {
                        if source.sourceUrl != nil {
                            Button("刷新") {
                                Task { await settings.refreshLXSource(id: source.id) }
                            }
                            .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                            Text("URL 导入")
                                .font(.liziBody(size: LiziTokens.size13))
                                .foregroundColor(LiziTokens.ink3)
                        } else {
                            Button(rebindId == source.id ? "取消绑定" : "绑定 URL") {
                                if rebindId == source.id {
                                    rebindId = nil
                                } else {
                                    rebindId = source.id
                                    rebindURLInput = ""
                                }
                            }
                            .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                            Text("本地导入")
                                .font(.liziBody(size: LiziTokens.size13))
                                .foregroundColor(LiziTokens.ink3)
                        }
                        Spacer()
                        if source.origin == "builtin" {
                            // 内置源不可删、只能关（registry.delete 也会拒绝）；
                            // 现在清单里没有内置源，这行是防御。
                            Text("内置源 · 只能关")
                                .font(.liziBody(size: LiziTokens.size13))
                                .foregroundColor(LiziTokens.ink3)
                        } else if source.origin == "sponsored" {
                            // 赞助版内置源同样可关不可删（registry.delete 也会拒绝）。
                            Text("赞助源 · 只能关")
                                .font(.liziBody(size: LiziTokens.size13))
                                .foregroundColor(LiziTokens.ink3)
                        } else {
                            Button("删除") {
                                settings.deleteLXSource(id: source.id)
                            }
                            .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                            .foregroundColor(.red)
                        }
                    }
                    if rebindId == source.id {
                        HStack(spacing: 8) {
                            TextField("粘贴该源的脚本 URL", text: $rebindURLInput)
                                .textFieldStyle(.roundedBorder)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            Button("确认") {
                                let url = rebindURLInput
                                let id = source.id
                                rebindId = nil
                                Task { await settings.bindLXSourceURL(id: id, urlString: url) }
                            }
                            .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                        }
                    }
                }
                Divider()
            }
            TextField("输入脚本 URL（支持 GitHub）", text: $lxURLInput)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.URL)
            HStack(spacing: 12) {
                Button("从 URL 导入") {
                    let url = lxURLInput
                    Task { await settings.importLXSourceFromURL(url) }
                }
                .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                Button("本地文件") { showLXFileImporter = true }
                    .font(.liziBody(size: LiziTokens.size14, weight: .medium))
            }
            if !settings.lxStatus.isEmpty {
                Text(settings.lxStatus)
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink2)
            }
            Text("GitHub/Gitee 链接会自动转为 raw 格式再拉取。URL 导入的源带 URL 标记，点刷新重新拉取更新；本地导入的源没有刷新按钮。")
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
        }
    }

    private func handleLXFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            // 多选逐个读、逐个导，不静默丢掉除第一个以外的文件。
            var files: [(name: String, content: String)] = []
            var readFailed: [String] = []
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else {
                    readFailed.append("\(url.lastPathComponent)：读不到选中的文件。")
                    continue
                }
                defer { url.stopAccessingSecurityScopedResource() }
                guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                    readFailed.append("\(url.lastPathComponent)：文件不是 UTF-8 文本。")
                    continue
                }
                files.append((name: url.lastPathComponent, content: content))
            }
            settings.importLXSourceFiles(files)
            if !readFailed.isEmpty {
                settings.lxStatus += " 读文件失败 \(readFailed.count) 个：\(readFailed.joined(separator: "；"))"
            }
        case .failure(let error):
            settings.lxStatus = "导入失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 3. 本地音乐

    private var localMusicSection: some View {
        sectionCard(title: "本地音乐",
                    note: "从文件 App 导入音频文件（mp3 / m4a / flac / wav / ogg），存在本机，不上传；大厅首页出现「本地音乐」推荐区，点一首就播。") {
            HStack {
                rowLabel("导入音频文件")
                Spacer()
                Text(settings.localMusicSummary)
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink2)
                // r25 #47：接首页同款导入器——系统文件选择器（UTType.audio，
                // 多选）→ `LocalMusic.importFiles`，与首页 LocalMusicSectionView
                // 的 `LocalMusicDocumentPicker` 同参数（UTType.audio / 多选 /
                // asCopy）。`LocalFilesBridge` 本身是 WKWebView 的
                // message handler（要 webView、回 JS 事件），设置页没有
                // WebView，接不过来；这里用 SwiftUI `.fileImporter`（同样是
                // 系统 UIDocumentPicker），后端与首页同一份 importFiles。
                Button("导入") { showLocalImporter = true }
                .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                .foregroundColor(LiziTokens.ink2)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(LiziTokens.paper)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let localImportStatus {
                Text(localImportStatus)
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink2)
            }
            toggleRow("在首页显示",
                      hint: "关闭后首页不再显示「本地音乐」区块；导入功能不受影响。",
                      isOn: $settings.localMusicShown)
        }
        .fileImporter(isPresented: $showLocalImporter,
                      allowedContentTypes: [UTType.audio],
                      allowsMultipleSelection: true) { result in
            handleLocalFileImport(result)
        }
    }

    /// r25 #47：导入结果处理（与首页 `LocalMusicView.importPicked` 同款：
    /// 后台线程拷文件 + 写清单，主线程刷新状态行；设 localImportStatus
    /// 会触发本页重绘，`localMusicSummary` 当场重读新数量）。
    private func handleLocalFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task.detached {
                let result = LocalMusic.importFiles(urls: urls)
                await MainActor.run {
                    localImportStatus = result.failed == 0
                        ? "已导入 \(result.imported.count) 首"
                        : "已导入 \(result.imported.count) 首，失败 \(result.failed) 个"
                }
            }
        case .failure(let error):
            localImportStatus = "导入失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 4. 音效

    private var audioSection: some View {
        sectionCard(title: "音效", note: "九档音质，显示的永远是实际返回的档位。均衡器细调 P4 上线。") {
            ForEach(AudioQuality.allCases, id: \.self) { quality in
                Button(action: { playback.setPreferredQuality(quality) }) {
                    HStack {
                        rowLabel(quality.displayName, hint: audioQualityBitrate(quality))
                        Spacer()
                        if playback.preferredQuality == quality {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(LiziTokens.ink2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Divider()
            Button(action: {
                notice = Notice(title: "音效 / 均衡器",
                                message: "均衡器细调（10 套预设 + 7 段 EQ）P4 上线，本轮只做 9 档音质选择。当前预设：平直（默认）。")
            }) {
                HStack {
                    rowLabel("音效 / 均衡器", hint: "10 套预设 + 7 段 EQ，P4 上线")
                    Spacer()
                    Text("\(playback.preferredQuality.displayName) · 平直")
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(LiziTokens.ink3)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// 壳版 `public/audio/eq-engine.js` QUALITIES 里的码率标注（DTS:X 除外，
    /// 它在壳版里就是 unsupported、无上游流，原生不提供这一档）。
    private func audioQualityBitrate(_ q: AudioQuality) -> String {
        switch q {
        case .standard: return "128 kbps"
        case .higher: return "192 kbps"
        case .exhigh: return "320 kbps"
        case .lossless: return "FLAC"
        case .hires: return "Hi-Res"
        case .surround: return "环绕声"
        case .dolby: return "Dolby Atmos"
        case .spatial: return "臻品全景声 3.0"
        case .master: return "臻品母带 4.0"
        }
    }

    // MARK: - 5. 播放页排版

    private var nowLayoutSection: some View {
        sectionCard(title: "播放页排版", note: "选一种立刻生效，只改播放页；不喜欢就点「默认」。") {
            ForEach(SettingsStore.nowLayouts, id: \.id) { layout in
                Button(action: { settings.nowLayout = layout.id }) {
                    HStack {
                        rowLabel(layout.name, hint: layout.desc)
                        Spacer()
                        if settings.nowLayout == layout.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(LiziTokens.ink2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Text("选择已保存（lizi.now.layout），进播放页即按版式重排（02/04/06 各改什么见播放页文件头对照表）。")
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
            toggleRow("LRCLIB 歌词兜底",
                      hint: "官方歌词优先；打开后官方没有歌词时才用 LRCLIB 歌词库兜底。",
                      isOn: $settings.lrclibEnabled)
        }
    }

    // MARK: - 5b. 形态歌词（r25 #31）

    /// 形态歌词三档（壳版 `#set-stage-lyric`，见 `SettingsStore`）：
    /// 原文 / 双文 / 译文；只改形态里显示的字，播放页歌词不动。
    /// 原生设置页没有单独的「形态」分区（壳版 `set-sec-stagelyric` 在
    /// 播放页排版区与外观区之间），这里单立一节、放在同样的位置。
    private var stageLyricSection: some View {
        sectionCard(title: "形态歌词", note: "只改形态（可视化）里显示的字；播放页歌词不动。没有译文的歌照旧显示原文。") {
            Picker("显示", selection: $settings.stageLyricMode) {
                ForEach(SettingsStore.stageLyricModes, id: \.id) { mode in
                    Text(mode.name).tag(mode.id)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("形态歌词显示")
            Text("有译文时才有区别 · 默认原文")
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
        }
    }

    // MARK: - 6. 外观

    private var appearanceSection: some View {
        sectionCard(title: "外观") {
            toggleRow("平台头像",
                      hint: "关闭时大厅的平台方块只显示平台图标，不显示账号头像。",
                      isOn: $settings.platformAvatar)
            toggleRow("用平台颜色铺色",
                      hint: "关闭时铺色态取当前专辑封面的颜色；打开后回到平台品牌色。",
                      isOn: $settings.platformColor)
            toggleRow("大厅内容轨",
                      hint: "开：精选/喜欢/收藏直接在跑马带里切换；关：恢复点击卡片跳浏览页的旧交互。",
                      isOn: $settings.hallRail)
            toggleRow("动画插图",
                      hint: "打开时锁屏专辑封面会动（本地生成，每首歌都有）；关闭后回到静态专辑图。仅 iOS 26+ 生效。",
                      isOn: $settings.animatedArtwork)
            Button(action: {
                notice = Notice(title: "主页背景",
                                message: "原生版暂不支持自定义主页背景（壳版用粘贴地址 / 选本地文件）。当前：默认渐变。")
            }) {
                HStack {
                    rowLabel("主页背景")
                    Spacer()
                    Text("默认渐变")
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(LiziTokens.ink3)
                }
            }
            .buttonStyle(.plain)
            Button(action: {
                settings.myAlbumsForm = settings.myAlbumsForm == "flow" ? "spine" : "flow"
            }) {
                HStack {
                    rowLabel("我的专辑展示", hint: "点一下在「侧立 3D」和「正面 Cover Flow」之间切换")
                    Spacer()
                    Text(settings.myAlbumsForm == "flow" ? "正面 Cover Flow" : "侧立 3D")
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(LiziTokens.ink3)
                }
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("推荐跑马带速度")
                        .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                        .foregroundColor(LiziTokens.ink)
                    Spacer()
                    Text(settings.marqueeSpeedLabel)
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink2)
                }
                Slider(value: $settings.marqueeSpeed, in: 0...100, step: 1)
            }
            Button(action: {
                notice = Notice(title: "大厅背景效果",
                                message: "原生大厅暂无背景动效，当前默认「流色」。壳版 6 种（流色/波浪线/等离子/渐变百叶/光束/抖色）待原生化。")
            }) {
                HStack {
                    rowLabel("大厅背景效果", hint: "铺色态海报背后那块动效，换一个立刻生效")
                    Spacer()
                    Text("流色（默认）")
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(LiziTokens.ink3)
                }
            }
            .buttonStyle(.plain)
            HStack {
                rowLabel("字体选择", hint: "待开放")
                Spacer()
                Text("Geist")
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink2)
            }
            HStack {
                rowLabel("快捷键", hint: "待开放")
                Spacer()
                Text("默认")
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink2)
            }
        }
    }

    // MARK: - 7. 关于

    private var aboutSection: some View {
        sectionCard(title: "关于") {
            HStack {
                rowLabel("关于 LIZI")
                Spacer()
                Text("LIZI 原生")
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink2)
            }
            HStack {
                rowLabel("版本")
                Spacer()
                Text(appVersion)
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink2)
            }
            HStack {
                rowLabel("构建")
                Spacer()
                Text(buildSummary)
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink2)
            }
            HStack {
                rowLabel("诊断日志")
                Spacer()
                Button("查看") {
                    diagnosticsText = settings.diagnosticsText()
                    showDiagnostics.toggle()
                }
                .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                Button("复制") {
                    UIPasteboard.general.string = settings.diagnosticsText()
                    notice = Notice(title: "诊断日志", message: "已复制到剪贴板。")
                }
                .font(.liziBody(size: LiziTokens.size13, weight: .medium))
            }
            if showDiagnostics {
                Text(diagnosticsText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(LiziTokens.ink2)
                    .lineLimit(40)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(LiziTokens.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Button(action: { openExternal("https://qm.qq.com/q/U6XytT33mC") }) {
                HStack {
                    rowLabel("QQ 群", hint: "LIZI用户体验群")
                    Spacer()
                    Text("724899514")
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(LiziTokens.ink3)
                }
            }
            .buttonStyle(.plain)
            Button(action: { openExternal("https://qr.alipay.com/fkx14272dybkfpkj6nmile0") }) {
                HStack {
                    rowLabel("赞助", hint: "支付宝")
                    Spacer()
                    Text("支持一下")
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(LiziTokens.ink3)
                }
            }
            .buttonStyle(.plain)
            Text("折射和形态渲染已固定为默认值；形态切换在播放页右侧抽屉里。")
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
    }

    /// 构建信息：短 commit + 构建号 + 日期。`LiziNativeBuildInfo` 是 CI
    /// 生成文件里的类型（见本文件头注释），这里真实引用它，不再是 P2 那样
    /// 无引用的死代码。
    private var buildSummary: String {
        "build #\(LiziNativeBuildInfo.build) · \(LiziNativeBuildInfo.shortCommit) · \(LiziNativeBuildInfo.date)"
    }
}
