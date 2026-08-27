# Chief 决策记录 — Paging Performance Telemetry（B+ Phase 1）

- 日期：2026-08-28
- 决策人：Chief / Main（工程决策已定，本记录为落盘）
- 关联任务：T-027

## 已决定

- **不**立即重写 `NSCollectionView` / `NSScrollView` / `NSClipView`；
- **不**把 LaunchBetter 改成 BuhoRebuild 风格的自定义 pager；
- **不**在本任务中改：
  - axis lock；
  - `followSensitivity`；
  - follow curve；
  - displacement clamp；
  - fling threshold；
  - `PagingSpring`；
  - settle 曲线；
  - `advanceRealClipBehindCover()` 的 35% 策略；
  - compositor page-boundary activation gate；
  - `PageVisualCache` 总体策略。
- 本任务只加入**默认关闭**的性能观测能力与确定性测试（`--paging-perf`）。
- 后续是否调手感、是否调 compositor、是否重写容器，**必须由真实 profile 和真实触控板结果决定**。

## 源码证据背景（已审计事实，无需重复完整审计）

- `PagingInteractionController.swift`：默认跟手 linear 1.3；位移钳制 ±1 page；momentum event 被消费；display link 驱动 applyScroll。
- `GridViewController.swift`：live path 写 NSClipView.scroll(to:)；compositor tracking 移动 layer；compositor settling 经 advanceRealClipBehindCover() 让真实 clip 追赶；teardown sync clip，active 时 layoutSubtreeIfNeeded()。
- `PagingGridLayout.swift`：仅可视尺寸变化时 layout invalidation 为 true；已存在部分 prepare/query counters。
- `PageCompositor.swift`：已存在部分默认关闭 metrics。

## 决策边界

- 本任务产出 = 证据采集能力（telemetry），**不是**性能修复；
- 自动化仅证明插桩接线，**不证明**真实触控板性能或手感；
- 真实设备采集与单变量 A/B 是下一阶段（T-029+），不是本任务。

## 追加（2026-08-28，T-027 FAIL #1 裁定 R2）

**问题**：①跨 suite 污染（全局 recorder + 并行 suite）；②离散滚轮打断在途 settle 吞数据；③catch-up 零断言。

**裁定（R2 三修）**：
- ① 隔离：defer 清空不足（污染在测试期间发生）→ (a) configure 后立即 defer 清空 + (b) 断言按 `pagingSessionSummary` 事件类型过滤（idle 污染是独立类型，过滤后断言语义不变且确定）；不做生产侧根本隔离（全局 recorder 对生产 `--paging-perf` 是正确设计）
- ② 生命周期：recorder 侧修 `beginSessionIfNeeded` —— `activeSession == nil || activeSession?.outcome != nil` 时走 beginSession（已收口未 emit 的 session 重建）；一次修复 interrupted/settled/cancelled 三变体；PagingInteractionController 零改动（T-013 安全）；测试断言 S1(interrupted)+S2(settled) 双摘要
- ③ catch-up 断言：真实路径优先；无法确定性触发则 recorder 级单元测试兜底（须如实注明覆盖路径）
- **确定性门**：两 grid 测试无 filter 全量下 ×10 全绿 + 全量 1 次，输出记录进结果文件（污染修复单次绿不算数）
- 复审：同一 Reviewer（按验收标准评估，非对照建议）
- 文件边界：仅 PagingPerfTelemetry.swift + PagingPerfTelemetryTests.swift
