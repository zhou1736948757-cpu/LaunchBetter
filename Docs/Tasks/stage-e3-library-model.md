# 任务包: Stage E3 AppLibrary pure model

## 背景

App Library 是从 Catalog、hidden state、usage/firstSeen metadata 派生的 read model，不属于 LayoutStore。此任务只建立 LaunchCore 纯逻辑模型、分类映射和 deterministic ranking，暂不实现 Platform persistence 或 LaunchUI。

当前已存在:

- `AppRecord.categoryIdentifier: String?`
- `CatalogSnapshot.currentSchemaVersion == 3`
- `LauncherSurface` / `LauncherSurfaceIndex`

## 允许修改的文件

- `Packages/LaunchCore/Sources/LaunchCore/AppLibraryModel.swift` (新增)
- `Packages/LaunchCore/Tests/LaunchCoreTests/AppLibraryModelTests.swift` (新增)

禁止修改其它文件、禁止提交、禁止切换分支、禁止修改旧仓库或现有未跟踪文件。

## 必须提供的纯值 API

具体命名可做等价窄调整，但必须保持以下职责和可供后续 Platform/UI 使用的稳定接口:

- `AppLibraryCategory`: Productivity、Social、Developer、Entertainment、Games、Creativity、Utilities、Education、Business、Finance、Other；`Codable/Hashable/Sendable/CaseIterable`。
- `AppLibraryCategoryClassifier`: 根据原始 `LSApplicationCategoryType` 做大小写归一后的确定性映射；nil、空、未知进入 Other。
- `AppLibraryUsageRecord`: `launchCount`、`lastLaunchedAt`，`Codable/Equatable/Sendable`。
- `AppLibraryMetadataSnapshot`: schemaVersion、usage map、firstSeen map、bootstrap marker；独立于 Layout，`Codable/Equatable/Sendable`。
- `AppLibraryApp`: AppID + 已解析 displayName + category，纯值。
- `AppLibraryCardID`: suggestions、recentlyAdded、category(category)；identity 不能包含当前 app array。
- `AppLibraryCard`: stable id、primary apps(最多 3)、mini apps(最多 4)、全量 category/detail apps或等价 payload。
- `AppLibraryModel`: 有序 cards + category detail payload，`Equatable/Sendable`，不持有 AppKit。
- `AppLibraryModelBuilder`: 从 Catalog、hidden IDs、custom names、language/system language、metadata、Page 1 fallback IDs、now 构建 model。

## 产品约束

- hidden App 和不在 Catalog 的 App 不出现在任何 card/detail。
- custom display name 优先，随后当前语言 localized name，再回退 AppRecord.displayName。
- 固定 category priority；category 内按 usage/recency，最终按 displayName/AppID 稳定 tie-break。
- 只有一个 App 的普通 category 合并到 Other，避免稀疏卡；Other 非空才生成。
- Suggestions 最多 4 个直接启动 App；无 usage 时使用 Page 1 visible fallback，再用 stable order 补齐。
- ranking 必须 deterministic，不能使用随机数或网络/ML。
- Recently Added 只在 metadata 已 bootstrap 且存在真实 firstSeen 新增时生成；初次 baseline 不得全部视为 today。
- Recently Added 默认 30 天窗口，常量集中定义并可测试。
- model build 是 memory-only，不修改 LayoutSnapshot，不做 IO。
- 100/250/500 App 构建不能产生 500 个 UI view；模型只保存值和 IDs。

## 必写测试

- 已知分类、nil、unknown、graphics/photo → Creativity。
- hidden/missing filter、custom source record 与普通 record 等价。
- localized/custom name 优先级。
- singleton category compact 到 Other、固定 category ordering、stable card IDs。
- ranking: recent+frequent > old+frequent、frequent > never-used、tie deterministic、decay。
- cold start Page 1 fallback。
- firstSeen bootstrap、30 天边界、无新增不生成空 Recently Added。
- model build 100/250/500 与重复 build 等值。

## 验收

- `cd Packages/LaunchCore && swift test` 通过。
- LaunchCore 不导入平台框架/文件系统。
- 返回实际 API、算法假设、测试结果、偏差和未决问题；每一步用 `[PROGRESS]`。
