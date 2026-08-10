# 任务包 A10+A11: 诊断提取 + DragController 文件组织(纯重构)

## 背景
LaunchBetter v0.2.3(Prompt Stage A §A10/A11)。AppDelegate 长期拥有整个诊断框架;
DragController(1050 行)集中大量辅助类型。均为**行为不变的重构**。

## 允许修改的文件
- A10: LaunchBetterApp/AppDelegate.swift(诊断逻辑移出) + 新增 LaunchBetterApp/Diagnostics/ 下文件
- A11: Packages/LaunchUI/Sources/LaunchUI/DragController.swift(拆分) + 新增 DragSessionState.swift /
  InputEndArbitration.swift / CreateFolderHoverDecision.swift / DragPreviewPlan.swift /
  DragOverlayLayer.swift / InsertionIndicatorLayer.swift(按实际类型归属)

## A10 要求
- 保留全部诊断行为: smoke/pagetest/pagingprobe/dragcacheprobe/searchprobe/gridtest/
  iconbench/threefingerdiag/folders/perf。**禁止删除任何诊断**
- 提取到 Diagnostics/: DiagnosticRunner.swift(模式分派)+ 各 probe 文件(SmokeProbe/PagingProbe/
  DragProbe/FolderProbe/SearchProbe/GridProbe/IconProbe/ThreeFingerProbe)
- AppDelegate = application bootstrap + diagnostic mode dispatch
- 保留 pass/fail 行为; 失败退出非零; 不打印假 OK

## A11 要求
- DragController 保持**唯一运行时拖拽所有者**(禁止拆出第二个拖拽引擎)
- 仅把逻辑独立的辅助类型移到聚焦文件(按上面命名); 不改行为
- 不改 DragController 的核心状态机/热路径逻辑

## 约束
- 行为零变化; 全部现有测试必须保持绿(UI 50 / Core 119+73 / Platform 102)
- 不新增依赖; 不新增 main.sync
- 单一写者: 只改上述文件

## 验收
1. 全部诊断命令仍可用且行为一致(--smoke/--pagetest/--pagingprobe/--iconbench/--threefingerdiag 等)
2. AppDelegate 变薄(诊断在 Diagnostics/)
3. DragController 按文件拆分, 行为不变
4. 三包测试全绿; xcodebuild build 成功

## 命令纪律(硬性)
bash 每条单命令, 严禁 2>&1 | && ;、rg、rm 外部目录。搜索用 grep 工具, 读文件用 read 工具。
验证命令: swift test / xcodebuild build。

## 禁止
不提交 git; 不切换分支; 不改 Launchpad_Back; 不改 A10/A11 之外文件(需要时报告)

## 输出
改动文件清单/假设/测试结果/偏差/未决; 每步 [PROGRESS]
