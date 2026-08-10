# 任务包 B2: 自定义应用源目录 — 运行时端到端生效

## 背景
LaunchBetter v0.2.3。customSourceDirectories 已持久化 + 设置 UI 有加/删(Partial)。
但运行时接线缺失: DependencyContainer 启动时一次性建 AppCatalogActor(sources)与
DirectoryMonitor(scopes), 设置里改源后保存不触发目录重扫/monitor 更新。
Stage B §B2 补端到端。

## 允许修改的文件(禁止范围外)
- Packages/LaunchPlatform/Sources/LaunchPlatform/AppCatalogActor.swift(源集合动态化/重扫新源)
- Packages/LaunchPlatform/Sources/LaunchPlatform/DirectoryMonitor.swift(动态 scope 重配)
- Packages/LaunchPlatform/Sources/LaunchPlatform/Stores.swift(如需)
- LaunchBetterApp/DependencyContainer.swift(接线: 源变更 → catalog/monitor 更新)
- LaunchBetterApp/LauncherStore.swift(如需暴露源变更事件)
- 对应测试: LaunchPlatformTests + (App 层运行时探针如需)

## 需求(端到端)
1. 设置 UI 添加/移除源 → 持久化(已有) → 运行时生效:
   - AppCatalogActor 更新源集合并扫描新增目录(增量, 不覆盖更新目录状态)
   - DirectoryMonitor 动态更新监控根(新增/移除源目录)
2. 规范化路径; 去重: 与默认源去重、自定义源互相去重(重叠不产生重复 AppID)
3. 无效/缺失目录优雅处理(不崩溃, 记录); 移除源正确对账(该源应用移除, 布局墓碑/保留语义按现有规则)
4. 不在 launcher show 时全量扫描; 不产生重复 AppID
5. 生命周期: monitor/catalog 重配安全(无 stale callback, 干净 shutdown)

## 约束
- 高风验 lifecycle 变更: 保留 actor generation 防陈旧、durable-before-publish
- 不改默认源扫描语义; 不新增 main.sync
- 与现有 FSEvents 恢复/对账兼容

## 验收
- 添加源(测试 fixture 临时目录)后应用出现且可搜索; monitor 监控新目录(改动即时反映)
- 移除源后应用消失, 无重复 AppID
- 无效/缺失源不崩溃
- 全测试绿; build 成功; 不引入 per-show 全量扫描

## 命令纪律(硬性)
bash 每条单命令, 严禁 2>&1 | && ;、rg、rm 外部目录。搜索用 grep 工具, 读用 read 工具。
验证: swift test / xcodebuild build。

## 禁止
不提交 git; 不切换分支; 不改 Launchpad_Back; 不改 B2 范围外文件

## 输出
改动文件清单/假设/测试结果/偏差/未决; 每步 [PROGRESS]
