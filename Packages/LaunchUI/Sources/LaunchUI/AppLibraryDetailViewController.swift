import AppKit
import LaunchCore

/// App Library 分类 detail: 半透明暗化层 + 玻璃面板, 内为垂直滚动列表
/// (icon + 完整 App 名)。
///
/// 关闭路径(经 callback, 不触碰 LauncherInteractionSurface):
/// - Escape(cancelOperation / keyDown 53)
/// - 面板外点击
/// - 选中一行(先 onSelect, 再交给宿主收尾)
///
/// 只请求可见行的图标; 行复用带 AppID/generation 校验, 迟到结果不串行。
@MainActor
public final class AppLibraryDetailViewController: NSViewController {
    private static let panelMaxWidth: CGFloat = 560
    private static let panelMaxHeight: CGFloat = 460
    private static let panelHorizontalMargin: CGFloat = 96
    private static let panelVerticalMargin: CGFloat = 140
    private static let rowHeight: CGFloat = 44

    private let detailTitle: String
    private let appIDs: [AppID]
    private let displayName: (AppID) -> String
    private let iconProvider: (any IconImageProviding)?
    private let onSelect: (AppID) -> Void
    private let onClose: () -> Void
    /// 行右键分类菜单入口(PA2; 宿主转发到 Library 控制器)。
    private let onCategoryMenu: ((AppID, NSPoint) -> Void)?

    private let detailRootView = LibraryDetailRootView()
    private let panel = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let detailCollectionView = LibraryCollectionView()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, AppID>?

    /// Reduce Motion 快照(L5): 每个行 cell configure 都读
    /// `MotionEnvironment.reduceMotion`(内部 3 次 NSWorkspace 查询)太贵。
    /// 在 loadView(本 detail 每次打开新建控制器, 无独立 reload API)读取一次缓存,
    /// 行配置复用该值。
    ///
    /// [DEFER BASIS] 系统设置变更时, 已呈现的 detail 停留在本次 load 快照上,
    /// 直到关闭重开才刷新。触发/owner: 后续 live 刷新应仿照
    /// AppLibraryViewController 的 F9 路径——注册
    /// `MotionEnvironment.displayOptionsDidChange` 观察者, 在回调里重读快照并
    /// 重放 diffable snapshot(需先为 detail 引入 reload 入口)。当前 detail 无
    /// reload API 且每次打开新建, 故不在此引入观察者/共享抽象。
    private var reloadReduceMotion = false
    /// 测试 seam 标记: 已注入覆盖值时, loadView 不再读取系统值。
    private var reloadReduceMotionOverridden = false

    public init(
        title: String,
        appIDs: [AppID],
        displayName: @escaping (AppID) -> String,
        iconProvider: (any IconImageProviding)?,
        onSelect: @escaping (AppID) -> Void,
        onClose: @escaping () -> Void,
        onCategoryMenu: ((AppID, NSPoint) -> Void)? = nil
    ) {
        self.detailTitle = title
        self.appIDs = appIDs
        self.displayName = displayName
        self.iconProvider = iconProvider
        self.onSelect = onSelect
        self.onClose = onClose
        self.onCategoryMenu = onCategoryMenu
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        // L5: load 级入口读取一次系统动效快照, 行配置复用缓存值,
        // 避免每个 cell configure 重复 NSWorkspace 查询。
        // 测试 seam 已注入覆盖值时保持覆盖值(生产路径不注入, 仍读取一次系统值)。
        if !reloadReduceMotionOverridden {
            reloadReduceMotion = MotionEnvironment.reduceMotion
        }
        detailRootView.wantsLayer = true
        detailRootView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        detailRootView.onEscape = { [weak self] in
            self?.handleClose()
        }
        detailRootView.onOutsideClick = { [weak self] in
            self?.handleClose()
        }
        detailRootView.setAccessibilityElement(true)
        detailRootView.setAccessibilityRole(.group)
        detailRootView.setAccessibilityLabel(detailTitle)
        detailRootView.setAccessibilityHelp(L10n.t(.categoryDetailHelp))

        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 16
        panel.layer?.masksToBounds = true
        detailRootView.addSubview(panel)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.stringValue = detailTitle
        titleLabel.setAccessibilityLabel(detailTitle)
        titleLabel.setAccessibilityHelp(L10n.t(.categoryDetailHelp))
        panel.addSubview(titleLabel)

        detailCollectionView.collectionViewLayout = AppLibraryLayout(
            mode: .list,
            rowSpacing: 4,
            contentInsets: NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0),
            rowHeight: Self.rowHeight
        )
        detailCollectionView.backgroundColors = [.clear]
        detailCollectionView.isSelectable = false
        detailCollectionView.register(
            AppLibraryDetailRowCell.self,
            forItemWithIdentifier: AppLibraryDetailRowCell.reuseIdentifier
        )
        dataSource = NSCollectionViewDiffableDataSource<Int, AppID>(
            collectionView: detailCollectionView
        ) { [weak self] collectionView, indexPath, appID in
            guard let self else { return nil }
            let cell = collectionView.makeItem(
                withIdentifier: AppLibraryDetailRowCell.reuseIdentifier, for: indexPath
            ) as? AppLibraryDetailRowCell
            guard let cell else { return nil }
            cell.configure(
                appID: appID,
                name: self.displayName(appID),
                provider: self.iconProvider,
                backingScale: self.currentBackingScale,
                reducedMotion: self.reloadReduceMotion,
                onSelect: { [weak self] selected in
                    self?.handleSelect(selected)
                },
                onCategoryMenu: { [weak self] menuAppID, windowPoint in
                    self?.onCategoryMenu?(menuAppID, windowPoint)
                }
            )
            return cell
        }

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = detailCollectionView
        detailCollectionView.autoresizingMask = []
        panel.addSubview(scrollView)

