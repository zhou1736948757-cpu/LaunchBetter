# LaunchBetter Project Memory

## North Star

打磨过的原生 macOS Launchpad 替代品:分页网格启动器、搜索、文件夹、拖拽、持久布局、
四指捏合/热键/热角激活、壁纸模糊背景、多显示器、无障碍、中英繁本地化。
优先级: 架构正确性 > 并发安全 > 数据完整性 > 确定性行为 > 实测性能 > 视觉质量 > 功能数量。

## Non-Negotiable Decisions

- AppID = 规范化应用路径;禁止 UUID 替代;禁止 ExpressibleByStringLiteral
- Catalog / Layout / Config / IconRepository 四分离
- LaunchCore 无 AppKit/SwiftUI/Combine/FileManager
- `DispatchQueue.main.sync` 全仓库 = 0
- 持久数据在 Application Support,缓存可删;Caches 全删不影响布局/设置/历史
- 启动器显示与普通应用启动 = 0 扫描/0 Info.plist IO/0 图标重扫
- 每帧状态不进 LauncherStore;走 GestureSampleBuffer → FrameCoordinator → CALayer
- 持久格式带 schemaVersion;迁移失败保留旧文件不销毁
- 墓碑宽限期 30 天
- 主网格用 NSCollectionView + DiffableDataSource,禁止 SwiftUI 巨型网格

## Current Phase

**v0.5.2 已发布(2026-08-21): 平滑落地(用户实测"略微有点卡"第二轮修复)。**

- 根因: v0.5.1 的揭露前强制布局把整页 ~40 cell 创建压缩到落地瞬间 = 一次
  主线程长停顿(首访页面明显)。
- 修复 `bf77232`: settling 每帧 routeScroll 内 advanceRealClipBehindCover —
  真实 clip 遮盖下向合成器偏移跟进 35% 缺口, NSCollectionView 逐帧增量物化
  cell + 图标请求摊到整个手势; 落地强制布局保留为兜底(此时通常无剩余工作)。
  引擎单一运动源不变(readPagingOffset 仍只读合成器); abort 由 teardown 兜底。
- 不变式测试更新: PagingOffsetOwnership clip 写点 2→3(新增第三处引擎驱动写);
  新增渐进推进集成测试(带真实间隔泵帧, 时间驱动弹簧才能推进)。
- 发布: v0.5.2 (6) 已装 /Applications 运行中; tag+main 已推。
- 测试(全绿): LaunchUI 372 / LaunchCore 181 / LaunchPlatform 142。

**v0.5.1 已发布(2026-08-21): 合成器快速甩页空窗修复。**

- 用户实测 bug: 快速甩到下一页后短暂只显示壁纸背景。根因: compositor 激活期间
  真实 clip 从未滚过目标页 → 目标页 cell 从未物化; settle 完成 teardown 里
  clip 同步后立即揭露 live, cell 物化在下一个布局周期 → 空窗。
- 修复 `8d1bac4`: onSyncClip(仅 finish/abort/shutdown 揭露时刻触发)里 clip 同步后
  强制 collectionView.layoutSubtreeIfNeeded, 让 cell 在合成表面仍遮盖时物化完毕。
  新断言: SyncLayoutCount ≥1 + visibleItems > 0(settleActivationAndCompletion)。
- 发布: v0.5.1 (5) 已装 /Applications 并运行; tag+main 已推 origin
- 测试(全绿): LaunchUI 371 / LaunchCore 181 / LaunchPlatform 142

**v0.5.0 已发布(2026-08-21): Page Compositor 成为默认分页架构。**

- 发布: `v0.5.0` tag + GitHub Release(用户决策: 免真机 A/B, 直接作为最终版本);
  /Applications 已覆盖 v0.5.0 (4) Release 构建并运行
- 合并提交: `ce38705` merge Page Compositor into main as default paging architecture;
  版本提交: `8def7fe` build: version 0.5.0
- 组合器默认 ON; `--disable-pagecompositor` kill switch 保留; `--pagecompositor`
  现在仅表示 A/B 遥测探针(PageCompositorProbe)
- 分支 perf/page-compositor 与 perf/page-compositor-v0.4.x 已合入, 可删(未删)
- 测试(全绿): LaunchUI 371(含 P2 29)/ LaunchCore 181 / LaunchPlatform 142;
  `--smoke` OK / `--gridtest` OK / 普通启动存活 OK; pbxproj 冲突以 HEAD UUID +
  仅新增 PageCompositorProbe 条目解决(重复条目扫描通过)
- PA1 测试适配: prewarm 去重测试显式关闭 compositor(compositor idle prepare
  会额外请求图标, 隔离断言语义)
- 未做(记录): 真机 p95/手感量化对比(用户明示跳过); 若日常出现分页视觉异常,
  第一反应 = 用 `--disable-pagecompositor` 复现对照再报 issue
- 本会话工程限制: opencode run 与 Task 子代理多次空返回, 实现由总控直接完成
  (用户指令), 单写者规则由总控独占满足

**历史: 性能优化 Phase A(快赢)已完成(2026-08-21)。**

- 提交: `f6f7f1b` library: X2 进 Library 首次交互修复(key-window 激活点击/手势残留/host 布局)
- 提交: `69cbe9c` settings: X1 滑杆固定宽度可拖 + SMAppService 开机自启
- 提交: `6b9b0c1` perf: PA1 翻页帧预算(遥测 IO 移出 settle 帧/trace autoclosure/
  页点增量更新/预热 (page,revision) 去重/displayModel revision 键控缓存)
- 提交: `fcb630f` perf: PA2 启动路径(BootstrapSeeds 读盘去重 2→1/Settings 惰性构建
  10-30ms/SMAppService XPC 移出首帧/滑杆 commit 150ms 合并+关闭冲刷)
- 任务记录: Docs/Tasks/pa1-interaction-frame-budget.md, pa2-launch-settings.md
- 待办: Phase B(B1 拖拽几何缓存/B2 Library host 预挂载/B3 复用快速路径/B4 运动模糊降级)、
  Phase C(C1 图标解码并发化/C2 缓存 128→48MB/C3 LRU O(1))未开始

**Stage D 自动化与代码审查门禁已完成，v0.3.8 已发布。**

物理/视觉 gate 尚未验收：时间连续性、真实触控板甩动速度与 120 Hz 手感仍为
`MANUAL_PHYSICAL_GATE`，不得表述为 Stage D 已完成实机验收。

当前状态:
- 发布: `v0.3.8` / `9f50d2a`（GitHub Release 已发布）
- 提交: `709e757` interaction: isolate settings input ownership
- 提交: `ee6d8ee` folder: inline title rename via long-press, remove header buttons
- 提交: `(最新)` motion tokens + reduce-motion + launcher transition lifecycle
- 提交: `(最新)` interaction: gate keyboard/three-finger, paging suspend, shield idempotency (Luna M1-M5)
- **模型路由(用户指令 2026-08-11)**: 总控 = opencode-go/gpt-5.6-luna (variant: max, 主对话);
   实现 = opencode-go/deepseek-v4-flash (variant: max); 评审 reviewer = opencode-go/qwen-3-7-plus;
  视觉 = opencode-go/mimo-v2.5; 仲裁 = opencode-go/qwen3.8-max。已写入 opencode.json / AGENTS.md / .opencode/agents/reviewer.md。

## 本阶段已完成(已验证)

- **Settings 交互所有权(用户实测 bug)**: `LauncherInteractionSurface`(launcher/folder/settings) + 父窗口 `SettingsInteractionShield` 消费完整鼠标序列 + 三指门控 + grid 拖拽/点击/翻页门控; Settings 打开前 cancelDrag + 关闭 folder + 暂停分页; 关闭单一 cleanup 路径(settingsController.onClose, 移除 deinit 兜底, 解决 Luna deinit finding)。
  - `--settingsownershipprobe` 22 项断言全过(三指 blocked / 根拖拽 blocked / 无 overlay / 无隐藏源 / 空白点击只关设置 / 关闭恢复 / 之后可用)。
