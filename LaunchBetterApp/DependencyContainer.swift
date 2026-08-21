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
    public let activationCoordinator: ActivationCoordinator
    public let settingsController: SettingsWindowController
    public let loginItem: SMAppServiceLoginItemController
    let threeFingerCoordinator: ThreeFingerDragCoordinator

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

        // App Library 元数据: 启动同步读盘 seed(启动恢复, 非 show/Library 入口 IO)。
        // 损坏/缺失回退空 seed; 损坏文件由 actor.start() 后台备份处理(与 catalog 一致)。
        let metadataStore = AppLibraryMetadataStore(directory: supportDir)
        // 文件名与 AppLibraryMetadataStore.fileURL 保持一致,但不在 MainActor
        // 同步访问 actor 隔离属性;URL 直接由 supportDir 派生。
        let metadataFileURL = supportDir.appendingPathComponent("AppLibraryMetadata.json")
        let initialMetadata =
            (try? DurableFile.loadCodable(
                AppLibraryMetadataSnapshot.self,
                from: metadataFileURL
            )) ?? .init()

        let store = LauncherStore(
            catalogActor: catalogActor,
            layoutStore: layoutActor,
            initialSnapshot: initialSnapshot,
            initialLayout: initialLayout,
            settingsStore: settingsStore,
            metadataStore: metadataStore,
            initialMetadata: initialMetadata
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
        L10n.configure(language: store.config.language)
        print("L10N configured lang=\(store.config.language) placeholder=\(L10n.t(.searchPlaceholder))")

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

        // 自定义源目录变更即时生效(Stage B §B2):
        // 设置保存(持久化)后 → 动态重配 monitor scopes → catalog 增量重扫新源/对账移除源。
        store.onCustomSourcesChange = { [weak catalogActor, weak directoryMonitor, weak store] customPaths in
            let fullSources = AppDiscoveryService.defaultSources + customPaths.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            directoryMonitor?.reconfigure(scopes: fullSources.map(\.path))
            Task {
                guard let delta = await catalogActor?.updateSources(fullSources), !delta.isEmpty else {
                    return
                }
                await MainActor.run {
                    store?.catalogDidChangeExternally()
                }
            }
        }

        // 窗口控制器单实例(激活协调器与冒烟共享)
        let wallpaperProvider = WallpaperProvider(
            cachesURL: cachesDir
        )
        // 启动即后台预渲染壁纸(首显时直接命中缓存, 热启动 <100ms 目标)
        if let mainScreen = NSScreen.main {
            let prewarmRequest = WallpaperProvider.RenderRequest(
                screenFrame: mainScreen.frame,
                backingScale: mainScreen.backingScaleFactor,
                blurRadius: 30
            )
            if CommandLine.arguments.contains("--perf") {
                print("PERF prewarmRequest frame=\(mainScreen.frame) scale=\(mainScreen.backingScaleFactor)")
            }
            Task.detached(priority: .utility) { [weak wallpaperProvider] in
                let image = wallpaperProvider?.blurredWallpaper(for: prewarmRequest)
                if CommandLine.arguments.contains("--perf") {
                    print("PERF prewarm image=\(image != nil)")
                }
            }
        }
        let windowController = LauncherWindowController(
            store: store,
            iconProvider: iconAdapter,
            wallpaperProvider: wallpaperProvider
        )
        self.windowController = windowController

        // 激活: 四指手势 + 三指拖动 + 全局热键 + 热角(§115 / Stage 2)
        // 单一 GestureCaptureEngine: 三指(拖动)与四指(pinch)按 finger count 路由(Stage 2 §19)
        let gestureEngine = GestureCaptureEngine()
        let activation = ActivationCoordinator(
            windowController: windowController,
            gestureEngine: gestureEngine,
            hotkey: GlobalHotkey()
        )
        activation.start()
        // 设置变更即时生效(热键/热角/语言/壁纸模糊/搜索栏大小)
        store.onConfigChange = { [weak activation, weak windowController] config in
            activation?.reconfigure(with: config)
            windowController?.reapplyVisualConfig()
        }
        activation.reconfigure(with: store.config)
        self.activationCoordinator = activation

        // 三指拖动: 复用现有 DragController(Stage 2 §9); 面板显示时启用
        let threeFinger = ThreeFingerDragCoordinator(
            windowController: windowController, engine: gestureEngine
        )
        threeFinger.install()
        windowController.onVisibilityChange = { [weak threeFinger] visible in
            threeFinger?.setEnabled(visible)
        }
        self.threeFingerCoordinator = threeFinger

        // 设置窗口
        let loginItem = SMAppServiceLoginItemController()
        // 启动时按配置应用一次登录项(开机自动启动); 失败非致命
        loginItem.apply(store.config.launchAtLogin)
        let settingsController = SettingsWindowController(
            handler: store,
            iconProvider: iconAdapter,
            loginItem: loginItem
        )
        self.settingsController = settingsController
        self.loginItem = loginItem
        // 启动器右上角齿轮 → 打开设置: 作为启动器 child window(浮在上方, 启动器不退出)
        windowController.settingsController = settingsController
        windowController.onOpenSettings = { [weak windowController, weak settingsController] sourcePoint in
            guard let windowController,
                  let settingsController,
                  let sw = settingsController.window else { return }
            settingsController.launcherWindow = windowController.window
            windowController.presentSettingsWindow(sw, from: sourcePoint)
        }
    }
}
