import AppKit
import LaunchCore

/// Pure mapping/apply seam for the Folder card and its settled dim surface.
///
/// The apply path never writes transition-owned opacity or shadow values. This
/// lets live accessibility changes update material while Folder motion keeps
/// consuming its existing presentation state.
struct FolderViewAppearance: Equatable, Sendable {
    let surfaceTreatment: AccessibilitySurfaceTreatment
    let surfaceOpacity: Float
    let boundaryTreatment: AccessibilityBoundaryTreatment
    let foregroundSeparation: AccessibilityForegroundSeparation
    let dimOpacity: Float

    static func make(for policy: AccessibilityMaterialPolicy) -> Self {
        Self(
            surfaceTreatment: policy.surfaceTreatment,
            surfaceOpacity: policy.surfaceOpacity,
            boundaryTreatment: policy.boundaryTreatment,
            foregroundSeparation: policy.foregroundSeparation,
            dimOpacity: policy.emphasizesBoundary ? 0.22 : 0.18
        )
    }

    @MainActor
    static func apply(
        _ appearance: Self,
        to card: NSVisualEffectView,
        dimLayer: CALayer
    ) {
        card.wantsLayer = true
        card.blendingMode = .withinWindow
        card.state = .active
        card.isEmphasized = appearance.foregroundSeparation == .enhanced

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch appearance.surfaceTreatment {
        case .translucent:
            card.material = .hudWindow
            card.layer?.backgroundColor = nil
        case .opaque:
            // `.windowBackground` is a public AppKit surface that does not
            // require blur to remain legible under Reduce Transparency.
            card.material = .windowBackground
            card.layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(CGFloat(appearance.surfaceOpacity))
                .cgColor
        }

        switch appearance.boundaryTreatment {
        case .standard:
            card.layer?.borderWidth = 0
            card.layer?.borderColor = nil
        case .emphasized:
            card.layer?.borderWidth = 1
            card.layer?.borderColor = NSColor.separatorColor
                .withAlphaComponent(0.85)
                .cgColor
        }

        // Keep the transition's current opacity untouched; only the settled
        // dim color changes with the view policy.
        dimLayer.backgroundColor = NSColor.black
            .withAlphaComponent(CGFloat(appearance.dimOpacity))
            .cgColor
        CATransaction.commit()
    }
}

/// 文件夹视图: 显示文件夹内应用(单页网格),并承接文件夹内的局部操作。
@MainActor
final class FolderViewController: NSViewController, NSTextFieldDelegate {
    private let panelMetrics = FolderPanelMetrics.self
    private let store: any LauncherStoring
    private let iconProvider: (any IconImageProviding)?
    private let folderID: FolderID
    private var accessibilityMaterialPolicy: AccessibilityMaterialPolicy

    var onBack: (() -> Void)?
    /// 文件夹拖拽越过卡片后交给窗口控制器, 后续事件仍来自同一 mouse session。
    var onDragExit: ((AppID, FolderID, CGImage?, NSPoint) -> Bool)?
    var onDragExitMove: ((NSPoint) -> Void)?
    var onDragExitEnd: ((NSPoint, @escaping (Bool) -> Void) -> Void)?

    private var rootView: FolderRootView!
    private var cardShadowView: NSView!
    private var visualCardView: NSVisualEffectView!
    private let transitionDimLayer = CALayer()
    private var titleLabel: FolderTitleView!
    private var editField: NSTextField?
    private var collectionView: ClickableCollectionView!
    private var scrollView: NSScrollView!
    private var dataSource: NSCollectionViewDiffableDataSource<Int, DisplayModel.DisplayItem>!
    private var displayedChildren: [AppID] = []

    private var dataObserverToken: UUID?
    private var orderOutObserver: NSObjectProtocol?
    private var isClosing = false
    private var transitionLayoutRevision: UInt64 = 0
    private var lastTransitionRootBounds: CGRect = .null
    private var lastTransitionCardFrame: CGRect = .null

    private let titleEditorHorizontalPadding = FolderTitleEditingMetrics.editorHorizontalPadding

    private struct TitleEditorState {
        let string: String
        let selectedRange: NSRange
    }

