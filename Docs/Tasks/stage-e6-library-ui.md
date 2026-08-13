# 任务包: Stage E6 App Library card UI

## 背景

Core 已提供 `AppLibraryModel`，Platform 已提供 metadata store，`PagingGridLayout` 已支持 leading host 的 page geometry。本任务建立独立 AppKit Library UI，暂不把它接入外层 Launcher paging，也不修改 GridViewController/LauncherWindowController。

## 允许修改的文件

新增:

- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryViewController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryLayout.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryCardCell.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryDetailViewController.swift`

可修改本地化:

- `Packages/LaunchUI/Sources/LaunchUI/L10n.swift`
- `Packages/LaunchUI/Tests/LaunchUITests/L10nTests.swift`

新增测试:

- `Packages/LaunchUI/Tests/LaunchUITests/AppLibraryLayoutTests.swift`
- `Packages/LaunchUI/Tests/LaunchUITests/AppLibraryViewTests.swift`

禁止修改其它文件、禁止提交、禁止切换分支、禁止修改旧仓库或现有未跟踪文件。

## API/接入边界

`AppLibraryViewController` 使用注入值，不依赖 LaunchPlatform、不访问文件系统:

```swift
@MainActor
public init(
    model: AppLibraryModel,
    displayName: @escaping (AppID) -> String,
    iconProvider: (any IconImageProviding)?,
    onLaunch: @escaping (AppID) -> Void
)
```

提供窄 API:

- `apply(model:)` 或 `beginSession(model:)`，当前 session 可冻结 model。
- `verticalScrollView` / `collectionView` 只作为外层接入和测试 seam，不暴露内部状态写入。
- Category card/mini cluster open detail；大 App icon 直接 `onLaunch`。
- category detail 的 Escape/outside close/selection 通过 callback，不触碰 LauncherInteractionSurface。

## 视觉与交互要求

- AppKit `NSScrollView + NSCollectionView`，禁止 SwiftUI giant grid。
- 卡片使用当前 LaunchBetter material language: 轻玻璃、圆角、克制 shadow、system font，不使用彩色主题、霓虹或网页式大 hover 抬升。
- 顶部顺序: Suggestions、Recently Added(存在才显示)、固定 category cards。
- 大图标最多 3 个，mini cluster 最多 4 个；card 不显示完整 App labels，detail 显示 icon + label。
- card 宽度 bounded responsive，目标 2-4 columns，约 280-430pt territory；根据实际可用宽度计算，不能按屏幕百分比无限拉伸。
- 只请求可见 card/detail icons；异步结果必须有 cell identity/generation/cancellation 防串图；使用当前 window backing scale，不使用 `NSScreen.main`。
- `mouseDown` 有轻微即时 press feedback；primary app click launch；mini cluster/card title click open detail。
- Accessibility: card group/button label/help、每个 App 的完整 display name、mini cluster “查看更多”、detail Escape/focus/VoiceOver。
- Reduce Motion 只保留短淡入淡出；不在本任务新建第二套 paging/animation engine。

## Layout 约束

新增纯几何 `AppLibraryLayoutMetrics` 或等价值对象并测试:

- 给定 available width/spacing/min/preferred/max，确定性计算列数和 card width。
- card width bounded；2-4 列在常见桌面宽度下成立，极窄宽度也必须 finite/non-negative。
- 垂直 content height 只按 card 数和 card height 计算；滚动不重建 model 或全表 icon。

`AppLibraryLayout` 可使用 custom `NSCollectionViewLayout`，不要复用 `PagingGridLayout` 的 ordinary slot/page 数学。

## 本地化

将以下文案加入现有 L10n，并同步 English / zh-Hans / zh-Hant:

- App Library、Suggestions、Recently Added、Category detail/help
- Productivity、Social、Developer、Entertainment、Games、Creativity、Utilities、Education、Business、Finance、Other
- View more apps / Launch app 等必要 accessibility 文案

不要散落硬编码用户可见文本。

## 测试

- metrics: 800/1200/1600/2400pt 宽度、2-4 列、bounded card、极窄宽度 finite。
- model card identity/payload apply 不改变 layout identity；空 model、无 Recently Added、500 App card 数受限。
- AppLibraryViewController: card order、primary launch callback、mini/detail callback、Escape/outside close、session model freeze。
- icon reuse: fake provider late result 不串到新 AppID；visible-only 请求可观察。
- localization keys 三语完整，`L10nTests` 全绿。

## 验收

- `cd Packages/LaunchUI && swift test` 通过。
- `xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter build` 通过。
- 不增加 `DispatchQueue.main.sync`。
- 返回实际新增类型、视觉假设、测试结果、偏差和未决问题；每一步用 `[PROGRESS]`。
