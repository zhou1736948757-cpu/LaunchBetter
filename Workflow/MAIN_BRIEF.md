# Main Orchestrator Brief

> Chief 正式化版本（2026-08-26）。此前为占位（"Pending Initial Chief Planning"）。

## Current Mission

**T-017：修复 PageCompositor 镜像 bug**（用户已确认的开发目标）。

- 根因（T-016 已定位，Reviewer 独立实验证实）：
  `Packages/LaunchUI/Sources/LaunchUI/PageCompositor.swift:191`
  `layer.isGeometryFlipped = true` → CALayer 垂直翻转 contents 渲染。
  现象：compositor ON 时滑动中图标+名字上下镜像（位置不变），停稳恢复
  （teardown 恢复 live 层）；live 路径（AppCellView.iconLayer）非 flipped 正常；
  activate 时 `liveLayer.opacity = 0`（:201）→ 用户只见镜像合成层。
- **Chief 方案决策：方案 A —— 移除 `isGeometryFlipped = true`（一行）**。
  备选 B（保留 flipped + `contentsTransform` 补偿）仅当 A 被证明破坏隐藏依赖时
  回退；方案 C（rasterize 改 y-up）拒绝。切换方案必须经 Chief。
- 必须补齐测试缺口：新增合成层方向测试（走真实 `PageCompositor.activate`
  路径 + `render(in:)` 像素断言，修复前应失败、修复后通过）。
- 120Hz 物理验收为 follow-up（不在本任务）；`MANUAL_PHYSICAL_GATE` 保持
  `OPEN / REQUIRED`。

## Execution Starting Point

- 语义依赖已满足：T-016 根因证据已闭合（Reviewer 独立实验证实，评审 PASS）；
  T-013 保护条件为基线。T-016 的 BLOCKED 状态（120Hz 无硬件）不阻塞 T-017。
- 基线：HEAD == origin/main == cb180e4（v0.7.0）；worktree 仅 Workflow 记录
  文件 dirty（MEMORY.md/STATE.json/events.jsonl/heartbeats.json），无生产改动。
- 测试基线：LaunchUI 470/66、LaunchCore 200/16、LaunchPlatform 149/23、
  GridIntegration 33/33（`swift test --package-path Packages/<pkg>`）。
- 建议执行顺序（Main 决定运行时细节）：Worker 实现（删 1 行 + 新增方向测试）
  → 定向测试 → 全量回归 → 用户交互验证（60Hz，compositor ON 变体）→
  Reviewer 独立评审 → 收口。
- 完整任务包：`Workflow/tasks/T-017.md`；计划：`Workflow/PLAN.md`。

## Runtime Authority

Main owns runtime dispatch, concurrency, retries, evidence collection, state
maintenance, and bounded adaptations inside the accepted plan.

## Do Not Decide Without Chief

- **方案 A/B/C 切换**（含 B 回退触发；A 失败时先收集证据再升级，不得自行改 B）。
- **验收标准放宽**（任何形式，包括"方向测试可跳过"或"回归可部分豁免"）。
- 修改 T-013 保护条件或对其重新解释。
- 修改 rasterize 坐标系 / PageVisual 契约 / 公开 API。
- 创建 T-018（120Hz 物理验收重开）或关闭/重开 `MANUAL_PHYSICAL_GATE`。
- 改变任务目标语义（如把"修复镜像"扩大为"重构 compositor"）。
- 任何 commit/push/tag/release 授权（默认禁止）。

## Reviewer Failure Policy

A formal Reviewer `FAIL` is the only event that increments `worker_failures`.

- FAIL #1 → Main sends an escalation packet to Chief for a Decision Delta.
- FAIL #2 → Main dispatches an isolated Expert Worker by default.
- If FAIL #2 contains explicit plan-level evidence, Main routes it to Chief instead.
- If an Expert Worker is reviewed and receives `FAIL`, Main routes the result to Chief.

## Worker Failure Policy

Worker Failure means a formal Reviewer `FAIL`.

Ordinary Worker test failures, shell errors, tool errors, timeouts, and
self-repaired implementation mistakes do not increment `worker_failures`.

At `worker_failures >= 2`, prefer Expert Worker unless explicit evidence
indicates that the accepted plan itself needs reinterpretation or change.

## Important Invariants

- `PagingInteractionController` 保持唯一 paging 运动写入者；`PageCompositor`
  仅 presentation。
- 不改 spring/stiffness/damping/fling 阈值/rubber-band/settle 时长/默认
  linear 1.3/normalizedDamped 默认/compositor 激活条件/100ms prepare
  debounce/`advanceRealClipBehindCover()`。
- 不改公开 API；不新增第二条 offset writer。
- 不得用 sleep 掩盖；不得用 `max(0, count)` 掩盖。
- 不删除历史 FAIL 记录；不 commit/push/tag/release。
- 修复范围：仅 `PageCompositor.swift`（191 行）与相关测试文件。

## Escalation Guidance

- Worker 发现方案 A 在真实测试中产生位置偏移/方向仍错/隐藏依赖破坏 →
  停止实现，写复现证据，报 Main → Main 升级 Chief（不得自行切 B）。
- 方向测试在修复后仍失败 → 同上，先给证据再升级。
- 交互验证发现新缺陷（非镜像）→ 记录证据，报 Main；是否扩任务由 Chief 定。
- 120Hz 设备出现 → 记录，报 Main；T-018 创建由 Chief 定。

## Relevant Artifact Map

See `PLAN.md`, `MEMORY.md`, `STATE.json`, `tasks/`, `results/`, `reviews/`,
`review-bundles/`, `decisions/`, and `events.jsonl` under `Workflow/`.

关键证据：`Workflow/evidence/T-016/analysis/calayer-flip-experiment.swift`
（Reviewer 独立实验）、`Workflow/evidence/T-016/analysis/phase2-analysis.md`
（根因定位 §3）、`Workflow/results/T-016.md`、`Workflow/tasks/T-013.md`
（保护条件 §141）。
