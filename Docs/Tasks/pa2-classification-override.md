# 任务包: PA2 — 分类根因修复 + 手动分类覆盖

## 背景与根因(已由主控查明)
- QQ: AppID `/Applications/QQ.app`、bundle `com.tencent.qq`、自报 `categoryIdentifier = public.app-category.developer-tools`、displayName QQ。
- 分类器 `developer-tools → .developer`。QQ 语义上是即时通讯 → 应 Social。
- 其它 IM 声明正常(WeChat `com.tencent.xinWeChat`→social、WhatsApp→social)。
- 用户要求: 手动覆盖(把 QQ 移到 Social,之后可"自动分类"还原);覆盖优先于自动分类;覆盖不得进 LayoutStore、不得改 AppRecord.categoryIdentifier。

## 允许修改的文件
- `Packages/LaunchCore/Sources/LaunchCore/AppLibraryModel.swift`(schema v2、builder 输入/优先级/合并规则、bundle 校正)
- `Packages/LaunchPlatform/Sources/LaunchPlatform/AppLibraryMetadataStore.swift`(override 读写 + 持久化)
- `LaunchBetterApp/LauncherStore.swift`(应用 override → 重建 model → 通知)
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryViewController.swift`(live 刷新 + 上下文菜单回调)
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryCardCell.swift` / `AppLibraryDetailViewController.swift`(右键菜单)
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryHostItem.swift`(转发 blank/override 刷新)
- `Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift`(host 数据变化时刷新 Library model)
- 相关测试文件

禁止改 LayoutStore/LayoutSnapshot/AppRecord.categoryIdentifier;禁止提交/切分支/改旧仓库。

## 规格

### 1. schema v2(核心)
`AppLibraryMetadataSnapshot.currentSchemaVersion` 1 → 2;新增
`public let categoryOverrides: [AppID: AppLibraryCategory]`。
解码: `decodeIfPresent ?? [:]`。编码含 categoryOverrides。
`AppLibraryMetadataStore` 内所有构造快照处(bootstrap/recordDiscovered/recordLaunch)
必须**保留** categoryOverrides;新增:
- `setCategoryOverride(appID: AppLibraryCategory)` → 更新 memory、noteMutation、返回新快照
- `clearCategoryOverride(appID)` → 移除、noteMutation、返回新快照
迁移: 旧文件缺 categoryOverrides → [:], 不抛错、不销毁 usage/firstSeen;损坏文件既有备份策略保留。

### 2. bundle-ID 校正(极小表,LaunchCore)
`AppLibraryCategoryClassifier` 增加 bundle 校正:
`public static let bundleCategoryCorrections: [String: AppLibraryCategory] = ["com.tencent.qq": .social]`
只允许这个证据充分的最小表(QQ 自报 developer-tools 语义错误)。不加名字启发式、无网络/AI。

### 3. Builder 优先级与合并(核心)
`AppLibraryModelBuilder.Inputs` 新增 `categoryOverrides: [AppID: AppLibraryCategory] = [:]`。
`resolve` 分类:
```
effective = overrides[record.id]
           ?? bundleCategoryCorrections[record.bundleIdentifier]
           ?? classifier(record.categoryIdentifier)
```
**合并规则(A11)**: 普通分类若只有 < `categoryCardMinimumAppCount`(2) 个 app 且**不含任何手动覆盖 app** → 并入 Other;若含手动覆盖 app → **必须保留为独立卡**,不得因稀疏被合并掉。手动覆盖进 Other 保持可见。测试此规则。
(实现建议: grouping 时记录每分类 hasManualOverride;合并时跳过 hasManual 的分类。)

### 4. LauncherStore 接线
`LauncherStore` 暴露(经 `AppLibraryDataProviding` 之外的专门接口或新增方法):
- `setCategoryOverride(appID:category:)` / `clearCategoryOverride(appID:)`:
  `applyMetadataSnapshot(await metadataStore.setCategoryOverride(...))`(async,不阻塞 UI 主路径,复用既有 applyMetadataSnapshot→rebuildLibraryModel→notify 链路)。
- `buildLibraryModel` 传入当前 `categoryOverrides`(来自 metadataSnapshot)。
禁止: 写 LayoutStore、重启、重扫、Info.plist IO。

### 5. Library live 刷新(热更新)
冻结 session 期间也要能刷新模型:
`AppLibraryViewController` 增加 `updateModel(_ model:)`: 绕过 sessionFrozen 的 apply 屏蔽,但保持 session 语义(身份稳定);复用 `reloadCards()`(diffable 身份稳定)。`AppLibraryHostItem` 在数据变化时(host 已 attach 且 session active)调 `controller.updateModel(provider.appLibraryModel())`。
`GridViewController.refresh()`(store.onDataChange 触发)里对 Library host 做同样刷新(不 endSession 重建,除非必要)。
稳定 diffable card 身份必须保持。

### 6. 手动覆盖 UI(macOS 原生,低复杂度)
右键(menu)入口:
- Library 卡片大图标: 菜单 "Move to Category" 子菜单(Productivity/Social/Developer/Entertainment/Games/Creativity/Utilities/Education/Business/Finance/Other)+ "Automatic Classification";当前生效分类打勾;当前为手动时"Automatic Classification"可移除 override。
- 分类 detail 行图标: 同样入口。
实现: card/detail cell 暴露右键 AppID + onCategoryMenu 回调;AppLibraryViewController 构建 NSMenu 并处理选择 → 调 store 覆盖 → 依赖第 5 节热刷新。不做拖拽换卡。

### 7. 测试(A21 覆盖点)
- 分类映射保持正确(LS→category)
- 手动覆盖 > 自动(bundle 校正) > classifier
- 移除覆盖恢复自动
- 未知 → Other
- 覆盖到稀疏分类仍可见(不合并)
- persistence roundtrip(含 categoryOverrides)
- 旧 schema(无 categoryOverrides)迁移 → []
- QQ 合成记录(bundle=com.tencent.qq, category=developer-tools)在无覆盖时经 bundle 校正 → social;覆盖为其它分类时覆盖优先
- schemaVersion=2 编码一致

## 验收
1. LaunchCore / LaunchPlatform / LaunchUI 测试全绿(记录准确数字)。
2. Debug build 成功。
3. 输出改动清单、根因说明、测试结果、偏差。
