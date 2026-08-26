# Workflow Plan

> Chief 正式化版本（2026-08-26）。此前为占位（"Pending Initial Chief Planning"）。
> 本计划覆盖已完成任务 T-000~T-016 的语义基线，并正式化当前开发目标 T-017
> （修复 PageCompositor 镜像 bug）及其 follow-up（120Hz 物理验收重开）。

## Objective

当前目标（用户已确认）：**T-017 修复 PageCompositor 镜像 bug** ——
compositor ON 时滑动过程中 app 图标+名字上下镜像（位置不变），停稳恢复。

- 修复必须最小、可验证、不违反 T-013 保护条件。
- 修复必须补齐测试缺口：新增"合成层渲染方向"测试（当前 PageVisualRendererTests
  只断言图像像素，无任何测试渲染合成层验证显示方向）。
- 后续 follow-up（不在本任务）：120Hz 真实设备物理验收重开
  （`MANUAL_PHYSICAL_GATE` 保持 `OPEN / REQUIRED`，待 120Hz 硬件）。

## User Requirements

1. 修复 compositor ON 路径的镜像显示（图标+名字上下颠倒），滑动中与停稳后
   显示方向一致、与 live 路径一致。
2. 修复不得改变位置语义（当前 frame 位置正确，仅方向错误）。
3. 补齐合成层方向测试，防止回归。
4. 现有测试全绿零回归（LaunchUI 470/66、LaunchCore 200/16、
   LaunchPlatform 149/23、GridIntegration 33/33）。
5. 交互验证：用户手动滑动确认无镜像（60Hz 本机，compositor ON 变体）。
6. T-013 保护条件不破坏（见 Critical Invariants）。
7. 不 commit/push/tag/release。

## Non-Goals

- **120Hz 物理验收不在本任务**：本机无 120Hz 显示模式（T-016 §5.3 已核实），
  `MANUAL_PHYSICAL_GATE` 保持 `OPEN / REQUIRED`；重开为 follow-up 任务，
  依赖 120Hz 设备可用。
- **不改 paging 参数**：spring/stiffness/damping/fling 阈值/rubber-band/
  settle 时长/默认 linear 1.3/normalizedDamped 默认/compositor 激活条件/
  100ms prepare debounce/`advanceRealClipBehindCover()` 一律不动。
- **不改 rasterize 坐标系**（方案 C 拒绝，见 Proposed Approach）。
- **不改公开 API**；不新增第二条 offset writer。
- **不做 60Hz→120Hz 推断**；不基于主观感受替代原始证据。
- 不清理 dirty worktree；不删除历史 FAIL 记录；不删除 `Workflow一/` legacy backup。

## Repository Understanding

- LaunchBetter：原生 macOS Launchpad 替代品，Swift 6 严格并发，
  AppKit + Core Animation，macOS 14+，GPL-3.0。
- 分页架构（T-013 基线，已核实）：
  - `PagingInteractionController` 是**唯一 paging 运动写入者**。
  - `PageCompositor` **只做 presentation**：把预渲染 `PageVisual` 摆到正确
    位置，settle 完成/中止时同步真实 NSClipView 再 reveal live。
  - `PageVisualRenderer.rasterize`（PageVisualRenderer.swift:308-326）后台
    光栅化，y-down 页面坐标（translate + scale(1,-1)），图像本身方向正确
    （PageVisualRendererTests.swift:101-107 逐像素断言验证）。
  - `PageVisualCache` 缓存视觉；`GridViewController` 在激活时计算 placement
    （GridViewController.swift:1648-1692）。
- 坐标系事实（T-017 决策关键）：
  - 宿主层 = `view.layer`（GridViewController 的 view，**非 flipped，y-up**）。
  - live 层 = `collectionView.layer`（ClickableCollectionView **flipped，y-down**）。
  - `baseFrame` 由 `collectionView.convert(documentRect, to: view)` 计算
    （GridViewController.swift:1672），且 PageCompositor.swift:104 注释明确
    "baseFrame 为宿主层坐标, y-up"。
  - live 路径 `AppCellView.iconLayer`（AppCellView.swift:44, 656）为**非 flipped**
    CALayer，方向正确。
