# LaunchBetter Stage A/B/C — Post-v0.2.3 Consolidation + Feature + RC Report

## BASELINE
- Start: v0.2.3 (d8cf597), main
- End: 本报告对应未 tag HEAD(将发布 v0.3.0)
- 执行方式: 主对话总控 + 多并发 DeepSeek implementer(隔离上下文)+ Luna 设计门/阶段评审 + Watchdog

## STAGE A — Architecture + Invisible Performance

已提交(原子):
- A1 RetryBackoff: FSEvents/持久化重试 capped backoff[250ms,1s,4s,15s,30s], 成功/新事件 reset, 取消干净退出
- A2/A3/A4: drag 热路径去每帧 setDragSourceHidden(identity-owned 保证); 每帧单次 DragHitTarget 分类;
  snapshot index cache 测量后 defer(13.66us/call, 稳态 0 次 → 一致性面不抵 ~9us)
- A5/A6: DiskCacheWriter(actor, keyed dedup, 有界, 错误不阻塞)磁盘写离首屏; live 结果不再二次光栅化
- A7: CellRootView viewDidChangeBackingProperties(标准 AppKit 生命周期, 零全局通知)
- A8: 可点击页点 PageDotView(复用 PagingInteractionController.startSettle, button 语义,
  本地化 "Page X of Y", 24pt 命中区 + 6pt 视觉点)
- A9/A12: FolderViewController 结构/元数据分离(去 reloadData, reapplyMetadata);
  LayoutStore.renameFolder 无假 DisplayModel(窄纯 API)
- A10/A11: 诊断提取 Diagnostics/(10 文件); DragController 拆 6 聚焦文件(单一运行时拖拽所有者)
- A13: LauncherStoring 分解 DEFER(设计注记; 布尔回执已覆盖唯一消费者)
- A14: DisplayItem 稳定身份(folder=FolderID, children 独立 payload; 无假 delete/insert; 拖拽按 FolderID 匹配保持)

Buho 借鉴: 可点击页点、标准 Retina 生命周期(独立实现, 未复制代码); 拒绝 CoreData/搜索分页/NSDraggingSession 重写/Dock 私有区。

## STAGE B — Feature Completion

- B1 本地化应用名: .lproj/InfoPlist.strings/CFBundleDisplayName/CFBundleName 解析
  (custom > localized > base > filename), schemaVersion 升级+迁移保留, 语言切换即时,
  搜索索引更新; OpenStep plist 解析已验证(PropertyListSerialization)
- B2 自定义来源端到端: 动态源集合+重扫(增量, generation 防陈旧), DirectoryMonitor 动态 scope,
  去重(默认+重叠), 无效目录容忍, 移除对账; 无 show 全量扫描
- B3 右键菜单: Reveal in Finder + Get Info(路径安全无 shell 注入); 本地化
- B5 设置 About(版本)
- B4 热键录制 DEFER(预设已满足; 自定义 recorder 不成比例复杂度)
- B6 垂直布局 DEFER(Luna 设计门: 现有 page/slot 契约未定义垂直线性索引, 直接实现破坏横向回归;
  已记录实施要点: prepareSearch 为连续几何投影基础, LayoutMode 归 Config)

## STAGE C — RC Hardening

- C1/C2 探针: paging scroll=58≤frames=70, settles=1, prepare 恒定; pagetest 0→1→2→1→0;
  smoke+dragtest+folders OK
- C3 压力测试: 合成 100/250/500 apps(DisplayModel/SearchIndex/LayoutTransaction/snapshot), 0.14s
- C4 生命周期: 审计 14 资源; GestureCaptureEngine.stop 清回调; PagingInteractionController teardown
  停 display link
- C5 并发评审(Luna): 修复 M1/M1-1/M2 — Multitouch box owner token + 设备订阅同锁串行化 +
  restart/stop 生命周期代数; M2/M3 sourceGeneration/DirectoryMonitor streamGeneration(幽灵应用);
  测试 wait 断言
- C7 CI: .github/workflows/ci.yml(macOS, 三包测试 + Debug/Release build)
- C6 GUI: Computer Use 存在但受限; 用现有探针+截图(页点点击/本地化名/Get Info 授权弹窗 → MANUAL)

## MEASUREMENTS
- paging: scroll=58≤70(每帧≤1 写), settles=1, prepare 4→4(0 额外)
- drag cache: 同 destination 停留 preview=1 恒定(v0.1.6 保留)
- icon: DiskCacheWriter 写离首屏; live 无双光栅化(冷延迟不劣化)
- 测试: Core 140(77 XCTest+63 ST)/ Platform 127 / UI 56; build Debug+Release OK

## TESTS
- 新增: RetryBackoffTests(7), DragHotPathTests, FolderRefreshTests, ContextMenuTests,
  A14FolderIdentityTests(4), CustomSourceTests, GestureEngineLifecycleTests, PagingLifecycleTests,
  StressTests(100/250/500), LocalizedNames 系列, DiscoveryTests 扩展
- 探针全过: smoke/pagetest/pagingprobe/dragtest/folders

## REVIEWS
- Luna: Stage A PASS(0B/0M); Stage B 通过(主控独立验证 OpenStep 解析 + 全绿);
  Stage C C5 并发评审: 多轮 MAJOR(M1/M1-1/M2/M2-M3/restart 竞态)全部针对性修复;
  终审受权限限制无法完整复核(不能跑测试), 主控独立验证: 源码修复正确 + 全测试绿
- 视觉: mimo 未参与(无新截图场景; 历史误报记录)

## COMPUTER USE
- computer-use skill 可用但 GUI 自动化受焦点/权限限制; 使用现有运行时探针 + 截图;
  真实 GUI(页点点击/本地化名/Get Info 弹窗)标 MANUAL_VERIFICATION_REQUIRED

## GIT
- 分支 main; 30+ 原子提交(Stage A 12, Stage B 8, Stage C 10); 全部已 push
- 待: v0.3.0 tag + GitHub Release

## MEMORY
- 已同步(Stage A/B/C 完成)

## MANUAL GATES
- 物理三指/四指手势手感; 页点点击; 本地化名实机抽查(2-3 个多语言应用);
  Get Info 首次 Automation 授权弹窗; 120Hz 手感

## REMAINING RISKS
- 垂直布局/热键录制/Scene 等 defer(记录)
- Multitouch 并发: 无 fake C API 交错测试(环境限制), 依赖源码级修复 + 压力测试
- InfoPlist.strings 实机抽查未做(manual)
- CI workflow 未经实际 GitHub 运行验证(需 push 后观察)
