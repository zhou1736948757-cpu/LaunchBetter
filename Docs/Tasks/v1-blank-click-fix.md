# 任务包: V1 — Library 空白点击隐藏修复(先 trace 后修)

## 背景
v0.4.0 已有 `BlankClickLibraryCollectionView`(网格背景空白) + `PausableLibraryScrollView.onBlankClick`(文档外空白) → `AppLibraryViewController.onBlankClick → host → GridViewController.onClickBlank → hide()`。
用户实测仍不隐藏。**主控代码级怀疑**: Library 文档视图高度 = contentSize(4 列 7 卡 → 2 行 ≈ 773pt) < 视口 956pt,底部 ~183pt 空白属于 **NSClipView**;点击该区域时 hitTest 返回 clip view,`PausableLibraryScrollView.mouseDown` 根本不会触发(NSScrollView 不拦截),clip view 吞掉点击 → 空白不隐藏。
必须先 trace 确认,禁止盲修。

## 允许修改
- `Packages/LaunchUI/Sources/LaunchUI/PausableLibraryScrollView.swift`(仅修复 hitTest/mouseDown)
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryViewController.swift`(仅 trace 桥/微调)
- `LaunchBetterApp/Diagnostics/LibraryBlankTraceProbe.swift`(新增)
- `LaunchBetterApp/Diagnostics/DiagnosticRunner.swift` / `ActivationCoordinator.swift`(`--libraryblanktrace` non-interactive 注册)
- `LaunchBetter.xcodeproj/project.pbxproj`(注册新文件)
- `Packages/LaunchUI/Tests/LaunchUITests/AppLibraryViewTests.swift`
- 禁止改其它、提交、改 Launchpad_Back、改用户数据。

## 规格
1. `--libraryblanktrace`: 对每次 mouse 会话记录(合成驱动 + 真实鼠标均可,写到 /tmp/lb-library-blank-trace.log): mouseDown/mouseUp 窗口点、hitTest 命中 view 类名、集合本地点、indexPathForItem 结果、是否命中 card(primary/mini/title/卡内空白)、文档 frame、blankSession armed/release 结果、onBlankClick 各层是否调用、interactionSurface、semantic surface。
2. 用 trace 复现并确认断点(预期: 底部/边缘空白点击 hitTest=NSClipView,scroll view mouseDown 未触发)。
3. 修复: 让文档外空白区域能被 scroll view 的空白会话接管。推荐: `PausableLibraryScrollView.hitTest` 对 `hit is NSClipView`(即非卡片、非滚动条的空白区)返回 `self`,使其 mouseDown/mouseUp 走 `isScrollContainerBlank` 会话。卡片点击仍由卡自身/集合视图处理;滚动条(scroller)不拦截;detail 打开时(detail 根覆盖)不触发;搜索/设置/settings 不变。
4. 空白语义(A3/A4): 卡片之间/首行上方/底部留白/左右外距 = 页面空白 → hide;卡片内部空白 → **打开分类 detail**(不隐藏),与卡片交互对象语义一致(先确认当前行为,若卡片内部空白当前触发 detail 则保留;若触发 hide 则改为 detail)。
5. 测试(A5): 页面背景→hide 一次;卡间隙→hide;底部空白→hide;大图标→仅 launch;mini→仅 detail;标题→detail;卡内空白→detail;detail 打开外点→关 detail 且不 hide;Settings 覆盖→ownership 不变;mouseDown blank 后拖出→不 hide;无配对 mouseDown 的 mouseUp→不 hide;两次独立空白→各 hide 一次。

## 验收
1. LaunchUI 全绿(记录数字),Debug build OK。
2. `--libraryblanktrace` 输出证明修复前后断点变化。
3. 报告根因、trace 证据、修复 diff、测试数。
