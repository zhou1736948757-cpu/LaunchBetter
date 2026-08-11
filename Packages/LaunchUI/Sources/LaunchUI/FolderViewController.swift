import AppKit
import LaunchCore

/// 文件夹视图: 显示文件夹内应用(单页网格),并承接文件夹内的局部操作。
@MainActor
final class FolderViewController: NSViewController, NSTextFieldDelegate {
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
    private var titleLabel: FolderTitleView!
    private var editField: NSTextField?
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

        // 标题: 居中, 长按重命名(无可见 Rename/Dissolve 按钮)。
        // FolderTitleView 是 NSView 容器: 一定接收 mouseDown, 自实现长按进入编辑。
        titleLabel = FolderTitleView(frame: .zero)
        titleLabel.text = store.folderName(for: folderID)
        titleLabel.titleFont = .boldSystemFont(ofSize: 24)
        titleLabel.onPressFeedback = { [weak self] pressed in
            self?.applyTitlePressFeedback(pressed)
        }
        titleLabel.onRenameActivate = { [weak self] in
            self?.beginTitleEditing()
        }
        card.addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            titleLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -24),
        ])

        // 子项网格: 可垂直滚动,左右保留安全边距,避免子项超出容量或操作栏重叠。
        collectionView = ClickableCollectionView()
        let folderLayout = PagingGridLayout(
            columns: panelMetrics.columns, rows: panelMetrics.rows,
            cellSize: panelMetrics.cellSize, iconSize: CGFloat(folderIconSize),
            horizontalSpacing: panelMetrics.spacing, verticalSpacing: panelMetrics.spacing
        )
        // 文件夹滚动区已经在卡片标题/操作栏下方, 不共享启动器搜索框的 chrome 保留区。
        folderLayout.setContentInsets(top: 0, bottom: 0)
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
        titleLabel.text = name
        visualCardView?.setAccessibilityLabel(L10n.format(.folderLabel, name))
        visualCardView?.setAccessibilityHelp(L10n.t(.folderContentsHelp))
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
        beginTitleEditing()
    }

    /// 标题按下/恢复的克制反馈(不弹、不缩整个卡片)。
    private func applyTitlePressFeedback(_ pressed: Bool) {
        guard !isClosing else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if pressed {
            titleLabel.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.98, y: 0.98))
            titleLabel.alphaValue = 0.75
        } else {
            titleLabel.layer?.setAffineTransform(.identity)
            titleLabel.alphaValue = 1
        }
        CATransaction.commit()
    }

    /// 长按标题 → 内联编辑(与标题同几何, 无跳变)。
    private func beginTitleEditing() {
        guard editField == nil,
              let card = visualCardView,
              store.folderChildren(folderID) != nil else { return }
        // 先落定标题约束, 保证 editor 与已解析的标题 frame 完全一致(避免小竖框/跳变)。
        card.layoutSubtreeIfNeeded()
        titleLabel.layoutSubtreeIfNeeded()

        let editor = NSTextField(frame: titleLabel.frame)
        editor.stringValue = titleLabel.text
        editor.font = titleLabel.titleFont
        editor.alignment = .center
        editor.isBordered = false
        editor.isBezeled = false
        editor.drawsBackground = false
        editor.textColor = .labelColor
        editor.focusRingType = .none
        editor.delegate = self
        editor.autoresizingMask = []
        card.addSubview(editor, positioned: .above, relativeTo: titleLabel)
        titleLabel.isHidden = true
        applyTitlePressFeedback(false)
        editField = editor
        view.window?.makeFirstResponder(editor)
        editor.currentEditor()?.selectAll(nil)
    }

    /// 结束内联编辑。commit=false 取消并恢复原标题。
    private func endTitleEditing(commit: Bool) {
        guard let editor = editField else { return }
        editField = nil
        let candidate = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.removeFromSuperview()
        titleLabel.isHidden = false

        guard commit else { return }
        guard !candidate.isEmpty else {
            refreshLocalizedPresentation()
            return
        }
        guard candidate != store.folderName(for: folderID) else { return }

        if let completingStore = store as? any LayoutMutationCompleting {
            completingStore.renameFolder(folderID, to: candidate) { [weak self] committed in
                guard let self else { return }
                if committed {
                    self.refreshLocalizedPresentation(folderName: candidate)
                } else {
                    // 持久化失败: 恢复权威存储名, 不假装成功。
                    self.refreshLocalizedPresentation()
                    self.refresh()
                }
            }
        } else {
            store.renameFolder(folderID, to: candidate)
            refreshLocalizedPresentation(folderName: candidate)
        }
    }

    // MARK: - NSTextFieldDelegate(内联重命名)

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            endTitleEditing(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endTitleEditing(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // 失焦(含 Enter 触发的 resign) → 仍处于编辑状态则提交有效名称。
        guard editField != nil else { return }
        endTitleEditing(commit: true)
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

/// 文件夹标题文本(纯 label 样式 + 无障碍重命名动作)。
/// 手势由 FolderTitleView 负责: NSTextField 的 cell 可能吞掉 mouseDown,
/// NSPressGestureRecognizer 挂 label 上不可靠。
final class FolderTitleLabel: NSTextField {
    /// 无障碍动作触发重命名。
    var onRenameActivate: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 显式走 init(frame:) 设置全部 label 样式:
        // NSTextField(string:) / labelWithString 是 ObjC convenience init,
        // 会绕过子类 override, 导致显示成默认可编辑的带边框小框。
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        textColor = .labelColor
        focusRingType = .none
        alignment = .center
        lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 无障碍: 移除可见按钮后仍可重命名。
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let action = NSAccessibilityCustomAction(
            name: L10n.t(.renameFolderHelp),
            target: self,
            selector: #selector(renameFromAccessibility)
        )
        return [action]
    }

    @objc private func renameFromAccessibility() {
        onRenameActivate?()
    }
}

/// 文件夹标题容器: 接收 mouseDown(NSView 一定收到, 不依赖 NSTextField cell),
/// 自实现长按(minimumPressDuration / allowableMovement)进入内联重命名。
final class FolderTitleView: NSView {
    /// 按压反馈(按下 true / 恢复 false)。
    var onPressFeedback: ((Bool) -> Void)?
    /// 长按达标 → 激活内联重命名。
    var onRenameActivate: (() -> Void)?

    let label = FolderTitleLabel(frame: .zero)

    private let minimumPressDuration: TimeInterval = 0.5
    private let allowableMovement: CGFloat = 6
    private var pressStartPoint: CGPoint?
    private var pressTimer: Timer?
    private var pointerInside = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.setAccessibilityLabel(L10n.format(.folderLabel, newValue))
        }
    }

    var titleFont: NSFont {
        get { label.font ?? .systemFont(ofSize: 13) }
        set { label.font = newValue }
    }

    override func mouseDown(with event: NSEvent) {
        pointerInside = true
        pressStartPoint = convert(event.locationInWindow, from: nil)
        onPressFeedback?(true)
        schedulePressCheck()
    }

    private func schedulePressCheck() {
        pressTimer?.invalidate()
        let timer = Timer(timeInterval: minimumPressDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activateRenameIfStillPressing()
            }
        }
        // eventTracking: 按住拖动期间仍触发。
        RunLoop.main.add(timer, forMode: .eventTracking)
        pressTimer = timer
    }

    private func activateRenameIfStillPressing() {
        guard pointerInside else { return }
        cancelPress()
        onRenameActivate?()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let start = pressStartPoint {
            let dx = point.x - start.x
            let dy = point.y - start.y
            if (dx * dx + dy * dy) > allowableMovement * allowableMovement {
                pointerInside = false
                onPressFeedback?(false)
                cancelPress()
                return
            }
        }
        if !bounds.contains(point) {
            pointerInside = false
            onPressFeedback?(false)
            cancelPress()
        }
    }

    override func mouseUp(with event: NSEvent) {
        pointerInside = false
        onPressFeedback?(false)
        cancelPress()
    }

    private func cancelPress() {
        pressTimer?.invalidate()
        pressTimer = nil
        pressStartPoint = nil
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
