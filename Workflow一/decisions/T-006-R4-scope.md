# Decision: T-006-R4 范围冲突 — 保留 PageVisual prepare debounce

## Context
T-006-R4 Reviewer 将 `Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift:1768` 的 `Task.sleep(nanoseconds: 100_000_000)` 判为“相关 compositor sleep”。

## Chief Decision
保留该 `Task.sleep(100ms)`，不将其视为本任务失败。

## Evidence
- 该 sleep 位于 `performWorkingSetPrepare` 的 PageVisual prepare debounce/idle 调度路径，不在 telemetry formatter、DisplayLink final-frame formatting、或测试辅助函数中。
- 用户原始 Prompt 明确要求继续使用已有 `100ms debounce/idle` 机制，除非测量证明需要调整；本任务不得无证据改变它。
- T-006-R3/R4 的真正证据问题是测试中的 sleep-based proof；相关 telemetry、compositor integration、paging interruption 测试已改为 deterministic formatter/clock seam。
- 删除该生产 debounce 会扩大范围并违反“不得同步页面光栅化/保留已有 prepare 调度”的约束。

## Scope Resolution
- 必须无 sleep-based timing proof 的范围：telemetry formatter tests、flag behavior tests、直接相关 paging/compositor test helpers。
- 允许且必须保留的生产调度：已有 PageVisual prepare 100ms debounce/idle sleep。
- 不修改该生产 sleep，不修改 T-005 坐标修复或 T-006 其它生产行为。

## Next Action
请求最终 Reviewer 按上述用户原始约束复核；不再创建删除 prepare debounce 的 repair task。

## Status
Chief decision recorded; MANUAL_PHYSICAL_GATE remains open.