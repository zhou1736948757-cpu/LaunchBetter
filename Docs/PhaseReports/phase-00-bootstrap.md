# Phase 0 — Bootstrap / Legacy Analysis

## Scope

环境确认、旧仓库只读分析、新仓库初始化、GitHub 私有仓库创建、工程脚手架、模型路由确认。

## Implementation Summary

- 确认环境: macOS 26.5.2、Xcode 26.6 (17F113)、Swift 6.3.3 (arm64)、git 2.50.1、
  gh 2.96.0(登录 zhou1736948757-cpu,scope: repo/workflow/gist)
- 只读分析旧仓库(explore agent): 提取已验证行为与失败类(见下)
- `git init -b main` + 创建私有 GitHub 仓库 + origin
- 创建 LICENSE(GPL-3.0,复用旧仓库许可文本)、README、AGENTS.md、MEMORY.md、
  .gitignore、opencode.json、.opencode/agents/{implementer,reviewer,visual-reviewer,arbiter}.md、
  .opencode/plugins/memory-compaction.ts、Docs/Architecture/0001-module-boundaries.md
- 模型目录确认(opencode 1.18.10 `opencode models`):
  deepseek-v4-flash / glm-5.2 / gpt-5.6-luna / qwen3.8-max 全部可用。
  本版本无 reasoning variant 选择命令,按文档 §12 记录此偏差: 各模型用默认推理级别,
  视觉降级链为 Luna → Qwen3.8 Max → 确定性布局测试 + 截图存档。

## Legacy Analysis Highlights(证据见旧仓库源码)

已验证可迁移行为:
- 四指捏合: 4 指、阈值 0.18、冷却 0.2s;三指: 位移 0.005、容差 0.15、2 帧确认
  (MultitouchGestureRecognizer.swift:140-172)
- 壁纸: CIGaussianBlur 半径 30、key 后 0.12s 冻结、背景 alpha=opacity*0.3
- NSPanel 拖拽 overlay(60pt 图标 + 11pt label, ignoresMouseEvents)
- 热角: 0.05s 轮询、容差 10pt、停留 0.3s、冷却 1s
- 网格参数: 默认 7 列、hSpacing 36、vSpacing 28、labelMaxWidth 90
- 图标磁盘: AppMetadataCache.json + IconSnapshots/<fnv>.png, Info.plist mtime 失效
- 窗口: canBecomeKey/Main=true, borderless + screenSaver level

确认失败类(必须避免):
- DispatchQueue.main.sync(AppIconResolver.swift:417)
- 后台扫描闭包持有 ViewModel,后台 deinit 触发隔离断言
- 全工程仅 2 个 @MainActor 类
- 每次显示面板 → 全量 loadInstalledApps;didLaunchApplicationNotification → 全量扫描
- .id(layoutVersion) 整树重建;getIcon 主线程同步解析
- DisplayManager 调用 CGDisplaySetDisplayMode 全局改系统刷新率
- 大 Codable UserPreferences + NotificationCenter 同步;AppleLanguages 需重启的语言切换

## Important Files

- AGENTS.md / MEMORY.md / README.md / LICENSE / opencode.json
- .opencode/agents/*.md, .opencode/plugins/memory-compaction.ts
- Docs/Architecture/0001-module-boundaries.md

## Tests

无代码。代理配置语法经 opencode 1.18.10 schema(自定义 skill)核对。

## Build Results

无代码构建。gh repo create 一次网络失败后重试成功。

## Performance Results

无。

## Review Results

无独立评审(Phase 0 为脚手架,无生产代码)。决策均依据文档 §134 步骤与旧仓库证据。

## Architecture Deviations

- 文档假设存在 `/variants` 命令: opencode 1.18.10 无此命令,`opencode models` 为准;
  记录于 MEMORY,模型路由偏差已注明
- Bundle ID: 选择 `dev.launchbetter.LaunchBetter`(开发稳定 ID),公开发布前复核,
  一旦 Input Monitoring/TCC 测试开始则不再更改
- 部署目标: macOS 14.0

## Known Limitations

- 尚未创建 Xcode 工程(Phase 1B 起,与 spike 一起)
- 尚未验证 gh push 权限(end-to-end 推送在首次 commit 后验证)

## Commit Range

待首次提交(TBD)

## Remaining Risks

- 网络抖动影响 gh push(已遇一次)
- 模型配额/推理级别不可精确控制,可能影响评审深度

## Next

Phase 1A — LaunchCore Foundation(AppID/AppRecord/Folder/Layout/Catalog/Icon/SearchIndex/Config
基础类型 + LayoutReconciler + swift-testing,零平台依赖)。
