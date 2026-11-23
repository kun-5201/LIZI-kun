import AVFoundation
import SwiftUI
import UIKit

/// 首页 / 大厅背景层（r31-imagebg，用户 2026-11-21 07:15）。
///
/// 挂在 HomeView 最外层 GeometryReader 的 `.background` 里——在全部内容
/// 之下，只做底色，永远不盖内容（本层 `allowsHitTesting(false)`，
/// 上面 Hero/面板/本地音乐/顶栏照常点按；滚动区底色已改透明）。
///
/// 三态（`BackgroundStore.mode`，`@ObservedObject` 跟着变，当场重绘）：
/// - 默认：底层就是原来的纸色 `LiziTokens.paper`，与 r30 视觉一致。
/// - 静态图片：沙盒图 `scaledToFill` 铺满裁切 + 3pt 轻模糊（只柔化
///   细节，不糊成色块）+ 可读性蒙版。
/// - 动态壁纸：`LoopingVideoBackgroundView`（AVPlayer 静音循环，
///   `resizeAspectFill` 铺满裁切）+ 同一款可读性蒙版。
///
/// 可读性蒙版（为什么是浅色、不是深色压暗——全站文字是深色墨字、
/// 底色是浅色纸面：深色压暗会反让顶栏品牌/齿轮/搜索这些深色字看不清。
/// 浅色蒙版做法：纵向白渐变（上下 0.55、中间 0.25）盖在图/视频之上、
/// 内容之下；图还看得见（约一半透出来），深色字对比度与原来纸面
/// 接近。Hero 与面板本身是不透明卡片，不受蒙版影响。）
struct HomeBackgroundView: View {
    @ObservedObject private var background = BackgroundStore.shared

    var body: some View {
        ZStack {
            LiziTokens.paper
            if background.mode == .image, let image = background.backgroundImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 3)
            } else if background.mode == .video, let url = background.videoFileURL {
                LoopingVideoBackgroundView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            if background.hasCustomBackground {
                LinearGradient(
                    colors: [Color.white.opacity(0.55),
                             Color.white.opacity(0.25),
                             Color.white.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// 循环播放的视频背景（动态壁纸的播放层）。
///
/// - 静音（`isMuted = true`），不抢音频焦点、不盖住正在播的歌；
/// - 播完回 0 继续播（`AVPlayerItemDidPlayToEndTime` → `seek(to: .zero)`
///   + `play()`，`actionAtItemEnd = .none` 保证播完不停在尾帧）；
/// - 画面 `resizeAspectFill` 铺满裁切，不留黑边；
/// - 切后台暂停、回前台继续播（背景视频不抢后台音频、不空转耗电）；
/// - 只做背景：`isUserInteractionEnabled = false`，不接任何手势。
struct LoopingVideoBackgroundView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LoopingVideoView {
        let view = LoopingVideoView()
        view.configure(url: url)
        return view
    }

    func updateUIView(_ uiView: LoopingVideoView, context: Context) {
        if uiView.currentURL != url { uiView.configure(url: url) }
    }

    static func dismantleUIView(_ uiView: LoopingVideoView, context: Context) {
        uiView.teardown()
    }
}

/// AVPlayerLayer 直挂的 UIView（layerClass 就是 AVPlayerLayer，不另包一层）。
final class LoopingVideoView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private(set) var currentURL: URL?

    func configure(url: URL) {
        teardown()
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .none
        guard let layer = self.layer as? AVPlayerLayer else { return }
        layer.player = player
        layer.videoGravity = .resizeAspectFill
        currentURL = url
        self.player = player
        // 播完回 0 继续播。
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.player?.seek(to: .zero)
            self?.player?.play()
        }
        // 切后台暂停、回前台继续播。
        resignObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.player?.pause() }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.player?.play() }
        isUserInteractionEnabled = false
        player.play()
    }

    /// 停播 + 解绑全部观察者 + 与 layer 脱钩（换视频 / 视图拆掉时调；
    /// deinit 也调，不留野观察者）。
    func teardown() {
        player?.pause()
        if player != nil { (layer as? AVPlayerLayer)?.player = nil }
        for observer in [endObserver, resignObserver, activeObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        endObserver = nil
        resignObserver = nil
        activeObserver = nil
        player = nil
        currentURL = nil
    }

    deinit { teardown() }
}
