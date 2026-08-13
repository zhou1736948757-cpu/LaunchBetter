# 任务包: Stage E Search surface restore 基线修复

## 背景

当前 `GridViewController.applyLatestData()` 在退出 Search 时，先调用 `exitSearchMode()`，但仍用搜索态 `pageCount == 1` clamp `pagedPageBeforeSearch`，导致从普通第 2 页或更后页清空搜索后错误回到 Page 1。Stage E 要求未来恢复 semantic `surfaceBeforeSearch`，本任务先修复现有普通页 restore 基线。

## 允许修改的文件

- `Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift`
- `Packages/LaunchUI/Tests/LaunchUITests/SearchPageRestoreTests.swift` (新增)

禁止修改其它文件、禁止提交、禁止切换分支、禁止修改旧仓库或现有未跟踪文件。

## 约束

- 退出 Search 后必须先恢复普通 display model/pageCount，再 clamp 原 page，再通过现有 paging writer jump 到目标；不能直接写 clip view offset。
- 用一个小型纯函数/静态 helper 集中 clamp 语义，避免测试依赖 AppKit 私有状态。
- 不改变 `hide()` 的默认回 Page 1 语义。
- 不在本任务引入 AppLibrary surface；后续 E5 会把保存值升级为 semantic surface。
- 不增加 `DispatchQueue.main.sync`，不逐帧 snapshot。

## 必写测试

- before page 0/1/2 与 pageCount 1/2/3 的恢复 clamp。
- 负数和超界页的确定性 clamp。
- pageCount 至少按 1 处理。

## 验收

- `cd Packages/LaunchUI && swift test` 通过。
- `xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter build` 通过。
- 返回改动文件、恢复顺序、测试结果、偏差和未决问题；每一步用 `[PROGRESS]`。
