import AppKit
import LaunchCore

/// 文件夹视图: 显示文件夹内应用(单页网格)+ 返回按钮。
@MainActor
final class FolderViewController: NSViewController {
    private let store: any LauncherStoring
    private let iconProvider: (any IconImageProviding)?
    private let folderID: FolderID

    var onBack: (() -> Void)?

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
        let root = NSView()

        let backButton = NSButton(title: "← 返回", target: self, action: #selector(backTapped))
        backButton.bezelStyle = .rounded
        root.addSubview(backButton)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            backButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
        ])

        let titleLabel = NSTextField(labelWithString: store.folderName(for: folderID))
        titleLabel.font = .boldSystemFont(ofSize: 24)
        titleLabel.alignment = .center
        root.addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            titleLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        ])

        // 子项网格: 单页, 支持点击启动(同样包 NSScrollView, 与主网格一致)
        let collectionView = ClickableCollectionView()
        collectionView.collectionViewLayout = PagingGridLayout(
            columns: store.gridColumns, rows: store.gridRows, itemSize: 96, spacing: 28
        )
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.register(AppCellView.self, forItemWithIdentifier: AppCellView.identifier)
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = collectionView
        // 关键: 关闭文档视图 autoresizing, 否则滚动视图会把它拉回可视宽度
        collectionView.autoresizingMask = []
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 80),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // Diffable: 单 section 子项
        let dataSource = NSCollectionViewDiffableDataSource<Int, DisplayModel.DisplayItem>(
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
                    accessibilityHint: "点击启动 \(store.displayName(for: id))",
                    appID: id,
                    pointSize: 96,
                    iconProvider: iconProvider
                )
            case .folder:
                break
            }
            return cell
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, DisplayModel.DisplayItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(
            (store.folderChildren(folderID) ?? []).map(DisplayModel.DisplayItem.app),
            toSection: 0
        )
        dataSource.apply(snapshot, animatingDifferences: false)

        collectionView.onClick = { [weak self] point in
            guard let self else { return }
            let local = collectionView.convert(point, from: nil)
            guard let indexPath = collectionView.indexPathForItem(at: local),
                  let item = dataSource.itemIdentifier(for: indexPath),
                  case .app(let id) = item else { return }
            store.launch(id)
        }

        view = root
    }

    private func stableColorIndex(_ key: String) -> Int {
        abs(key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % 12
    }

    @objc private func backTapped() {
        onBack?()
    }
}
