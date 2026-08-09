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

    /// 可见性变化回调(三指拖动等按面板显示启用, Stage 2)。
    public var onVisibilityChange: ((Bool) -> Void)?

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
        dragController.onFolderExitDragCancelled = { [weak self] in
            self?.folderViewController?.restoreFolderAfterDragCancellation()
        }
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
        // 避开刘海屏 notch(用户实测 v0.1.3 重叠): 安全区动态下移(v0.1.4)
        let screen = window.screen ?? NSScreen.main
        let topInset = max(0, screen?.safeAreaInsets.top ?? 0)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 24 + topInset),
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
            if folderViewController != nil {
                closeFolderView()
            } else {
                hide()
            }
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
        onVisibilityChange?(true)
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
        // v0.1.4: 默认不聚焦搜索框(避免光标闪烁); 点击搜索框才聚焦。
        // 键盘翻页/Return 经 window.keyDown 响应链仍可用。
        window.makeFirstResponder(nil)
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
        onVisibilityChange?(false)
        // M4: 隐藏时终止拖拽(display link/overlay 清理)
        dragController?.shutdown()
        // 文件夹是临时覆盖层；隐藏/Escape 后重开必须回到主网格。
        closeFolderView()
        iconProvider?.trimMemoryForHidden()
        guard let window else { return }
        store.searchQuery = ""
        searchField.stringValue = ""
        gridViewController.refresh()
        // v0.1.4: 重新打开面板回到第一页
        gridViewController.goToPage(0, animated: false)
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
        closeFolderView()
        // 文件夹是覆盖主网格与搜索栏的临时 overlay;底层内容保持可见,由 overlay 暗化。
        let folderView = FolderViewController(
            store: store, iconProvider: iconProvider, folderID: folderID
        )
        folderView.onBack = { [weak self] in
            self?.closeFolderView()
        }
        folderView.onDragExit = { [weak self] app, folder, sourceImage, point in
            self?.dragController?.beginFolderExitDrag(
                app: app,
                from: folder,
                sourceImage: sourceImage,
                at: point
            ) ?? false
        }
        folderView.onDragExitMove = { [weak self] point in
            self?.dragController?.updateDrag(at: point)
        }
        folderView.onDragExitEnd = { [weak self] point, completion in
            guard let dragController = self?.dragController else {
                completion(false)
                return
            }
            dragController.endDrag(at: point, completion: completion)
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
        guard let folderViewController else { return }
        folderViewController.cancelActiveDrag()
        if dragController?.isDragging == true {
            dragController?.cancelDrag()
        }
        folderViewController.onBack = nil
        folderViewController.onDragExit = nil
        folderViewController.onDragExitMove = nil
        folderViewController.onDragExitEnd = nil
        folderViewController.view.removeFromSuperview()
        self.folderViewController = nil
    }

    /// 确定性诊断(冒烟验证用)。
    public func diagnostics() -> String {
        "window=\(isVisible) grid[\(gridViewController?.diagnostics() ?? "nil")]"
    }

    /// 诊断: 可见单元格中已加载真实图标数。
    public func realIconCount() -> Int {
        guard let grid = gridViewController else { return 0 }
        return grid.collectionViewRef.visibleItems().compactMap { $0 as? AppCellView }
            .filter(\.hasRealIcon).count
    }

    /// 诊断: 可见单元格数。
    public func visibleItemCountForDiag() -> Int {
        gridViewController?.collectionViewRef.visibleItems().count ?? 0
    }

    /// 诊断: 手动驱动一帧(无 display link 环境, v0.1.6 §69)。
    public func dragProbeTick(_ point: NSPoint) {
        gridViewController?.dragController?.probeProcessTick(point)
    }

    /// 是否有活动拖拽(Stage 2 三指 enable/disable 检查)。
    public func hasActiveDrag() -> Bool {
        dragController?.isDragging ?? false
    }

    /// 三指拖动: 反查指针下图标并开始拖拽(Stage 2)。返回是否成功开始。
    /// 位置语义与旧 LaunchHistory 一致: 用 NSEvent.mouseLocation(指针), 非触点中心。
    public func threeFingerDragBegin() -> Bool {
        // 文件夹覆盖层存在时不可命中其后的主网格；文件夹子项由文件夹控制器接管。
        guard folderViewController == nil else { return false }
        guard let grid = gridViewController, let drag = dragController else { return false }
        guard let windowPoint = currentPointerInWindow() else { return false }
        guard let item = grid.itemAt(point: windowPoint) else { return false }
        drag.beginDrag(item: item, at: windowPoint, inputSource: .threeFinger)
        return drag.isDragging
    }

    public func threeFingerDragUpdate() {
        guard let drag = dragController, let windowPoint = currentPointerInWindow() else { return }
        drag.updateDrag(at: windowPoint, inputSource: .threeFinger)
    }

    public func threeFingerDragEnd() {
        guard let drag = dragController, let windowPoint = currentPointerInWindow() else { return }
        let leftMouseButtonPressed = (NSEvent.pressedMouseButtons & 1) != 0
        drag.endDrag(
            at: windowPoint,
            inputSource: .threeFinger,
            leftMouseButtonPressed: leftMouseButtonPressed
        )
    }

    /// 三指路径统一使用窗口基坐标，避免多处 screen→window 转换产生契约漂移。
    private func currentPointerInWindow() -> NSPoint? {
        window?.mouseLocationOutsideOfEventStream
    }

    public func threeFingerDragCancel() {
        dragController?.cancelDrag()
    }

    /// 拖拽缓存诊断(v0.1.6 §64): 同 destination 停留时 preview/transform 写应不增长。
    public func dragCacheDiagnostics() -> String {
        guard let grid = gridViewController, let drag = grid.dragController else { return "nil" }
        return "frames=\(drag.dragFrameCount) destChanges=\(drag.destinationChangeCount) previews=\(drag.previewCalculationCount) transformWrites=\(drag.transformWriteCount) folderHit=\(drag.folderHitTestCount) overlayWrites=\(drag.overlayVisualWriteCount)"
    }

    /// 冒烟诊断: 拖拽测试 API(公开, 数据均为 LaunchCore 公开类型)。
    public func dragTestItems() -> [DisplayModel.DisplayItem] {
        gridViewController?.allItems() ?? []
    }

    /// 强制刷新网格(诊断/设置生效验证用)。
    public func refreshGrid() {
        gridViewController?.forceRefresh()
    }

    /// 应用自渲染截图: layer 级渲染(与屏幕合成一致)。
    /// cacheDisplay 对纯 layer-backed 层级不可靠(搜索模式实测为空图, 假 BLOCKER)。
    public func captureContentScreenshot(to path: String) {
        guard let window, let contentView = window.contentView, let layer = contentView.layer else { return }
        let scale = window.backingScaleFactor
        let width = Int(contentView.bounds.width * scale)
        let height = Int(contentView.bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.scaleBy(x: scale, y: scale)
        // AppKit y 向上 → 位图 y 向下
        context.translateBy(x: 0, y: contentView.bounds.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("SCREENSHOT_WRITTEN \(path)")
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

    /// 测试: hide + show 后应回到第一页(v0.1.4)。
    public func pageTestHideShowReset() -> Bool {
        hide()
        show()
        return gridViewController?.currentPageValue == 0
    }

    public func pageTestScrollX() -> Double {
        let x = gridViewController?.collectionViewRef.enclosingScrollView?.contentView.bounds.origin.x ?? -1
        return Double(x)
    }

    public func pageTestCurrentPage() -> Int {
        gridViewController?.currentPageValue ?? -1
    }

    /// 分页探针(性能测量, v0.1.6 §63): 合成 NSEvent 驱动分页交互。
    public func pagingProbeFeed(_ event: NSEvent) {
        gridViewController?.pagingProbeFeed(event)
    }

    public func pagingProbeDiagnostics() -> String {
        let paging = gridViewController?.pagingDiagnostics ?? "nil"
        let layout = gridViewController?.layoutDiagnostics ?? "nil"
        return "paging[\(paging)] layout[\(layout)]"
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
            if folderViewController != nil {
                closeFolderView()
            } else {
                hide()
            }
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
