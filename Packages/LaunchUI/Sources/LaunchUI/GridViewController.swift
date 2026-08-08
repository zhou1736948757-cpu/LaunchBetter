import AppKit
import LaunchCore

/// 网格视图控制器: NSCollectionView + DiffableDataSource + 分页导航。
///
/// 两种模式:
/// - 分页模式: 每页一个 section,横向分页,滚轮/键盘翻页
/// - 搜索模式: 单 section 平铺结果,禁用分页滚动
///
/// 结构变化(目录变化/搜索切换/drop 完成)才应用 snapshot(§83),
/// 禁止逐帧应用 snapshot(§132)。
@MainActor
final class GridViewController: NSViewController {
    typealias Item = DisplayModel.DisplayItem

    private let store: any LauncherStoring
    private let iconProvider: (any IconImageProviding)?
    private var collectionView: NSCollectionView!
    private var dataSource: NSCollectionViewDiffableDataSource<Int, Item>!
    private var currentPage = 0
    private var pageCount = 1
    private var searchMode = false

    /// 点击文件夹时回调(打开文件夹视图)。
    var onOpenFolder: ((FolderID) -> Void)?

    /// 拖拽控制(由窗口控制器注入)。
    var dragController: DragController?

    /// 集合视图(拖拽/诊断用)。首次访问触发 view 加载。
    var collectionViewRef: NSCollectionView {
        if collectionView == nil {
            _ = view
        }
        return collectionView
    }

    /// 槽位步进(图标 + 间距), 预览变换位移量。
    var slotStep: CGFloat { 96 + 28 }

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
            columns: store.gridColumns, rows: store.gridRows, itemSize: 96, spacing: 28
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
        container.addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: container.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.collectionView = collectionView

        configureDataSource()
        view = container
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
        let pointSize = Int(96)
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

    /// 应用最新显示模型(或搜索结果)。
    func refresh() {
        if let results = store.searchResults() {
            searchMode = true
            applySearch(results)
        } else {
            searchMode = false
            applyDisplayModel(store.displayModel())
        }
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
    }

    private func applySearch(_ results: [Item]) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(results, toSection: 0)
        pageCount = 1
        currentPage = 0
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.scrollToPage(0, animated: false)
    }

    // MARK: - 页面导航

    func goToPage(_ page: Int, animated: Bool = true) {
        guard !searchMode else { return }
        currentPage = min(max(0, page), pageCount - 1)
        collectionView.scrollToPage(currentPage, animated: animated)
    }

    func nextPage() { goToPage(currentPage + 1) }
    func previousPage() { goToPage(currentPage - 1) }

    // MARK: - 点击启动

    func handleClick(at point: NSPoint) {
        let local = collectionView.convert(point, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: local) else { return }
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
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
            let addItem = NSMenuItem(title: "加入文件夹", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let folders = store.folderNames()
            if folders.isEmpty {
                let empty = NSMenuItem(title: "(无文件夹)", action: nil, keyEquivalent: "")
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
                title: "新建文件夹", action: #selector(createFolderWith(_:)), keyEquivalent: ""
            )
            newFolder.representedObject = id
            newFolder.target = self
            menu.addItem(newFolder)
        case .folder(let id, _):
            let rename = NSMenuItem(
                title: "重命名…", action: #selector(renameFolder(_:)), keyEquivalent: ""
            )
            rename.representedObject = id
            rename.target = self
            menu.addItem(rename)

            let dissolve = NSMenuItem(
                title: "解散文件夹", action: #selector(dissolveFolder(_:)), keyEquivalent: ""
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
        if !searchMode, abs(event.deltaY) > abs(event.deltaX), abs(event.deltaY) > 0.5 {
            if event.deltaY < 0 {
                nextPage()
            } else {
                previousPage()
            }
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// 确定性诊断(冒烟验证用): 当前快照结构。
    func diagnostics() -> String {
        let snapshot = dataSource.snapshot()
        return "sections=\(snapshot.numberOfSections) items=\(snapshot.itemIdentifiers.count) pageCount=\(pageCount) search=\(searchMode)"
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

    /// 单元格(可见时)。
    func cellView(at path: IndexPath) -> NSCollectionViewItem? {
        collectionView.item(at: path)
    }

    /// 光标 → 拖拽目的地(显示空间 page/slot)。
    func dragDestination(from point: NSPoint) -> LayoutTransaction.Destination {
        let local = collectionView.convert(point, from: nil)
        let bounds = collectionView.bounds
        guard bounds.width > 0 else { return LayoutTransaction.Destination(page: 0, slot: 0) }
        let page = min(max(0, Int(floor(local.x / bounds.width))), max(0, pageCount - 1))
        return LayoutTransaction.Destination(page: page, slot: slot(at: local))
    }

    /// 光标所在槽位(页内)。
    private func slot(at local: NSPoint) -> Int {
        let bounds = collectionView.bounds
        let columns = store.gridColumns
        let rows = store.gridRows
        let itemSize: CGFloat = 96
        let spacing: CGFloat = 28
        let gridWidth = CGFloat(columns) * itemSize + CGFloat(columns - 1) * spacing
        let gridHeight = CGFloat(rows) * itemSize + CGFloat(rows - 1) * spacing
        let startX = (bounds.width - gridWidth) / 2
        let startY = (bounds.height - gridHeight) / 2
        let pageOffset = floor(local.x / bounds.width) * bounds.width
        let col = Int(floor((local.x - pageOffset - startX) / (itemSize + spacing)))
        let row = Int(floor((local.y - startY) / (itemSize + spacing)))
        let clampedCol = min(max(0, col), columns - 1)
        let clampedRow = min(max(0, row), rows - 1)
        return clampedRow * columns + clampedCol
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
    func scrollToPage(_ page: Int, animated: Bool) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let x = CGFloat(page) * bounds.width
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
            }
        } else {
            clip.setBoundsOrigin(NSPoint(x: x, y: 0))
        }
    }
}
