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

**v0.1.11 — 用户实测调参: followSensitivity 1.15, displacementThreshold 0.15**, 已安装 /Applications, tag v0.1.11

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

- 用户待办: ① 真实双指滑动翻页实测(Test A-E, §38); ② 图标/标签间距再加大一点;
  ③ 设置界面入口(面板内加按钮); ④ 搜索栏具体问题待用户补充
- 剩余: 正式签名分发(需 Apple 凭据, 可选); 长名断行/文件夹图标区分/磁盘缓存上限/120Hz 复测;
  三指拖拽/垂直布局/LaunchHistory parity 属 Stage 2

## Current Branch

fix/v0.1.3-grid-foundation(Stage 1 完成, 待用户决定合并)

## Last Known Good Commit

d1696cd (Stage 1 报告 Docs/PhaseReports/stage-01-grid-foundation.md; 评审 8/8 PASS)

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
- 版本: v0.1.0(首版) → v0.1.1(图标色块/标签/壁纸性能) → **v0.1.2(翻页修复, 268ab36)**
- 预发布审计通过: secret scan 干净 / 无硬编码私密路径 / 182 测试全绿 / GPL-3.0 就位
- 四指手势实测通过(用户验证), 触点帧开销 1-6μs/帧

## Next Actions

1. 真实触控板双指滑动翻页实测(程序化已通过: 1470→2940→1470)
2. 图标/标签间距: 方向已对(图标 64pt/66%, 单行标签, 间隙~16pt), 再加大一档定稿
3. 设置界面: 面板内无入口(全屏置顶时菜单栏不可见) → 需在面板加设置按钮;
   壁纸开关未真正接入 WallpaperProvider; 热键仅 5 预设; 语言切换后设置窗口不即时刷新
4. 搜索栏具体问题待用户补充现象(当前: 结果单页列表, 顶部居中)
5. **可选**: Apple 签名/公证凭据 → 正式分发
6. 打磨: 长名断行优化、文件夹图标区分、磁盘缓存上限策略、120Hz 复测

## Watchdog 状态(规则自检已启用)

- 运行中(600s 周期; `--once` 可立即执行一轮), 状态 /tmp/launchbetter-watchdog/state.json
- 检查项: 上下文使用率(≥50% 尝试 compact, 最佳努力) / MEMORY 新鲜度(新提交未同步即 STALE) /
  MEMORY 必需章节结构(§24) / 违禁模式扫描(main.sync=0) / subagent 进程 / 构建卡死 / 网络
- 实践记录: Watchdog 已成功拦截真实违规(章节改名、提交未同步 MEMORY), 规则自检有效
- 上下文 ≥50% 自动 compact: **最佳努力** — session.compact 是 TUI 命令无 HTTP 端点,
  脚本探测 server 失败时仅记录建议(真实限制, 需人工或等上下文满自动压缩)

## Last Updated

2026-08-08
