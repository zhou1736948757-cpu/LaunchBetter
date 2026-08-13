# 任务包: Stage E App Library Architecture Gate

## 背景

LaunchBetter 当前 HEAD 为 `e48d954c10871d1de24ec406d962dfea8a9cb3b2`，目标是在所有普通 Layout page 左侧增加 derived App Library special surface。E0 已完成当前源码审计，设计稿位于 `Docs/Architecture/0002-app-library-surface.md`。

已知基线:

- LaunchCore 87、LaunchPlatform 127、LaunchUI 196 测试通过。
- 完整工程 Debug build 目前被既存 `LauncherStore.init` 初始化顺序错误阻塞。
- 当前 Search 从普通第 2 页退出会在搜索态 pageCount=1 时错误回到第 0 页。
- 当前 worktree 已有用户未跟踪 `Docs/Visual/*` 与 `work/`，禁止碰触。

## 评审材料

- `AGENTS.md`
- `MEMORY.md`
- `Docs/Architecture/0001-module-boundaries.md`
- `Docs/Architecture/0002-app-library-surface.md`
- 当前源码与测试，尤其是 `GridViewController`、`PagingGridLayout`、`PagingInteractionController`、`DragController`、`LauncherWindowController`、`LauncherInteractionOwnership`、`LauncherStore`、`AppRecord`、`AppDiscoveryService`、`LayoutStore`。

## 允许修改的文件

- 无。只读评审，禁止编辑、提交和生成生产补丁。

## 评审重点

1. `LauncherSurface` 与 physical/semantic mapping 是否能保持默认 Page 1、普通 page index、drag destination 和 LayoutStore isolation。
2. leading section 方案是否比负 offset、Layout sentinel、第二套 paging engine 更安全。
3. `PagingGridLayout`、`GridGeometry`、`DragController`、folder-exit、page dots 的坐标和 index contract 是否完整。
4. Library 嵌套 vertical `NSCollectionView` 与 outer horizontal paging 的 axis arbitration 是否可实现且不引入第二套竞争状态机。
5. Search 的 `surfaceBeforeSearch`、hidden/missing 过滤、Settings return、hide/show 默认页语义。
6. `AppRecord.categoryIdentifier`、Catalog schema upgrade、`AppLibraryMetadataStore` 的职责、迁移和 actor freshness。
7. Usage/firstSeen bootstrap、中央 launch recording、session snapshot、stable diffable identity。
8. Category detail ownership、outside click、Escape、stale completion、Motion reuse、Reduce Motion、lazy icon loading。
9. 已知完整工程 build 阻塞是否应先单独修复，以及是否存在遗漏的 Stage E blocker。

## 输出格式

必须分类输出 `BLOCKER / MAJOR / MINOR / NOTE / PASS`。

每个 BLOCKER/MAJOR 必须包含:

- file
- symbol/area
- failure mechanism
- why it matters
- minimum corrective action
- test that should catch it

如果方案通过，明确列出 PASS 的设计条款与尚未验证的实现假设。禁止根据旧版本或 MEMORY 猜测，冲突以当前源码和测试为准。
