# LaunchBetter 双指滑动"跟手翻页"问题描述

## 1. 背景

macOS 原生 Launchpad 替代品(LaunchBetter),主界面 = NSCollectionView 分页网格。
每页宽度 = NSScrollView 的 NSClipView 可视宽度(1470pt),文档视图宽度 = 页宽 × 页数。
文档视图是 flipped(点击集合视图 isFlipped = true),水平方向无滚动条,滚动视图包在
全屏无边框窗口里。

翻页方式:双指在触控板上水平滑动(每页最多翻一页,带吸附)。

## 2. 事件流(实测)

真实触控板一次水平滑动产生一串 NSEvent:

```
phase=.began, momentumPhase=[]
phase=.changed, momentumPhase=[]   (×N)
phase=.ended,   momentumPhase=[]
phase=.changed, momentumPhase=.began   ← 惯性阶段
phase=.changed, momentumPhase=.changed (×N)
phase=.ended,   momentumPhase=.ended
```

事件从 NSScrollView 的文档视图(ClickableCollectionView,NSCollectionView 子类)
的 `scrollWheel(with:)` 进入,经回调 `onPageScroll` 转发给控制器处理,返回 true 表示
"已处理"(不再交给系统滚动),返回 false 则放行给系统。

## 3. 当前实现(核心代码)

控制器 `handlePageScroll(_ event: NSEvent) -> Bool`:

```
1) momentumPhase != [] 时: 全部拦截 return true; 仅当 momentumPhase == .ended
   时调用 snapToNearestPage() 吸附
2) phase == .began: pagingSession.reset(); gestureBaseX = clip 当前 offset.x
3) phase == .ended/.cancelled: 调用 snapToNearestPage(); return false
4) 水平主导判定: abs(event.deltaX) > abs(event.deltaY) × 1.5 且 abs(deltaX) > 0.5:
   - 把 deltaX 喂进 PagingGestureSession(纯累计器, 累计 accumulatedDeltaX)
   - 调用 followFinger(): 实时把 clip 滚到 gestureBaseX + clamp(-累计, -页宽, +页宽)
   - return true
5) 否则若 abs(deltaY) > 0.5: 走"一次手势最多一页"的提交制(nextPage()/previousPage())
6) 其余 return false
```

`followFinger()` 关键行:

```swift
let dx = -pagingSession.accumulatedDeltaX      // 左滑(deltaX<0)→ offset 增加
let clamped = min(max(dx, -pageWidth), pageWidth)
let target = min(max(gestureBaseX + clamped, 0), maxX)
clip.scroll(to: NSPoint(x: target, y: 0))      // 无动画直接设置
```

`snapToNearestPage()`:

```swift
let target = geometry.snapTarget(
    currentOffsetX: clip.bounds.origin.x,
    currentPage: currentPage, pageCount: pageCount)   // 阈值 0.35 页宽
currentPage = target
goToPage(target, animated: true)   // 0.35s easeInEaseOut 动画
```

`goToPage` 内部:`clip.animator().setBoundsOrigin(x: page×页宽)`,
动画 completion 里若位置偏离整页 >1pt 再硬校准一次。

PagingGestureSession(纯逻辑,有 7 个测试)只做累计与"一次最多一页"判定,
阈值 16pt,水平主导 1.5 倍。

## 4. 用户反馈的问题

"跟手还是有问题" —— 具体表现为(用户原话要点):

- 滑动时页面跟手的感觉不对(不流畅/不跟手/位移与手指不一致)
- 松手后吸附的判定/动画有违和感

(请用户补充具体现象:是"页面不动只有松手才跳"、"页面跟手太灵敏/太迟钝"、
"方向相反"、"滑一点就翻页"还是"翻页后弹回"等。)

## 5. 实现者已识别的技术疑点(按可疑程度排序)

### 疑点 A:用错了位移事件字段 —— deltaX 不是像素单位(最可疑)

`NSEvent.deltaX` 是"行/格"单位(触控板典型值 ±0.1 ~ ±3,随系统"滚动速度"设置缩放),
不是像素。跟手需要**像素级**位移,正确字段是:

```swift
let precise = event.hasPreciseScrollingDeltas   // 触控板 = true, 鼠标滚轮 = false
let deltaX = event.scrollingDeltaX              // 像素单位(触控板)
```