- 测试：Swift Testing（`@Test`/`#expect`），`swift test --package-path Packages/<pkg>`；
  PageCompositorTests 20 个 @Test（.serialized, @MainActor）。

## Proposed Approach

**方案决策：推荐 A —— 移除 `PageCompositor.swift:191` 的 `layer.isGeometryFlipped = true`。**

决策依据（证据链闭合）：

1. **经验证据一致**：Reviewer 独立实验（`Workflow/evidence/T-016/analysis/calayer-flip-experiment.swift`，
   已编译运行）证明：`isGeometryFlipped = false` → contents 正向；
   `isGeometryFlipped = true` → contents 垂直镜像。live 路径（非 flipped）方向
   正确；bug 现象（仅 compositor ON 镜像）与实验完全吻合。
2. **坐标系事实**：宿主层 y-up、baseFrame 为 y-up 宿主坐标（源码注释 + convert
   计算）。移除 flipped 后子层坐标系与宿主一致（y-up），frame 直接映射，无几何歧义。
3. **最小变更**：一行删除；合成层无子层，无任何代码依赖该层 flipped 几何
   （grep 确认 `isGeometryFlipped` 仅 PageCompositor.swift:191 一处）；
   `layerFramesForDiag` 返回宿主坐标 frame，不受影响。
4. **备选 B（保留 flipped + `contentsTransform = CATransform3DMakeScale(1, -1, 1)`）**：
   双机制叠加（几何 flip + contents 变换）正是本 bug 的"机制叠加"类错误温床；
   flipped=true 时层自身坐标系 y-down 与宿主 y-up 相反，frame 解释隐含翻转，
   维护者极易再次踩坑。**仅当 A 被证明破坏隐藏依赖时作为回退**。
5. **备选 C（rasterize 改 y-up）**：影响所有 rasterize 消费者（渲染器内部绘制、
   PageVisualCache、PageVisualRendererTests 逐像素断言、全库 "y-down 与 flipped
   文档一致" 约定），爆炸半径最大，违反最小变更原则。**拒绝**。

修复后需补**合成层方向测试**（走真实 `PageCompositor.activate` 路径：
非 flipped host + live 层 + `PageVisualRenderer.rasterize` 产物 →
`hostLayer.render(in:)` → 像素断言顶部/底部方向，无镜像）。

## Key Design Decisions

- **D1（方案 A）**：移除 `isGeometryFlipped = true` 为推荐修复；B 为回退，
  C 拒绝。切换方案必须经 Chief（见 Chief-Owned Decisions）。
- **D2（方向测试走真实路径）**：新测试必须经 `PageCompositor.activate` 真实
  激活路径（host 非 flipped + rasterize 产物 + `render(in:)` 像素断言），
  不得只测裸 CALayer 行为；修复前该测试应失败（红蓝颠倒），修复后通过。
- **D3（120Hz follow-up）**：`MANUAL_PHYSICAL_GATE` 保持 `OPEN / REQUIRED`；
  120Hz 物理验收重开为独立 follow-up 任务，依赖 120Hz 设备。
- **D4（不动 rasterize）**：y-down 页面坐标约定是渲染器与测试的既有契约，
  本任务不触碰。
- **D5（测试 seam 复用）**：方向测试复用既有内部 seam
  （`layerFramesForDiag`/`liveLayerOpacityForDiag` 等），不新增公开 API。

## Critical Invariants

T-013 保护条件（T-017 不得违反，逐条绑定）：

- `PagingInteractionController` 保持唯一 paging 运动写入者；不新增第二条
  offset writer。
- `PageCompositor` 仅 presentation；不替换 `PagingSpring`。
- 不改 spring stiffness/damping；不改 fling 阈值；不改 rubber-band；
  不改 settle 时长；默认 linear follow sensitivity 仍 1.3；
  normalizedDamped 仍 opt-in；不改 compositor 激活条件。
- 不改 PageVisual 100ms prepare debounce；不改 gridOrigin/leading offset
  坐标语义；不同步 rasterize PageVisual；不在 gesture start 等待 cache。
