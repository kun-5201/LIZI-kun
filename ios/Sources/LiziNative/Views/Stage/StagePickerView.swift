import SwiftUI

/// 形态选择器（对照壳版舞台页「形态」按钮弹出的两列下拉 `#stage-menu-pop`）。
///
/// 壳版下拉内容 = `stageMenuList(true)`：发行版只含白名单 85 个 + classic
/// （传统播放器，点它回播放页）；开发者版（`?edition=dev`）才是全集。
/// 原生版同样默认只列发行版（可播放的 85 个），再加一个「全部目录」开关列出
/// 全集 675 个——目录里没有文件的形态照样列出来（名 + 描述），但置灰并标
/// 「文件未收录」，点它会明说原因，不会打开一个空白页（壳版对这些条目
/// 直接 404，缺失是工作目录本身就没有这些文件，不是原生版引入的）。
/// 搜索按壳版 `stageMatches`：编号 + 形态名 + 描述子串匹配。
struct StagePickerView: View {
    @ObservedObject var bridge: StageBridge
    /// 选形态后的回调（StageView 接：classic 回播放页，其余调 bridge.load）。
    var onSelect: (StageForm) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showAll = false
    @State private var unavailableForm: StageForm?

    private var listed: [StageForm] {
        let base = StageCatalog.menuList(includeClassic: true, releaseOnly: !showAll)
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return base }
        return base.filter { StageCatalog.matches($0, query: query) }
    }

    private var availableCount: Int {
        listed.filter { $0.isClassic || StageCatalog.isAvailable($0) }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("范围", selection: $showAll) {
                    Text("发行版 · 可播放").tag(false)
                    Text("全部目录").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                List {
                    Section {
                        ForEach(listed) { form in
                            Button(action: { pick(form) }) {
                                HStack(spacing: 12) {
                                    Text(form.isClassic ? "—" : form.formId)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, alignment: .leading)
                                        .monospacedDigit()
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(form.name)
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            if bridge.currentForm.formId == form.formId {
                                                Text("当前")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.accentColor, in: Capsule())
                                            }
                                            if !form.isClassic, !StageCatalog.isAvailable(form) {
                                                Text("文件未收录")
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(.secondary)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                                            }
                                        }
                                        Text(form.desc)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    if !form.isClassic, !StageCatalog.isAvailable(form) {
                                        Image(systemName: "exclamationmark.triangle")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                                .opacity(form.isClassic || StageCatalog.isAvailable(form) ? 1 : 0.55)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(showAll
                             ? "全部目录 \(listed.count) 个 · 其中可播放 \(availableCount) 个"
                             : "发行版 \(listed.count) 个 · 全部可播放")
                    } footer: {
                        if showAll {
                            Text("「文件未收录」的形态只有目录条目、没有 HTML 文件（工作目录里就没有，壳版同样打不开），点它会提示原因，不会打开空白页。")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .searchable(text: $query, prompt: "搜编号 / 形态名 / 描述")
            .navigationTitle("选择形态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert(
                "这个形态打不开",
                isPresented: Binding(
                    get: { unavailableForm != nil },
                    set: { if !$0 { unavailableForm = nil } }
                ),
                presenting: unavailableForm
            ) { _ in
                Button("知道了", role: .cancel) { unavailableForm = nil }
            } message: { form in
                Text("「\(form.name)」只有目录条目，它的 HTML 文件不在本机工作目录里（壳版同样 404），所以这版装不上。已收录的 85 个形态在「发行版 · 可播放」里都能直接打开。")
            }
        }
    }

    private func pick(_ form: StageForm) {
        if form.isClassic || StageCatalog.isAvailable(form) {
            onSelect(form)
        } else {
            unavailableForm = form
        }
    }
}
