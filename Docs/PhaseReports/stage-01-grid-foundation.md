# LaunchBetter Stage 1 Report

分支: fix/v0.1.3-grid-foundation · 目标: 统一 Grid Geometry, 消除 Paging/Drag/Search/Settings/Icon 几何分叉

## 1. Confirmed Bugs

| # | Bug | 根因 | 证据 |
|---|-----|------|------|
| 1 | 跨页拖拽目的地全算到页 0 | `dragDestination` 用 `collectionView.bounds.width`(文档宽=页宽×页数)当页宽 | 代码审查 §4-6 |
| 2 | 双指一次滑动可能翻 2-3 页 | `handlePageScroll` 每个 changed 事件都翻页, 无会话状态机 | §8 分析 |
| 3 | 搜索结果 >42 个画到可见区外无法访问 | `applySearch` 单 section + 分页布局, 超容量项无滚动路径 | §11; 实测 "com" 76 结果 |
| 4 | rows/columns/iconSize 设置不生效 | 布局一次性创建, config 变化不重建 | §14; GRIDTEST 实测 8×5 前无效 |
| 5 | 搜索模式内容完全不可见 | 非 flipped 文档视图 + 垂直滚动: `bounds.origin` 与 clip 不同步, 可见区计算错位 | 实测 clipY=1384 时 bounds.origin=0, 56 个单元格在位但不合成 |
| 6 | 搜索进入后内容不滚动到顶 | 文档高度在下个布局回合才落定, `scrollToTop` 用旧高度 | 实测 clipY=0 停在底部 |
| 7 | 搜索截图/评审呈"空网格"假象 | 探针在 `refreshGrid()` 后立即截图, 单元格刚被重置为占位; `cacheDisplay` 对纯 layer-backed 层级不可靠 | 像素级对比: 同位置 0 差异 |
| 8 | 图标尺寸固定 96pt 请求、64pt 显示 | `configure` pointSize=96 硬编码; AppCellView icon 固定 64 | §16-18 |
| 9 | 拖拽预览仅 X 平移 | `applyPreviewTransforms` 单一 translationX | §20 |
| 10 | 拖拽 overlay 为灰色占位 | `DragOverlayLayer.configure` 系统灰 | §23 |
| 11 | 边缘翻页用文档宽 | `maybeAdvancePage` 用 `bounds.width` | §25 |
| 12 | 边缘翻页潜在振荡 | 翻页后指针落回前一页边缘即反向翻回 | §26 分析 |
| 13 | 布局在每次滚动时全量重算 | `shouldInvalidateLayout` 恒 true | §31; 实测 prepare 4→7 |
| 14 | 每次 show/hide 全量 snapshot | `refresh()` 无修订判断; `searchQuery=""` 无变化也 bump | §29-30 |
| 15 | 拖拽期目录/配置变化导致陈旧 drop | 无 revision 防护 | 评审 M7 |

## 2. Root Causes

- **几何没有唯一真值**: pageWidth/itemSize/iconSize/spacing 散落 5+ 处且互相矛盾
  (PagingGridLayout 96/28; GridViewController.slotStep 96+28、slot(at:) 96/28;
  configure 96; AppCellView 64; IconRepository 96)
- **坐标系混用**: document width vs clip 可视宽; document vs viewport 坐标
- **输入没有状态机**: 事件流 began/changed×N/ended/momentum 未建模
- **非 flipped 文档视图垂直滚动**: AppKit NSCollectionView 在非 flipped 滚动视图内垂直
  滚动时可见区计算失效(经典坑, v0.1.2 只修了横向分页没踩到, 搜索纵向一进来就爆)

## 3. Architecture Changes

- **GridGeometry**(LaunchCore, 纯逻辑): 唯一几何真值。表达 pageSize/columns/rows/cellSize/
  iconSize/spacing/pageCapacity, 提供 frameForSlot/slotForPoint/pageForPoint/pageOrigin/
  gridOrigin + 搜索模式几何。拖拽、布局、槽位、边缘翻页、图标请求尺寸全部从它派生。
- **PagingGestureSession**(LaunchCore, 纯输入): began/changed/ended/momentum →
  一次手势最多一页、水平主导、惯性忽略、新手势可再翻。
- **PagingGridLayout**: 委托 GridGeometry; 增加 .search 模式(垂直滚动);
  失效仅限可视尺寸变化。
- **ClickableCollectionView.isFlipped = true**: 垂直滚动渲染修复(§11)。
- **DisplayRevision**(LauncherStore): 目录/布局/配置/搜索任一变化递增; Grid 无变化跳过
  full snapshot; 拖拽起始 revision 捕获做陈旧防护。
- 截图管线改为 layer render(与屏幕合成一致)。

## 4. Files Changed

