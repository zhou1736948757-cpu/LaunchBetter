# 任务包: Stage E9b Library vertical/horizontal axis arbitration

## 背景

E8 已接入 physical Library section，E9a 已建立 `.appLibrary`/`.appLibraryCategory` owner。当前 Library 内部 `NSScrollView` 会自行处理滚轮，但没有明确把 horizontal gesture 路由给外层 `PagingInteractionController`。本任务只补这一条 axis arbitration。

## 允许修改的文件

- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryViewController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryHostItem.swift`
- `Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryAxisArbitration.swift` (新增)
- `Packages/LaunchUI/Tests/LaunchUITests/AppLibraryAxisArbitrationTests.swift` (新增)

禁止修改其它文件、禁止提交、禁止切换分支、禁止修改旧仓库或未跟踪用户文件。

## 设计要求

新增纯逻辑 `AppLibraryAxisArbiter`/等价值对象:

- route = `undecided` / `vertical` / `horizontal`
- 手势开始时重置，使用现有 `PagingAxisLock` 和 `PagingTuning` 的阈值/主导轴语义。
- 明显 horizontal 一旦锁定，后续 vertical burst 不能抢回 owner。
- 明显 vertical 锁定后，后续 horizontal burst 不能抢回 owner。
- diagonal 未达到阈值保持 undecided，不产生 jitter。
- ended/cancelled/reset 回 idle。

`PausableLibraryScrollView` 或等价 Library scroll router:

- detail/owner paused 时消费所有 scroll，不交给 Library 或 outer Grid。
- undecided 期间消费小样本，锁定 vertical 后把当前及后续交给内部 NSScrollView；锁定 horizontal 后交给注入的 `GridViewController.handleAppLibraryHorizontalScroll`。
- horizontal route 使用现有 `PagingInteractionController.handleWheel`，不得创建第二个 horizontal settle/spring/display-link。
- horizontal handler 返回 false 时仍不能把已锁定 horizontal 事件交给 vertical scroll，避免双向同时运动。
- phase ended/cancelled 后 reset arbiter。
- category detail 打开时原有 E9a `isScrollPaused` gate 优先级最高。

Grid 提供窄方法:

```swift
func handleAppLibraryHorizontalScroll(_ event: NSEvent) -> Bool
```

仅当 current surface 是 `.appLibrary` 且非 Search/category detail 时调用 paging；由 Host 将 handler 注入 Library controller。普通 Launcher page 输入路径不改变。

## 必写测试

- dominant horizontal → horizontal，后续 vertical burst 仍 horizontal。
- dominant vertical → vertical，后续 horizontal burst 仍 vertical。
- below threshold/diagonal → undecided，无 route 抖动。
- ended/reset → 下一手势可重新选择轴。
- paused → scroll 不交给任何一方。
- horizontal handler 使用同一 PagingInteractionController seam；无第二 writer/第二 settle engine。

## 验收

- `cd Packages/LaunchUI && swift test` 通过。
- `xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter build` 通过。
- `DispatchQueue.main.sync` 仍为 0。
- 返回 axis 状态机、事件 owner、测试结果、偏差和未决问题；每一步用 `[PROGRESS]`。