        view = detailRootView

        var snapshot = NSDiffableDataSourceSnapshot<Int, AppID>()
        snapshot.appendSections([0])
        snapshot.appendItems(appIDs)
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutPanel()
        updateDocumentFrame()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(detailRootView)
    }

    /// 测试 seam: 集合视图。
    var collectionView: NSCollectionView { detailCollectionView }

    /// 测试 seam(L5): 当前缓存的 Reduce Motion 快照值。
    var reloadReduceMotionForDiag: Bool { reloadReduceMotion }

    /// 测试 seam(L5): 在 loadView 前注入缓存的 Reduce Motion 快照,
    /// 使测试能构造与实时系统值不同的快照, 验证行配置确实复用缓存而非逐行查询。
    /// 仅测试调用; 生产路径不调用, loadView 仍读取一次 MotionEnvironment.reduceMotion。
    func setReloadReduceMotionForTesting(_ value: Bool) {
        reloadReduceMotion = value
        reloadReduceMotionOverridden = true
    }

    /// 测试 seam: Escape 路径(与 keyDown(53)/cancelOperation 同一入口)。
    func handleEscape() {
        handleClose()
    }

    // MARK: - 布局

    private func layoutPanel() {
        let bounds = detailRootView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let width = min(Self.panelMaxWidth, max(0, bounds.width - Self.panelHorizontalMargin))
        let height = min(Self.panelMaxHeight, max(0, bounds.height - Self.panelVerticalMargin))
        panel.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )

        let padding: CGFloat = 20
        titleLabel.frame = CGRect(
            x: padding,
            y: panel.bounds.height - 16 - 20,
            width: max(0, panel.bounds.width - padding * 2),
            height: 20
        )
        scrollView.frame = CGRect(
            x: padding,
            y: 16,
            width: max(0, panel.bounds.width - padding * 2),
            height: max(0, panel.bounds.height - 16 - 52)
        )
    }

    private func updateDocumentFrame() {
        guard let layout = detailCollectionView.collectionViewLayout else { return }
        let size = layout.collectionViewContentSize
        guard size.width > 0, size.height > 0 else { return }
        if detailCollectionView.frame.size != size {
            detailCollectionView.frame.size = size
        }
    }

    private var currentBackingScale: Int {
        let scale = view.window?.backingScaleFactor ?? 2
        return max(1, Int(scale.rounded()))
    }

    // MARK: - 交互

    private func handleSelect(_ appID: AppID) {
        onSelect(appID)
    }

    private func handleClose() {
        onClose()
    }
}

