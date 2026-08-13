# 任务包: Stage E11 App Library 视觉细化(用户实机反馈)

## 背景(用户实机反馈 + 截图/OCR 证据)

用户实测安装版后反馈:
1. App Library 卡片与底部搜索栏、右下设置齿轮 UI 重叠。
2. 卡片是比例失调的长方形(实测 474×280, 约 1.7:1), 希望改成正方形(保留圆角)。
3. 卡片两侧要留一点空, 卡片之间的空("中间")要稍微少一点。
4. 参考苹果 App Library 设计(正方形圆角卡片、2-4 列、统一间距)。

证据: `/tmp/lb-e10/user-report-top.png`(Release 版 fresh layer-render);
窗口 1470×956pt, 第 3 行卡片 628..908pt, 搜索栏 873.5..900pt, 齿轮右下约
(1400..1440, 906..946) → 底部重叠约 34pt; 右侧卡片与齿轮区域重叠。

## 允许修改的文件

- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryLayout.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryViewController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryCardCell.swift`(仅当方形卡内容布局必须微调时)
- `Packages/LaunchUI/Tests/LaunchUITests/AppLibraryLayoutTests.swift`
- `Packages/LaunchUI/Tests/LaunchUITests/AppLibraryViewTests.swift`

禁止修改其它文件; 禁止提交/切分支/改旧仓库; 保留用户未跟踪文件。

## 规格(必须逐条满足)

1. **方形卡片**: `AppLibraryLayoutMetrics.cardHeight(forWidth:)` 改为正方形
   (height = width), 保留有界 clamp(建议 [240, 430], 与 width 范围一致)。
   保持 `preferredCardWidth`/`maxCardWidth`/`minCardWidth` 语义不变。
2. **侧边留空**: 网格模式内容区增加水平 edge inset(默认 24pt, 两侧各 24),
   `contentWidth` 计算纳入 insets; 列数计算仍按有效宽度。
3. **中间间距更小**: `defaultSpacing` 与 `defaultRowSpacing` 24 → 16。
4. **顶部不再与搜索栏/齿轮重叠**(2026-08-13 主控复核修正方向): 启动器窗口的
   搜索栏在**顶部居中**(`searchFieldTopConstraint` 挂 topAnchor)、齿轮在
   **右上角**。Library host 占满整页, 所以卡片顶行压在 chrome 下。
   修复: `AppLibraryViewController` 增加 `setContentInsets(top:bottom:)`,
   把宿主窗口层的顶部保留区(GridViewController 的 `gridLayout.topInset`,
   搜索框+间距)传入 `AppLibraryLayout.contentInsets.top`; 底部保留带改为
   默认小 padding(20)。`AppLibraryHostItem` 转发并缓存 insets(controller
   创建前/后都要正确应用);`GridViewController.setContentInsets` 同时更新
   hostItem;host cell 配置时用当前 insets。第一行卡片 minY == topInset。
   移除上一轮错误的 `defaultLibraryBottomInset = 56` 常量及其用法。
5. **圆角不变**(14)。
6. 卡片内容布局在方形下仍合理: 标题顶部、大图标区、mini 区底部;
   上一轮已把 `primaryIconSize` 上限提到 76、mini 提到 32, 保留。

## 必写/更新测试

- `AppLibraryLayoutTests`: 更新 cardHeight 相关断言为正方形;
  新增/改写: 顶部保留带不重叠断言(第一行 minY == contentInsets.top);
  最后一行底部 ≤ contentSize - bottomInset; edge inset 与 16pt 间距断言;
  frame 确定性。
- `AppLibraryViewTests`: 若引用旧数值则更新。
- 全量 LaunchUI 测试必须通过。

## 截图管线方向修正(2026-08-13 主控复核)

当前 launcher PNG 与屏幕上下颠倒(证据: 代码搜索栏锚定顶部, MEMORY v0.3.1
齿轮右上角, 但 PNG 中搜索栏/齿轮在底部、Suggestions 卡在底部)。
修复: `LauncherWindowController.captureContentScreenshot` 移除
`context.translateBy(x:0,y:contentView.bounds.height)` 与
`context.scaleBy(x:1,y:-1)` 两行(仅保留 `scaleBy(x:scale,y:scale)`),
launcher contentView 为 flipped, layer.render 天然 top-down。
Settings 窗口(contentView 非 flipped)的 `captureSettingsWindow` **保持**
现有 y-flip 不变。改后用 `/tmp/lb-e10/ocr` 验证 fresh PNG:
"搜索应用" 必须出现在图像顶部区域(y≈0.9), Suggestions 卡在顶部,
齿轮在右上;文字方向仍须可读(isGeometryFlipped 校正保持)。
若移除 y-flip 后文字方向变化, 按需调整探针校正并报告。

## 验收

1. `cd Packages/LaunchUI && swift test` 全绿。
2. `xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter -configuration Debug build` 成功。
3. 生成 fresh `--libraryshot top/mid` PNG: 主控用 OCR 验证
   (a) 搜索栏在图像顶部, 齿轮右上; (b) 第一行卡片不与搜索栏/齿轮重叠;
   (c) 卡片方形、两侧留白 24、间距 16。
4. 输出: 改动清单、假设、测试结果、与规格的偏差。
