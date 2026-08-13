# 任务包: Stage E12 分页滑动帧耗时测量(用户实机反馈"一页很多软件时左右滑卡顿")

## 背景

用户实机: 8 列×5 行(40 cells/页)、iconSize 80、壁纸模糊 60、显示标签。
左右滑动(精确触控板手势)在 App 密集页感到卡顿。分页引擎本身
(PagingInteractionController)每帧只写一次 clip.scroll, 状态全在局部; 需要
实测每帧耗时定位是渲染/布局还是引擎问题。

## 允许修改的文件

- `LaunchBetterApp/Diagnostics/PagingScrollProbe.swift`(新增)
- `LaunchBetterApp/Diagnostics/DiagnosticRunner.swift`
- `LaunchBetterApp/ActivationCoordinator.swift`(non-interactive flag 列表)
- `LaunchBetter.xcodeproj/project.pbxproj`(注册新文件)

禁止修改其它文件(尤其生产代码)、提交、切分支、改旧仓库。

## 探针规格 `--pagingscrollprobe`

- 复用现有 seam: `pagingProbeFeed(_:)`、`pagingProbeDisplayFrame()`、
  `pagingProbeDiagnostics()`、`layoutDiagnostics`、`pageTestNext()`、
  `libraryShotNavigateToLibrary()`、`libraryShotWaitSettled()`。
- 流程:
  1. `show()` + 导航到 Library surface, 等 settle。
  2. 预热: 每个 phase 先跑一次不打表的同尺寸手势(让图标/层缓存热起来),
     再跑第二次并测量。
  3. Phase L(Library, 7 张卡片): 测量手势。
  4. `pageTestNext()` 进入普通 Page 1(用户 App 页, ~40 cells), 等 settle,
     再测量同样手势(Phase P)。
- 测量手势: began + 74 个 changed(dx=-20, 精确 delta, 总位移 ~1480pt≈1 页宽
  1470)以 120Hz 间隔驱动;每个 tick:
  `t0 = CACurrentMediaTime(); pagingProbeFeed(event); pagingProbeDisplayFrame();
  window.displayIfNeeded(); dt = CACurrentMediaTime() - t0` 记录 dt。
  changed 结束后 feed ended, 继续驱动 display frame 直到 settle(≤240 帧),
  settle 期间同样记录 dt。
- 输出每 phase: tick 数、avg/p95/max dt(ms)、settle 帧数与耗时、
  `pagingProbeDiagnostics()`、`layoutDiagnostics()`、window backingScaleFactor。
- 合成 NSEvent 参照 PagingProbe.swift 的 makeScroll(相位 rawValue 99/123)。

## 验收

1. Debug build 成功。
2. 运行 `--pagingscrollprobe` 输出两个 phase 的完整数字。
3. 报告: 改动清单、原始输出、你的解读(哪一 phase 更慢、layout prepare/
   attribute 查询计数是否异常)。

## 禁止

- 不修改 PagingInteractionController / GridViewController / AppCellView 等生产文件。
- 不改用户持久化数据。
- 不提交。
