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

Phase 1A (LaunchCore Foundation) — 完成,59 测试通过,待提交并进入 Phase 1B

## Current Task

Phase 1A 收尾: 提交推送;然后 Phase 1B 一次性 NSCollectionView/120Hz spike

## Current Branch

main

## Last Known Good Commit

f25627f (Phase 0 bootstrap);Phase 1A 提交待创建

## Completed Milestones

- 环境确认: macOS 26.5.2, Xcode 26.6 (17F113), Swift 6.3.3, git 2.50.1, gh 2.96.0
- gh 已登录: zhou1736948757-cpu (repo scope)
- 旧仓库只读分析完成(详见 Docs/PhaseReports/phase-00-bootstrap.md)
- /Users/mac/Projects/LaunchBetter Git 仓库初始化 (git init -b main)
- GitHub 私有仓库创建: github.com/zhou1736948757-cpu/LaunchBetter
- LICENSE (GPL-3.0, 复用旧仓库许可文本) / README / AGENTS.md / .gitignore 已创建
- 模型目录确认: opencode-go/deepseek-v4-flash, glm-5.2, gpt-5.6-luna, qwen3.8-max 全部可用
- Phase 1A 完成: LaunchCore 包 11 源文件 + 9 测试套件 59 测试全部通过,
  release 构建通过,违禁导入(AppKit/SwiftUI/Combine/FileManager/DispatchQueue)扫描 = 0

## Verified Technical Facts

- 旧版四指捏合参数(待 Phase 8 重新验证): 4 指, 阈值 0.18, 冷却 0.2s;三指: 位移 0.005, 容差 0.15, 2 帧确认
- 旧版壁纸: CIGaussianBlur 半径 30, key 后 0.12s 冻结, 背景 alpha = opacity*0.3
- 旧版网格: 默认 7 列, hSpacing 36, vSpacing 28, labelMaxWidth 90, 图标 48/64/80/96
- 旧版热角: 0.05s 轮询, 容差 10pt, 停留 0.3s, 冷却 1s
- 旧版图标磁盘缓存: AppMetadataCache.json + IconSnapshots/<fnv-hash>.png, Info.plist mtime 失效
- 旧版崩溃根因: AppIconResolver.swift:417 main.sync;后台扫描闭包持有 ViewModel;仅 2 个 @MainActor 类;.id(layoutVersion) 整树重建
- 全新 bundle ID: dev.launchbetter.LaunchBetter(开发期稳定 ID,公开发布前需复核)
- 部署目标决策: macOS 14.0 (Sonoma)

## Current Performance Measurements

无(尚无实现,Phase 1B 开始测量)

## Known Issues / Blockers

- 评审模型路由限制: 当前任务工具只能路由 explore/general 子代理,无法路由到
  .opencode/agents 配置的 GLM-5.2/Luna/Qwen。Phase Gate 评审将记录偏差,
  并用最高可用独立子代理替代;若该功能后续可用则恢复文档路由。

## Architecture Changes

- 三包架构: LaunchCore / LaunchPlatform / LaunchUI,依赖方向 Core ← Platform, Core ← UI ← App
- 四运行时管道: A 目录数据 / B UI 结构 / C 图标资源 / D 逐帧交互
- 从旧版确认丢弃: main.sync 路径、每次显示全量扫描、didLaunchApplicationNotification 触发全量扫描、大 Codable UserPreferences 树 + NotificationCenter 同步、CGDisplaySetDisplayMode 改系统刷新率、.id(layoutVersion) 整树重建、AppleLanguages 重启式语言切换
- Phase 1A 决策: AppID/FolderID 纯文本规范化(尾空白/尾斜杠,根路径 "/" 保留),
  解码时规范化并抛错;SearchIndex 固定大小写+变音符不敏感包含匹配、结果按 AppID 排序

## Rejected Approaches

- 放弃旧架构整体迁移(目标即避免旧崩溃类)
- 放弃 bundle ID 复用 com.Eric-Yang.Launchpad-Back
- 放弃 LaunchHistory v0.8 用户数据迁移(旧应用保留为参考)
- 放弃 displayName/自定义名做 AppID(路径身份保持确定性)

## GitHub / Release Status

- 仓库: github.com/zhou1736948757-cpu/LaunchBetter (PRIVATE)
- 计划: 通过 Minimum Usable Release Gate 后转 PUBLIC (已授权), 首个版本 v0.1.0
- 预发布审计清单: secret scan / credential scan / .gitignore / 许可来源 / build+test / README / 历史合理性

## Next Actions

1. 提交并推送 Phase 1A
2. Phase 1B: 一次性 NSCollectionView/120Hz spike(200 placeholder cells、水平分页、
   CALayer 拖拽 overlay、shadow gap、跨页行为),在真实 120Hz 显示器测量
   帧时间/P95/P99/main 线程尖峰;spike 代码不入生产
3. Phase 1C: 基于 spike 结论实现 DisplayModel + LayoutTransaction(纯逻辑)

## Last Updated

2026-08-08
