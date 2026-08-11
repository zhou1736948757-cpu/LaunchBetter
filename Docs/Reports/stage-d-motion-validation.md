# LaunchBetter Stage D motion validation report

## 结论

Stage D 的自动化测试、Debug/Release 构建、历史诊断探针和独立终审均已达到记录中的门槛；但本报告不宣称 Stage D 已完成视觉或实机手感验收。

最终 Settings 修复后的 `--motionprobe` 复跑进入 `NSApplication.run` 后没有继续输出，因此该次复跑结果不确定。Computer Use 与屏幕捕获又受 `.screenSaver`/权限链路限制，时间连续性、真实触控板甩动速度和 120 Hz 手感仍为 `MANUAL_PHYSICAL_GATE`。本次文档收尾没有重跑测试、构建或 GUI 探针，只汇总已经完成的验证记录，并重新执行 `git diff --check`。

## 主要实现

| 范围 | 实现结果 | 主要证据路径 |
| --- | --- | --- |
| Motion 基础 | 小型语义 motion tokens、系统 motion 环境快照和可中断的 newest-intent-wins 生命周期；generation guard 拒绝陈旧 completion。 | `Packages/LaunchUI/Sources/LaunchUI/Motion.swift`、`LauncherTransitionLifecycle.swift` |
| 启动器转场 | 启动器 show/hide 的克制呈现与解散；反转从当前可见状态继续，生命周期与清理显式归属。 | `LauncherTransitionCoordinator.swift`、`LauncherWindowController.swift` |
| 文件夹转场 | 从真实可见源几何开始的 open/close 空间连续性、无效源中央 fallback、可反转 spring、代理层与 display link teardown。 | `FolderTransitionCoordinator.swift`、`FolderViewController.swift` |
| Settings 转场 | 设置窗口呈现/关闭动画、generation 防陈旧；原生窗口移动立即取消 presentation animation 并取得所有权。 | `SettingsTransitionCoordinator.swift`、`SettingsWindowController.swift` |
| Press / drag | `mouseDown` 即时 press feedback、按压到拖拽的表示切换、取消与结束清理；拖拽热路径保留逐帧隔离和缓存。 | `PressDragPresentation.swift`、`AppCellView.swift`、`DragController.swift`、`DragOverlayLayer.swift` |
| Paging | 1:1 direct manipulation、单一 offset writer、速度交接、最多一页 settle、边缘 rubber band、可中断 lifecycle。 | `PagingInteractionController.swift`、`PagingGridLayout.swift`、`PagingSpring.swift` |
| Accessibility / material | Reduce Motion 移除大位移；Reduce Transparency 与 Increase Contrast 改变材质策略；系统设置变化实时更新。 | `AccessibilityDisplayObserver.swift`、`AccessibilityMaterialPolicy.swift` |
| Lifecycle / perf / diagnostics | display link、observer、proxy 和 completion 显式 teardown；覆盖 launcher/folder/settings/press/paging 的确定性 motion diagnostics。 | `FrameCoordinator.swift`、`MotionDiagnosticsProbe.swift` 及对应 LaunchUI tests |

## 已通过的验证

| Gate | 状态 | 结果 |
| --- | --- | --- |
| LaunchCore | `AUTOMATED_VERIFIED` | 87 XCTest + 143 Swift Testing 通过。 |
| LaunchPlatform | `AUTOMATED_VERIFIED` | 127 Swift Testing 通过。 |
| LaunchUI | `AUTOMATED_VERIFIED` | 5 XCTest + 152 Swift Testing 通过。 |
| Debug build | `AUTOMATED_VERIFIED` | `BUILD SUCCEEDED`。 |
| Release build | `AUTOMATED_VERIFIED` | `BUILD SUCCEEDED`。 |
| Whitespace/error check | `AUTOMATED_VERIFIED` | `git diff --check` 通过；文档收尾后再次通过。 |
| 诊断探针（历史记录） | `AUTOMATED_VERIFIED` | `motionprobe`、`layoutdiag`、`pagetest`、`pagingprobe`、`dragcacheprobe`、`smoke --folders`、`searchprobe`、`settingsownershipprobe` 曾通过。此项不等于最终 Settings 修复后的 `motionprobe` 复跑通过。 |
| 独立终审 | `AUTOMATED_VERIFIED` | 独立最终 Sol medium 只读审查：0 blocker、0 major、0 minor。 |

## 性能测量

| 路径 | 首次 | Warm |
| --- | ---: | ---: |
| Launcher show | 36.2 ms | 2.2–5.6 ms |
| Wallpaper | 232.8 ms | 2.1–5.5 ms |

这些数据是已记录的本机测量值，不外推为所有设备、刷新率或真实输入条件下的保证。

## 未验收与限制

- 最终 Settings 修复后的 `--motionprobe` 复跑在进入 `NSApplication.run` 后无后续输出；没有可据此判定通过或失败的终态，因此不授予完成标签，也不以较早的通过记录替代该次结果。
- Computer Use/屏幕捕获受 `.screenSaver` 与权限链路限制，未取得足以判定动态连续性的可靠时间序列证据；`VISUAL_VERIFIED` 未达成。
- 启动器、文件夹、Settings、press 与 paging 的真实时间连续性仍为 `MANUAL_PHYSICAL_GATE`。
- 真实触控板甩动速度与反向接管手感仍为 `MANUAL_PHYSICAL_GATE`。
- 120 Hz 显示下的节奏、连续性与主观手感仍为 `MANUAL_PHYSICAL_GATE`。

因此，当前可以表述为“自动化与代码审查门禁通过，性能数据已记录”；不能表述为“最终 motionprobe 已复跑通过”或“Stage D 已完成视觉/物理验收”。
