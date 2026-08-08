# Phase 6 — Drag Engine

## Scope

完整拖拽引擎: 输入管道(样本缓冲/帧协调器)、拖拽控制器、CALayer 预览变换、
drop 单次结构更新、文件夹悬停移入、边缘翻页。

## Implementation Summary

- **GestureSampleBuffer(§89)**: NSLock + 仅最新样本 + **会话 token 隔离**
  (旧会话样本不得泄漏到新拖拽)
- **FrameCoordinator(§87/§88)**: 绑定网格视图的 CADisplayLink(跟随显示器刷新率),
  每帧触发;拖拽中静止也持续处理最后样本(边缘悬停翻页可用)
- **DragController(§57)**: 状态机;beginDrag(overlay 建立+coordinator 启动)/
  updateDrag(仅写缓冲)/endDrag(一次 LayoutTransaction.drop → 一次 applyDragDrop →
  一次 Diffable snapshot);**弱引用网格**打破引用环;shutdown() 由窗口控制器
  在 hide 时调用(display link/overlay/回调清理)
- **预览变换**: source 与 gap 之间的直接项 CALayer 平移一个槽位;
  **prepareForReuse 强制 identity**(复用不残留变换)
- **文件夹悬停**: 悬停文件夹 → overlay 变绿提示"放入 xxx",drop 走 addToFolder
- **边缘翻页**: 60pt 边缘阈值,0.4s 节流,静止悬停持续触发
- **ClickableCollectionView**: 单击(无拖动)→ launch;5pt 阈值 → 拖拽
- 每帧状态仅存在于 sample buffer / coordinator / layer 呈现(§60)

## Important Files

- Packages/LaunchUI/Sources/LaunchUI/{GestureSampleBuffer,FrameCoordinator,DragController,ClickableCollectionView,GridViewController}.swift
- AppCellView(复用复位)、LauncherWindowController(拖拽接线+shutdown)

## Tests

162 基础测试全绿(本阶段为 UI 交互,单元覆盖经真实代码路径冒烟):
- `--dragtest`: beginDrag → updateDrag×20 → endDrag → 布局顺序实际改变并持久化
  (changed=true, 87 项守恒)
- 冒烟回归: 搜索/启动/文件夹流程不受影响

## Build Results

- 两包 swift test 全绿;xcodebuild Debug SUCCEEDED;--smoke/--dragtest 通过

## Performance Results

- 预览路径仅 CALayer 变换 + 快照只读(不 apply),符合 spike 结论(纯 layer 变换零开销)
- 120Hz 帧预算验证仍受限于本机 60Hz 显示器(Phase 1B 记录)

## Review Results

- **Luna Max 代码评审(拖拽引擎)**: 0 BLOCKER / 4 MAJOR / 3 MINOR / 4 NOTE / 多项 PASS
- **4 MAJOR 全部修复**:
  - M1 边缘翻页静止不持续 → 每帧处理最后样本
  - M2 样本会话隔离 → buffer 会话 token
  - M3 复用 cell 变换残留 → prepareForReuse 复位 identity
  - M4 引用环/display link 生命周期 → 弱引用 + 窗口控制器持有 + hide 时 shutdown
- **3 MINOR 全部修复**: overlay 标签/位置统一更新、节流时间会话重置、
  preview nil 时 overlay 仍移动
- **Luna 视觉评审(截图)**: 0 BLOCKER / 0 MAJOR(两行标签修复后)/ 2 MINOR
  (词断裂换行、阴影偏弱,记录 Phase 9)

## Architecture Deviations

- 无。D 管道(§58)严格成立: 输入 → 样本缓冲 → CADisplayLink → FrameCoordinator → CALayer
- NOTE 记录: flatIndex 为实际 item 索引(紧凑分页下与槽位一致);快照只读不 apply

## Known Limitations

- 本机 60Hz,120Hz 帧时间无法实测(Phase 1B 记录)
- 键盘拖拽/触控板拖拽未实现(Phase 8 手势激活后评估)

## Commit Range

TBD(Phase 6 提交)

## Remaining Risks

- 无阻塞项。

## Next

Phase 7 — FSEvents Incremental Catalog:
DirectoryMonitor(FSEvents)、scope 监控、.app root 折叠、debounce、scoped reconcile、
事件丢失恢复;安装/删除/更新/重命名/临时替换/事件风暴验证。
