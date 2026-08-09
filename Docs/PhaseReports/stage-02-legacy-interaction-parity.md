# LaunchBetter Stage 2 — Legacy Interaction Parity Report

分支: stage-02-legacy-parity · 目标: 证据驱动 Legacy Feature Parity Audit + Three-Finger Drag

## 1. Old LaunchHistory Evidence Summary

旧项目 `/Users/mac/Projects/Launchpad_Back`(SwiftUI, 10k 行)全部 feature 经 explore agent 只读审计 + 人工复核。
关键: **"LaunchHistory" 只是缓存目录名**, 不存在 launch history / recent / count / timestamps 功能
(UserPreferences 仅有死字段)。不再凭项目名推断功能。

## 2. Feature Parity Matrix Summary

Docs/FeatureParity/LaunchHistory-Parity-Matrix.md — 27 项候选, 每项含 Old Source Evidence / Old Behavior /
Current Evidence / Status / Migration Decision / Notes。

## 3. VERIFIED_PARITY Features

App launching / horizontal paging / search / persistent ordering / folders / folder rename / folder
dissolve(LaunchBetter 有显式入口, 旧仅自动解体)/ drag reorder / cross-page drag / drag in-out folder /
hidden apps / custom names / uninstall / four-finger pinch / three-finger drag(本阶段新实现)/
hot corner / wallpaper blur / localization(即时切换更优)/ multi-display / accessibility / refresh-rescan(FSEvents 更优)。

## 4. VERIFIED_PARTIAL Features

- Custom app source directories(已有部分接线)
- Context menu(缺 Finder 显示/简介)
- Global hotkey(5 预设; 旧项目仅硬编码 ⌘L, 自定义 UI 未接线 → LaunchBetter 已覆盖实际行为)
- Settings(图标 slider 粒度、about tab)

## 5. VERIFIED_MISSING Features

- Vertical layout(旧有连续垂直滚动, 本阶段按 §33 不实现)
- Localized app names(旧读 .lproj/InfoPlist.strings/CFBundleDisplayName; 本阶段按 §32 不实现)

## 6. OLD_FEATURE_NOT_PROVEN Items

- Launch history / recently used / launch count / timestamps(旧无实现, 命名陷阱)
- Vertical paging(旧无翻页实现)

## 7. Three-Finger Drag Old Behavior

- count=3; minTranslation=0.005(归一化); pinchTolerance=0.15; confirmFrames=2
- 状态机: 非 3 指立即结束; 平移且非捏合连续 2 帧确认 → began; 拖动中捏合 → ended
- 位置语义: NSEvent.mouseLocation(指针), 非触点中心; 反查指针下图标
- 生命周期: 面板显示启用; 隐藏发 cancel(不 drop)

## 8. Three-Finger Drag New Architecture

```
MultitouchSupport(dlopen) → GestureCaptureEngine.receive(单一订阅)
  → 3 指 → ThreeFingerDragRecognizer(LaunchCore 纯逻辑, 常量对齐 legacy)
  → 4+ 指 → PinchAnalyzer(既有)
  → ThreeFingerGestureEvent
  → ThreeFingerDragCoordinator(latest-value coalescing; 指针位置)
  → DragController.beginDrag(.threeFinger) / updateDrag / endDrag / cancelDrag
```
复用 DragController 全部能力: 预览缓存/二维 diff/真实图标 overlay/跨页边缘翻页/文件夹 drop/
revision 陈旧防护。无第二套 reorder 引擎。

## 9. Input Arbitration

| 输入 | 引擎 | 路由 |
|---|---|---|
| 2 指水平 | PagingInteractionController | scrollWheel(precise) |
| 3 指 | ThreeFingerDragRecognizer | 单一 MTDevice 订阅, finger-count 路由 |
| 4+ 指 | PinchAnalyzer | 同一订阅 |
| 鼠标 | DragController(.mouse) | 与 .threeFinger 互斥(session owner) |

## 10. Performance Results

- 三指 changed: latest-value coalescing, 主线程最多 1 个 drain 任务(250Hz 不积压)
- raw frame 只做: finger count / centroid / 位移 / 半径 / 状态机(纯计算微秒级, 后台线程就地)
- 无 per-frame Store / Diffable / Task / IO; UI 工作由既有 FrameCoordinator(display link)消费
- idle: 无触点无回调(GESTURE_DEBUG 实测既有机制); 三指能力开启不影响 idle

## 11. Tests

- 新增 12 XCTest: ThreeFingerDragRecognizer(0/2/3/4 指, 阈值, 连续确认, began 恰一次,
  ended/cancel, 拖动中捏合, noisy count)
- LaunchCore: 96 + 66(原 54 + 12)全绿; 无回退

## 12. Build / Smoke / Pagetest

- xcodebuild BUILD SUCCEEDED(debug + release)
- smoke / dragtest OK; pagetest 0→1→2→1→0 + hideShowReset OK
- threefingerdiag OK(engine running, coordinator 接线, 无触点计数为 0, 不崩溃)

## 13. Review Result

Luna Max: **0 BLOCKER / 0 MAJOR**(复评后)。首轮 2 MAJOR(M4 changed 积压, M5 update/end 无 owner)+
1 MINOR + 3 NOTE; M4/M5 已修(合并 + owner 校验); MINOR-1 按 legacy 语义保留; NOTE 已记录。

## 14. Git Commits

- 7ce4f46 docs: evidence-backed legacy feature parity matrix + three-finger drag core
- ed80195 fix: three-finger changed coalescing + input-source ownership (M4/M5)

## 15. Recommended Stage 3

- P1 Catalog metadata parity: 本地化应用名(.lproj/InfoPlist.strings)+ 自定义来源深化
- P2 Settings/context parity: 图标 slider 细化, Finder 显示/简介, 热键 recorder
- P3 Optional layout: 垂直滚动布局
- P4 Final hardening

## 16. 用户实机验证(§24, 未完成前不宣称三指 validated)

Test A 三指放触控板小幅移动 → 不误触
Test B 三指达到拖动阈值 → App 开始拖动
Test C 三指慢速移动 → Overlay 连续无延迟
Test D/E 跨行 / 跨页
Test F 拖到 Folder
Test G 松手 → 正确 Drop
Test H 中途手指数异常 → 安全 cancel 无残留 transform
