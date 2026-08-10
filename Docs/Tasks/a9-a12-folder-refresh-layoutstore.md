# 任务包 A9+A12: Folder refresh 去 reloadData + LayoutStore 去假 DisplayModel

## 背景
LaunchBetter v0.2.3(Prompt Stage A §A9/A12)。
- §A9: FolderViewController.refresh(284)执行 Diffable 快照后 `collectionView.reloadData()`(301),
  可能重建/重配置可见 cell、重启图标任务、抵消 Diffable 效率。
- §A12: LayoutStore.renameFolder(127)用 `currentDisplayPlaceholder()`(142:
  DisplayModel(pages: [], pageCapacity: 42) 造假 DisplayModel)仅因 LayoutEditor.apply 需要,
  重命名本应是纯持久化状态变更。

## 允许修改的文件(禁止范围外)
- Packages/LaunchUI/Sources/LaunchUI/FolderViewController.swift
- Packages/LaunchPlatform/Sources/LaunchPlatform/LayoutStore.swift
- Packages/LaunchCore/Sources/LaunchCore/LayoutEditor.swift(如需窄 API)
- 测试: Packages/LaunchUI/Tests/LaunchUITests/ + Packages/LaunchPlatform/Tests/LaunchPlatformTests/ + Packages/LaunchCore/Tests/LaunchCoreTests/

## 实现要求

### A9 Folder refresh
1. 审计 refresh() 调用点与触发原因(结构变化 vs 元数据/本地化变化)
2. 分离"结构更新"与"元数据/本地化重配置":
   - 结构变化 → Diffable apply(保留)
   - 仅元数据/本地化 → 只重配置可见 cell(不 reloadData, 不重启图标任务)
3. 使用最小正确 AppKit 操作
4. 验证: 重排/增删子项/重命名/本地化/图标更新/missing-hidden 均无 stale UI

### A12 LayoutStore rename
1. 移除 currentDisplayPlaceholder() 假 DisplayModel 依赖
2. 重命名走窄纯 API(不要求显示几何)
   - 若 LayoutEditor.apply 需要 DisplayModel 参数, 提供/改用不依赖几何的窄 API
   - 或 LayoutStore 直接持久化改名(重命名不影响布局结构)
3. 保持持久化 + 失败保留旧文件语义

## 约束
- 不改文件夹业务逻辑/交互行为
- 每帧状态不进 Store; 不新增 main.sync
- 单一写者: 只改上述文件

## 验收标准
1. FolderViewController.refresh 不再无条件 reloadData(结构变化才 Diffable; 元数据只重配置可见 cell)
2. LayoutStore.renameFolder 不再构造假 DisplayModel
3. 相关测试全绿(含新增)
4. xcodebuild build 成功
5. 文件夹 UI 无回退(重排/改名/本地化/增删/图标)

## 必写测试
- A9: refresh 后可见 cell 不被无谓重建(计数器或结构断言); 重命名/本地化更新仍生效; 增删子项结构正确
- A12: renameFolder 持久化成功/失败保留旧文件; 无显示几何依赖
- 回归: 文件夹重排/拖出/解散既有测试

## 禁止
- 不修改 /Users/mac/Projects/Launchpad_Back
- 不提交 git、不切换分支
- 不引入新依赖

## 输出要求
改动文件清单 / 技术假设清单 / build+test 结果 / 与任务包偏差 / 未决问题; 每步 [PROGRESS]
