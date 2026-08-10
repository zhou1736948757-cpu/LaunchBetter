import AppKit
import CoreGraphics
import LaunchCore
import QuartzCore

/// 启动器运行时布局证据(所有 rect 已转换到 contentView 坐标系)。
public struct LauncherLayoutDiagnostics {
    public let searchRectInContent: CGRect
    public let firstRowRectInContent: CGRect
    public let pageDotsRectInContent: CGRect?
    public let settingsButtonRectInContent: CGRect
    public let settingsButtonBounds: CGRect
    public let firstRowDocumentRect: CGRect
    public let intendedSearchGridGap: CGFloat
    public let actualSearchGridGap: CGFloat
    public let searchGridOverlap: Bool
    public let contentViewIsFlipped: Bool
    public let collectionViewIsFlipped: Bool
    public let searchMode: Bool

    public var settingsBoundsAreSquare: Bool {
        abs(settingsButtonBounds.width - settingsButtonBounds.height) <= 0.5
    }

    public var settingsFrameIsSquare: Bool {
        abs(settingsButtonRectInContent.width - settingsButtonRectInContent.height) <= 0.5
    }

    public var isValid: Bool {
        !searchGridOverlap
            && actualSearchGridGap + 0.5 >= intendedSearchGridGap
            && abs(settingsButtonBounds.width - 40) <= 0.5
            && abs(settingsButtonBounds.height - 40) <= 0.5
            && settingsBoundsAreSquare
            && settingsFrameIsSquare
    }
}

private enum LauncherChromeMetrics {
    static let searchTopMargin: CGFloat = 24
    static let settingsTopMargin: CGFloat = 20
    static let searchMinimumHeight: CGFloat = 22
    static let searchAspectRatio: CGFloat = 16
    static let searchToGridGap: CGFloat = 24
    static let searchContentPadding: CGFloat = GridGeometry.defaultSearchPadding
    static let pageDotHitHeight: CGFloat = 24
    static let pageDotBottomMargin: CGFloat = 12
    static let gridBottomGap: CGFloat = 8

