import AppKit
import LaunchCore
import LaunchPlatform
import LaunchUI

/// 依赖容器: 装配存储与 UI 组件(薄层,无业务逻辑)。
@MainActor
public final class DependencyContainer {
    public let store: LauncherStore
    public let iconAdapter: IconImageAdapter
    public let windowController: LauncherWindowController
    public let directoryMonitor: DirectoryMonitor

    public init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.launchbetter.LaunchBetter"
        let supportDir = ApplicationSupport.directory(bundleIdentifier: bundleID)
        let catalogStore = CatalogSnapshotStore(directory: supportDir)
        let settingsStore = SettingsStore(directory: supportDir)

        var sources = AppDiscoveryService.defaultSources
        if let saved = try? settingsStore.load() {
            sources.append(contentsOf: saved.customSourceDirectories.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            })
        }

        let catalogActor = AppCatalogActor(store: catalogStore, sources: sources)
        // 首帧同步恢复快照(损坏时由 actor.start() 在后台备份处理)
        let initialSnapshot = (try? catalogStore.load()) ?? CatalogSnapshot(apps: [])

        // 布局存储: 首帧同步恢复(磁盘权威), 变更经 LayoutStore 持久化
        let layoutStore = LayoutSnapshotStore(directory: supportDir)
        let initialLayout = (try? layoutStore.load()) ?? LayoutSnapshot()
        let layoutActor = LayoutStore(seed: initialLayout, persistence: layoutStore)

        let store = LauncherStore(
            catalogActor: catalogActor,
            layoutStore: layoutActor,
            initialSnapshot: initialSnapshot,
            initialLayout: initialLayout,
            settingsStore: settingsStore
        )

        // 图标管道: 磁盘缓存(可再生) + 内存 LRU + 实时提取
        let cachesDir = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        )[0].appendingPathComponent(bundleID, isDirectory: true)
        let iconDiskCache = IconDiskCache(
            rootURL: cachesDir.appendingPathComponent("Icons", isDirectory: true)
        )
        let iconMemoryCache = IconMemoryCache(
            costLimitBytes: 128 * 1024 * 1024, // 128MB 图标内存上限
            countLimit: 2_000
        )
        let iconRepository = IconRepository(
            memoryCache: iconMemoryCache,
            diskCache: iconDiskCache,
            provider: AppIconProvider()
        )
        let iconAdapter = IconImageAdapter(repository: iconRepository, store: store)

        self.store = store
        self.iconAdapter = iconAdapter

        // FSEvents 增量目录监控(§69-72): 安装/删除/更新实时反映, 启动器显示仍零扫描。
        // 注入式回调(避免 NotificationCenter 胶水): 目录变化 → 增量对账 → 布局刷新
        let directoryMonitor = DirectoryMonitor(
            scopes: sources.map(\.path),
            latency: 1.0
        )
        directoryMonitor.onChange = { [weak catalogActor, weak store] summary in
            Task { @MainActor in
                guard let delta = await catalogActor?.applyChangeSummary(summary), !delta.isEmpty else {
                    return
                }
                store?.catalogDidChangeExternally()
            }
        }
        directoryMonitor.start()
        self.directoryMonitor = directoryMonitor

        self.windowController = LauncherWindowController(store: store, iconProvider: iconAdapter)
    }
}
