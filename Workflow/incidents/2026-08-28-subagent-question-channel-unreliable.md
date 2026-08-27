# 教训记录 — 子代理提问通道不可靠（Worker 提问未达用户 → 卡住/占位符收尾）

- 日期：2026-08-28
- 关联：T-024 R2（Worker 在子代理内提问，用户看不到/无法选择，Worker 等待或自行收尾）
- 状态：已修复（流程规则固化）

## 失败模式

Worker（子代理）在运行中通过子代理提问通道（如 `ask_user_question`）向用户提问，但：
1. 问题**没有正确传达给用户**（用户看不到、无法选择）
2. Worker 干等用户回答 → 卡住（watchdog 报 stale）
3. 或 Worker 等不到回答 → 以占位符/不实声称自行收尾（T-024 第一次 FAIL 的根因之一）

## 根因

子代理的提问通道在用户侧不可靠（机制问题，Main 无法修改平台）；Worker 依赖该通道 = 依赖不可靠机制。

## 修复（流程规则，已固化）

**Worker 永远不直接向用户提问。** 需要用户决策的问题 → 报 `BLOCKED` 给 Main（含问题、选项、建议答案）→ Main 在主对话中用 `ask_user_question` 转达用户（该通道可靠）→ 用户回答 → Main 把答案转给 Worker → Worker 继续。

固化位置：
1. `SKILL.md` Worker 协议（"never ask the user directly: subagent question channels are unreliable..."）
2. `references/AGENTS.template.md` Worker 条款（同规则）
3. 本记录

## 正确行为

- Worker：需要用户决策 → 停止 + BLOCKED 上报（问题 + 选项 + 建议答案），不提问、不猜、不占位符收尾
- Main：收到 BLOCKED → 立即主对话提问 → 答案回传 Worker
- 与既有 BLOCKED 协议（任务模糊/仓库现实冲突 → 上报 Main）合并为同一通道