- **Folder 清理**: 移除 Rename/Dissolve 可见按钮; 标题重居中; 长按(0.5s/6pt)NSPressGestureRecognizer 内联重命名(Enter 提交/Escape 取消/失焦提交/空名恢复/持久化失败恢复权威名); 标题即时按压反馈(0.98 缩放); 无障碍自定义动作 "重命名文件夹"; 标题/编辑器同几何无跳变。
- **2→1 自动解散**: `LayoutEditor.moveOutOfFolder` 已在同一候选快照原子实现(剩余 child 占原槽 + 删记录); 3→2/2→1/隐藏/持久化失败/重启全部已有测试覆盖。
- **Motion 基础**: `MotionTokens`(pressFeedback/standard/spatial/momentumSettle spring specs) + `MotionEnvironment`(Reduce Motion/Transparency/Contrast 实时读取) + `LauncherTransitionLifecycle`(generation 防过期 show/hide completion)集成 show()/hide()。
- **Luna 设计门(M1-M5 已修)**: 键盘+三指 update/end 门控; shield 幂等 + 失活兜底; Folder 外点击同序列防护(ClickableCollectionView 无配对 mouseDown 的 mouseUp 忽略); Folder/Settings 进入暂停分页状态机。
- 测试: LaunchCore 143 / LaunchUI 64(新增过渡生命周期 + mouse-session)/ LaunchPlatform 127; Debug build OK。

## Stage E(App Library)成果(已验证, 未提交)

- 默认打开 Page 1;physical surface 0 = App Library,1+ = Layout pages;
  `LauncherSurfaceIndex` 映射;绝不写 LayoutStore 用户布局。
- Catalog schema 3 + `categoryIdentifier`;`AppLibraryMetadataStore` usage/firstSeen
  与 Layout 分离;`AppLibraryModel`(Suggestions ≤4、category primary ≤3/mini ≤4、
  recently added 30 天 bootstrap、稳定 tie-break)。
- Library UI: 独立垂直 NSScrollView + NSCollectionView;卡片/detail/lazy icon/
  L10n/a11y;`AppLibraryAxisArbiter` + pending-began replay 复用唯一 paging
  settle/display-link 引擎;Library/Category/Settings ownership、Search restore。
- E10 visual evidence: `--libraryshot <png> --library-state top|mid|detail|search|settings`;
  六状态 fresh PNG(top/mid/detail/search/settings+settings pair),2940×1912 @2x /
  Settings 1520×1360 @2x;probe 内临时将内容 NSTextField layer
  `isGeometryFlipped=false` 再恢复(全窗口 x 翻转方案被否决: 会把本来正确的
  搜索图标/齿轮位置镜像)。
- 测试: LaunchCore 166(Swift Testing)+97(XCTest)、LaunchPlatform 137、LaunchUI 266
  全绿;Debug build OK;`DispatchQueue.main.sync = 0`。
- 评审: mimo-v2.5-pro 阶段末评审 0 BLOCKER / 0 MAJOR(1 MINOR: detail 行 mouseUp
  无位移门控 → 已修复为 6pt 阈值 + 2 新测试);Luna 最终验收 0 BLOCKER / 0 MAJOR /
  0 MINOR, 通过。
