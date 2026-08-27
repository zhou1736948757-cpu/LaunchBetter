# LaunchBetter 发布检查清单（RELEASE-CHECKLIST）

> 固化 v0.7.2 发布事故（P0：漏提交生产代码）的验证门。事故记录：
> `Workflow/incidents/2026-08-27-v0.7.2-release.md`
>
> 用法：按顺序执行，逐项打勾；**任何一步失败 → 停止，修复后重来**。
> 发布步骤中 git 命令**禁止 `2>/dev/null` 吞错误**（事故根因 2）；add 失败即停。

## 0. 前置

- [ ] 发布内容已全部 commit：生产代码 + 测试 + `project.pbxproj` 版本号 bump + Workflow 记录
- [ ] 确认本次发布 tag 尚未创建（或为补发场景，tag 已存在但内容需复核）

## 1. 暂存后核对（事故根因 1/3）

```bash
git status --short
git diff --cached --stat
```

- [ ] `git status --short` 无遗漏的 `M`/`??` 生产与测试文件
  - ⚠️ 区分：` M`（前导空格 = **未暂存**）≠ `M `（M 在前 = **已暂存**）—— 事故根因 3
- [ ] `git diff --cached --stat` 逐项核对暂存区，确认包含**全部**预期文件（生产代码、测试、pbxproj、Workflow 记录）
  - ⚠️ `git add` 含不存在 pathspec 会**整体失败**且不暂存任何文件 —— 事故根因 1，必须看 stat 输出而非只信 add 的 exit code

## 2. commit 后复核（事故根因 4）

```bash
git show --stat HEAD
```

- [ ] 复核 commit 内容：文件数、关键文件（生产代码 + 测试 + pbxproj）都在
- [ ] commit message 写明变更内容

## 3. tag 后核对（事故根因 4）

```bash
git ls-tree -r <tag> --name-only
```

- [ ] 关键文件在 tag 上存在：`Packages/LaunchUI/Sources/LaunchUI/`、`Packages/LaunchCore/Sources/`、`Packages/LaunchPlatform/Sources/`、`LaunchBetterApp/`、`LaunchBetter.xcodeproj/project.pbxproj`、对应测试文件
- [ ] 可用 `git ls-tree -r <tag> --name-only | grep <关键文件>` 抽查

## 4. 权威门（事故根因 5）

```bash
scripts/verify-release.sh <tag>
```

- [ ] 输出 **PASS**（6 道门全过：clean → tag → fresh clone → version → Release build → 全量测试）
- [ ] 任一步 FAIL → 修复后重跑，**不得跳过**

## 5. push 后确认

```bash
git ls-remote --tags origin
```

- [ ] `<tag>` 出现在 origin 的 tags 列表中
- [ ] 本地 `git rev-parse --verify <tag>` 与 origin SHA 一致（verify-release.sh 门 2 已自动核对）

## 6. GitHub Release 条目

- [ ] 创建 Release 条目，notes 写明变更（生产代码、测试、Workflow 记录）
- [ ] 附件/链接指向本次 tag 的构建产物（如有）

---

## 事故根因 → 检查项映射

| 根因（v0.7.2 事故） | 本清单检查项 |
|---|---|
| 1. `git add` 含不存在 pathspec 整体失败 | §1 `git diff --cached --stat` 逐项核对 |
| 2. `2>/dev/null` 吞错误 | 全程禁令：发布步骤 git 命令禁止 `2>/dev/null` |
| 3. ` M`（未暂存）误读为已暂存 | §1 `git status --short` 区分 ` M` 与 `M ` |
| 4. 补 add 遗漏文件 | §2 `git show --stat HEAD` + §3 `git ls-tree -r <tag>` |
| 5. 无 fresh-clone 验证 | §4 `scripts/verify-release.sh <tag>` 权威门（fresh clone + Release build + 全量测试） |

## verify-release.sh 白名单说明

门 1（working tree clean）允许以下条目，其余任何 `M/D/A/R/C/??` 一律大声失败：

- **已跟踪文件被修改**（工作流运行时状态，非生产/测试代码，精确路径匹配）：
  `Workflow/STATE.json`、`Workflow/events.jsonl`、`Workflow/heartbeats.json`
- **未跟踪路径**（隐私目录 / 进行中工作流产物 / 验证门自身）：
  `Workflow/evidence/`、`Docs/aegis/`、`Workflow/tasks/`、`Workflow/results/`、
  `Workflow/reviews/`、`Workflow/decisions/`、`Workflow/incidents/`、
  `Workflow/review-bundles/`、`Workflow/watchdog.json`、`Workflow/watchdog-alerts.jsonl`、
  `Scripts/verify-release.sh`（git 报告大小写；文件系统大小写不敏感，
  `scripts/` 与 `Scripts/` 为同一目录）、`Workflow/RELEASE-CHECKLIST.md`

白名单在脚本顶部 `ALLOWED_TRACKED_MODS` / `ALLOWED_UNTRACKED` 数组，可按需调整。
