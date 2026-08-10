# 任务包 C5 修复 M2/M3: 自定义来源 generation 一致性(Luna MAJOR)

## 背景
Luna C5 并发评审发现(真实, B2 引入):
- M2: DirectoryMonitor.stop() 只取消 debounce, 不清空 pendingScopes/pendingAppRoots/pendingEventLoss;
  移除 source 后新事件会把旧 source 路径一起交付, AppCatalogActor.reconcileScope 不校验当前 source
  → 幽灵应用/布局错误
- M3: AppCatalogActor.performUpdateSources 在 delta.isEmpty 时更新 sources 后直接返回不递增
  generation; 并发 full scan 只校验 generation 不校验 source 集合, 旧源扫描可在重配后提交

## 允许修改的文件(禁止范围外)
- Packages/LaunchPlatform/Sources/LaunchPlatform/DirectoryMonitor.swift(generation 化 pending; 重配丢弃旧 gen)
- Packages/LaunchPlatform/Sources/LaunchPlatform/AppCatalogActor.swift(sourceGeneration 或提交前校验 sources==captured)
- 测试: Packages/LaunchPlatform/Tests/LaunchPlatformTests/(M2/M3 复现测试)

## 要求
1. M2: DirectoryMonitor 为 stream/摘要引入 generation; 重配/stop 丢弃旧 generation 的
   pendingScopes/pendingAppRoots/pendingEventLoss; 禁止对非当前 source 执行 scope reconcile
2. M3: performUpdateSources 每次更新 sources 递增独立 sourceGeneration(或提交时校验
   captured source 集合); full scan 提交前校验源集合
3. 保留 durable-before-publish; 无新 main.sync; 无行为回归(正常源增删仍工作)
4. 测试: 注入旧 source pending → 重配移除 → 新源事件不含旧源; 阻塞 full scan 期间移除
   无 delta 的 source → 释放后 snapshot 不含旧源应用

## 命令纪律(硬性)
bash 每条单命令, 严禁 2>&1 | && ;、rg、rm、which。搜索用 grep 工具, 读用 read 工具。
验证: cd Packages/LaunchPlatform && swift test; xcodebuild build。

## 禁止
不提交 git; 不改 Launchpad_Back; 不改 M2/M3 范围外文件

## 输出
改动/假设/测试结果/偏差; 每步 [PROGRESS]
