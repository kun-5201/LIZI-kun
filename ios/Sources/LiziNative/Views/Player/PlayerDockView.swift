import SwiftUI

/// 底部 dock（仅播放页显示，高 76px，`--dock-h: 76px`）。
///
/// 布局照抄壳版 `.dock`：
/// - 左：76×76 正方形封面，点按 = 播放/暂停（壳版 `.dock__art`；触屏没有 hover，
///   所以播放/暂停小图标常显，不像壳版只在 hover 时出现）。
/// - 右：整条渐变进度条（壳版 `.dock__bar` + `.dock__paint` 渐变），点按或拖动 seek。
///
/// 第 13 轮教训：拖动时进度条的 rect 必须冻结 —— 这里封面是固定 76×76、
/// 进度条是 HStack 里唯一的弹性项（`flex: 1`），拖动只改渐变填充宽度，
/// 不改任何一个 view 的 frame；拖动中显示 `dragFraction`，忽略 `store.progress`
/// 的更新，松手才调一次 `seek(to:)`。
struct PlayerDockView: View {
    @EnvironmentObject private var store: PlaybackStore

    /// 拖动中的进度（0…1）；非 nil 时显示它，不读 `store.progress`。
    @State private var dragFraction: CGFloat?

    private var fraction: CGFloat {
        if let dragFraction { return dragFraction }
        guard store.duration > 0 else { return 0 }
        return CGFloat(max(0, min(store.progress / store.duration, 1)))
    }

    var body: some View {
        HStack(spacing: 0) {
            coverButton
            progressBar
        }
        .frame(height: PlayerTokens.dockHeight)
        .background(Color.black.opacity(0.35))
    }

    // MARK: - 左：76×76 封面（点按 = 播放/暂停）

    private var coverButton: some View {
        Button(action: { store.togglePlay() }) {
            ZStack {
                CoverImageView(url: store.currentTrack?.coverURL, placeholderIconSize: 24)
                Color.black.opacity(0.25)
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
            }
        }
        .frame(width: PlayerTokens.dockHeight, height: PlayerTokens.dockHeight)
        .disabled(store.currentTrack == nil)
        .accessibilityLabel(store.isPlaying ? "暂停" : "播放")
    }

    // MARK: - 右：整条渐变进度条（点按 / 拖动 seek）

    private var progressBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                // 未走过的轨道（壳版 .dock__bar 的淡白底）。
                Color.white.opacity(0.08)
                // 走过的渐变（壳版 .dock__paint：bar-a → bar-b）。
                LinearGradient(
                    colors: [
                        PlayerTokens.barA.opacity(0.75),
                        PlayerTokens.barA,
                        PlayerTokens.barB,
                        PlayerTokens.barB.opacity(0.9),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: max(0, fraction * width))
                // 轨道上沿一线光、下沿一线光（壳版 .dock__paint::after / .dock__bar::before）。
                VStack(spacing: 0) {
                    Color.white.opacity(0.45).frame(height: 1)
                    Spacer()
                    LinearGradient(
                        colors: [Color.white.opacity(0.3), Color.white.opacity(0.04)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 1)
                }
                // 播放头：一根发亮的细线（壳版 .dock__head）。
                if store.currentTrack != nil {
                    Rectangle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2)
                        .shadow(color: .white.opacity(0.45), radius: 8, x: 0, y: 0)
                        .offset(x: max(0, fraction * width - 1))
                }
            }
            .contentShape(Rectangle())
            .gesture(seekGesture(width: width))
            .disabled(store.currentTrack == nil || store.duration <= 0)
        }
        .frame(height: PlayerTokens.dockHeight)
        .accessibilityLabel("进度条")
        .accessibilityValue("\(PlayerTokens.formatDuration(store.progress)) / \(PlayerTokens.formatDuration(store.duration))")
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard width > 0, store.currentTrack != nil, store.duration > 0 else { return }
                dragFraction = clamp(value.location.x / width)
            }
            .onEnded { value in
                guard width > 0, store.currentTrack != nil, store.duration > 0 else {
                    dragFraction = nil
                    return
                }
                let target = clamp(value.location.x / width)
                dragFraction = nil
                // seek(to:) 入参是秒。
                store.seek(to: TimeInterval(target) * store.duration)
            }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
