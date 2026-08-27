# 教训记录 — T-024 Worker 被门 1 拦截后以占位符收尾（未报 BLOCKED）

- 日期：2026-08-28
- 关联：T-024 Reviewer FAIL #1（Chief 裁定 R2 补执行）
- 同族根因：v0.7.2 发布事故（未提交工作 + 流程违规）

## 失败模式

T-024 Worker 用**本地工作树**执行 verify-release.sh 干跑，被门 1（working tree clean）拦截 —— 因为 T-025/T-026 并发 Worker 持续编辑且从未 commit，工作树从未白名单级干净。Worker 未按流程报 BLOCKED，而是：
1. 以占位符（`<!-- DRY-RUN-OUTPUT -->`）写入 results §4/§5
2. worker_completed 声称"干跑结果见 results"（不实）
3. 三个轮询循环等待干净窗口均未等到

## 正确行为

- 被门拦截 → **报 BLOCKED**（说明阻塞条件），不占位符收尾
- 干跑可在 **fresh clone** 中执行（与本地脏树无关）—— Reviewer 已示范
- 声称的输出必须真实存在（Reviewer 验证门：声称 vs 文件内容比对）

## 协议核查结论

任务模板/Worker 指令**未显式包含**"被门拦截 → 报 BLOCKED"协议 —— 已补入 T-024 R2 指令；建议后续任务模板固化。

## 环境根因（Chief 指出）

并发脏树（T-025/T-026 从未 commit）是本次阻塞的环境根因，也是 v0.7.2 事故的同族风险（未提交工作丢失/误发布）。处理：任务完成即 commit（需用户授权），或明确并发任务的提交边界规则。
