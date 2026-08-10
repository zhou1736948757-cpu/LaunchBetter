# 任务包 B1: 本地化应用名元数据(parity gap)

## 背景
LaunchBetter v0.2.3。当前应用显示名仅用基础 Info.plist(CFBundleDisplayName/CFBundleName),
未解析 .lproj/InfoPlist.strings 的本地化名(旧 LaunchHistory 有: AppScannerService.localizedDisplayName
读 preferredLocalizations → InfoPlist.strings → CFBundleDisplayName)。Stage B §B1 补齐。

## 允许修改的文件(禁止范围外)
- Packages/LaunchPlatform/Sources/LaunchPlatform/AppDiscoveryService.swift(元数据解析处)
- Packages/LaunchCore/Sources/LaunchCore/AppRecord.swift(若需存本地化名/语言字段)
- Packages/LaunchCore/Sources/LaunchCore/Catalog.swift(快照结构, schemaVersion 版本化)
- Packages/LaunchCore/Sources/LaunchCore/SearchIndex.swift(若索引需本地化名)
- LaunchBetterApp/LauncherStore.swift(displayName 解析 + rebuildSearchIndex 触发)
- 对应测试: LaunchPlatformTests + LaunchCoreTests

## 需求
1. 解析顺序: 自定义名 > 本地化 CFBundleDisplayName(lproj) > 本地化 CFBundleName >
   基础 CFBundleDisplayName > CFBundleName > 文件名(按 macOS 语义; 用户自定义名始终最高)
2. 确定性回退; 解析发生在 catalog 元数据工作(catalog 扫描/对账), 非每次显示/每帧
3. 结果缓存进 catalog 快照/AppRecord(schemaVersion 升级, 旧文件迁移保留)
4. 语言切换即时更新可见名(无需重启), 搜索索引随之更新
5. 无 per-launcher-show Info.plist IO; 无 per-frame IO

## 约束
- LaunchCore 无 AppKit/FileManager/Combine; 本地化解析在 LaunchPlatform
- 不破坏现有 schemaVersion 迁移; 迁移失败保留旧文件
- 不改交互/布局行为

## 验收
- en / zh-Hans / zh-Hant / 缺失本地化 / 畸形 strings / 回退 / 自定义覆盖 / 搜索 测试
- LaunchCore/Platform/UI 全测试绿; xcodebuild build 成功
- 语言切换后显示名与搜索即时更新(无重启)

## 命令纪律(硬性)
bash 每条单命令, 严禁 2>&1 | && ;、rg、rm 外部目录。搜索用 grep 工具, 读用 read 工具。
验证: swift test / xcodebuild build。

## 禁止
不提交 git; 不切换分支; 不改 Launchpad_Back; 不改 B1 范围外文件

## 输出
改动文件清单/假设/测试结果/偏差/未决; 每步 [PROGRESS]
