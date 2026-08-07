# Phase 3 — Minimal Launcher

## Scope

首个可运行的启动器: Xcode 工程、LaunchBetterApp target、LaunchUI 包、
NSCollectionView 分页网格、搜索、点击启动、无障碍基础、多显示器基础。
占位图标(真实图标 Phase 4)。

## Implementation Summary

- **Xcode 工程**: xcodegen 2.46.0(brew 安装)生成 LaunchBetter.xcodeproj,
  project.yml 为单一事实源;3 个本地包 + LaunchBetterApp target(bundle ID
  dev.launchbetter.LaunchBetter, macOS 14+)
- **LaunchUI 包**: LauncherWindow(无边框、canBecomeKey/Main、level=.floating、
  多屏跟随鼠标)、PagingGridLayout(基于 Phase 1B 验证的布局)、AppCellView
  (CALayer 占位图标 + 首字母 + 标签 + 无障碍 label/role/help)、GridViewController
  (DiffableDataSource、分页/搜索双模式、滚轮/键盘翻页、点击启动)、
  LauncherWindowController(搜索栏、显示/隐藏淡入淡出、Escape 隐藏、Return 启动首项)
- **LaunchBetterApp**: AppDelegate(菜单、reopen toggle、--screenshot/--smoke 调试模式)、
  DependencyContainer、LauncherStore(MainActor,缓存快照;启动同步恢复快照 →
  后台对账 → applySnapshot;陈旧防护经 actor 串行化)、LauncherWindowCoordinator
- **架构调整**: AppCatalogActor 全部方法改 async(actor 隔离);LauncherStore 在
  MainActor 持有快照缓存(后台服务返回 Sendable,MainActor 应用,§62)
- **DisplayModel 修复**: 派生页按 pageCapacity 重新分块(此前布局页可超容量,
  导致 87 项挤一页);布局行列与配置一致(gridColumns/gridRows 经协议注入)

## Important Files

- project.yml + LaunchBetter.xcodeproj(生成)
- LaunchBetterApp/ (5 文件)
- Packages/LaunchUI/Sources/LaunchUI/ (7 文件)
- Packages/LaunchCore DisplayModel(分块)、LaunchPlatform AppCatalogActor(async)

## Tests

- LaunchCore: 82/82(新增"超容量页重分块")
- LaunchPlatform: 31/31(适配 async API)
- 冒烟验证(--smoke): catalogApps=87(真实系统)、layoutPages=3(42/页,容量 42)、
  search "chrome"→1、窗口可见、网格 3 sections/87 items、
  **真实启动验证**: 经 NSWorkspace.open 成功拉起 Google Chrome
- 持久化跨重启: 快照恢复(catalogApps=87 来自磁盘)

## Build Results

- xcodebuild Debug: SUCCEEDED
- 全部包测试通过

## Performance Results

- 未正式测量(LauncherShow signpost 待 Phase 4+ 统一接入);
  首帧同步快照加载路径已就绪(< 10ms 目标待验证)

## Review Results

- 视觉评审: **降级**。Luna 图像通道不可用(当前模型栈不支持图像输入,
  read 工具无法接收图片,子代理重试确认)。截图已存档
  Docs/Visual/phase-03-launcher.png,待支持视觉的模型评审。
  按 §17 降级链执行了确定性布局验证替代。
- 自查发现并修复: 页面未按容量分块、布局行列与配置不一致、冒烟查询选词
  (safari 本机不存在)、NSScreen 可选值 `??` 推断怪癖

## Architecture Deviations

- DisplayModel 从"保留布局页结构"改为"按容量重分块"(UI 需要;Phase 1C
  报告的推迟项在此落实,报告已记录)
- 截图方案: screencapture 因 TCC 屏幕录制权限不可用,改为应用自渲染
  (bitmapImageRepForCachingDisplay,无需权限)+ --screenshot 参数
- NSScreen `??` 怪癖记录: Swift 6.3 + macOS 26 SDK 下
  `NSScreen? ?? NSScreen?` 保留 Optional,必须 if-let 显式解包

## Known Limitations

- 无真实图标(占位色块);热键/手势/热角激活(Phase 8);文件夹(Phase 5);
  拖拽(Phase 6);壁纸模糊(Phase 9)
- 启动路径为启动即显示 + Dock reopen toggle(临时激活方式)
- 视觉证据待支持图像的模型评审

## Commit Range

TBD(Phase 3 提交)

## Remaining Risks

- 无阻塞项。120Hz 验证仍受限于本机 60Hz 显示器(Phase 1B 记录)。

## Next

Phase 4 — Icon Pipeline:
内存 LRU(字节成本)+ 磁盘缓存 + IconKey 变体 + 稳定 IconContentVersion
(补齐图标资源信号)+ in-flight 去重 + 消费者取消 + 可见页优先 + 内存压力裁剪
+ AppIconProvider。GLM Max 评审要求(限制记录)。
