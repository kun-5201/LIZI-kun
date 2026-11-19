import SwiftUI

/// 本形态设置面板（对照壳版 `#stage-settings` + `StagePanel`；样式对照用户
/// 2026-11-20 舞台视频：标题在左（当前舞台名），右上「恢复默认 + X」，
/// 滑杆 / 开关 / 分段控件，底部「调完自动记住，切歌不变」）。
///
/// 形态在脚本里声明一次 `window.__stagePanel`（标题 + items），宿主负责渲染、
/// 持久化（按形态编号，`lizi.native.stageSettings.<id>`，与曲目/平台无关——
/// 播任意平台的歌都是同一套面板、同一份设置）和变化时发
/// `postMessage({ __c100: 1, type: 'setting', payload: { key, value } })`。
/// 四种控件与壳版一一对应：range（滑杆）/ switch（开关）/
/// select（下拉）/ segment（分段）。`shake`（震动）是壳版在每个面板末尾
/// 统一追加的开关，关掉后桥的 beat.level 恒 0（见 StageBridge.shakeOff）。
/// 舞台页与播放页共用本视图（两处都调它，不另写一套）。
struct StageSettingsView: View {
    @ObservedObject var bridge: StageBridge
    let spec: StagePanelSpec

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 视频里的面板头：标题在左（当前舞台名），恢复默认 + X 在右上；
            // 不再用 NavigationStack 的「完成」+ 列表里红字恢复默认（r22a）。
            HStack {
                Text(spec.title ?? bridge.currentForm.name)
                    .font(.headline)
                Spacer()
                Button("恢复默认") { bridge.resetSettings() }
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("恢复默认设置")
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            List {
                Section {
                    ForEach(spec.items) { item in
                        settingRow(item)
                    }
                } footer: {
                    // 底部那行字：优先用形态自己的 hint（纸页快闪的 hint 就是
                    // 「调完自动记住，切歌不变。」）；没有 hint 的形态用通用文案
                    // （与视频同字）。不再单独放一个旧文案段——之前
                    // hint 在顶部、通用文案在底部，同一句话出现两次。
                    Text(footerText)
                        .font(.system(size: 13))
                }
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
                    Spacer()
                    Text(formatNumber(bridge.settingValue(for: item).doubleValue, step: item.step ?? 0.01))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
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
        case "select":
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
            .font(.system(size: 15))
        case "segment":
            VStack(alignment: .leading, spacing: 6) {
                Text(item.label ?? item.key)
                    .font(.system(size: 15))
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
                Spacer()
                Text(bridge.settingValue(for: item).stringValue)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatNumber(_ value: Double, step: Double) -> String {
        let decimals = step < 0.01 ? 3 : step < 0.1 ? 2 : step < 1 ? 1 : 0
        return String(format: "%.\(decimals)f", value)
    }
}
