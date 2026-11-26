// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Lizi",
    platforms: [
        .iOS("16.2"),
    ],
    products: [
        // xtool bundles each .library product into an iOS app/extension.
        .library(
            name: "Lizi",
            targets: ["Lizi"]
        ),
        .library(
            name: "LiziLiveActivity",
            targets: ["LiziLiveActivity"]
        ),
    ],
    targets: [
        .target(
            name: "Lizi",
            path: "ios/Sources/Lizi",
            // App icon is supplied via xtool.yml iconPath; the asset catalog
            // is not compiled by SwiftPM here.
            exclude: ["Assets.xcassets"],
            // 注意：public/ 不在这里声明为 SwiftPM 资源。xtool 在 Linux 沙盒里
            // 拷 84M 资源包会被 EPERM 拦住（每次卡在不同子目录）。改由打包后
            // 手动把 public/ 拷进 .app 根目录（StaticFiles 用 Bundle.main
            // 找 public/，正好对上）。见 README 打包说明。
            resources: []
        ),
        // WidgetKit extension. The attributes file is duplicated here
        // (identical copy also in the app target): SwiftPM 6 forbids two
        // targets sharing one source file, so each target compiles its
        // own copy. Keep the two copies identical.
        .target(
            name: "LiziLiveActivity",
            path: "ios/Sources/LiziLiveActivity"
        ),
    ],
    // 服务端代码按 Swift 5 写的（XcodeGen 里 SWIFT_VERSION 5.0）；Swift 6
    // 严格并发会把静态可变状态等全报成硬错，这里保持 Swift 5 模式。
    swiftLanguageModes: [.v5]
)
