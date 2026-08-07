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

Phase 4 (Icon Pipeline) — 完成(提交 5ff991d),142 测试通过,评审修复已落实,进入 Phase 5

## Current Task

Phase 5 持久布局 + 文件夹系统: LayoutStore 应用 LayoutMutation、LayoutSnapshot 持久化、文件夹创建/重命名/解散、墓碑、重启持久性

## Current Branch

main

## Last Known Good Commit

5ff991d (Phase 4)

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

- 仓库: github.com/zhou1736948757-cpu/LaunchBetter (PRIVATE)
- 计划: 通过 Minimum Usable Release Gate 后转 PUBLIC (已授权), 首个版本 v0.1.0
- 预发布审计清单: secret scan / credential scan / .gitignore / 许可来源 / build+test / README / 历史合理性

## Next Actions

1. 提交并推送 Phase 4 (图标管道 + 评审修复)
2. Phase 5: 持久布局 + 文件夹系统(LayoutStore 应用 LayoutMutation、
   LayoutSnapshot 持久化、文件夹创建/重命名/解散、墓碑、重启持久性)
3. Phase 6: 拖拽引擎

## Last Updated

2026-08-08