- 不改 `advanceRealClipBehindCover()`。
- 不修改搜索、拖拽、Folder、Settings、App Library ownership。
- 不修改公开 API。
- 不以延长动画时间制造 mid-settle 窗口；不以 sleep 掩盖 deterministic 问题；
  不使用 `max(0, count)` 掩盖生命周期错误。
- 不删除历史 Reviewer FAIL；不删除 `Workflow一/` legacy backup。
- 不执行 commit/push/tag/release；不清理 dirty worktree；不触碰无关文件。

## Global Acceptance Criteria

1. **合成层方向测试通过**：新增测试断言 compositor 合成层渲染无镜像
   （输出顶部 == 页面视觉顶部）。
2. **全量回归零失败**：LaunchUI 470/66（+新增测试数）、LaunchCore 200/16、
   LaunchPlatform 149/23、GridIntegration 33/33 全绿，全部命令 exit 0、
   executed > 0。
3. **交互验证**：用户手动滑动确认无镜像（60Hz 本机，compositor ON 变体
   A/C 参数），滑动中与停稳后方向一致。
4. **T-013 保护条件不破坏**：paging 参数、compositor 激活条件、公开 API
   零 diff（除 PageCompositor.swift 的修复行与新增测试文件外）。

## Task Graph

语义依赖（不记录运行时并发）：

```text
T-000..T-015  [PASSED] 工作流/记录基线
      │
      ▼
T-016  [BLOCKED] 真实设备物理验收（60Hz 完成；120Hz 无硬件）
      │  产出：60Hz 数据 + 镜像 bug 根因（Reviewer 独立实验证实）
      ▼
T-017  [本任务] 修复 PageCompositor 镜像 bug
      │  语义依赖：T-016 根因证据（已闭合）、T-013 保护条件（基线）
      ▼
T-018  [follow-up，未创建] 120Hz 物理验收重开
      依赖：120Hz 设备可用 + T-017 修复合入（验收时 compositor 无镜像）
```

- T-017 依赖 T-016 的**根因定位产出**（已由 Reviewer 独立证实，评审 PASS），
  不依赖 T-016 的物理验收完成（BLOCKED 状态不阻塞 T-017）。
- T-017 完成后，`MANUAL_PHYSICAL_GATE` 仍 `OPEN / REQUIRED`。

## Risks / Uncertainties

- **frame 坐标系假设**：方案 A 依赖"baseFrame 为 y-up 宿主坐标 + 非 flipped
  层直接映射"的假设。若假设有误，A 可能引入位置偏移。缓解：方向测试同时断言
  frame 位置（`layerFramesForDiag == baseFrame` 既有测试）+ 交互验证。
- **`render(in:)` 与屏幕渲染一致性**：实验与方向测试均用 `render(in:)`；
  live 路径（非 flipped）屏幕方向正确为佐证。若屏幕渲染与 `render(in:)`
  出现分歧，以交互验证为准并回退 B。
- **回归风险**：全量 4 包回归（470/66 + 200/16 + 149/23 + 33/33）兜底；
  修复行仅 1 行，影响面限于合成层渲染。
- **120Hz 设备依赖**：物理验收 follow-up 持续阻塞，直至 120Hz 硬件可用；
  不得用 60Hz 结果推断 120Hz。
- **contentsGravity/contentsScale 交互**：方向测试用 1x visual 简化；
  2x 路径由既有 rasterize 测试覆盖。

## Main Flexibility

Main 可决定：Worker/Reviewer 调度与串并行、测试命令修正、证据收集、
状态维护、T-017 内部的小型实现适配（保持方案 A 语义不变）。
Main 不得：改变方案（A/B/C 切换）、放宽验收标准、修改 T-013 保护条件、
改变任务目标语义、创建 T-018 或重开物理门。

## Chief-Owned Decisions

- 方案 A/B/C 的选择与切换（含 B 回退触发条件）。
- 验收标准放宽（任何形式）。
- rasterize 坐标系变更（本任务拒绝，未来如需另行决策）。
- 120Hz 物理验收重开时机与 T-018 任务定义。
- 任何 T-013 保护条件的解释或变更。
