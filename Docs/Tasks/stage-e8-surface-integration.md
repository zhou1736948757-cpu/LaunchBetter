# 任务包: Stage E8 leading App Library surface integration

## 背景

当前已验证:

- `LauncherSurface` / `LauncherSurfaceIndex`
- `PagingGridLayout.leadingSurfaceEnabled`
- 独立 `AppLibraryViewController` 与 `AppLibraryDataProviding`
- 普通 Grid/Paging/Drag/Search suites 全绿

现在把 Library 作为外层 collection view 的 physical section 0 接入 `GridViewController`。这是高风险分页/坐标任务，必须保持普通 Layout page/Drag API 语义。

## 允许修改的文件

- `Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryViewController.swift` (只允许增加 session 生命周期窄 API)
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryHostItem.swift` (新增)
- `Packages/LaunchUI/Tests/LaunchUITests/AppLibrarySurfaceNavigationTests.swift` (新增)

必要时可在 `Packages/LaunchUI/Tests/LaunchUITests/PagingOffsetOwnershipTests.swift` 增加与 physical page count 相关断言，但不得修改其它生产文件。

禁止修改 `LauncherWindowController`、`DragController`、`PagingGridLayout`、LaunchCore、LaunchPlatform、旧仓库和现有未跟踪文件；不提交、不切换分支。

## Data source contract

保持现有内部 `typealias Item = DisplayModel.DisplayItem`，避免 Folder/Drag/diagnostic 调用方被 wrapper 污染。新增内部 wrapper:

```swift
enum LauncherSurfaceItem: Hashable {
    case appLibrary
    case layout(DisplayModel.DisplayItem)
}
```

外层 diffable data source 使用 wrapper:

- paged mode snapshot section 0: `[.appLibrary]`
- paged normal page n: physical section n+1，items `[.layout(item)]`
- search mode: leading disabled，单 section 0，items `[.layout(result)]`

新增 `AppLibraryHostItem` 承载 `AppLibraryViewController`，从 `store as? any AppLibraryDataProviding` 获取 model，从 LauncherStoring 获取 displayName/launch，使用已有 iconProvider。Host item 不产生 AppCell/Drag identity。

`AppLibraryViewController` 增加 `endSession()` 或等价窄 API，host reuse/Launcher hide 时释放冻结 model；不得把 model 写入 Layout。

## Paging / semantic contract

- `pageCount` 继续表示普通 Layout page count，至少 1。
- 新增 `physicalSurfaceIndex`，初始值为 1，即 `.layoutPage(0)`。
- `currentPageValue` 对外继续返回普通 Layout page index；Library active 时返回安全的 0，DragController 不得把 Library 当普通页。
- `pageCountValue` 继续返回普通 Layout page count；新增 physical diagnostics/API 供 paging engine 使用。
- PagingInteractionController 的 `onReadPageCount` 返回 `LauncherSurfaceIndex(layoutPageCount: pageCount).physicalSurfaceCount`。
- `onSettleTargetPage` 接收 physical index，更新 physical state、semantic current page、page dots 和普通页 prewarm；Library 不 prewarm ordinary icons。
- `goToPage(n)` 仍表示用户 Layout page n，内部映射为 physical n+1；`nextPage/previousPage` 沿 physical surface 走，因此 Page1 previous → Library，Library next → Page1。
- `hide()` 现有调用 `goToPage(0)` 必须仍回 physical 1，不得改成 Library。
- paged snapshot/apply 后默认 surface 保持 Page1/物理 1，除非当前已明确处于 Library。

## Search contract

- 进入 Search 前保存 `LauncherSurface`，不是 raw page number。
- Search mode 关闭 leading section、使用 physical page 0 的既有 vertical search layout。
- Library → Search → clear 恢复 Library；Page N → Search → clear 恢复 Page N。
- 现有 Search page restore 测试必须继续通过。
- page dots 使用普通 `pageCount`，Library active 或 Search active 不显示普通 dot。

## Coordinate / Drag contract

普通 `GridGeometry` 仍是 local Layout page math:

- `flatIndex/indexPath` 只对普通 display items，paged indexPath section 返回 normal page + 1；search 返回 section 0。
- `cachedItem/itemAt/hoveredFolder/dragRepresentation/folderTransitionSource` 遇 physical section 0 必须返回 nil/host 语义，不把 Library 当 AppCell。
- `frame(atFlatIndex:)`、`overlayFrame` 返回 document frame 时加一个 leading `pageWidth`。
- `dragDestination(from:)` 将 document x 减 leading `pageWidth` 后再交给 GridGeometry，得到普通 Layout page/slot；Library active 或点中 physical page 0 时 drop 必须拒绝/走明确 no-op，不得写 Layout。
- `currentPageRect` 普通页 frame 要包含 leading document offset；Library active 时 drag edge path 不得启动。
- `allItems()` 继续只返回普通 `DisplayModel.DisplayItem`，保持 LauncherWindowController diagnostics/folder open 调用不变。
- `pageTestDocumentWidth`/`scrollDiagnostics` 区分 ordinary page count 与 physical document width；新增 tests 锁定 physical width = (ordinary pages + 1) × pageWidth。

## Interaction boundary

本任务只把 host 嵌入并保证普通 Grid drag 不命中 host；完整 `.appLibrary` ownership、vertical/horizontal axis router、Settings return、category detail owner 在后续 E9。可以在 Library active 时先拒绝 ordinary drag/three-finger，但不得为此新增第二套 paging engine。

## 必写测试

- 1/3 ordinary pages 的 snapshot section ordering: Library 0, Page0 1, Page1 2...
- 初始/default surface physical 1；`goToPage(0)` offset 是 pageWidth，不是 0。
- `goToPage(2)` 返回 semantic 2、physical 3；previous Page0 进入 Library，next Library 回 Page0。
- Paging engine page count 使用 physical count；document width physical count × pageWidth。
- Page dots count 只等于 ordinary page count，Library 不占 dot。
- Search from Library/Page2 restore 对应 semantic surface。
- ordinary frame/flatIndex/drag destination 在 leading offset 下映射不偏一页；Library host 不是 drop target。
- ordinary Folder/App `allItems`/hit-test/drag representation 回归。
- no LayoutSnapshot/LayoutStore/AppRecord page mutation。

## 验收

- `cd Packages/LaunchCore && swift test` 通过。
- `cd Packages/LaunchPlatform && swift test` 通过。
- `cd Packages/LaunchUI && swift test` 通过。
- `xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter build` 通过。
- `DispatchQueue.main.sync` 仍为 0。
- 返回 physical/semantic mapping、坐标审计、测试结果、偏差和未决问题；每一步用 `[PROGRESS]`。
