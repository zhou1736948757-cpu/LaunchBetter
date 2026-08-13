# 任务包: Stage E10 fresh App Library visual evidence

## 背景

Stage E 数据、UI、leading surface、ownership、axis arbitration 已通过当前自动化门禁。需要从 fresh Debug binary 生成真实 AppKit layer-render PNG，不能用历史截图或 `cacheDisplay` 假装视觉验证。

## 允许修改的文件

- `LaunchBetterApp/Diagnostics/DiagnosticRunner.swift`
- `LaunchBetterApp/Diagnostics/ActivationCoordinator.swift`
- `LaunchBetterApp/Diagnostics/AppLibraryShotProbe.swift` (新增)
- `Packages/LaunchUI/Sources/LaunchUI/LauncherWindowController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift`
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryViewController.swift`

禁止修改其它文件、禁止提交、禁止切换分支、禁止修改旧仓库或现有未跟踪文件。

## 诊断接口

增加非交互 flag:

```text
--libraryshot <output.png>
--library-state top|mid|detail|search|settings
```

默认 `top`。Probe 必须:

1. 等待依赖/窗口初始化完成。
2. show Launcher，使用公开诊断 seam 从默认 Page1 导航到 Library。
3. `top`: Library 顶部。
4. `mid`: Library 内垂直滚动到约 45%-60%（若内容不足，记录 stable no-op）。
5. `detail`: 打开第一个 category detail，等待布局。
6. `search`: 在 Library surface 设置 query，刷新现有 Search UI。
7. `settings`: 从 Library 打开 Settings；至少输出 parent Library screenshot 和 Settings screenshot，或生成同一 backing scale 的明确 composite。
8. 使用已有 `LauncherWindowController.captureContentScreenshot(to:)` layer render；禁止 `cacheDisplay`/screencapture。
9. PNG 写完打印 state、surface、尺寸、backingScale、visible/card/detail counts 后退出 0；失败退出 1。

`ActivationCoordinator` 将 `--libraryshot` 视为 non-interactive，不能弹辅助功能权限提示。

## 生产 seam 约束

- 诊断方法只导航/读取，不写 Layout、Config、Usage，不改变普通用户持久化。
- `show` 默认 Page1；probe 用现有 semantic `previousPage`/surface seam，不写 clip offset。
- detail open/close 使用 AppLibrary callback/owner，不复制 transition engine。
- mid scroll 只改变 Library session 内 vertical offset，probe 结束前不触发 catalog scan。
- 不增加 `DispatchQueue.main.sync`。

## 验收

- `xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter build` 通过。
- 运行 fresh binary 生成至少 `top/mid/detail/search` 四张 PNG；`settings` 尽力生成并记录限制。
- 当前对话主代理实际读取所有 PNG，不能只信 probe 文本。
- PNG 交给 visual reviewer，输出 BLOCKER/MAJOR/MINOR/PASS；主代理用图像事实复核，视觉误报不直接采纳。
- 返回命令、路径、尺寸/scale、surface/model 状态、失败限制；每一步用 `[PROGRESS]`。
