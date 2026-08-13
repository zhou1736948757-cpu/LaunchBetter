# 任务包: PA3 — App Library 空白点击隐藏

## 背景
普通 Launcher 空白点击已隐藏(`grid.onClickBlank → LauncherWindowController.hide()`)。Library host 占满整页,外层 ClickableCollectionView 不拥有 Library 空白点击 → 需在 Library 内部实现空白语义并复用既有 hide 路径。

## 允许修改的文件
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryViewController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryHostItem.swift`
- `Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift`
- `Packages/LaunchUI/Tests/LaunchUITests/AppLibraryViewTests.swift`
- `LaunchBetterApp/LauncherStore.swift`(仅当需要新接口;尽量复用)
- `LaunchBetterApp/DependencyContainer.swift`(仅当必须;尽量不复用)

禁止改其它文件、提交、切分支、改旧仓库。

## 规格
1. "真空白"定义: 点击不在
   - 分类卡片上(LibraryCardRootView 自己消费了)
   - 大图标 / mini 簇 / 标题
   - 分类 detail 打开时(detail 根视图自己消费)
   - 搜索 / 设置 / 滚动条
2. 实现: 在 `AppLibraryViewController` 内处理空白点击。
   - 空白 = 点在 Library 网格集合视图背景(indexPathForItem == nil)或 scroll 容器非卡片区域。
   - 事件所有权(A19): mouseDown 在空白 → mouseUp 在空白且位移 ≤ 阈值(6pt) → 回调 `onBlankClick`;**一次**隐藏。mouseDown 后拖走(mouseUp 超出)→ 不触发。绝不透传/启动/拖拽/开卡/重开 Launcher。
   - 建议子类或拦截: 在 LibraryCollectionView/PausableLibraryScrollView 实现 mouseDown/mouseUp 会话(类似 ClickableCollectionView 的模式),空白命中才记录;卡片区域由卡片自身消费,不会到这。
   - detail 打开时(isScrollPaused / detailController != nil)不得触发空白隐藏。
3. 转发链路: `AppLibraryViewController.onBlankClick` → `AppLibraryHostItem.onBlankClick` → `GridViewController` 复用其 `onClickBlank`(已 → window hide)。**不得新建第二套 hide 实现**。
4. Settings/Folder 现有 ownership 规则保持。

## 必写测试
- 真空白 → hide 回调一次
- 卡片区域点击 → 无 blank 回调
- 大图标 → 仅 launch(无 blank)
- mini/标题 → 仅 detail(无 blank)
- 空白 mouseDown 后拖出 mouseUp → 无 blank
- detail 打开时点空白 → 无 blank(关闭 detail 而非隐藏)
- 连续两次空白点击 → 各一次回调(每次独立会话)

## 验收
1. LaunchUI 测试全绿。
2. Debug build 成功。
3. 输出改动清单、测试数、偏差。
