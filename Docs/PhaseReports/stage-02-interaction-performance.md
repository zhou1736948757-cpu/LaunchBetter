# LaunchBetter Interaction & Performance Consolidation Report

分支: fix/v0.1.6-interaction · 目标: 交互质量 + 性能 + 代码健康整合(v0.1.6)

## 1. Baseline

- BUILD SUCCEEDED; LaunchCore 96 (swift-testing) + 33 (XCTest) 全绿
- pagetest 0→1→2→1→0 OK + hideShowReset OK; smoke 88 apps / 3 页 / 42 容量 / search=1
- 机器: macOS 26.5, 默认屏幕 1470×956, 刘海屏(safeArea 32pt)

## 2. Paging Root Causes

- 跟手用 `event.deltaX`(行/格单位)而非像素 `scrollingDeltaX` → 位移比例失真(主因)
- 无手势级 axis lock: 单帧 dy 略大即退出水平跟手(不连贯)
- 位置无 writer 合并: 事件率(125-250Hz)与屏幕率(60-120Hz)不匹配, 原实现每个 changed 事件直接 scroll
- 吸附动画用 NSAnimationContext(frame-based 由 AppKit 内部管理), 无法与手势无缝衔接/打断
- 系统横向弹性与自实现跟手可能双重作用

## 3. New Paging Architecture

```
NSEvent(scrollingDeltaX/Y, precise)
   ↓
PagingInteractionController  (axis lock / displacement / velocity EMA / latest desired)
   ↓
CADisplayLink (NSView.displayLink, macOS 14+)  = 唯一 offset writer
   ↓
clip.scroll(to:)  (每 display frame 最多一次)
```
- TRACKING: 直接应用最新 desired(direct manipulation, 无低通, 无 epsilon skip)
- SETTLING: PageSnapAnimator(time-based critical damped spring)
- momentum 全拦截(0 位移 0 snap 0 重结算); 一次手势一次 settle, 最多一页
- 首尾页 rubber band(刚度阻尼 + 饱和上限); 禁用系统横向弹性

## 4. Snap / Spring Design

- 解析解: y(t) = (y0 + (v0 + ω·y0)·t)·exp(−ω·t), ω=14 rad/s
- wall-clock 驱动(ProcessInfo.systemUptime), 60Hz/120Hz 响应一致(测试验证)
- 收敛判定: |position-tolerance| < 0.5pt 且 |velocity| < 5pt/s → 精确落位 + 停 link
- 打断: 新手势 .began 时 animator.cancel() + generation token, 从当前实际 offset 重新跟手
- PagingTargetResolver: |位移| ≥ 30% 页宽 → 翻页; 否则 |位移| ≥ 12% 且速度 ≥ 900pt/s → fling

## 5. Drag Hot-Path Optimizations

- 缓存: lastDestination / lastGapIndex / currentTransforms(目标状态)/ lastOverlayVisual
- destination 未变 → 0 preview / 0 transform 写
- transform diff: old-only→identity, changed→new, unchanged→0 写
- folder hit-test 每帧一次; overlay 视觉状态相同则不写 layer/string
- cache 绑定几何指纹(页宽)与 displayRevision(变化 → 清缓存/取消拖拽)

## 6. LauncherStore Optimizations

- commitLayoutChange(searchMetadataChanged:) 统一提交(去嵌套 Task→Task)
- SearchIndex 精确失效: 仅 catalog/display-metadata/customDisplayName 变化重建
- gridRows/columns/iconSize/wallpaper/hotkey/hotcorner/hidden/reorder/folder 均不重建

## 7. AppCell Optimizations

- visibleIconImage 类型校验(CFGetTypeID == CGImage.typeID)后强转, 消除裸 force-cast
- screen-scale observer: 评估后保留 cell-level(重构为 window-level 收益低风险高, §55 允许)

## 8. Measured-but-Deferred Optimizations

