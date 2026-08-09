import AppKit
import LaunchCore

enum GridDragSourceIdentity: Equatable {
    case app(AppID)
    case folder(FolderID)

    init(item: DisplayModel.DisplayItem) {
        switch item {
        case .app(let id):
            self = .app(id)
        case .folder(let id, _):
            self = .folder(id)
        }
    }
}

/// 网格视图控制器: NSCollectionView + DiffableDataSource + 分页导航。
///
/// 两种模式:
/// - 分页模式: 每页一个 section,横向分页,滚轮/键盘翻页
/// - 搜索模式: 单 section 垂直滚动结果网格(结果可超一页容量)
///
/// 几何唯一真值: GridGeometry(PagingGridLayout 的 currentGeometry/liveGeometry),
/// 本控制器不再维护 pageWidth/itemSize/slotStep 等硬编码(Stage 1, P0)。
///
/// 分页交互(v0.1.6 PART A): NSEvent/手势状态/速度/spring 全部在
/// PagingInteractionController + PageSnapAnimator, 本控制器只做集合/数据源/
/// 搜索/页点/网格集成与唯一 scroll write 注入(§11)。
///
/// 结构变化(目录变化/搜索切换/drop 完成)才应用 snapshot(§83),
/// 禁止逐帧应用 snapshot(§132)。
@MainActor
final class GridViewController: NSViewController {
    typealias Item = DisplayModel.DisplayItem

    private let store: any LauncherStoring
    private let iconProvider: (any IconImageProviding)?
    private var collectionView: NSCollectionView!
    private var scrollView: NSScrollView!
    private var dataSource: NSCollectionViewDiffableDataSource<Int, Item>!
    private var currentPage = 0
    private var pageCount = 1
    /// 当前页(诊断)。
    var currentPageValue: Int { currentPage }

    /// 页数(诊断)。
    var pageCountValue: Int { pageCount }

    /// 分页交互控制器(v0.1.6): 手势状态 + 唯一 offset writer。
    private let paging = PagingInteractionController()

    /// 当前几何(拖拽/槽位计算用; 未 prepare 时用实时参数推算)。
    var geometry: GridGeometry {
        (collectionView.collectionViewLayout as? PagingGridLayout)?.liveGeometry
            ?? GridGeometry(
                columns: store.gridColumns, rows: store.gridRows,
                cellSize: cellSize, iconSize: iconSize,
                horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing,
                pageWidth: collectionView?.bounds.width ?? 0, pageHeight: collectionView?.bounds.height ?? 0
            )
    }

    /// 滚动诊断(翻页调试)。
    func scrollDiagnostics() -> String {
        let layout = collectionView.collectionViewLayout as? PagingGridLayout
        let content = layout?.collectionViewContentSize ?? .zero
        let doc = collectionView.frame
        let clip = collectionView.enclosingScrollView?.contentView.bounds ?? .zero
        let sections = collectionView.numberOfSections
        let items = sections > 0 ? collectionView.numberOfItems(inSection: 0) : -1
        let frames = layout?.itemFrameCount ?? -1
        return "content=\(Int(content.width))x\(Int(content.height)) docFrame=\(Int(doc.width))x\(Int(doc.height)) clipX=\(Int(clip.origin.x)) clipY=\(Int(clip.origin.y)) clipW=\(Int(clip.width)) sections=\(sections) items=\(items) frames=\(frames) prepare=\(layout?.prepareCount ?? 0)"
    }
    private var searchMode = false
    private var lastAppliedLanguage = L10n.currentLanguage
    /// 退出搜索后恢复的页码。
    private var pagedPageBeforeSearch = 0

    /// 搜索模式(诊断/拖拽开关)。
    var isSearchMode: Bool { searchMode }

    /// 点击文件夹时回调(打开文件夹视图)。
    var onOpenFolder: ((FolderID) -> Void)?

    /// 点击空白处回调(退出启动器)。
    var onClickBlank: (() -> Void)?

