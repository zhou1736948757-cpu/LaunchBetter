# 0002 - Stage E App Library Surface

> 状态: Proposed, E0 audit complete | 日期: 2026-08-12 | 阶段: Stage E

## Baseline

- 当前 source of truth: `main` / `e48d954c10871d1de24ec406d962dfea8a9cb3b2`
- 本地比 `origin/main` 多 1 个提交; 未跟踪的 `Docs/Visual/*` 与 `work/` 不属于本阶段改动范围。
- LaunchCore 87 测试、LaunchPlatform 127 测试、LaunchUI 196 测试通过。
- 当前完整工程 Debug build 有既存编译阻塞: `LauncherStore.init` 在所有 stored properties 初始化前调用 `rebuildCatalogIndex()`。Stage E 必须先修复并单独验证，不把它归因于 App Library。
- 当前搜索从普通第 2 页或更后页退出时会被搜索态 `pageCount == 1` 提前 clamp 到第 0 页。Stage E 的 surface restore 必须修复并补测试。

## Decision Summary

App Library 是一个 derived、只读、非 Layout 的 leading special surface。它使用现有横向分页文档的第 0 个物理 section，普通 Layout page 从物理 section 1 开始。Library section 内部使用独立的垂直 `NSScrollView + NSCollectionView`，不创建第二套横向分页器，也不使用负 scroll offset。

```text
physical surface 0 = App Library
physical surface 1 = Layout page 0 (用户 Page 1)
physical surface 2 = Layout page 1 (用户 Page 2)
...
```

`LayoutSnapshot`、`LayoutStore`、`LayoutTransaction` 和 `FolderRecord` 永远不包含 App Library sentinel、section 或 FolderID。

## 1. Semantic Surface Contract

在 LaunchCore 定义纯逻辑 surface 语义和映射，禁止 UI 各处手算 `+1/-1`:

```swift
enum LauncherSurface: Equatable, Sendable {
    case appLibrary
    case layoutPage(Int)
}

struct LauncherSurfaceIndex: Sendable, Equatable {
    let layoutPageCount: Int

    var physicalSurfaceCount: Int { layoutPageCount + 1 }
    func physicalIndex(for surface: LauncherSurface) -> Int
    func surface(forPhysicalIndex index: Int) -> LauncherSurface
    func layoutPageIndex(forPhysicalIndex index: Int) -> Int?
}
```

`layoutPageCount` 至少为 1，保持空布局仍有用户 Page 1 的产品语义。物理状态和语义状态分开:

- PagingInteractionController、PageSnapAnimator、PagingTargetResolver、PagingRubberBand 只处理 physical index、offset 和 physical count。
- `GridViewController` 的普通页 API、拖拽目的地、Layout mutation API 使用 semantic `layoutPage(Int)`。
- 现有 `currentPageValue` / `pageCountValue` 保留普通 Layout page 语义，避免 DragController 将 Library 当成可拖拽页；增加专用 physical diagnostics/API。
- 默认 surface 是 `.layoutPage(0)`，物理 index 为 1。
- Page dots 使用 `layoutPageCount`，Library 不增加 dot；Library active 时 dots 使用现有 motion language 隐藏或淡出。

## 2. Presentation Integration

### Leading section

`PagingGridLayout` 增加 leading-special-section 语义:

- paged mode 的 section 0 是一个完整 page-sized Library host item。
- ordinary section `physicalIndex >= 1` 的 slot 几何仍由普通 `GridGeometry` 计算，再加一个 leading `pageWidth` 文档偏移。
- GridGeometry 继续只负责普通 Layout page 的 page/slot/frame 数学，不认识 App Library 卡片。
- paged document width 是 `physicalSurfaceCount * pageWidth`，仍由唯一 paging writer 写 horizontal offset。
- search mode 临时关闭 leading section，使用现有单 section vertical search layout；退出时按保存的 semantic surface 恢复，不把搜索页当成 Library 或普通 Page 1。

### Data source

外层 collection data source 使用稳定 wrapper identity，而不是把 Library 写进 `DisplayModel`:

```swift
enum LauncherSurfaceItem: Hashable {
    case appLibrary
    case layout(DisplayModel.DisplayItem)
}
```

`AppLibraryHostItem` 只承载 `AppLibraryViewController`，不承载 Layout item。普通 AppCell、Folder cell、drag identity 和 Layout transaction 仍只处理 `.layout(...)` 项。外层 diffable identity 对 Library 永远稳定，普通 item identity 继续沿用 AppID/FolderID。

普通拖拽坐标在进入 `GridGeometry` 前减去 leading page offset，再将结果映射到 Layout page/slot；返回文档 frame 或 overlay frame 时加回该偏移。物理 section 0 的 item 永远不是有效 Layout drop target，Library active 时 root drag、三指 App drag、create folder、reorder 全部关闭。

## 3. Library Data Model

### Catalog metadata

