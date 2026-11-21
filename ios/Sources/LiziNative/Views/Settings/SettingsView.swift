import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 设置页（P3-C，屏幕 11）：对照壳版 `public/index.html` 的 `#view-settings`
/// 整页 + `app.js` 设置逻辑，r31-settings-organization 归档后 8 分区已落 +
/// 「音乐与音质」预留位 1 个（音质替换工在加，见 body 里预留注释）；
/// 每项都归进一个分区，无孤项、无重复项、无死入口（去重记录见下）。
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
/// 4. 音乐与音质（r31 音质系统替换，已落地）：播放来源三段
///    （自动/账号优先/第三方优先，只定优先顺序，不硬隔离）+
///    默认档 Picker（9 档全列，默认 exhigh，调
///    PlaybackStore.setPreferredQuality 写 settings.audioQuality，
///    当场影响取链档位）+ 音质降级时提示开关。
///    旧「音效」分区已删（r31-settings-organization 去重）：均衡器细调
///    （10 套预设 + 7 段 EQ）P4 未实现，旧入口行只弹提示，是死入口，
///    已删，不留。设置页与播放页的选档不是重复：本分区默认档 Picker
///    （9 档，改全局默认档，切歌不丢）与播放页底部音质芯片选择器
///    （9 档，单曲覆盖，切歌清掉）各管各的，都留着（r31 第三推：
///    音质替换工按批准设计重加默认档 Picker，旧「设置页 9 档选档已删」口径过期）。
///    壳版第 9 档 DTS:X 无上游流，原生不提供，不编。
/// 5. 播放页排版（r35-6 已删：只留默认，02/04/06 三套版式、设置页这一节、
///    `lizi.now.layout` 键全清；播放页永远只走默认两栏）。
///    LRCLIB 兜底开关原在这里，r31-settings-sections 挪进下面的「歌词显示」
///    分区（键与默认值不动）。
/// 5c. 歌词显示（r31-settings-sections，只归类现有设置，不新增歌词功能）：
///    LRCLIB 歌词兜底（原在播放页排版区，键 `lizi.lrclib.enabled`，默认开）
///    + 形态歌词三档（原 5b 独立分区，壳版 `#set-stage-lyric`，键
///    `lizi.stage.lyricMode`，默认原文）；只改歌词显示方式，播放页歌词
///    与形态显示的字都不新增、不改逻辑。
/// 5d. 显示与性能（r31-settings-sections）：120Hz 高刷新率开关（默认开，
///    键 `lizi.display.highRefreshRate`，控两处 CADisplayLink 的
///    preferredFrameRateRange 上限：开 120 / 关 60；plist 解锁是编译期，
///    运行时关不掉）+ 动画插图（原在外观区，键 `lizi.animatedArtwork`，
///    默认开，锁屏动态封面）。
/// 6. 外观（r31-settings-organization 去重后只剩真能用的两项：我的专辑展示
///    + 推荐跑马带速度，全真持久化；r31-imagebg 再加「背景」一项，
///    静态图片 / 动态壁纸真实现，见 appearanceSection）：
///    平台头像/平台颜色/大厅内容轨三开关已删——只写 UserDefaults，原生大厅
///    从不读这三把键（只剩壳版 public/app.js 在读，原生包不走那条路），
///    拨了没任何效果，是假开关；大厅消费对应键后再加回。
///    主页背景/大厅背景效果两行原是只弹「暂不支持」提示的死入口，
///    r31-imagebg 已真做出来（不是把死入口贴回去）：外观区「背景」行，
///    相册选图/选视频、落盘保存、重启保留、首页/大厅生效、可读性蒙版；
///    字体选择/快捷键两行已删——壳版「待开放」静态行，点按无反应。
///    开场引导壳版已隐藏（hidden），不复刻。
///    动画插图原在这里，r31-settings-sections 挪进上面的「显示与性能」分区。
/// 7. 关于：版本（Bundle）、构建（LiziNativeBuildInfo，CI 生成）、诊断日志
///    （查看/复制/清空，读/清 DiagLog）、QQ 群、赞助（支付宝收款码链接，均照抄壳版）、
///    免责声明（r36：点行进全文页，文案只在下面的 `liziDisclaimerText` 一处）。
///
/// r31-settings-organization 去重清单（删了哪个 → 留了哪个）：
/// - 设置页 9 档选档 → 留（改）：音质替换工在「音乐与音质」分区重加了
///   9 档默认档 Picker（调 PlaybackStore.setPreferredQuality，改全局默认档，
///   切歌不丢）；播放页底部音质芯片选择器也留（PlayerBottomDock.qualityPickerSheet，
///   单曲覆盖，切歌清掉）。两个选档各管各的，不是重复（r31 第三推，旧「删」口径过期）。
/// - 音效/均衡器入口行 → 删（P4 未实现，只弹提示）；无留件，均衡器没有。
/// - 平台头像/平台颜色/大厅内容轨三开关 → 删（原生无消费者）；无留件。
/// - 主页背景/大厅背景效果/字体选择/快捷键四行 → 删（只弹提示或静态行）；
///   无留件，这四项原生没有。（r31-imagebg 更正：主页背景/大厅背景效果
///   已真实现，见外观区「背景」；字体选择/快捷键仍没有。）
/// 查过不是重复、留下的：本地音乐导入（首页与设置页各一个入口，同调
/// LocalMusic.importFiles，同一实现、不同页面的入口，不算重复项）；
/// 形态歌词三档、LRCLIB、动画插图、120Hz、每日签到/自动签到，
/// 全仓各只有一个设置入口。播放页音质芯片只剩底部一处（r29 已删歌名下角标）。
///
/// 没有（做不了/没接口，老实写清）：均衡器细调；
/// 字体选择；快捷键；平台头像/平台颜色/大厅内容轨
/// （原生大厅未消费对应键）。以上均不在设置页摆入口。
/// （r31-imagebg：主页背景自定义 / 大厅背景效果已实现，不再列在这里，
/// 见外观区「背景」。）
///
/// 注意：`LiziNativeBuildInfo` 由构建工作流 `ipa-native` job 的
/// 「Write native build info」一步在构建机上生成
/// `ios/Sources/LiziNative/BuildInfo.generated.swift`（不进 git）；本地
/// 磁盘上没有这个文件是正常的，代码直接引用该类型即可，CI 生成后才编译。
/// P2 报告说它因无 UI 引用被 strip 掉——本页真实引用它（短 commit + build
/// 号 + 日期），让它进包。
/// r36 免责声明（用户 2026-11-21 22:26 定）：文案全文只放这一处常量，
/// 关于页入口行与全文页都读它——用户改措辞只改这一行，不许散在多处。
/// 标题「免责声明」是页标题，不在正文里；正文逐字如下。
private let liziDisclaimerText = "本软件仅供个人学习交流使用。软件内的音乐、歌词、封面等内容版权归原平台及版权方所有。本软件不提供、不存储任何音乐内容，所有播放均来自用户已授权的平台账号或用户自行添加的音源。使用本软件即表示您已阅读并同意本声明。"
struct SettingsView: View {
    @StateObject private var settings = SettingsStore.shared
    /// r31-mquality 残留补（构建工 r31 修）：musicQualitySection 的默认音质
    /// Picker setter 调 playback.setPreferredQuality，但本文件没声明 playback，
    /// 编译不过（下载工报的 SettingsView:583 行引用）。App 根部经
    /// .environmentObject 下发 PlaybackStore（LiziNativeApp，与
    /// PlatformStripView 同款），这里直接取环境对象；不改调 SettingsStore
    /// 写口，因为 setPreferredQuality 还负责写盘 + 推 shared 刷新。
    @EnvironmentObject private var playback: PlaybackStore
    /// r36-12 听歌排行：设置页入口直接走导航（`nav.show(.listeningRank)`），
    /// 与 AccountDetailView 快捷入口同一路由；RootView 已下发 AppNavigation。
    @EnvironmentObject private var nav: AppNavigation
    /// r23f：登录底座（r23a，`Views/Login/`）——设置页只消费它的接口
    /// （约定见 `LoginSheetTarget.swift` 文件头）；登录/登出成功后它发布
    /// 变化，账号行随之重绘。未落地前本引用编译不过（见 r23f 驱动 GAP）。
    @ObservedObject private var loginStore = LoginStore.shared
    /// r31-download：下载管理行读下载清单（数量/大小当场刷新）。
    @ObservedObject private var downloads = DownloadStore.shared

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
    /// r31 日志清空：展开日志区底部「清空日志」的二次确认弹窗开关。
    @State private var showClearDiagnosticsConfirm = false
    /// r25 #47：本地导入文件选择器 + 导入结果行（导入后数量显示当场刷新）。
    @State private var showLocalImporter = false
    @State private var localImportStatus: String? = nil
    /// r25 #45：网易每日签到结果行 + 进行中态。
    @State private var dailySigninStatus = ""
    @State private var isSigningIn = false
    /// r31-imagebg：背景（外观区）——系统 PhotosPicker 选图/选视频
    /// （matching: .images / .videos），读到后交 BackgroundStore 落盘；
    /// backgroundStatus 是选图/选视频结果行（不用 Notice，见文件头
    /// r31-settings-organization §5a：Notice 只留诊断日志的回执）。
    @ObservedObject private var background = BackgroundStore.shared
    @State private var showImagePicker = false
    @State private var showVideoPicker = false
    @State private var imagePickerItem: PhotosPickerItem?
    @State private var videoPickerItem: PhotosPickerItem?
    @State private var backgroundStatus: String? = nil
    /// r31-download：下载管理页 sheet 开关。
    @State private var showDownloads = false
    /// r36 免责声明：关于页「免责声明」行点开全文页的开关。
    @State private var showDisclaimer = false
    /// v3 稿图（r36 第⑨⑩⑪件，2026-11-21 22:07 定稿）：设置页标签分组
    ///（平台账号 / 自定义源管理 / 本地音乐 / 音效），点标签切分组并回顶部。
    @State private var selectedSettingsTab: SettingsTab = .accounts
    /// 标签栏是否已吸顶（头自身 minY ≤ 1 时吸顶，见 settingsTabHeader）：
    /// 吸顶时头里只剩 LI 标记居中，LIZI + kun 已随大标题滑走。
    @State private var settingsTabPinned = false

