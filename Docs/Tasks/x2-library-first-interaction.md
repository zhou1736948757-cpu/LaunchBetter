# 任务包: X2 — App Library 进入后首次交互无效

## 用户反馈(实测)
进入 App Library 后,必须"轻点一下或划一下",才能与该面板里的软件交互(如点 App 启动)。首次点击/滚动像被"激活"消耗掉。

## 允许修改
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryViewController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryHostItem.swift`
- `Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/PausableLibraryScrollView.swift`(含在该文件内)
- `Packages/LaunchUI/Sources/LaunchUI/LauncherWindowController.swift`
- `Packages/LaunchUI/Tests/LaunchUITests/AppLibraryViewTests.swift`
- 相关测试;禁止改其它、提交、改 Launchpad_Back、改用户数据。

## 必须做的事
1. **先复现/取证**: 在 headless 用探针(可扩展现有 `--libraryblanktrace` 或新增 `--libraryinteracttrace`)或单元测试模拟:
   - 进入 Library surface(导航)后,不先做任何输入,直接向一张卡片大图标注入 mouseDown/mouseUp → 断言 `onLaunch` 是否立即触发。
   - 同样测垂直 scrollWheel 是否立即滚动。
   - 记录首次事件被谁消费/吞掉(命中 view、responder chain、arbiter 状态、momentumRoute、isScrollPaused、host cell 是否已挂载/布局、frame 是否 zero、外层面板是否先响应)。
2. **定位根因**。候选(逐一排查,用证据确认):
   - Library view 不是 first responder / key window 焦点未落到 Library(首次点击被当作"激活"点击)
   - host cell 挂载时机: 进入 surface 时 controller.view 尚未布局(首次事件时 frame 为 0,hit-test 落空)
   - PausableLibraryScrollView 轴仲裁/ momentumRoute / pendingBegan 残留状态吞掉首个滚轮
   - 外层 ClickableCollectionView/host cell 拦截首次点击
   - `window.makeFirstResponder` 未在进入 Library 时设置;搜索框是默认首响应者,首次点击被"转焦点"消耗
3. **修复**: 根因修掉(不靠"首次事件后一切正常"的巧合)。例如进入 .appLibrary surface 时把首响应设为 Library(或确保 card hit-test 从首个事件就正确);清掉进入时的残留仲裁状态;确保 host 挂载后立即布局。修复不得破坏: 空白点击隐藏、三指重分类、detail、Settings/Folder ownership、翻页。
4. **测试**: 进入 Library 后首事件直接点大图标 → 立即 launch(无需前置点击);首事件直接垂直滚 → 立即滚动;首事件直接点卡片空白 → 打开 detail(无需前置);空白首击 → 隐藏。同时保 A5/A21 既有测试不回归。

## 验收
1. LaunchUI 全绿(记录数字),Debug build OK。
2. 报告: 复现证据、根因、修复 diff、测试数。
