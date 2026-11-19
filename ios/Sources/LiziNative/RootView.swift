import SwiftUI

/// 原生版空态首页（P0 脚手架占位）。
///
/// 只显示「LIZI 原生」+ 构建信息，证明 App 能装、能启动、能读到构建期
/// 生成的版本信息。首页真正的 Hall 视图由 P1 工人按 NATIVE-REWRITE-PLAN.md §1 接。
struct NativeHomeView: View {
    @State private var lastOpenedURL: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("LIZI 原生")
                .font(.largeTitle.bold())
            Text("原生重写 · P0 脚手架")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                buildRow(label: "构建", value: LiziNativeBuildInfo.shortCommit)
                buildRow(label: "构建号", value: LiziNativeBuildInfo.build)
                buildRow(label: "日期", value: LiziNativeBuildInfo.date)
                buildRow(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "未知")
                buildRow(label: "版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知")")
                if let lastOpenedURL {
                    buildRow(label: "最近打开", value: lastOpenedURL)
                }
            }
            .font(.footnote.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("空态首页——页面功能由后续工人接")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onOpenURL { url in
            // P0 只记录，不处理：证明 lizinative:// scheme 已接进 App。
            // 真正的路由（now / airplay 等）由 P1 工人接。
            lastOpenedURL = url.absoluteString
        }
    }

    private func buildRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}
