# PA1: 交互帧预算减负（Phase A 批次 1）

## 背景

真机遥测基线（`--pagingtelemetry`，2026-08-13）：翻页 settle 帧间隔 avg 17.9ms /
p95 26–33ms（60Hz 名义 16.7ms），存在掉帧。代码审查定位到三处"旁路工作"是
settle 前 3 帧尖刺的主要来源。本任务包只修这三处，不做其他重构。

## 目标（3 个独立可验证单元）

### A1. 遥测 flush 移出 settle 帧回调（测量污染，最先修）

现状：`PagingInteractionController.swift`
- `flushTelemetry`（约 :123-138：map+sort+reduce+字符串拼接）与
  `appendTelemetryLine`（约 :167-176：FileHandle 同步写）在 `finishSettle`（约 :415，
  位于 `animator.onFrame` 回调内 = 最后一个 settle 帧预算里）及打断路径（约 :301）
  被同步调用。

要求：
- flush 改为收敛后的下一个 runloop hop（`DispatchQueue.main.async` 允许；
  全仓库禁 `DispatchQueue.main.sync`）。
- 打断路径同样处理。
- 环形缓冲数据本身仍同步记录（记录是 O(1)，保留）；只有 flush/IO 延后。
- 注意 controller 生命周期：hop 时 self 可能已 shutdown，需 weak 捕获。

### A2. 输入热路径 trace 字符串惰性化

现状：trace 开关关闭时字符串仍然无条件构建：
- `PagingInteractionController.swift:240-243` 每次 scrollWheel 事件拼 NSEvent phase 描述串
- `:391 / :416` settleStart/settleEnd 关闭时仍读 clip bounds + 拼串
- `AppLibraryViewController.swift:906-910` `PausableLibraryScrollView.hitTest` 内
  `LibraryBlankTraceLog.record(...)` 做 `String(describing: type(of:))` 反射——
  hitTest 是所有鼠标/滚轮事件必经点
- `AppLibraryViewController.swift:930-934 / 942-946 / 985-988 / 1113-1116`、
  `AppLibraryCardCell.swift:274-291` 的 `documentFrameSummary()` 等实参无条件求值

要求：
- 首选方案：把 trace/record 函数参数改为 `@autoclosure () -> String`，
  所有调用点自动惰性化，diff 最小。若某调用点跨 actor 边界导致 autoclosure
  不合法，再退化为 `if enabled { ... }` 显式门控。
- 语义不变：开关打开时输出内容与现在完全一致。

### A3. settle 启动旁路减负

现状（三件事在 settle 第一帧之前同步执行，且键盘/dot 路径双份执行）：
1. `GridViewController.swift:1261-1285` `updatePageDots()` 无条件销毁重建全部页点
   （removeFromSuperview 循环 + 每 dot 新建 view/约束/L10n 字符串）。
2. `GridViewController.swift:841-859` `prewarmAdjacentPages` 每次调
   `store.displayModel()`（LauncherStore.swift:340-346 → DisplayModel 全量构建 O(n)），
   再对相邻两页每 app 派生一个 `Task(priority:.utility)`（~70 个堆分配）。
3. 双执行：`navigate(toPhysical:)`（:808-816）与 `goToPage(animated:true)`（:753-767）
   自己先调 updatePageDots+prewarm，随后 `startSettle` 的 `onSettleTargetPage`
   回调（PagingInteractionController.swift:377 → GridViewController.swift:1102-1105
   → applySettledPhysicalPage 尾部 :835-836）又各做一次。

要求：
- 页点增量更新：pageCount 不变时只切换 active 态（保留既有 view 实例）；
  pageCount 变化或语言重建时才全量重建。
- prewarm 去重：同一 (physicalPage, catalogRevision) 组合不重复执行
  （加私有 lastPrewarmedPage/lastPrewarmedRevision 门）。去重后键盘路径的
  双执行自然消除，不需要改调用点结构。
- displayModel 缓存：LauncherStore 增加 revision 键控缓存——revision 未变时
  `displayModel()` 返回缓存的同一值；`bumpRevision()` 处失效。DisplayModel
  是值类型，注意缓存变量放 LauncherStore（@MainActor）内。
- 不改变任何行为语义：页点视觉结果、预热覆盖范围、翻页目标解析全部不变。

## 约束（不可协商）

- Swift 6 严格并发；UI 层 @MainActor；禁止 `DispatchQueue.main.sync`
- 每帧状态不得进入 LauncherStore（displayModel 缓存不是每帧状态，允许）
- 不动 LaunchCore 包
- 遵守现有代码风格（本仓库生产代码用中文注释，简短说明"为什么"）
- 测试命令：
  - `cd Packages/LaunchUI && swift test`（现 339 全绿，必须保持全绿）
  - `cd Packages/LaunchCore && swift test`（不动但跑一遍确认）
  - `xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter build`
- 零新警告

## 新增测试要求

1. A2：断言 trace 关闭时不产生字符串分配不可直接测；改为对
   `LibraryBlankTraceLog.record` / paging trace 的 autoclosure 惰性化做编译级 +
   行为级验证（开启时输出不变）。至少保证现有 trace 相关测试全绿。
2. A3 页点：新增测试——同 pageCount 下连续两次翻页后，页点 view 实例身份
   保持（用 descendant 找 dot view 断言 identity 不变或计数器 seam）。
3. A3 prewarm：seam 计数器断言同一页重复触发只执行一次预热。
4. A3 displayModel 缓存：同 revision 两次调用返回相等模型且源数据未变时
   不重算（可用计算次数计数器 seam）；bump 后失效。

## 返回格式

改动清单（file:line）/ 假设清单 / 测试结果（原样粘贴尾部统计）/ 偏差 /
进度标记 `[PROGRESS]`。

## 明确不做

- 不改 PagingSpring/PageSnapAnimator 数学
- 不动 Library host 挂载时机（那是 Phase B 的 B2）
- 不动拖拽几何缓存（B1）
- 不动设置滑杆（PA2 的 A4）