    static func searchHeight(for width: CGFloat) -> CGFloat {
        max(searchMinimumHeight, width / searchAspectRatio)
    }
}

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
    private var searchFieldWidthConstraint: NSLayoutConstraint?
    private var searchFieldHeightConstraint: NSLayoutConstraint?
    private var searchFieldTopConstraint: NSLayoutConstraint?
    private var settingsButtonTopConstraint: NSLayoutConstraint?
    private var settingsButtonView: SettingsButton?
    private var dragController: DragController?
    private var backgroundLayer = CALayer()
    private var dimLayer = CALayer()
    private var backgroundRequest: WallpaperProvider.RenderRequest?

    private var visible = false

    /// Launcher 视觉过渡状态机(过期 completion 防护)。
    private var transition = LauncherTransitionLifecycle()

    /// 诊断: 当前过渡状态。
    public var transitionStateForDiag: String { "\(transition.state)" }

    /// 可见性变化回调(三指拖动等按面板显示启用, Stage 2)。
    public var onVisibilityChange: ((Bool) -> Void)?

    /// 打开设置回调(由应用层接线到 SettingsWindowController)。
    public var onOpenSettings: (() -> Void)?

    /// 设置窗口控制器(唯一所有权入口)。由应用层注入。
    public weak var settingsController: SettingsWindowController?

    /// 当前输入所有者。Settings 激活时底层 Launcher 不得响应任何输入。
    private var interactionSurface: LauncherInteractionSurface = .launcher

    /// Settings 激活时覆盖在 Launcher 内容上的输入屏蔽层。
    private var interactionShield: SettingsInteractionShield?

    /// 当前输入面(诊断/探针)。
    public var currentInteractionSurface: LauncherInteractionSurface { interactionSurface }

    /// 把设置窗口作为启动器的 child window 挂载(浮在启动器上方, 启动器不退出)。
    /// 由应用层把 settingsController.launcherWindow 设为本窗口后调用。
    public func presentSettingsWindow(_ settingsWindow: NSWindow) {
        guard let window, let contentView = window.contentView else { return }
        // 幂等: 已激活则只把设置带到前台, 不重复安装 shield/child。
        if interactionSurface == .settings {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        // 取消进行中的瞬态操作; 关闭 folder overlay(其可能正持有拖拽); 暂停分页。
        dragController?.cancelDrag()
        closeFolderView()
        gridViewController?.suspendPagingForSurface()
        interactionSurface = .settings
        installSettingsShield(in: contentView)
        settingsController?.onClose = { [weak self] in
            MainActor.assumeIsolated {
                self?.settingsDidClose()
            }
        }
        window.addChildWindow(settingsWindow, ordered: .above)
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    /// App 菜单入口: 与齿轮按钮走同一所有权路径(不能直接调 settingsController.show())。
    public func openSettingsFromMenu() {
        guard let settingsController, let sw = settingsController.window else { return }
        settingsController.launcherWindow = window
        presentSettingsWindow(sw)
    }

    /// 屏蔽层点击(Launcher 空白): 只关闭 Settings, 不结束所有权(等待 mouseUp)。
    private func requestSettingsClose() {
        settingsController?.close()
    }

    /// Settings 已关闭(任意路径)。若仍有点击序列未完成, 等 mouseUp 再恢复所有权;
    /// 但为防 mouseUp 永不到达(应用失活/事件取消), 设置有限兜底。
    private func settingsDidClose() {
        guard interactionSurface == .settings else { return }
        if let shield = interactionShield, shield.isConsumingClick {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated {
                    // 幂等: mouseUp 若已到达会先恢复; 未到达则由本兜底清理。
                    self?.endSettingsOwnership()
                }
            }
            return
        }
        endSettingsOwnership()
    }

    /// shield mouseUp 已消费完整序列 → 现在安全恢复。
    private func shieldClickConsumed() {
        endSettingsOwnership()
    }

    /// 恢复 Launcher 交互(幂等): 移除 shield、释放所有权、恢复分页、确保拖拽空闲。
    private func endSettingsOwnership() {
        guard interactionSurface == .settings else { return }
        interactionSurface = .launcher
        interactionShield?.removeFromSuperview()
        interactionShield = nil
        gridViewController?.resumePagingForSurface()
        dragController?.cancelDrag()
    }

    private func installSettingsShield(in contentView: NSView) {
        let shield = SettingsInteractionShield(frame: contentView.bounds)
        shield.autoresizingMask = [.width, .height]
        shield.onShieldMouseDown = { [weak self] in
            MainActor.assumeIsolated {
                self?.requestSettingsClose()
            }
        }
        shield.onShieldMouseUp = { [weak self] in
            MainActor.assumeIsolated {
                self?.shieldClickConsumed()
            }
        }
        contentView.addSubview(shield, positioned: .above, relativeTo: nil)
        interactionShield = shield
    }

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
                // 设置窗口作为 child 挂载时其成为 key → 父 resign key, 不得隐藏启动器。
                guard NSApp.modalWindow == nil, window.attachedSheet == nil,
                      window.childWindows == nil || window.childWindows!.isEmpty else { return }
                self?.hide()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateChromeLayoutForCurrentScreen()
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
            guard let self, self.interactionSurface == .launcher else { return }
            self.openFolder(folderID)
        }
        grid.onClickBlank = { [weak self] in
            guard let self, self.interactionSurface == .launcher else { return }
            self.hide()
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
            collectionView.onDragBegin = { [weak self] point in
                guard let self, let item = grid.itemAt(point: point) else { return }
                self.beginRootDragIfPermitted(item: item, at: point)
            }
            collectionView.onDragMove = { [weak self, weak dragController] point in
                guard let self, self.interactionSurface == .launcher else { return }
                dragController?.updateDrag(at: point)
            }
            collectionView.onDragEnd = { [weak self, weak dragController] point in
                guard let self, self.interactionSurface == .launcher else { return }
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
        // 搜索栏等比大小(宽 = 标尺, 高 = 宽/16; 居中)。顶部 safe area
        // 由 updateChromeLayoutForCurrentScreen() 与网格保留区统一更新。
        let size = CGFloat(store.searchBarWidth)
        let height = LauncherChromeMetrics.searchHeight(for: size)
        searchFieldWidthConstraint = searchField.widthAnchor.constraint(equalToConstant: size)
        searchFieldHeightConstraint = searchField.heightAnchor.constraint(equalToConstant: height)
        searchFieldTopConstraint = searchField.topAnchor.constraint(
            equalTo: root.topAnchor,
            constant: 0
        )
        NSLayoutConstraint.activate([
            searchFieldTopConstraint!,
            searchField.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            searchFieldWidthConstraint!,
            searchFieldHeightConstraint!,
        ])

        // 设置入口: 右上角玻璃齿轮(唯一设置入口, 简洁 macOS 风格)。
        let settingsButton = SettingsButton()
        settingsButton.target = self
        settingsButton.action = #selector(settingsButtonTapped)
        settingsButtonView = settingsButton
        root.addSubview(settingsButton)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButtonTopConstraint = settingsButton.topAnchor.constraint(
            equalTo: root.topAnchor,
            constant: 0
        )
        NSLayoutConstraint.activate([
            settingsButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            settingsButtonTopConstraint!,
            settingsButton.widthAnchor.constraint(equalToConstant: 40),
            settingsButton.heightAnchor.constraint(equalToConstant: 40),
        ])

        window.contentView = root
        updateChromeLayoutForCurrentScreen()
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

    @objc private func settingsButtonTapped() {
        onOpenSettings?()
    }

    // MARK: - 显示 / 隐藏

    public func show() {
        guard !visible else { return }
        visible = true
        let transitionToken = transition.beginShow()
        let showStart = CFAbsoluteTimeGetCurrent()
        lastShowStart = showStart
        guard let window, let launcherWindow = window as? LauncherWindow else { return }
        launcherWindow.showOnScreen(containing: NSEvent.mouseLocation)
        onVisibilityChange?(true)
        // 换屏后安全区可能变化: 同时更新搜索框、设置按钮与网格保留区。
        updateChromeLayoutForCurrentScreen()
        // 语言可能已变更: 刷新本地化文案
        searchField.placeholderString = L10n.t(.searchPlaceholder)
        updateBackground(for: window)
        gridViewController.refresh()
        let contentReady = CFAbsoluteTimeGetCurrent() - showStart
        // 首次呈现从 0 淡入; 若正处于 dismiss 中途重开, 从当前呈现反向淡入(不重置到 0)。
        if !window.isVisible {
            window.alphaValue = 0
        }
        window.makeKeyAndOrderFront(nil)
        let orderedFront = CFAbsoluteTimeGetCurrent() - showStart
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MotionEnvironment.launcherFadeDuration
            window.animator().alphaValue = 1
        } completionHandler: {
            MainActor.assumeIsolated {
                // 若期间又 hide(), 令牌过期 → 不覆盖 dismissing 状态。
                _ = self.transition.completeShow(transitionToken)
            }
        }
        // v0.1.4: 默认不聚焦搜索框(避免光标闪烁); 点击搜索框才聚焦。
        // 键盘翻页/Return 经 window.keyDown 响应链仍可用。
        window.makeFirstResponder(nil)
        if CommandLine.arguments.contains("--perf") {
            print("PERF show contentReadyMs=\(String(format: "%.1f", contentReady * 1000)) orderedFrontMs=\(String(format: "%.1f", orderedFront * 1000))")
        }
    }

    /// 壁纸背景: 内存命中同步应用(热显示零延迟), 否则后台渲染(§62 模式)。
    /// 布局诊断: 设置按钮/搜索栏/网格首排坐标, 均使用实际 view frame。
    public func settingsButtonFrameDiagnostics() -> String {
        guard let b = settingsButtonView, let contentView = window?.contentView else { return "nil" }
        contentView.layoutSubtreeIfNeeded()
        let bounds = b.bounds
        let inContent = b.convert(b.bounds, to: contentView)
        let constraints = b.constraints
            .map { String(Int($0.constant)) }
            .joined(separator: ",")
        return "bounds=\(bounds) frameInContent=\(inContent) constraints=\(constraints)"
    }

    public func searchFieldFrameDiagnostics() -> String {
        guard let contentView = window?.contentView else { return "nil" }
        contentView.layoutSubtreeIfNeeded()
        let f = searchField.convert(searchField.bounds, to: contentView)
        return "rectInContent=\(f) contentFlipped=\(contentView.isFlipped)"
    }

    public func gridFirstRowTopDiagnostics() -> String {
        guard let grid = gridViewController,
              let contentView = window?.contentView,
              let firstRow = grid.firstRowFrame(in: contentView),
              let documentFrame = grid.firstRowDocumentFrame() else {
            return "nil"
        }
        return "rectInContent=\(firstRow) rectInDocument=\(documentFrame) collectionFlipped=\(grid.collectionViewRef.isFlipped)"
    }

    public func contentInsetsDiagnostics() -> String {
        gridViewController?.contentInsetsDiagnostics() ?? "nil"
    }

    /// 运行时 frame invariant: 所有矩形先转入同一个 contentView 坐标系。
    public func runtimeLayoutDiagnostics() -> LauncherLayoutDiagnostics? {
        guard let contentView = window?.contentView,
              let grid = gridViewController,
              let settingsButton = settingsButtonView,
              let firstRow = grid.firstRowFrame(in: contentView),
              let firstRowDocument = grid.firstRowDocumentFrame() else {
            return nil
        }
        contentView.layoutSubtreeIfNeeded()

        let searchRect = searchField.convert(searchField.bounds, to: contentView)
        let settingsRect = settingsButton.convert(settingsButton.bounds, to: contentView)
        let pageDotsRect = grid.pageDotsFrame(in: contentView)
        let gap: CGFloat
        if contentView.isFlipped {
            gap = visualTop(of: firstRow, in: contentView)
                - visualBottom(of: searchRect, in: contentView)
        } else {
            gap = visualBottom(of: searchRect, in: contentView)
                - visualTop(of: firstRow, in: contentView)
        }

        return LauncherLayoutDiagnostics(
            searchRectInContent: searchRect,
            firstRowRectInContent: firstRow,
            pageDotsRectInContent: pageDotsRect,
            settingsButtonRectInContent: settingsRect,
            settingsButtonBounds: settingsButton.bounds,
            firstRowDocumentRect: firstRowDocument,
            intendedSearchGridGap: LauncherChromeMetrics.searchToGridGap
                + (grid.isSearchMode ? LauncherChromeMetrics.searchContentPadding : 0),
            actualSearchGridGap: gap,
            searchGridOverlap: searchRect.intersects(firstRow),
            contentViewIsFlipped: contentView.isFlipped,
            collectionViewIsFlipped: grid.collectionViewRef.isFlipped,
            searchMode: grid.isSearchMode
        )
    }

    /// 诊断用: 将系统指针移动到设置按钮中心, 供 --showstay --hover-settings 截图。
    public func movePointerToSettingsButtonForDiagnostic() {
        guard let window, let contentView = window.contentView,
              let settingsButton = settingsButtonView else { return }
        contentView.layoutSubtreeIfNeeded()
        let pointInWindow = settingsButton.convert(
            NSPoint(x: settingsButton.bounds.midX, y: settingsButton.bounds.midY),
            to: nil
        )
        let pointOnScreen = window.convertPoint(toScreen: pointInWindow)
        guard let screen = window.screen else { return }
        CGWarpMouseCursorPosition(
            CGPoint(x: pointOnScreen.x, y: screen.frame.maxY - pointOnScreen.y)
        )
    }

    /// 诊断用: 打开当前主网格中的第一个文件夹, 验证 overlay 不改变主网格布局。
    @discardableResult
    public func openFirstFolderForDiagnostic() -> Bool {
        guard let folder = gridViewController?.allItems().compactMap({ item -> FolderID? in
            if case .folder(let id) = item { return id }
            return nil
        }).first else {
            return false
        }
        openFolder(folder)
        window?.contentView?.layoutSubtreeIfNeeded()
        return true
    }

    private func visualTop(of rect: CGRect, in view: NSView) -> CGFloat {
        view.isFlipped ? rect.minY : rect.maxY
    }

    private func visualBottom(of rect: CGRect, in view: NSView) -> CGFloat {
        view.isFlipped ? rect.maxY : rect.minY
    }

    /// 当前屏幕的内容保留量。safe area、搜索框约束和 GridGeometry 共用这一组值。
    private func currentContentInsets(
        for safeArea: NSEdgeInsets,
        searchHeight: CGFloat
    ) -> (top: CGFloat, bottom: CGFloat) {
        let safeTop = max(0, safeArea.top)
        let safeBottom = max(0, safeArea.bottom)
        let top = safeTop
            + LauncherChromeMetrics.searchTopMargin
            + searchHeight
            + LauncherChromeMetrics.searchToGridGap
        let bottom = safeBottom
            + LauncherChromeMetrics.pageDotHitHeight
            + LauncherChromeMetrics.pageDotBottomMargin
            + LauncherChromeMetrics.gridBottomGap
        return (top, bottom)
    }

    /// 同步当前显示器的 safe area 到搜索框、设置按钮和 GridGeometry。
    /// `showOnScreen` 换屏后必须调用, 防止 chrome 与网格使用不同屏幕的 safeTop。
    private func updateChromeLayoutForCurrentScreen() {
        guard let contentView = window?.contentView else { return }
        let safeArea = (window?.screen ?? NSScreen.main)?.safeAreaInsets ?? NSEdgeInsetsZero
        let width = CGFloat(store.searchBarWidth)
        let searchHeight = LauncherChromeMetrics.searchHeight(for: width)

        searchFieldTopConstraint?.constant = LauncherChromeMetrics.searchTopMargin + max(0, safeArea.top)
        settingsButtonTopConstraint?.constant = LauncherChromeMetrics.settingsTopMargin + max(0, safeArea.top)
        searchFieldWidthConstraint?.constant = width
        searchFieldHeightConstraint?.constant = searchHeight

        let insets = currentContentInsets(for: safeArea, searchHeight: searchHeight)
        gridViewController?.setContentInsets(top: insets.top, bottom: insets.bottom)
        contentView.layoutSubtreeIfNeeded()
    }

    /// 设置即时生效(Stage v0.3.4): 壁纸模糊强度 + 搜索栏大小。
    /// 由应用层在 onConfigChange 时调用(设置里改滑条立即反映)。
    public func reapplyVisualConfig() {
        if let window {
            updateBackground(for: window)
        }
        // 搜索框尺寸变化 → 同步 chrome constraints 与 GridGeometry 保留区。
        updateChromeLayoutForCurrentScreen()
    }

    private func updateBackground(for window: NSWindow) {
        guard let provider = wallpaperProvider, let screen = window.screen else { return }
        // 用窗口内容尺寸而非屏幕 frame: 壁纸精确覆盖整个窗口(避免上下边缘
        // 尺寸不匹配露出未模糊区域, 用户实测反馈)
        let coverFrame = window.contentView?.bounds ?? screen.frame
        let request = WallpaperProvider.RenderRequest(
            screenFrame: coverFrame,
            backingScale: window.backingScaleFactor,
            blurRadius: CGFloat(store.wallpaperBlurRadius)
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
        // 设置作为 child window 打开时, 点击启动器空白只关闭设置, 不退出启动器(用户要求 v0.3.4)。
        // (设置窗口已因 resign key 自动 close; 此处防止启动器随之 hide)
        if let window, let children = window.childWindows, !children.isEmpty {
            return
        }
        visible = false
        let transitionToken = transition.beginHide()
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
            context.duration = MotionEnvironment.launcherFadeDuration
            window.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                // 若期间又 show(), 令牌过期 → 禁止过期 orderOut 关掉已重开的窗口。
                guard self.transition.completeHide(transitionToken), window.isVisible else { return }
                window.orderOut(nil)
            }
        }
    }

    public func toggle() {
        visible ? hide() : show()
    }

    public var isVisible: Bool { visible }
    public var isActuallyVisible: Bool { window?.isVisible == true }

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
        interactionSurface = .folder
        gridViewController?.suspendPagingForSurface()
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
        // 文件夹关闭后交还 launcher 面(仅当没有更高优先级的 settings 面), 并恢复分页。
        if interactionSurface == .folder {
            interactionSurface = .launcher
            gridViewController?.resumePagingForSurface()
        }
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

    public func isSearchModeForDiag() -> Bool {
        gridViewController?.isSearchMode ?? false
    }

    public func snapshotItemCountForDiag() -> Int {
        gridViewController?.diagnosticSnapshotItemCount ?? -1
    }

    /// 诊断: 手动驱动一帧(无 display link 环境, v0.1.6 §69)。
    public func dragProbeTick(_ point: NSPoint) {
        gridViewController?.dragController?.probeProcessTick(point)
    }

    public func dragCacheProbePoint() -> NSPoint? {
        gridViewController?.dragCacheProbePoint()
    }

    /// 是否有活动拖拽(Stage 2 三指 enable/disable 检查)。
    public func hasActiveDrag() -> Bool {
        dragController?.isDragging ?? false
    }

    /// 三指拖动: 反查指针下图标并开始拖拽(Stage 2)。返回是否成功开始。
    /// 位置语义与旧 LaunchHistory 一致: 用 NSEvent.mouseLocation(指针), 非触点中心。
    public func threeFingerDragBegin() -> Bool {
        // 只有 launcher 面拥有输入: Settings 激活或文件夹打开时不可命中底层网格。
        guard interactionSurface == .launcher else { return false }
        guard let grid = gridViewController, let drag = dragController else { return false }
        guard let windowPoint = currentPointerInWindow() else { return false }
        guard let item = grid.itemAt(point: windowPoint) else { return false }
        drag.beginDrag(item: item, at: windowPoint, inputSource: .threeFinger)
        return drag.isDragging
    }

    public func threeFingerDragUpdate() {
        guard interactionSurface == .launcher,
              let drag = dragController, let windowPoint = currentPointerInWindow() else { return }
        drag.updateDrag(at: windowPoint, inputSource: .threeFinger)
    }

    public func threeFingerDragEnd() {
        guard interactionSurface == .launcher,
              let drag = dragController, let windowPoint = currentPointerInWindow() else { return }
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

    /// 鼠标路径的统一拖拽入口: 只有 launcher 面允许开始根网格拖拽。
    private func beginRootDragIfPermitted(item: DisplayModel.DisplayItem, at point: NSPoint) {
        guard interactionSurface == .launcher else {
            if CommandLine.arguments.contains("--inputtrace") {
                print("INPUTTRACE grid drag BLOCKED surface=\(interactionSurface)")
            }
            return
        }
        if CommandLine.arguments.contains("--inputtrace") {
            print("INPUTTRACE grid drag begin")
        }
        dragController?.beginDrag(item: item, at: point)
    }

    // MARK: - 所有权诊断 seam(probe 使用, 与真实输入路径同一门控)

    /// 诊断: 第一个显示项的窗口坐标锚点(供 probe 发起/尝试拖拽)。
    public func diagnosticFirstItemAnchor() -> NSPoint? {
        guard let grid = gridViewController, let item = grid.allItems().first,
              let index = grid.flatIndex(of: item) else { return nil }
        let documentFrame = grid.frame(atFlatIndex: index)
        return grid.collectionViewRef.convert(
            NSPoint(x: documentFrame.midX, y: documentFrame.midY),
            to: nil
        )
    }

    /// 诊断: 尝试走真实鼠标路径开始根拖拽(受 surface 门控)。返回是否真的开始。
    public func diagnosticBeginRootDrag(at point: NSPoint) -> Bool {
        guard let item = gridViewController?.itemAt(point: point) else { return false }
        beginRootDragIfPermitted(item: item, at: point)
        return dragController?.isDragging ?? false
    }

    public func diagnosticRequestSettingsClose() {
        requestSettingsClose()
    }

    public func diagnosticShieldMouseUp() {
        shieldClickConsumed()
    }

    public func diagnosticHasHiddenDragSource() -> Bool {
        gridViewController?.hasHiddenDragSourceForDiag ?? false
    }

    public func diagnosticHasDragOverlay() -> Bool {
        gridViewController?.dragController?.hasOverlayForDiag ?? false
    }

    public func dragStateForDiag() -> String {
        gridViewController?.dragController?.stateForDiag ?? "nil"
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

    public func pagingProbeGesture(deltaXs: [CGFloat]) {
        gridViewController?.pagingProbeGesture(deltaXs: deltaXs)
    }

    public func pagingProbeDisplayFrame() -> Bool {
        gridViewController?.pagingProbeDisplayFrame() ?? false
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
            if interactionSurface == .settings {
                requestSettingsClose()
            } else if folderViewController != nil {
                closeFolderView()
            } else {
                hide()
            }
        case 123, 33, 124, 34, 36: // Left/PageUp, Right/PageDown, Return
            // 只有 launcher 面拥有键盘: Folder/Settings 激活时不得分页/启动底层。
            guard interactionSurface == .launcher else { return }
            switch event.keyCode {
            case 123, 33: gridViewController.previousPage()
            case 124, 34: gridViewController.nextPage()
            case 36: launchFirstSearchResult()
            default: break
            }
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
