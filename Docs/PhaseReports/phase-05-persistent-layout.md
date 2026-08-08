# Phase 5 — Persistent Layout / Folder System

## Scope

布局持久化与文件夹系统: LayoutEditor(显示→布局空间映射)、LayoutSnapshotStore、
LayoutStore(actor)、应用接入(LauncherStore 缓存 + 上下文菜单 + 文件夹视图)、
重启持久性验证。

## Implementation Summary

- **LaunchCore — LayoutEditor(纯逻辑)**: Phase 1C 推迟的契约落地 —
  LayoutTransaction 在显示空间计算变更,LayoutEditor 映射回布局空间,
  **隐藏/缺失应用保持布局原位**(锚点映射,不挪动不可见项):
  - `apply`: reorder(目标 = 移除源项后的 gap 位置,锚点前插,越界追加,
    按容量重分块)/ addToFolder(可见子项定位插入,隐藏子项保持原位)/
    moveOutOfFolder / renameFolder
  - `createFolder`: ≥1 应用(UX 支持单应用新建),文件夹出现在最早应用位置
  - `dissolveFolder`: children 插回原显示位置
  - DisplayModel 补充 hiddenAppIDs/missingAppIDs 派生输入
- **LaunchPlatform**: LayoutSnapshotStore(原子写/损坏备份);
  LayoutStore(actor): start(磁盘权威,缺失/损坏保留种子布局)、reconcile、
  apply/createFolder/dissolveFolder/renameFolder,每次变更原子持久化,
  持久化失败不阻断内存操作
- **应用接入**: LauncherStore 持有 LayoutStore + MainActor 缓存(§62 模式),
  文件夹操作异步经 actor 应用并同步缓存;修复关键 bug:
  **applySnapshot 在布局无变化时跳过 store 同步,导致 store 停在空种子** —
  改为始终同步(幂等),文件夹操作不再在空布局上执行
- **UI**: 单元格右键菜单(加入文件夹▸/新建文件夹/重命名…/解散文件夹)、
  文件夹视图(点击打开,返回按钮,子项网格可点击启动)、名称输入 NSAlert
- **冒烟(--folders)**: 创建(87→86)→重命名→加入(86→85)→解散(85→87)
  槽位守恒;重启持久性: 布局文件 3 页/87 项,二次启动正确加载

## Important Files

- Packages/LaunchCore: LayoutEditor.swift + DisplayModel/LayoutSnapshot 扩展
- Packages/LaunchPlatform: LayoutSnapshotStore.swift + LayoutStore.swift
- LaunchBetterApp: LauncherStore.swift(布局接入)
- Packages/LaunchUI: ClickableCollectionView + FolderViewController + GridViewController(菜单)
- Tests: LaunchCore LayoutEditorTests(14)、LaunchPlatform LayoutStoreTests(6)

## Tests

162 通过(LaunchCore 96 + LaunchPlatform 66):
LayoutEditor: reorder 隐藏保持原位/越界/跨页分块/无效、addToFolder 隐藏子项
原位/clamp/已在文件夹内、moveOutOfFolder、rename、createFolder(≥1/无效)、
dissolve(未知/不在显示)、确定性。
LayoutStore: 持久化往返、损坏备份、启动恢复+变更持久化+重启、无效 mutation、
文件夹操作持久化。

## Build Results

- 两包 swift test 全绿;xcodebuild Debug SUCCEEDED
- 冒烟: --folders 全链路 + 重启持久性验证通过
- 发现并修复 3 个 bug: applySnapshot 跳过 store 同步、冒烟主线程信号量死锁、
  createFolder 早期 ≥2 限制与 UX 不符

## Performance Results

无新增测量;布局变更路径为低频(用户操作),无性能压力。

## Review Results

- Luna 视觉评审(Phase 5 截图): 见 /tmp/review-p5.log, 结论摘入提交
- 自查评审: 发现并修复上述 3 个 bug

## Architecture Deviations

- createFolder 允许 ≥1 应用(文档未规定下限;legacy 合并 2 个,UX 允许单应用新建)
- LayoutStore 使用"磁盘权威 + 种子保留"启动语义(与文档 §47 墓碑精神一致)

## Known Limitations

- 文件夹内拖拽排序(展开视图中重排)属 Phase 6 Drag Engine
- 拖入/拖出文件夹的拖拽交互属 Phase 6(当前经上下文菜单)

## Commit Range

TBD(Phase 5 提交)

## Remaining Risks

- 无阻塞项。

## Next

Phase 6 — Drag Engine:
DragController/DragOverlay/FrameCoordinator/CADisplayLink/GestureSampleBuffer +
LayoutTransaction 集成;高频路径只做 layer 变换;drop 一次布局变更。
120Hz 测量(60Hz 显示器局限记录)。GLM/Luna 评审。
