# LaunchHistory → LaunchBetter Feature Parity Matrix

> Stage 2 证据驱动审计。全部旧侧结论来自 `/Users/mac/Projects/Launchpad_Back` 源码核对(explore agent 只读审计 + 人工复核)。
> 禁止凭项目名/README/MEMORY 推断功能。Status 枚举见各表。

## 审计结论汇总

| # | Feature | Old Source Evidence | Old Behavior | Current LaunchBetter Evidence | Status | Migration Decision | Notes / Risk |
|---|---------|--------------------|--------------|-------------------------------|--------|--------------------|--------------|
| 1 | App launching | AppLauncherService.launch/launchAsync; NSWorkspace.open | 单击启动; NSWorkspace.open | LauncherStore.launch → NSWorkspace.shared.open | VERIFIED_PARITY | 无 | 一致 |
| 2 | Horizontal paging | PaginationViewModel; PageViewEditable.offset; threshold=50, velocity=200 | 横向分页, 拖拽/滚轮/键盘 | PagingInteractionController + PagingGridLayout(分页) | VERIFIED_PARITY | 无 | LaunchBetter 更完整(跟手+吸附) |
| 3 | Vertical layout | ViewLayoutMode.verticalScroll; VerticalScrollView | 连续垂直滚动(非分页) | 无 | VERIFIED_MISSING | 下一阶段(§33) | 本阶段不实现 |
| 3b | Vertical paging | 无翻页实现 | 无 | — | OLD_FEATURE_NOT_PROVEN | 不实现 | — |
| 4 | Search | SearchBarView; SearchViewModel; filteredApps; SearchIndexEntry | 名称/bundleID/path 子串搜索, 带缓存 | SearchIndex(LaunchCore)+ 垂直结果网格 | VERIFIED_PARITY | 无 | LaunchBetter 支持 >42 结果滚动 |
| 5 | Persistent ordering | orderKey="launchpad_item_order"; saveDebounce 0.5; UserDefaults | 持久排序, 防抖保存 | LayoutStore 持久化 + DisplayModel | VERIFIED_PARITY | 无 | — |
| 6 | Folders | AppFolder; createFolder; foldersKey="launchpad_folders" | 文件夹创建/持久 | LayoutStore.folders + 文件夹视图 | VERIFIED_PARITY | 无 | — |
| 7 | Folder rename | renameFolder; FolderExpandedView.onRename | 展开视图内重命名 | 右键菜单 rename | VERIFIED_PARITY | 无 | — |
| 7b | Folder dissolve | removeAppFromFolder(≤1 app 自动解体); deleteFolder 无调用点 | 仅自动解体可达 | dissolveFolder(右键菜单) | VERIFIED_PARITY | 无 | LaunchBetter 有显式解散入口 |
| 8 | Drag reorder | moveItem; LongPress 0.2s; handleFloatingDrop; spring 0.3 | 长按编辑模式拖拽重排 | DragController + LayoutTransaction | VERIFIED_PARITY | 无 | LaunchBetter 无需长按编辑模式 |
| 9 | Cross-page drag | checkEdgeForPageChange; edgeThreshold=50; 0.3s | 边缘驻留翻页拖拽 | DragController.maybeAdvancePage(页边缘 0.4s) | VERIFIED_PARITY | 无 | 阈值/时序相近 |
| 10 | Drag into/out of folder | createFolder/addAppToFolder; removeAppFromFolder(.floatingDrag) | 拖入生成/加入文件夹; 拖出移除 | LayoutTransaction.moveIntoFolder + hoveredFolder drop | VERIFIED_PARITY | 无 | — |
| 11 | Hidden apps | hiddenAppsKey="hiddenApps"; toggleAppVisibility | 隐藏/恢复 | config.hiddenAppIDs + 右键菜单 | VERIFIED_PARITY | 无 | — |
| 12 | Custom display names | customName; CustomNameStore "customNames"; RenameAppSheet | 自定义显示名 | config.customDisplayNames + 右键 rename | VERIFIED_PARITY | 无 | — |
| 13 | Custom app sources | CustomAppSourceStore "customAppPaths"; scanCustomApp | 自定义目录扫描 | config.customSourceDirectories(部分接线) | VERIFIED_PARTIAL | 下一阶段(§31) | 本阶段不深化 |
| 14 | Localized app names | AppScannerService.localizedDisplayName; InfoPlist.strings; CFBundleDisplayName | .lproj 优先, 其次 plist | 未读取 .lproj | VERIFIED_MISSING | 下一阶段 Catalog Metadata(§32) | 本阶段不实现 |
| 15 | Uninstall / Trash | AppUninstallerService.moveToTrash; FileManager.trashItem | 右键卸载到废纸篓 | store.moveToTrash + 右键菜单 | VERIFIED_PARITY | 无 | — |
| 16 | Context menu | AppIconView.appContextMenu | 重命名/隐藏/卸载/Finder/简介/编辑 | GridViewController.contextMenu | VERIFIED_PARTIAL | 下一阶段(§31) | LaunchBetter 缺 Finder 显示/简介 |
| 17 | Global hotkey | registerGlobalHotKey; RegisterEventHotKey ⌘L | 硬编码 ⌘L(自定义 UI 未接线) | GlobalHotkey Carbon + 5 预设 | VERIFIED_PARTIAL | 最小补缺口(§26) | 自定义 recorder 下一阶段 |
| 18 | Four-finger pinch | MultitouchGestureRecognizer; count=4; threshold=0.18; cooldown=0.2 | 四指捏合开/关启动器 | GestureCaptureEngine + PinchAnalyzer(cooldown 0.2) | VERIFIED_PARITY | 无 | TCC 已授权, 实测通过 |
| 19 | Three-finger drag | processThreeFingerFrame; count=3; minTranslation=0.005; pinchTolerance=0.15; confirmFrames=2 | 三指拖动指针下图标(移动/生成文件夹/跨页) | **ThreeFingerDragRecognizer + 复用 DragController**(Stage 2 新增) | VERIFIED_PARITY(新实现) | 本阶段完成 | 见三指专项 |
| 20 | Hot corner | HotCornerMonitor; tolerance=10; dwell=0.3; cooldown=1.0; poll=0.05 | 四角热角, 驻留触发 | HotCornerMonitor(Timer 0.1s) | VERIFIED_PARITY | 无 | poll 周期略异(0.1 vs 0.05), 行为等价 |
| 21 | Wallpaper blur | FreezableBlurView; desktopImageURL; CI blur radius=30; 0.12s 冻结 | 壁纸模糊背景 | WallpaperProvider(blur 30, 磁盘缓存) | VERIFIED_PARITY | 无 | — |
| 22 | Settings | SettingsView 5 tabs | 通用/外观/手势/热键/关于 | SettingsWindowController(网格/语言/热键/热角/壁纸/来源/隐藏) | VERIFIED_PARTIAL | 下一阶段(§31) | LaunchBetter 无图标大小 slider 100%对应, 无 about tab |
| 23 | Localization | Localizable.xcstrings en/zh-Hans/zh-Hant; LocalizationManager | 英/简/繁即时或重启切换 | L10n(en/zh-Hans/zh-Hant)即时切换 | VERIFIED_PARITY | 无 | LaunchBetter 即时生效更优 |
| 24 | Multi-display | NSScreen.screens 遍历(HotCorner/窗口定位/壁纸) | 多屏定位 | LauncherWindow 屏幕跟随 + 壁纸按屏 | VERIFIED_PARITY | 无 | — |
| 25 | Accessibility | AXIsProcessTrusted + prompt | 无障碍授权检测 | ActivationCoordinator 单次权限检查 + 设置深链 | VERIFIED_PARITY | 无 | — |
| 26 | Refresh / rescan | loadInstalledApps 两阶段; appListRefreshRequested; didLaunchApplicationNotification | 启动两阶段(快照+后台扫描)+ 应用启动通知刷新 | 首帧快照 + 后台 reconcile + FSEvents 增量 | VERIFIED_PARITY | 无 | LaunchBetter 用 FSEvents 更优 |
| 27 | Launch history / recent / count / timestamps | 无实现(UserPreferences 死字段) | 不存在 | — | OLD_FEATURE_NOT_PROVEN | 不实现 | 命名陷阱: "LaunchHistory" 是缓存目录名 |

