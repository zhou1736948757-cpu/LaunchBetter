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

    private var model: AppLibraryModel
    private var previousCards: [AppLibraryCardID: AppLibraryCard] = [:]
    private var sessionFrozen = false

    private let scrollView = PausableLibraryScrollView()
    private let gridCollectionView = LibraryCollectionView()
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

    public init(
        model: AppLibraryModel,
        displayName: @escaping (AppID) -> String,
        iconProvider: (any IconImageProviding)?,
        onLaunch: @escaping (AppID) -> Void
    ) {
        self.model = model
        self.displayName = displayName
        self.iconProvider = iconProvider
        self.onLaunch = onLaunch
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

    /// 结束固定 session: 解除模型冻结(host 复用 / Launcher 隐藏时调用)。
    /// 之后 `apply(model:)` 恢复生效; 宿主再次 `beginSession` 用最新模型重新固定。
    public func endSession() {
        sessionFrozen = false
    }

    /// 外层接入/测试 seam: 垂直滚动容器。
    public var verticalScrollView: NSScrollView { scrollView }

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

    /// 水平滚动路由(宿主注入, 复用外层分页引擎)。
    var onHorizontalScroll: ((NSEvent) -> Bool)?

    private var arbiter = AppLibraryAxisArbiter()
    /// 手势结束后的 momentum 路由(下次 .began / momentum 结束清除)。
    private var momentumRoute: AppLibraryAxisRoute = .undecided
    /// 未决 began 事件: 手势以 undecided 起步时暂存, 锁定 horizontal 时重放给
    /// 外层播种手势配对; 锁定 vertical / ended 仍 undecided / paused 时丢弃。
    private var pendingBeganEvent: NSEvent?

    override func scrollWheel(with event: NSEvent) {
        // detail/owner paused 优先级最高(E9a gate): 消费所有 scroll, 并先重置
        // 仲裁器 / momentum 路由 / 未决 began, 防止暂停期间残留锁定污染下一手势。
        guard !isScrollPaused else {
            arbiter.end()
            momentumRoute = .undecided
            pendingBeganEvent = nil
            return
        }

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
    func handlePreciseScroll(phase: NSEvent.Phase, event: NSEvent) {
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
            if route == .horizontal {
                _ = onHorizontalScroll?(event)
            } else if route == .undecided {
                pendingBeganEvent = event
            }
            return
        case .ended, .cancelled:
            let route = arbiter.accumulate(
                deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY
            )
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
            return
        default:
            break
        }

        let route = arbiter.accumulate(
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY
        )
        // 首个 horizontal changed: 在交付当前事件前重放 began 播种外层手势配对。
        replayPendingBeganIfHorizontal(route: route)
        apply(route: route, event: event)
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
}
