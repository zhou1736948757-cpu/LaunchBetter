# 任务包 A2+A3+A4: Drag hot-path 消除冗余 + 单一 hit-test + snapshot index cache

## 背景
LaunchBetter v0.2.3(Prompt Stage A §A2/A3/A4)。DragController(1050 行, Codex 阶段重写)热路径存在可消除的重复工作:
- §A2: `processTick` 每帧调用 `grid?.setDragSourceHidden(true, for: item)`(DragController.swift:573)。
  若 identity-owned source state + configure/reuse 重应用已保证视觉所有权, 该每帧重设是冗余。
- §A3: 同一帧 `processTick` 内至少 2 次 hit-test: `hoveredFolder(at:)`(594)与
  `updateCreateFolderTarget` 内部 `itemAt(point:)`(716)。可合并为单次 DragHitTarget 分类。
- §A4: `flatIndex(of:)`/`indexPath(atFlatIndex:)`(GridViewController.swift:676/691)每次构造
  dataSource.snapshot()(O(N))。拖拽中重复调用是否构成有意义开销需测量判断。

## 允许修改的文件(禁止范围外)
- Packages/LaunchUI/Sources/LaunchUI/DragController.swift
- Packages/LaunchUI/Sources/LaunchUI/GridViewController.swift
- 如需纯逻辑(如 DragHitTarget / snapshot index cache 类型), 放 Packages/LaunchUI/Sources/LaunchUI/
  (本项目 UI 测试 target 已存在, 可加对应测试)
- 对应测试: Packages/LaunchUI/Tests/LaunchUITests/ 或 Packages/LaunchCore/Tests(仅当纯逻辑放 Core)

## 约束
- 不改变产品交互行为(优化前后 UX 必须一致)
- 单一写者: 只改上述文件
- 每帧状态不进 LauncherStore
- 不新增 main.sync

## 实现要求

### A2(优先)
1. 先审计: AppCellView/GridViewController 是否已有"源项隐藏由 identity-owned 状态 + configure/reuse 重应用"保证。
   - 若已保证 → 移除 processTick 每帧 setDragSourceHidden
   - 若跨页进入可视区会丢隐藏 → 在 source identity 变化点(如 configure/复用)重应用隐藏, 而非每帧
2. 保留 beginDrag 时的初次隐藏与 cancel/drop 恢复语义
3. 必写测试(现有 LaunchUI 测试框架): 源隐藏立即生效 / 复用保持隐藏 / 跨页保持隐藏 /
   无重复源 / cancel 恢复 / drop 恢复 / 陈旧 completion 不影响新 session

### A3
1. 引入单次语义分类(建议 DragHitTarget: .none/.app(AppID)/.folder(FolderID))
2. processTick 每帧**一次** hit-test, 由分类推导 folder target / App→App create-folder / reorder 路径
3. 保持: 源 App 不能以自身为目标; folder 优先; dwell 保留; 插入指示器保留
4. 测试: 同帧一次 hit-test(计数器); 各分类推导正确

### A4(测量优先)
1. 审计拖拽路径中 flatIndex/indexPath 调用次数与每次 snapshot 开销
2. 若明确重复 → 实现 O(1) 映射缓存(identity→flat, flat→IndexPath), 在
   catalog/layout/search/folder/geometry 变化(即 snapshot 应用点)失效
3. 若测量显示开销可忽略 → 报告 "measured, optimization deferred" 并给出依据
4. 若实现缓存: 测试缓存结果 == 实际 Diffable snapshot; 各失效点正确

## 验收标准
1. DragController.swift:573 的每帧 setDragSourceHidden 已消除(或给出证据证明其必要)
2. processTick 一帧一次 hit-test(可验证计数器或代码结构)
3. A4: 实现或明确 defer(附测量依据)
4. 既有 LaunchUI 测试 + 新增测试全绿
5. xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter build 成功
6. 拖拽 UX 无回退

## 禁止
- 不修改 /Users/mac/Projects/Launchpad_Back
- 不提交 git、不切换分支
- 不引入新依赖
- 不改 DragController 之外的业务逻辑(LauncherStore/LayoutStore/Catalog 等)

## 输出要求
改动文件清单 / 技术假设清单 / build+test 结果 / A4 测量依据 / 与任务包偏差 / 未决问题; 每步 [PROGRESS]
