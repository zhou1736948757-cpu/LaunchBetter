import AppKit
import LaunchCore
import LaunchPlatform
import LaunchUI

/// 依赖容器: 装配存储与 UI 组件(薄层,无业务逻辑)。
@MainActor
public final class DependencyContainer {
    public let store: LauncherStore
    public let windowController: LauncherWindowController

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
        let store = LauncherStore(
            catalogActor: catalogActor,
            initialSnapshot: initialSnapshot,
            settingsStore: settingsStore
        )
        self.store = store
        self.windowController = LauncherWindowController(store: store)
    }
}
