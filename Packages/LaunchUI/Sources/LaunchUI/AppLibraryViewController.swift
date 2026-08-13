import AppKit
import LaunchCore

/// App Library 卡片网格控制器(独立 AppKit 表面)。
///
/// 注入边界: model / displayName / iconProvider / onLaunch 全部由宿主提供;
/// 本类不依赖 LaunchPlatform, 不访问文件系统。
///
/// 卡片顺序完全由 `model.cards` 决定(Suggestions、Recently Added、固定分类)。
/// 大图标点击直接 `onLaunch`; mini cluster / 卡片标题点击打开分类 detail。
/// detail 的 Escape / 面板外点击 / 选中关闭都经 callback, 不触碰
/// LauncherInteractionSurface。
///
/// 滚动轴仲裁(Stage E9b): 垂直滚动留在内部 NSScrollView; horizontal 手势经
/// `PausableLibraryScrollView` 路由到宿主注入的 `onHorizontalScroll`, 复用外层
/// PagingInteractionController, 不创建第二套 settle/spring/display-link。
@MainActor
public final class AppLibraryViewController: NSViewController {
    private let displayName: (AppID) -> String
    private let iconProvider: (any IconImageProviding)?
    private let onLaunch: (AppID) -> Void
    /// 手动分类覆盖能力(PA2; nil = 不显示分类菜单)。
    private let categoryOverriding: (any AppLibraryCategoryOverriding)?

    private var model: AppLibraryModel
    private var previousCards: [AppLibraryCardID: AppLibraryCard] = [:]
    private var sessionFrozen = false

    private let scrollView = PausableLibraryScrollView()
    private let gridCollectionView = BlankClickLibraryCollectionView()
    private var dataSource: NSCollectionViewDiffableDataSource<Int, AppLibraryCardID>?

    /// view 加载前的 inset 请求缓存: `setContentInsets` 可能在 loadView 前
    /// 被调用(host `makeController` 早于 `controller.view` 访问), 此时 layout
    /// 尚不存在, 暂存并在 `loadView` 创建布局后应用。
    private var pendingContentInsets: (top: CGFloat, bottom: CGFloat)?

    private var detailController: AppLibraryDetailViewController?

    /// Category detail 打开/关闭状态变化回调(open = true 表示 detail 已打开)。
    /// 由宿主转发给 Grid/Window 维护 `.appLibraryCategory` 输入 owner。
    var onDetailChange: ((Bool) -> Void)?

    /// 水平滚动 handler(宿主注入, Stage E9b): 复用外层
    /// `PagingInteractionController` 的既有 settle/display-link 引擎,
    /// 不创建第二套 horizontal 滚动 writer。
    /// 返回 true = 已消费; false 仍由本层消费(不落回垂直滚动)。
    var onHorizontalScroll: ((NSEvent) -> Bool)?

    /// 真空白点击回调(PA3): 点在 Library 网格集合视图背景
    /// (`indexPathForItem == nil`)或 scroll 容器非卡片区域, mouseDown→mouseUp
    /// 均空白且位移 ≤ 6pt 时触发一次。detail 打开期间不触发。
    /// 由宿主转发给 Grid 复用其 `onClickBlank`(→ window hide), 不新建 hide 路径。
    var onBlankClick: (() -> Void)?

