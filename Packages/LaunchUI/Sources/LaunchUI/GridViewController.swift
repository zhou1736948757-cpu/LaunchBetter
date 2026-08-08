import AppKit
import LaunchCore

/// 网格视图控制器: NSCollectionView + DiffableDataSource + 分页导航。
///
/// 两种模式:
/// - 分页模式: 每页一个 section,横向分页,滚轮/键盘翻页
/// - 搜索模式: 单 section 垂直滚动结果网格(结果可超一页容量)
///
/// 几何唯一真值: GridGeometry(PagingGridLayout 的 currentGeometry/liveGeometry),
/// 本控制器不再维护 pageWidth/itemSize/slotStep 等硬编码(Stage 1, P0)。
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
                accessibilityHint: "点击启动 \(store.displayName(for: id))",
                appID: id,
                pointSize: pointSize,
                iconProvider: iconProvider
            )
        case .folder(let id, _):
            cell.configure(
                displayName: store.folderName(for: id),
                colorIndex: stableColorIndex("folder:" + id.rawValue),
                accessibilityHint: "文件夹 \(store.folderName(for: id))",
                appID: nil,
                pointSize: pointSize,
                iconProvider: nil
            )
        }
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
        currentPage = min(max(0, page), pageCount - 1)
        collectionView.scrollToPage(currentPage, animated: animated)
        updatePageDots()
    }

    func nextPage() { goToPage(currentPage + 1) }
    func previousPage() { goToPage(currentPage - 1) }

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

            let newFolder = NSMenuItem(
                title: L10n.t(.newFolder), action: #selector(createFolderWith(_:)), keyEquivalent: ""
            )
            newFolder.representedObject = id
            newFolder.target = self
            menu.addItem(newFolder)

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

    @objc private func createFolderWith(_ sender: NSMenuItem) {
        guard let appID = sender.representedObject as? AppID else { return }
        let name = promptForName(defaultValue: "新文件夹")
        guard let name, !name.isEmpty else { return }
        store.createFolder(name: name, appIDs: [appID])
    }

    @objc private func renameFolder(_ sender: NSMenuItem) {
        guard let folderID = sender.representedObject as? FolderID else { return }
        let current = store.folderName(for: folderID)
        let name = promptForName(defaultValue: current)
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
        let name = promptForName(defaultValue: store.displayName(for: appID))
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

    private func promptForName(defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = defaultValue == "新文件夹" ? "新建文件夹" : "重命名"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func scrollWheel(with event: NSEvent) {
        // 已迁移到集合视图层(ClickableCollectionView.onPageScroll)
        super.scrollWheel(with: event)
    }

    // MARK: - 双指滑动分页状态机

    /// 手势会话: 一次手势最多一页, momentum 不额外分页, 水平主导才翻页(Stage 1 §8)。
    private var pagingSession = PagingGestureSession()

    /// 手势开始时的 clip 位置(跟手基准, v0.1.4)。
    private var gestureBaseX: CGFloat = 0

    /// 滚轮/双指滑动翻页: 横向跟手平移 + 松手吸附; 纵向滚轮一次一页。
    /// 惯性(momentum)阶段拦截(交给系统会滚动到任意非整页位置, 卡在两页中间)。
    private func handlePageScroll(_ event: NSEvent) -> Bool {
        guard !searchMode else { return false }

        // momentum/惯性: 全部拦截(防系统自由滚动), 惯性结束时吸附到最近页
        if event.momentumPhase != [] {
            if event.momentumPhase == .ended {
                snapToNearestPage()
            }
            return true
        }

        switch event.phase {
        case .began:
            pagingSession.reset()
            gestureBaseX = collectionView.enclosingScrollView?.contentView.bounds.origin.x ?? 0
        case .ended, .cancelled:
            pagingSession.feed(phase: .ended, deltaX: 0, deltaY: 0)
            // 手势结束: 吸附到最近整页(跟手后校准, 防卡两页中间)
            snapToNearestPage()
            return false
        default:
            break
        }

        // 横向双指滑动(水平主导)→ 跟手平移(位移钳制在一页内), 松手吸附
        if abs(event.deltaX) > abs(event.deltaY) * pagingSession.horizontalDominance,
           abs(event.deltaX) > 0.5 {
            _ = pagingSession.feed(
                phase: event.phase == .changed ? .changed : .began,
                deltaX: event.deltaX, deltaY: 0
            )
            followFinger()
            return true
        }

        // 纵向输入: 触控板连续手势也经会话状态机(一次手势最多一页, 评审 M4);
        // 离散鼠标滚轮(无 phase)保留每格一页
        if abs(event.deltaY) > 0.5 {
            let committed = pagingSession.feed(
                phase: event.phase == .changed ? .changed : .began,
                deltaX: event.deltaY, deltaY: 0
            )
            if committed {
                if pagingSession.direction > 0 {
                    nextPage()
                } else {
                    previousPage()
                }
            }
            return true
        }
        return false
    }

    /// 跟手: 页面随手指水平平移(累计位移钳制在一页宽内, 一次手势最多一页)。
    private func followFinger() {
        guard let scroll = collectionView.enclosingScrollView else { return }
        let clip = scroll.contentView
        let pageWidth = clip.bounds.width
        guard pageWidth > 0 else { return }
        // 左滑(deltaX<0, 累计为负)→ 内容左移 → offset 增加
        let dx = -pagingSession.accumulatedDeltaX
        let clamped = min(max(dx, -pageWidth), pageWidth)
        let maxX = max(0, CGFloat(pageCount) * pageWidth - pageWidth)
        let target = min(max(gestureBaseX + clamped, 0), maxX)
        clip.scroll(to: NSPoint(x: target, y: 0))
    }

    /// 吸附到最近整页: 位移超过 35% 页宽则翻页, 否则弹回(v0.1.4 跟手吸附)。
    private func snapToNearestPage() {
        guard !searchMode else { return }
        guard let scroll = collectionView.enclosingScrollView else { return }
        let clip = scroll.contentView
        let pageWidth = clip.bounds.width > 0 ? clip.bounds.width : collectionView.bounds.width
        guard pageWidth > 0 else { return }
        let target = geometry.snapTarget(
            currentOffsetX: clip.bounds.origin.x,
            currentPage: currentPage,
            pageCount: pageCount
        )
        currentPage = target
        goToPage(target, animated: true)
    }

    /// 确定性诊断(冒烟验证用): 当前快照结构。
    func diagnostics() -> String {
        let snapshot = dataSource.snapshot()
        return "sections=\(snapshot.numberOfSections) items=\(snapshot.itemIdentifiers.count) pageCount=\(pageCount) search=\(searchMode)"
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

    /// 源项当前显示的图标图像(拖拽 overlay 复用, 零磁盘 IO, Stage 1 §23-24)。
    func visibleIconImage(for item: Item) -> CGImage? {
        guard let index = flatIndex(of: item), let path = indexPath(atFlatIndex: index) else {
            return nil
        }
        guard let cell = cellView(at: path) as? AppCellView else { return nil }
        return cell.visibleIconImage
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
    /// 翻页: 页步长 = clip 可见宽度(非文档宽度)。
    func scrollToPage(_ page: Int, animated: Bool) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let clipWidth = clip.bounds.width > 0 ? clip.bounds.width : bounds.width
        let x = CGFloat(page) * clipWidth
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
            } completionHandler: {
                // 动画被中途打断时校准回整页(v0.1.4 防卡两页中间)
                MainActor.assumeIsolated {
                    if abs(clip.bounds.origin.x - x) > 1 {
                        clip.scroll(to: NSPoint(x: x, y: 0))
                    }
                }
            }
        } else {
            // NSClipView.scroll(to:) 是文档化的编程滚动 API
            clip.scroll(to: NSPoint(x: x, y: 0))
            if CommandLine.arguments.contains("--pagetest") {
                print("PAGETEST scrollToPage x=\(Int(x)) now=\(Int(clip.bounds.origin.x))")
            }
        }
    }
}
