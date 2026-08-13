# 任务包: Stage E4 AppLibraryMetadataStore

## 背景

Core 已提供 `AppLibraryMetadataSnapshot`、`AppLibraryUsageRecord` 和 `AppLibraryModelBuilder`。现在需要 Platform actor 持久化 usage/firstSeen，完全独立于 LayoutStore。

## 允许修改的文件

- `Packages/LaunchPlatform/Sources/LaunchPlatform/AppLibraryMetadataStore.swift` (新增)
- `Packages/LaunchPlatform/Tests/LaunchPlatformTests/AppLibraryMetadataStoreTests.swift` (新增)

禁止修改其它文件、禁止提交、禁止切换分支、禁止修改旧仓库或现有未跟踪文件。

## API 目标

提供窄的 actor API，等价命名可调整但职责必须保留:

```swift
public actor AppLibraryMetadataStore {
    public init(directory: URL, initialSnapshot: AppLibraryMetadataSnapshot = .init())
    public func start() async -> AppLibraryMetadataSnapshot
    public func snapshot() -> AppLibraryMetadataSnapshot
    public func bootstrap(existingAppIDs: [AppID], now: Date) async -> AppLibraryMetadataSnapshot
    public func recordDiscovered(appIDs: [AppID], now: Date) async -> AppLibraryMetadataSnapshot
    public func recordLaunch(_ appID: AppID, at: Date) async -> AppLibraryMetadataSnapshot
    public func flush() async
    public func shutdown() async
}
```

## 约束

- 文件位于传入 Application Support directory 下的 `AppLibraryMetadata.json`。
- 持久化使用 `DurableFile`，带 schemaVersion、原子保存、损坏文件先 backup 后使用 seed/空快照；不能静默删除证据。
- `start()`、`shutdown()` 幂等；`deinit` 不承担业务生命周期工作。
- `bootstrap` 第一次把现有 AppID 写入 firstSeen 作为 baseline 并设置 `isBootstrapped=true`，这些 App 不属于 Recently Added。
- bootstrap 之后 `recordDiscovered` 只为不存在的 AppID 写 now，重复发现不重置。
- remove/reappear 同一 AppID 不重置 firstSeen；新 AppID 才新增。
- `recordLaunch` 只更新 count/last timestamp，不保存搜索词、窗口内容、文件或用户输入。
- 写入不能同步阻塞 UI；使用 actor 内 memory aggregate + coalesced/debounced atomic persistence。`flush()` 必须等待 pending write 完成。
- 未来 schema 或损坏输入不能 crash actor；遵循 Core snapshot 当前解码约定并保留旧文件。
- 不依赖 AppKit/SwiftUI，不触碰 LayoutStore/LayoutSnapshot。

## 必写测试

- 缺失文件 seed/start、schema round-trip、重启加载。
- bootstrap existing apps 全部 baseline，且不产生 Recently Added 候选。
- new AppID discovered 写入；重复发现保持原时间；remove/reappear 保持。
- launch count/lastLaunchedAt 更新、顺序调用确定性。
- 多次快速更新 coalesced 后 flush 可读。
- 损坏 JSON backup 保留且 actor 回退，不 crash。
- start/shutdown/flush 幂等。

## 验收

- `cd Packages/LaunchPlatform && swift test` 通过。
- 不增加 `DispatchQueue.main.sync`。
- 返回改动文件、持久化/并发假设、测试结果、偏差和未决问题；每一步用 `[PROGRESS]`。
