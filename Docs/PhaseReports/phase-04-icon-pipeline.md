# Phase 4 — Icon Pipeline

## Scope

完整图标管道: 内存 LRU、磁盘缓存、IconKey 变体、稳定内容版本、in-flight 去重、
消费者取消、预解码、内存压力、AppIconProvider 集中提取、可见页优先、signpost。

## Implementation Summary

- **LaunchCore**: IconContentVersion.stableContentHash(FNV-1a 64bit,确定性,
  跨进程稳定)+ StableHash 工具
- **LaunchPlatform**:
  - IconContentVersionFactory: 真实内容信号(§74) — CFBundleIconFile/CFBundleIconName
    定位图标资源 mtime+大小 → Assets.car → 回退 Info.plist mtime + CFBundleVersion;
    AppDiscoveryService 已接入
  - IconMemoryCache(§76): 显式 dict + LRU + 字节成本(bytesPerRow×height)+
    可选数量限制;不用 NSCache;trim(keeping:)/trim(recentCount:)/removeAll 确定性逐出
  - IconDiskCache(§78): Icons/<hash(AppID)>/<pointSize>-<scale>-<contentHash>.png,
    文件名含完整变体;损坏文件删除重建(可再生缓存)
  - AppIconProvider(§80): 全应用唯一 NSWorkspace.icon 调用点,渲染为
    显示就绪 BGRA 位图
  - IconRepository(actor, §75): 内存 → in-flight(首挂起点前注册)→ 磁盘 →
    实时 → 预解码 → 内存+磁盘;每键 Task 共享,消费者取消不杀共享任务(§81);
    DispatchSource 内存压力监听(critical 全清/warning 激进裁剪, §77);
    os_signpost 事件(IconMemoryHit/IconDiskHit/IconLiveResolve);统计接口
  - trimForHidden: 启动器隐藏保留最近 32 个条目(§77)
- **LaunchUI**: IconImageProviding 协议(不依赖 LaunchPlatform);
  AppCellView 图标加载 + 复用竞态防护(§85: representedAppID + 消费者任务,
  取消+ID 校验后应用);GridViewController 传入 provider(可见页优先天然成立:
  cell 物化时才请求)
- **LaunchBetterApp**: IconImageAdapter(协议→actor 映射,内容版本经 LauncherStore);
  DependencyContainer 装配(磁盘 Caches/Icons + 128MB 内存上限 + 2000 数量上限);
  --iconbench 基准模式

## Important Files

- Packages/LaunchPlatform/Sources/LaunchPlatform/{IconMemoryCache,IconDiskCache,IconRepository,AppIconProvider,IconContentVersionFactory}.swift
- Packages/LaunchCore/Sources/LaunchCore/Icon.swift(稳定哈希)
- Packages/LaunchUI/Sources/LaunchUI/{AppCellView,LauncherStoring,GridViewController}.swift
- LaunchBetterApp/IconImageAdapter.swift + DependencyContainer.swift
- Tests: IconCacheTests(21) + IconRepositoryTests(15)

## Tests

113 + 27 = 140 通过(LaunchCore 82, LaunchPlatform 58):
LRU 逐出确定性、成本限制、trim keeping/recentCount、磁盘往返/变体隔离/损坏重建、
内容版本哈希确定性、工厂信号优先级/稳定性/变更、Repository 首取/内存命中/
**in-flight 去重(并发只调一次 provider)**/磁盘命中(不调 provider)/变体隔离/
内容失效/**消费者取消共享任务存活**/内存压力保留与恢复/invalidate。

## Build Results

- 两个包 swift test 全绿;xcodebuild Debug SUCCEEDED
- 真实系统冒烟(--smoke)回归通过

## Performance Results(实测基准 --iconbench, 87 应用)

- 冷路径(磁盘+实时提取): 87 图标共 1756ms(20.19ms/图标,含 NSWorkspace 提取+写盘)
- 热路径(全内存命中): 87 图标共 **5.5ms(0.06ms/图标)**
- 磁盘写入 1 次/图标;内容版本信号驱动,图标更新自动换键
- signpost 事件已埋点(统一 subsystem dev.launchbetter)

## Review Results

- **Luna Max 独立代码评审(独立窗口, reviewer agent)**: 0 BLOCKER / 3 MAJOR / 4 MINOR / 4 NOTE / 多项 PASS
- **修复(3 个 MAJOR 全部落实, 已加测试)**:
  - M1 取消语义: `image(for:)` 入口与每个返回点检查 `Task.isCancelled`,取消消费者返回 nil,
    共享任务不受影响(测试: 取消者 nil / 未取消者获结果 / provider 仅调一次)
  - M2 陈旧结果防护: 每应用代际(appGenerations),invalidate 提升代际,
    in-flight 旧任务经 isCurrent 校验不发布结果;适配器 await 后复验内容版本
    (测试: invalidate 后旧任务返回 nil,新请求正常)
  - M3 生命周期: 显式 shutdown()(幂等,取消内存压力源/清 in-flight/清内存),
    处理器弱捕获 source 破除保留环(测试: shutdown 幂等,磁盘仍可恢复)
- **MINOR 已修**: canonicalString 长度前缀编码(消除 nil 与 "-" 碰撞);
  系统内存压力走统一 trimMemory API(语义一致)
- **MINOR 记录待办(Phase 9/10)**: 磁盘缓存增长无上限策略、CFBundleIconFile
  其他声明形式识别、AppIconProvider 显式 @MainActor 隔离确认、actor 内同步
  IO 队头阻塞(后续测度量级)、mtime+size 信号固有局限
- **MiMo V2.5 视觉评审(真实图标截图)**: PASS + 2 MINOR(长名标签省略号、
  文件夹图标与单应用图标视觉区分, 均 Phase 9 项)——与 Luna 结论一致
- 视觉评审链路验证: visual-reviewer(Luna→MiMo V2.5 切换)两次图像测试均正确描述
  (灰兔图片),模型配置切换后确认可用

## Architecture Deviations

- 无。§75/§76/§77/§78/§80/§81/§85 全部按文档落实
- 模型路由调整(用户指令): reviewer = gpt-5.6-luna variant:max;
  visual-reviewer = mimo-v2.5;已写入 .opencode/agents/
- 120Hz 显示链路验证仍受限于本机 60Hz(Phase 1B 记录)

## Known Limitations

- in-process Task 子代理(task 工具)无法被外部 watchdog 观察,仅能观察
  opencode run 独立会话
- 预解码(BGRA 位图)按 §79 实现,收益量化测量留待 Phase 6 帧时间统计

## Commit Range

TBD(Phase 4 提交)

## Remaining Risks

- 无阻塞项。

## Next

Phase 5 — Persistent Layout / Folder System:
LayoutStore(应用 LayoutMutation)、LayoutSnapshot 持久化、文件夹创建/重命名/解散、
墓碑行为、隐藏过滤、重启持久性验证。
