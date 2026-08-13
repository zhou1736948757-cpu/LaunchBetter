# 任务包: Stage E9a Library interaction ownership

## 背景

E8 已把 App Library 作为 physical section 0 接入 Grid，E6 detail 已支持 Escape/outside/select callback，但 LauncherInteractionSurface 仍只有 launcher/folder/settings。本任务建立 Library/category detail 的唯一 input owner，并保证 Settings 从 Library 打开后回 Library。

## 允许修改的文件

- `Packages/LaunchUI/Sources/LaunchUI/LauncherInteractionOwnership.swift`
- `Packages/LaunchUI/Sources/LaunchUI/LauncherWindowController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryViewController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryHostItem.swift`
- `Packages/LaunchUI/Tests/LaunchUITests/AppLibraryInteractionOwnershipTests.swift` (新增)

禁止修改其它文件、禁止提交、禁止切换分支、禁止修改旧仓库或未跟踪用户文件。E9b axis router 另行处理，不在本任务修改 PagingGridLayout 或新增第二套 paging engine。

## Ownership 状态

扩展 `LauncherInteractionSurface`:

```swift
case launcher
case appLibrary
case appLibraryCategory
case folder
case settings
```

关联值不是必须；Category identity 已由前景 AppLibraryViewController 持有。所有新增状态必须同步更新现有 switches/guards，不能只加 enum case。

## Grid callbacks

在 Grid 增加窄 callback/seam:

- `onSurfaceChange: ((LauncherSurface) -> Void)?`
- `onAppLibraryCategoryDetailChange: ((Bool) -> Void)?`
- `closeAppLibraryDetail()` 或等价窄 API

`setCurrentSurface` 变更时通知 WindowController。Host 将 AppLibraryViewController 的 detail state callback 转发给 Grid/Window。Category detail 打开/关闭必须 generation-safe、幂等。

## Window owner 规则

- surface `.appLibrary` → `interactionSurface = .appLibrary`，保留 paging 可用，但 root App drag、three-finger drag、create folder、ordinary Grid launch/context menu/blank hide 必须被阻断；Library 自身 launch 仍通过注入的 Store callback。
- surface `.layoutPage` → `interactionSurface = .launcher`。
- detail open → `.appLibraryCategory`；暂停 outer paging、Library scroll、root drag、three-finger 和普通 Grid input；detail 负责 Escape/outside/click 完整序列。
- detail close → `.appLibrary`；恢复 paging，但不让同一次 outside mouseUp 穿透到 Grid/hide。
- Settings 打开前取消 drag、关闭 Folder；若当前 surface 是 Library 或 Category detail，关闭 detail并记录 `settingsReturnSurface = .appLibrary`。Settings close/re-present/fallback 完成后恢复该 surface，而不是盲目写 `.launcher`。
- Settings shield 继续消费完整 mouseDown/dragged/up/right/other/scroll sequence。
- Folder 只从普通 `.launcher` AppCell 打开；Library active 不得调用 `onOpenFolder`。

## Keyboard / Escape

- `.launcher` 和 `.appLibrary` 可以响应 Left/Right/PageUp/PageDown；Library previous → Page1，Page1 previous → Library。
- `.appLibrary` Return 可启动 Search first result/当前可访问 launch 语义，不触发底层 Grid 空白 hide。
- `.appLibraryCategory` Left/Right/Return/底层 paging/drag 全部阻断。
- Escape 顺序: Settings close → Category detail close → Folder close → Library/Launcher hide；detail close 不让同键继续触发 hide。
- stale detail close completion 不得释放新 surface owner。

## 鼠标/三指门控

- 现有 `ClickableCollectionView` root mouse callbacks 在 `.appLibrary` / `.appLibraryCategory` 不得开始/更新/结束 ordinary DragController session。
- threeFinger begin/update/end 仅 `.launcher`；Library/category/settings/folder 全部静默拒绝并清理晚到事件。
- AppLibrary card 大图标 launch、mini/detail 和 detail row launch 是前景 surface 自有路径，不经过 root Grid drag gate。

## 必写测试

- enum/surface route: launcher ↔ appLibrary ↔ appLibraryCategory，Settings return 保持 Library。
- Library active 阻断 root mouse drag、three-finger、folder open、blank hide；Library card launch callback 仍工作。
- Category detail active 阻断 paging/drag/scroll/keyboard，Escape/outside close 只释放一次。
- stale close/fallback completion 不得释放新 category/settings owner。
- Settings mouse sequence 完整消费后不产生底层 mouseUp/click/hide。
- hide/show 清理 detail，最终 Page1/Library transient state reset。
- 现有 Settings/Folder/InputEnd/Paging suites 全绿。

## 验收

- `cd Packages/LaunchUI && swift test` 通过。
- `xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter build` 通过。
- `DispatchQueue.main.sync` 仍为 0。
- 返回 ownership 状态机、Settings return、测试结果、偏差和未决问题；每一步用 `[PROGRESS]`。