- `layoutAttributesForElements` O(N): 实测 swipe 中 attributeQueries 4→5(≈1 次/交互),
  全遍历 130 项占比极低 → deferred(§92 原则)
- attribute cache(NSCollectionViewLayoutAttributes 预缓存): Allocations 未显示明显
  per-frame 创建 → deferred
- DisplayLink idle 生命周期: 按需启停已实现(idle 即 invalidate), 无需 interaction-only 激活

## 9. Before / After Performance Counters

| 指标 | Before | After(实测) |
|---|---|---|
| swipe scroll writes | 每 NSEvent 1 次(无合并) | 39 ≤ frames 46(§82) |
| swipe 额外 layout prepare | +1/滚动 | 0(prepare 4→4, §83) |
| 一次 gesture settle 次数 | 可能多次(momentum 重 snap) | 1(§20) |
| momentum 额外位移 | 有(系统滚动) | 0 |
| 同 destination 50 帧 preview | 每帧 1 次 | 1(§85) |
| 同 destination 50 帧 transform 写 | 每帧 reset+重写 | 恒定(§85) |
| overlay 视觉写 | 每帧 | 1 次 |
| UI-only config 搜索索引重建 | 每次 save | 0(§86) |
| custom name 变化重建 | 1 | 1(正确) |

## 10. Time Profiler Findings

- 用轻量数值计数器替代 GUI Instruments(无焦点环境 display link 不触发):
  pagingprobe 实测 input=10 → frames=46 → scroll=39, settle=751ms 收敛;
  DragCache probe 手动驱动帧验证缓存逻辑(display link 需真实窗口焦点)
- 建议用户在有焦点窗口下跑 Instruments 复核(§73)

## 11. Allocation Findings

- 热路径代码审查: NSEvent 热路径仅小运算(axis lock/displacement/EMA/latest target),
  DisplayLink 热路径仅 spring 数学 + clip.scroll(§32-33); 无 Task/Array/String 创建
- 未发现明显 per-frame churn(§74)

## 12. 60Hz / 120Hz Validation

- PagingSpring 纯 wall-clock(测试: 60Hz 6 帧 = 120Hz 12 帧在 t=0.1s 位置一致)
- 速度 EMA 按真实 dt 调整平滑系数, 与帧率解耦

## 13. Tests

- 新增 21 XCTest: PagingAxisLock(4) / PagingTargetResolver(6) / PagingSpring(5) /
  PagingRubberBand(4) / PagingVelocityEstimator(2)
- LaunchCore: 96 + 54 全绿; 无回退

## 14. Build / Smoke / Pagetest

- xcodebuild Debug/Release BUILD SUCCEEDED
- smoke/dragtest OK; pagetest 0→1→2→1→0 + hideShowReset OK
- searchprobe: overflow 76 / realIcons 42/42; gridtest: 8×5→40 capacity, searchRebuildDelta=0
- pagingprobe OK; dragcacheprobe OK; searchRebuildOnCustomName +1 OK

## 15. Manual Trackpad Tests Required

- §76 慢速(50-100pt)拖动: 连续不黏
- §77 正常 swipe(20-40% 页): 吸附自然
- §78 fling: 短距快速翻页
- §79 snap 中(30-70%)反向抓取: 无跳变
- §80 高频左右切换: 不卡半页/不错页

## 16. Known Remaining Risks

- NSView.displayLink 在无焦点/无渲染环境下不触发(环境限制, 真实交互正常)
- Follow sensitivity = 1.0 未实机校准; displacementThreshold 0.30 / fling 900pt/s 需实机微调
- 视觉评审对该深色壁纸界面的可靠性低(4 次误报记录), 手感验证必须用户实测

## 17. Git Commit Range

- 620b472 refactor: isolate paging interaction (PART A)
- 511205b perf: drag cache/transform-diff, precise search invalidation, prewarm (B/C/D/E/H)
- a96243d perf: verify via runtime probes (PART I)
- 4d76cb0 fix: reviewer M4/M5 + m1-m4
- merge 到 main + tag v0.1.6