- `AppRecord` 增加可缺省的 `categoryIdentifier: String?`。
- `AppDiscoveryService.makeRecord` 在已有 discovery Info.plist IO 中读取 `LSApplicationCategoryType`，禁止在 Library show 时重新读 plist。
- `CatalogSnapshot.currentSchemaVersion` 升级;旧 AppRecord 无此字段时解码为 nil，旧 Catalog 保留并在正常新 snapshot 持久化时升级。
- 分类字符串保持原始 metadata 字符串，UI 分类映射是纯逻辑，不把系统分类硬编码成持久化 enum。

### Stable UI categories

LaunchCore 定义稳定、可测试的 UI category 和确定性映射。第一版至少覆盖 Productivity、Social、Developer、Entertainment、Games、Creativity、Utilities、Education、Business、Finance、Other。未知、nil 和未映射值进入 Other。

分类排序使用固定 priority；同一 category 内使用 usage/recency score，最终用 display name、AppID 作为稳定 tie-break。内容变化只更新 category payload，不改变 category card identity。

### Derived metadata store

新增小型 `AppLibraryMetadataStore` actor，使用独立 Application Support 文件和 schemaVersion，不属于 LayoutStore。它只保存:

- `AppID -> launchCount / lastLaunchedAt`
- `AppID -> firstSeen`
- bootstrap marker/version

保存异步、coalesced、atomic。损坏时备份并使用空 metadata，不阻塞 Launcher show；迁移失败保留旧文件。

firstSeen bootstrap 规则:

- 第一次初始化时当前 Catalog 全部 App 作为 baseline，不进入 Recently Added。
- 后续新 AppID 首次进入 Catalog 时记录 now。
- 重启保持时间;移除后同 AppID 回归不重置。
- 无可信 install date 时，Recently Added 使用 firstSeen；无真正新增项时不显示空卡。

Usage 记录统一接入 `LauncherStore.launch` 的中央启动路径。只有 `NSWorkspace.open` 明确返回成功时才记录；记录和落盘不阻塞启动请求。若平台只能证明 request dispatched，必须在代码与测试中明确该语义。

## 4. Derived Model and Session Freeze

纯逻辑 `AppLibraryModelBuilder` 输入 Catalog snapshot、hidden set、当前语言、metadata snapshot 和 Page 1 弱 fallback signal，输出 `AppLibraryModel`:

- Suggestions: 最多 4 个直接启动 App。
- Recently Added: 有真实新增时才生成，使用 firstSeen。
- Category cards: 最多 3 个大图标和最多 4 个 mini icon。
- Category detail payload: 该 category 全量 App，按同一 deterministic ranking 排序。
- card identity: `suggestions`、`recentlyAdded`、`category(categoryID)`，不包含当前 App array。

hidden 和不在 Catalog 的 App 不出现在 Library；tombstone 只由 Layout 继续管理，Library 仅消费当前 Catalog/hidden 的过滤结果。custom source 只要进入 Catalog 就与默认 source App 一样进入 Library。

Launcher show 或进入 Library 时冻结 `AppLibrarySessionModel`。当前 Library session 内后台 Catalog/usage 更新只标记 dirty，不替换用户眼前的卡片顺序；下一次 Library entry 更新。语言切换、明确的重大 Catalog 结构变化可结束 session 并安全重建，但不得逐帧 rebuild。

## 5. AppKit UI

在 LaunchUI 内新增独立 Library 子系统，不把它塞进 Folder:

- `AppLibraryViewController`
- `AppLibraryLayout`
- `AppLibraryCardCell`
- `AppLibraryDetailViewController`
- 小型 `AppLibraryTransitionCoordinator`

Library card 使用独立 bounded responsive layout，目标 2-4 列，card 宽度保持在约 280-430pt territory，并由真实可用内容区调整。使用 AppKit `NSScrollView + NSCollectionView` 虚拟化，图标只请求可见 card/detail item。卡片沿用现有 material、system font、AppCell icon provider 和 backing-scale 语义，但不复用 AppCell 的拖拽/分页耦合。

- 大图标直接 Launch App。
- mini cluster 打开独立 Category detail，不创建 FolderID、不写 Layout。
- Category detail 自己垂直连续滚动，默认 top，不持久化 scroll offset。
- Library 离开到 Page 1 后，同一 Launcher visible session 保留 Library vertical offset；Launcher hide 后下次回 top。
- card/detail 处理 localization、VoiceOver label、Return/Escape、Reduce Motion、Reduce Transparency 和 Increase Contrast。
- backing scale 使用当前 Launcher window/view 的 scale，不使用 `NSScreen.main` 作为布局 truth。

## 6. Ownership and Gesture Arbitration

`LauncherInteractionSurface` 扩展为至少 `.appLibrary` 和 `.appLibraryCategory(...)`，并同步更新所有 click、drag、three-finger、keyboard、scroll、Escape 和 Settings route。前景 surface 必须有唯一 input owner。

Library host 使用一个明确的 scroll router:

