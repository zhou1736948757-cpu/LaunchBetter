# Phase 1C — Layout Model Finalization

## Scope

基于 Phase 1B spike 结论,实现 LaunchCore 布局显示与拖拽事务模型(纯逻辑,无 AppKit)。

## Implementation Summary

### DisplayModel(显示空间派生)
从 Catalog + Layout + Configuration 派生实际分页 UI 结构:
- 隐藏应用与缺失应用(墓碑)从显示过滤(显示过滤器,不从 Catalog/Layout 删除)
- 文件夹显示可见子项;无可见子项 → 从显示隐藏(布局保留,解散由对账器决定)
- 过滤后空页丢弃;不存在的文件夹项跳过
- pageCapacity = gridColumns × gridRows(为此 AppConfiguration 增加 gridRows,默认 6,
  解码缺字段回退,前向兼容,schemaVersion 保持 1)

### LayoutTransaction(阴影布局事务)
- `preview`: 源项移除后的槽位列表 + gapIndex + sourceIndex + displacedCount(UI 以
  CALayer 变换呈现,不做结构更新)
- `drop`: 同页/跨页重排,目标槽位确定性 clamp,按 pageCapacity 重分块,
  输出新 DisplayModel + LayoutMutation + changedPages
- `moveIntoFolder` / `moveOutOfFolder`: 文件夹成员变更,空文件夹从显示隐藏
- LayoutMutation(enum): reorder / addToFolder / moveOutOfFolder,由 Phase 5
  LayoutStore 应用;事务本身不触碰布局存储
- 所有索引在显示空间进行(已过滤隐藏/缺失),操作确定性、可测试

## Important Files

- Packages/LaunchCore/Sources/LaunchCore/DisplayModel.swift
- Packages/LaunchCore/Sources/LaunchCore/LayoutTransaction.swift
- Packages/LaunchCore/Sources/LaunchCore/Configuration.swift(新增 gridRows)
- Packages/LaunchCore/Tests/LaunchCoreTests/DisplayModelTests.swift
- Packages/LaunchCore/Tests/LaunchCoreTests/LayoutTransactionTests.swift

## Tests

81 个测试全部通过(11 套件,新增 22 个):
- DisplayModel: 隐藏/缺失过滤、文件夹子项过滤、空文件夹隐藏、空页丢弃、
  pageCapacity、visibleAppIDs
- LayoutTransaction: 同页/跨页 preview 与 drop、clamp、no-op drop、确定性、
  文件夹整体拖拽、拖入/拖出、越界 clamp、非法操作 nil

## Build Results

- `swift test`: 81/81 通过
- `swift build -c release`: 通过
- 违禁导入: 0

## Performance Results

无(纯逻辑模型,无运行时管道)。spike 结论指导: 拖拽期间仅 layer 变换,
drop 时一次结构更新(本 Phase 的 DropResult 即该结构事件)。

## Review Results

自查评审 + 测试驱动修订:
- DisplayModel 派生规则与文档 §55(缺失隐藏)、隐藏过滤语义逐条对齐
- LayoutTransaction 操作全部返回 nil 而非隐式失败,便于 UI 层安全处理
- no-op drop(原位置)返回 changedPages 空集,UI 可跳过更新

GLM 独立评审限制同前(工具无法路由到 GLM),记录于 MEMORY。

## Architecture Deviations

- DisplayModel 页面结构按布局原样保留(不重新分块);拖拽 drop 时按 pageCapacity
  归一化分页。已记录: LayoutStore(Phase 5)应保证布局页恒不超过容量。
- 显示空间索引 → 布局存储映射(LayoutMutation 应用)推迟到 Phase 5 实现,
  本 Phase 提供确定性变更描述作为契约。

## Known Limitations

- 文件夹"展开视图"内的拖拽(open folder 状态下子项间移动)未建模,
  由 Phase 6 Drag Engine 结合 UI 处理
- 边缘自动翻页(拖到屏幕边缘换页)属 Phase 6 交互层

## Commit Range

TBD(Phase 1C 提交)

## Remaining Risks

- 无。

## Next

Phase 2 — App Catalog + Persistent State:
PathCanonicalizer / AppDiscoveryService / AppCatalogActor / CatalogSnapshotStore /
ReconcileEngine / SettingsStore / StateMigration 基础(LaunchPlatform 包)。
启动策略: 进程启动后台全量对账一次 + 用户显式刷新;Launcher 显示永不全量扫描。