    /// 页码指示点容器。
    private var pageDots: NSStackView!
    private var pageDotViews: [NSView] = []

    /// 拖拽控制(由窗口控制器注入)。
    var dragController: DragController?

    /// 当前 App B 建夹目标。cell 离屏/reuse 后由 configure 恢复。
    private var createFolderTargetAppID: AppID?
    private var createFolderTargetIsActive = false

    /// 当前主网格拖拽源身份。它独立于可复用的 cell 实例。
    private var activeDragSourceIdentity: GridDragSourceIdentity?

    /// 集合视图(拖拽/诊断用)。首次访问触发 view 加载。
    var collectionViewRef: NSCollectionView {
        if collectionView == nil {
            _ = view
        }
        return collectionView
    }

    // 几何参数(唯一来源, 供 GridGeometry 构建; 与 PagingGridLayout 共享语义)
    private let cellSize: CGFloat = 96
    private let horizontalSpacing: CGFloat = 28
    private let verticalSpacing: CGFloat = 28
    private var iconSize: CGFloat { CGFloat(store.iconSize) }

    /// 上次应用的显示修订(无变化跳过 full snapshot, Stage 1 §30)。
    private var lastAppliedRevision: UInt64 = .max

    init(store: any LauncherStoring, iconProvider: (any IconImageProviding)?) {
        self.store = store
        self.iconProvider = iconProvider
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView()

        let collectionView = ClickableCollectionView()
        collectionView.collectionViewLayout = PagingGridLayout(
            columns: store.gridColumns, rows: store.gridRows,
            cellSize: cellSize, iconSize: iconSize,
            horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing
        )
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.register(AppCellView.self, forItemWithIdentifier: AppCellView.identifier)
        collectionView.onClick = { [weak self] point in
            self?.handleClick(at: point)
        }
        collectionView.onContextMenu = { [weak self] point in
            self?.contextMenu(at: point)
        }
        collectionView.onPageScroll = { [weak self] event in
            self?.handlePageScroll(event) ?? false
        }

        // 页码指示点(底部居中)
        let dots = NSStackView()
        dots.orientation = .horizontal
        dots.spacing = 8
        dots.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dots)
        NSLayoutConstraint.activate([
            dots.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            dots.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        pageDots = dots

        // 分页滚动: 集合视图必须包在 NSScrollView 中(否则 scrollToPage 是空操作,
        // 用户只能看到第一页 — 这是"看不到后两页"的根因)
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        // v0.1.6 §19: 禁用系统横向橡皮筋(避免与 LaunchBetter rubber band 双重作用);
        // 搜索模式垂直滚动不受影响。
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = collectionView
        // 关键: 关闭文档视图 autoresizing, 否则滚动视图会把它拉回可视宽度
        collectionView.autoresizingMask = []
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.collectionView = collectionView
        self.scrollView = scrollView

        configureDataSource()
        view = container
        // 必须在 view 赋值之后接线(linkView 访问 self.view 会触发 loadView 递归)
        setupPagingController()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 文档视图 frame 必须等于布局 contentSize(否则滚动范围只有一页宽)
        updateDocumentFrame()
    }

    /// 同步集合视图 frame 到布局 contentSize(分页滚动的前提; 搜索模式高度也跟随)。
    private func updateDocumentFrame() {
        guard let layout = collectionView.collectionViewLayout as? PagingGridLayout else { return }
        let size = layout.collectionViewContentSize
        if let paged = collectionView as? ClickableCollectionView {
            paged.setDocumentSize(size)
        } else if collectionView.frame.size != size {
            collectionView.frame = NSRect(origin: .zero, size: size)
        }
    }

    private func configureDataSource() {
        dataSource = NSCollectionViewDiffableDataSource<Int, Item>(
            collectionView: collectionView
        ) { [weak self] _, indexPath, item in
            guard let self else { return nil }
            let cell = collectionView.makeItem(
                withIdentifier: AppCellView.identifier, for: indexPath
            ) as? AppCellView
            configure(cell, with: item)
            return cell
        }
        collectionView.dataSource = dataSource
    }

    private func configure(_ cell: AppCellView?, with item: Item) {
        guard let cell else { return }
        let pointSize = Int(iconSize)
        switch item {
        case .app(let id):
            cell.configure(
                displayName: store.displayName(for: id),
                colorIndex: stableColorIndex(id.rawValue),
                accessibilityHint: L10n.format(.launchApp, store.displayName(for: id)),
                appID: id,
                pointSize: pointSize,
                iconProvider: iconProvider
            )
            if createFolderTargetAppID == id {
                cell.setCreateFolderTargetHighlighted(true, active: createFolderTargetIsActive)
            }
        case .folder(let id, _):
            let children = store.folderChildren(id) ?? []
            cell.configureFolder(
                displayName: store.folderName(for: id),
                accessibilityHint: L10n.format(.folderLabel, store.folderName(for: id)),
                folderID: id,
                children: children,
                pointSize: pointSize,
                iconProvider: iconProvider
            )
        }
        // prepareForReuse/beginConfiguration 可能刚恢复 opacity; identity 是唯一真值。
        cell.setDragSourceHidden(isActiveDragSource(item))
    }

    private func stableColorIndex(_ key: String) -> Int {
        abs(key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 12
    }

    // MARK: - 刷新(修订跳过)

    /// 应用最新显示模型(或搜索结果)。
    /// 修订相同(目录/布局/配置/搜索均未变)时跳过 full snapshot(Stage 1 §30)。
    func refresh() {
        // Settings 结构参数变更 → 重建布局几何并重新分页(Stage 1 §14)
        let layout = gridLayout
        if store.gridColumns != layout.columns
            || store.gridRows != layout.rows
            || store.iconSize != Int(layout.iconSize) {
            applyGeometryConfig(
                columns: store.gridColumns, rows: store.gridRows, iconSize: store.iconSize
            )
            return
        }
        if store.displayRevision != lastAppliedRevision {
            lastAppliedRevision = store.displayRevision
            applyLatestData()
            if L10n.currentLanguage != lastAppliedLanguage {
                lastAppliedLanguage = L10n.currentLanguage
                // Diffable keeps cells with unchanged identities. A language-only
                // revision must still rebuild labels and accessibility strings.
                collectionView.reloadData()
            }
        }
    }

    /// 强制刷新(忽略修订; 结构参数已变时由调用方使用)。
    func forceRefresh() {
        lastAppliedRevision = .max
        refresh()
    }

    private func applyLatestData() {
        if let results = store.searchResults() {
            enterSearchMode(with: results)
        } else {
            if searchMode {
                exitSearchMode()
                // 退出搜索恢复搜索前页码(Stage 1 §12)
                currentPage = min(pagedPageBeforeSearch, max(0, pageCount - 1))
            }
            applyDisplayModel(store.displayModel())
        }
    }

    // MARK: - 搜索模式

    private func enterSearchMode(with results: [Item]) {
        let wasPagedMode = !searchMode
        searchMode = true
        paging.isEnabled = false
        if wasPagedMode {
            pagedPageBeforeSearch = currentPage
        }
        gridLayout.mode = .search
        gridLayout.invalidateLayout()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(results, toSection: 0)
        pageCount = 1
        currentPage = 0
        dataSource.apply(snapshot, animatingDifferences: false)
        // 强制布局(文档高度更新), 再滚动到顶 —— viewDidLayout 依赖视图尺寸变化,
        // 搜索切换时容器尺寸不变不触发, 必须显式落定
        view.layoutSubtreeIfNeeded()
        updateDocumentFrame()
        scrollToTop()
        updatePageDots()
    }

    private func exitSearchMode() {
        guard searchMode else { return }
        searchMode = false
        paging.isEnabled = true
        gridLayout.mode = .paged
        gridLayout.invalidateLayout()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
    }

    private var gridLayout: PagingGridLayout {
        collectionView.collectionViewLayout as! PagingGridLayout
    }

    private func scrollToTop() {
        guard let scroll = collectionView.enclosingScrollView else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
    }

    private func applyDisplayModel(_ display: DisplayModel) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        for (pageIndex, page) in display.pages.enumerated() {
            snapshot.appendSections([pageIndex])
            snapshot.appendItems(page, toSection: pageIndex)
        }
        pageCount = max(1, display.pages.count)
        currentPage = min(currentPage, pageCount - 1)
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.scrollToPage(currentPage, animated: false)
        updatePageDots()
    }

    /// Settings 结构参数变更: 重建布局几何并重新分页(Stage 1 §14/§15)。
    func applyGeometryConfig(columns: Int, rows: Int, iconSize: Int) {
        let gridLayout = gridLayout
        gridLayout.update(
            columns: columns, rows: rows, iconSize: CGFloat(iconSize),
            cellSize: cellSize, horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        )
        // 参数变化 → 页容量变化 → 重新分页并回第一页
        currentPage = 0
        forceRefresh()
        // Diffable 对相同 item 复用 cell(不重新调用数据源闭包) →
        // 必须 reloadData 强制重配置, 否则 iconPointSize 停留在旧值(评审 M2)
        collectionView.reloadData()
        collectionView.scrollToPage(currentPage, animated: false)
    }

    // MARK: - 页面导航

    func goToPage(_ page: Int, animated: Bool = true) {
        guard !searchMode else { return }
        let clamped = min(max(0, page), pageCount - 1)
        if animated {
            // 动画翻页统一经 PageSnapAnimator(time-based spring, v0.1.6 §23/§31)
            paging.startSettle(toPage: clamped)
        } else {
            currentPage = clamped
            paging.jumpTo(page: clamped)
            updatePageDots()
        }
        prewarmAdjacentPages(clamped)
    }

    func nextPage() { goToPage(currentPage + 1) }
    func previousPage() { goToPage(currentPage - 1) }

    /// 相邻页图标预热(v0.1.6 §36-37): 只维护 current±1 working set, 不全量预加载。
    private func prewarmAdjacentPages(_ page: Int) {
        guard let iconProvider else { return }
        let display = store.displayModel()
        let scale = Int(view.window?.backingScaleFactor ?? 2)
        let pointSize = Int(iconSize)
        for p in [page - 1, page + 1] where p >= 0 && p < display.pages.count {
            let apps = display.pages[p].compactMap { item -> AppID? in
                if case .app(let id) = item { return id }
                return nil
            }
            for id in apps {
                // 异步预热入内存缓存(已命中者 O(1); 未命中走存储库管道, 不阻塞主线程)
                Task(priority: .utility) { [weak iconProvider] in
                    _ = await iconProvider?.icon(for: id, pointSize: pointSize, scale: scale)
                }
            }
        }
    }

    // MARK: - 点击启动

    func handleClick(at point: NSPoint) {
        let local = collectionView.convert(point, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: local),
              let item = dataSource.itemIdentifier(for: indexPath) else {
            // 点击空白处 → 退出启动器
            onClickBlank?()
            return
        }
        switch item {
        case .app(let id):
            store.launch(id)
        case .folder(let id, _):
            onOpenFolder?(id)
        }
    }

    // MARK: - 右键菜单(Phase 5)

    func contextMenu(at point: NSPoint) -> NSMenu? {
        let local = collectionView.convert(point, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: local),
              let item = dataSource.itemIdentifier(for: indexPath) else {
            return nil
        }
        let menu = NSMenu()

        switch item {
        case .app(let id):
            let addItem = NSMenuItem(title: L10n.t(.addToFolder), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let folders = store.folderNames()
            if folders.isEmpty {
                let empty = NSMenuItem(title: L10n.t(.noFolders), action: nil, keyEquivalent: "")
                empty.isEnabled = false
                submenu.addItem(empty)
            } else {
                for (folderID, name) in folders.sorted(by: { $0.value < $1.value }) {
                    let item = NSMenuItem(title: name, action: #selector(addToFolder(_:)), keyEquivalent: "")
                    item.representedObject = FolderMenuItemPayload(appID: id, folderID: folderID)
                    item.target = self
                    submenu.addItem(item)
                }
            }
            addItem.submenu = submenu
            menu.addItem(addItem)

            menu.addItem(.separator())

            let hide = NSMenuItem(
                title: L10n.t(store.isHidden(id) ? .unhideApp : .hideApp),
                action: #selector(toggleHidden(_:)), keyEquivalent: ""
            )
            hide.representedObject = id
            hide.target = self
            menu.addItem(hide)

            let rename = NSMenuItem(
                title: L10n.t(.renameApp), action: #selector(renameApp(_:)), keyEquivalent: ""
            )
            rename.representedObject = id
            rename.target = self
            menu.addItem(rename)

            menu.addItem(.separator())

            let trash = NSMenuItem(
                title: L10n.t(.moveToTrash), action: #selector(moveToTrash(_:)), keyEquivalent: ""
            )
            trash.representedObject = id
            trash.target = self
            menu.addItem(trash)
        case .folder(let id, _):
            let rename = NSMenuItem(
                title: L10n.t(.rename), action: #selector(renameFolder(_:)), keyEquivalent: ""
            )
            rename.representedObject = id
            rename.target = self
            menu.addItem(rename)

            let dissolve = NSMenuItem(
                title: L10n.t(.dissolveFolder), action: #selector(dissolveFolder(_:)), keyEquivalent: ""
            )
            dissolve.representedObject = id
            dissolve.target = self
            menu.addItem(dissolve)
        }
        return menu
    }

    private struct FolderMenuItemPayload {
        let appID: AppID
        let folderID: FolderID
    }

    @objc private func addToFolder(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? FolderMenuItemPayload else { return }
        store.addToFolder(app: payload.appID, folder: payload.folderID)
    }

    @objc private func renameFolder(_ sender: NSMenuItem) {
        guard let folderID = sender.representedObject as? FolderID else { return }
        let current = store.folderName(for: folderID)
        let name = promptForName(defaultValue: current, titleKey: .rename)
        guard let name, !name.isEmpty else { return }
        store.renameFolder(folderID, to: name)
    }

    @objc private func dissolveFolder(_ sender: NSMenuItem) {
        guard let folderID = sender.representedObject as? FolderID else { return }
        store.dissolveFolder(folderID)
    }

    @objc private func toggleHidden(_ sender: NSMenuItem) {
        guard let appID = sender.representedObject as? AppID else { return }
        store.setHidden(appID, hidden: !store.isHidden(appID))
    }

    @objc private func renameApp(_ sender: NSMenuItem) {
        guard let appID = sender.representedObject as? AppID else { return }
        let name = promptForName(
            defaultValue: store.displayName(for: appID), titleKey: .renameApp
        )
        guard let name, !name.isEmpty else { return }
        store.setCustomName(appID, name: name)
    }

    @objc private func moveToTrash(_ sender: NSMenuItem) {
        guard let appID = sender.representedObject as? AppID else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t(.moveToTrash)
        alert.informativeText = "\(store.displayName(for: appID))?"
        alert.addButton(withTitle: L10n.t(.ok))
        alert.addButton(withTitle: L10n.t(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.moveToTrash(appID)
    }

    private func promptForName(defaultValue: String, titleKey: L10n.Key) -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.t(titleKey)
        alert.addButton(withTitle: L10n.t(.ok))
        alert.addButton(withTitle: L10n.t(.cancel))
        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 分页交互(v0.1.6 PART A)

    /// 接线 PagingInteractionController 到本网格(唯一 offset writer 注入)。
    private func setupPagingController() {
        paging.linkView = view
        paging.onReadCurrentOffset = { [weak self] in
            guard let self else { return 0 }
            return self.collectionView.enclosingScrollView?.contentView.bounds.origin.x ?? 0
        }
        paging.onReadPageWidth = { [weak self] in
            guard let self else { return 0 }
            let clip = self.collectionView.enclosingScrollView?.contentView
            return clip?.bounds.width ?? self.collectionView.bounds.width
        }
        paging.onReadPageCount = { [weak self] in
            self?.pageCount ?? 1
        }
        paging.onScroll = { [weak self] offset in
            guard let self, let scroll = self.collectionView.enclosingScrollView else { return }
            scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
        }
        paging.onSettleTargetPage = { [weak self] page in
            guard let self else { return }
            self.currentPage = page
            self.updatePageDots()
            self.prewarmAdjacentPages(page)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // 已迁移到集合视图层(ClickableCollectionView.onPageScroll)
        super.scrollWheel(with: event)
    }

    /// 滚轮/双指滑动: 委托给 PagingInteractionController(状态机 + DisplayLink 唯一 writer)。
    private func handlePageScroll(_ event: NSEvent) -> Bool {
        guard !searchMode else { return false }
        paging.isEnabled = true
        return paging.handleWheel(event)
    }

    /// 分页交互诊断(v0.1.6 §63)。
    var pagingDiagnostics: String { paging.diagnostics() }

    /// 分页探针: 合成 NSEvent 驱动分页交互(性能测量, §63/§82)。
    func pagingProbeFeed(_ event: NSEvent) {
        if event.phase == .began {
            paging.resetCounters()
        }
        _ = paging.handleWheel(event)
    }

    func pagingProbeGesture(deltaXs: [CGFloat]) {
        paging.probeGesture(deltaXs: deltaXs)
    }

    func pagingProbeDisplayFrame() -> Bool {
        paging.probeDisplayFrame()
    }

    /// 布局诊断(§56/§83): 一次交互中 prepare / attribute query 计数。
    var layoutDiagnostics: String {
        let layout = collectionView.collectionViewLayout as? PagingGridLayout
        return "prepare=\(layout?.prepareCount ?? 0) attributeQueries=\(layout?.attributeQueryCount ?? 0)"
    }

    /// 确定性诊断(冒烟验证用): 当前快照结构。
    func diagnostics() -> String {
        let snapshot = dataSource.snapshot()
        return "sections=\(snapshot.numberOfSections) items=\(snapshot.itemIdentifiers.count) pageCount=\(pageCount) search=\(searchMode)"
    }

    var diagnosticSnapshotItemCount: Int {
        dataSource.snapshot().itemIdentifiers.count
    }

    /// 更新页码指示点(搜索模式隐藏)。
    private func updatePageDots() {
        guard let pageDots else { return }
        for dot in pageDotViews {
            dot.removeFromSuperview()
        }
        pageDotViews = []
        guard !searchMode, pageCount > 1 else { return }
        for index in 0..<pageCount {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            let active = index == currentPage
            dot.layer?.backgroundColor = (active
                ? NSColor.white
                : NSColor.white.withAlphaComponent(0.4)).cgColor
            pageDots.addArrangedSubview(dot)
            pageDotViews.append(dot)
        }
    }

    // MARK: - 拖拽辅助

    /// 扁平显示索引(所有页面槽位)。
    func flatIndex(of item: Item) -> Int? {
        var flat = 0
        let snapshot = dataSource.snapshot()
        for section in 0..<snapshot.numberOfSections {
            for element in snapshot.itemIdentifiers(inSection: section) {
                if element == item {
                    return flat
                }
                flat += 1
            }
        }
        return nil
    }

    /// 扁平索引 → IndexPath。
    func indexPath(atFlatIndex index: Int) -> IndexPath? {
        var flat = 0
        let snapshot = dataSource.snapshot()
        for section in 0..<snapshot.numberOfSections {
            let items = snapshot.itemIdentifiers(inSection: section)
            if index < flat + items.count {
                return IndexPath(item: index - flat, section: section)
            }
            flat += items.count
        }
        return nil
    }

    /// 扁平索引 → 文档坐标 frame(二维拖拽预览用, Stage 1 §20-21)。
    func frame(atFlatIndex index: Int) -> CGRect {
        geometry.frame(forFlatIndex: index)
    }

    /// 单元格(可见时)。
    func cellView(at path: IndexPath) -> NSCollectionViewItem? {
        collectionView.item(at: path)
    }

    /// Empty horizontal gap used by the drag-cache diagnostic. This avoids App
    /// hover/dwell and deterministically exercises ordinary reorder preview caching.
    func dragCacheProbePoint() -> NSPoint? {
        guard dataSource.snapshot().itemIdentifiers.count >= 3 else { return nil }
        let left = frame(atFlatIndex: 1)
        let right = frame(atFlatIndex: 2)
        guard left.maxX < right.minX else { return nil }
        let documentPoint = NSPoint(
            x: (left.maxX + right.minX) / 2,
            y: (left.midY + right.midY) / 2
        )
        return collectionView.convert(documentPoint, to: nil)
    }

    /// 源项当前的语义化拖拽视觉表示(只复用已渲染内存, 零磁盘 IO)。
    func dragRepresentation(for item: Item) -> DragVisualRepresentation? {
        guard let index = flatIndex(of: item), let path = indexPath(atFlatIndex: index) else {
            return nil
        }
        guard let cell = cellView(at: path) as? AppCellView else { return nil }
        return cell.dragRepresentation()
    }

    /// 登记并隐藏主网格拖拽源。先捕获表示，再登记 identity/隐藏 cell。
    /// cell 离屏或随后被复用时，configure 会按 identity 同步恢复隐藏状态。
    @discardableResult
    func beginDragSource(for item: Item) -> DragVisualRepresentation? {
        guard flatIndex(of: item) != nil else { return nil }
        let representation = dragRepresentation(for: item)
        activeDragSourceIdentity = GridDragSourceIdentity(item: item)
        applyDragSourceVisibility(for: item, hidden: true)
        return representation
    }

    /// 释放主网格拖拽源身份并恢复当前可见 cell。
    func endDragSource(for item: Item) {
        let identity = GridDragSourceIdentity(item: item)
        guard activeDragSourceIdentity == identity else { return }
        activeDragSourceIdentity = nil
        applyDragSourceVisibility(for: item, hidden: false)
    }

    /// 兼容旧的网格调用方，同时把状态提升为 identity-owned。
    func setDragSourceHidden(_ hidden: Bool, for item: Item) {
        let identity = GridDragSourceIdentity(item: item)
        if hidden {
            activeDragSourceIdentity = identity
        } else {
            guard activeDragSourceIdentity == identity else { return }
            activeDragSourceIdentity = nil
        }
        applyDragSourceVisibility(for: item, hidden: hidden)
    }

    private func isActiveDragSource(_ item: Item) -> Bool {
        activeDragSourceIdentity == GridDragSourceIdentity(item: item)
    }

    private func applyDragSourceVisibility(for item: Item, hidden: Bool) {
        guard let index = flatIndex(of: item), let path = indexPath(atFlatIndex: index),
              let cell = cellView(at: path) as? AppCellView else { return }
        cell.setDragSourceHidden(hidden)
    }

    /// 设置 App B 建夹目标高亮。切换目标时清理旧 cell；离屏目标仅更新记录，
    /// 待 collection view 重新配置 cell 时恢复。
    func setCreateFolderTargetHighlight(appID: AppID?, active: Bool) {
        let normalizedActive = appID == nil ? false : active
        guard createFolderTargetAppID != appID
                || createFolderTargetIsActive != normalizedActive else { return }

        let previousAppID = createFolderTargetAppID
        createFolderTargetAppID = appID
        createFolderTargetIsActive = normalizedActive

        if let previousAppID, previousAppID != appID {
            applyCreateFolderTargetHighlight(
                appID: previousAppID, highlighted: false, active: false
            )
        }
        if let appID {
            applyCreateFolderTargetHighlight(
                appID: appID, highlighted: true, active: normalizedActive
            )
        }
    }

    private func applyCreateFolderTargetHighlight(
        appID: AppID,
        highlighted: Bool,
        active: Bool
    ) {
        guard isViewLoaded, collectionView != nil, dataSource != nil,
              let index = flatIndex(of: .app(appID)),
              let path = indexPath(atFlatIndex: index),
              let cell = cellView(at: path) as? AppCellView else { return }
        cell.setCreateFolderTargetHighlighted(highlighted, active: active)
    }

    /// 文档坐标中的槽位 frame 转为 overlay 容器坐标。
    func overlayFrame(forFlatIndex index: Int) -> CGRect {
        view.convert(frame(atFlatIndex: index), from: collectionView)
    }

    /// 光标 → 拖拽目的地(显示空间 page/slot)。
    /// 坐标系: 窗口点 → 文档坐标 → GridGeometry(页宽 = clip 可视宽, 非文档宽, Stage 1 §5)。
    func dragDestination(from point: NSPoint) -> LayoutTransaction.Destination {
        let local = collectionView.convert(point, from: nil)
        let g = geometry
        guard g.pageWidth > 0 else { return LayoutTransaction.Destination(page: 0, slot: 0) }
        let (page, slot) = g.pageAndSlot(forDocumentPoint: local, pageCount: pageCount)
        return LayoutTransaction.Destination(page: page, slot: slot)
    }

    /// 将已计算好的主网格 page/slot 转成显示空间索引, 供 folder-exit drop 使用。
    /// 指针到目的地的计算仍唯一由 dragDestination(from:) 完成。
    func displayIndex(for destination: LayoutTransaction.Destination) -> Int {
        FolderExitDragPlacement.displayIndex(
            for: destination,
            pageCapacity: geometry.pageCapacity,
            pageCount: pageCount
        )
    }

    /// 光标处的显示项(拖拽源/文件夹悬停)。
    func itemAt(point: NSPoint) -> Item? {
        let local = collectionView.convert(point, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: local) else { return nil }
        return dataSource.itemIdentifier(for: indexPath)
    }

    /// 全部显示项(冒烟诊断)。
    func allItems() -> [Item] {
        let snapshot = dataSource.snapshot()
        return snapshot.itemIdentifiers
    }

    /// 光标悬停的文件夹(移入文件夹目标)。
    func hoveredFolder(at point: NSPoint) -> FolderID? {
        let local = collectionView.convert(point, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: local),
              let item = dataSource.itemIdentifier(for: indexPath),
              case .folder(let id, _) = item else {
            return nil
        }
        return id
    }

    /// 当前页内可见网格 rect(文档坐标, 边缘翻页判定用, Stage 1 §25)。
    var currentPageRect: CGRect {
        let g = geometry
        return g.pageRect(page: min(max(0, currentPage), max(0, pageCount - 1)))
    }

    /// overlay 层级(拖拽图标)。
    func addOverlayLayer(_ layer: CALayer) {
        if !view.wantsLayer { view.wantsLayer = true }
        view.layer?.addSublayer(layer)
    }

    func removeOverlayLayer(_ layer: CALayer) {
        layer.removeFromSuperlayer()
    }
}

private extension NSCollectionView {
    /// 翻页(非动画, 初始化/结构刷新/测试用): 页步长 = clip 可见宽度(非文档宽度)。
    /// 动画翻页统一走 PagingInteractionController → PageSnapAnimator(v0.1.6 §23),
    /// 不再使用 clip.animator / NSAnimationContext。
    func scrollToPage(_ page: Int, animated: Bool) {
        guard !animated else { return }
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let clipWidth = clip.bounds.width > 0 ? clip.bounds.width : bounds.width
        let x = CGFloat(page) * clipWidth
        // NSClipView.scroll(to:) 是文档化的编程滚动 API
        clip.scroll(to: NSPoint(x: x, y: 0))
        if CommandLine.arguments.contains("--pagetest") {
            print("PAGETEST scrollToPage x=\(Int(x)) now=\(Int(clip.bounds.origin.x))")
        }
    }
}
