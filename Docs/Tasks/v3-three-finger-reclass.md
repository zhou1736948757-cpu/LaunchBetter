# 任务包: V3 — 三指拖 App 到分类卡(重分类)

## 背景
用户要求: 三指拖 App → 放到另一个分类卡 → 改其分类(重分类)。复用现有 `AppLibraryCategoryOverriding`(categoryOverrides/setCategoryOverride/clearCategoryOverride),绝不进 LayoutStore。当前三指路由仅允许 `.launcher`。

## 允许修改
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryReclassificationDragController.swift`(新增)
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryViewController.swift`(源命中 + hover + 覆盖命令 + 拖拽期暂停滚动/翻页)
- `Packages/LaunchUI/Sources/LaunchUI/AppLibraryCardCell.swift`(仅 hover 高亮 seam/命中辅助,若需要)
- `Packages/LaunchUI/Sources/LaunchUI/LauncherWindowController.swift`(三指路由: .appLibrary → 重分类拖拽; .settings/.appLibraryCategory → 阻塞; .folder → 既有; .launcher → 既有 DragController)
- `Packages/LaunchUI/Sources/LaunchUI/LauncherInteractionOwnership.swift`(如需要状态说明)
- `Packages/LaunchUI/Sources/LaunchUI/LauncherStoring.swift`(协议只读,如需要)
- 相关测试
- 禁止改 LayoutStore/LayoutSnapshot/DragController 结构逻辑、提交、改 Launchpad_Back。

## 规格
1. **路由**(A11): `threeFingerDragBegin` 按 interactionSurface 分派:
   - `.launcher` → 既有结构拖拽(不变)
   - `.appLibrary` → Library 重分类拖拽
   - `.settings` → 阻塞
   - `.folder` → 既有行为不变
   - `.appLibraryCategory` → 阻塞(本阶段不支持)
2. **源命中**(A13): 指针所在 Library 可见 App 图标;仅 **large primary 图标** 可作为源(本阶段);mini 簇暂不作为源(文档说明延迟);card 背景/标题/空白/页面空白不启动。
3. **拖拽 owner**(A12): 新建小型 `AppLibraryReclassificationDragController`,职责仅: 源身份 + 源视觉(复用已渲染图标/内存占位,禁止拖拽起点磁盘/Info.plist/图标请求)+ 指针跟踪 + 目标分类卡 + hover 高亮 + drop/cancel + 覆盖命令。不引入第二个 mega DragController;不复用 LayoutStore 重排/建夹/页槽。
4. **目标**(A15): 仅普通分类卡(Suggestions/Recently Added/页面空白/搜索/设置 无效);拖到当前生效分类 → no-op 恢复视觉;拖到空白 → cancel 无变更;drop 外部 → cancel。
5. **drop 语义**(A16/A17): 有效目标 → `setCategoryOverride(appID, target)` → 热刷新(updateModel);当前 Library surface 保持;不重扫;不动 LayoutStore;被拖 app 立即可见于目标分类(且因 V2 手动置顶规则排最前)。
6. **高亮**(A18): 悬停有效分类卡 → MotionTokens 约束的轻微 scale/border 强调;离开即时恢复;无大弹跳/常亮。
7. **拖拽期暂停**(A19): 拖拽激活时暂停 Library 垂直滚动与 Library↔Page1 水平翻页;drop/cancel 后恢复。
8. **不跨面**(A20): 本阶段只做分类↔分类,不做 Library→Page1 或 Page1→Library。
9. `--` 三指重分类诊断探针可选: `--libraryreclassprobe`(合成三指 + 指针到卡片,断言覆盖保存)。

## 必写测试(A21)
- .appLibrary + 指针在大图标 → begin 重分类
- .launcher → 既有 DragController 不变
- .settings → 阻塞;.appLibraryCategory → 阻塞;.folder → 既有不变
- 有效分类 hover → 高亮
- drop Social → override 保存
- 同分类 drop → no-op
- drop 空白 → cancel 无变更
- cancel → 无变更
- 拖拽激活 → Library 垂直滚动阻塞
- 拖拽激活 → Library 水平翻页阻塞
- end → 两者恢复
- 无 LayoutStore 变更断言

## 验收
1. LaunchUI 全绿(记录数字),Debug build OK。
2. 报告: 路由、源命中、overlay、目标、持久化、无 LayoutStore 证明、滚动/翻页挂起。
