# Phase 7 — FSEvents Incremental Catalog

## Scope

FSEvents 增量目录: DirectoryMonitor、.app root 折叠、debounce、scoped reconcile、
事件丢失恢复;实时安装/删除/更新验证。

## Implementation Summary

- **AppRootFolding(纯逻辑)**: 事件路径折叠(§71) —
  最长 scope 匹配(前缀防子串误匹配)、.app 组件折叠到应用根、非 .app 子项 → scope 脏、
  scope 外 → ignored
- **DirectoryMonitor**: FSEventStream 包装(SetDispatchQueue 后台队列)、
  C 回调窄包装、事件丢失标志检测(MustScanSubDirs/UserDropped/KernelDropped/
  RootChanged/EventIdsWrapped, §72)、0.5s debounce 合并摘要、锁保护跨线程状态、
  显式 start()/stop()(deinit 兜底)
- **AppCatalogActor 增量对账**: reconcileAppRoot(单应用重扫)/ reconcileScope(单目录
  枚举)/ applyChangeSummary(组合增量, 事件丢失 → scope 恢复性重扫)/ CatalogDelta.merged
- **应用接入**: 注入式回调(无 NotificationCenter 胶水): 目录变化 → 增量对账 →
  LauncherStore 拉取最新快照 → 布局对账(新应用入布局/墓碑)→ 刷新;
  启动器显示仍零扫描(§66 不变式保持)

## Important Files

- Packages/LaunchPlatform: AppRootFolding.swift + DirectoryMonitor.swift + AppCatalogActor 扩展
- Packages/LaunchCore: CatalogDelta.merged
- LaunchBetterApp: DependencyContainer + LauncherStore.catalogDidChangeExternally
- Tests: FSEventsTests(12 个: 折叠 7 + 增量对账 6 + 实时事件 1)

## Tests

96 + 79 = 175 全绿(LaunchCore 96, LaunchPlatform 79):
折叠规则 7 项(含前缀陷阱)、增量对账 6 项(scope 插入/更新/删除恢复/隔离/组合/事件丢失)、
真实 FSEvents 事件到达与折叠。

## Build Results

- 两包 swift test 全绿;xcodebuild Debug SUCCEEDED
- **端到端实时验证**: 运行中应用感知 ~/Applications 安装(FSEventsLiveTest 5s 内入快照)
  与删除(自动移除), 零重启零手动刷新

## Performance Results

- 增量路径: 单应用重扫 = 1 次 Info.plist 读取;scope 枚举仅该目录。
  全量扫描仅保留为事件丢失恢复机制(§72)

## Review Results

- 自查发现并修复 3 个 bug:
  1. `URL.resolvingSymlinksInPath()` 在此 SDK 不解析 /var → realpath 方案
     (PathCanonicalizer 全面改用, 测试期望同步)
  2. 外部变更后布局用陈旧目录缓存 → catalogDidChangeExternally 先拉取最新快照
  3. **DirectoryMonitor 局部变量在 init 后析构**(deinit stop 静默停用)→
     容器属性持有
- 环境事实: /var → /private/var 收敛必须用 realpath(URL/NSString 均失效)

## Architecture Deviations

- 无。§69-72 全部落实;启动器显示零扫描不变式保持

## Known Limitations

- /System/Applications 视为低优先级(§69), 靠启动/手动对账
- debounce 固定 0.5s(未配置化)

## Commit Range

TBD(Phase 7 提交)

## Remaining Risks

- 无阻塞项。

## Next

Phase 8 — Multitouch / Global Activation:
GestureCaptureEngine(MultitouchSupport 隔离)、四指捏合、全局热键(Carbon);
**需要用户授予输入监控权限(TCC)**;Minimum Usable Release Gate 评估。
