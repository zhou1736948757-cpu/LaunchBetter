import AppKit
import LaunchCore
import QuartzCore

/// 启动器窗口控制器: 组装搜索栏 + 网格 + 窗口生命周期。
///
/// 职责:
/// - show/hide(淡入淡出)
/// - 搜索栏 → store.searchQuery → GridViewController.refresh
/// - 键盘导航(左右翻页 / Escape 隐藏 / Return 启动首项)
/// - 点击启动(经 GridViewController 点击路由)
@MainActor
public final class LauncherWindowController: NSWindowController, NSSearchFieldDelegate {
    private let store: any LauncherStoring
    private let iconProvider: (any IconImageProviding)?
    private let wallpaperProvider: WallpaperProvider?
    private var gridViewController: GridViewController!
    private var folderViewController: FolderViewController?
    private let searchField = NSSearchField()
    private var dragController: DragController?
    private var backgroundLayer = CALayer()
    private var dimLayer = CALayer()
    private var backgroundRequest: WallpaperProvider.RenderRequest?

    private var visible = false

    public init(
        store: any LauncherStoring,
        iconProvider: (any IconImageProviding)?,
        wallpaperProvider: WallpaperProvider? = nil
    ) {
        self.store = store
        self.iconProvider = iconProvider
        self.wallpaperProvider = wallpaperProvider
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let window = LauncherWindow(screen: screen)
        super.init(window: window)
        configureWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureWindow() {
        guard let window else { return }
        // 失焦自动退出(点击其他应用); 模态对话框(重命名等)期间不退出
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSApp.modalWindow == nil, window.attachedSheet == nil else { return }
                self?.hide()
            }
        }
        let root = NSView()
        root.wantsLayer = true

        // 背景: 壁纸层 + 深色叠加层(§93; 无壁纸时保持深色)
        backgroundLayer.contentsGravity = .resizeAspectFill
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        root.layer?.addSublayer(backgroundLayer)
        root.layer?.addSublayer(dimLayer)

        let grid = GridViewController(store: store, iconProvider: iconProvider)
        grid.onOpenFolder = { [weak self] folderID in
            self?.openFolder(folderID)
        }
        grid.onClickBlank = { [weak self] in
            self?.hide()
        }
        gridViewController = grid

        // 拖拽引擎: 网格鼠标事件 → DragController(经样本缓冲/帧协调器)
        let dragController = DragController(grid: grid, store: store)
        self.dragController = dragController
        grid.dragController = dragController
        if let collectionView = grid.collectionViewRef as? ClickableCollectionView {
            collectionView.onDragBegin = { [weak dragController] point in
                guard let dragController, let item = grid.itemAt(point: point) else { return }
                dragController.beginDrag(item: item, at: point)
            }
            collectionView.onDragMove = { [weak dragController] point in
                dragController?.updateDrag(at: point)
            }
            collectionView.onDragEnd = { [weak dragController] point in
                dragController?.endDrag(at: point)
            }
        }

