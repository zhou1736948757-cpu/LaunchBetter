# 任务包: Stage E5 PagingGridLayout leading special section

## 背景

Architecture Note 已决定: physical section 0 是 App Library host，普通 Layout section 从 physical 1 开始；普通 `GridGeometry` 不认识 Library 卡片，只继续计算 Layout page 的局部 slot 几何。

本任务只改分页布局数学，不接 `GridViewController` data source、不改 LayoutStore、不做 Library UI。

## 允许修改的文件

- `Packages/LaunchUI/Sources/LaunchUI/PagingGridLayout.swift`
- `Packages/LaunchUI/Tests/LaunchUITests/LeadingSurfaceLayoutTests.swift` (新增)

禁止修改其它文件、禁止提交、禁止切换分支、禁止修改旧仓库或现有未跟踪文件。

## 设计要求

- 增加窄的 `leadingSurfaceEnabled` 或等价属性，默认 false，保持所有现有普通布局测试行为不变。
- paged mode 且 enabled 时:
  - section 0 的 host item frame 为完整 page rect `(x: 0, y: 0, width: pageWidth, height: pageHeight)`。
  - physical section `p >= 1` 的普通 item 使用 `normalPage = p - 1` 的 `GridGeometry.frame(forSlot:in:)`，再加 `x += pageWidth`。
  - content width 仍为 physical section count × pageWidth；高度仍跟随 clip viewport。
- enabled=false 时与当前 section/page 几何完全一致。
- search mode 不使用 leading special section；保留当前单 section vertical search 语义。
- layout attributes、item frame cache、candidate section query、invalidate/resize 在两种模式下都要一致。
- 不把 Library 卡片塞进 `GridGeometry.frame(forSlot:)`，不引入负 offset。

## 必写测试

- disabled 回归: 普通 section 0 slot frame 与现有几何一致。
- enabled: section 0 host full page；section 1 slot 0 位于 x=pageWidth、对应普通 page 0；section 2 对应普通 page 1。
- content width 对 physical sections 正确。
- resize/leading toggle invalidate 后 frame 不残留。
- search mode 不应用 leading host 偏移。
- attributes query 不把所有 sections 当成普通 page slots。

## 验收

- `cd Packages/LaunchUI && swift test` 通过。
- `xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter build` 通过。
- 不增加 `DispatchQueue.main.sync`，不逐帧 Diffable snapshot。
- 返回改动文件、几何映射、测试结果、偏差和未决问题；每一步用 `[PROGRESS]`。
