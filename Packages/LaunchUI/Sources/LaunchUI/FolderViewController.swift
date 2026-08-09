import AppKit
import LaunchCore

/// 文件夹视图: 显示文件夹内应用(单页网格),并承接文件夹内的局部操作。
@MainActor
final class FolderViewController: NSViewController {
    private let panelMetrics = FolderPanelMetrics.self
    private let store: any LauncherStoring
    private let iconProvider: (any IconImageProviding)?
    private let folderID: FolderID

    var onBack: (() -> Void)?
    /// 文件夹拖拽越过卡片后交给窗口控制器, 后续事件仍来自同一 mouse session。
    var onDragExit: ((AppID, FolderID, CGImage?, NSPoint) -> Bool)?
    var onDragExitMove: ((NSPoint) -> Void)?
    var onDragExitEnd: ((NSPoint, @escaping (Bool) -> Void) -> Void)?

    private var rootView: FolderRootView!
    private var cardShadowView: NSView!
    private var visualCardView: NSVisualEffectView!
    private var titleLabel: NSTextField!
    private var dissolveButton: NSButton!
    private var renameButton: NSButton!
    private var collectionView: ClickableCollectionView!
    private var scrollView: NSScrollView!
    private var dataSource: NSCollectionViewDiffableDataSource<Int, DisplayModel.DisplayItem>!
    private var displayedChildren: [AppID] = []

    private var dataObserverToken: UUID?
    private var orderOutObserver: NSObjectProtocol?
    private var isClosing = false

    // 文件夹覆盖层自己的鼠标拖拽状态; 不进入 LauncherStore 持久状态。
    private var draggingApp: AppID?
    private var draggingSourceIndex: Int?
    private var draggingOutside = false
    private var folderExitLifecycle = FolderExitDragLifecycle()
    private var folderExitHandedOff: Bool { folderExitLifecycle.isActive }
    private let dragOverlay = DragOverlayLayer()
    private let insertionIndicator = InsertionIndicatorLayer()

