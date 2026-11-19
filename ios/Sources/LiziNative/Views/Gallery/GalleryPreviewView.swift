import SwiftUI

/// 球面画廊的大预览（壳版 stage-pick 的 stage-pick-preview 层，原生版）。
///
/// 壳版行为对照：
/// - 点格子开大预览：一个 16:9 舞台（hero iframe，1280×800 虚拟视口 cover 裁切），
///   下面是编号 / 名字 / 描述 / 正在播放的歌。
/// - 「进入这个形态」进舞台；再点一次预览舞台本身也进入（第二次确认）——
///   原生侧 WebView 吃掉点按，容器上的 tap 手势收不到，所以只留按钮这条
///   可靠路径，不假装点舞台能进。
/// - 预览独占：大预览打开时球面格子的预览全部卸掉（省 CPU）——原生侧球面
///   本来就没有 live 预览，这一条自然满足。
/// - 预览的舞台承载一律复用 P3-A 的 `StageBridge` + `StageWebView`（不另造桥）：
///   同一个 init/tick/beat/live 协议、同一套 ready 兜底（2 秒没 ready 就直接
///   发 init）、同一个封面主色。预览用的桥是独立实例，进舞台后 StageView
///   再建自己的桥（壳版进舞台也是重新载 iframe，同款行为）。
/// - 没有舞台文件的形态不建桥、不给进入按钮，直接明示（发行版 69 个全有文件，
///   这一条只在「全部」版里出现）。
struct GalleryPreviewView: View {
    let form: StageForm
    let onClose: () -> Void
    let onEnter: () -> Void

    @EnvironmentObject private var playback: PlaybackStore
    @StateObject private var bridge: StageBridge

    init(form: StageForm, onClose: @escaping () -> Void, onEnter: @escaping () -> Void) {
        self.form = form
        self.onClose = onClose
        self.onEnter = onEnter
        _bridge = StateObject(wrappedValue: StageBridge(initialFormId: form.formId))
    }

    private var isAvailable: Bool {
        StageCatalog.isAvailable(form)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 0) {
                // 16:9 舞台（壳版 spv__stage）。
                ZStack {
                    Color(hex: 0x0B0C12)
                    if isAvailable {
                        StageWebView(bridge: bridge)
                            .onAppear { bridge.attach(store: playback) }
                            .onDisappear { bridge.detach() }
                        if !bridge.isReady {
                            ProgressView("预览加载中…")
                                .font(.liziBody(size: LiziTokens.size13))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    } else {
                        VStack(spacing: 8) {
                            Text(form.formId)
                                .font(.liziMono(size: LiziTokens.size20, weight: .semibold))
                                .foregroundColor(.white)
                            Text("该形态暂无舞台文件")
                                .font(.liziBody(size: LiziTokens.size14))
                                .foregroundColor(.white.opacity(0.7))
                            Text("壳版也没有提供这个文件，不是原生版漏拷。")
                                .font(.liziBody(size: LiziTokens.size12))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .cornerRadius(LiziTokens.radius14)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // 元数据（壳版 pickPreviewNum / Id / Name / Desc / Song）。
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(form.formId)
                            .font(.liziMono(size: LiziTokens.size14, weight: .semibold))
                            .foregroundColor(LiziTokens.accent)
                        Text(form.name)
                            .font(.liziDisplay(size: LiziTokens.size20))
                            .foregroundColor(.white)
                    }
                    Text(form.desc)
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(.white.opacity(0.7))
                    if let track = playback.currentTrack {
                        Text("正在播放：\(track.title) · \(track.artist)")
                            .font(.liziBody(size: LiziTokens.size13))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    } else {
                        Text("还没有歌曲，预览使用默认配色")
                            .font(.liziBody(size: LiziTokens.size13))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // 进入 / 返回（壳版 stage-pick-preview-enter / back）。
                HStack(spacing: 12) {
                    if isAvailable {
                        Button(action: onEnter) {
                            Text("进入这个形态")
                                .font(.liziBody(size: LiziTokens.size16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(LiziTokens.accent)
                                .cornerRadius(LiziTokens.radius14)
                        }
                    }
                    Button(action: onClose) {
                        Text("返回列表")
                            .font(.liziBody(size: LiziTokens.size16, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(LiziTokens.radius14)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                Spacer()
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }
}
