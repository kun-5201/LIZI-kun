import SwiftUI

/// 歌曲定时弹层（r52-3，传统播放页专用；舞台页不挂）。
/// - 竖屏：底部弹层，单列 7 行（15/30/60/90/120 分钟 + 播完当前歌曲 +
///   取消定时），行高 56pt，选中行右侧打金勾（定稿图
///   ~/workspace/lizi-r52-sleep-timer-mockup.png）。
/// - 横屏：居中面板，两列选项（左 15/30/60，右 90/120/播完当前歌曲），
///   选中勾在两列中间，下面一行红色「取消定时」（定稿图
///   ~/workspace/lizi-r52-sleep-timer-landscape-mockup.png）。
///   横屏只有约 402pt 高：行高 44pt、面板总高约 280pt，全选项点得到、
///   不被裁、不溢出。
/// - 标题「歌曲定时」+ 副文案「到时自动暂停播放」；定时开着时再打开，
///   标题下多一行剩余时间（分钟定时「还剩 X 分钟」/播完「播完当前歌曲后暂停」）。
/// - 点选项即设定并关闭；点「取消定时」即取消并关闭；点遮罩只关闭、不改定时。
struct SleepTimerSheetView: View {
    @EnvironmentObject private var store: PlaybackStore
    var isLandscape: Bool
    var onClose: () -> Void

    /// 卡片底色（稿子的深紫灰底）。
    private static let cardColor = Color(red: 0.17, green: 0.17, blue: 0.22)
    /// 选中勾颜色（稿子的金勾）。
    private static let checkColor = Color.yellow

    private var minuteOptions: [Int] { [15, 30, 60, 90, 120] }
    private var rowHeight: CGFloat { isLandscape ? 44 : 56 }

    /// 定时开着时标题下那行剩余时间（无定时时不显示）。
    private var remainingLine: String? {
        switch store.sleepTimerMode {
        case .none: return nil
        case .minutes:
            let mins = Int(ceil(max(0, store.sleepTimerRemainingSeconds) / 60))
            return "还剩 \(max(1, mins)) 分钟"
        case .endOfTrack: return "播完当前歌曲后暂停"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if let remaining = remainingLine {
                Text(remaining)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.top, 4)
                    .padding(.horizontal, 20)
            }
            if isLandscape {
                landscapeOptions
            } else {
                portraitOptions
            }
            cancelRow
        }
        .padding(.top, 16)
        .padding(.bottom, isLandscape ? 12 : 24)
        .background {
            // 横屏全圆角居中面板，竖屏只上两角圆角的底部弹层。
            if isLandscape {
                Self.cardColor.clipShape(RoundedRectangle(cornerRadius: 20))
            } else {
                Self.cardColor.clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
            }
        }
    }

    /// 标题行：左「歌曲定时」，右副文案「到时自动暂停播放」（横竖屏同款）。
    private var headerRow: some View {
        HStack {
            Text("歌曲定时")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Text("到时自动暂停播放")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 20)
    }

    /// 竖屏单列：5 个分钟档 + 播完当前歌曲，各一行；选中行右侧金勾。
    private var portraitOptions: some View {
        VStack(spacing: 0) {
            ForEach(minuteOptions, id: \.self) { mins in
                optionButton(title: "\(mins) 分钟", selected: store.sleepTimerMinutes == mins) {
                    store.setSleepTimer(minutes: mins)
                    onClose()
                }
                Divider().background(Color.white.opacity(0.12)).padding(.leading, 20)
            }
            optionButton(title: "播完当前歌曲", selected: store.sleepTimerMode == .endOfTrack) {
                store.setSleepTimerEndOfTrack()
                onClose()
            }
        }
        .padding(.top, 8)
    }

    /// 横屏两列：左 15/30/60，右 90/120/播完当前歌曲；选中勾在两列中间
    /// （与定稿图同款）；每行左右两格都是整格可点。
    private var landscapeOptions: some View {
        VStack(spacing: 0) {
            landscapeRow(leftMinutes: 15, rightMinutes: 90)
            landscapeRow(leftMinutes: 30, rightMinutes: 120)
            landscapeRow(leftMinutes: 60, rightEndOfTrack: true)
        }
        .padding(.top, 8)
    }

    private func landscapeRow(leftMinutes: Int, rightMinutes: Int? = nil, rightEndOfTrack: Bool = false) -> some View {
        HStack(spacing: 0) {
            optionCell(title: "\(leftMinutes) 分钟", selected: store.sleepTimerMinutes == leftMinutes) {
                store.setSleepTimer(minutes: leftMinutes)
                onClose()
            }
            // 中间勾列（定稿图同款）：本行左右任一选项选中时打勾。
            ZStack {
                if store.sleepTimerMinutes == leftMinutes
                    || (rightMinutes.map { store.sleepTimerMinutes == $0 } ?? false)
                    || (rightEndOfTrack && store.sleepTimerMode == .endOfTrack) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Self.checkColor)
                }
            }
            .frame(width: 48)
            if let rightMinutes {
                optionCell(title: "\(rightMinutes) 分钟", selected: store.sleepTimerMinutes == rightMinutes) {
                    store.setSleepTimer(minutes: rightMinutes)
                    onClose()
                }
            } else {
                optionCell(title: "播完当前歌曲", selected: store.sleepTimerMode == .endOfTrack) {
                    store.setSleepTimerEndOfTrack()
                    onClose()
                }
            }
        }
        .frame(height: rowHeight)
    }

    /// 取消定时行：竖屏左对齐、横屏居中（与两张定稿图同款），红色；
    /// 上方一条分隔线。无定时时点它也只是关闭，不报错。
    private var cancelRow: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.12))
            Button(action: {
                store.cancelSleepTimer()
                onClose()
            }) {
                Text("取消定时")
                    .font(.system(size: isLandscape ? 18 : 20))
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: isLandscape ? .center : .leading)
                    .frame(height: rowHeight)
                    .padding(.horizontal, 20)
            }
            .accessibilityLabel("取消定时")
        }
        .padding(.top, 4)
    }

    /// 单列选项行：标题左对齐，选中时右侧金勾；整行可点。
    private func optionButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Self.checkColor)
                }
            }
            .frame(height: rowHeight)
            .padding(.horizontal, 20)
        }
        .accessibilityLabel(title)
    }

    /// 横屏两列里的一个格子：标题左对齐，整格可点。
    private func optionCell(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: rowHeight)
                .padding(.leading, 20)
        }
        .accessibilityLabel(title)
    }
}
