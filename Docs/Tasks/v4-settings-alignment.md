# 任务包: V4 — Settings 表单对齐(标签列 + 值列)

## 背景
用户截图显示 Settings 控件/复选框/下拉在不同水平位置开始(NSStackView([label, control]) spacing=8,label 宽度不一)。要求所有行共享稳定的值/控件列,控件整体右移对齐。禁止给单个控件乱加偏移;禁止改整体面板尺寸/材质/设计。

## 允许修改
- `Packages/LaunchUI/Sources/LaunchUI/SettingsWindowController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/`(如新增小型 `SettingsFormRow` 复用组件)
- `Packages/LaunchUI/Tests/LaunchUITests/`(Settings 相关测试: `SettingsWindowLiveTests`/`L10nTests` 等,如引用布局)
- 禁止改其它、提交、改 Launchpad_Back。

## 规格
1. **根因**(A22): 现有 `row(_ title, _ view)` 用 `NSStackView(views:[label, view]) spacing=8`;label 宽度可变 → 控件 x 参差。不修根因,只给个别控件加偏移 = 失败。
2. **两列表单**(A23/A24): 创建真实的 标签列 + 值列。优先:
   - 复用/改造既有 `NSGridView`(buildContent 里已有一个未用的 NSGridView,先审计它应改造还是删除,不留死对象),或
   - 新增小型 `SettingsFormRow`(label + value 视图,值列等宽,复用)。
   - 结构: 左侧垂直 section 栈,每个 section: header + 行网格(label 列 + value 列)。
3. **值列对齐**(A25): 共享 label 列宽 = section 内 max intrinsic label 宽 + gap(有界);中文起始区间 ~105-125pt 作调试范围;三语(简中/繁中/英文)都要验证,英文长标签截断/换行得体,不得把控件顶乱。
4. **复选框/热键**(A26): `showLabelsCheck`、`hotkeyCheck` 必须与值列对齐;热键值列可内嵌横向 stack `[✓ 启用][⌘L ▾]`;不允许"启用"复选框回到最左 margin。
5. **原生下拉**(A27): 不 hack NSPopUpButton 的弹出菜单屏幕定位;只对齐闭合控件/行;除非运行时证据证明控件本身错位。
6. **不回归**(C): 不整体平移面板、不改窗口尺寸掩盖问题;设置交互所有权/语言即时切换/隐藏应用/自定义来源等行为不变。

## 必写/更新测试
- 行帧: 每行 value 控件 minX 一致(在 section 内/或全表单,按实现)
- showLabels/hotkey 复选框与值列对齐
- 四热角/图标尺寸/语言/模糊/搜索栏尺寸 slider 值列一致
- 三语 label 不溢出、控件不被挤出
- 既有 Settings 行为测试不回归

## 验收
1. LaunchUI 全绿(记录数字),Debug build OK。
2. 生成三语 fresh Settings 截图(`--settingsshot` + 设置语言后),主控用 OCR/像素测量核对值列对齐。
3. 报告: 旧布局根因、新表单架构、三语证据。