        root.addSubview(grid.view)
        grid.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            grid.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            grid.view.topAnchor.constraint(equalTo: root.topAnchor),
            grid.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        searchField.delegate = self
        searchField.placeholderString = L10n.t(.searchPlaceholder)
        searchField.alignment = .center
        searchField.sendsSearchStringImmediately = true
        root.addSubview(searchField)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            searchField.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 320),
        ])

        window.contentView = root
        (window as? LauncherWindow)?.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event)
        }

        store.onDataChange = { [weak self] in
            self?.gridViewController?.refresh()
        }
    }

    // MARK: - NSSearchFieldDelegate

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        return false
    }

    // MARK: - 显示 / 隐藏

    public func show() {
        guard !visible else { return }
        visible = true
        let showStart = CFAbsoluteTimeGetCurrent()
        lastShowStart = showStart
        guard let window, let launcherWindow = window as? LauncherWindow else { return }
        launcherWindow.showOnScreen(containing: NSEvent.mouseLocation)
        // 语言可能已变更: 刷新本地化文案
        searchField.placeholderString = L10n.t(.searchPlaceholder)
        updateBackground(for: window)
        gridViewController.refresh()
        let contentReady = CFAbsoluteTimeGetCurrent() - showStart
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        let orderedFront = CFAbsoluteTimeGetCurrent() - showStart
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 1
        }
        window.makeFirstResponder(searchField)
        if CommandLine.arguments.contains("--perf") {
            print("PERF show contentReadyMs=\(String(format: "%.1f", contentReady * 1000)) orderedFrontMs=\(String(format: "%.1f", orderedFront * 1000))")
        }
    }

    /// 壁纸背景: 内存命中同步应用(热显示零延迟), 否则后台渲染(§62 模式)。
    private func updateBackground(for window: NSWindow) {
        guard let provider = wallpaperProvider, let screen = window.screen else { return }
        let request = WallpaperProvider.RenderRequest(
            screenFrame: screen.frame,
            backingScale: window.backingScaleFactor,
            blurRadius: 30
        )
        if CommandLine.arguments.contains("--perf") {
            print("PERF showRequest frame=\(screen.frame) scale=\(window.backingScaleFactor)")
        }
        backgroundRequest = request
        // 布局层帧(屏幕变化时跟随)
        backgroundLayer.frame = window.contentView?.bounds ?? screen.frame
        dimLayer.frame = backgroundLayer.frame

        if let cached = provider.cachedWallpaper(for: request) {
            applyBackground(cached)
            return
        }

        Task.detached(priority: .userInitiated) { [weak self, weak provider] in
            guard let provider else { return }
            let image = provider.blurredWallpaper(for: request)
            // 每次显示仅一次主线程跳转(§88: 禁止每帧跳转, 此处是离散事件)
            DispatchQueue.main.async {
                guard let self, self.backgroundRequest == request else { return }
                self.applyBackground(image)
            }
        }
    }

    private func applyBackground(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.contents = image
        CATransaction.commit()
        if CommandLine.arguments.contains("--perf") {
            print("PERF wallpaperReadyMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - lastShowStart) * 1000))")
        }
    }

    private var lastShowStart: CFAbsoluteTime = 0
    private var wallpaperShowCounter = 0

    public func hide() {
        guard visible else { return }
        visible = false
        // M4: 隐藏时终止拖拽(display link/overlay 清理)
        dragController?.shutdown()
        iconProvider?.trimMemoryForHidden()
        guard let window else { return }
        store.searchQuery = ""
        searchField.stringValue = ""
        gridViewController.refresh()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                window.orderOut(nil)
            }
        }
    }

    public func toggle() {
        visible ? hide() : show()
    }

    public var isVisible: Bool { visible }

    // MARK: - 文件夹视图

    private func openFolder(_ folderID: FolderID) {
        guard let window, let contentView = window.contentView else { return }
        let folderView = FolderViewController(
            store: store, iconProvider: iconProvider, folderID: folderID
        )
        folderView.onBack = { [weak self] in
            self?.closeFolderView()
        }
        folderViewController = folderView
        contentView.addSubview(folderView.view)
        folderView.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            folderView.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            folderView.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            folderView.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            folderView.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func closeFolderView() {
        folderViewController?.view.removeFromSuperview()
        folderViewController = nil
    }

    /// 确定性诊断(冒烟验证用)。
    public func diagnostics() -> String {
        "window=\(isVisible) grid[\(gridViewController?.diagnostics() ?? "nil")]"
    }

    /// 冒烟诊断: 拖拽测试 API(公开, 数据均为 LaunchCore 公开类型)。
    public func dragTestItems() -> [DisplayModel.DisplayItem] {
        gridViewController?.allItems() ?? []
    }

    /// 翻页测试 API(校验真实滚动位置)。
    public func pageTestNext() -> Int {
        gridViewController?.nextPage()
        return gridViewController?.currentPageValue ?? -1
    }

    public func pageTestPrevious() -> Int {
        gridViewController?.previousPage()
        return gridViewController?.currentPageValue ?? -1
    }

    public func pageTestGoTo(_ page: Int) -> Int {
        gridViewController?.goToPage(page, animated: false)
        return gridViewController?.currentPageValue ?? -1
    }

    public func pageTestScrollX() -> Double {
        let x = gridViewController?.collectionViewRef.enclosingScrollView?.contentView.bounds.origin.x ?? -1
        return Double(x)
    }

    public func pageTestCurrentPage() -> Int {
        gridViewController?.currentPageValue ?? -1
    }

    public func pageTestPageCount() -> Int {
        gridViewController?.pageCountValue ?? -1
    }

    public func pageTestPageWidth() -> Double {
        Double(gridViewController?.geometry.pageWidth ?? -1)
    }

    public func pageTestDocumentWidth() -> Double {
        Double(gridViewController?.collectionViewRef.frame.width ?? -1)
    }

    public func pageTestScrollDiagnostics() -> String {
        gridViewController?.scrollDiagnostics() ?? "nil"
    }

    public func dragTestBegin(item: DisplayModel.DisplayItem, at point: NSPoint) {
        gridViewController?.dragController?.beginDrag(item: item, at: point)
    }

    public func dragTestUpdate(at point: NSPoint) {
        gridViewController?.dragController?.updateDrag(at: point)
    }

    public func dragTestEnd(at point: NSPoint) {
        gridViewController?.dragController?.endDrag(at: point)
    }

    // MARK: - 键盘

    public func handleKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            hide()
        case 123, 33: // Left, PageUp
            gridViewController.previousPage()
        case 124, 34: // Right, PageDown
            gridViewController.nextPage()
        case 36: // Return
            launchFirstSearchResult()
        default:
            break
        }
    }

    private func launchFirstSearchResult() {
        guard let results = store.searchResults(), let first = results.first else { return }
        if case .app(let id) = first {
            store.launch(id)
        }
    }

    // MARK: - NSSearchFieldDelegate

    public func controlTextDidChange(_ obj: Notification) {
        store.searchQuery = searchField.stringValue
        gridViewController.refresh()
    }
}
