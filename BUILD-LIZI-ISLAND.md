# Lizi iOS + 灵动岛歌词 — 构建说明

IPA：`~/workspace/your_files/Lizi-IslandLyrics-unsigned.ipa`（62M，未签名，全能签导入安装）
- 主 App：`com.lty5201.lizi`，LIZI 粒子播放器 1.1.0，iOS 16.2+，arm64
- 扩展：`com.lty5201.lizi.LiziLiveActivity`，歌词灵动岛，WidgetKit，arm64
- sha256：`a9f0f0f040481836ac641b8227b5a47961092e745b96e0d42d2a58cbf902cbda`

## 集成方案

- 扩展 UI 直接复用 island-lyrics 的 LyricsLiveActivityViews（紧凑条当前行+♪，展开/锁屏三行+进度，当前行加粗）；属性 struct 改名 `LiziLyricsAttributes`，字段与 island-lyrics 相同。
- 歌词不重新取：网页播放器已有 LRC，渲染在 `#lyrics` 里（每行 `.ly`，当前行 `.ly.is-active`，正文 `.ly__main`）。
- 桥接：注入 WKUserScript（document end，每 1 秒）读 DOM（`Player.audio` 优先，取不到找未暂停的 `<audio>`，再退到 #btn-play；歌名从 document.title 按 "·" 拆），经 `window.webkit.messageHandlers.liziBridge.postMessage` 推给原生 `LyricsBridge` → `LiziIslandCoordinator`。行变/切歌/播放暂停切换立刻推，进度最多 5 秒推一次；staleDate 15s，结束 .immediate。
- LiveActivityManager 只要求 `areActivitiesEnabled`；frequentPushesEnabled 只作警告。

## 构建路线：SwiftPM + xtool 本地编

工程：`~/workspace/lizi-ios/`（Package.swift、xtool.yml、Lizi-Info.plist、LiziLiveActivity-Info.plist 在包根目录；project.yml 未动，留给 GitHub Actions 路线备用）。

固定环境（每次都要带）：
```bash
export PATH=$HOME/workspace/xtool-test/swift-6.4.2-RELEASE-ubuntu24.04/usr/bin:$PATH
export XDG_CONFIG_HOME=/home/hatch/.config
export TMPDIR=/home/hatch/workspace/xtool-test/tmp
~/workspace/xtool-test/squashfs-root/usr/bin/xtool dev build --ipa
```

## 两个坑与绕法（复现构建时必须做）

### 1. public/ 资源拷不进包（沙盒 EPERM）
xtool 打包时拷 84M 的 `public/` 会被沙盒拦（NSCocoaErrorDomain 513 / EPERM），每次卡在不同子目录（`_ab`、`vendor`），换 TMPDIR 到 /tmp 也一样。手动拷同样的路径能拷，不是文件系统问题。
- 绕法：Package.swift 里不声明 public/ 资源（`resources: []`），xtool 才能打完包；打完后手动把 `public/` 拷进 `Payload/Lizi.app/public/`（Bundle.main 找 public/，正好对上），再重新 zip。
- 注意：不要改 StaticFiles.swift（它用 Bundle.main，本来就对）。

### 2. 扩展二进制是空壳（xtool 链接 bug）
xtool 编出的 `LiziLiveActivity.appex/LiziLiveActivity` 只有 49K、24 个字串，只链 Foundation，没有 SwiftUI/WidgetKit 代码。扩展的三个 .swift 文件其实编成了 .o（LiziLiveActivityBundle.o、Views.o、Attributes.o），合并的 `LiziLiveActivity.o`（337K）里 Widget 代码全在，但 xtool 的最终链接把 Swift 代码 strip 掉了（只剩 stub.o 的 `_NSExtensionMain`）。
- 绕法：用 ld64.lld 手动重链扩展二进制，再替换进 IPA：
```bash
SDK=/home/hatch/.config/swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
LD64=/home/hatch/.config/swiftpm/swift-sdks/darwin.artifactbundle/toolset/bin/ld64.lld
STUB=~/workspace/lizi-ios/.build/out/Intermediates.noindex/Lizi-Builder.build/Debug-iphoneos/LiziLiveActivity-Extension-p.build/Objects-normal/arm64/stub.o
SWIFTO=~/workspace/lizi-ios/.build/out/Products/Debug-iphoneos/LiziLiveActivity.o
"$LD64" -arch arm64 -platform_version ios 16.2 16.2 -syslibroot "$SDK" \
  -o /tmp/LiziLiveActivity-fixed "$STUB" "$SWIFTO" \
  -F "$SDK/System/Library/Frameworks" \
  -framework SwiftUI -framework WidgetKit -framework ActivityKit -framework Foundation \
  -L "$SDK/usr/lib/swift" -lswiftCore -lSystem -lobjc
```
  重链后 225K，链 ActivityKit/SwiftUI/WidgetKit，DynamicIsland 符号 89 个。替换进 `Payload/Lizi.app/PlugIns/LiziLiveActivity.appex/LiziLiveActivity` 后重新 zip。
- 注意：不要用 swiftc 链（它调 Linux 的 /usr/bin/ld；`-use-ld` 对 .o 输入不起作用；ld64.lld 不认 `-no_dead_strip`，默认不 strip，不用加）。

## 编译期修补（最小改动，都在 lizi-ios 里）
- `CFStringEncodings.gb_18030_2000` → 数值 `0x0632`（Kuwo.swift、QQ.swift；真机 Xcode 也会遇到）。
- Crypto.swift `kCCOptionPKCS7Padding` 等包 `CCOptions(...)`（UInt32 类型不匹配）。
- Package.swift 加 `swiftLanguageModes: [.v5]`（放 targets 之后），绕 Swift 6 严格并发。
- `LiziIslandCoordinator` / `LiveActivityManager` 去掉 @MainActor（WebHost 非 MainActor 无法同步创建；ActivityKit 调用内部用 `Task { @MainActor in }`）。

## 未验证（需真机）
- 装后播放一首歌，确认灵动岛出现当前歌词行、切行时更新、暂停/切歌时切换。
- 位置权限选「始终」，否则回桌面 App 被挂起、岛约 15 秒消失。
