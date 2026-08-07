# LaunchBetter

原生 macOS Launchpad 替代品。Swift 6 严格并发、AppKit + Core Animation、120Hz-ready。

## 项目定位

- **模块架构**: LaunchCore(纯逻辑)/ LaunchPlatform(平台边界)/ LaunchUI(AppKit UI) 三个本地 Swift 包
- **核心能力**: 分页网格启动器、搜索、文件夹、拖拽重排、持久化布局、四指捏合激活、全局热键
- **性能目标**: 热启动显示 < 100ms、120Hz 帧预算 8.33ms、快照加载 < 10ms
- **许可**: GPL-3.0(源自 LaunchHistory / EricYang801/Launchpad_Back,见 LICENSE)

## 构建

要求: Xcode 26+ / Swift 6.3+, macOS 14+。

```bash
# LaunchCore 纯逻辑包测试
cd Packages/LaunchCore && swift test

# 完整工程(Xcode 工程自 Phase 1B 起逐步搭建)
open LaunchBetter.xcodeproj
```

## 目录结构

```
LaunchBetter/
├── AGENTS.md          # 代理工程规则
├── MEMORY.md          # 已验证的项目状态
├── Docs/
│   ├── Architecture/  # 架构决策记录
│   └── PhaseReports/  # 阶段报告
├── LaunchBetterApp/   # 应用 target(Phase 3+)
└── Packages/
    ├── LaunchCore/    # 纯 Swift 核心模型(无 AppKit/文件系统)
    ├── LaunchPlatform/# 平台边界(文件系统/图标/手势)
    └── LaunchUI/      # AppKit 启动器 UI
```

## 状态

见 `Docs/PhaseReports/` 与 `MEMORY.md` 获取当前进度。

## 归属

基于 EricYang801/Launchpad_Back(GPL-3.0) 的产品验证经验重建,架构全新设计。