- 明显 vertical gesture 交给 Library 内部 vertical scroll。
- 明显 horizontal gesture 交给现有 PagingInteractionController，物理 Page 1 与 Library 之间仍是 1:1 direct manipulation。
- undecided/diagonal 遵循现有 `PagingAxisLock`，锁定后 loser 不得重新抢 owner。
- 不新增第二套相互竞争的 horizontal gesture recognizer。
- category detail 打开后暂停底层 Library scroll、outer paging、root drag、three-finger 和普通 Grid interaction；detail view 消费完整 mouse sequence。
- category detail 的 outside click、Escape 和 stale close completion 不得把同一事件穿透到 Grid、hide Launcher 或释放新的 owner。

Page 1 的现有方向契约保持: 当前代码中 `scrollingDeltaX > 0` 减小 offset、因此从普通 Page 1 向 Library 的方向必须按实际 NSEvent contract 接入，不根据中文“左滑/右滑”重新猜符号。

## 7. Search, Settings, Show/Hide

- Search field、SearchIndex 和结果 UI 继续全局复用，不新增 Library search engine。
- Search enter 保存 `surfaceBeforeSearch`；Library → Search → clear 回 Library，Page N → Search → clear 回 Page N。
- Search 结果必须遵守 hidden/missing 的可见性契约，不能通过 Search 绕过 Library/Launcher 过滤。
- Settings 从 Library 打开仍由 Settings shield 获得完整 ownership；关闭后回 Library，不盲目写回 `.launcher`。
- hide 前关闭 category detail、结束 Library transient session、清理 proxy/scroll ownership；hide/show 最终 physical index 是 1，即 Layout Page 0。
- 不持久化 last surface。

## 8. Motion and Performance

Library ↔ Page 1 优先使用现有 PagingInteractionController、PageSnapAnimator 和 velocity handoff。Category card → detail 使用小型 source-anchored coordinator，复用 MotionEnvironment/MotionTokens 语义、generation guard、invalid-source center fallback 和显式 teardown，不复制 Folder 的数据模型，也不建立 giant AnimationManager。

禁止:

- Library show 触发 full Catalog scan、Info.plist IO 或全量 icon reload。
- 每个 icon completion 重建整个 Library snapshot。
- 每个滚动帧进入 LauncherStore 或 apply Diffable snapshot。
- 进入 Library 预先 rasterize 全部 100/250/500 App icons。

模型 build 必须是 memory-only derived computation。至少记录 100/250/500 App 的 build、card count、visible item 和 scroll content 行为；icon provider 要验证可见项 lazy load、in-flight dedup、reuse 防陈旧。

## 9. Test Gates

必须新增并通过:

- surface mapping: Library/1/3 pages、default Page 1、物理边界和普通 Layout index 不变。
- Geometry/drag: leading offset、普通 slot/frame、Library drop 拒绝、folder-exit index。
- Search: Library restore、Page N restore、hidden/missing 过滤、hide/show。
- Page dots/keyboard: dots 只统计 Layout page，Library 边界按键和 owner gate。
- category classifier: known/nil/unknown/graphics-photo/hidden/custom source。
- ranking: recency、frequency、decay、tie、cold start fallback。
- firstSeen: bootstrap、新 App、restart、remove/reappear、new AppID。
- metadata persistence: schema、corruption backup、atomic/coalesced failure、future version。
- AppLibrary model: stable identity、session freeze、100/250/500 stress。
- gesture arbitration: horizontal/vertical/diagonal/lock/interruption。
- ownership: category detail、outside click、Escape、Settings return、no passthrough。
- motion: source geometry、fallback、Reduce Motion、stale completion、teardown。

现有普通 suites 必须保持绿色。完整工程 build 先修复并验证 E0 已知 `LauncherStore` 初始化阻塞。

## 10. Review and Evidence Gates

动手前必须完成独立只读架构评审，重点是 surface mapping、LayoutStore isolation、paging/drag geometry、Search restore、ownership、metadata actor 和 concurrency。项目定义的 reviewer 为 `mimo-v2.5-pro`；本阶段 Prompt 另要求 Luna max，故两者都执行，不以其中一个权限失败代替 pass。

UI slice 必须产生 fresh self-rendered PNG 或 frame evidence。通用 `cacheDisplay` 截图不作为可靠证据，优先使用 layer render。主对话读取图片做独立复核，再提交 `mimo-v2.5` visual reviewer；视觉结论必须有像素证据。当前环境的真实 CGEvent、screen capture、120 Hz 和 trackpad 仍可能只能标记 `MANUAL_PHYSICAL_GATE`。

最终 gate:

- 所有现有与新增测试通过。
- Debug/Release build 成功。
- fresh binary 用户流程证据: Page 1 → Library、Library top/mid、category detail、Search、Settings。
- reviewer 与 Luna: 0 BLOCKER / 0 MAJOR。
- 视觉结论按 `AUTOMATED_VERIFIED` / `VISUAL_VERIFIED` / `MANUAL_PHYSICAL_GATE` 分开记录。
- 未经用户决定不自动 tag/release。