## 专项: Three-Finger Drag(本阶段实现)

### 旧行为(源码证据)

`MultitouchGestureRecognizer.swift`:
- `threeFingerCount = 3`, `threeFingerMinTranslation = 0.005`(归一化坐标), `threeFingerPinchTolerance = 0.15`, `threeFingerConfirmFrames = 2`
- 状态机: activeCount != 3 → 立即 ended; 3 指时判定平移(质心位移 ≥ 0.005)且非捏合(半径变化 ≤ 0.15)→ 连续 2 帧确认 → began; 拖动中检测捏合 → ended
- 位置语义: `ThreeFingerDragCoordinator` 用 `NSEvent.mouseLocation`(指针位置, 非触点中心)反查指针下图标作为 draggingItem, 并用指针位置驱动拖动
- 生命周期: 面板显示时启用; 隐藏时发 `.cancel`(不执行 drop)
- 事件: `ThreeFingerDragUIEvent.begin(mouseLocation)/change(mouseLocation)/end/cancel`, 经 NotificationCenter 分发到 ContentView 的 DragGesture 逻辑

### LaunchBetter 新实现(复用现有 DragController)

```
MultitouchSupport(MTRegisterContactFrameCallback, dlopen)
   ↓ (后台线程, 125-250Hz)
GestureCaptureEngine.receive
   ↓ 按 finger count 路由(单一订阅, §19)
   3 指 → ThreeFingerDragRecognizer(纯逻辑状态机, LaunchCore, 常量对齐 0.005/0.15/2)
   4+ 指 → PinchAnalyzer(既有)
   ↓ ThreeFingerGestureEvent(began/changed/ended)
ThreeFingerDragCoordinator(LaunchBetterApp)
   ↓ (轻量 main.async → updateDrag 只写 latest-sample buffer)
DragController.beginDrag(item:at:inputSource:.threeFinger) / updateDrag / endDrag / cancelDrag
   ↓ (既有 FrameCoordinator/display link 消费, 预览缓存/二维 diff/真实图标 overlay/revision 防护全部复用)
```

