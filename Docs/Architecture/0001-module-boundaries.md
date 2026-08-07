# 0001 — 模块边界与运行时管道

> 状态: Accepted | 日期: 2026-08-08 | 相关阶段: Phase 0/1

## 决策

LaunchBetter 由三个本地 Swift 包 + 一个应用 target 组成,依赖方向严格单向:

```
LaunchCore (纯逻辑,无 AppKit/SwiftUI/Combine/FileManager)
   ↑            ↑
LaunchPlatform  LaunchUI
   ↑            ↑
        LaunchBetterApp
```

## 模块职责

### LaunchCore
纯 Swift、Sendable、可确定性测试。禁止任何平台框架与文件系统访问。
持有: AppID / AppRecord / FolderID / FolderRecord / LayoutItem / LayoutSnapshot /
MissingAppState / LayoutReconciler / LayoutTransaction / DisplayModel / CatalogSnapshot /
CatalogDelta / IconKey / IconContentVersion / AppConfiguration / HotkeyConfig /
HotCornerConfig / SearchIndex。

AppID 创建只做纯确定性变换(URL 语法标准化、尾斜杠、稳定序列化),禁止文件系统访问。

### LaunchPlatform
平台边界: PathCanonicalizer(文件系统大小写/symlink/private-var 收敛)、
AppDiscoveryService、AppCatalogActor、SnapshotStore、StateMigration、IconRepository
(内存 LRU + 磁盘 + AppIconProvider)、DirectoryMonitor(FSEvents)、
GestureCaptureEngine(MultitouchSupport 隔离)、WallpaperProvider。

禁止依赖 LaunchUI / LauncherStore。私有框架(MultitouchSupport)只允许在此层,
C 指针包装保持窄接口,`@unchecked Sendable` 必须记录理由。

### LaunchUI
AppKit 启动器: LauncherWindow/Controller、NSCollectionView + DiffableDataSource、
AppCell、DragOverlay、FrameCoordinator、CADisplayLink、设置界面。

### LaunchBetterApp
组装: AppDelegate、DependencyContainer、LauncherWindowCoordinator。无业务逻辑。

## 四运行时管道(禁止坍缩)

- A 目录数据: Filesystem → Reconcile → AppCatalogActor → CatalogDelta
- B UI 结构: Catalog + Layout + Config → DisplayModel → DiffableDataSource → NSCollectionView
- C 图标资源: AppCell → IconRepository → Memory → Disk → Live Provider → CGImage → CALayer
- D 逐帧交互: Gesture input → GestureSampleBuffer(仅最新样本) → CADisplayLink → FrameCoordinator → CALayer transforms

## 持久化分离

- 持久用户数据: `~/Library/Application Support/dev.launchbetter.LaunchBetter/`
  (CatalogSnapshot / LayoutSnapshot / Settings / LaunchHistory / CustomNames / StateMetadata)
- 可再生缓存: `~/Library/Caches/dev.launchbetter.LaunchBetter/`(图标变体、壁纸渲染缓存)
- 全格式 schemaVersion,原子写入(temp + fsync + replace),损坏处理: 缓存删除重建、持久状态不静默清除

## 并发规则

- MainActor: LauncherWindowController / LauncherStore / 窗口可见性 / 当前页 / 选中 / 搜索文本
- 后台 actor: AppCatalogActor / IconRepository / LayoutStore / SettingsStore / LaunchHistoryStore
- 每帧状态(拖拽位置/动画进度/手势帧)不得进 LauncherStore
- 仓库级 `DispatchQueue.main.sync` = 0
- 陈旧结果防护: 每次异步结果校验 identity + generation token + cancellation + owner lifecycle
- 后台任务返回 Sendable 值,MainActor 应用;禁止后台持有 UI 所有者

## 图标缓存身份

IconKey = AppID + pointSize + scale + contentVersion。
磁盘缓存禁止仅以 hash(AppID) 命名。contentVersion 基于真实内容信号
(图标资源高精度 mtime/大小、Info.plist mtime),禁止用 reconcile 代数。
内存缓存: 显式 dict + LRU + 字节成本限制(≈bytesPerRow × height),不用 NSCache。
in-flight 去重必须在首个挂起点前注册。

## 启动契约

- 启动: 读 CatalogSnapshot → LayoutSnapshot → Settings → 构建 DisplayModel → 可用 → 后台 reconcile
- 启动器显示: 0 扫描 / 0 Info.plist IO / 0 图标重扫(Phase 2 起不变式)
- 普通应用启动(didLaunchApplicationNotification): 只更新 LaunchHistoryStore

## 参考

- 旧版失败类与已验证行为: Docs/PhaseReports/phase-00-bootstrap.md
- 工程规则: AGENTS.md
