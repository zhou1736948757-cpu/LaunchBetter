# 任务包: P2 — Page Compositor / PageVisualCache 实验

## 背景(Part A 稳定 checkpoint: pre-page-compositor-20260813 → 本分支基 024bb54)
真机基线: 密集页 settle 帧间隔 avg 17.6-17.9ms、p95 26-33ms(60Hz 屏名义 16.7ms,偶发掉帧)。
目标: 分页跟踪/回弹期间用 2-3 张预渲染页面表面替代 40-60 个 live cell 合成,让密集页滑动接近稀疏页。
PagingInteractionController 保持唯一运动引擎;PageCompositor 只是 presentation target。
失败可回退到 checkpoint,绝不进 main。

## 分支与纪律
- 本分支 `perf/page-compositor-v0.4.x`: 从 Phase A checkpoint `024bb54` 新建,
  移植旧实验分支 `perf/page-compositor`(8b4d8f3)的 Page Compositor,并保留
  Phase A 成果(Library 空白点击/三指重分类/分类常驻排序/Settings 表单对齐/
  PA4 interruptedSettleTarget/categoryOverride v2)。禁止提交 main、禁止 force push。
- 允许修改 `Packages/LaunchUI/Sources/LaunchUI/`(新增 PageVisual.swift / PageVisualCache.swift / PageCompositor.swift 等 + 改 GridViewController / PagingInteractionController)、`LaunchBetterApp/Diagnostics/`、`LaunchBetter.xcodeproj/project.pbxproj`、测试文件。
- 禁止改 LaunchCore/LaunchPlatform 业务逻辑、LayoutStore、Launchpad_Back。可以加测试。
- 不提交(总控收口)。

## 核心规格

### 1. 快照渲染策略(OPTION C,已选定)
不用 NSCollectionView/cacheDisplay 快照相邻离屏页(虚拟化不实现 cells,会强制 realization/滚动)。
改为**轻量页面渲染器**(纯内存,后台/idle 准备):
- 输入: 该 Layout page 的 display items + 几何(iconSize/positions/spacing)+ 内存图标 CGImage(IconImageProviding 或缓存)+ 名称(当前语言)+ 文件夹(≤9 子图标缩略)。
- 输出: 只包含**页面网格内容区**(非全屏)的 CGImage + logical bounds + raster scale。
- 图标: 只用已缓存内存图标;未就绪 → 用稳定占位(与 live 一致);绝不在手势中触盘/读 Info.plist。
- 标签: 与 AppCellView 同字体/阴影/裁切;文件夹: 圆角底 + 图标网格(对齐 FolderThumbnailView 视觉)。
- **禁止在 gesture 起点同步渲染**: 仅 idle 时准备;未就绪 → 本次手势 live 分页(降级)。

### 2. PageVisual / Cache
- `PageVisualKey`: 普通 layout page index + displayRevision + geometryRevision + backingScale + languageRevision(+ 需要时的文件夹/图标代数)。
- `PageVisual`: CGImage、logicalBounds、rasterScale、key、bytes。
- `PageVisualCache`: **有界 working set ≤ 3**(previous/current/next);LRU/精确驱逐;内存记账(totalBytes/visualCount/rasterScale);失效按 key;purge 条件: hide、内存压力、geometry/backingScale 变化、结构变更。
- 准备时机(idle,防抖): settle 完成、show 稳定、图标安静、revision 变化后。

### 3. PageCompositor(只做 presentation)
- 激活条件: paged 模式 + 普通 Layout surface + 无 drag/Folder/Settings/Search/Category detail + 相邻页视觉齐备 + **密度门(当前页 ≥ 20 项, 默认阈值 `pageVisualMinItemsPerPage`, 可覆盖)**。**不支持 Library↔Page1**(用 live)。
- 激活零跳变: 激活帧 compositor 视觉 == 当前 live 页面视觉(像素容差);然后隐藏 live 前景页内容(不隐藏 wallpaper/搜索/齿轮/页点)。
- 每页 layer x = pageIndex*pageWidth - currentPagingOffset(单一 offset,无独立弹簧);**文档 x 含 leading 偏移**(Stage E: 普通页从物理 1 开始, 页 n 文档 x = leadingDocumentOffset + n*pageWidth, 移植时修正旧分支缺失)。
- 反向: previous/current/next 在 working set 内直接复用,零模式切换。
- settle 完成: 禁隐式动画下把真实 NSClipView 设到精确目标 → reveal live → 移除 compositor layers → 释放。
- 打断: 新手势不拆 compositor,继续从 compositor.currentOffset。
- 中止(缓存失效/不满足): 捕获当前 visual offset → 真实 clip 同步到同 offset → reveal live → 移除 → 走 live。
- 显式 shutdown: search/folder/settings/hide/drag 开始/配置变化/backing scale 变化/结构变更 → 同步收尾,无僵尸 layer。
- 开关: 默认关;`--pagecompositor` 开启;`--disable-pagecompositor` 为紧急 kill switch(任何情况下强制关闭)。
- 缓存未命中/视觉未就绪 → 本次手势 live 分页(降级);**绝不阻塞手势起点**。

### 4. 偏移抽象(关键)
- `GridViewController.readPagingOffset()`: compositor active → compositor.currentOffset;否则 clip.bounds.origin.x。
- PagingInteractionController.onReadCurrentOffset 接这个;不得散射。
- 每帧路径极简: 只允许 offset 数学 + CALayer position/transform/opacity;禁止 Store/DisplayModel/Diffable/图标/文件/文本布局/文件夹光栅/autolayout/Task。

### 5. 遥测(默认关)
compositorEnabled/Active、cacheHits/Misses、visualBuildCount/avgMs/maxMs、activeVisualCount/bytes、fallbackLiveCount、compositorFrames/frameApplyAvgUs/maxUs、abortCount、reversalCount。CLI `--pagecompositor` 开启 A/B。

### 6. 测试(确定性)
cache cap/eviction/revision/scale/geometry 失效;eligibility(普通页 true,search/folder/settings/drag/Library 边界 false,稀疏页密度门 false);offset 语义(active==compositor, inactive==clip);settle 激活/完成零跳变;Page2→halfway→reverse→Page2;中止同步;500 轮无泄漏无残留无中间态。快照渲染器 1x/2x 逐像素对比预期。
- 移植修正: 并发 prepare(防抖 Task vs 测试 seam)串行化共享同一在途任务,语言代数在准备起点快照并与缓存键自洽(并行测试套件改全局 L10n 曾致缓存键/激活检查失配 → 8 轮全量复跑稳定)。

## 验收(总控做)
1. LaunchUI 测试全绿 + Debug build。
2. `--pagecompositor` A/B 遥测对比 dense 页(live vs compositor 的帧间隔/p95/max、fallback 次数)。
3. 视觉: 相邻页截图/帧序列无 flash/位移/标签漂移/像素跳变。
4. 报告: 架构、内存、性能数字、已知限制、是否值得合 main 的建议。