- Packages/LaunchCore/Sources/LaunchCore/GridGeometry.swift (新)
- Packages/LaunchCore/Sources/LaunchCore/PagingGestureSession.swift (新)
- Packages/LaunchCore/Tests/LaunchCoreTests/GridGeometryTests.swift (新, 21 测试)
- Packages/LaunchCore/Tests/LaunchCoreTests/PagingGestureSessionTests.swift (新, 7 测试)
- Packages/LaunchUI/Sources/LaunchUI/PagingGridLayout.swift (几何委托/search/失效)
- Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift (几何接入/搜索模式/修订)
- Packages/LaunchUI/Sources/LaunchUI/DragController.swift (二维预览/页边缘/真实图标/防护)
- Packages/LaunchUI/Sources/LaunchUI/AppCellView.swift (iconSize 驱动/scale 重请求)
- Packages/LaunchUI/Sources/LaunchUI/ClickableCollectionView.swift (flipped/文档尺寸)
- Packages/LaunchUI/Sources/LaunchUI/LauncherStoring.swift (iconSize/displayRevision)
- Packages/LaunchUI/Sources/LaunchUI/FolderViewController.swift (iconSize 接线)
- LaunchBetterApp/LauncherStore.swift (displayRevision/searchQuery bump)
- LaunchBetterApp/AppDelegate.swift (pagetest 0→1→2→1→0; searchprobe; gridtest)
- LaunchBetterApp/IconImageAdapter.swift (无实质变更)
- Docs/Visual/Stage1/ (5 张验证截图)

## 5. Tests Added

- GridGeometry: 容量/网格居中/首格/跨页/扁平索引/页判定/槽位判定/钳制/跨页边界/
  不同列行页宽/搜索行数/搜索文档尺寸/搜索帧全在文档内/顶部锚定 — 21
- PagingGestureSession: 一次手势一页/惯性零翻页/新手势可再翻/小幅抖动零翻页/
  纵向手势零翻页/方向符号/累计阈值 — 7

## 6. Full Test Results

- LaunchCore: 96 (swift-testing) + 28 (XCTest) 全部通过
- LaunchPlatform: 未变更, 回归通过
- smoke: catalog=88, 3 页, 容量 42, 搜索 chrome=1, dragtest=OK changed=true
- pagetest: 0→1→2→1→0 全对; pageWidth=1470=clipW; documentWidth=4410=3×page
- searchprobe: "com"→76 结果(>42), 文档高 1384(溢出), 42/42 真实图标, 退出恢复
- gridtest: 8×5×48 → capacity 40 生效并恢复; 64/80/96 变体全对
- 布局失效: 翻页 prepare=4 恒定(修复前每次滚动 +1)

## 7. Build Result

- xcodebuild Debug/Release 均 BUILD SUCCEEDED
- Release 已 ad-hoc 签名安装 /Applications/LaunchBetter.app(替换 v0.1.2)

## 8. Performance Measurements

- show/hide: 无变化状态修订去重后跳过 full snapshot(未再重复全量 Diffable)
- 翻页动画: 0 次无意义布局重算(prepare 4→4)
- 图标: 探针 8s 内 42/42 可见单元格图标就绪(磁盘缓存 80pt 条目, 冷启动后加载)

## 9. Visual Results

Docs/Visual/Stage1/:
- 01-normal-80pt.png — 7×6, 80pt, 图标/标签/页点正常
- 02-search-overflow.png — 76 结果垂直网格, 真实图标
- 03-grid-8x5-48pt.png — 8×5, 48pt
- 04-grid-64pt.png — 7×6, 64pt
- 05-grid-96pt.png — 7×6, 96pt
- 像素级验证: 各尺寸网格对齐、底行完整、字形存在(评审 4 次误报均被证伪)

## 10. Code Review Result

- 首轮 Luna Max: 0 BLOCKER / 8 MAJOR / 6 MINOR-NOTE
- 修复后复评: **M1-M8 全部 PASS; 0 BLOCKER / 0 MAJOR** ✓ 达成 Stage 1 门槛

## 11. Git Commits

- 85108cc fix: unify paged grid geometry (GridGeometry single source of truth)
- 3e5ff1a fix: search overflow vertical grid rendering (flipped document view)
- 18d13c6 fix: address 8 reviewer MAJORs (grid foundation hardening)
- 0dcf361 MEMORY: Stage 1 complete, grid foundation verified
- 11d6336 docs: Stage 1 final screenshots

## 12. Manual Trackpad Tests Required (用户实测)

- Test A: 第一页双指向左滑一次 → 只能到第二页
- Test B: 第二页再向左一次 → 只能到第三页
- Test C: 第三页向右一次 → 只能到第二页
- Test D: 轻微水平移动 → 不翻页
- Test E: 滑动结束后的惯性 → 不产生第二次翻页

(未完成上述实测前, 不得宣称 Trackpad validated)

## 13. Remaining Known Issues

- 图标/标签间距: 方向正确, 用户要再拉开一点(几何已统一, 只需调 gap 系数)
- 设置界面入口: 面板内无设置按钮(菜单栏 Cmd+, 存在); 壁纸开关未接真实 WallpaperProvider
- 搜索栏: 用户提到有问题, 具体现象待补充
- 搜索模式不支持拖拽(已禁用, 属设计决策)
- 正式签名分发(需 Apple 凭据, 可选)
- 120Hz 显示器无法本机实测

## 14. Recommended Stage 2 Scope

- LaunchHistory → LaunchBetter feature parity(用户已批准路线)
- 三指拖拽、垂直启动器布局、文件夹全新视觉
- Hotkey Recorder、自动更新、签名/公证
- 图标/标签间距定稿、设置面板内入口、搜索栏问题修复