- **互斥**(§17): DragController 增加 `DragInputSource`(.mouse/.threeFinger), 一个 session 只有一个 owner, 已 dragging 时其他输入源不得 begin
- **仲裁**(§18-19): 2 指 → PagingInteractionController; 3 指 → 三指拖动; 4+ 指 → pinch; 单一 MTDevice 订阅
- **坐标**(§14/§15/§16): 拖动源与位置 = 指针(mouseLocation), 与旧行为一致; 不移动系统真实光标
- **private framework**: 已隔离 LaunchPlatform(MultitouchSupport dlopen); 失败 → 三指不可用, 启动器正常

### 诊断计数(§37)

GestureCaptureEngine: threeFingerRawFrameCount / begin / update / end; ThreeFingerDragCoordinator: begin/update/end/cancel/missedBegin。

## Recommended Migration Order(§35)

| 优先级 | 内容 | 估算风险 | 架构影响 |
|---|---|---|---|
| P0 | Interaction parity(三指拖动 ✓ 本阶段完成; pinch/hotkey/hotcorner 已验证 parity) | LOW | Platform + App |
| P1 | Catalog metadata parity(本地化应用名, 自定义来源深化) | MEDIUM | Platform |
| P2 | Settings/context parity(图标大小 slider 细化, Finder 显示/简介, 热键 recorder) | MEDIUM | UI + App |
| P3 | Optional layout parity(垂直滚动布局) | HIGH | UI + Core |
| P4 | Final parity hardening | LOW | 全层 |

## 已确认不存在的功能(OLD_FEATURE_NOT_PROVEN)

- **Launch history / recently used / launch count / launch timestamps**: 旧项目无任何实现(仅 UserPreferences 死字段); "LaunchHistory" 只是缓存目录名
- **Vertical paging(垂直分页)**: 无翻页实现, 仅有连续垂直滚动布局(布局本身也未迁移)