    /// 设置页标签（v3 稿图）：4 项，与现有分节平级。
    private enum SettingsTab: String, CaseIterable {
        case accounts, lx, local, sound
        var title: String {
            switch self {
            case .accounts: return "平台账号"
            case .lx: return "自定义源管理"
            case .local: return "本地音乐"
            case .sound: return "音效"
            }
        }
    }

    /// 标签栏吸顶头自身位置（在 settingsScroll 坐标系的 minY）：
    /// 吸顶时 minY ≈ 0，未吸顶时是它在流内的位置（大标题下面，> 0）。
    private struct SettingsTabHeaderOffsetKey: PreferenceKey {
        static var defaultValue: CGFloat = .infinity
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    // v3 稿图（r36 第⑨⑩⑪件，2026-11-21 22:07 定稿）：
                    // 顶部品牌锁扣（LI + LIZI + kun 紧挨着一排，居中）+
                    // 大标题「设置」+ 副标题，全部随内容滑走；下滑后顶部
                    // 只剩 LI 标记（见 settingsTabHeader 的吸顶头）。
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Spacer()
                            BrandLockupView()
                            Spacer()
                        }
                        .padding(.top, 8)
                        Text("设置")
                            .font(.liziDisplay(size: 28))
                            .foregroundColor(LiziTokens.ink)
                        Text("账号、音源、音效与外观。")
                            .font(.liziBody(size: LiziTokens.size13))
                            .foregroundColor(LiziTokens.ink3)
                    }
                    .padding(.horizontal, 16)
                    .id("settingsTop")
                    Section(header: settingsTabHeader(proxy: proxy)) {
                        VStack(alignment: .leading, spacing: 16) {
                            switch selectedSettingsTab {
                            case .accounts:
                                accountSection
                                rankSection
                            case .lx:
                                lxSection
                            case .local:
                                localMusicSection
                                storageDownloadSection
                            case .sound:
                                musicQualitySection
                                lyricsSection
                                displayPerformanceSection
                                appearanceSection
                                aboutSection
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 32)
            }
            .coordinateSpace(name: "settingsScroll")
            .onPreferenceChange(SettingsTabHeaderOffsetKey.self) { minY in
                settingsTabPinned = minY <= 1
            }
            .background(LiziTokens.paper)
        .onAppear {
            settings.refreshLXSources()
            // r31-signin：进设置页时重读最近一次签到结果（自动签可能
            // 在后台跑完，本页 @State 还是旧的；重启后也由此恢复显示）。
            // 手动签到进行中时不动，等它自己落结果。
            if !isSigningIn {
                settings.refreshSigninStatus()
                dailySigninStatus = settings.lastSigninStatus
            }
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
        .sheet(isPresented: $showDownloads) {
            DownloadsView()
        }
        .sheet(isPresented: $showDisclaimer) {
            DisclaimerView()
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
        // r31-imagebg：背景选图/选视频（系统 PhotosPicker，不自己写相册）。
        .photosPicker(isPresented: $showImagePicker, selection: $imagePickerItem, matching: .images)
        .photosPicker(isPresented: $showVideoPicker, selection: $videoPickerItem, matching: .videos)
        .onChange(of: imagePickerItem) { item in
            Task { @MainActor in
                await handleImagePick(item)
                imagePickerItem = nil
            }
        }
        .onChange(of: videoPickerItem) { item in
            Task { @MainActor in
                await handleVideoPick(item)
                videoPickerItem = nil
            }
        }
        // r31-imagebg：模式先切、文件后选——切到图片/视频但还没文件时
        // 弹对应的选图器；取消就停在「未选图/未选视频」，首页显示默认背景。
        .onChange(of: background.mode) { newMode in
            if newMode == .image && background.backgroundImage == nil { showImagePicker = true }
            if newMode == .video && !background.hasVideoFile { showVideoPicker = true }
        }
        } // ScrollViewReader（标签切分组时回顶部用 proxy）
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
                        // v2 稿图（r36 第⑨⑩⑪件，2026-11-21 22:00 定稿）：
                        // 右半边同一行：头像 → 用户名（绿字）→ VIP 标识 → 「>」；
                        // 左边平台真 Logo + 平台名 + 副标题不变。整行点按进详情/
                        // 登录页（行为不动）；VIP 牌与用户名同一行、在用户名右边。
                        HStack(spacing: 6) {
                            accountAvatarView(platform: account.id)
                            Text(nickname ?? (account.loggedIn ? "已登录" : "未登录"))
                                .font(.liziBody(size: LiziTokens.size13))
                                .foregroundColor(.green)
                                .lineLimit(1)
                            vipBadgeView(platform: account.id)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(LiziTokens.ink3)
                        }
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
            // r31-signin：每日自动签到开关（默认关——现有签到是手动的，
            // 见 SettingsStore 网易每日签到区注释）。开 = 每天自动签到
            // 一次，今天已签过（手动/自动任一）就跳过，不重复签；
            // 关 = 不自动签。7 个平台里只有网易有可用签到接口，
            // 其它平台没有，不编。
            toggleRow("每日自动签到", hint: "打开后每天自动签到一次（仅网易云音乐有签到接口）；今天已签过就不再重复签", isOn: $settings.autoDailySignIn)
                .accessibilityLabel("每日自动签到")
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

    /// v2 稿图（r36 第⑨件）：平台账号行右侧头像。有头像 URL 显示真头像
    ///（CoverImageView，第⑥件链路：代理 → 直链 → 深色占位，3 次重试，不许白框）；
    /// 没头像 / 未登录显示可见人形占位（person.circle.fill，ink3），不留白。
    /// Apple Music 没有头像来源——登录后也只能显示人形占位，老实说明。
    private func accountAvatarView(platform: String) -> some View {
        Group {
            if let url = loginStore.avatarURL(platform: platform) {
                CoverImageView(url: url, placeholderIconSize: 12)
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(LiziTokens.ink3)
                    .frame(width: 24, height: 24)
            }
        }
    }

    /// v2 稿图（r36 第⑩件）：VIP 标识，紧跟用户名右边、同一行。
    /// 复用 `loginStore.vipLabel(platform:)`（r31 会员校验，不另起一套）；
    /// SVIP 橙实心、VIP 红实心、其余（已知非会员 / 会员态未知 / 未登录）
    /// 一律灰描边「普通用户」——按 22:00 批的 v2 稿图三态；SVIP 绝不降级成 VIP。
    /// 注意：酷我 / Apple Music / 汽水 / 波点没有会员校验接口，列表牌按稿图
    /// 显示「普通用户」；详情页（AccountDetailView）仍保留诚实的「未知」+ 脚注。
    private func vipBadgeView(platform: String) -> some View {
        let label = loginStore.vipLabel(platform: platform)
        let badge: (text: String, fill: Color?, fg: Color, bold: Bool) = {
            switch label {
            case "SVIP": return ("SVIP", Color(hex: 0xFF8C00), .white, true)
            case "VIP": return ("VIP", Color(hex: 0xE60026), .white, true)
            default: return ("普通用户", nil, LiziTokens.ink3, false)
            }
        }()
        return Text(badge.text)
            .font(.system(size: 10, weight: badge.bold ? .bold : .regular))
            .foregroundColor(badge.fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Group {
                    if let fill = badge.fill {
                        RoundedRectangle(cornerRadius: 7).fill(fill)
                    } else {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(hex: 0xB4B4B4), lineWidth: 1)
                    }
                }
            )
    }

    /// 听歌排行独立模块（r36-12，用户 2026-11-21 22:02「听歌排行在设置里面
    /// 做一个单独的模块」）：与「平台账号」「自定义源管理」平级的独立一节，
    /// 同款 sectionCard 样式；点行进排行页。
    /// 复用 r31 的 `ListeningRankView` + `PlayRecord`（网易 weapi
    /// `/v1/play/record` 服务端排行，周/总榜切换），不重建、不另拉接口；
    /// 入口固定传网易（其余 6 台没有等价服务端接口，副标题写清仅网易）。
    private var rankSection: some View {
        sectionCard(title: "听歌排行", note: "网易云音乐服务端听歌记录排行（最近一周 / 所有时间）。") {
            Button(action: { nav.show(.listeningRank(platform: "netease")) }) {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(LiziTokens.accent)
                    rowLabel("听歌排行", hint: "最近一周 / 所有时间 · 仅网易云音乐有服务端记录")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(LiziTokens.ink3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("听歌排行，查看网易云音乐听歌排行")
        }
    }

    /// 吸顶头（v3 稿图，r36 第⑨⑩⑪件）：标签栏 + 下滑后只剩的 LI 标记。
    /// - 未吸顶（在顶部）：头在流内、大标题下面，只显示标签栏；LI 收起
    ///   （高 0，不留空隙），品牌锁扣在上面正常显示。
    /// - 已吸顶（头顶到 ScrollView 顶，minY ≤ 1）：LI 展开居中置顶，
    ///   标签栏贴在 LI 下面；LIZI + kun 已随大标题滑走（它们只在
    ///   BrandLockupView 里，不在这里）。
    /// 吸顶状态由头自身位置判定（GeometryReader 量它在 settingsScroll
    /// 坐标系的 minY）：吸顶时 minY ≈ 0；在流内时 minY 是它离内容顶的
    /// 距离（> 0）。头自身高度不影响自己的 minY（顶边），无反馈环。
    private func settingsTabHeader(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            BrandMarkView()
                .frame(height: settingsTabPinned ? 11.7 : 0)
                .opacity(settingsTabPinned ? 1 : 0)
                .padding(.bottom, settingsTabPinned ? 8 : 0)
                .animation(.easeInOut(duration: 0.2), value: settingsTabPinned)
            settingsTabBar(proxy: proxy)
        }
        .background(
            GeometryReader { g in
                Color.clear.preference(
                    key: SettingsTabHeaderOffsetKey.self,
                    value: g.frame(in: .named("settingsScroll")).minY
                )
            }
        )
        .background(LiziTokens.paper)
    }

    /// 标签栏（v3 稿图）：4 项一排；选中黑底白字 pill，未选中墨字；
    /// 点标签切分组并回顶部（新分组内容从顶开始看）。
    private func settingsTabBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 16) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button(action: { selectSettingsTab(tab, proxy: proxy) }) {
                    Text(tab.title)
                        .font(.liziBody(size: LiziTokens.size13,
                                        weight: selectedSettingsTab == tab ? .bold : .regular))
                        .foregroundColor(selectedSettingsTab == tab ? .white : LiziTokens.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Group {
                                if selectedSettingsTab == tab {
                                    RoundedRectangle(cornerRadius: 13.5).fill(LiziTokens.ink)
                                } else {
                                    Color.clear
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置分组：\(tab.title)")
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func selectSettingsTab(_ tab: SettingsTab, proxy: ScrollViewProxy) {
        selectedSettingsTab = tab
        withAnimation {
            proxy.scrollTo("settingsTop", anchor: .top)
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

    // MARK: - r31-imagebg：背景选图/选视频处理

    /// 相册选图（PhotosPicker，matching: .images）：读到 Data 交
    /// BackgroundStore.saveImageData 落盘（最长边 1920、JPEG 0.85，
    /// 只存沙盒文件）；解不开/写盘失败都写明原因，不静默、不弹 Notice。
    private func handleImagePick(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                backgroundStatus = "选图失败：读不到这张图片。"
                return
            }
            backgroundStatus = background.saveImageData(data)
                ? "背景图片已设置（已存到本机，重启还在）。"
                : "选图失败：这张图片打不开，换一张试试。"
        } catch {
            backgroundStatus = "选图失败：\(error.localizedDescription)"
        }
    }

    /// 相册选视频（PhotosPicker，matching: .videos）：`PickedVideoFile`
    /// （FileRepresentation）拿到的临时文件原样交 BackgroundStore.saveVideoFile
    /// 拷进沙盒（不转码，不整段读进内存）；拷失败写明原因，不静默、不弹 Notice。
    /// r31 第三推构建修：run 44844080035 报 `PhotosPickerItem` 没有
    /// `loadFileRepresentation`，run 44846007485 报也没有 `itemProvider`——
    /// 该类型只暴露 `loadTransferable(type:)`，所以用 FileRepresentation
    /// 的 Transferable 包装只取临时文件 URL。
    private func handleVideoPick(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let picked = try await item.loadTransferable(type: PickedVideoFile.self) else {
                backgroundStatus = "选视频失败：读不到这个视频。"
                return
            }
            backgroundStatus = background.saveVideoFile(from: picked.url)
                ? "动态壁纸已设置（视频已存到本机，静音循环播放，重启还在）。"
                : "选视频失败：存不下这个视频，换一个小一点的试试。"
        } catch {
            backgroundStatus = "选视频失败：\(error.localizedDescription)"
        }
    }

/// PhotosPicker 选视频的 Transferable 包装：只取临时文件 URL，不整段读进内存。
/// exporting 闭包是 FileRepresentation 的必填项（本处只走 importing 方向）。
private struct PickedVideoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { picked in
            SentTransferredFile(picked.url)
        } importing: { received in
            PickedVideoFile(url: received.file)
        }
    }
}

    // MARK: - 4. 音乐与音质（r31 音质系统替换，已落地）

    /// 播放来源三段 + 默认音质 Picker + 降级提示开关。
    /// - 播放来源：三段只定腿的优先顺序（自动 = LX 优先、账号兜底；
    ///   账号优先 = 账号腿先；第三方优先 = LX 腿先），不硬隔离——
    ///   任一段拿不到时另一段都可兜底（R7 已删）。
    /// - 默认音质：全局默认档（默认 exhigh），9 档全列，不探测、
    ///   不设限（R3 已删）；改完下次点播即生效，不改当前这首歌
    ///   的单曲覆盖（播放页选档才是单曲覆盖，切歌清掉）。
    /// - 降级提示：实际档位低于请求档时，提示文案进播放页音质
    ///   选择器；关掉只记日志，不提示。
    /// 显示的永远是实际返回的档位（芯片/首页卡片读
    /// PlaybackStore.servedQualityText），不是这里选的请求档。
    private var musicQualitySection: some View {
        sectionCard(title: "音乐与音质", note: "默认音质是没选单曲覆盖时的取链档位；显示的永远是实际返回的档位。") {
            Picker("播放来源", selection: $settings.playbackSourceMode) {
                ForEach(PlaybackSourceMode.allCases, id: \.self) { mode in
                    Text(mode.shortDisplayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(settings.playbackSourceMode.explanation)
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
            Picker("默认音质", selection: Binding(
                get: { settings.audioQuality },
                set: { quality in playback.setPreferredQuality(quality) }
            )) {
                ForEach(AudioQuality.allCases, id: \.self) { quality in
                    Text("\(quality.displayName) · \(audioQualityBitrate(quality))").tag(quality)
                }
            }
            .pickerStyle(.menu)
            toggleRow("音质降级时提示",
                      hint: "实际档位低于所选档位时，在音质选择器里提示已按实际档位播放；关闭后只记日志，不提示。",
                      isOn: $settings.qualityDowngradeNotice)
        }
    }

    /// 9 档的技术标注（选择器里的补充说明；Moumusic sourceDisplayName
    /// 的 Lizi 版：档位名 + 英文/码率，不宣称音源没给过的档位）。
    private func audioQualityBitrate(_ q: AudioQuality) -> String {
        switch q {
        case .standard: return "128 kbps"
        case .higher: return "192 kbps"
        case .exhigh: return "320 kbps"
        case .lossless: return "无损 FLAC"
        case .hires: return "Hi-Res / FLAC 24-bit"
        case .atmos: return "高清环绕声 / Spatial"
        case .dolby: return "杜比全景声 / Dolby Atmos"
        case .surround: return "沉浸环绕声 / Surround"
        case .master: return "超清母带 / Master"
        }
    }

    // MARK: - 3b. 存储与下载（r31-download）

    /// 存储与下载分区（Moumusic 设置「存储与下载」分区同款入口）：
    /// 「下载管理」行进 DownloadsView（正在下载进度 / 已下载点播 / 左滑删除）；
    /// 摘要实读下载清单（已下载 N 首 · X MB），下载不设会员/登录门，
    /// 返回什么音质就下什么、显示实际下载音质。
    /// 位置在本地音乐之后；不占「音乐与音质」的位置
    ///（那个分区是音质替换工的 musicQualitySection，不抢）。
    private var storageDownloadSection: some View {
        sectionCard(title: "存储与下载",
                    note: "下载的歌曲存在本机，不上传；播放时优先播本地文件。") {
            Button(action: { showDownloads = true }) {
                HStack {
                    rowLabel("下载管理", hint: downloads.summaryText)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(LiziTokens.ink2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下载管理 \(downloads.summaryText)")
        }
    }


    // MARK: - 5c. 歌词显示（r31-settings-sections）
    //
    // 只归类现有歌词显示设置，不新增歌词功能：
    // - LRCLIB 歌词兜底：原在播放页排版区（该区 r35-6 已删），逐字挪过来（键
    //   `lizi.lrclib.enabled`、默认开、hint 文案都不动）；
    // - 形态歌词三档：原 5b 独立分区（r25 #31），整节并进来
    //   （Picker 与说明文案都不动，只改形态里显示的字）。
    // 位置 = 原 5b 形态歌词的位置（外观区之前），
    // 其他分区顺序不动。
    private var lyricsSection: some View {
        sectionCard(title: "歌词显示", note: "只改歌词显示方式；官方歌词优先，没有歌词时不编歌词。") {
            toggleRow("LRCLIB 歌词兜底",
                      hint: "官方歌词优先；打开后官方没有歌词时才用 LRCLIB 歌词库兜底。",
                      isOn: $settings.lrclibEnabled)
            // 形态歌词三档（壳版 `#set-stage-lyric`，见 `SettingsStore`）：
            // 原文 / 双文 / 译文；只改形态里显示的字，播放页歌词不动。
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

    // MARK: - 5d. 显示与性能（r31-settings-sections）
    //
    // 120Hz 高刷新率开关 + 动画插图（原在外观区，逐字挪过来，键
    // `lizi.animatedArtwork`、默认开、hint 文案都不动）。
    // 位置 = 外观区之前（歌词显示之后），其他分区顺序不动。
    // 120Hz 开关控运行时帧率：开 = 两处 CADisplayLink 上限 120，
    // 关 = 上限 60（SettingsStore.frameRateRange()）；plist 的
    // CADisableMinimumFrameDurationOnPhone 是编译期解锁，运行时关不掉，
    // 开关能控的就是这两处 link；默认开 = 120Hz 工既有行为不变。
    private var displayPerformanceSection: some View {
        sectionCard(title: "显示与性能", note: "高刷只在 ProMotion 机型上生效，60Hz 机型不受影响；动画插图关掉后锁屏回静态专辑图。") {
            toggleRow("120Hz 高刷新率",
                      hint: "打开时跑马带与动画按 120Hz 刷新（仅 ProMotion 机型生效）；关闭后限速 60Hz，更省电。",
                      isOn: $settings.highRefreshRate)
                .accessibilityLabel("120Hz 高刷新率")
            toggleRow("动画插图",
                      hint: "打开时锁屏专辑封面会动（本地生成，每首歌都有）；关闭后回到静态专辑图。仅 iOS 26+ 生效。",
                      isOn: $settings.animatedArtwork)
        }
    }

    // MARK: - 6. 外观

    private var appearanceSection: some View {
        sectionCard(title: "外观", note: "只留真能用的三项。") {
            // r31-settings-organization：平台头像/平台颜色/大厅内容轨
            // 三开关已删（只写键、原生大厅从不读，拨了无效，见文件头）；
            // 动画插图 r31-settings-sections 已挪进「显示与性能」分区。
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
            // r31-imagebg：背景（首页 / 大厅背景真实现；对照表 #18 / #20）：
            // 模式三段（默认 / 静态图片 / 动态壁纸）+ 两个选图按钮 +
            // 恢复默认；选图/选视频走系统 PhotosPicker（见 body 末尾
            // .photosPicker），读到后交 BackgroundStore 落盘保存；
            // 状态行只写结果，不弹 Notice（Notice 只留诊断日志回执）。
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    rowLabel("背景", hint: "首页 / 大厅的底色背景；不设就用默认背景")
                    Spacer()
                    Text(background.statusText)
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink2)
                }
                Picker("背景", selection: $background.mode) {
                    Text("默认").tag(BackgroundStore.Mode.none)
                    Text("静态图片").tag(BackgroundStore.Mode.image)
                    Text("动态壁纸").tag(BackgroundStore.Mode.video)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("背景")
                if background.mode == .image, let image = background.backgroundImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("当前背景图片预览")
                }
                if background.mode == .video, background.hasVideoFile {
                    HStack(spacing: 6) {
                        Image(systemName: "film")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(LiziTokens.ink2)
                        Text("视频已设置\(background.fileSizeText.map { " · \($0)" } ?? "")")
                            .font(.liziBody(size: LiziTokens.size13))
                            .foregroundColor(LiziTokens.ink2)
                    }
                }
                HStack(spacing: 12) {
                    Button("选图片") { showImagePicker = true }
                        .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                        .foregroundColor(LiziTokens.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(LiziTokens.paper)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("从相册选一张图片做背景")
                    Button("选动态壁纸") { showVideoPicker = true }
                        .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                        .foregroundColor(LiziTokens.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(LiziTokens.paper)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("从相册选一段视频做动态壁纸")
                    Spacer()
                    if background.hasCustomBackground {
                        Button("恢复默认", role: .destructive) { background.clearBackground() }
                            .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                            .accessibilityLabel("恢复默认背景")
                    }
                }
                if let backgroundStatus {
                    Text(backgroundStatus)
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink2)
                }
                Text("图片 / 视频存在本机沙盒里，相册原图删了背景还在；背景上有一层浅色蒙版，深色字一直可读；视频背景静音循环播放，切后台暂停。")
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
            }
            // r31-settings-organization：大厅背景效果/字体选择/快捷键
            // 三行已删（前者只弹「暂无」提示，后两者是「待开放」静态行，
            // 点按无反应，见文件头）；r31-imagebg 更正：大厅背景效果
            // 已真实现（上面「背景」行），字体选择/快捷键仍没有，不摆入口。
        }
    }

    // MARK: - 7. 关于

    private var aboutSection: some View {
        sectionCard(title: "关于") {
            HStack {
                rowLabel("关于 LIZI")
                Spacer()
                // r31：关于行也用代码打上去的品牌三件套（BrandLockupView，
                // LI 标记 + LIZI + kun，与顶栏同一份），不再是纯文字
                // 「LIZI kun」——原来这里根本没有 LI 标记。
                BrandLockupView()
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
                // r31 日志清空：按钮只放在「查看」展开后的日志区最底部，
                // 不放在「诊断日志」主行（查看/复制那一行）——平时滑设置页
                // 碰不到它；点一下先弹二次确认（同款见队列「清空队列」、
                // 账号详情「退出登录」），确认才真清，清完弹 Notice
                // 「日志已清空。」并当场把展开的文本刷成空 JSON。
                HStack {
                    Spacer()
                    Button {
                        showClearDiagnosticsConfirm = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .medium))
                            Text("清空日志")
                                .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                        }
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .accessibilityLabel("清空诊断日志")
                }
                .alert("清空日志", isPresented: $showClearDiagnosticsConfirm) {
                    Button("清空", role: .destructive) {
                        diagnosticsText = settings.clearDiagnostics()
                        notice = Notice(title: "诊断日志", message: "日志已清空。")
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将清空当前全部诊断日志（最近请求、事件、日志、播放面包屑），清空后无法恢复。")
                }
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
            // r36 免责声明：关于页入口行（QQ 群/赞助同款 Button + chevron 行），
            // 点开 sheet 全文页；文案只在文件顶 `liziDisclaimerText` 一处。
            Button(action: { showDisclaimer = true }) {
                HStack {
                    rowLabel("免责声明")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(LiziTokens.ink3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("免责声明")
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

/// r36 免责声明全文页：设置 → 关于 → 「免责声明」行点开的 sheet。
/// 正文只读文件顶的 `liziDisclaimerText` 一处常量，不另写一份。
private struct DisclaimerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(liziDisclaimerText)
                    .font(.liziBody(size: LiziTokens.size14))
                    .foregroundColor(LiziTokens.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(LiziTokens.paper)
            .navigationTitle("免责声明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
