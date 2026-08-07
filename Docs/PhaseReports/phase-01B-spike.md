# Phase 1B — Disposable NSCollectionView/120Hz Spike

## Scope

一次性原型,验证最大的 UI 技术赌注:
NSCollectionView + 水平分页 + 200 placeholder cells + CALayer 拖拽 overlay +
跨页行为 + Diffable snapshot 结构更新成本。spike 代码已删除,本报告保留测量证据。

## Setup

- 硬件: MacBook Pro, 内置 Liquid Retina 2560x1664, **实际刷新率 60Hz**(`NSScreen.maximumFramesPerSecond = 60`),scale 2.0
- 网格: 7 列 × 6 行,96pt 图标,28pt 间距,200 项 → 5 页
- 测量: NSView.displayLink tick 间隔(ms),每阶段一个统计周期
- 阶段:
  1. idle 3s — 静态网格
  2. pageTransition 5s — 0.45s 翻页动画循环(NSAnimationContext + animator bounds origin)
  3. dragLayer 4s — overlay CALayer 正弦拖拽(纯 layer transform)
  4. snapshotStorm 4s — 每 tick 应用一次轮转顺序的 diffable snapshot(禁止模式的最坏成本)

## Results

| 阶段 | ticks | mean | p50 | p95 | p99 | max | 备注 |
|---|---|---|---|---|---|---|---|
| idle | 158 | 18.64ms | 16.67ms | 16.67ms | 25.93ms | 314ms | max/p99 为启动首帧热噪音 |
| pageTransition | 303 | 16.67ms | 16.67ms | 16.67ms | 16.67ms | 16.80ms | 翻页零掉帧 |
| dragLayer | 243 | 16.67ms | 16.67ms | 16.67ms | 16.67ms | 16.80ms | 纯 layer 变换零开销 |
| snapshotStorm | 243 | 16.67ms | 16.67ms | 16.67ms | 16.67ms | 16.80ms | 帧间隔未受影响 |

snapshot apply 单次成本: count=243, **mean 6.09ms, p95 6.45ms, max 7.64ms**。

## Conclusions

1. **验证通过**: NSCollectionView + 自定义分页 layout + 200 cells 渲染稳定,
   翻页动画期间无 layout invalidation 尖峰(帧间隔恒定 16.67ms)。
2. **纯 CALayer overlay 拖拽路径零成本**: 逐帧只做 layer transform 的
   方案(D 管道)正确。
3. **Diffable snapshot 是结构事件,不是帧事件**: 单次 apply ~6ms。
   - 60Hz(16.67ms 预算)下勉强可行;
   - 120Hz(8.33ms 预算)下每帧 apply 会耗尽预算且无余量做渲染。
   → 证实设计: 拖拽期间仅 layer 变换,drop 时一次布局变更 + 一次 snapshot。
4. **多页 layout 计算成本可忽略**: prepare() 每页 42 项全量布局,无可见尖峰。

## Limitations

- **120Hz 未验证**: 本机显示器实测 60Hz,无法验证 8.33ms 帧预算。
  设计保持 120Hz-ready,待 ProMotion 显示器上复测(记录于 MEMORY)。
- 首帧 warmup(314ms)是窗口创建的启动噪声,与稳态无关;真实启动性能
  由 Phase 3+ 的 LauncherShow signpost 测量。
- snapshotStorm 用 animatingDifferences=false 测最小成本;真实 drop 动画
  场景(animatingDifferences=true)成本只会更高,结论方向不变。

## Review

无独立评审(spike 为一次性代码)。GLM 评审限制同 Phase 1A,记录于 MEMORY。

## Next

Phase 1C — 基于 spike 结论实现 DisplayModel + LayoutTransaction(纯逻辑):
DisplayModel 从 Catalog+Layout+Config 派生分页结构;LayoutTransaction 计算
同页/跨页重排、gap 预览、drop 结果,不触碰 AppKit。
