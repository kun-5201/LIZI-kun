import SwiftUI

/// 本形态设置面板（对照壳版 `#stage-settings` + `StagePanel`）。
///
/// 形态在脚本里声明一次 `window.__stagePanel`（标题 + items），宿主负责渲染、
/// 持久化（按形态编号，`lizi.native.stageSettings.<id>`）和变化时发
/// `postMessage({ __c100: 1, type: 'setting', payload: { key, value } })`。
/// 四种控件与壳版一一对应：range（滑杆）/ switch（开关）/
/// select（下拉）/ segment（分段）。`shake`（震动）是壳版在每个面板末尾
/// 统一追加的开关，关掉后桥的 beat.level 恒 0（见 StageBridge.shakeOff）。
struct StageSettingsView: View {
    @ObservedObject var bridge: StageBridge
    let spec: StagePanelSpec

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let hint = spec.hint, !hint.isEmpty {
                    Section {
                        Text(hint)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ForEach(spec.items) { item in
                        settingRow(item)
                    }
                }
                Section {
                    Button(role: .destructive, action: { bridge.resetSettings() }) {
                        Text("恢复默认")
                    }
                    .accessibilityLabel("恢复默认设置")
                } footer: {
                    Text("改完自动记住，切歌不变。")
                }
            }
            .navigationTitle(spec.title ?? bridge.currentForm.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
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
