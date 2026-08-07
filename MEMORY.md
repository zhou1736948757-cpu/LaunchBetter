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

Phase 0 (Bootstrap / Legacy Analysis) — 完成,准备提交并进入 Phase 1A

## Current Task

Phase 0 收尾: 项目文件创建完毕,待提交推送;然后 Phase 1A LaunchCore 基础类型

## Current Branch

main

## Last Known Good Commit

无(仓库刚初始化,尚无提交)

## Completed Milestones

- 环境确认: macOS 26.5.2, Xcode 26.6 (17F113), Swift 6.3.3, git 2.50.1, gh 2.96.0
- gh 已登录: zhou1736948757-cpu (repo scope)
- 旧仓库只读分析完成(详见 Docs/PhaseReports/phase-00-bootstrap.md)
- /Users/mac/Projects/LaunchBetter Git 仓库初始化 (git init -b main)
- GitHub 私有仓库创建: github.com/zhou1736948757-cpu/LaunchBetter
- LICENSE (GPL-3.0, 复用旧仓库许可文本) / README / AGENTS.md / .gitignore 已创建
- 模型目录确认: opencode-go/deepseek-v4-flash, glm-5.2, gpt-5.6-luna, qwen3.8-max 全部可用

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

无

## Architecture Changes

- 三包架构: LaunchCore / LaunchPlatform / LaunchUI,依赖方向 Core ← Platform, Core ← UI ← App
- 四运行时管道: A 目录数据 / B UI 结构 / C 图标资源 / D 逐帧交互
- 从旧版确认丢弃: main.sync 路径、每次显示全量扫描、didLaunchApplicationNotification 触发全量扫描、大 Codable UserPreferences 树 + NotificationCenter 同步、CGDisplaySetDisplayMode 改系统刷新率、.id(layoutVersion) 整树重建、AppleLanguages 重启式语言切换

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

1. 创建 .opencode/agents (implementer/reviewer/visual-reviewer/arbiter) 与 compaction 插件
2. 创建 Docs/Architecture/0001-module-boundaries.md 与 Phase 0 报告
3. 首次 commit + push main
4. Phase 1A: LaunchCore 基础类型 (AppID/AppRecord/FolderID/FolderRecord/LayoutItem/CatalogSnapshot/CatalogDelta/IconContentVersion/IconKey/AppConfiguration/HotkeyConfig/HotCornerConfig/SearchIndex/LayoutSnapshot/MissingAppState/basic LayoutReconciler) + swift-testing 测试, 0 AppKit/0 SwiftUI/0 Combine/0 FileManager

## Last Updated

2026-08-08