    public init(
        model: AppLibraryModel,
        displayName: @escaping (AppID) -> String,
        iconProvider: (any IconImageProviding)?,
        onLaunch: @escaping (AppID) -> Void,
        categoryOverriding: (any AppLibraryCategoryOverriding)? = nil
    ) {
        self.model = model
        self.displayName = displayName
        self.iconProvider = iconProvider
        self.onLaunch = onLaunch
        self.categoryOverriding = categoryOverriding
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    /// 更新模型。卡片身份不变时 layout 与未变化的 cell 实例保持稳定;
    /// 仅与旧模型不同的卡片 payload 触发定向 reload。
    public func apply(model: AppLibraryModel) {
        guard !sessionFrozen else { return }
        guard model != self.model else { return }
        self.model = model
        if detailController != nil { closeDetail() }
        reloadCards()
    }

    /// 开始固定 session: 冻结当前模型, 后续 apply 一律忽略。
    public func beginSession(model: AppLibraryModel) {
        sessionFrozen = true
        self.model = model
        if detailController != nil { closeDetail() }
        reloadCards()
    }

    /// 冻结 session 期间的 live 模型刷新(PA2 热更新)。
    ///
    /// 绕过 `sessionFrozen` 对 `apply(model:)` 的屏蔽, 但保持 session 语义:
    /// 不解除冻结、不复用 host;复用 `reloadCards()` 的 diffable 稳定身份
    /// (card ID 不变 → 不 delete/insert, 无 flicker)。
    public func updateModel(_ model: AppLibraryModel) {
        guard model != self.model else { return }
        self.model = model
        if detailController != nil { closeDetail() }
        reloadCards()
    }

    /// 结束固定 session: 解除模型冻结(host 复用 / Launcher 隐藏时调用)。
    /// 之后 `apply(model:)` 恢复生效; 宿主再次 `beginSession` 用最新模型重新固定。
    public func endSession() {
        sessionFrozen = false
    }

    /// 外层接入/测试 seam: 垂直滚动容器。
    public var verticalScrollView: NSScrollView { scrollView }

    /// PA4 诊断 seam: Library 轴仲裁链路的 trace 开关(转发到滚动容器)。
    public var pagingTraceEnabled: Bool {
        get { scrollView.traceEnabled }
        set { scrollView.traceEnabled = newValue }
    }

    /// PA4 诊断 seam: 以显式 phase + 合成事件驱动真实 Library 轴仲裁/路由链路
    /// (handlePreciseScroll; 合成 NSEvent 的 phase 字段在本 SDK 不可靠往返,
    /// 因此 phase 由调用方显式提供, 与既有测试 seam 同构)。
    /// 返回事件是否被水平路由到外层分页引擎。
    @discardableResult
    func probeFeed(phase: NSEvent.Phase, event: NSEvent) -> Bool {
        scrollView.handlePreciseScroll(phase: phase, event: event) == .horizontal
    }

    /// PA4 诊断 seam: 沿 momentum 路由处理合成 momentum 事件。
    func probeFeedMomentum(event: NSEvent) {
        scrollView.routeMomentumForProbe(event)
    }

    /// 更新顶部/底部保留带(宿主 chrome 变化; host 经 `AppLibraryHostItem`
    /// 转发, 创建前/后都能应用)。顶部保留带 = 窗口层搜索框 + 间距, 保证第一行
    /// 卡片不与 chrome 重叠; 底部为默认小 padding。
    public func setContentInsets(top: CGFloat, bottom: CGFloat) {
        let t = max(0, top)
        let b = max(0, bottom)
        if let layout = gridCollectionView.collectionViewLayout as? AppLibraryLayout {
            layout.setContentInsets(top: t, bottom: b)
        } else {
            pendingContentInsets = (t, b)
        }
    }

    /// 外层接入/测试 seam: 卡片网格。
    public var collectionView: NSCollectionView { gridCollectionView }

    /// 测试 seam: 当前打开的 detail(未打开时为 nil)。
    var presentedDetail: AppLibraryDetailViewController? { detailController }

    /// 关闭当前 detail(幂等; 不关闭 Library 本身)。
    /// 由宿主在 Settings 打开 / Launcher 隐藏 / 离开 Library surface 时调用。
    func dismissDetailIfPresent() {
        guard detailController != nil else { return }
        closeDetail()
    }

    // MARK: - View lifecycle

    public override func loadView() {
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.setAccessibilityLabel(L10n.t(.appLibrary))
        scrollView.setAccessibilityHelp(L10n.t(.libraryCardsHelp))
        scrollView.onHorizontalScroll = { [weak self] event in
            self?.onHorizontalScroll?(event) ?? false
        }
        // PA3: 网格背景与 scroll 容器空白都汇到同一处理(controller 层统一门控)。
        scrollView.onBlankClick = { [weak self] in
            self?.handleBlankClick()
        }
        gridCollectionView.onBlankClick = { [weak self] in
            self?.handleBlankClick()
        }

        gridCollectionView.collectionViewLayout = AppLibraryLayout(
            mode: .grid,
            contentInsets: AppLibraryLayoutMetrics.defaultContentInsets
        )
        if let pending = pendingContentInsets {
            (gridCollectionView.collectionViewLayout as? AppLibraryLayout)?
                .setContentInsets(top: pending.top, bottom: pending.bottom)
            pendingContentInsets = nil
        }
        gridCollectionView.backgroundColors = [.clear]
        gridCollectionView.isSelectable = false
        gridCollectionView.allowsMultipleSelection = false
        gridCollectionView.setAccessibilityLabel(L10n.t(.appLibrary))
        gridCollectionView.setAccessibilityHelp(L10n.t(.libraryCardsHelp))
        gridCollectionView.register(
            AppLibraryCardCell.self,
            forItemWithIdentifier: AppLibraryCardCell.reuseIdentifier
        )
        dataSource = NSCollectionViewDiffableDataSource<Int, AppLibraryCardID>(
            collectionView: gridCollectionView
        ) { [weak self] collectionView, indexPath, cardID in
            guard let self,
                  let card = self.model.cards.first(where: { $0.id == cardID }) else { return nil }
            let cell = collectionView.makeItem(
                withIdentifier: AppLibraryCardCell.reuseIdentifier, for: indexPath
            ) as? AppLibraryCardCell
            guard let cell else { return nil }
            let primary = card.primaryAppIDs.map { (appID: $0, name: self.displayName($0)) }
            let mini = card.miniAppIDs.map { (appID: $0, name: self.displayName($0)) }
            cell.onAction = { [weak self] action in
                self?.handleAction(action, card: card)
            }
            cell.onCategoryMenu = { [weak self] appID, windowPoint in
                self?.presentCategoryMenu(for: appID, at: windowPoint)
            }
            cell.configure(
                cardID: card.id,
                title: Self.title(for: card),
                primary: primary,
                mini: mini,
                provider: self.iconProvider,
                backingScale: self.currentBackingScale,
                reducedMotion: MotionEnvironment.reduceMotion
            )
            return cell
        }

        scrollView.documentView = gridCollectionView
        gridCollectionView.autoresizingMask = []
        view = scrollView

        reloadCards()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        updateDocumentFrame()
    }

    // MARK: - 卡片标题

    private static func title(for card: AppLibraryCard) -> String {
        switch card.id {
        case .suggestions:
            return L10n.t(.suggestions)
        case .recentlyAdded:
            return L10n.t(.recentlyAdded)
        case .category(let category):
            return L10n.categoryTitle(for: category)
        }
    }

    // MARK: - 模型刷新

    private func reloadCards() {
        guard let dataSource else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, AppLibraryCardID>()
        snapshot.appendSections([0])
        snapshot.appendItems(model.cards.map(\.id))

        var reloaded: [AppLibraryCardID] = []
        for card in model.cards {
            guard let previous = previousCards[card.id], previous != card else { continue }
            reloaded.append(card.id)
        }
        if !reloaded.isEmpty {
            snapshot.reloadItems(reloaded)
        }
        dataSource.apply(snapshot, animatingDifferences: false)

        var updated: [AppLibraryCardID: AppLibraryCard] = [:]
        updated.reserveCapacity(model.cards.count)
        for card in model.cards {
            updated[card.id] = card
        }
        previousCards = updated
    }

    private func updateDocumentFrame() {
        guard let layout = gridCollectionView.collectionViewLayout else { return }
        let size = layout.collectionViewContentSize
        guard size.width > 0, size.height > 0 else { return }
        if gridCollectionView.frame.size != size {
            gridCollectionView.frame.size = size
        }
    }

    private var currentBackingScale: Int {
        let scale = view.window?.backingScaleFactor ?? 2
        return max(1, Int(scale.rounded()))
    }

    // MARK: - 交互路由

    /// PA3: 真空白点击统一入口(网格背景 / scroll 容器)。
    /// detail 打开时(`isScrollPaused` / `detailController != nil`)不得触发
    /// 空白隐藏 —— detail 根视图覆盖并消费全部点击, 这里再门控一次是防御性
    /// 兜底(保证任何路径都不在 detail 期隐藏 Library)。
    private func handleBlankClick() {
        guard detailController == nil, !scrollView.isScrollPaused else { return }
        onBlankClick?()
    }

    private func handleAction(_ action: AppLibraryCardCell.Action, card: AppLibraryCard) {
        switch action {
        case .launch(let appID):
            onLaunch(appID)
        case .openDetail:
            openDetail(for: card)
        }
    }

    private func openDetail(for card: AppLibraryCard) {
        guard detailController == nil else { return }
        let detail = AppLibraryDetailViewController(
            title: Self.title(for: card),
            appIDs: card.detailAppIDs,
            displayName: displayName,
            iconProvider: iconProvider,
            onSelect: { [weak self] appID in
                self?.closeDetail()
                self?.onLaunch(appID)
            },
            onClose: { [weak self] in
                self?.closeDetail()
            },
            onCategoryMenu: { [weak self] appID, windowPoint in
                self?.presentCategoryMenu(for: appID, at: windowPoint)
            }
        )
        addChild(detail)
        detail.view.frame = view.bounds
        detail.view.autoresizingMask = [.width, .height]
        detail.view.alphaValue = 0
        view.addSubview(detail.view)
        detailController = detail
        // detail 打开期间暂停 Library 自身滚动(滚轮事件不透传)。
        scrollView.isScrollPaused = true
        onDetailChange?(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MotionEnvironment.launcherFadeDuration
            context.allowsImplicitAnimation = true
            detail.view.alphaValue = 1
        }
    }

    private func closeDetail() {
        guard let detail = detailController else { return }
        detail.view.removeFromSuperview()
        detail.removeFromParent()
        detailController = nil
        scrollView.isScrollPaused = false
        onDetailChange?(false)
    }

    // MARK: - 手动分类覆盖菜单(PA2)

    /// 右键入口: 卡片大图标 / detail 行。无覆盖能力时不做任何事。
    private func presentCategoryMenu(for appID: AppID, at windowPoint: NSPoint) {
        guard let menu = makeCategoryMenu(for: appID),
              let window = view.window else { return }
        menu.popUp(positioning: nil, at: windowPoint, in: window.contentView)
    }

    /// 构建分类菜单(测试 seam; 不弹窗)。
    ///
    /// 结构: "Move to Category" 子菜单(固定 category 优先级, 当前生效分类打勾)
    /// + 分隔线 + "Automatic Classification"(当前为手动时选择即移除 override)。
    func makeCategoryMenu(for appID: AppID) -> NSMenu? {
        guard let overriding = categoryOverriding else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let moveItem = NSMenuItem(
            title: L10n.t(.moveToCategory), action: nil, keyEquivalent: ""
        )
        let submenu = NSMenu()
        let effective = effectiveCategory(for: appID)
        for category in AppLibraryCategory.allCases {
            let item = NSMenuItem(
                title: L10n.categoryTitle(for: category),
                action: #selector(applyCategoryOverride(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = CategoryMenuItemPayload(appID: appID, category: category)
            if category == effective {
                item.state = .on
            }
            submenu.addItem(item)
        }
        moveItem.submenu = submenu
        menu.addItem(moveItem)

        menu.addItem(.separator())

        let automatic = NSMenuItem(
            title: L10n.t(.automaticClassification),
            action: #selector(clearCategoryOverride(_:)),
            keyEquivalent: ""
        )
        automatic.target = self
        automatic.representedObject = appID
        if overriding.categoryOverrides[appID] == nil {
            automatic.state = .on
        }
        menu.addItem(automatic)
        return menu
    }

    /// 当前生效分类: 从 model 的 `categoryDetail` partition 反查
    /// (每个可见 app 恰好属于一个分类, 含合并进 Other 的)。
    private func effectiveCategory(for appID: AppID) -> AppLibraryCategory? {
        for (category, ids) in model.categoryDetail where ids.contains(appID) {
            return category
        }
        return nil
    }

    @objc func applyCategoryOverride(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? CategoryMenuItemPayload,
              let overriding = categoryOverriding else { return }
        Task { [weak overriding] in
            await overriding?.setCategoryOverride(appID: payload.appID, category: payload.category)
        }
    }

    @objc func clearCategoryOverride(_ sender: NSMenuItem) {
        guard let appID = sender.representedObject as? AppID,
              let overriding = categoryOverriding else { return }
        Task { [weak overriding] in
            await overriding?.clearCategoryOverride(appID: appID)
        }
    }

    private struct CategoryMenuItemPayload {
        let appID: AppID
        let category: AppLibraryCategory
    }

    // MARK: - 诊断 seam(E10 visual evidence)

    /// E10 诊断: 打开第一个 category 分类卡 detail(幂等; 无分类卡返回 false)。
    /// 只导航/读取, 不写 Layout/Config/Usage。
    func openFirstCategoryDetailForDiagnostic() -> Bool {
        guard detailController == nil else { return true }
        guard let card = model.cards.first(where: { card in
            if case .category = card.id { return true }
            return false
        }) else { return false }
        openDetail(for: card)
        return detailController != nil
    }

    /// E10 诊断: Library 内垂直滚动到内容 `fraction`(45%-60%)处。只改变
    /// session 内 vertical offset, 不触发 catalog scan。内容不足一屏时
    /// 记录 stable no-op(返回 scrolled=false)。
    func scrollVerticalToFractionForDiagnostic(_ fraction: Double) -> (scrolled: Bool, fraction: Double) {
        let clip = scrollView.contentView
        guard let document = scrollView.documentView else { return (false, 0) }
        let maxOffset = max(0, document.frame.height - clip.bounds.height)
        guard maxOffset > 0 else { return (false, 0) }
        let clamped = min(max(fraction, 0), 1)
        clip.scroll(to: NSPoint(x: 0, y: maxOffset * clamped))
        scrollView.reflectScrolledClipView(clip)
        return (true, Double(clip.bounds.origin.y / maxOffset))
    }

    /// E10 诊断: 卡片 / 可见 cell / detail 状态快照。
    func libraryShotCounts() -> String {
        "cards=\(model.cards.count) visible=\(gridCollectionView.visibleItems().count) detail=\(detailController == nil ? 0 : 1)"
    }
}

/// App Library 空白点击会话(PA3, 类似 ClickableCollectionView 的鼠标会话模式)。
///
/// 语义: mouseDown 在空白命中后记录按下点; mouseUp 时若位移 ≤ 6pt 且 up 点
/// 仍为空白, 才算一次有效空白点击。拖出(位移超阈值)自动作废, 不会累积到
/// 下一次会话。mouseUp 无配对 mouseDown → 一律忽略(覆盖层场景)。
@MainActor
struct LibraryBlankClickSession {
    static let threshold: CGFloat = 6

    private(set) var downPoint: NSPoint?
    private(set) var armed = false

    mutating func arm(at point: NSPoint) {
        downPoint = point
        armed = true
    }

    mutating func reset() {
        downPoint = nil
        armed = false
    }

    /// 返回 true = 本次会话为有效空白点击(位移 ≤ 阈值)。任何路径都清空会话。
    mutating func release(at point: NSPoint) -> Bool {
        defer { reset() }
        guard armed, let start = downPoint else { return false }
        let dx = point.x - start.x
        let dy = point.y - start.y
        return dx * dx + dy * dy <= Self.threshold * Self.threshold
    }
}

/// App Library 网格集合视图(flipped, y-down): 与 `AppLibraryLayout` 的
/// y-down frame 数学一致, 垂直滚动时 bounds.origin 同步正确。
///
/// PA3: 承载真空白点击会话。空白 = 网格集合视图背景(`indexPathForItem == nil`);
/// 卡片点击由 `LibraryCardRootView` 自身消费(不调用 super), 不会到达这里;
/// 滚动条由 NSScroller 消费; detail 打开时 detail 根视图覆盖并消费全部点击。
@MainActor
final class BlankClickLibraryCollectionView: NSCollectionView {
    override var isFlipped: Bool { true }

    /// PA3: 真空白点击回调(mouseDown→mouseUp 空白 + 位移 ≤ 6pt)。
    var onBlankClick: (() -> Void)?

    private var blankSession = LibraryBlankClickSession()

    override func mouseDown(with event: NSEvent) {
        let point = event.locationInWindow
        if isBlank(at: point) {
            blankSession.arm(at: point)
        } else {
            blankSession.reset()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = event.locationInWindow
        guard isBlank(at: point), blankSession.release(at: point) else { return }
        onBlankClick?()
    }

    private func isBlank(at windowPoint: NSPoint) -> Bool {
        let local = convert(windowPoint, from: nil)
        return indexPathForItem(at: local) == nil
    }
}

/// Library 自身的垂直滚动容器 + 水平/垂直轴仲裁路由(Stage E9b)。
///
/// 事件所有权:
/// - detail/owner paused(`isScrollPaused`, E9a gate)优先级最高: 消费所有 scroll,
///   既不滚动 Library, 也不冒泡到外层 Grid 翻页。
/// - 非 precise(鼠标滚轮): 无连续手势, 单次事件即决定性(垂直 → 内部滚动;
///   水平 → 外层 handler)。
/// - precise 手势: 经 `AppLibraryAxisArbiter` 仲裁。undecided 期间消费小样本;
///   vertical 锁定后当前及后续事件交内部 NSScrollView;horizontal 锁定后交注入的
///   `GridViewController.handleAppLibraryHorizontalScroll`(复用外层
///   PagingInteractionController 的唯一 settle/display-link 引擎)。
/// - 外层分页只在仲裁器锁定 horizontal 后才接收事件(.began 锁定才播种手势配对);
///   vertical/undecided 事件从不交付外层, 不产生假分页状态。
/// - 手势以 undecided/diagonal 起步时暂存 began 事件; 后续锁定 horizontal 时在
///   首个 horizontal 事件前重放 began 给外层(播种 began→changed→ended 手势配对:
///   PagingInteractionController 的 feedTracking 以 began 的 beginGesture 为前提,
///   缺 began 时整个水平手势会被静默丢弃)。锁定 vertical / 手势 ended 仍
///   undecided 时丢弃 began。
/// - horizontal handler 返回 false 仍消费事件, 绝不把已锁定 horizontal 事件交给
///   vertical scroll(避免双向同时运动)。
/// - ended/cancelled 后重置 arbiter; momentum 沿手势锁定轴路由。
@MainActor
final class PausableLibraryScrollView: NSScrollView {
    /// true = 消费但不执行滚动(detail 打开期间)。
    var isScrollPaused = false

    /// PA3: scroll 容器空白点击回调(点在文档视图 frame 之外的非卡片区域,
    /// 如内容不足一屏时的底部留白)。detail 打开期间不记录。
    var onBlankClick: (() -> Void)?

    /// 水平滚动路由(宿主注入, 复用外层分页引擎)。
    var onHorizontalScroll: ((NSEvent) -> Bool)?

    private var arbiter = AppLibraryAxisArbiter()
    /// 手势结束后的 momentum 路由(下次 .began / momentum 结束清除)。
    private var momentumRoute: AppLibraryAxisRoute = .undecided
    /// 未决 began 事件: 手势以 undecided 起步时暂存, 锁定 horizontal 时重放给
    /// 外层播种手势配对; 锁定 vertical / ended 仍 undecided / paused 时丢弃。
    private var pendingBeganEvent: NSEvent?

    /// PA4: 逐事件 trace(`--pagingeventtrace` 时开启, 诊断用途)。
    var traceEnabled = false {
        didSet {
            guard traceEnabled else { return }
            trace("library traceEnabled")
        }
    }

    /// PA4: 轴仲裁 + 路由状态一行(traceEnabled 时写共享 log)。
    private func trace(_ detail: String) {
        guard traceEnabled else { return }
        PagingTraceLog.record(
            "library \(detail) arbiter=\(String(describing: arbiter.state)) "
                + "route=\(String(describing: arbiter.route)) "
                + "pendingBegan=\(pendingBeganEvent != nil ? 1 : 0) "
                + "momentumRoute=\(String(describing: momentumRoute)) "
                + "paused=\(isScrollPaused ? 1 : 0)"
        )
    }

    /// PA3: 容器空白点击会话(mouseDown→mouseUp 空白 + 位移 ≤ 6pt)。
    private var blankSession = LibraryBlankClickSession()

    override func mouseDown(with event: NSEvent) {
        // detail/owner paused: 空白点击由 detail 根视图消费, 本层不记录。
        guard !isScrollPaused else {
            blankSession.reset()
            return
        }
        let point = event.locationInWindow
        if isScrollContainerBlank(at: point) {
            blankSession.arm(at: point)
        } else {
            blankSession.reset()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = event.locationInWindow
        guard isScrollContainerBlank(at: point), blankSession.release(at: point) else { return }
        onBlankClick?()
    }

    /// scroll 容器空白 = 点不在文档视图(网格) frame 内。
    private func isScrollContainerBlank(at windowPoint: NSPoint) -> Bool {
        guard let document = documentView else { return true }
        let local = convert(windowPoint, from: nil)
        let documentFrame = convert(document.frame, from: document.superview)
        return !documentFrame.contains(local)
    }

    override func scrollWheel(with event: NSEvent) {
        // detail/owner paused 优先级最高(E9a gate): 消费所有 scroll, 并先重置
        // 仲裁器 / momentum 路由 / 未决 began, 防止暂停期间残留锁定污染下一手势。
        guard !isScrollPaused else {
            trace("wheel pausedPhase=\(event.phase) momentum=\(event.momentumPhase)")
            arbiter.end()
            momentumRoute = .undecided
            pendingBeganEvent = nil
            return
        }

        trace(
            "wheel phase=\(event.phase) momentum=\(event.momentumPhase) "
                + "dx=\(Int(event.scrollingDeltaX)) dy=\(Int(event.scrollingDeltaY))"
        )

        if event.momentumPhase != [] {
            routeMomentum(event)
            return
        }

        if !event.hasPreciseScrollingDeltas {
            routeDiscrete(event)
            return
        }

        if event.phase == [] {
            // 无 phase 的连续滚动输入(部分鼠标/辅助输入): 逐事件决定性路由,
            // 避免 undecided 消费策略吞掉全部滚动。
            routeByPerEventDominance(event)
            return
        }

        handlePreciseScroll(phase: event.phase, event: event)
    }

    /// 有 phase 的 precise 连续手势路由。
    ///
    /// phase 由调用方显式提供(scrollWheel 传真实 phase; 测试经此 seam 注入
    /// phase, 因为合成 NSEvent 的 phase 字段在本 SDK 不可靠往返),
    /// 事件对象仅提供 deltas。
    ///
    /// began 未锁定(undecided/diagonal)时暂存原 began 事件; 一旦后续 changed
    /// 累计锁定 horizontal, 在交付首个 horizontal 事件前先重放 began 给外层
    /// PagingInteractionController(其 feedTracking 以 began 的 beginGesture
    /// 为前提, 缺 began 则整个手势被静默丢弃)。锁定 vertical / ended 仍
    /// undecided 时丢弃 began。
    /// - Returns: 本次累计后的路由(PA4 探针用于断言 horizontal 交付)。
    @discardableResult
    func handlePreciseScroll(phase: NSEvent.Phase, event: NSEvent) -> AppLibraryAxisRoute {
        switch phase {
        case .began:
            arbiter.begin()
            momentumRoute = .undecided
            // .began 可能携带首批位移(快速甩动): 先累计; 仅当仲裁器在开始
            // 即锁定 horizontal 时才立即种子外层分页手势(began→changed→ended
            // 配对)。未锁定(undecided/diagonal)暂存 began 等待重放;
            // 锁定 vertical 不触碰外层, 不产生假分页手势。
            let route = arbiter.accumulate(
                deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY
            )
            trace("precise began route=\(route)")
            if route == .horizontal {
                _ = onHorizontalScroll?(event)
            } else if route == .undecided {
                pendingBeganEvent = event
            }
            return route
        case .ended, .cancelled:
            let route = arbiter.accumulate(
                deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY
            )
            trace("precise \(phase == .ended ? "ended" : "cancelled") route=\(route)")
            // 只按锁定路由交付: horizontal → 先重放暂存 began 再交 ended
            // (与 began 配对并触发 settle); vertical → 内部滚动;
            // vertical/undecided 绝不额外送达外层, 并丢弃 began。
            replayPendingBeganIfHorizontal(route: route)
            apply(route: route, event: event)
            if route != .undecided, phase == .ended {
                momentumRoute = route
            }
            arbiter.end()
            pendingBeganEvent = nil
            return route
        default:
            break
        }

        let route = arbiter.accumulate(
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY
        )
        // 首个 horizontal changed: 在交付当前事件前重放 began 播种外层手势配对。
        replayPendingBeganIfHorizontal(route: route)
        trace("precise changed route=\(route)")
        apply(route: route, event: event)
        return route
    }

    /// horizontal 锁定且存在未决 began 时: 先重放 began 给外层, 再清除
    /// (每个手势只播种一次)。
    private func replayPendingBeganIfHorizontal(route: AppLibraryAxisRoute) {
        guard route == .horizontal, let began = pendingBeganEvent else { return }
        pendingBeganEvent = nil
        _ = onHorizontalScroll?(began)
    }

    private func apply(route: AppLibraryAxisRoute, event: NSEvent) {
        switch route {
        case .vertical:
            super.scrollWheel(with: event)
        case .horizontal:
            // handler 返回 false 仍消费: 已锁定 horizontal 事件不得落回垂直滚动。
            _ = onHorizontalScroll?(event)
        case .undecided:
            break
        }
    }

    /// 非 precise(鼠标滚轮): 无连续手势, 单次事件即决定性。
    private func routeDiscrete(_ event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            _ = onHorizontalScroll?(event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// 无 phase 的 precise 连续输入: 逐事件决定性路由。
    private func routeByPerEventDominance(_ event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            _ = onHorizontalScroll?(event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// momentum 沿手势锁定轴: vertical → 内部惯性滚动; horizontal → 外层分页
    /// (其 momentum 全拦截, 0 位移 0 snap, 不产生第二次 settle)。
    private func routeMomentum(_ event: NSEvent) {
        trace(
            "momentum momentumPhase=\(event.momentumPhase) dx=\(Int(event.scrollingDeltaX)) "
                + "dy=\(Int(event.scrollingDeltaY)) route=\(String(describing: momentumRoute))"
        )
        switch momentumRoute {
        case .vertical:
            super.scrollWheel(with: event)
        case .horizontal:
            _ = onHorizontalScroll?(event)
        case .undecided:
            break
        }
        if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            momentumRoute = .undecided
        }
    }

    /// PA4 诊断 seam: 直接沿 momentum 路由处理(合成事件 phase 往返不可靠)。
    func routeMomentumForProbe(_ event: NSEvent) {
        routeMomentum(event)
    }
}
