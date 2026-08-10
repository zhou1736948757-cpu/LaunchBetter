# 任务包 A1: FSEvents/持久化重试 capped backoff

## 背景
LaunchBetter v0.2.3(Prompt Stage A §A1)。`LauncherStore.drainExternalCatalogRefreshes()`
在布局持久化失败时用固定 250ms 无限重试(LaunchBetterApp/LauncherStore.swift:415
`Task.sleep(for: .milliseconds(250))`)。持久失败(磁盘满/权限/损坏保护写阻塞)时会造成
持续 wakeup。需替换为确定性 capped backoff。

## 允许修改的文件(禁止范围外)
- Packages/LaunchCore/Sources/LaunchCore/RetryBackoff.swift(新, 纯逻辑)
- Packages/LaunchCore/Tests/LaunchCoreTests/RetryBackoffTests.swift(新)
- LaunchBetterApp/LauncherStore.swift(drainExternalCatalogRefreshes 接线; 禁止改其他逻辑)

## 设计
LaunchCore 新增纯逻辑 `RetryBackoff`:
- 延迟序列 [250ms, 1s, 4s, 15s, 30s](到达序列尾后停留在 cap 30s)
- `nextDelayMilliseconds() -> Int`(每次调用推进; 到 cap 后保持)
- `reset()`(成功 commit 或新的文件系统活动时调用 → 回到 250ms)
- 无 sleep; 纯调度值计算, 可测

LauncherStore 接线:
- 循环内失败分支: `try await Task.sleep(for: .milliseconds(retry.nextDelayMilliseconds()))`
- 成功 commit(或捕获到新 pending 事件): `retry.reset()`
- 取消/退出: Task.sleep catch → break(现状保留)

## 约束
- LaunchCore 禁止 AppKit/SwiftUI/Combine/FileManager; 纯 Foundation
- 不改变 durable-before-publish 语义(持久化失败不得提前发布 UI 状态)
- 不改变 catalogDidChangeExternally 的合并/任务生命周期
- 无 busy loop、无 lost pending event、无 stale publication

## 验收标准
1. RetryBackoff 序列 = [250, 1000, 4000, 15000, 30000]; 超尾后保持 30000
2. reset() 回到 250
3. drainExternalCatalogRefreshes 使用 RetryBackoff(不再硬编码 250)
4. 成功 commit 后 reset(下次失败从 250 开始)
5. LaunchCore swift test 全绿(含新增)
6. xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter build 成功

## 必写测试(LaunchCoreTests/RetryBackoffTests.swift)
- 序列推进到 cap
- cap 后保持
- reset 后重新开始
- 空/单元素序列边界(防御)

## 禁止
- 不修改 LaunchBetterApp/LauncherStore.swift 中 drain 之外的部分
- 不提交 git、不切换分支
- 不改 /Users/mac/Projects/Launchpad_Back
- 不引入新依赖

## 输出要求
改动文件清单 / 技术假设清单 / build+test 结果 / 与任务包偏差 / 未决问题; 每步 [PROGRESS]