/// detail 行: icon + 完整 App 名, 整行可点击。
@MainActor
final class AppLibraryDetailRowCell: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AppLibraryDetailRowCell")

    private static let iconSize: CGFloat = 32

    private let rowRoot = DetailRowRootView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var onSelect: ((AppID) -> Void)?
    /// 右键分类菜单入口(PA2; 由 detail 控制器在配置时设置)。
    private var onCategoryMenu: ((AppID, NSPoint) -> Void)?
    private var reducedMotion = false

    private var representedAppID: AppID?
    private var requestGeneration: UInt64 = 0
    private var iconTask: Task<Void, Never>?
    private var requestedPointSize = 0
    private var backingScale = 2

    /// 测试 seam: 已应用的 provider 图标。
    private(set) var appliedCGImage: CGImage?

    /// 测试 seam(L5): 本行配置时收到的 Reduce Motion 快照值。
    private(set) var reducedMotionForDiag = false

    override func loadView() {
        rowRoot.wantsLayer = true
        rowRoot.onMouseDown = { [weak self] in
            self?.beginPress()
        }
        rowRoot.onMouseUp = { [weak self] in
            self?.dispatchSelection()
        }
        // 每次 mouseUp(含超阈值远释放)都恢复行 transform, 避免按压态残留;
        // 选中仍由 onMouseUp 在 6pt 阈值内单独分发。
        rowRoot.onMouseUpAlways = { [weak self] in
            self?.endPress()
        }
        rowRoot.onRightMouseDown = { [weak self] point in
            self?.handleRightClick(at: point)
        }

        iconView.wantsLayer = true
        iconView.imageScaling = .scaleProportionallyDown
        iconView.layer?.contentsGravity = .resizeAspect
        iconView.layer?.cornerRadius = 6
        iconView.layer?.masksToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        rowRoot.addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        rowRoot.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: rowRoot.leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: rowRoot.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: rowRoot.trailingAnchor, constant: -10),
            nameLabel.centerYAnchor.constraint(equalTo: rowRoot.centerYAnchor),
        ])

        view = rowRoot
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        reset()
    }

    func configure(
        appID: AppID,
        name: String,
        provider: (any IconImageProviding)?,
        backingScale: Int,
        reducedMotion: Bool,
        onSelect: @escaping (AppID) -> Void,
        onCategoryMenu: ((AppID, NSPoint) -> Void)? = nil
    ) {
        reset()
        representedAppID = appID
        self.backingScale = max(1, backingScale)
        self.reducedMotion = reducedMotion
        reducedMotionForDiag = reducedMotion
        self.onSelect = onSelect
        self.onCategoryMenu = onCategoryMenu
        nameLabel.stringValue = name
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(name)
        view.setAccessibilityHelp(L10n.format(.launchApp, name))

        requestedPointSize = Int(Self.iconSize.rounded())
        iconView.image = AppLibraryIconPlaceholder.image(
            appID: appID,
            name: name,
            pointSize: requestedPointSize,
            scale: self.backingScale
        )
        guard let provider else { return }
        let expectedGeneration = requestGeneration
        let pointSize = requestedPointSize
        let scale = self.backingScale
        iconTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let image = await provider.icon(for: appID, pointSize: pointSize, scale: scale)
            guard !Task.isCancelled,
                  let self,
                  self.representedAppID == appID,
                  self.requestGeneration == expectedGeneration else { return }
            self.applyIcon(image)
        }
    }

    /// 选中当前行(鼠标/测试共用)。
    func dispatchSelection() {
        guard let appID = representedAppID else { return }
        onSelect?(appID)
    }

    /// 右键分发(PA2): 回调携带窗口坐标点(供 controller menu popUp)。
    func handleRightClick(at point: NSPoint) {
        guard let appID = representedAppID else { return }
        let windowPoint = view.convert(point, to: nil)
        onCategoryMenu?(appID, windowPoint)
    }

    // MARK: - 按压

    private func beginPress() {
        guard !reducedMotion else { return }
        animateTransform(CATransform3DMakeScale(MotionTokens.titlePressScale, MotionTokens.titlePressScale, 1))
    }

    /// 恢复按压态: 每次 mouseUp 都调用(含超阈值远释放), 保证 transform 不残留。
    private func endPress() {
        guard !reducedMotion else { return }
        animateTransform(CATransform3DIdentity)
    }

    private func applyIcon(_ image: CGImage?) {
        if let image {
            appliedCGImage = image
            iconView.image = NSImage(cgImage: image, size: NSSize(width: requestedPointSize, height: requestedPointSize))
        }
    }

    private func animateTransform(_ transform: CATransform3D) {
        guard let layer = view.layer else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MotionTokens.pressFeedback.response
            context.allowsImplicitAnimation = true
            layer.transform = transform
        }
    }

    private func reset() {
        iconTask?.cancel()
        iconTask = nil
        requestGeneration &+= 1
        representedAppID = nil
        onSelect = nil
        onCategoryMenu = nil
        appliedCGImage = nil
        if isViewLoaded {
            iconView.image = nil
            nameLabel.stringValue = ""
            view.layer?.transform = CATransform3DIdentity
        }
    }
}

/// detail 根视图: 接受首响应, Escape/取消关闭, 面板外点击关闭。
@MainActor
private final class LibraryDetailRootView: NSView {
    var onEscape: (() -> Void)?
    var onOutsideClick: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func mouseDown(with event: NSEvent) {
        onOutsideClick?()
    }
}

/// detail 行根视图: 转发 mouseDown/mouseUp; 超过 6pt 位移的 mouseUp 不转发选中。
/// 每次 mouseUp(含远释放/无配对)都触发 onMouseUpAlways(恢复行 transform),
/// 选中仅由 onMouseUp 在 6pt 阈值内分发。右键(rightMouseDown)单独转发给行 cell。
@MainActor
private final class DetailRowRootView: NSView {
    private static let pressClickThreshold: CGFloat = 6

    var onMouseDown: (() -> Void)?
    var onMouseUp: (() -> Void)?
    var onMouseUpAlways: (() -> Void)?
    var onRightMouseDown: ((NSPoint) -> Void)?
    private var mouseDownPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        onMouseDown?()
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = mouseDownPoint else {
            // 无配对 mouseUp: 仍恢复 transform, 保持状态安全。
            onMouseUpAlways?()
            onMouseUp?()
            return
        }
        mouseDownPoint = nil
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - start.x
        let dy = point.y - start.y
        // 每次配对 mouseUp 都恢复 transform(含远释放), 避免按压态残留。
        onMouseUpAlways?()
        if dx * dx + dy * dy <= Self.pressClickThreshold * Self.pressClickThreshold {
            onMouseUp?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onRightMouseDown?(point)
    }
}