当前代码用 `event.deltaX` 做 `clip.scroll(to:)` 的像素位移 —— 量级和方向都可能不对:
1:1 像素位移建立在错误单位的输入上,导致跟手比例失真(可能过快/过慢/抖动)。
应改为:触控板(hasPreciseScrollingDeltas)用 `scrollingDeltaX`,鼠标滚轮可退化为提交制。

### 疑点 B:跟手没有阻尼/加速比

即使换用 scrollingDeltaX,1:1 跟手在 Launchpad 式交互里通常要加阻尼系数
(常见 0.4~0.7,或者加速度响应曲线),否则页面像"贴着手指滑"而不是"有惯性、
有弹性"。目标体验:手指滑 300pt,页面跟 120~200pt,松手后按位移比例吸附。

### 疑点 C:动画与手势竞争导致基准错乱

`goToPage(animated: true)` 是 0.35s 动画。若用户在前一次吸附动画未完成时再次
滑动,`.began` 时 `gestureBaseX` 记录的是"动画中途位置"(非整页),跟手基准偏移;
松手 snap 用 `currentPage`(旧页)对齐 → 可能吸附到错页或出现回弹。
需要:`.began` 时若当前不在整页,先取消动画并把 currentPage 校准到实际所在页,
再记基准。

### 疑点 D:纵向路径与横向路径共享同一个 PagingGestureSession

横向跟手用 accumulatedDeltaX 累计;纵向(滚轮)也喂同一个 session
(`deltaX: event.deltaY`)。两者在同一个手势会话里可能互相污染累计值
(例如先纵向动 2pt 再横向滑,累计 deltaY 影响…)。建议横向跟手用独立累计,
不共享 session 的累计状态。

### 疑点 E:方向与系统"自然滚动"设置的耦合

macOS "滚动方向:自然" 下,手指左滑 → scrollingDeltaX 为负 → 内容应左移
(= offset 增加)。当前代码 `dx = -accumulated` 假设这个符号。若用户关闭自然滚动,
符号会相反。建议对 event.isDirectionInvertedFromDevice 做兼容。

### 疑点 F:跟手只处理"水平主导"事件,可能漏事件

`abs(deltaX) > abs(deltaY) × 1.5` 的主导判定会让"慢速/微小滑动"事件被丢给
纵向分支或 return false → 跟手不连贯(事件流中断)。实际跟手应放宽:只要
手势已进入水平会话,后续 changed 事件都应继续跟手(方向可钳制),不要中途
因单帧 deltaY 略大就退出跟手。

### 疑点 G:clip.scroll(to:) 每事件直接设置与 NSScrollView 内部状态冲突

NSScrollView/NSClipView 在 hasHorizontalScroller = false 且文档视图有
横向弹性(elastance)时,`constrainBoundsRect` 可能拦截/修正直接写入的 offset,
导致跟手出现"弹性阻尼感"或回弹。建议检查是否禁用横向橡皮筋
(horizontalScrollElasticity = .none)后跟手更直。

## 6. 期望行为(验收标准)

1. 手指左滑/右滑时,页面**实时**跟随手指水平移动(比例/阻尼可调)
2. 位移被钳制在"当前页 ± 一页宽"内(一次手势最多一页)
3. 松手:位移 > 阈值(可调, 当前 35%)→ 平滑吸附到下一页/上一页;否则弹回当前页
4. 惯性阶段不再产生任何位移(全拦截),松手瞬间的吸附动画即最终位置
5. 与系统"自然滚动"设置、鼠标滚轮(提交制)兼容
6. 吸附动画进行中再次滑动,不会基准错乱
7. 可自动化测试:手势会话/吸附目标为纯逻辑(已有 PagingGestureSession + snapTarget 测试)

## 7. 当前代码位置

- 手势处理: `Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift`
  `handlePageScroll` / `followFinger` / `snapToNearestPage`(约 514-606 行)
- 纯逻辑: `Packages/LaunchCore/Sources/LaunchCore/PagingGestureSession.swift`
- 吸附纯逻辑: `Packages/LaunchCore/Sources/LaunchCore/GridGeometry.swift` `snapTarget`
- 事件入口: `Packages/LaunchUI/Sources/LaunchUI/ClickableCollectionView.swift` `scrollWheel`
- 翻页动画: `GridViewController.swift` 底部 `NSCollectionView.scrollToPage` extension
- 测试: `PackingCoreTests/PagingGestureSessionTests.swift`、`GridGeometryTests.swift`
