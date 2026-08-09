# AGENTS.md — LaunchBetter 工程规则

本文件回答:代理必须如何在 LaunchBetter 上工作。改动需谨慎,保持相对稳定。

## 项目本质

原生 macOS Launchpad 替代品。Swift 6 严格并发,AppKit + Core Animation。
性能与架构正确性优先于功能数量。

## 构建与测试命令

```bash
# LaunchCore 包测试(Phase 1A 起)
cd Packages/LaunchCore && swift test

# 完整工程(Phase 1B 起)
xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter build
xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter test
```

## 不可协商的架构决策(违反即 Major Decision Gate)

- AppID = 规范化应用路径(禁止生成 UUID 代替;禁止 ExpressibleByStringLiteral)
- Catalog / Layout / Config 三分离,禁止 AppItem 大对象合并责任
- 四运行时管道(A 目录数据 / B UI 结构 / C 图标资源 / D 逐帧交互)不得坍缩为单一 Observable 状态图
- LaunchCore 禁止 AppKit / SwiftUI / Combine / FileManager
- 全仓库 `DispatchQueue.main.sync` 数量 = 0
- 持久化用户数据 ≠ 缓存;持久数据在 `~/Library/Application Support/`,可再生缓存在 `~/Library/Caches/`
- 启动器显示、普通应用启动 → 0 次目录扫描 / 0 次 Info.plist IO / 0 次图标重扫
- 每帧状态(拖拽位置/动画进度)不得进入 LauncherStore,只走 GestureSampleBuffer → FrameCoordinator → CALayer
- 每个持久化格式必须带 schemaVersion,面向迁移设计
- 墓碑(Tombstone)默认宽限期 30 天,应用更新期间不得销毁布局
- deinit 中禁止重要生命周期工作(IO/actor 跳转/业务变更);用显式 start()/shutdown()

## 禁用的工程模式

- DispatchQueue.main.sync
- AppRecord 持有 NSImage / NSView / CALayer / 页面号 / 选中态 / 拖拽态
- Catalog 持有 Layout;Layout 持有 AppRecord 对象
- 后台任务持有 LauncherStore / WindowController / NSView
- 图标单次完成触发整表重建、整数组重建或目录重扫
- 全核心管理器做成全局单例
- 未检查的 `@unchecked Sendable` 仅用于消除编译警告
- 用 SwiftUI 巨型网格承载高频性能关键表面(主网格用 NSCollectionView)
- 每拖拽帧应用 Diffable snapshot
- 图标磁盘缓存仅以 AppID 哈希命名
- 持久化图标版本用 reconcile 代数代替真实内容信号

## 避免过度工程

- NSCollectionView 被测量否定前,禁止自建全 CALayer 网格
- 不为假想速度写不安全代码
- 不为"听起来现代"批量创建 actor
- 不建无具体用途的抽象层
- 不引入尚未证明需要的依赖(Sparkle 等 Phase 10 再评估)

## 阶段收尾规则

- 每个大阶段完成后: 删除旧版本 App 构建(仅保留最新, 含 DerivedData 旧构建清理),
  /Applications/LaunchBetter.app 覆盖为最新; 推送 GitHub 分支

## Git 纪律

- 原子提交;正常实现单元 = 测试/构建 → 评审 → commit
- 分支约定: `main` + `phase/XX-*`;Phase Gate 后合并 main 并推送
- 禁止: force push、重写已发布历史、未授权重置用户工作、删除含未合并工作的分支
- 提交信息简明描述变更

## 模型路由(用户指令,2026-08-10 更新)

- **总控(主对话)**: opencode-go/deepseek-v4-flash —— 阶段规划、任务打包、调度评审、
  验证收口、Git 提交、MEMORY 维护。
  **总控不直接写生产代码** —— 实现一律交独立 implementer 窗口(防上下文污染)。
- **实现(独立 subagent)**: opencode-go/deepseek-v4-flash **variant: max**(Max 思考深度)。
  运行方式: `opencode run -m opencode-go/deepseek-v4-flash "<任务包指令>"` 起独立窗口,
  与主对话**完全隔离上下文**。任务包在 `Docs/Tasks/<name>.md`(模板见 implementer.md);
  implementer 返回(改动清单/假设清单/测试结果/偏差/进度 `[PROGRESS]`);
  总控收到后必须独立验证(build/测试/探针),不盲信。
  **主对话禁止在同一会话里改生产文件**;只有总控的验证/提交/评审属例外。
- **方案门 + 阶段评审**: opencode-go/gpt-5.6-luna (variant: max),经 `.opencode/agents/reviewer.md`
  独立窗口 —— 高风险任务(几何/手势/并发/性能)动手前先评审执行计划;阶段末评审
  0 BLOCKER 0 MAJOR 才能完成
- **视觉评审**: opencode-go/mimo-v2.5,经 `.opencode/agents/visual-reviewer.md` —— 仅截图证据场景;
  视觉结论必须经像素级验证后采纳(该项目 4 次误报记录)
- **仲裁**: opencode-go/qwen3.8-max —— Flash 与 Luna 分歧、疑难调试,慎用

## 超长 Prompt 处理协议

收到超长/多阶段任务 Prompt 时,总控必须先做以下步骤再动手(防遗忘/防幻觉):

1. **解析并回读**: 提取"目标 / 禁止项 / 完成条件 / 关键数值 / 验收 gate",输出一份
   结构化关键约束清单,**请用户确认后再执行**(用户确认或回复"执行"即放行)
2. **拆 todo**: 每个可验证单元一条;完成条件逐项对应 §XX
3. **外部化**: 关键约束/禁止项/数值写入 `Docs/Tasks/<name>.md` 或 MEMORY,不依赖模型记忆
4. **逐项验收**: 阶段结束按完成条件清单逐条核对并输出,对照原文
5. 若用户不确认,默认只做探索/只读分析,不动生产代码

## 单一写者规则

架构关键阶段同一时刻只有一个可写代理在改重叠生产文件。只读代理(explore/review)可并发。

## Major Decision Gate(停下问用户)

产品级行为改变、架构契约破坏且无等价安全方案、数据丢失、修改旧仓库
`/Users/mac/Projects/Launchpad_Back`、许可不确定性、破坏性 Git、疑似泄露凭据、
Apple 签名/公证凭据缺失、已有无关的非空 `<user>/LaunchBetter` 仓库、不可约阻塞。

## MEMORY 规则

- 只写已验证事实(测试通过/构建成功/实测数据/commit SHA),禁止 maybe/大概/感觉
- 每次压缩上下文后、新阶段开始前、长任务子代理返回后重读 MEMORY.md
- 冲突时优先级: 当前源码 > 自动化测试 > 可复现运行时行为 > 测量 > Git 历史 >
  文档 > MEMORY.md > 阶段报告 > 本主提示 > 代理假设
- 压缩后必须先重读 MEMORY.md + git status + git log 再写操作

## 旧仓库(只读参考)

`/Users/mac/Projects/Launchpad_Back` 是只读参考。禁止 edit/write/delete/reset/
checkout/stash/commit/push/rebase/clean。只允许读取。迁移旧代码必须: 检查依赖 →
只提取必要行为 → 按新模块边界重写 → 加测试 → 禁止整子系统搬运。
