# 任务包: PA4 — Library↔Page1 半路卡住翻页根因 + trace + 压力探针

## 背景(用户实机)
Library ↔ Page1 滑动**偶尔停在中间水平位置**;不是完全冻结(继续输入还能动)。
推断属 paging 生命周期/事件结束/所有权问题,不是进程挂死。
主控初步怀疑: 表面翻转(Library→layoutPage)期间后续 scrollWheel 事件经
`handleAppLibraryHorizontalScroll`(guard `currentSurface == .appLibrary`)被丢弃,
`.ended` 未达 paging → phase 停留 tracking、display link 停在中间偏移。
必须**先 trace 取证**,禁止盲修。

## 允许修改的文件
- `Packages/LaunchUI/Sources/LaunchUI/PagingInteractionController.swift`(仅 trace/修复)
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryViewController.swift`(仅 trace 桥)
- `Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift`(仅 trace 接线/修复)
- `Packages/LaunchUI/Sources/LaunchUI/LauncherWindowController.swift`(仅 trace 接线/修复)
- `LaunchBetterApp/Diagnostics/PagingEventTraceProbe.swift`(新增)
- `LaunchBetterApp/Diagnostics/PagingStressProbe.swift`(新增)
- `LaunchBetterApp/Diagnostics/DiagnosticRunner.swift` / `ActivationCoordinator.swift`(flag 注册,`--pagingeventtrace`/`--pagingstressprobe` 均 non-interactive)
- `LaunchBetter.xcodeproj/project.pbxproj`(注册新文件)
- 相关测试

禁止改 PageSnapAnimator 弹簧参数、禁止加"定时器强制吸页"作为修复(最后防御性兜底仅可在根因修复后、按需加)。

## 规格

### 1. `--pagingeventtrace`
对 Library↔Page1 手势逐事件记录(生产默认关闭;trace 开启时写 /tmp/lb-paging-eventtrace.log):
timestamp / event.phase / momentumPhase / deltaX / deltaY / Library arbiter state+route / pendingBeganEvent 有无 / momentumRoute / Paging phase / baseOffset / latestDesiredOffset / 实际 clip offset / physicalSurfaceIndex / semantic surface / settleStart / settleEnd / interruption / displayLink start-stop。
驱动方式: 合成 NSEvent(参照 PagingProbe.makeScroll) + 逐帧 `pagingProbeDisplayFrame()`;也可做真实事件注入(本机无辅助功能权限,以合成驱动为主)。

### 2. `--pagingstressprobe`
确定性/半确定性重复: Library→Page1 与 Page1→Library 各 ≥100(目标 500)轮,
每轮变化模式轮流: 慢位移 / 恰阈值位移 / 快速 flick / settle 中途反转 / diagonal→horizontal 锁定 / horizontal→momentum / 取消。
每轮 settle 完成后断言:
- Paging phase == idle
- display link 未激活
- `abs(offset/pageWidth - nearestInteger) <= epsilon`(不休息在页中间)
- currentSurface 与物理 offset 一致(0→appLibrary,n≥1→layoutPage(n-1))
失败即打印该轮 trace 摘要并退出 1。

### 3. 根因修复
用 trace 定位后修复根因。任务特别要求排查:
- `.ended/.cancelled` 是否丢失(surface 翻转后 handler 丢弃)
- horizontal 流被 seed 但从未 finalize
- momentum 生命周期
- PageSnapAnimator 提前停止
- display link 在中间 offset 被停
- currentSurface 过早更新 / owner 在 settle 中变化
- clip/document 几何变化
- search/settings/library 状态切换
修复后加 idle 不变式断言/探针覆盖(A15)。

### 4. 测试
- 不变式: settle 后 offset 必在页边界
- ended/cancelled 都收敛
- momentum 0 位移
- 500 轮压力通过
- 现有分页/轴测试保持

## 验收
1. LaunchUI 测试全绿(记录数字)。
2. Debug build 成功。
3. `--pagingstressprobe` 500 轮全过(输出轮数/失败)。
4. `--pagingeventtrace` 输出一份正常手势 trace + 一份卡住时 trace(若复现)。
5. 报告根因、trace 证据、修复 diff、压力结果。
