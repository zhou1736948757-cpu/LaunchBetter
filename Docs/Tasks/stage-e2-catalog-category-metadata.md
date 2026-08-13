# 任务包: Stage E2 Catalog category metadata

## 背景

App Library 的分类必须在已有 Catalog discovery Info.plist IO 中采集，Library show 不得逐 App 读取 Info.plist。当前 `AppRecord` 没有 category 字段，Catalog schema 为 2，`AppDiscoveryService.makeRecord` 已经解析同一个 Info.plist。

## 允许修改的文件

- `Packages/LaunchCore/Sources/LaunchCore/AppRecord.swift`
- `Packages/LaunchCore/Sources/LaunchCore/Catalog.swift`
- `Packages/LaunchCore/Tests/LaunchCoreTests/AppRecordTests.swift`
- `Packages/LaunchCore/Tests/LaunchCoreTests/CatalogTests.swift`
- `Packages/LaunchPlatform/Sources/LaunchPlatform/AppDiscoveryService.swift`
- `Packages/LaunchPlatform/Tests/LaunchPlatformTests/DiscoveryTests.swift`

禁止修改其它文件、禁止提交、禁止切换分支、禁止修改 `/Users/mac/Projects/Launchpad_Back`、禁止碰现有未跟踪文件。

## 约束

- `categoryIdentifier: String?` 是原始 `LSApplicationCategoryType`，不在 AppRecord 中定义 UI category enum。
- AppRecord 旧 JSON 没有该字段时必须 decode 为 nil，不能破坏旧 Catalog。
- `CatalogSnapshot.currentSchemaVersion` 从 2 升到 3；旧 schema 2 必须可解码，不能静默删除数据。
- `AppDiscoveryService` 只在已有 `Contents/Info.plist` 读取点读取 category，禁止新增 Library/show 扫描路径。
- LaunchCore 仍不能导入 AppKit/SwiftUI/Combine/FileManager。
- 保持 AppID、localizedNames、iconContentVersion、排序和 CatalogDelta 语义不变。
- 不在本任务实现 classifier、UsageStore、firstSeen 或 UI。

## 实现要求

- AppRecord 初始化参数新增带默认值的 `categoryIdentifier`，避免无关调用方破坏。
- 自定义 Codable 解码使用 `decodeIfPresent`；编码包含字段但允许 nil。
- Catalog 版本常量升级并保留现有解码排序行为。
- discovery 从 `[String: Any]` 读取 `LSApplicationCategoryType as? String`，空字符串按 nil 处理。

## 必写测试

- AppRecord 新字段 round-trip。
- 无字段旧 JSON decode 为 nil。
- Catalog schema 3 初始化与 schema 2 旧快照解码。
- Discovery fake app: known category、nil、unknown/empty category。
- 现有 display name/localized name/icon metadata 测试不回归。

## 验收

- `cd Packages/LaunchCore && swift test` 通过。
- `cd Packages/LaunchPlatform && swift test` 通过。
- 不增加 `DispatchQueue.main.sync`。
- 返回改动文件、schema 假设、测试结果、偏差和未决问题；每一步用 `[PROGRESS]`。
