# Phase 2 — App Catalog + Persistent State

## Scope

LaunchPlatform 包: 应用发现、路径规范化、目录增量对账、快照/设置持久化、
迁移框架、目录服务 actor。不实现 FSEvents(Phase 7)。

## Implementation Summary

新建 `Packages/LaunchPlatform`(Swift 6, macOS 14+,依赖 LaunchCore):

- **PathCanonicalizer**: 文件系统级收敛(symlink、/private、相对组件);
  不存在路径自然回退纯文本规范化(§39 第二层)
- **AppDiscoveryService**: 枚举源目录顶层 .app(/Applications、~/Applications、
  /System/Applications、自定义源),提取 displayName(CFBundleDisplayName →
  CFBundleName → 文件名)、bundleIdentifier、Info.plist mtime、CFBundleVersion;
  不可读 Info.plist 跳过;不调用 NSWorkspace.icon(集中到 Phase 4)
- **ReconcileEngine**: 旧快照 → 新记录集 → CatalogDelta(inserted/updated/removed,
  确定性排序)
- **CatalogSnapshotStore / SettingsStore / DurableFile**: 原子写入
  (temp + atomic replace)、损坏不静默清除(备份 `*.corrupt-<timestamp>`)
- **StateMigrationService**: 基于 Data 的确定性迁移链(步骤可跨类型边界),
  版本高于目标抛错、缺路径抛错;当前 schemaVersion=1 透传
- **AppCatalogActor**: 启动恢复磁盘快照(损坏→备份+空快照继续)、
  background 全量对账(发现运行在 detached utility 任务,不阻塞 actor)、
  对账结果原子持久化(失败不阻断流程,记录 lastPersistError)、
  generation 陈旧防护契约(currentSnapshot(ifGeneration:))
- LaunchCore 增补: `VersionedState` 协议(基础层,避免反向依赖)、
  CatalogSnapshot Equatable

## Important Files

- Packages/LaunchPlatform/Sources/LaunchPlatform/ 8 个文件
- Packages/LaunchPlatform/Tests/LaunchPlatformTests/ 2 个测试文件
- Packages/LaunchCore/Sources/LaunchCore/VersionedState.swift

## Tests

112 个测试全部通过(LaunchCore 81 + LaunchPlatform 31, 6 套件):
PathCanonicalizer(symlink 收敛、/private 收敛、不存在回退)、AppDiscovery
(真实 fake bundle 发现、名称回退链、过滤规则、身份一致性)、ReconcileEngine
(插入/更新/删除/混合/排序)、存储(往返、缺失、损坏抛错不静默清除、备份保留)、
迁移框架(透传/单步/链式/缺路径/高版本)、AppCatalogActor(空启动、对账增量、
持久化+重启恢复、删除产生 removed、损坏快照备份恢复、陈旧防护)。

## Build Results

- LaunchPlatform: swift test 31/31, release 构建通过,违禁模式扫描 = 0
- LaunchCore: 81/81 回归通过
- 真实系统冒烟(临时测试,已删除): /Applications 发现 40 个应用,
  名称/bundleID 提取正确

## Performance Results

- 真实 /Applications 发现: 40 应用 ~18ms(含 Info.plist 读取,debug 构建)。
  启动对账性能将由 Phase 3+ 的 signpost 正式测量。

## Review Results

自查评审:
- 发现/持久化/对账职责分离,与 §53 对齐
- 陈旧防护以 actor 串行化 + generation 契约实现
- 损坏持久状态策略与 §97 一致(备份,不静默清除)
- 删除产生 removed 的路径测试验证墓碑语义前置条件

GLM 独立评审限制同前(记录于 MEMORY)。

## Architecture Deviations

- IconContentVersion 信号暂只含 Info.plist mtime + bundleVersion
  (图标资源信号 Phase 4 补齐,公开发布前定稿)
- 持久文件格式 JSON(非 plist);§96 允许,格式契约以 schemaVersion 为准
- 存储目录由宿主注入(bundle ID 由应用层解析),测试注入临时目录

## Known Limitations

- 启动对账为"启动一次全量"策略(临时),FSEvents 增量到 Phase 7
- 性能 target(快照加载 < 10ms)尚未在正式产品路径测量

## Commit Range

TBD(Phase 2 提交)

## Remaining Risks

- 无阻塞项。

## Next

Phase 3 — Minimal Launcher:
Xcode 工程 + LaunchBetterApp target(LauncherWindow/Controller、NSCollectionView +
DiffableDataSource + DisplayModel provider、搜索、点击启动、占位图标)。
启动器显示零扫描(§66 不变式)。Luna 视觉评审截图。