    init(store: any LauncherStoring, iconProvider: (any IconImageProviding)?, folderID: FolderID) {
        self.store = store
        self.iconProvider = iconProvider
        self.folderID = folderID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = FolderRootView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        root.onWindowChange = { [weak self] in
            self?.folderRootWindowDidChange()
        }
        root.onOutsideClick = { [weak self] in
            self?.closeFolder()
        }
        rootView = root

        let cardShadowView = NSView()
        cardShadowView.wantsLayer = true
        cardShadowView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        cardShadowView.layer?.cornerRadius = 24
        cardShadowView.layer?.shadowColor = NSColor.black.cgColor
        cardShadowView.layer?.shadowOpacity = 0.28
        cardShadowView.layer?.shadowRadius = 18
        cardShadowView.layer?.shadowOffset = NSSize(width: 0, height: -8)
        cardShadowView.setAccessibilityRole(.group)
        root.addSubview(cardShadowView)
        cardShadowView.translatesAutoresizingMaskIntoConstraints = false
        self.cardShadowView = cardShadowView

        let targetWidth = cardShadowView.widthAnchor.constraint(equalToConstant: panelMetrics.cardSize.width)
        targetWidth.priority = .defaultHigh
        let targetHeight = cardShadowView.heightAnchor.constraint(equalToConstant: panelMetrics.cardSize.height)
        targetHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            cardShadowView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            cardShadowView.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            cardShadowView.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            cardShadowView.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            cardShadowView.topAnchor.constraint(greaterThanOrEqualTo: root.topAnchor, constant: 24),
            cardShadowView.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
            cardShadowView.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -48),
            cardShadowView.heightAnchor.constraint(lessThanOrEqualTo: root.heightAnchor, constant: -48),
            targetWidth,
            targetHeight,
        ])

        let card = NSVisualEffectView()
        card.material = .hudWindow
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 24
        card.layer?.masksToBounds = true
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(L10n.format(.folderLabel, store.folderName(for: folderID)))
        card.setAccessibilityHelp(L10n.t(.folderContentsHelp))
        cardShadowView.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: cardShadowView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: cardShadowView.trailingAnchor),
            card.topAnchor.constraint(equalTo: cardShadowView.topAnchor),
            card.bottomAnchor.constraint(equalTo: cardShadowView.bottomAnchor),
        ])
        visualCardView = card
        root.cardView = cardShadowView

        let dissolveButton = NSButton(
            title: L10n.t(.dissolveFolder), target: self, action: #selector(dissolveTapped)
        )
        self.dissolveButton = dissolveButton
        dissolveButton.bezelStyle = .rounded
        dissolveButton.setAccessibilityHelp(L10n.t(.dissolveFolder))
        card.addSubview(dissolveButton)
        dissolveButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dissolveButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            dissolveButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
        ])

        let renameButton = NSButton(
            title: L10n.t(.rename), target: self, action: #selector(renameTapped)
        )
        self.renameButton = renameButton
        renameButton.bezelStyle = .rounded
        renameButton.setAccessibilityHelp(L10n.t(.renameFolderHelp))
        card.addSubview(renameButton)
        renameButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            renameButton.trailingAnchor.constraint(equalTo: dissolveButton.leadingAnchor, constant: -8),
            renameButton.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
        ])

        titleLabel = NSTextField(labelWithString: store.folderName(for: folderID))
        titleLabel.font = .boldSystemFont(ofSize: 24)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityLabel(L10n.format(.folderLabel, store.folderName(for: folderID)))
        card.addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            titleLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: renameButton.leadingAnchor, constant: -16),
        ])

        // 子项网格: 可垂直滚动,左右保留安全边距,避免子项超出容量或操作栏重叠。
        collectionView = ClickableCollectionView()
        let folderLayout = PagingGridLayout(
            columns: panelMetrics.columns, rows: panelMetrics.rows,
            cellSize: panelMetrics.cellSize, iconSize: CGFloat(folderIconSize),
            horizontalSpacing: panelMetrics.spacing, verticalSpacing: panelMetrics.spacing
        )
        folderLayout.mode = .search
        collectionView.collectionViewLayout = folderLayout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.register(AppCellView.self, forItemWithIdentifier: AppCellView.identifier)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = collectionView
        // 关键: 关闭文档视图 autoresizing,否则分页布局会被拉回可视宽度。
        collectionView.autoresizingMask = []
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            scrollView.topAnchor.constraint(equalTo: card.topAnchor, constant: 56),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])

        dataSource = NSCollectionViewDiffableDataSource<Int, DisplayModel.DisplayItem>(
            collectionView: collectionView
        ) { [weak self] _, indexPath, item in
            guard let self else { return nil }
            let cell = collectionView.makeItem(
                withIdentifier: AppCellView.identifier, for: indexPath
            ) as? AppCellView
            guard let cell else { return nil }
            switch item {
            case .app(let id):
                cell.configure(
                    displayName: store.displayName(for: id),
                    colorIndex: stableColorIndex(id.rawValue),
                    accessibilityHint: L10n.format(.launchApp, store.displayName(for: id)),
                    appID: id,
                    pointSize: folderIconSize,
                    iconProvider: iconProvider
                )
            case .folder:
                break
            }
            return cell
        }

        collectionView.onClick = { [weak self] point in
            guard let self,
                  let local = self.collectionView?.convert(point, from: nil),
                  let indexPath = self.collectionView?.indexPathForItem(at: local),
                  let item = self.dataSource?.itemIdentifier(for: indexPath),
                  case .app(let id) = item else { return }
            self.store.launch(id)
        }
        collectionView.onDragBegin = { [weak self] point in
            self?.beginDrag(at: point)
        }
        collectionView.onDragMove = { [weak self] point in
            self?.updateDrag(at: point)
        }
        collectionView.onDragEnd = { [weak self] point in
            self?.endDrag(at: point)
        }

        view = root
        refresh()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateDocumentFrame()
    }

    private func folderRootWindowDidChange() {
        removeObservers()
        guard let window = view.window else { return }

        dataObserverToken = store.addDataObserver { [weak self] in
            self?.storeDidChange()
        }
        orderOutObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSApp.modalWindow == nil, window.attachedSheet == nil else { return }
                self?.closeFolder()
            }
        }
    }

    private func removeObservers() {
        if let dataObserverToken {
            store.removeDataObserver(dataObserverToken)
            self.dataObserverToken = nil
        }
        if let orderOutObserver {
            NotificationCenter.default.removeObserver(orderOutObserver)
            self.orderOutObserver = nil
        }
    }

    private func storeDidChange() {
        guard !isClosing else { return }
        refresh()
    }

    private func refreshLocalizedPresentation(folderName: String? = nil) {
        let name = folderName ?? store.folderName(for: folderID)
        titleLabel.stringValue = name
        titleLabel.setAccessibilityLabel(L10n.format(.folderLabel, name))
        visualCardView?.setAccessibilityLabel(L10n.format(.folderLabel, name))
        visualCardView?.setAccessibilityHelp(L10n.t(.folderContentsHelp))
        dissolveButton?.title = L10n.t(.dissolveFolder)
        dissolveButton?.setAccessibilityHelp(L10n.t(.dissolveFolder))
        renameButton?.title = L10n.t(.rename)
        renameButton?.setAccessibilityHelp(L10n.t(.renameFolderHelp))
    }

    private func refresh() {
        guard isViewLoaded, !folderExitHandedOff else { return }
        guard let children = store.folderChildren(folderID) else {
            closeFolder()
            return
        }

        refreshLocalizedPresentation()
        if children == displayedChildren {
            // 仅元数据/本地化变化(重命名/自定义名/目录名/语言/图标到达):
            // Diffable 对同 identity cell 复用后不再调用数据源闭包,
            // 只重配置可见 cell;不 reloadData、不重启图标任务。
            reconfigureVisibleCells()
        } else {
            displayedChildren = children
            var snapshot = NSDiffableDataSourceSnapshot<Int, DisplayModel.DisplayItem>()
            snapshot.appendSections([0])
            snapshot.appendItems(children.map(DisplayModel.DisplayItem.app), toSection: 0)
            dataSource.apply(snapshot, animatingDifferences: false)
            // 结构变化后显式落定文档高度。
            view.layoutSubtreeIfNeeded()
            updateDocumentFrame()
        }
        resetDrag()
    }

    /// 元数据/本地化变化时只刷新可见 cell 的文本与无障碍(结构不变)。
    private func reconfigureVisibleCells() {
        for cell in collectionView.visibleItems() {
            guard let appCell = cell as? AppCellView,
                  let indexPath = collectionView.indexPath(for: cell),
                  let item = dataSource.itemIdentifier(for: indexPath),
                  case .app(let id) = item else { continue }
            appCell.reapplyMetadata(
                displayName: store.displayName(for: id),
                accessibilityHint: L10n.format(.launchApp, store.displayName(for: id))
            )
        }
    }

    private func updateDocumentFrame() {
        guard let layout = collectionView.collectionViewLayout as? PagingGridLayout else { return }
        let size = layout.collectionViewContentSize
        guard size.width > 0, size.height > 0 else { return }
        if collectionView.frame.size != size {
            collectionView.setDocumentSize(size)
        }
    }

    private func beginDrag(at point: NSPoint) {
        guard !isClosing, !folderExitHandedOff else { return }
        let local = collectionView.convert(point, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: local),
              let item = dataSource.itemIdentifier(for: indexPath),
              case .app(let app) = item,
              let sourceIndex = displayedChildren.firstIndex(of: app) else {
            resetDrag()
            return
        }
        draggingApp = app
        draggingSourceIndex = sourceIndex
        draggingOutside = !folderInteractionRect.contains(view.convert(point, from: nil))
        dragOverlay.configure(
            label: store.displayName(for: app),
            sourceImage: (collectionView.item(at: indexPath) as? AppCellView)?.visibleIconImage
        )
        view.layer?.addSublayer(dragOverlay.layer)
        view.layer?.addSublayer(insertionIndicator.layer)
        (collectionView.item(at: indexPath) as? AppCellView)?.setDragSourceHidden(true)
        setTrailingSlotReservation(true)
        dragOverlay.move(to: point, in: view)
        updateInsertionIndicator(at: point)
    }

    private func updateDrag(at point: NSPoint) {
        if folderExitHandedOff {
            onDragExitMove?(point)
            return
        }
        guard let app = draggingApp else { return }
        draggingOutside = !folderInteractionRect.contains(view.convert(point, from: nil))
        if draggingOutside {
            handoffFolderDrag(at: point)
            onDragExitMove?(point)
            return
        }
        dragOverlay.move(to: point, in: view)
        setSourceHidden(true, app: app)
        updateInsertionIndicator(at: point)
    }

    private func endDrag(at point: NSPoint) {
        if folderExitHandedOff {
            requestFolderExitDrop(at: point)
            return
        }
        guard let app = draggingApp, let sourceIndex = draggingSourceIndex else {
            resetDrag()
            return
        }
        let outside = draggingOutside
            || !folderInteractionRect.contains(view.convert(point, from: nil))

        if outside {
            handoffFolderDrag(at: point)
            guard folderExitHandedOff else { return }
            requestFolderExitDrop(at: point)
            return
        }

        guard let gap = folderDropGap(at: point) else {
            resetDrag()
            return
        }
        resetDrag()
        // gap 是原列表索引;源项移除后,其后的 gap 要左移一位。
        let destination = gap > sourceIndex ? gap - 1 : gap
        guard destination != sourceIndex else { return }
        store.reorderFolderApp(app: app, in: folderID, toIndex: destination)
    }

    /// mouseUp 只发起 moveOutOfFolder；Store 回执到达前保持隐藏 chrome 和专用 session。
    private func requestFolderExitDrop(at point: NSPoint) {
        guard folderExitLifecycle.awaitResult() else { return }
        let completion: (Bool) -> Void = { [weak self] committed in
            self?.completeFolderExit(committed)
        }
        guard let onDragExitEnd else {
            completion(false)
            return
        }
        onDragExitEnd(point, completion)
    }

    private func completeFolderExit(_ committed: Bool) {
        guard folderExitLifecycle.resolve(committed) else { return }
        resetDrag()
        if committed {
            closeFolder()
        } else {
            // 回执失败: 保留文件夹、恢复 chrome/源图标，并重新接收交互。
            setFolderChromeVisible(true)
            refresh()
        }
    }

    /// 文件夹卡片的交互边界。越过卡片后保持 folder-exit session 直到 mouseUp。
    private var folderInteractionRect: NSRect {
        guard let cardShadowView else { return view.bounds }
        return cardShadowView.convert(cardShadowView.bounds, to: view)
    }

    private var folderIconSize: Int {
        panelMetrics.iconPointSize(for: store.iconSize)
    }

    /// 清理文件夹局部 layer, 但不提交 store 变更。
    private func clearLocalDragVisuals() {
        if let app = draggingApp {
            setSourceHidden(false, app: app)
        }
        dragOverlay.layer.removeFromSuperlayer()
        insertionIndicator.hide()
        insertionIndicator.layer.removeFromSuperlayer()
        draggingApp = nil
        draggingSourceIndex = nil
    }

    /// 只隐藏文件夹 chrome, 保留根视图接收原 mouse session 的后续事件。
    private func setFolderChromeVisible(_ visible: Bool) {
        // 不能在 mouseDown -> mouseUp 的同一拖拽会话中隐藏 cardShadowView：
        // collectionView 是它的子视图，祖先 isHidden 后 AppKit 会中断原事件接收链，
        // mouseUp 无法到达，主网格 overlay/插入线会永久停留，看起来像应用卡死。
        // 保持视图层级参与事件分发，仅将视觉透明；提交成功后再由 closeFolderView 移除。
        cardShadowView?.isHidden = false
        cardShadowView?.alphaValue = visible ? 1 : 0
        rootView?.layer?.backgroundColor = visible
            ? NSColor.black.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
    }

    private func handoffFolderDrag(at point: NSPoint) {
        guard !folderExitHandedOff,
              let app = draggingApp,
              folderExitLifecycle.begin() else { return }
        let sourceImage = (collectionView.item(
            at: IndexPath(item: draggingSourceIndex ?? 0, section: 0)
        ) as? AppCellView)?.visibleIconImage
        clearLocalDragVisuals()
        draggingOutside = true
        setFolderChromeVisible(false)
        let started = onDragExit?(app, folderID, sourceImage, point) ?? false
        guard started else {
            folderExitLifecycle.cancel()
            setFolderChromeVisible(true)
            refresh()
            return
        }
    }

    /// 将鼠标点映射到当前可见子项的 gap,支持单元格之间和末尾空槽。
    private func folderDropGap(at point: NSPoint) -> Int? {
        guard !displayedChildren.isEmpty,
              let layout = collectionView.collectionViewLayout as? PagingGridLayout else {
            return nil
        }
        let local = collectionView.convert(point, from: nil)
        guard collectionView.bounds.contains(local) else { return nil }

        let dropGeometry = FolderDropGeometry(
            geometry: layout.liveGeometry,
            itemCount: displayedChildren.count
        )
        return dropGeometry.gap(for: local)
    }

    private func resetDrag() {
        clearLocalDragVisuals()
        setTrailingSlotReservation(false)
        draggingOutside = false
        folderExitLifecycle.cancel()
    }

    /// 由窗口控制器在主拖拽 session 取消/teardown 后调用, 恢复文件夹视觉。
    func restoreFolderAfterDragCancellation() {
        guard folderExitHandedOff else { return }
        resetDrag()
        setFolderChromeVisible(true)
        refresh()
    }

    /// 关闭文件夹前取消其局部或已 handoff 的视觉 session。
    func cancelActiveDrag() {
        let wasHandedOff = folderExitHandedOff
        resetDrag()
        if wasHandedOff {
            setFolderChromeVisible(true)
        }
    }

    private func setSourceHidden(_ hidden: Bool, app: AppID) {
        guard let index = displayedChildren.firstIndex(of: app),
              let cell = collectionView.item(at: IndexPath(item: index, section: 0)) as? AppCellView else {
            return
        }
        cell.setDragSourceHidden(hidden)
    }

    private func updateInsertionIndicator(at point: NSPoint) {
        guard let gap = folderDropGap(at: point),
              let frame = insertionSlotFrame(forGap: gap) else {
            insertionIndicator.hide()
            return
        }
        insertionIndicator.show(at: view.convert(frame, from: collectionView))
    }

    private func insertionSlotFrame(forGap gap: Int) -> NSRect? {
        guard !displayedChildren.isEmpty,
              let layout = collectionView.collectionViewLayout as? PagingGridLayout else {
            return nil
        }
        let bounded = min(max(0, gap), displayedChildren.count)
        let dropGeometry = FolderDropGeometry(
            geometry: layout.liveGeometry,
            itemCount: displayedChildren.count
        )
        if bounded < displayedChildren.count {
            return layout.layoutAttributesForItem(
                at: IndexPath(item: bounded, section: 0)
            )?.frame ?? dropGeometry.frame(forGap: bounded)
        }
        return dropGeometry.frame(forGap: bounded)
    }

    /// During a local folder drag, reserve the virtual trailing slot in the
    /// search document so its insertion frame remains scrollable and visible.
    private func setTrailingSlotReservation(_ reserved: Bool) {
        guard let layout = collectionView?.collectionViewLayout as? PagingGridLayout,
              layout.reservesSearchTrailingSlot != reserved else {
            return
        }
        layout.reservesSearchTrailingSlot = reserved
        collectionView.layoutSubtreeIfNeeded()
        updateDocumentFrame()
    }

    private func closeFolder() {
        // folder-exit mouseUp 在回执前不能走普通关闭路径。
        guard !isClosing, !folderExitLifecycle.isAwaitingResult else { return }
        isClosing = true
        resetDrag()
        onBack?()
    }

    @objc private func renameTapped() {
        guard store.folderChildren(folderID) != nil else {
            closeFolder()
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.t(.rename)
        alert.informativeText = store.folderName(for: folderID)
        let field = NSTextField(string: store.folderName(for: folderID))
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t(.ok))
        alert.addButton(withTitle: L10n.t(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let completingStore = store as? any LayoutMutationCompleting {
            renameButton.isEnabled = false
            completingStore.renameFolder(folderID, to: name) { [weak self] committed in
                guard let self else { return }
                self.renameButton.isEnabled = true
                if committed {
                    self.refreshLocalizedPresentation(folderName: name)
                } else {
                    self.refresh()
                }
            }
        } else {
            store.renameFolder(folderID, to: name)
            refreshLocalizedPresentation(folderName: name)
        }
    }

    @objc private func dissolveTapped() {
        guard store.folderChildren(folderID) != nil else {
            closeFolder()
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.t(.dissolveFolder)
        alert.informativeText = store.folderName(for: folderID)
        alert.addButton(withTitle: L10n.t(.ok))
        alert.addButton(withTitle: L10n.t(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let completingStore = store as? any LayoutMutationCompleting {
            dissolveButton.isEnabled = false
            completingStore.dissolveFolder(folderID) { [weak self] committed in
                guard let self else { return }
                self.dissolveButton.isEnabled = true
                if committed {
                    self.closeFolder()
                } else {
                    self.refresh()
                }
            }
        } else {
            store.dissolveFolder(folderID)
            closeFolder()
        }
    }

    private func stableColorIndex(_ key: String) -> Int {
        abs(key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 12
    }
}

/// 文件夹面板的固定几何契约, 与主网格配置解耦。
struct FolderPanelMetrics: Equatable {
    static let cardSize = CGSize(width: 420, height: 440)
    static let columns = 3
    static let rows = 3
    static let cellSize: CGFloat = 96
    static let spacing: CGFloat = 20
    static let iconSizeLimit = 80

    static func iconPointSize(for configuredSize: Int) -> Int {
        min(max(16, configuredSize), iconSizeLimit)
    }
}

private final class FolderRootView: NSView {
    var onWindowChange: (() -> Void)?
    var onOutsideClick: (() -> Void)?
    weak var cardView: NSView?

    override func mouseDown(with event: NSEvent) {
        guard let cardView else { return }
        let point = cardView.convert(event.locationInWindow, from: nil)
        guard !cardView.bounds.contains(point) else { return }
        onOutsideClick?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}