- 安装(2026-08-13, 用户指令): Release ad-hoc 构建已覆盖安装
  `/Applications/LaunchBetter.app`(universal x86_64+arm64)并启动;旧 DerivedData
  LaunchBetter-* 与 Packages/*/.build 已清空, 磁盘仅保留 /Applications 副本。
- E11 视觉细化(用户实机反馈, 已完成并重装): 卡片改方形(height=width,
  clamp [240,430]);水平 edge inset 24、spacing/rowSpacing 24→16;顶部保留带
  接入(窗口 chrome topInset 经 AppLibraryHostItem→setContentInsets 传入
  AppLibraryLayout.contentInsets.top, 首行 minY=topInset, 搜索栏/齿轮不再重叠;
  pending insets 缓存覆盖 loadView 前调用)。截图管线修正: launcher
  contentView 为 flipped, captureContentScreenshot 移除 y-flip(此前 PNG 与
  屏幕上下颠倒, 搜索栏/齿轮在 PNG 底部);launcher 探针不再做 isGeometryFlipped
  文本校正(y 方向修正后自然可读);Settings 窗口 y-flip 保留。LaunchUI 274 测试
  全绿; OCR 验证: 搜索应用 ≈80pt 顶部居中, 首行卡片标题 ≈139pt, 无重叠。
- 待办: AppLibraryModel.swift:322 有 1 个未使用 `record` 绑定编译警告(功能无影响,
  下次实现任务顺手修); 用户实机手感验收进行中。
- **Part A 稳定化(进行中, 2026-08-13, 未提交)**: 卡片象限布局(2×2, 3 large + 右下 mini 2×2, Suggestions 2×2 四大图标, 标题 top-left, 无卡片内标签, 无 mini 胶囊;密度 330/370/inset30/spacing16, 1470pt→4 列);分类根因(QQ 自报 developer-tools→bundle 校正 com.tencent.qq→social + 手动覆盖 schema v2 categoryOverrides, 优先级 override>bundle>classifier, 稀疏含覆盖分类不合并, 右键 Move to Category/Automatic Classification, 热刷新 updateModel);Library 空白点击隐藏(BlankClickLibraryCollectionView + scroll 容器空白, 复用 grid.onClickBlank→hide)。测试: Core 174 / Platform 142 / UI 293 全绿。
- **P2 真机基线(telemetry, 2026-08-13)**: 用户实际手势两次 settle: frames 22/42, avgMs 17.64/17.87, p95 26.18/33.23, max 32.25/33.44 → 密集页 settle 帧间隔 ~18ms(60Hz 屏名义 16.7ms), p95 约 2 帧 → 偶发掉帧, 这是"卡顿"的可测证据(供 P2 before/after)。
- **翻页半路卡住根因(代码级定位)**: beginGesture 打断 in-flight settle 后, 若新手势未锁定水平轴(垂直/微动), endGesture→finishTrackingWithoutSettle 停在被打断的中间偏移(baseOffset 是动画中间值)且 display link 停 → 半路卡住;后续手势能再动。修复方案: 记录 interruptedSettleTarget, finishTrackingWithoutSettle/零位移水平结束时 restart settle 到原目标。PA4 实施中。

## Part A 稳定化 checkpoint(2026-08-13, 已验证)

- **APP_LIBRARY_STABLE_CHECKPOINT=`55f038d5b05aa7d8e5fd2a540a561fadf1be33fb`**(commit `library: stabilize App Library (Part A)`)
- **APP_LIBRARY_STABLE_TAG=`pre-page-compositor-20260813`**(annotated, 已推 origin)
- 内容: QQ 分类根因(自报 developer-tools→bundle 校正 com.tencent.qq→social);手动分类覆盖(schema v2 categoryOverrides, 优先级 override>bundle>classifier, 稀疏含覆盖不合并, 右键菜单, 热刷新);卡片象限布局(2×2, 4 列@1470pt);Library 空白点击隐藏;翻页半路卡住修复(interruptedSettleTarget 重启 settle);`--pagingeventtrace`/`--pagingstressprobe`(500 轮全过)。
- 测试: LaunchCore 174 / LaunchPlatform 142 / LaunchUI 304 全绿, 零警告;Debug build OK。
- 评审: qwen3.7-plus 0 BLOCKER / 0 MAJOR / 0 MINOR。视觉: Library 卡片布局 PASS(4 列/象限/top-left/无标签/无胶囊);Settings 截图镜像与壁纸预览黑为已记录捕获管线限制(非用户可见)。
- 工作树: work/ 与 Docs/Visual/* 未跟踪保留;`--pagingtelemetry` 真机基线(frames 22/42, avg 17.6-17.9ms, p95 26-33ms)为 P2 before 数据。
- **P2 实验分支: `perf/page-compositor`(自本 checkpoint 创建)**

## P2 Page Compositor 实验(2026-08-13, 分支 perf/page-compositor @8b4d8f3)

- 已实现并推送分支(未合 main): PageVisual 轻量渲染器(OPTION C, 纯内存 CGImage, 网格内容区);PageVisualCache(cap≤3/字节记账/多 revision 失效/purge);PageCompositor(presentation-only, 普通 Layout 页触控板手势合成, Library/搜索/文件夹/设置/拖拽边界降级 live, 激活零跳变, 反转复用 working set, settle 完成 clip 同步→reveal→移除, 打断保持, 安全中止, 显式 shutdown);readPagingOffset 抽象;PagingInteractionController 仍唯一运动引擎;--pagecompositor 遥测。
- 测试: LaunchUI 332 全绿(含 cache/renderer/compositor/integration 500 轮压力), Debug build OK。
- 评审 qwen3.7-plus: 0 BLOCKER / 0 MAJOR / 3 MINOR(合 main 前清理)。
- **决策: DO NOT SHIP(暂不合 main)**。headless 无法测真实 120Hz 手感;真机 A/B(`--pagecompositor` vs `--pagingtelemetry` 帧间隔)是 MANUAL_PHYSICAL_GATE。main 保持 pre-page-compositor-20260813 稳定 checkpoint。
- 回滚路径: 任意时刻 `git checkout main`(55f038d 稳定) 即可, 无歧义。

## v0.4.x Phase A 稳定 checkpoint(2026-08-13, 已验证)

- **STABLE_SHA=`024bb54289f430f67f15daa01ec769de434340d4`**, **TAG=`pre-page-compositor-v0.4.0`**(已推 origin)
- 逻辑提交: `settings: align controls in shared form columns`(33e6238)、`library: rank category cards by common usage`(b2e483f)、`library: fix blank-background dismissal + three-finger reclassification`(024bb54)
- 内容:
  - 空白点击修复: 根因一 NSClipView 吞文档外空白(→PausableLibraryScrollView.hitTest 对 contentView 返回 self),根因二 onClickBlank 门控仅 .launcher(→放行 .appLibrary);--libraryblanktrace 10/10 场景 OK
  - 分类卡常用排序: CategoryCommonRanker(override>launchCount 频率>Page1 冷启动先验>lastLaunchedAt tie-break>stable);手动覆盖置顶;Suggestions 独立不污染
  - 三指重分类: AppLibraryReclassificationDragController(仅大图标源/仅普通分类目标/同分类 no-op/空白 cancel/drop→override→热刷新/拖拽期挂起滚动+翻页/无 LayoutStore)
  - Settings 两列表单对齐: SettingsFormRow 共享 labelColumnWidth,复选框/热键/下拉/slider 值列一致,三语验证
- 测试: LaunchCore 180 / LaunchPlatform 142 / LaunchUI 326 全绿;Debug build OK。
- 评审 qwen3.7-plus: 0 BLOCKER / 0 MAJOR / 3 MINOR。视觉: Library 卡片+Settings 表单 PASS(0B/0M)。
- **Phase B: perf/page-compositor-v0.4.x 分支自本 checkpoint 创建, 移植 perf/page-compositor@8b4d8f3 的 PageCompositor 架构。**

## P2 移植(perf/page-compositor-v0.4.x @11ad60c, 2026-08-13)

- 已移植并推送分支(未合 main): PageVisual/PageVisualCache/PageVisualRenderer/PageCompositor/PageCompositorProbe;
  冲突按当前架构解决, Phase A 六项成果全部保留(评审逐项核对);修正 leadingDocumentOffset placement、
  密度资格门默认 20、并发 prepare 串行化 + languageRevision 快照(修复并行套件 L10n 竞态 flaky)、renderer availableIDs let。
- kill switch: `--pagecompositor` 默认关 + `--disable-pagecompositor`;缓存 miss → live 降级, 绝不阻塞手势起点。
- 测试: LaunchUI **355/355**(基线 304 + P2 51, 10+ 轮稳定), Debug build OK;LaunchCore/Platform 零改动。
- 评审 qwen3.7-plus: 0 BLOCKER / 0 MAJOR / 3 MINOR(防御性)/ 2 NOTE。
- **决策: DO NOT SHIP(暂不合 main)**。headless 无法 idle 预渲染(`PAGECOMPOSITOR visuals not ready`),
  真机 40-60 App 页 A/B(p95/手感)是 MANUAL_PHYSICAL_GATE。main 保持 pre-page-compositor-v0.4.0 稳定 checkpoint。
- 真机 A/B 命令: `open /Applications/LaunchBetter.app --args --pagecompositor`(或从分支构建)对照
  `--pagingtelemetry` 帧间隔(/tmp/lb-paging-telemetry.log);`--disable-pagecompositor` 为 live 基线。
- 回滚: `git checkout main`(024bb54 稳定) 即可。
- 已知限制: Settings 控件内部标题(弹出菜单/按钮)在 CALayer.render 下仍镜像
  (与既有 `--settingsshot` 一致, 属捕获管线限制, 非 Stage E 回归);壁纸预览两
  矩形区域 layer-render 为黑色;mid 内容不足一屏 → STABLE_NOOP(记录, 非缺陷);
  探针曾观察一次 navigate→Library 的 settle 竞态(重跑成功, 待实机确认)。
- 实机物理 gate 仍未验收: 真实触控板、120Hz 手感、物理时间连续性。

## 本阶段环境限制(已验证)

- `AXIsProcessTrusted()=false` → 无法注入真实 CGEvent(需系统辅助功能权限), computer-use/orca 也看不到启动器窗口(AX 不可见)。
- 无头 nohup 启动时窗口 alpha 卡 0(动画不运行), v0.3.7 干净构建同样如此 → 本环境截图/视觉验证降级。
- 视觉验证代之以: 程序化断言探针(权威) + 既有 v0.3.7 截图证据; 后续需用户在实机上完成视觉 gate。

## 下一步(未开始)

- Folder 空间过渡(source-anchored, 可中断, 无效源 fallback)、Launcher 呈现/解散动效、Settings 呈现/关闭动效、Cell 按下反馈、拖拽 grab offset 审计、Paging 三细节(1:1/动量投影/非线性橡皮筋)、Reduce Transparency/Contrast 响应、性能 profile、可视化验证、Luna 终审。

## v0.3.6 Changes

- `GridGeometry` 接收运行时顶部/底部保留区; `PagingGridLayout` 基于搜索框与页点占用的可用内容区垂直布局。
- 顶部保留区由 safe area、搜索框实际高度和安全间距计算; 底部保留区由页点区域、底部安全区和安全间距计算。
- flipped 文档中 `frame.minY` 是视觉顶部; `availableContentRect` 使用 `[topInset, pageHeight-bottomInset]`, overflow 时优先保护顶部。
- 搜索模式第 0 行从 `availableContentRect.minY + defaultSearchPadding` 开始; 文件夹滚动区显式使用 `top=0/bottom=0`。
- 运行时 frame invariant 使用 AppKit `convert` 到 contentView; normal gap 27.25pt、search gap 48pt、overlap=false、collectionView flipped=true。
- 分页 document height 使用当前 clip viewport; `pagetest`、`pagingprobe`、`dragcacheprobe`、`smoke --folders` 均通过。
- Settings 入口改为无 image 的自定义 CALayer 按钮: 40×40、cornerRadius 11、22pt systemBlue 齿轮、玻璃背景、hover/pressed。
- 验证: LaunchCore 143、LaunchUI 56、LaunchPlatform 127 测试通过; Debug/Release build 成功。

## v0.3.4 修复(用户实测)

- 热角: active-corner guard(停在角上只触发一次, toggle 不再闪开关); 左上角 toggleLauncher 正常
- 壁纸模糊强度 / 搜索栏大小修改即时生效(reapplyVisualConfig on onConfigChange)
- 搜索栏等比缩放(宽+高, 居中)
- cellSize = iconSize + 28(图标最大档标签不被挤进图标)
- GridGeometry gridOrigin top/bottom inset(网格不顶出搜索栏)
- 设置打开时点击启动器只关设置不退出(hide guard child)
- 设置窗口 isMovableByWindowBackground(拖动面板空白移动, 不透传)
- pagetest 自适应页数
- 测试: Core 143 / Platform 127 / UI 56

## v0.3.3 修复(用户实测)

- AppRecord 语言代码规范化(zh_CN/zh_TW/zh-CN → zh-Hans/zh-Hant 族):
  系统性修复所有同类应用中文名(百度网盘/微信等, 非单点)
- 设置窗口 isOpaque 深色背景(红绿灯在面板内)
- 壁纸模糊强度 slider(0-60, 接入 WallpaperProvider.blurRadius)
- 搜索栏宽度 slider(200-600)
- 热角容差 10→24pt(之前太小难触发)
- 设置齿轮 28→36
- 点击设置面板外关闭设置
- 测试: Core 143 / Platform 127 / UI 56

## v0.3.1 修复(用户实测)

- 设置入口: 启动器右上角齿轮 → SettingsWindowController(之前无入口改语言;
  根因 config.language 残留 english → 菜单英文 + 微信显示 WeChat)
- 文件夹容器圆角正方形(原 96×80 矩形; iconFrame 改为 iconSize×iconSize 居中)
- 文件夹按钮 .texturedRounded(去掉毛玻璃上的小框)
- PagingTuning: displacementThreshold 0.15→0.10; flingMinimumDisplacementPages 0.12→0.05
  (修复 fling 阈值>位移阈值致 fling 永不触发)
- 测试: Core 140 / Platform 127 / UI 56; 探针 OK

## Stage A/B/C 成果(已验证)

- **Stage A(架构+隐形性能)**: RetryBackoff capped[250ms..30s]; drag 热路径去每帧
  setDragSourceHidden + 单次 hit-test; snapshot index cache 测量 defer(13.66us/call 稳态0);
  DiskCacheWriter 磁盘写离首屏 + live 无二次光栅化; Retina viewDidChangeBackingProperties;
  可点击页点(复用 startSettle); FolderViewController 去 reloadData; LayoutStore 去假 DisplayModel;
  诊断提取 Diagnostics/; DragController 拆 6 文件; A13 defer; A14 DisplayItem 稳定身份
  (folder=FolderID, children=payload, 无假 delete/insert)
- **Stage B(功能)**: 本地化应用名(.lproj/InfoPlist.strings/CFBundle*, schemaVersion 升级,
  语言切换即时, OpenStep plist 解析已验证); 自定义来源端到端(动态源+monitor scopes,
  sourceGeneration 防幽灵应用); 右键菜单 Reveal in Finder/Get Info; 设置 About;
  B4 热键录制 defer; B6 垂直布局 defer(Luna 设计门)
- **Stage C(RC 硬化)**: 生命周期审计 14 资源(engine stop 清回调/display link teardown);
  压力测试 100/250/500 apps; CI(GitHub Actions macOS); 并发评审修复:
  Multitouch box owner token + 设备订阅同锁串行化 + restart/stop 生命周期代数 +
  sourceGeneration/DirectoryMonitor streamGeneration(幽灵应用)
- 测试: Core 140 / Platform 127 / UI 56 全绿; build OK; 探针全过
- 报告: Docs/PhaseReports/stage-03-post-v0.2.3-consolidation.md
- 待实机: 三指/四指手感、页点点击、本地化名实机抽查、Get Info 授权弹窗(manual)


## Stage A 成果(已验证)

- A1 RetryBackoff: FSEvents/持久化重试 capped backoff[250ms..30s], 成功/新事件 reset
- A2/A3/A4: drag 热路径去每帧 setDragSourceHidden + 每帧单次 hit-test(DragHitTarget);
  snapshot index cache 测量后 defer(13.66us/call, 稳态 0 次)
- A5/A6: DiskCacheWriter(actor, keyed dedup, 有界)磁盘写离首屏; live 不再双光栅化
- A7: CellRootView 用 viewDidChangeBackingProperties(标准 API, 替代 per-cell 通知)
- A8: 可点击页点 PageDotView(复用 startSettle, button 语义, 本地化 Page X of Y)
- A9/A12: FolderViewController 去 reloadData(结构/元数据分离); LayoutStore rename 无假 DisplayModel
- A10/A11: 诊断提取 Diagnostics/; DragController 拆 6 聚焦文件(单写者引擎保持)
- A13: LauncherStoring 分解 DEFER(设计注记 Docs/DesignNotes/)
- A14: DisplayItem 稳定身份(folder=FolderID, children=payload, 无假 delete/insert)
- 测试: Core 77+119 / Platform 102 / UI 50; build OK; smoke/pagetest/folders OK
- 报告/任务包: Docs/Tasks/* + Docs/DesignNotes/a13


- 基线: `v0.2.2` / `9ee1264`
- 发布分支: `main`
- 发布状态: Release 构建、ad-hoc 签名、自动化门禁及用户 P0 验收均已通过
- GitHub: `v0.2.3` tag/release 已准备发布

## v0.2.3 关键成果(自动化已验证)

- 文件夹事务完整性: create/add/reorder/remove/dissolve 的 missing/hidden 映射、去重、孤儿槽位与
  单子项自动解散规则统一；重启持久化使用明确 committed 结果，失败不提前发布 UI 状态
- 拖拽状态机: root pending-drop 取消不会污染下一次拖拽；文件夹来源身份正确隐藏；真实文件夹缩略图
  用作拖拽表示；3/6/9 与 4/5/7/8 尾槽几何有行为测试
- 并发与持久化: AppCatalogActor 增量扫描全局串行且具 generation 防陈旧；LauncherStore 外部刷新
  合并并在 reconcile 成功后发布；首次 no-op seed 也落盘
- 诊断与本地化: 非交互诊断不弹权限阻塞；smoke/drag/folder/three-finger/cache/paging 探针强化；
  en/zh-Hans/zh-Hant 文案与 accessibility 补齐
- 自动化门禁: LaunchCore 119 Swift Testing + 66 XCTest；LaunchPlatform 93；LaunchUI 37；
  Debug/Release build 通过；7 组必选诊断及 paging/search/grid 强化探针全部退出 0；
  最终 Luna 复审为 0 BLOCKER / 0 MAJOR
- `MANUAL_VERIFICATION_REQUIRED`: 鼠标与三指真实拖拽、App→App/文件夹、文件夹边界重排与拖出、
  Escape/隐藏/关闭取消、跨页、重启持久化、三种语言即时切换

## Stage 2 关键成果(已验证)

- **Parity Matrix**(Docs/FeatureParity/LaunchHistory-Parity-Matrix.md): 27 项全部源码证据审计;
  "LaunchHistory" 仅是缓存目录名, 无 launch history/recent/count(不凭名字推断)
- **Three-Finger Drag**: ThreeFingerDragRecognizer(LaunchCore 纯逻辑, 对齐旧语义
  count=3/0.005/0.15/2帧, 12 测试); 单一 MTDevice 订阅 finger-count 路由(3指拖动/4+指 pinch);
  复用 DragController(输入源互斥 .mouse/.threeFinger; changed coalescing 防主线程积压);
  指针位置语义与旧行为一致
- VERIFIED_PARITY 21 项(四指 0.18/0.2、热角 10/0.3/1.0、热键、壁纸、搜索、文件夹等);
  PARTIAL 4 项(自定义来源/context menu/热键预设/设置); NOT_PROVEN 2 项(launch history/vertical paging);
  MISSING 2 项(本地化应用名/垂直布局, 留下一阶段)
- 测试: 96 + 66(新增 12)全绿; build/smoke/pagetest/threefingerdiag OK; Luna 评审 0 BLOCKER 0 MAJOR
- 报告: Docs/PhaseReports/stage-02-legacy-interaction-parity.md
- **待用户实机三指验证(§24 Test A-H)**

## v0.1.6 关键成果(已验证)

- **PagingInteractionController + PageSnapAnimator**(v0.1.6 PART A):
  NSEvent → 状态机; CADisplayLink(NSView.displayLink)唯一 offset writer(每帧≤1 scroll);
  precise scrollingDeltaX/Y; gesture-level axis lock; 位置无低通; 速度 O(1) EMA;
  time-based 临界阻尼 spring(60/120Hz 一致); momentum 全拦截; 一次手势一次 settle 最多一页;
  displacement+velocity fling target; 外边缘 rubber band(刚度+饱和); 禁用系统横向弹性
- **Drag 优化**(PART C): lastDestination/lastGapIndex/currentTransforms/overlayVisual 缓存 +
  transform diff; folder hit-test 每帧一次; cache 绑定几何指纹与 displayRevision
- **Store**(PART D): commitLayoutChange 统一提交; SearchIndex 仅 catalog/customName 变化重建
- 实测: swipe scroll=39≤frames=46; prepare 4→4(0 额外); drag 50帧 preview=1;
  UI-only config searchRebuildDelta=0; custom name +1
- 测试: 96 + 54(新增 21)全绿; build/smoke/pagetest/searchprobe/pagingprobe/dragcacheprobe OK
- 报告: Docs/PhaseReports/stage-02-interaction-performance.md
- 待实机手感验证(§76-80): 慢速跟手/吸附/fling/snap 反向抓取/高频切换

## Current Task

- **Stage B(功能补齐)**: B1 本地化应用名 / B2 自定义来源 / B3 右键菜单 / B4 热键 / B5 设置 / B6 垂直布局(Luna 门)
- 完成 Stage C(RC 硬化)后收尾

## Current Branch

main

## Last Known Good Commit

v0.2.3 release commit (tag `v0.2.3`); 基线为 `v0.2.2` / `9ee1264`

## Stage 1 关键成果(已验证)

- **GridGeometry**(LaunchCore 纯逻辑): 几何唯一真值 — pageSize/columns/rows/cellSize/iconSize/
  spacing/pageCapacity + frameForSlot/slotForPoint/pageForPoint;21 XCTest
- **PagingGestureSession**(LaunchCore): 一次手势最多一页/惯性忽略/水平主导;7 XCTest
- pageWidth 唯一真值 = clip 可视宽; 拖拽/槽位/边缘翻页全部经 GridGeometry
- 搜索溢出: 垂直滚动结果网格(>42 结果可达), 退出恢复原页码; **flipped 文档视图修复**
  (非 flipped + 垂直滚动 bounds.origin 不同步 → 滚动后内容消失, 实测证据)
- rows/columns/iconSize Settings 真正生效(GRIDTEST 实测 8x5→capacity 40; 48/64/80/96 变体)
- 图标点尺寸 = IconKey pointSize 一致(48/64/80/96 变体测试); 跨显示器 scale 重请求
- 布局失效优化: 翻页 prepare 4→4(原 +1/次滚动)
- show/hide 修订去重(displayRevision; searchQuery 仅实际变化时 bump)
- 拖拽: 二维预览(含 gap 处被挤动项)、页边缘翻页防振荡、overlay 真实图标零磁盘 IO、
  拖拽期 revision 陈旧防护、overlay 视口坐标
- 截图管线: cacheDisplay 对纯 layer-backed 层级不可靠(假空图)→ layer render
- 测试: 96(swift-testing)+28(XCTest 新增)全绿; smoke/dragtest/pagetest/searchprobe/gridtest OK
- visual-reviewer(mimo)4 次误报(镜像/缺字形/裁切/搜索空), 均被像素级证据证伪;
  唯一真实捕获 = 搜索顶行裁切 → 促成 flipped 修复

## 编排规则(2026-08-10 用户明确)

- **实现一律走独立 implementer 窗口**(`opencode run -m opencode-go/deepseek-v4-flash`),
  与主对话完全隔离上下文, 防污染。任务包模板见 .opencode/agents/implementer.md;
  主对话禁止在同一会话改生产代码(只做规划/打包/验证/提交/评审)
- **超长 Prompt 协议**: 收到长任务先"解析回读关键约束清单 → 用户确认 → 拆 todo → 外部化
  到 Docs/Tasks/ 或 MEMORY → 逐项验收", 不依赖模型记忆(防遗忘/防幻觉)

## 阶段收尾规则(用户要求, 必须执行)

每个大阶段完成后:
1. 删除旧版本 App(仅保留最新): 清空 DerivedData/Build/Products 中的旧 Debug/Release 构建,
   /Applications/LaunchBetter.app 只保留最新(ad-hoc 签名覆盖安装)
2. 推送 GitHub(分支 + 报告), 待用户决定合并

## Completed Milestones

- 环境确认: macOS 26.5.2, Xcode 26.6 (17F113), Swift 6.3.3, git 2.50.1, gh 2.96.0
- gh 已登录: zhou1736948757-cpu (repo scope)
- 旧仓库只读分析完成(详见 Docs/PhaseReports/phase-00-bootstrap.md)
- GitHub 私有仓库创建: github.com/zhou1736948757-cpu/LaunchBetter (PRIVATE)
- Phase 1A: LaunchCore 11 源文件 + 59 测试(现 82)
- Phase 1B: NSCollectionView spike — 60Hz 显示器验证翻页/拖拽零掉帧;
  snapshot apply ~6ms(120Hz 预算 8.33ms 下逐帧不可行,证实设计);**120Hz 无法本机实测**
- Phase 1C: DisplayModel + LayoutTransaction(显示空间纯逻辑)
- Phase 2: LaunchPlatform — 发现/对账/持久化/迁移/AppCatalogActor,真实 /Applications 冒烟 40 应用
- Phase 3: Xcode 工程(xcodegen)+ LaunchUI + LaunchBetterApp —
  冒烟: 87 应用/3 页(42 每页)/搜索 chrome=1/真实启动 Chrome 成功/跨重启快照恢复
- Phase 4: 图标管道完成 — 142 测试;基准: 冷 87 图标 1.76s,热 5.5ms(0.06ms/图标)
- **Luna Max 评审修复**: 0 BLOCKER / 3 MAJOR(M1 取消语义、M2 代际陈旧防护、
  M3 生命周期 shutdown)全部修复 + 2 个 MINOR(canonicalString 长度前缀、
  内存压力语义统一);4 个 MINOR/NOTE 记录待办(磁盘缓存上限策略等 Phase 9/10)
- **模型路由(用户指令,已生效)**: reviewer = gpt-5.6-luna variant:max;
  visual-reviewer = mimo-v2.5(图像能力验证通过: 灰兔图片正确描述)
- **Watchdog 已启动**: Scripts/status-watchdog.sh(600s 周期,后台 pid 见 /tmp),
  状态 /tmp/launchbetter-watchdog/state.json + log;首轮: 上下文 0.2%、网络 OK
- 环境怪癖记录: NSScreen 可选值 `??` 推断保留 Optional(必须 if-let);
  screencapture 无 TCC 屏幕录制权限 → 应用自渲染截图(--screenshot);
  `opencode run --session` 是续会话参数,新会话不要传

## Verified Technical Facts

- 旧版四指捏合参数(待 Phase 8 重新验证): 4 指, 阈值 0.18, 冷却 0.2s;三指: 位移 0.005, 容差 0.15, 2 帧确认
- 旧版壁纸: CIGaussianBlur 半径 30, key 后 0.12s 冻结, 背景 alpha = opacity*0.3
- 旧版网格: 默认 7 列, hSpacing 36, vSpacing 28, labelMaxWidth 90, 图标 48/64/80/96
- 旧版热角: 0.05s 轮询, 容差 10pt, 停留 0.3s, 冷却 1s
- 旧版图标磁盘缓存: AppMetadataCache.json + IconSnapshots/<fnv-hash>.png, Info.plist mtime 失效
- 旧版崩溃根因: AppIconResolver.swift:417 main.sync;后台扫描闭包持有 ViewModel;仅 2 个 @MainActor 类;.id(layoutVersion) 整树重建
- 全新 bundle ID: dev.launchbetter.LaunchBetter(开发期稳定 ID,公开发布前需复核)
- 部署目标决策: macOS 14.0 (Sonoma)
- 本机真实应用数: /Applications 40 + /System/Applications 46 + ~/Applications 1 = 87
- 本机无 Safari(搜索 "safari" 返回 0 是正确行为);Chrome/Xcode/Notes 等存在

## Current Performance Measurements

- 无正式 signpost;spike 数据: 60Hz 下翻页/纯 layer 拖拽零掉帧;
  diffable snapshot apply mean 6.09ms / p95 6.45ms
- 待测: 启动快照加载(< 10ms 目标)、LauncherShow(< 100ms 目标)

## Known Issues / Blockers

- 任务工具(task)只能路由 explore/general,无法路由项目 agents;
  **已通过 `opencode run --agent <name>` 独立窗口解决**(GLM/Luna 评审可行;
  并发窗口上限 4,单一写者规则保持: 评审窗口全部只读)
- Watchdog: session.compact 无 HTTP 端点,50% 上下文预警采用状态文件 +
  MEMORY 新鲜性检查(自动压缩由 opencode 在上下文满时执行)
- in-process Task 子代理不可被外部 watchdog 观察
- 视觉 MINOR(待 Phase 9): 浅色图标上白标签对比度弱、长名省略号、
  标签与图标间距小(Phase 3 截图曾出现 1 个空图标块,未复现)
- 120Hz 性能验证受限于本机 60Hz 显示器

## Architecture Changes

- 三包架构: LaunchCore / LaunchPlatform / LaunchUI,依赖方向 Core ← Platform, Core ← UI ← App
- 四运行时管道: A 目录数据 / B UI 结构 / C 图标资源 / D 逐帧交互
- 从旧版确认丢弃: main.sync 路径、每次显示全量扫描、didLaunchApplicationNotification 触发全量扫描、大 Codable UserPreferences 树 + NotificationCenter 同步、CGDisplaySetDisplayMode 改系统刷新率、.id(layoutVersion) 整树重建、AppleLanguages 重启式语言切换
- Phase 1A: AppID/FolderID 纯文本规范化;SearchIndex 大小写+变音符不敏感包含匹配、结果按 AppID 排序
- Phase 1C 落实: DisplayModel 按 pageCapacity 重分块(UI 恒不超容量);
  LayoutTransaction 显示空间操作 + LayoutMutation 契约
- Phase 2: 持久文件 JSON + schemaVersion;损坏备份不静默清除;actor async API
- Phase 3: AppCatalogActor 方法 async,MainActor 缓存快照(§62 模式);
  LauncherStore 启动同步恢复快照 → 后台对账;调试模式 --screenshot/--smoke

## Rejected Approaches

- 放弃旧架构整体迁移(目标即避免旧崩溃类)
- 放弃 bundle ID 复用 com.Eric-Yang.Launchpad-Back
- 放弃 LaunchHistory v0.8 用户数据迁移(旧应用保留为参考)
- 放弃 displayName/自定义名做 AppID(路径身份保持确定性)
- 放弃 screencapture 截图方案(TCC 权限不可用,应用自渲染替代)

## GitHub / Release Status

- 仓库: github.com/zhou1736948757-cpu/LaunchBetter (**PUBLIC**)
- 当前正式版本: **v0.2.3**
- v0.2.2 基线: `9ee1264`
- v0.2.3: hardening、自动化门禁和用户 P0 验收完成

## Next Actions

1. 后续版本处理 parity gap: 本地化应用名、自定义来源、热键录制、设置扩展、垂直布局
2. 继续观察混合缩放显示器上的文件夹子项拖拽清晰度与持久化拒绝反馈

## Watchdog 状态(规则自检已启用)

- 运行中(600s 周期; `--once` 可立即执行一轮), 状态 /tmp/launchbetter-watchdog/state.json
- 检查项: 上下文使用率(≥50% 尝试 compact, 最佳努力) / MEMORY 新鲜度(新提交未同步即 STALE) /
  MEMORY 必需章节结构(§24) / 违禁模式扫描(main.sync=0) / subagent 进程 / 构建卡死 / 网络
- 实践记录: Watchdog 已成功拦截真实违规(章节改名、提交未同步 MEMORY), 规则自检有效
- 上下文 ≥50% 自动 compact: **最佳努力** — session.compact 是 TUI 命令无 HTTP 端点,
  脚本探测 server 失败时仅记录建议(真实限制, 需人工或等上下文满自动压缩)

## Last Updated

2026-08-11

## Stage D motion system 收尾（2026-08-11）

- 主要实现: Launcher/Folder/Settings 转场、press/drag、paging、accessibility/material、lifecycle/perf/diagnostics。
- 自动化已验证: LaunchCore 87 XCTest + 143 Swift Testing；LaunchPlatform 127 Swift Testing；LaunchUI 5 XCTest + 152 Swift Testing；Debug/Release `BUILD SUCCEEDED`；`git diff --check` 通过。
- 历史探针 `motionprobe/layoutdiag/pagetest/pagingprobe/dragcacheprobe/smoke --folders/searchprobe/settingsownershipprobe` 曾通过；最终 Settings 修复后的 `motionprobe` 复跑进入 `NSApplication.run` 后无输出，结果不确定，不宣称通过。
- 性能: 首次 show 36.2 ms、warm 2.2–5.6 ms；首次 wallpaper 232.8 ms、warm 2.1–5.5 ms。
- 独立最终 Sol medium 审查: 0 blocker / 0 major / 0 minor。
- Computer Use/屏幕捕获受 `.screenSaver`/权限链路限制；时间连续性、真实触控板甩动速度、120 Hz 手感均为 `MANUAL_PHYSICAL_GATE`，尚未验收。报告: `Docs/Reports/stage-d-motion-validation.md`。

<!-- chef-worker-reviewer-workflow:memory:start -->
## Workflow memory

- Workflow version: `1.4` (fresh start 2026-08-26; previous run archived to `Workflow一/`)
- Project: `LaunchBetter`
- Initialized at: `2026-08-26T13:41:00+09:00` (fresh)
- Reconfigured at: `2026-08-26T13:38:10+09:00` (superseded by fresh start)
- Artifact root: `Workflow/`
- Archive: `Workflow一/` (prior run T-001..T-012, ARCHIVE-NOTE.md included)
- Source contract: `AGENTS.md`

### Runtime configuration
<!-- chef-worker-reviewer-workflow:runtime-config:start -->

- Main/Orchestrator model declaration: `current-main-conversation` (current main conversation; routing may be unverified)
- Chief model: `ollama/glm-5.2`
- Worker model: `ollama/deepseek-v4-flash:0731`
- Reviewer model: `ollama/minimax-m2.7`
- Worker maximum concurrency: `2`
- Default thinking depth: `max`
- Configuration file: `Workflow/config.json`

<!-- chef-worker-reviewer-workflow:runtime-config:end -->

### Role assignments

| Role | Owner / agent ID | Scope | Status |
|---|---|---|---|
| Main | `current-main-conversation` | Runtime center: dispatch, state, evidence | active |
| Chief | `Chief` | planning, decisions, routing | idle |
| Worker | `Worker` | bounded implementation tasks | idle |
| Reviewer | `Reviewer` | independent verification | idle |

### Current state

- Workflow status: `PASSED` (T-013 closed 2026-08-26; T-014 record reconciliation closed with recorded deviation; T-015 acceptance-truthfulness correction closed 2026-08-26; automated acceptance complete; previous run archived to `Workflow一/`)
- Active task: `none`
- Next action: User supplies next development goal → Chief Initial Global Planning → `Workflow/PLAN.md` + initial task packets.
- Blocker: `MANUAL_PHYSICAL_GATE` only (real-device 60/120 Hz trackpad/compositor validation — **OPEN / REQUIRED**; no physical validation performed)
- Last verified: `2026-08-26T17:08:00+09:00`

### Task ledger

| Task ID | Objective | Owner | Status | Review | Evidence |
|---|---|---|---|---|---|
| `T-000` | Initialize workflow contract | Chief | `PASSED` | `N/A` | `AGENTS.md`, `Workflow/config.json`, `Workflow/manifest.json` |
| `T-008` | Settle telemetry lifecycle correctness | Worker | `PASSED` | `T-008-R1-r1 PASS` | `Workflow/results/T-008.md`, `Workflow/reviews/T-008-R1-r1.md` |
| `T-009` | Probe counter isolation and nonnegative semantics | Worker | `PASSED` | `T-009-r1 PASS` | `Workflow/results/T-009.md`, `Workflow/reviews/T-009-r1.md` |
| `T-010` | Real active compositor interruption integration evidence | Worker | `PASSED` | `T-010-R2-r1 PASS` | `Workflow/results/T-010.md`, `Workflow/reviews/T-010-R2-r1.md` |
| `T-011` | Strict callback ordering evidence | Worker | `PASSED` | `T-011-r1 PASS` | `Workflow/results/T-011.md`, `Workflow/reviews/T-011-r1.md` |
| `T-012` | Final package/evidence verification before T-007 closure | Worker | `PASSED` | `T-012-r2 PASS; MANUAL_PHYSICAL_GATE open` | `Workflow/results/T-012.md` (canonical), `Workflow一/reviews/T-012-r2.md` |
| `T-013` | Close final interruption evidence and normalize acceptance records | Worker | `PASSED` | `T-013-r1 PASS` | `Workflow/results/T-013.md`, `Workflow/reviews/T-013-r1.md` |
| `T-014` | Final workflow state reconciliation (record-only) | Worker | `PASSED WITH RECORDED DEVIATION` | `T-014-r1 PASS; T-015-r1 PASS (AC2 lifecycle completeness NOT MET, Chief ACCEPT_RECORDED_DEVIATION)` | `Workflow/results/T-014.md`, `Workflow/reviews/T-014-r1.md`, `Workflow/decisions/T-015-t014-acceptance-deviation.md` |
| `T-015` | T-014 acceptance-truthfulness correction & lifecycle recording discipline (record-only) | Worker | `PASSED` | `T-015-r1 PASS` | `Workflow/results/T-015.md`, `Workflow/reviews/T-015-r1.md` |
| `T-016` | Real-device 60/120Hz paging feel + PageCompositor physical acceptance (human-in-the-loop) | Worker | `BLOCKED` | `Reviewer PASS (1Q+3MINOR); §5.3 no 120Hz hardware → BLOCKED; MANUAL_PHYSICAL_GATE OPEN/REQUIRED; 60Hz 4-run data saved; mirror bug root cause PageCompositor.swift:191 isGeometryFlipped (unfixed)` | `Workflow/results/T-016.md`, `Workflow/evidence/T-016/` (runs/observations/analysis), `Workflow/reviews/` (Reviewer reply archived by Main) |
| `T-017` | Fix PageCompositor mirror bug (Chief plan A: remove isGeometryFlipped) | Worker | `PASSED` | `T-017-r1 PASS; production diff -1 line; direction test red→green (3 assertions failed pre-fix = red/blue inverted); full regression 471/66+200/16+149/23+33/33 green; T-013 zero violation; acceptance #3 interactive verification pending user` | `Workflow/results/T-017.md`, `Workflow/reviews/T-017-r1.md`, `Workflow/tasks/T-017.md`, `Workflow/PLAN.md`, `Workflow/MAIN_BRIEF.md` |
| `T-007` | Corrected automated acceptance conclusion | Chief | `PASSED` | `T-013-r1 PASS; MANUAL_PHYSICAL_GATE open` | `Workflow/results/T-007.md` (canonical, precise diff attribution) |

### Decisions

No non-trivial decisions recorded yet.

### Work log

<!-- chef-worker-reviewer-workflow:work-log:start -->

### 2026-08-25T19:36:39+09:00 — T-001
- Role: `Worker`
- Action: Implemented direction-aware two-page compositor + first page visual prepare
- Result: All 445 LaunchUI tests pass, Reviewer PASS
- Evidence: `Workflow/results/T-001.md`
- Next: T-002 dispatch

### 2026-08-25T19:36:39+09:00 — T-002
- Role: `Worker`
- Action: Disabled default diagnostics hot path + added activation reason telemetry
- Result: All 453 LaunchUI tests pass, Reviewer PASS
- Evidence: `Workflow/results/T-002.md`
- Next: T-004 verification

### 2026-08-25T19:36:39+09:00 — T-003
- Role: `Worker`
- Action: Added PagingFollowCurve opt-in damped experiment
- Result: 10 new tests pass, Reviewer PASS, MANUAL_PHYSICAL_GATE
- Evidence: `Workflow/results/T-003.md`
- Next: T-004 verification

### 2026-08-25T19:36:39+09:00 — T-004
- Role: `Chief`
- Action: Full verification: 802 tests pass across 3 packages, git diff clean
- Result: All acceptance criteria met, MANUAL_PHYSICAL_GATE for trackpad
- Evidence: `Workflow/results/T-004.md`
- Next: Workflow complete

### 2026-08-25T23:38:49+09:00 — T-005
- Role: `Worker`
- Action: Fixed PageVisual compositor placement gridOrigin alignment
- Result: Coordinate tests and package verification passed; Reviewer PASS
- Evidence: `Workflow/results/T-005.md`
- Next: T-006 execution

### 2026-08-25T23:38:50+09:00 — T-006
- Role: `Chief`
- Action: Accepted compositor interruption, telemetry, flag, damping, API repairs after review loop
- Result: Final Reviewer PASS; Sol medium escalation ACCEPT; MANUAL_PHYSICAL_GATE remains
- Evidence: `Workflow/reviews/T-006-final-r1.md`
- Next: T-007 closure

### 2026-08-25T23:38:50+09:00 — T-007
- Role: `Chief`
- Action: Completed final package verification
- Result: LaunchCore 200, LaunchUI 459, LaunchPlatform 149; diff check clean
- Evidence: `Workflow/results/T-007.md`
- Next: Workflow complete with physical gate open

### 2026-08-26T04:00:00+09:00 — T-012
- Role: `Worker`
- Action: Ran all required package, diff, and status verification commands; reconciled T-008 through T-011 evidence and reviews
- Result: LaunchCore 200, LaunchUI 467, LaunchPlatform 149; diff check clean; T-010-R2 covered-reverse evidence PASS supersedes the earlier T-010-r1 FAIL; T-007 may be re-evaluated after final review; MANUAL_PHYSICAL_GATE remains open
- Evidence: `Workflow/results/T-012.md`, `Workflow/reviews/T-010-R2-r1.md`
- Next: Final Reviewer to certify corrected T-012, then update T-007 acceptance conclusion

### 2026-08-26T04:30:00+09:00 — T-007 corrected closure
- Role: `Chief`
- Action: Reconciled T-008/T-009/T-010/T-011 evidence and corrected the reopened T-007 acceptance record
- Result: Automated acceptance PASS; Core 200, UI 467, Platform 149; diff check clean; T-010-R2 PASS supersedes the earlier T-010-r1 FAIL; MANUAL_PHYSICAL_GATE remains open
- Evidence: `Workflow/results/T-007.md`, `Workflow/reviews/T-012-r2.md`
- Next: Real-device 60/120 Hz physical validation; do not claim subjective smoothness until performed

### 2026-08-26T15:55:00+09:00 — T-013 closure
- Role: `Main`
- Action: Dispatched Worker (T-013-A last-page active-settle interruption test; T-013-B two telemetry E2E tests; T-013-C record normalization); verified production untouched (mtime + diff stat); independent Reviewer PASS (18/18)
- Result: Automated acceptance PASS; Core 200, UI 470 (+3), Platform 149; diff check clean; last-page Page 2 → Page 3 active settle → mid-settle → Page 4-direction interruption → live fallback → Page 3 evidence closed; T-013 test/record-only; MANUAL_PHYSICAL_GATE remains open
- Evidence: `Workflow/results/T-013.md`, `Workflow/reviews/T-013-r1.md`, `Workflow/results/T-007.md`, `Workflow/results/T-012.md`
- Next: Real-device 60/120 Hz physical validation; do not claim subjective smoothness until performed

### 2026-08-26T16:46:00+09:00 — T-014 closure
- Role: `Main`
- Action: Record-only final workflow state reconciliation: STATE fixed (T-000 PASSED, T-013 attempts 1/1 rebuilt from completion evidence, workflow PASSED); honest state_changed events appended (no backfilled dispatch/start); T-012-r2 Addendum 2 with nl -ba verified line numbers + stable section identifiers; T-000 configuration supersession decision; B1 evidence-scope addenda (T-013 result + review); independent Reviewer PASS (7/7)
- Result: Record acceptance PASS; STATE/MEMORY/events consistent; no READY task coexists with PASSED workflow; git diff --check clean; HEAD==origin/main; no commit/push/tag/release; MANUAL_PHYSICAL_GATE remains open
- Evidence: `Workflow/results/T-014.md`, `Workflow/reviews/T-014-r1.md`, `Workflow/decisions/T-000-configuration-supersession.md`
- Next: Real-device 60/120 Hz physical validation; do not claim subjective smoothness until performed

### 2026-08-26T17:08:00+09:00 — T-015 closure
- Role: `Main`
- Action: T-014 acceptance-truthfulness correction per user review: Chief Decision Delta ACCEPT_RECORDED_DEVIATION (T-014 AC2 timeline honesty PASS / lifecycle completeness NOT MET / no backfill of missing worker_dispatched/review_started; T-014 = PASSED WITH RECORDED DEVIATION); T-014 result 10-point Addendum; T-012-r2 Addendum 3 stable-reference policy (no live line numbers, resolve by heading + Task ID); T-013-r1 item 15 supersession note; Reviewer PASS 14/14 with Reviewer-owned confirmation; T-015 itself recorded the complete real lifecycle chain task_created → decision_recorded → worker_dispatched → worker_completed → review_started → review_passed → task_closed (events seq 13–19)
- Result: Record acceptance PASS; all canonical records consistent; STATE/MEMORY/events aligned; git diff --check clean; HEAD==origin/main; no commit/push/tag/release; MANUAL_PHYSICAL_GATE remains OPEN/REQUIRED
- Evidence: `Workflow/results/T-015.md`, `Workflow/reviews/T-015-r1.md`, `Workflow/decisions/T-015-t014-acceptance-deviation.md`
- Next: Real-device 60/120 Hz physical validation; do not claim subjective smoothness until performed

### 2026-08-26T23:50:00+09:00 — T-016 closure
- Role: `Main`
- Action: Real-device physical acceptance (human-in-the-loop): 60Hz round R1–R4 completed (96 formal trackpad gestures, blind order seed 20260826: R1=D R2=C R3=A R4=B; user oral-mode scores all 7/10, 8 standard defects all NO); 120Hz round NOT RUN (no 120Hz mode on built-in display, no external display → §5.3 BLOCKED); MOUSE SUPPLEMENTAL NOT RUN (no mouse); Worker phase 2 analysis (compositor ON p95 median 16.81ms vs OFF 17.70–18.70ms, matches user feel; per-gesture p95 medians all <25ms but no per-frame data → proxy bounds only, honestly labeled); mirror bug found on compositor-ON runs (R2/R3): icons+labels vertically mirrored during scroll, position unchanged, restored on settle — root cause `Packages/LaunchUI/Sources/LaunchUI/PageCompositor.swift:191 layer.isGeometryFlipped = true` (CALayer flips contents; live path non-flipped; activate hides live via opacity=0; teardown restores), confirmed by independent experiment (calayer-flip-experiment.swift); Reviewer PASS with 1 QUESTION (formal/warmup split not independently verifiable from logs) + 3 MINOR; no source/test/config changes (git diff --check clean, HEAD==origin/main==cb180e4)
- Result: T-016 PHYSICAL ACCEPTANCE: BLOCKED; MANUAL_PHYSICAL_GATE remains OPEN/REQUIRED; 60Hz evidence archived (runs/observations/analysis, reproducible scripts); mirror bug documented with root cause, NOT fixed (out of scope); no commit/push/tag/release
- Evidence: `Workflow/results/T-016.md`, `Workflow/evidence/T-016/` (runs/60hz-R1..R4, observations/60hz-R1..R4-scores.md, analysis/phase2-analysis.md + analyze_60hz.py + calayer-flip-experiment.swift)
- Next: Reopen physical acceptance on 120Hz-capable hardware (external ProMotion display) or new task; mirror bug fix candidate (remove isGeometryFlipped / contentsTransform compensation / y-up rasterize + compositor-layer orientation test) for a future dev task

### 2026-08-27T00:40:00+09:00 — T-017 closure
- Role: `Main`
- Action: Chief Initial Global Planning (PLAN.md/MAIN_BRIEF.md formalized, T-017 packet created; Chief decision A: remove `PageCompositor.swift:191 layer.isGeometryFlipped = true` — one-line deletion, B as fallback, C rejected); Worker TDD implementation: new direction test `compositorLayerRendersUpright` (real `activate` path + `render(in:)` pixel assertions + `layerFramesForDiag == baseFrame`), red→green with real evidence (3 assertions failed pre-fix = red/blue inverted; false-positive caught: `hostLayer.render(in:)` does not apply sublayer flip → render compositor sublayer directly); full regression LaunchUI 471/66, LaunchCore 200/16, LaunchPlatform 149/23, GridIntegration 33/33, diff --check clean; Reviewer PASS (6/6 verified, incl. independent red-state worktree rerun and flip-mechanism experiment; 2 MINOR: T-016 legacy experiment comment, acceptance #3 pending user); T-013 zero violation; no commit/push/tag/release
- Result: T-017 PASSED (implementation + review); production diff exactly −1 line; `MANUAL_PHYSICAL_GATE` remains OPEN/REQUIRED; acceptance #3 (user interactive verification: scroll with compositor ON, confirm no mirror) pending user
- Evidence: `Workflow/results/T-017.md`, `Workflow/reviews/T-017-r1.md`, `Workflow/tasks/T-017.md`, `Workflow/PLAN.md`, `Workflow/MAIN_BRIEF.md`
- Next: User interactive verification (acceptance #3); then decide next dev goal (e.g., T-018 120Hz physical acceptance on capable hardware, or other improvements)
<!-- chef-worker-reviewer-workflow:work-log:end -->

### Review findings

No review findings recorded yet.

### Risks and follow-ups

- Confirm project-specific test commands before dispatching the first Worker task.
- Keep detailed task, result, and review evidence in `Workflow/` and link to it here.

### Update rules

- Chief owns current state, task status, and decisions.
- Worker appends implementation evidence and deviations.
- Reviewer appends findings and verification results.
- Keep entries concise, append-oriented, and free of secrets.
- Do not delete resolved findings; mark them resolved with evidence.
<!-- chef-worker-reviewer-workflow:memory:end -->