    private var lastValidTitleEditorState: TitleEditorState?
    private var isRestoringTitleEditorState = false

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
        self.accessibilityMaterialPolicy = AccessibilityMaterialPolicy(
            snapshot: MotionEnvironment.liveSnapshot()
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = FolderRootView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        transitionDimLayer.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        transitionDimLayer.frame = root.bounds
        root.layer?.addSublayer(transitionDimLayer)
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

        let card = FolderCardView()
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
        applyAccessibilityMaterialPolicy(accessibilityMaterialPolicy)

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
        scrollView.wantsLayer = true
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
        collectionView.onDragBeginWithSource = { [weak self] sourcePoint, currentPoint in
            self?.beginDrag(from: sourcePoint, at: currentPoint)
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

    /// Updates only the card/dim material properties. Folder transition layers
    /// continue to own their current opacity and existing soft shadow weight.
    func applyAccessibilityMaterialPolicy(_ policy: AccessibilityMaterialPolicy) {
        accessibilityMaterialPolicy = policy
        guard isViewLoaded, let card = visualCardView else { return }
        FolderViewAppearance.apply(
            FolderViewAppearance.make(for: policy),
            to: card,
            dimLayer: transitionDimLayer
        )
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        transitionDimLayer.frame = rootView.bounds
        let rootBounds = rootView.bounds
        let cardFrame = cardShadowView?.frame ?? .zero
        if rootBounds != lastTransitionRootBounds || cardFrame != lastTransitionCardFrame {
            transitionLayoutRevision &+= 1
            lastTransitionRootBounds = rootBounds
            lastTransitionCardFrame = cardFrame
        }
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

    private func beginDrag(from sourcePoint: NSPoint, at currentPoint: NSPoint) {
        guard !isClosing, !folderExitHandedOff else { return }
        guard let selection = DragSourceAnchorResolver.resolve(
            sourcePoint: sourcePoint,
            currentPoint: currentPoint,
            valueAt: { (sourcePoint: NSPoint) -> (IndexPath, DisplayModel.DisplayItem)? in
                let local = collectionView.convert(sourcePoint, from: nil)
                guard let indexPath = collectionView.indexPathForItem(at: local),
                      let item = dataSource.itemIdentifier(for: indexPath) else {
                    return nil
                }
                return (indexPath, item)
            }
        ),
              case .app(let app) = selection.source.1,
              let sourceIndex = displayedChildren.firstIndex(of: app) else {
            resetDrag()
            return
        }
        let indexPath = selection.source.0
        let point = selection.currentPoint
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        transitionDimLayer.opacity = visible ? 1 : 0
        CATransaction.commit()
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

    /// Auto Layout 完成一次真实 card frame 后暴露 Folder transition target。
    /// 调用方应在动画开始前调用；动画帧只消费返回的 CALayer 引用。
    func transitionTarget(in targetView: NSView) -> FolderTransitionTarget? {
        guard isViewLoaded, view.window === targetView.window,
              let cardShadowView,
              let cardLayer = cardShadowView.layer,
              let materialLayer = visualCardView?.layer else {
            return nil
        }
        view.layoutSubtreeIfNeeded()
        let frame = cardShadowView.convert(cardShadowView.bounds, to: targetView)
        guard frame.width > 0, frame.height > 0 else { return nil }

        let revision = transitionLayoutRevision
        let targetLayer = transitionDimLayer
        let contentLayers = [titleLabel?.layer, scrollView?.layer].compactMap { $0 }
        return FolderTransitionTarget(
            frameInContentView: frame,
            cornerRadius: materialLayer.cornerRadius,
            baseShadowOpacity: cardLayer.shadowOpacity,
            dimLayer: targetLayer,
            cardLayer: cardLayer,
            materialLayer: materialLayer,
            contentLayers: contentLayers,
            isCurrent: { [weak self, weak targetView] in
                guard let self, let targetView else { return false }
                return self.view.window === targetView.window
                    && self.transitionLayoutRevision == revision
            }
        )
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

        let titleFrame = titleLabel.frame
        let titleText = titleLabel.text
        let titleFont = titleLabel.titleFont
        let editorFrame = titleEditorFrame(
            for: titleText,
            font: titleFont,
            in: card,
            preserving: titleFrame
        )

        let editor = NSTextField(frame: editorFrame)
        editor.stringValue = titleText
        editor.font = titleFont
        editor.alignment = .center
        editor.isBordered = false
        editor.isBezeled = false
        editor.drawsBackground = false
        editor.textColor = .labelColor
        editor.focusRingType = .none
        editor.usesSingleLineMode = true
        editor.delegate = self
        editor.autoresizingMask = []
        // 编辑态视觉提示: 浅色圆角底, 明确"已进入可编辑状态"; 聚焦后 field editor
        // 提供光标闪烁。
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 6
        editor.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        card.addSubview(editor, positioned: .above, relativeTo: titleLabel)
        titleLabel.isHidden = true
        applyTitlePressFeedback(false)
        lastValidTitleEditorState = TitleEditorState(
            string: titleText,
            selectedRange: NSRange(location: 0, length: (titleText as NSString).length)
        )
        editField = editor
        // 长按仍在鼠标事件序列中(mouseUp 未到)。延迟到事件序列结束后再聚焦,
        // 避免在途 mouseUp 打断 first responder / field editor。
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let editor = self.editField,
                      editor.superview != nil else { return }
                self.madeTitleEditorFirstResponder =
                    self.view.window?.makeFirstResponder(editor) ?? false
                editor.currentEditor()?.selectAll(nil)
                self.rememberLastValidTitleEditorState(for: editor)
            }
        }
    }

    private func titleEditorFrame(
        for text: String,
        font: NSFont,
        in card: NSView,
        preserving referenceFrame: NSRect
    ) -> NSRect {
        let measuredTextWidth = FolderTitleEditingMetrics.renderedTextWidth(text, font: font)
        let availableWidth = FolderTitleEditingMetrics.availableEditorWidth(cardWidth: card.bounds.width)
        let editorWidth = min(
            measuredTextWidth + titleEditorHorizontalPadding,
            availableWidth
        )
        return NSRect(
            x: referenceFrame.midX - editorWidth / 2,
            y: referenceFrame.minY,
            width: editorWidth,
            height: referenceFrame.height
        )
    }

    /// 诊断: 最近一次 makeFirstResponder 是否成功。
    private var madeTitleEditorFirstResponder = false

    /// 诊断: 手动进入标题编辑(供 probe 验证聚焦/光标)。
    func startTitleEditingForDiagnostic() {
        beginTitleEditing()
    }

    /// 诊断: 编辑状态(firstResponder / field editor / frame / editable)。
    func diagnosticTitleEditState() -> String {
        guard let editor = editField else {
            return "no-editing title=\(titleLabel.text) titleFrame=\(titleLabel.frame) intrinsic=\(titleLabel.intrinsicContentSize)"
        }
        let fr = view.window?.firstResponder
        let isEditor = fr === editor
        let isFieldEditor = (fr as? NSTextView) != nil
        let ce = editor.currentEditor() != nil
        let frDesc = fr.map { String(describing: type(of: $0)) } ?? "nil"
        return "editing=true madeFR=\(madeTitleEditorFirstResponder) isEditor=\(isEditor) isFieldEditor=\(isFieldEditor) fr=\(frDesc) currentEditor=\(ce) frame=\(editor.frame) editable=\(editor.isEditable) title=\(titleLabel.text) intrinsic=\(titleLabel.intrinsicContentSize)"
    }

    private func rememberLastValidTitleEditorState(for editor: NSTextField) {
        guard !isRestoringTitleEditorState else { return }
        let fallbackSelection = lastValidTitleEditorState?.selectedRange
            ?? NSRange(location: (editor.stringValue as NSString).length, length: 0)
        let selectedRange = (editor.currentEditor() as? NSTextView)?.selectedRange ?? fallbackSelection
        lastValidTitleEditorState = TitleEditorState(
            string: editor.stringValue,
            selectedRange: selectedRange
        )
    }

    private func restoreLastValidTitleEditorState(in editor: NSTextField) {
        guard let state = lastValidTitleEditorState else { return }
        isRestoringTitleEditorState = true
        defer { isRestoringTitleEditorState = false }

        let fieldEditor = editor.currentEditor() as? NSTextView
        editor.stringValue = state.string
        guard let fieldEditor else { return }
        fieldEditor.string = state.string

        let stringLength = (state.string as NSString).length
        let location = min(max(0, state.selectedRange.location), stringLength)
        let length = min(
            max(0, state.selectedRange.length),
            stringLength - location
        )
        fieldEditor.setSelectedRange(NSRange(location: location, length: length))
    }

    private func currentTitleEditorStateCanBeKept(
        _ editor: NSTextField,
        font: NSFont,
        card: NSView
    ) -> Bool {
        guard let lastValidTitleEditorState else { return false }
        let currentString = editor.stringValue
        guard !FolderTitleEditingMetrics.textFits(
            currentString,
            font: font,
            cardWidth: card.bounds.width
        ) else {
            return true
        }

        // An over-wide persisted name is not silently truncated. Deleting or
        // shortening it remains an accepted edit even while it is still over
        // the new limit; subsequent widening input is still rejected.
        let currentWidth = FolderTitleEditingMetrics.renderedTextWidth(currentString, font: font)
        let lastValidWidth = FolderTitleEditingMetrics.renderedTextWidth(
            lastValidTitleEditorState.string,
            font: font
        )
        return currentWidth < lastValidWidth
            || (
                currentWidth == lastValidWidth
                    && (currentString as NSString).length
                        < (lastValidTitleEditorState.string as NSString).length
            )
    }

    private func restoreOverWideTitleEditorIfNeeded(
        _ editor: NSTextField,
        font: NSFont,
        card: NSView
    ) {
        if let fieldEditor = editor.currentEditor() as? NSTextView, fieldEditor.hasMarkedText() {
            return
        }
        guard !FolderTitleEditingMetrics.textFits(
            editor.stringValue,
            font: font,
            cardWidth: card.bounds.width
        ) else { return }
        restoreLastValidTitleEditorState(in: editor)
    }

    private func updateTitleEditorFrame(_ editor: NSTextField, in card: NSView) {
        guard let font = editor.font else { return }
        let currentFrame = editor.frame
        let updatedFrame = titleEditorFrame(
            for: editor.stringValue,
            font: font,
            in: card,
            preserving: currentFrame
        )
        guard updatedFrame != currentFrame else { return }

        // 只改变控件 frame, 不重写 string 或重新成为 first responder。
        // 因此 field editor 的选择/光标位置保持不变; 额外恢复 NSTextView
        // 的选区以防 AppKit 在 frame 调整时重置它。
        let fieldEditor = editor.currentEditor() as? NSTextView
        let selectedRange = fieldEditor?.selectedRange
        editor.frame = updatedFrame
        if let fieldEditor, let selectedRange {
            fieldEditor.setSelectedRange(selectedRange)
        }
    }

    /// 结束内联编辑。commit=false 取消并恢复原标题。
    private func endTitleEditing(commit: Bool) {
        guard let editor = editField else { return }
        if commit, let font = editor.font, let card = visualCardView {
            restoreOverWideTitleEditorIfNeeded(editor, font: font, card: card)
        }
        editField = nil
        let candidate = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.removeFromSuperview()
        titleLabel.isHidden = false
        lastValidTitleEditorState = nil
        isRestoringTitleEditorState = false

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

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let editor = obj.object as? NSTextField,
              editor === editField else { return }
        rememberLastValidTitleEditorState(for: editor)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        shouldChangeCharactersIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard let editor = control as? NSTextField,
              editor === editField,
              let font = editor.font,
              let card = visualCardView else {
            return true
        }
        return FolderTitleEditingMetrics.allowsChange(
            currentText: textView.string,
            affectedRange: affectedCharRange,
            replacementString: replacementString,
            font: font,
            cardWidth: card.bounds.width,
            hasMarkedText: textView.hasMarkedText()
        )
    }

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

    func controlTextDidChange(_ obj: Notification) {
        guard let editor = obj.object as? NSTextField,
              editor === editField,
              let card = visualCardView,
              let font = editor.font else { return }

        let fieldEditor = editor.currentEditor() as? NSTextView
        if !isRestoringTitleEditorState, !(fieldEditor?.hasMarkedText() ?? false) {
            if currentTitleEditorStateCanBeKept(editor, font: font, card: card) {
                rememberLastValidTitleEditorState(for: editor)
            } else {
                restoreOverWideTitleEditorIfNeeded(editor, font: font, card: card)
            }
        }
        updateTitleEditorFrame(editor, in: card)
    }

    private func stableColorIndex(_ key: String) -> Int {
        abs(key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 12
    }
}

/// Folder title editing geometry and replacement policy.
///
/// The policy deliberately works on complete Swift strings. It never truncates
/// a replacement, so a rejected paste cannot leave a partial grapheme behind.
enum FolderTitleEditingMetrics {
    static let cardHorizontalInset: CGFloat = 24
    static let editorHorizontalPadding: CGFloat = 16

    static func renderedTextWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func availableEditorWidth(cardWidth: CGFloat) -> CGFloat {
        max(0, cardWidth - 2 * cardHorizontalInset)
    }

    static func maximumTextWidth(cardWidth: CGFloat) -> CGFloat {
        max(0, availableEditorWidth(cardWidth: cardWidth) - editorHorizontalPadding)
    }

    static func editorWidth(for text: String, font: NSFont, cardWidth: CGFloat) -> CGFloat {
        min(
            renderedTextWidth(text, font: font) + editorHorizontalPadding,
            availableEditorWidth(cardWidth: cardWidth)
        )
    }

    static func textFits(_ text: String, font: NSFont, cardWidth: CGFloat) -> Bool {
        renderedTextWidth(text, font: font) <= maximumTextWidth(cardWidth: cardWidth)
    }

    static func proposedString(
        currentText: String,
        affectedRange: NSRange,
        replacementString: String?
    ) -> String? {
        guard let range = Range(affectedRange, in: currentText) else { return nil }
        return currentText.replacingCharacters(
            in: range,
            with: replacementString ?? ""
        )
    }

    static func allowsChange(
        currentText: String,
        affectedRange: NSRange,
        replacementString: String?,
        font: NSFont,
        cardWidth: CGFloat,
        hasMarkedText: Bool
    ) -> Bool {
        // AppKit owns the marked-text selection while an IME composition is in
        // progress. Let it finish; controlTextDidChange validates the committed
        // result and restores the last complete state if needed.
        if hasMarkedText { return true }
        guard let proposedText = proposedString(
            currentText: currentText,
            affectedRange: affectedRange,
            replacementString: replacementString
        ) else {
            return false
        }

        if textFits(proposedText, font: font, cardWidth: cardWidth) {
            return true
        }

        // Deletion/shortening is never blocked. This also preserves an existing
        // persisted title that predates the width limit without truncating it.
        let isDeletion = (replacementString ?? "").isEmpty && affectedRange.length > 0
        let proposedWidth = renderedTextWidth(proposedText, font: font)
        let currentWidth = renderedTextWidth(currentText, font: font)
        return isDeletion || proposedWidth < currentWidth
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

/// NSVisualEffectView 作为卡片背景时可能在真实窗口命中测试中截断子视图下探。
/// 保留卡片自身作为空白区命中目标, 但让标题/滚动区收到真实鼠标事件。
private final class FolderCardView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        for subview in subviews.reversed() {
            let pointInSubview = subview.convert(point, from: self)
            if let hit = subview.hitTest(pointInSubview) {
                return hit
            }
        }
        return self
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

    private let minimumPressDuration: TimeInterval = 0.3
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

    // NSView 默认无内在尺寸: 若缺失, Auto Layout 会把本容器塌缩成很窄,
    // 标题/编辑器文字被截断(最后一个字消失)。按内部 label 撑开。
    override var intrinsicContentSize: NSSize {
        label.intrinsicContentSize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.setAccessibilityLabel(L10n.format(.folderLabel, newValue))
            invalidateIntrinsicContentSize()
        }
    }

    var titleFont: NSFont {
        get { label.font ?? .systemFont(ofSize: 13) }
        set {
            label.font = newValue
            label.invalidateIntrinsicContentSize()
            invalidateIntrinsicContentSize()
        }
    }

    /// NSTextField 的 label 子视图必须让容器接收命中, 否则 AppKit 会把
    /// mouseDown 直接交给 label, 外层长按状态机永远不会开始。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(point) else { return nil }
        return self
    }

    override var mouseDownCanMoveWindow: Bool { false }

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
        // common 覆盖 AppKit 默认模式和鼠标 tracking 模式, 真实事件循环和
        // 单元测试推进默认模式时都能触发。
        RunLoop.main.add(timer, forMode: .common)
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
