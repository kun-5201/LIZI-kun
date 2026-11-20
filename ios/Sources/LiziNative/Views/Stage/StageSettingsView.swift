import SwiftUI

/// 本形态设置浮层（r26，用户 22:36：齿轮面板也改成歌曲内浮层就地调，
/// 不去另外一个界面；样式与形态下拉同一套深色面板）。
///
/// 旧的全屏 sheet 已撤：本视图现在是 StageView 里盖在舞台画面上的浮层内容，
/// 与 StagePickerView 共用 StageFloatPanel 外壳；播放页不调它（播放页齿轮
/// 是进舞台页，见 PlayerView 注释），全 app 只有 StageView 一个调用点。
///
/// 调节项原样保留：形态 `window.__stagePanel` 声明的四种控件
/// range / switch / select / segment 有几个画几个（纸页快闪 9 项：
/// 中心词 / 镜头放大 / 周围虚化 / 中心保持清晰 / 运动模糊 / 复古胶卷 /
/// 每拍换纸 / 荧光笔 / 震动；体素街机厅只有震动 1 项），另加右上「恢复默认」。
/// 改一个立即生效（bridge.setSetting：写盘 + postMessage 发给形态），
/// 设置按形态编号存（`lizi.native.stageSettings.<id>`），与曲目/平台无关，
/// 切歌不变；歌不停，不跳页面。
struct StageSettingsView: View {
    @ObservedObject var bridge: StageBridge
    let spec: StagePanelSpec
    /// 关面板（StageView 接：showSettings = false）。
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 面板头：标题在左（当前舞台名），恢复默认 + X 在右上（r22a 原样）。
            HStack {
                Text(spec.title ?? bridge.currentForm.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Button("恢复默认") { bridge.resetSettings() }
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityLabel("恢复默认设置")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                }
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.09)).frame(height: 1)
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 13) {
                    ForEach(spec.items) { item in
                        settingRow(item)
                    }
                    Text(footerText)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }

    /// 底部文案：形态 hint 优先（每形态自己的说明），没有 hint 时用通用文案。
    private var footerText: String {
        if let hint = spec.hint, !hint.isEmpty { return hint }
        return "调完自动记住，切歌不变。"
    }

    @ViewBuilder
    private func settingRow(_ item: StagePanelItem) -> some View {
        switch item.type {
        case "range":
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.label ?? item.key)
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(formatNumber(bridge.settingValue(for: item).doubleValue, step: item.step ?? 0.01))
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { bridge.settingValue(for: item).doubleValue },
                        set: { bridge.setSetting(key: item.key, value: .number($0)) }
                    ),
                    in: (item.min ?? 0)...(item.max ?? 1),
                    step: item.step ?? 0.01
                )
                .tint(.white)
            }
        case "switch":
            Toggle(
                item.label ?? item.key,
                isOn: Binding(
                    get: { bridge.settingValue(for: item).boolValue },
                    set: { bridge.setSetting(key: item.key, value: .bool($0)) }
                )
            )
            .font(.system(size: 15))
            .foregroundStyle(.white)
            // 壳版开关开态是淡蓝（.spnl__sw 开态 oklch(62% 0.16 250)），
            // 不用系统绿，保持深色面板的单色调。
            .tint(Color(red: 0.45, green: 0.58, blue: 1.0))
        case "select":
            HStack {
                Text(item.label ?? item.key)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { bridge.settingValue(for: item).stringValue },
                        set: { bridge.setSetting(key: item.key, value: .string($0)) }
                    )
                ) {
                    ForEach(item.options ?? [], id: \.v) { opt in
                        Text(opt.t).tag(opt.v)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .foregroundStyle(.white)
            }
        case "segment":
            VStack(alignment: .leading, spacing: 6) {
                Text(item.label ?? item.key)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                Picker(
                    item.label ?? item.key,
                    selection: Binding(
                        get: { bridge.settingValue(for: item).stringValue },
                        set: { bridge.setSetting(key: item.key, value: .string($0)) }
                    )
                ) {
                    ForEach(item.options ?? [], id: \.v) { opt in
                        Text(opt.t).tag(opt.v)
                    }
                }
                .pickerStyle(.segmented)
            }
        default:
            HStack {
                Text(item.label ?? item.key)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                Spacer()
                Text(bridge.settingValue(for: item).stringValue)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func formatNumber(_ value: Double, step: Double) -> String {
        let decimals = step < 0.01 ? 3 : step < 0.1 ? 2 : step < 1 ? 1 : 0
        return String(format: "%.\(decimals)f", value)
    }
}
