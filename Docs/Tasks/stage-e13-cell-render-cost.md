# 任务包: Stage E13 cell 渲染成本优化 + 真机帧耗时遥测

## 背景(实测二分结论)

用户实机: 8 列×5 行(40 cells/页)时左右滑卡顿; 改 6 列后明显消失 →
每帧成本与每页可见 cell 数量成正比。分页引擎已实测无罪
(手势 762/768ms、settle 39/38 帧、每帧一次滚动写, 与密度无关)。
headless 环境测不到合成/栅格成本, 需要真机数据 + 针对性降成本。

## 允许修改的文件

- `Packages/LaunchUI/Sources/LaunchUI/AppCellView.swift`
- `Packages/LaunchUI/Sources/LaunchUI/PagingInteractionController.swift`(仅遥测)
- `Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift`(仅遥测开关接线)
- `LaunchBetterApp/Diagnostics/DiagnosticRunner.swift` / `LaunchBetterApp/AppDelegate.swift` / `LaunchBetterApp/ActivationCoordinator.swift`(仅 `--pagingtelemetry` 分支, 该 flag 保持交互式, 不进 non-interactive 列表)
- `Packages/LaunchUI/Tests/LaunchUITests/`(如需更新断言)

禁止修改其它文件、提交、切分支、改旧仓库、改用户持久化数据。

## 优化 1: 图标遮罩按需开启(AppCellView)

现状: `iconLayer.cornerRadius = 16; iconLayer.masksToBounds = true` 恒开,
40 个 offscreen mask/帧。macOS 真实图标(ICNS/NSWorkspace)自带圆角 alpha,
遮罩是冗余的。

改法:
- 占位符状态(backgroundColor 色块 + letterLayer)与建夹高亮
  (`setCreateFolderTargetHighlighted` 非 none)期间: `masksToBounds = true`。
- 真实图标应用成功后: `masksToBounds = false`(cornerRadius 保留, 供
  `transitionSourceCornerRadius` 语义)。
- `prepareForReuse` 恢复占位状态时回到 `masksToBounds = true`。
- 视觉语义不变: 真实图标本身已圆角; 占位/高亮仍圆角。

## 优化 2(遥测, 不改行为)

`PagingInteractionController`:
- `telemetryEnabled` 开关(默认 false, 零开销路径不变)。
- `displayTick()` 中当 enabled: 记录相邻 tick 的
  `CACurrentMediaTime()` 间隔到环形缓冲(容量 512, 追加 O(1));
  每次手势结束(endGesture/finishSettle 后)把当前缓冲写成一行到
  `/tmp/lb-paging-telemetry.log`: 帧数、avg/p95/max ms、phase。
- `--pagingtelemetry`: 应用以正常交互方式运行(非 non-interactive),
  启动时经 AppDelegate/DiagnosticRunner 分支只设置 `telemetryEnabled = true`,
  不做任何其它事、不退出。

## 必做验证

1. `cd Packages/LaunchUI && swift test` 全绿(如有断言引用 masksToBounds 则更新)。
2. Debug build 成功。
3. `--libraryshot top` 与 `--pagingscrollprobe` 仍能跑(回归)。
4. 报告: 改动清单、测试结果、偏差。

## 禁止

- 不碰 PressDragPresentation/DragController/PageSnapAnimator。
- 不提交。
