# 任务包: Stage E1 semantic LauncherSurface contract

## 背景

Stage E App Library 必须是普通 Layout Page 1 左侧的 special surface，但不能进入 LayoutStore。Architecture Note 已确定纯逻辑 physical/semantic mapping:

```text
physical 0 = App Library
physical 1 = Layout page 0
physical 2 = Layout page 1
```

当前所有 page index 都是普通页物理 section index，尚无语义 surface abstraction。这个任务只建立 Core 契约，不接 UI，不接 LayoutStore。

## 允许修改的文件

- `Packages/LaunchCore/Sources/LaunchCore/LauncherSurface.swift` (新增)
- `Packages/LaunchCore/Tests/LaunchCoreTests/LauncherSurfaceTests.swift` (新增)

禁止修改其它文件、禁止提交、禁止切换分支、禁止修改 `/Users/mac/Projects/Launchpad_Back`、禁止碰现有未跟踪文件。

## 约束

- LaunchCore 不得导入 AppKit/SwiftUI/Combine/FileManager。
- `LauncherSurface` 必须为纯值、`Equatable`、`Sendable`。
- `LauncherSurfaceIndex` 的 `layoutPageCount` 规范化为至少 1。
- Library 永远 physical index 0；`.layoutPage(n)` 映射到 `n + 1`，并对无效 n 做确定性 clamp。
- physical index 反向映射必须对边界做确定性 clamp；physical 0 反向为 `.appLibrary`。
- 不提供任何 LayoutSnapshot/LayoutStore sentinel 或持久化编码。
- 不修改现有 `GridGeometry`，本任务只交付映射值对象。

## 建议 API

```swift
public enum LauncherSurface: Equatable, Sendable {
    case appLibrary
    case layoutPage(Int)
}

public struct LauncherSurfaceIndex: Equatable, Sendable {
    public let layoutPageCount: Int
    public init(layoutPageCount: Int)
    public var physicalSurfaceCount: Int { get }
    public func physicalIndex(for surface: LauncherSurface) -> Int
    public func surface(forPhysicalIndex index: Int) -> LauncherSurface
    public func layoutPageIndex(forPhysicalIndex index: Int) -> Int?
}
```

可以增加必要的窄 helper，但不要增加第二套 page abstraction。

## 必写测试

- 1 个 Layout page: physical `[Library, Page0]`，默认 Page0 是 physical 1。
- 3 个 Layout pages: physical `[Library, Page0, Page1, Page2]`。
- `.layoutPage(-1)`、`.layoutPage(999)`、physical `-1`、physical `999` 的 clamp。
- physical 0 不能得到普通 Layout page index。
- `physicalSurfaceCount == layoutPageCount + 1` 且至少 2。
- mapping 往返与 `Equatable/Sendable` 语义稳定。

## 验收

- `cd Packages/LaunchCore && swift test` 通过。
- 不增加 `DispatchQueue.main.sync`。
- 返回改动文件、API 说明、测试结果、偏差和未决问题；每一步用 `[PROGRESS]`。
