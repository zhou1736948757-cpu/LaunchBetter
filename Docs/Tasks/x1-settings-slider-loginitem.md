# 任务包: X1 — Settings 滑杆修复 + 开机自动启动选项

## 用户反馈(实测)
1. Settings 里"模糊强度/尺寸百分比"滑杆调不动(拖不了/无效)。v0.4.0 之前可调;V4 表单对齐重构(NSGridView + SettingsFormRow)后失效。`valueChanged→commit` 逻辑未变,疑 NSGridView 布局让滑杆宽度退化/被遮挡/无 hit 区域。
2. 新增设置项: 是否**开机自动启动**(login item)。

## 允许修改
- `Packages/LaunchCore/Sources/LaunchCore/AppConfiguration.swift`(或配置模型所在)
- `Packages/LaunchPlatform/Sources/LaunchPlatform/Stores.swift`(SettingsStore 持久化,如需要;AppConfiguration 自带 schemaVersion=1,decodeIfPresent 缺省)
- `Packages/LaunchUI/Sources/LaunchUI/SettingsWindowController.swift`(滑杆修复 + 开机项 UI)
- `Packages/LaunchUI/Sources/LaunchUI/SettingsFormRow.swift`(如需要)
- `Packages/LaunchUI/Sources/LaunchUI/L10n.swift`(三语 key)
- `Packages/LaunchUI/Sources/LaunchUI/LauncherStoring.swift`(协议,如需要)
- `LaunchBetterApp/LauncherStore.swift`(save 应用 launchAtLogin / onConfigChange 处理)
- `LaunchBetterApp/AppDelegate.swift`(启动时应用 launchAtLogin 状态)
- `LaunchBetterApp/DependencyContainer.swift`(如需要)
- 相关测试
- 禁止改其它、提交、改 Launchpad_Back、改用户持久数据(测试用临时目录)。

## 规格

### 1. 滑杆修复
- 先测量取证: 运行时打印 `blurSlider.frame / isEnabled / isHidden / superview / window / intrinsicContentSize / sliderType`、所在 NSGridView 列宽、是否有覆盖视图。判定是"宽度退化/被遮挡/事件未达/值被回跳"。
- 修复根因(不允许只是把滑杆从 grid 挪走再碰巧能用,除非证明 grid 是根因): 保证滑杆有可用宽度与命中区、能拖动、值即时生效(模糊/搜索栏宽度即时改变),三语下均可调。
- 回归: 值列对齐保持(这是 v0.4.1 卖点,不能因修复滑杆而错位)。

### 2. 开机自动启动
- 配置: `AppConfiguration.launchAtLogin: Bool`(默认 false, decodeIfPresent 缺省 false, 保留旧文件)。
- 应用: 用 **SMAppService**(macOS 13+, 本工程 target 14.0 可用)注册/注销 `SMAppService.mainApp`:
  - 启动时按配置应用一次;
  - 设置变更(launchAtLogin checkbox)即时注册/注销;
  - 失败不崩溃,记录状态(SMAppService 在非 /Applications 运行会失败,诊断打印即可)。
  - 实现可放 `LaunchBetterApp/LoginItemController.swift`(或等效小组件)。
- UI: Settings 表单新增一行"开机自动启动"(三语: 开机自动启动 / 開機自動啟動 / Launch at Login)checkbox,复用 SettingsFormRow 值列对齐;放合适 section(可新增"通用/General"或并入热键所在区,按美观)。
- 持久化: SettingsStore 保存(经 AppConfiguration 既有持久化,无额外 schema 升级即可;若 AppConfiguration 解码需要,保持向后兼容)。
- 不动 Launchpad_Back、不动 LayoutStore。

### 测试
- 滑杆: 构造后 frame 宽 > 阈值;setDoubleValue + sendAction → commit 读值正确;模糊/搜索栏宽度应用路径(可注入 handler)值变化。
- 开机项: config roundtrip(launchAtLogin 保留);decodeIfPresent 旧文件缺省 false;checkbox 状态绑定 config;toggle 调 handler.save 并应用 SMAppService(测试注入 fake login item controller 断言 register/unregister 调用)。
- 既有 Settings 行为测试不回归;值列对齐测试保留。

## 验收
1. LaunchCore / LaunchPlatform / LaunchUI 全绿(记录数字),Debug build OK。
2. Settings fresh 截图(三语可选一张)+ 滑杆 frame 测量报告。
3. 报告: 滑杆根因与修复、开机项架构(SMAppService 应用点)、测试数。
