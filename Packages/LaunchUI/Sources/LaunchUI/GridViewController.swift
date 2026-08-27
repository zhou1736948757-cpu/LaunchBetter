import AppKit
import LaunchCore
import QuartzCore

/// Runtime diagnostic switches owned by the paging controller wiring.
/// Keeping flag interpretation here gives tests a real configuration seam
/// without depending on the process-wide CommandLine arguments.
struct PagingDiagnosticsConfiguration: Equatable, Sendable {
    let pageCompositorEnabled: Bool
    let pagingFeelTelemetryEnabled: Bool

    init(arguments: [String]) {
        pageCompositorEnabled = arguments.contains("--pagecompositor")
        pagingFeelTelemetryEnabled = arguments.contains("--pagingfeeltelemetry")
    }
}

/// 外层 diffable data source 的 item 包装(Stage E8)。
///
/// - `.appLibrary`: 物理 section 0 的 Library host, 恒单 item。
/// - `.layout(item)`: 普通 display item(页面内容 / 搜索结果)。
///
/// 普通 `Item`/Folder/Drag/diagnostic 调用方仍只面对
/// `DisplayModel.DisplayItem`;host 不产生 AppCell/Drag identity。
enum LauncherSurfaceItem: Hashable {
    case appLibrary
    case layout(DisplayModel.DisplayItem)
}

enum GridDragSourceIdentity: Equatable {
    case app(AppID)
    case folder(FolderID)

    init(item: DisplayModel.DisplayItem) {
        switch item {
        case .app(let id):
            self = .app(id)
        case .folder(let id):
            self = .folder(id)
        }
    }
}

/// 光标命中的拖拽目标语义分类(§A3): 每帧一次索引命中后, 文件夹悬停与
/// App→App 建夹共用这一分类, 不再重复 indexPathForItem。
enum DragHitTarget: Equatable {
    case none
    case app(AppID)
    case folder(FolderID)

    var pointedApp: AppID? {
        if case .app(let id) = self { return id }
        return nil
    }
}

/// Folder source 的纯 revision seam。捕获 token 前先同步 GridGeometry；后续动画帧
/// 只比较 UInt64，不重新查询 NSView、Store 或 diffable data source。
struct FolderTransitionSourceRevision {
    private(set) var value: UInt64 = 0
    private(set) var geometry: GridGeometry?

    mutating func invalidate() {
        value &+= 1
    }

    mutating func synchronizeGeometry(_ current: GridGeometry) {
        guard geometry != current else { return }
        geometry = current
        invalidate()
    }

    mutating func capture(synchronizing current: GridGeometry) -> UInt64 {
        synchronizeGeometry(current)
        return value
    }

    func isCurrent(_ token: UInt64) -> Bool {
        value == token
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
    private let renamePromptPresenter = RenamePromptPresenter()
    /// Test seam for verifying that context-menu rename remains launcher-owned.
    var activeRenameAlert: NSAlert? { renamePromptPresenter.activeAlert }
    var activeRenameTextField: NSTextField? { renamePromptPresenter.activeTextField }
    private var collectionView: NSCollectionView!
    private var scrollView: NSScrollView!
    private var dataSource: NSCollectionViewDiffableDataSource<Int, LauncherSurfaceItem>!
    private var cachedDisplayItems: [Item] = []
    private var cachedSectionCounts: [Int] = []
    private var currentPage = 0
    private var pageCount = 1
    /// 语义 surface(默认 `.layoutPage(0)`, 即物理 1)。
    private var currentSurface: LauncherSurface = .layoutPage(0)
    /// 进入 Search 前保存的语义 surface(不是 raw page number, Stage E8)。
    private var surfaceBeforeSearch: LauncherSurface = .layoutPage(0)
    /// 当前页(诊断)。
    var currentPageValue: Int { currentPage }

    /// 页数(诊断, 普通 Layout page count, ≥ 1)。
    var pageCountValue: Int { pageCount }

    /// 当前语义 surface(诊断/导航)。
    var currentSurfaceValue: LauncherSurface { currentSurface }

    /// 是否启用 leading surface(物理 section 0 = App Library host)。
    /// 仅当 store 提供 `AppLibraryDataProviding` 时启用, 否则保持既有
    /// 单表面几何/分页语义(所有非 provider 测试替身不受影响)。
    private var leadingSurfaceEnabled: Bool { store is any AppLibraryDataProviding }

    /// 物理 section 偏移: paged + leading = 1; search 恒 0。
    private var ordinarySectionOffset: Int {
        (searchMode || !leadingSurfaceEnabled) ? 0 : 1
    }

    /// 普通 Layout 页在文档坐标中的 leading 偏移(未启用时 0)。
    private var leadingDocumentOffset: CGFloat {
        (searchMode || !leadingSurfaceEnabled) ? 0 : geometry.pageWidth
    }

    /// 物理 surface 数(分页引擎用): leading = 普通页数 + 1(Library), 否则 = 普通页数。
    /// 搜索模式禁用 leading surface, 单垂直 section → 恒 1。
    var physicalSurfaceCount: Int {
        if searchMode { return 1 }
        return leadingSurfaceEnabled
            ? LauncherSurfaceIndex(layoutPageCount: pageCount).physicalSurfaceCount
            : pageCount
    }

    /// 当前物理 surface 索引: 0 = App Library, n + 1 = Layout page n。
    /// 初始值 1 = `.layoutPage(0)`; 未启用 leading 时 = 普通 currentPage。
    /// 搜索模式禁用 leading surface → 恒 0。
    var physicalSurfaceIndex: Int {
        if searchMode { return 0 }
        return leadingSurfaceEnabled
            ? LauncherSurfaceIndex(layoutPageCount: pageCount).physicalIndex(for: currentSurface)
            : currentPage
    }

    /// App Library host(物理 section 0 的内容)。
    private lazy var hostItem = AppLibraryHostItem(store: store, iconProvider: iconProvider)

    /// 分页交互控制器(v0.1.6): 手势状态 + 唯一 offset writer。
    private let paging = PagingInteractionController()

    /// Library-only 数据观察者 token(P3-I): 元数据变更(launch usage / category
    /// override)经此触发 `hostItem.refreshModel()`, 与 grid `refresh()` 的
    /// displayRevision 门解耦 —— 不 bump revision、不触发 grid 全量刷新。
    private var libraryDataObserverToken: UUID?

    // MARK: - P2 Page Compositor(实验, 默认关)

    /// 页面视觉缓存(working set ≤ 3)与渲染器(纯内存, idle 准备)。
    private let pageVisualCache = PageVisualCache()
    private let pageVisualRenderer = PageVisualRenderer()
    /// presentation-only 合成器: PagingInteractionController 仍是唯一运动引擎。
    let pageCompositor = PageCompositor()

    /// T-002: 激活原因遥测(默认关; `--pagingfeeltelemetry` 开启)。观察者, 不改变激活判断。
    let pageCompositorActivationTelemetry = PageCompositorActivationTelemetry()

    /// T-027: 分页性能遥测 recorder(默认关; `--paging-perf` 开启)。观察者,
    /// 只做计数/耗时聚合, 不改变任何行为; 默认路径不接线(perfRecorder == nil)。
    private let pagingPerfTelemetry = PagingPerfTelemetry()

    /// T-002: 本次手势起点快照的 paging 计数(用于按手势差分 displayFrame/scrollWrite)。
    private var compositorTelemetryStartDisplayFrames = 0
    private var compositorTelemetryStartScrollWrites = 0
    private var telemetryCompletionReason: GestureTelemetryCompletionReason = .settled
    private var telemetrySettleDurationMs: Double?

    /// 分页合成架构(v0.5.0 起默认启用, 用户决策 2026-08-21): Idle 用真实 Cell,
    /// Tracking/Settling 只移动当前页+目标页的预渲染合成表面(PageVisual);
    /// 视觉未就绪/不满足资格门时无条件 live 降级, 绝不阻塞手势起点。
    /// `--disable-pagecompositor` 是紧急 kill switch(任何情况下强制关闭)。
    /// 测试可直接置 true/false 驱动确定性场景(`--pagecompositor` 仍用于 A/B 遥测探针)。
    var pageVisualCompositorEnabled = {
        return !CommandLine.arguments.contains("--disable-pagecompositor")
    }()

    /// 内存压力监听(L10): 注释声称的 purge 此前无监听。macOS 的 AppKit 没有
    /// 内存警告通知(iOS 才有 `UIApplicationDidReceiveMemoryWarningNotification`),
    /// 真实机制是 `DispatchSourceMemoryPressure`——loadView 时注册(主队列),
    /// 回调 purgePageVisuals(); deinit 取消源, 不泄漏。
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// 诊断 seam: purgePageVisuals 触发次数(内存压力 / 显式 purge 共用)。
    private(set) var memoryPressurePurgeCountForDiag = 0

    /// 诊断 seam: 内存压力事件源是否已注册(测试生命周期断言)。
    var memoryPressureObserverRegisteredForDiag: Bool { memoryPressureSource != nil }

    /// 密度门: 当前普通页项数低于该值不合成(稀疏页 live 合成成本低, 无收益;
    /// 密集页才是目标)。测试可调低覆盖默认 3 项/页的替身。
    var pageVisualMinItemsPerPage = 20

    /// prepare 代际: 每次调度递增, 过期 prepare 不得插入缓存(结构已变)。
    private var pageVisualPrepareGeneration = 0

    /// 在途防抖 prepare 任务(L15): 每次调度先取消旧任务, 完成后置 nil。
    /// 防止快速连续变化时多个 100ms 防抖任务堆积、旧任务在结构已变后仍执行。
    private var pageVisualPrepareTask: Task<Void, Never>?

    /// 在途 working set 准备(串行化; 重复调用 await 同一任务)。
    private var pageVisualPrepareInFlight: Task<Void, Never>?

    /// 最近一次准备时快照的语言代数: 激活检查与缓存键共用同一值, 自洽
    /// (语言切换走 Settings/refresh → shutdown + purge + 重建, 无陈旧窗口)。
    private var lastPreparedLanguageRevision: UInt64 = GridViewController.languageRevision()

    /// 最近一次观察到的 backing scale(换屏 → 收掉/重建视觉)。
    private var lastCompositorBackingScale = -1

    /// 当前几何(拖拽/槽位计算用; 未 prepare 时用实时参数推算)。
    var geometry: GridGeometry {
        let layout = collectionView.collectionViewLayout as? PagingGridLayout
        return layout?.liveGeometry
            ?? GridGeometry(
                columns: store.gridColumns, rows: store.gridRows,
                cellSize: cellSize, iconSize: iconSize,
                horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing,
                pageWidth: collectionView?.bounds.width ?? 0, pageHeight: collectionView?.bounds.height ?? 0,
                topInset: layout?.topInset ?? 160, bottomInset: layout?.bottomInset ?? 40
            )
    }

    /// 顶部/底部保留区(由窗口层计算: 顶部搜索框 + 底部页点)。
    /// 保持 GridGeometry 唯一真值: 只更新布局的可用内容区, 重新 prepare。
    /// 同时把顶部 chrome 保留区转发给 App Library host(底部用 Library 默认
    /// 小 padding, 不吞掉网格页点保留带)。
    func setContentInsets(top: CGFloat, bottom: CGFloat) {
        if gridLayout.topInset != max(0, top) || gridLayout.bottomInset != max(0, bottom) {
            dragController?.invalidateActiveSessionForDisplayChange()
        }
        gridLayout.setContentInsets(top: top, bottom: bottom)
        hostItem.setContentInsets(
            top: max(0, top),
            bottom: AppLibraryLayoutMetrics.defaultContentInsets.bottom
        )
        updateFolderTransitionGeometryRevision()
        refreshCellsIfEffectivePointSizeChanged()
        schedulePageVisualPrepare()
    }

    /// 进入 Folder/Settings 覆盖层: 暂停分页状态机, 停止在途 settle/display link,
    /// 并收掉 compositor(同步收尾, 无僵尸 layer)。
    func suspendPagingForSurface() {
        shutdownPageCompositor()
        paging.isEnabled = false
    }

    /// 离开覆盖层恢复分页; 搜索模式保持禁用。重新准备相邻页视觉。
    func resumePagingForSurface() {
        paging.isEnabled = !searchMode
        schedulePageVisualPrepare()
    }

    /// 当前保留区(布局诊断)。
    func contentInsetsDiagnostics() -> String {
        let g = geometry
        return "topInset=\(Int(g.topInset)) bottomInset=\(Int(g.bottomInset)) available=\(Int(max(0, g.pageHeight - g.topInset - g.bottomInset)))"
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
    /// T-025: 搜索词是 UI ephemeral state, 由 Grid(UI 层)持有; 存储不保有 query。
    /// 由 LauncherWindowController(搜索栏)写入; 变化经 refresh() 重新过滤,
    /// 不递增 displayRevision。
    var searchQuery = ""
    private var lastAppliedLanguage = L10n.currentLanguage
    /// 最近一次用来配置 AppCell/预热图标的有效 pointSize, 防止布局回调循环 reload。
    private var lastConfiguredEffectivePointSize: Int?

    /// 搜索模式(诊断/拖拽开关)。
    var isSearchMode: Bool { searchMode }

    /// 点击文件夹时回调(打开文件夹视图)。
    var onOpenFolder: ((FolderID) -> Void)?

    /// 点击空白处回调(退出启动器)。
    var onClickBlank: (() -> Void)?

    /// 语义 surface 变更回调(Stage E9a)。WindowController 据此同步输入 owner:
    /// `.appLibrary` → `.appLibrary`, `.layoutPage` → `.launcher`。
    var onSurfaceChange: ((LauncherSurface) -> Void)?

    /// App Library category detail 打开/关闭回调(Stage E9a)。由 Library 控制器
    /// 经 host 转发; 打开/关闭必须幂等, WindowController 以当前 owner 门控。
    var onAppLibraryCategoryDetailChange: ((Bool) -> Void)?

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
    /// 单元格边长 = 图标尺寸 + 标签空间(用户反馈: 图标最大档时标签被挤进图标内)。
    private var cellSize: CGFloat { CGFloat(store.iconSize) + 28 }
    private let horizontalSpacing: CGFloat = 28
    private let verticalSpacing: CGFloat = 28
    private var iconSize: CGFloat { CGFloat(store.iconSize) }

    /// 上次应用的显示修订(无变化跳过 full snapshot, Stage 1 §30)。
    private var lastAppliedRevision: UInt64 = .max

    /// T-025: 上次应用的搜索词。搜索词变化(即使修订未变)也要重新过滤并
    /// 应用最新数据; 搜索词未变且修订未变才跳过 full snapshot。
    private var lastAppliedSearchQuery = ""

    /// Folder source 的离散布局/显示修订；过渡帧只读取这个缓存值，不访问 Store。
    private var folderTransitionRevision = FolderTransitionSourceRevision()

    /// 上次应用的文件夹 payload(可见子项, §A14)。子项变化只 reload 对应 folder
    /// item(identity 不变 → 无 delete/insert、无 flicker), 不整表重建。
    private var lastAppliedFolderPayloads: [FolderID: [AppID]] = [:]

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
        let pagedLayout = PagingGridLayout(
            columns: store.gridColumns, rows: store.gridRows,
            cellSize: cellSize, iconSize: iconSize,
            horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing
        )
        pagedLayout.leadingSurfaceEnabled = leadingSurfaceEnabled
        collectionView.collectionViewLayout = pagedLayout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.register(AppCellView.self, forItemWithIdentifier: AppCellView.identifier)
        collectionView.register(AppLibraryHostCell.self, forItemWithIdentifier: AppLibraryHostCell.reuseIdentifier)
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
        // 24pt 交互区 + 负间距 → 视觉点间距保持 ~14pt(原 6pt 点 + 8pt 间距)
        dots.spacing = -10
        dots.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dots)
        NSLayoutConstraint.activate([
            dots.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            dots.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        pageDots = dots
        pageDotViews = []

        // 分页滚动: 集合视图必须包在 NSScrollView 中(否则分页滚动是空操作,
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
        registerMemoryPressureObserver()
    }

    /// L10: 注册内存压力监听(幂等)。事件源挂主队列, 回调直接 purge 页面视觉。
    private func registerMemoryPressureObserver() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // 主队列事件源回调: 与视图层主线程约定一致。
            MainActor.assumeIsolated {
                guard let self else { return }
                self.purgePageVisuals()
                // purge 后立即重排一次 idle 视觉准备: 缓存清空不能把后续手势
                // 永久困在 live 降级路径(空白页 bug 的触发源之一)。
                self.schedulePageVisualPrepare()
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// 测试 seam: 直接触发一次内存压力 purge(等价于事件源回调路径)。
    func triggerMemoryPressurePurgeForDiag() {
        purgePageVisuals()
    }

    /// F10: 取消并清理内存压力事件源(幂等)。
    /// deinit(nonisolated) 与 MainActor 侧 teardown seam 共用这一静态路径,
    /// 避免取消逻辑重复。`nonisolated`: 仅操作 dispatch source(线程安全),
    /// 可在 deinit 中同步调用。
    private nonisolated static func tearDownMemoryPressureSource(_ source: DispatchSourceMemoryPressure?) {
        source?.setEventHandler {}
        source?.cancel()
    }

    /// F10: 内存压力源 teardown seam(幂等): 清 handler → cancel → 置 nil。
    /// 调用后 `memoryPressureObserverRegisteredForDiag == false`;
    /// 重复调用安全。deinit 走同一路径。
    func teardownMemoryPressureObserver() {
        guard let source = memoryPressureSource else { return }
        Self.tearDownMemoryPressureSource(source)
        memoryPressureSource = nil
    }

    deinit {
        Self.tearDownMemoryPressureSource(memoryPressureSource)
        // T-027: 释放时输出尚未输出的 idle 归属摘要(幂等; enabled 关闭时 no-op)。
        // 注意: 不能在此捕获 self(触发 copy-of-self 限制), 仅捕获 recorder 局部值。
        let perfRecorder = pagingPerfTelemetry
        MainActor.assumeIsolated {
            perfRecorder.flushIdleSummaryIfAny()
        }
        // P3-I: 注销 Library-only 数据观察者(幂等)。
        // 硬约束: 本控制器为 @MainActor 类, 所有引用均在主线程持有/释放,
        // deinit 必在主线程执行(与 memoryPressureSource teardown 同一前提)。
        // 若未来该类变为 nonisolated, 此处需改用 nonisolated 清理路径。
        if let token = libraryDataObserverToken {
            MainActor.assumeIsolated {
                store.removeDataObserver(token)
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 文档视图 frame 必须等于布局 contentSize(否则滚动范围只有一页宽)
        updateDocumentFrame()
        refreshCellsIfEffectivePointSizeChanged()
        updateFolderTransitionGeometryRevision()
        // P2: backing scale 变化(换屏)→ 收掉 compositor + purge + 按新 scale 重建。
        let scale = currentBackingScale
        if scale != lastCompositorBackingScale {
            lastCompositorBackingScale = scale
            shutdownPageCompositor()
            purgePageVisuals()
            schedulePageVisualPrepare()
        }
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
        dataSource = NSCollectionViewDiffableDataSource<Int, LauncherSurfaceItem>(
            collectionView: collectionView
        ) { [weak self] _, indexPath, item in
            guard let self else { return nil }
            // T-027: diffable 数据源的真实 cell provider 调用点(每 item 一次)。
            PagingPerfContext.recordCellEvent("cellProvider")
            switch item {
            case .appLibrary:
                let cell = collectionView.makeItem(
                    withIdentifier: AppLibraryHostCell.reuseIdentifier, for: indexPath
                ) as? AppLibraryHostCell
                configureHost(cell)
                return cell
            case .layout(let layoutItem):
                // host 复用: 离开 Library 时释放冻结 session, 下次进入取最新 model。
                hostItem.endSession()
                let cell = collectionView.makeItem(
                    withIdentifier: AppCellView.identifier, for: indexPath
                ) as? AppCellView
                configure(cell, with: layoutItem)
                return cell
            }
        }
        collectionView.dataSource = dataSource
        // detail 状态转发: Library 控制器 → host → Grid → Window。
        hostItem.onDetailChange = { [weak self] open in
            guard let self else { return }
            self.onAppLibraryCategoryDetailChange?(open)
        }
        // 水平滚动路由: Library → host → Grid 复用外层分页引擎(Stage E9b)。
        hostItem.onAppLibraryHorizontalScroll = { [weak self] event in
            self?.handleAppLibraryHorizontalScroll(event) ?? false
        }
        // PA3: Library 真空白点击 → 复用既有 onClickBlank(已 → window hide),
        // 不新建第二套 hide 实现。
        hostItem.onBlankClick = { [weak self] in
            self?.onClickBlank?()
        }
        // P3-I: Library-only 元数据变更(launch usage / category override)经
        // dataObservers 触发 host live 刷新, 不依赖 grid refresh() 的
        // displayRevision 门(该门只对 grid-visible 结构变更递增)。
        if let existing = libraryDataObserverToken {
            store.removeDataObserver(existing)
        }
        libraryDataObserverToken = store.addDataObserver { [weak self] in
            self?.hostItem.refreshModel()
        }
    }

    /// 配置 App Library host cell: 挂载 Library 控制器视图(只挂一次)。
    /// 挂载时同步当前 chrome 顶部保留带(幂等; controller 创建前/后都生效)。
    /// X2: 挂载后立即落定 layout —— host 在 settle 动画期间挂载, 若等到下一次
    /// 布局才刷帧, 首个输入的 hit-test 会命中尚未布局(零 frame/空热区)的卡片
    /// 区域而落空(被外层 Grid 吞掉)。这里显式 flush 保证进入 surface 的下一秒
    /// 即可命中。
    private func configureHost(_ cell: AppLibraryHostCell?) {
        guard let cell else { return }
        hostItem.setContentInsets(
            top: max(0, gridLayout.topInset),
            bottom: AppLibraryLayoutMetrics.defaultContentInsets.bottom
        )
        guard let controller = hostItem.makeController() else {
            cell.view.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        // PA4: trace 开启时联动 Library 滚动容器 trace(挂载时统一开启)。
        if PagingTraceLog.enabled {
            controller.pagingTraceEnabled = true
        }
        guard controller.view.superview !== cell.view else { return }
        cell.view.subviews.forEach { $0.removeFromSuperview() }
        controller.view.frame = cell.view.bounds
        controller.view.autoresizingMask = [.width, .height]
        cell.view.addSubview(controller.view)
        cell.view.needsLayout = true
        cell.view.layoutSubtreeIfNeeded()
    }

    private func configure(_ cell: AppCellView?, with item: Item) {
        guard let cell else { return }
        // T-027: AppCell 真实 configure 调用点(含 folder 缩略图分支)。
        PagingPerfContext.recordCellEvent("cellConfigure")
        let pointSize = liveEffectivePointSize()
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
        case .folder(let id):
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

    /// 配置和预热必须使用同一请求值；有效值始终来自布局实时 geometry，
    /// 而不是 store 的 raw iconSize。向下取整避免图标反向撑破已适配的 cell。
    private func liveEffectivePointSize() -> Int {
        let iconSize = gridLayout.liveGeometry.iconSize
        guard iconSize.isFinite else { return 1 }
        return max(1, Int(iconSize.rounded(.down)))
    }

    private func refreshCellsIfEffectivePointSizeChanged() {
        guard collectionView != nil else { return }
        let pointSize = liveEffectivePointSize()
        guard lastConfiguredEffectivePointSize != pointSize else { return }
        lastConfiguredEffectivePointSize = pointSize
        collectionView.reloadData()
        schedulePageVisualPrepare()
    }

    /// 只在有效几何真的变化时失效已捕获的 Folder source。
    /// viewDidLayout 可能在同一几何下重复调用，不能把每次布局都当作失效。
    private func updateFolderTransitionGeometryRevision() {
        folderTransitionRevision.synchronizeGeometry(gridLayout.liveGeometry)
    }

    // MARK: - 刷新(修订跳过)

    /// 应用最新显示模型(或搜索结果)。
    /// 修订相同(目录/布局/配置均未变)且搜索词未变时跳过 full snapshot
    /// (Stage 1 §30; T-025: 搜索词变化不递增修订, 但必须重新过滤)。
    func refresh() {
        // 隐藏期间图标缓存可能被 trim; 每次 show 后的首次预热必须真正执行,
        // 不能被 (page, revision) 去重键挡掉(PA1)。
        lastPrewarmKey = nil
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
        let revisionChanged = store.displayRevision != lastAppliedRevision
        let searchChanged = searchQuery != lastAppliedSearchQuery
        if revisionChanged || searchChanged {
            if revisionChanged {
                dragController?.invalidateActiveSessionForDisplayChange()
                folderTransitionRevision.invalidate()
                lastAppliedRevision = store.displayRevision
                // External data changes can arrive during a swipe; retire the
                // presentation-only compositor before replacing its page model.
                shutdownPageCompositor()
            }
            lastAppliedSearchQuery = searchQuery
            applyLatestData()
            if L10n.currentLanguage != lastAppliedLanguage {
                lastAppliedLanguage = L10n.currentLanguage
                // Diffable keeps cells with unchanged identities. A language-only
                // revision must still rebuild labels and accessibility strings.
                collectionView.reloadData()
            }
            // App Library live 刷新(PA2): 数据变化时同步 Library 模型
            // (host 已 attach 且 session active 才生效; 未 attach 由
            // makeController 重新固定, 不 endSession 重建)。
            // P3-I: 此处与 dataObserver 路径可能双重调用 refreshModel(),
            // 但 updateModel 幂等(model != self.model guard)→ 第二次为 no-op。
            // 保留此调用作为 defense-in-depth(observer 尚未注册时仍可刷新 Library)。
            hostItem.refreshModel()
        }
        schedulePageVisualPrepare()
    }

    /// 强制刷新(忽略修订; 结构参数已变时由调用方使用)。
    func forceRefresh() {
        lastAppliedRevision = .max
        refresh()
    }

    private func applyLatestData() {
        if let results = store.searchResults(for: searchQuery) {
            enterSearchMode(with: results)
        } else {
            let restoringSearchExit = searchMode
            if searchMode {
                exitSearchMode()
            }
            applyDisplayModel(store.displayModel())
            // Stage E: 先恢复普通 display model/pageCount(applyDisplayModel),
            // 再按普通 pageCount 确定性 clamp 原语义 surface, 最后经 paging
            // 唯一 writer jump(不直接写 clip offset)。搜索态 pageCount==1 的
            // clamp 已无效。保存的是 LauncherSurface(Library 或普通页), 不是
            // raw page number。
            if restoringSearchExit {
                switch surfaceBeforeSearch {
                case .appLibrary:
                    setCurrentSurface(.appLibrary)
                    currentPage = 0
                case .layoutPage(let page):
                    currentPage = Self.clampedPage(page, pageCount: pageCount)
                    setCurrentSurface(.layoutPage(currentPage))
                }
                paging.jumpTo(page: physicalSurfaceIndex)
                updatePageDots()
            }
        }
    }

    // MARK: - 搜索模式

    private func enterSearchMode(with results: [Item]) {
        let wasPagedMode = !searchMode
        searchMode = true
        // P2: 结构变更 → 收掉 compositor 并 purge 视觉缓存(搜索态视觉无效)。
        shutdownPageCompositor()
        purgePageVisuals()
        paging.isEnabled = false
        if wasPagedMode {
            // 保存语义 surface(Library 或普通页), 不是 raw page number(Stage E8)。
            surfaceBeforeSearch = currentSurface
        }
        // 离开 Library surface: 释放冻结 session, 下次进入取最新 model。
        hostItem.endSession()
        gridLayout.mode = .search
        gridLayout.invalidateLayout()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        cachedDisplayItems = results
        cachedSectionCounts = [results.count]
        var snapshot = NSDiffableDataSourceSnapshot<Int, LauncherSurfaceItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(results.map(LauncherSurfaceItem.layout), toSection: 0)
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
        // 搜索结果只有一个横向页面: x=0 仍由 paging 的唯一 writer 写入;
        // onScroll 同时将 y 复位到 0, 这里不再直接写 clip 的 horizontal offset。
        paging.jumpTo(page: 0)
    }

    private func applyDisplayModel(_ display: DisplayModel) {
        cachedDisplayItems = display.pages.flatMap { $0 }
        cachedSectionCounts = display.pages.map(\.count)
        var snapshot = NSDiffableDataSourceSnapshot<Int, LauncherSurfaceItem>()
        if leadingSurfaceEnabled {
            // 物理 section 0 = App Library host(恒单 item), 普通页从 section 1 开始。
            snapshot.appendSections([0])
            snapshot.appendItems([.appLibrary], toSection: 0)
            for (pageIndex, page) in display.pages.enumerated() {
                snapshot.appendSections([pageIndex + 1])
                snapshot.appendItems(page.map(LauncherSurfaceItem.layout), toSection: pageIndex + 1)
            }
        } else {
            for (pageIndex, page) in display.pages.enumerated() {
                snapshot.appendSections([pageIndex])
                snapshot.appendItems(page.map(LauncherSurfaceItem.layout), toSection: pageIndex)
            }
        }
        // §A14: folder 身份稳定, 子项 payload 独立刷新。已显示的 folder 的可见子项
        // 变化 → reload 该 item(重新 configure → 缩略图/子项更新), identity 不变。
        // 新出现/已消失的 folder 走 insert/delete, 无需 reload。
        let folderPayloads = display.folderChildrenPayload
        let changed = folderPayloads.keys.filter { id in
            guard let previous = lastAppliedFolderPayloads[id] else { return false }
            return folderPayloads[id] != previous
        }
        if !changed.isEmpty {
            snapshot.reloadItems(changed.map { .layout(.folder($0)) })
        }
        lastAppliedFolderPayloads = folderPayloads
        pageCount = max(1, display.pages.count)
        currentPage = min(currentPage, pageCount - 1)
        // 默认 surface 保持 Page1/物理 1, 除非当前已明确处于 Library。
        if currentSurface != .appLibrary {
            setCurrentSurface(
                .layoutPage(min(max(0, currentPage), max(0, pageCount - 1)))
            )
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        paging.jumpTo(page: physicalSurfaceIndex)
        updatePageDots()
    }

    /// Settings 结构参数变更: 重建布局几何并重新分页(Stage 1 §14/§15)。
    func applyGeometryConfig(columns: Int, rows: Int, iconSize: Int) {
        dragController?.invalidateActiveSessionForDisplayChange()
        // P2: 几何/结构变更 → 收掉 compositor, 视觉缓存键自然失效。
        shutdownPageCompositor()
        let gridLayout = gridLayout
        gridLayout.update(
            columns: columns, rows: rows, iconSize: CGFloat(iconSize),
            cellSize: cellSize, horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        )
        folderTransitionRevision.invalidate()
        lastConfiguredEffectivePointSize = liveEffectivePointSize()
        // 参数变化 → 页容量变化 → 重新分页并回第一页
        currentPage = 0
        forceRefresh()
        // Diffable 对相同 item 复用 cell(不重新调用数据源闭包) →
        // 必须 reloadData 强制重配置, 否则 iconPointSize 停留在旧值(评审 M2)
        collectionView.reloadData()
        // geometry-config 跳跃也沿物理 surface 走(普通页 0 → 物理 1, Library 存在时不落进 Library)。
        paging.jumpTo(page: physicalIndex(forLayoutPage: currentPage))
    }

    // MARK: - 页面导航

    /// 页码确定性 clamp(Stage E): 负数 → 0, 超界 → 最后一页, pageCount 至少按 1 处理。
    /// 与 PagingInteractionController 的 settle/jump 目标 clamp 语义一致。
    static func clampedPage(_ page: Int, pageCount: Int) -> Int {
        min(max(0, page), max(0, pageCount - 1))
    }

    /// 切换语义 surface 并维护 host session 生命周期。
    /// 离开 Library 时释放冻结 model(host 复用语义), 进入由 cell configure 重新固定;
    /// 同时清理仍打开的 category detail(幂等), 并经 `onSurfaceChange` 通知 Window。
    private func setCurrentSurface(_ surface: LauncherSurface) {
        guard surface != currentSurface else { return }
        if currentSurface == .appLibrary, surface != .appLibrary {
            hostItem.endSession()
            hostItem.closeDetail()
        }
        currentSurface = surface
        onSurfaceChange?(surface)
    }

    /// 关闭 App Library category detail(幂等; 无 detail 时为 no-op)。
    /// 由 WindowController 在 Settings 打开 / Launcher 隐藏时调用。
    func closeAppLibraryDetail() {
        hostItem.closeDetail()
    }

    /// 诊断: 当前 App Library 控制器(host 尚未挂载时为 nil)。
    var libraryControllerForDiag: AppLibraryViewController? {
        hostItem.libraryControllerForDiag
    }

    // MARK: - E10 诊断 seam(App Library 视觉证据)

    /// E10: 导航到 App Library surface(Page1 → previousPage 语义; 已在
    /// Library 时 no-op)。leading surface 未启用时返回 false。
    func libraryShotNavigateToLibrary() -> Bool {
        guard leadingSurfaceEnabled else { return false }
        if currentSurface != .appLibrary {
            previousPage()
        }
        return true
    }

    /// E10: 分页 settle 是否已完成(驱动一帧; 未完成返回 false, 调用方轮询)。
    func libraryShotWaitSettled() -> Bool {
        pagingProbeDisplayFrame()
    }

    /// E10: Library 内部垂直滚动到内容约 55%(45%-60% 目标); 内容不足 → stable no-op。
    func libraryShotScrollMid() -> (scrolled: Bool, fraction: Double) {
        guard let library = libraryControllerForDiag else { return (false, 0) }
        return library.scrollVerticalToFractionForDiagnostic(0.55)
    }

    /// E10: 打开第一个 category detail(无分类卡返回 false)。
    func libraryShotOpenFirstCategoryDetail() -> Bool {
        guard let library = libraryControllerForDiag else { return false }
        return library.openFirstCategoryDetailForDiagnostic()
    }

    /// E10: surface / 搜索 / 卡片 / 可见 cell / detail 状态快照。
    func libraryShotState() -> String {
        let surface: String
        switch currentSurface {
        case .appLibrary: surface = "appLibrary"
        case .layoutPage(let page): surface = "layoutPage(\(page))"
        }
        let counts = libraryControllerForDiag?.libraryShotCounts() ?? "cards=0 visible=0 detail=0"
        return "surface=\(surface) search=\(searchMode ? 1 : 0) \(counts)"
    }

    func goToPage(_ page: Int, animated: Bool = true) {
        guard !searchMode else { return }
        let clamped = Self.clampedPage(page, pageCount: pageCount)
        if animated {
            // 动画翻页统一经 PageSnapAnimator(time-based spring, v0.1.6 §23/§31);
            // 目标 = 普通页的物理 surface。
            paging.startSettle(toPage: physicalIndex(forLayoutPage: clamped))
        } else {
            currentPage = clamped
            setCurrentSurface(.layoutPage(clamped))
            paging.jumpTo(page: physicalIndex(forLayoutPage: clamped))
            updatePageDots()
        }
        prewarmAdjacentPages(clamped)
    }

    /// 普通 Layout page → 分页引擎的物理页索引(leading 开启时 + 1, 否则原样)。
    private func physicalIndex(forLayoutPage page: Int) -> Int {
        leadingSurfaceEnabled
            ? LauncherSurfaceIndex(layoutPageCount: pageCount).physicalIndex(for: .layoutPage(page))
            : page
    }

    /// 沿物理 surface 前进/后退(Page1 previous → Library, Library next → Page1)。
    func nextPage() {
        guard !searchMode else { return }
        if leadingSurfaceEnabled {
            let target = min(physicalSurfaceCount - 1, physicalSurfaceIndex + 1)
            navigate(toPhysical: target)
        } else {
            navigate(toPhysical: currentPage + 1)
        }
    }

    func previousPage() {
        guard !searchMode else { return }
        if leadingSurfaceEnabled {
            navigate(toPhysical: max(0, physicalSurfaceIndex - 1))
        } else {
            navigate(toPhysical: currentPage - 1)
        }
    }

    /// 导航到物理 surface(经 paging 唯一 writer 的 settle)。
    private func navigate(toPhysical physical: Int) {
        if leadingSurfaceEnabled {
            let index = LauncherSurfaceIndex(layoutPageCount: pageCount)
            let surface = index.surface(forPhysicalIndex: physical)
            setCurrentSurface(surface)
            switch surface {
            case .appLibrary:
                currentPage = 0
            case .layoutPage(let page):
                currentPage = page
            }
            paging.startSettle(toPage: physical)
        } else {
            let clamped = Self.clampedPage(physical, pageCount: pageCount)
            currentPage = clamped
            setCurrentSurface(.layoutPage(clamped))
            paging.startSettle(toPage: clamped)
        }
        updatePageDots()
        prewarmAdjacentPages(currentPage)
    }

    /// paging settle 目标页(物理索引)落地: 更新物理状态/语义当前页/页点/预热。
    private func applySettledPhysicalPage(_ physical: Int) {
        if leadingSurfaceEnabled {
            let index = LauncherSurfaceIndex(layoutPageCount: pageCount)
            let surface = index.surface(forPhysicalIndex: physical)
            setCurrentSurface(surface)
            switch surface {
            case .appLibrary:
                currentPage = 0
            case .layoutPage(let page):
                currentPage = page
            }
        } else {
            currentPage = Self.clampedPage(physical, pageCount: pageCount)
            setCurrentSurface(.layoutPage(currentPage))
        }
        updatePageDots()
        prewarmAdjacentPages(currentPage)
    }

    /// 相邻页图标预热(v0.1.6 §36-37): 只维护 current±1 working set, 不全量预加载。
    /// Library 是独立 surface, 不预热普通图标。
    ///
    /// 去重: 同一 (page, displayRevision, pointSize, scale) 只执行一次
    /// (L15 扩展: 几何/图标尺寸或 backing scale 变化时允许重新预热)。
    /// settle 目标页回调与 navigate/goToPage 会先后各调一次本函数
    /// (PA1 前 = 双份 O(n) displayModel 构建 + ~70 个 Task 派生落在 settle
    /// 首帧前), revision 未变时第二次是纯重复。
    ///
    /// 并发: 相邻两页全部 app ID 收集成单个数组后, 用**有界 TaskGroup**
    /// 预热(每批 ≤8 个在途)——替代 N 个裸 Task, 消除 settle 首帧的批量
    /// 任务派生开销。
    ///
    /// 可取消: 连续调度只保留最后一个在途 prewarm(先 cancel 旧任务再替换),
    /// 避免新旧预热重叠; 任务结束(含被取消)后在 MainActor 内确认自己仍是
    /// 当前代际才清空引用。
    private var lastPrewarmKey: (page: Int, revision: UInt64, pointSize: Int, scale: Int)?
    /// 在途 prewarm 任务(新调度先取消旧任务)。
    private var pagePrewarmTask: Task<Void, Never>?
    /// prewarm 代际: 每次调度递增; 结束收尾只清理自己那一代。
    private var pagePrewarmGeneration = 0

    private func prewarmAdjacentPages(_ page: Int) {
        guard currentSurface != .appLibrary else { return }
        guard let iconProvider else { return }
        let revision = store.displayRevision
        let pointSize = liveEffectivePointSize()
        let scale = Int(view.window?.backingScaleFactor ?? 2)
        if let lastPrewarmKey,
           lastPrewarmKey.page == page,
           lastPrewarmKey.revision == revision,
           lastPrewarmKey.pointSize == pointSize,
           lastPrewarmKey.scale == scale {
            return
        }
        lastPrewarmKey = (page, revision, pointSize, scale)
        let display = store.displayModel()
        // 相邻两页全部 app IDs(保持页面顺序、页内顺序)。
        var ids: [AppID] = []
        for p in [page - 1, page + 1] where p >= 0 && p < display.pages.count {
            for item in display.pages[p] {
                if case .app(let id) = item {
                    ids.append(id)
                }
            }
        }
        // 取消在途旧 prewarm, 只保留当前这一代(Task 继承 MainActor 隔离,
        // 收尾可安全写回 pagePrewarmTask)。
        pagePrewarmTask?.cancel()
        pagePrewarmGeneration &+= 1
        let generation = pagePrewarmGeneration
        pagePrewarmTask = Task(priority: .utility) { [weak self, weak iconProvider] in
            guard let provider = iconProvider else { return }
            // 有界 TaskGroup: 每批 ≤8 个在途(一批 addTask 后逐个 consume
            // 完再开下一批), 预热不阻塞主线程、不一次性派生全量任务。
            // IconImageProviding 声明为 Sendable → 发送闭包可直接强捕获。
            await withTaskGroup(of: Void.self) { group in
                let strideCount = 8
                var index = 0
                while index < ids.count {
                    let end = min(index + strideCount, ids.count)
                    for offset in index..<end {
                        let id = ids[offset]
                        group.addTask {
                            _ = await provider.icon(for: id, pointSize: pointSize, scale: scale)
                        }
                    }
                    for _ in index..<end { _ = await group.next() }
                    index = end
                }
            }
            // 收尾(含正常/取消): 自己仍是当前代际才清空, 不误清新任务。
            if let self, generation == self.pagePrewarmGeneration {
                self.pagePrewarmTask = nil
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
        case .appLibrary:
            // Library host 是独立表面: 不启动应用、不隐藏启动器(点击由 Library 自身处理)。
            break
        case .layout(let layoutItem):
            switch layoutItem {
            case .app(let id):
                store.launch(id)
            case .folder(let id):
                onOpenFolder?(id)
            }
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
        case .appLibrary:
            return nil
        case .layout(let layoutItem):
            switch layoutItem {
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

                menu.addItem(.separator())

                let reveal = NSMenuItem(
                    title: L10n.t(.revealInFinder), action: #selector(revealInFinder(_:)), keyEquivalent: ""
                )
                reveal.representedObject = id
                reveal.target = self
                menu.addItem(reveal)

                let getInfo = NSMenuItem(
                    title: L10n.t(.getInfo), action: #selector(getInfo(_:)), keyEquivalent: ""
                )
                getInfo.representedObject = id
                getInfo.target = self
                menu.addItem(getInfo)
            case .folder(let id):
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
        presentRenamePrompt(defaultValue: current, titleKey: .rename) { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            self.store.renameFolder(folderID, to: name)
        }
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
        presentRenamePrompt(
            defaultValue: store.displayName(for: appID),
            titleKey: .renameApp,
            appID: appID
        ) { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            self.store.setCustomName(appID, name: name)
        }
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

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let appID = sender.representedObject as? AppID else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: appID)])
    }

    @objc private func getInfo(_ sender: NSMenuItem) {
        guard let appID = sender.representedObject as? AppID else { return }
        let script = NSAppleScript(source: getInfoAppleScriptSource(for: appID))
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            print("GETINFO_FAILED appID=\(appID) error=\(error)")
        }
    }

    /// 规范 AppID → 文件 URL(路径身份, 无 shell 拼接)。
    func fileURL(for appID: AppID) -> URL {
        URL(fileURLWithPath: appID.rawValue)
    }

    /// Get Info 的 AppleScript 源(字符串安全编码, 不执行; 无 shell)。
    ///
    /// AppleScript 字符串内转义 `\` 与 `"`, 路径经 POSIX file 构造,
    /// 不经过 osascript/shell, 无注入面。
    func getInfoAppleScriptSource(for appID: AppID) -> String {
        let escaped = appID.rawValue
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Finder\" to open information window of (POSIX file \"\(escaped)\")"
    }

    private func presentRenamePrompt(
        defaultValue: String,
        titleKey: L10n.Key,
        appID: AppID? = nil,
        completion: @escaping (String?) -> Void
    ) {
        guard let parentWindow = view.window else { return }
        renamePromptPresenter.present(
            in: parentWindow,
            defaultValue: defaultValue,
            title: L10n.t(titleKey),
            appID: appID,
            iconProvider: iconProvider,
            iconPointSize: 64,
            completion: completion
        )
    }

    // MARK: - 分页交互(v0.1.6 PART A)

    /// Called by the real launcher show lifecycle. Refreshes do not reset this.
    func beginShowSession() {
        pageCompositorActivationTelemetry.beginShowSession()
    }

    /// Applies only the two independent paging diagnostic switches.
    /// This is the same seam used by setupPagingController and by behavior tests.
    func applyPagingDiagnosticsConfiguration(_ configuration: PagingDiagnosticsConfiguration) {
        pageCompositor.metrics.enabled = configuration.pageCompositorEnabled
        pageCompositor.diagnosticsEnabled = configuration.pageCompositorEnabled
        pageCompositorActivationTelemetry.enabled = configuration.pagingFeelTelemetryEnabled
        paging.onDisplayLinkTick = configuration.pagingFeelTelemetryEnabled
            ? { [weak self] in
                self?.pageCompositorActivationTelemetry.recordDisplayLinkInterval()
            }
            : nil
    }

    /// T-027: `--paging-perf` 接线（默认关闭；测试经此 seam 显式开启）。
    /// 关闭时各 perfRecorder 引用置 nil —— 默认路径每个调用点仅一次 optional
    /// 检查，零分配、零字符串构建、零时间戳读取；开启时 recorder 只做计数与
    /// 耗时聚合，不参与任何行为决策。幂等，可重复调用。
    /// 注意: 视图加载前调用时布局尚未创建, gridLayout 部分自动跳过
    /// (生产路径 setupPagingController 恒在 viewDidLoad 后调用, 布局已就绪)。
    func configurePagingPerfTelemetry(enabled: Bool) {
        pagingPerfTelemetry.enabled = enabled
        paging.perfRecorder = enabled ? pagingPerfTelemetry : nil
        if collectionView?.collectionViewLayout is PagingGridLayout {
            gridLayout.perfRecorder = enabled ? pagingPerfTelemetry : nil
        }
        pageCompositor.perfRecorder = enabled ? pagingPerfTelemetry : nil
        PagingPerfContext.recorder = enabled ? pagingPerfTelemetry : nil
    }

    /// T-027: 测试/诊断 —— 遥测是否已接线。
    var pagingPerfEnabledForDiag: Bool { pagingPerfTelemetry.enabled }

    /// T-027: 测试/诊断 —— 当前 recorder 的 open session 状态。
    var pagingPerfHasOpenSessionForDiag: Bool { pagingPerfTelemetry.hasOpenSessionForDiag }

    /// T-027: 测试/诊断 —— 捕获 recorder 的 JSONL 摘要输出(默认 stdout)。
    /// 只替换输出目标, 不改变任何采集行为。
    func setPagingPerfSummaryHandlerForDiag(_ handler: @escaping (String) -> Void) {
        pagingPerfTelemetry.onSummary = handler
    }

    var pagingDisplayLinkTelemetryEnabledForDiag: Bool {
        paging.onDisplayLinkTick != nil
    }

    /// 接线 PagingInteractionController 到本网格(唯一 offset writer 注入)。
    private func setupPagingController() {
        paging.linkView = view
        paging.onReadCurrentOffset = { [weak self] in
            guard let self else { return 0 }
            return self.readPagingOffset()
        }
        paging.onReadPageWidth = { [weak self] in
            guard let self else { return 0 }
            let clip = self.collectionView.enclosingScrollView?.contentView
            return clip?.bounds.width ?? self.collectionView.bounds.width
        }
        paging.onReadPageCount = { [weak self] in
            guard let self else { return 1 }
            return self.physicalSurfaceCount
        }
        paging.onScroll = { [weak self] offset in
            guard let self else { return }
            self.routeScroll(offset)
        }
        paging.onSettleTargetPage = { [weak self] page in
            guard let self else { return }
            self.applySettledPhysicalPage(page)
        }
        // P2: 水平轴锁定后、首个非零水平位移时按方向激活 compositor(在首次
        // offset 写入前; 零跳变)。垂直/未定轴/零位移手势不触发。
        paging.onWillStartHorizontalTracking = { [weak self] direction in
            self?.recordPagingEventForDiag("directionCallback")
            self?.tryActivatePageCompositor(direction: direction)
        }
        paging.onInteractionCancelled = { [weak self] in
            guard let self else { return }
            self.telemetryCompletionReason = .cancelled
            self.telemetrySettleDurationMs = nil
            self.flushCompositorActivationTelemetry()
        }
        paging.onSettleLifecycle = { [weak self] lifecycle in
            guard let self else { return }
            switch lifecycle {
            case .settled(let duration):
                self.telemetryCompletionReason = .settled
                self.telemetrySettleDurationMs = duration * 1000
            case .interrupted(let duration):
                self.telemetryCompletionReason = .interrupted
                self.telemetrySettleDurationMs = duration * 1000
                self.flushCompositorActivationTelemetry()
            case .cancelled(let duration):
                self.telemetryCompletionReason = .cancelled
                self.telemetrySettleDurationMs = duration.map { $0 * 1000 }
                self.flushCompositorActivationTelemetry()
            }
        }
        // P2: 运动停止(idle)→ 收掉 compositor(同步 clip → reveal), 并重试
        // 防抖丢弃的视觉准备: 100ms 防抖醒来时 phase 非 idle 而丢掉的 prepare,
        // 会在下一次真正 idle 时补跑(schedulePageVisualPrepare 内部已有
        // generation + 取消旧任务机制, 重复调度安全)。
        paging.onPhaseIdle = { [weak self] in
            guard let self else { return }
            self.finalizePageCompositor()
            self.flushCompositorActivationTelemetry()
            // T-027: teardown 指标已在上一步记入 session, 此时收口输出 JSONL。
            self.pagingPerfTelemetry.flushOpenSession()
            self.schedulePageVisualPrepare()
        }
        // P2: settle 收敛 → idle 准备相邻页视觉。
        paging.onSettleComplete = { [weak self] in
            self?.schedulePageVisualPrepare()
        }
        pageCompositor.onSyncClip = { [weak self] offset in
            guard let self else { return }
            self.collectionView.enclosingScrollView?.contentView.scroll(
                to: NSPoint(x: offset, y: 0)
            )
            // P2 空窗修复(v0.5.1): 快速甩页时真实 clip 从未滚过目标页,
            // 目标页 cell 从未物化。若揭露后等下一个布局周期才创建 cell,
            // 用户会看到一段只有壁纸背景的空白。这里在合成表面仍遮盖时
            // 强制同步布局, 让目标页 cell 在揭露前就绪。
            if self.pageCompositor.isActive {
                // T-027: 记录 layoutSubtreeIfNeeded() 是否执行及其耗时(teardown 归属)。
                let perfStart = self.pagingPerfTelemetry.enabled ? CACurrentMediaTime() : 0
                self.collectionView.layoutSubtreeIfNeeded()
                if self.pagingPerfTelemetry.enabled {
                    self.pagingPerfTelemetry.recordCompositorTeardownLayout(
                        durationMs: (CACurrentMediaTime() - perfStart) * 1000
                    )
                }
                self.pageCompositorSyncLayoutCountForDiag += 1
            }
        }
        // `--pagecompositor` owns compositor metrics and per-frame events.
        // Activation telemetry is intentionally independent: enabling
        // `--pagingfeeltelemetry` must not add compositor diagnostics.
        applyPagingDiagnosticsConfiguration(
            PagingDiagnosticsConfiguration(arguments: CommandLine.arguments)
        )
        // E13: --pagingtelemetry 遥测开关接线。应用保持正常交互运行,
        // 只开启分页帧间隔遥测(每手势写一行到 /tmp/lb-paging-telemetry.log)。
        // 该 flag 不在 ActivationCoordinator 的 non-interactive 列表中。
        if CommandLine.arguments.contains("--pagingtelemetry") {
            paging.telemetryEnabled = true
        }
        // PA4: --pagingeventtrace 逐事件 trace(分页引擎侧; Library 滚动容器
        // 侧在 configureHost 挂载控制器时经 PagingTraceLog.enabled 联动开启)。
        if CommandLine.arguments.contains("--pagingeventtrace") {
            PagingTraceLog.enabled = true
            paging.traceEnabled = true
        }
        // T-003: --pagingfeel-damped 归一化阻尼跟手曲线实验(默认关; 产品默认
        // 仍为 linear 1.3)。交互式 A/B 实验, 未经真实触控板验证前不设为默认。
        if CommandLine.arguments.contains("--pagingfeel-damped") {
            paging.followCurve = .normalizedDamped(strength: PagingTuning.followSensitivity)
        }
        // T-027: --paging-perf 分页性能诊断(默认关; 交互式运行, 每 session 完成
        // 时输出一行 JSONL 到 stdout)。不改变任何行为。
        configurePagingPerfTelemetry(
            enabled: CommandLine.arguments.contains("--paging-perf")
        )
    }

    // MARK: - P2 偏移抽象与滚动路由

    /// 当前水平偏移唯一读取: compositor active → compositor.currentOffset;
    /// 否则真实 clip。PagingInteractionController 经 onReadCurrentOffset 接这里,
    /// 不得散射到其它来源。
    func readPagingOffset() -> CGFloat {
        if pageCompositor.isActive {
            return pageCompositor.currentOffset
        }
        return collectionView.enclosingScrollView?.contentView.bounds.origin.x ?? 0
    }

    /// 唯一 offset writer 路由: compositor active → 只移动合成层(不写 clip),
    /// settle 期间真实 clip 在遮盖下渐进跟进(见 `advanceRealClipBehindCover`);
    /// 否则写真实 clip。
    ///
    /// T-027: 按真实路由分桶记录(live tracking / live settling /
    /// compositor tracking / compositor settling layer apply)。idle 期写入
    /// (jump 等程序化写)不归属任何 session 桶, 不计数。
    private func routeScroll(_ offset: CGFloat) {
        recordPagingEventForDiag("firstOffsetWrite")
        if pageCompositor.isActive {
            let perfStart = pagingPerfTelemetry.enabled ? CACurrentMediaTime() : 0
            pageCompositor.applyOffset(offset)
            if pagingPerfTelemetry.enabled {
                pagingPerfTelemetry.recordCompositorApplyOffset(
                    phase: paging.phase == .settling ? "settling" : "tracking",
                    durationMs: (CACurrentMediaTime() - perfStart) * 1000
                )
            }
            if paging.phase == .settling {
                advanceRealClipBehindCover()
            }
            return
        }
        // live 路径: 真实 clip 写。compositor tracking 期间按架构不应出现
        // 真实 clip 写(compositor 分支已 return; 该计数恒 0, 由 recorder
        // 的 compositorTracking.realClipWriteCount 如实暴露, 供真机验证)。
        let perfStart = pagingPerfTelemetry.enabled ? CACurrentMediaTime() : 0
        collectionView.enclosingScrollView?.contentView.scroll(
            to: NSPoint(x: offset, y: 0)
        )
        if pagingPerfTelemetry.enabled, paging.phase != .idle {
            pagingPerfTelemetry.recordLiveScroll(
                phase: paging.phase == .settling ? "settling" : "tracking",
                durationMs: (CACurrentMediaTime() - perfStart) * 1000
            )
        }
    }

    /// P2 平滑落地(v0.5.2): settling 每帧让真实 clip 向 compositor 偏移跟进
    /// 35% 缺口(遮盖下, 视觉不可见)。NSCollectionView 因此逐帧增量物化目标页
    /// cell + 发起图标请求, 而不是把整页 ~40 个 cell 的创建压缩到揭露瞬间
    /// (v0.5.1 的落地强制布局保留为兜底, 此时通常已无剩余工作)。
    /// 引擎不受影响: readPagingOffset 在 compositor active 期间只读合成器偏移。
    /// abort/打断路径由 teardown 的 clip 同步 + 强制布局兜底。
    ///
    /// T-027: 记录调用数 / gap 阈值跳过 / catch-up 写次数+耗时 / gap 最大值。
    private func advanceRealClipBehindCover() {
        let target = pageCompositor.currentOffset
        let current = realClipOffset()
        let gap = target - current
        guard abs(gap) > 0.5 else {
            // T-027: gap 阈值跳过(默认关时单次 bool 检查, 零记录)。
            if pagingPerfTelemetry.enabled {
                pagingPerfTelemetry.recordCatchUpGapSkip()
            }
            return
        }
        // T-027: 记录调用数(默认关时单次 bool 检查, 零记录)。
        if pagingPerfTelemetry.enabled {
            pagingPerfTelemetry.recordAdvanceRealClipCall()
        }
        let perfStart = pagingPerfTelemetry.enabled ? CACurrentMediaTime() : 0
        collectionView.enclosingScrollView?.contentView.scroll(
            to: NSPoint(x: current + gap * 0.35, y: 0)
        )
        if pagingPerfTelemetry.enabled {
            pagingPerfTelemetry.recordCatchUpWrite(
                durationMs: (CACurrentMediaTime() - perfStart) * 1000,
                gap: abs(gap)
            )
        }
        pageVisualRealClipAdvanceCountForDiag += 1
    }

    /// 当前真实 clip 水平偏移(compositor 未激活时的权威值)。
    private func realClipOffset() -> CGFloat {
        collectionView.enclosingScrollView?.contentView.bounds.origin.x ?? 0
    }

    // MARK: - P2 Page Compositor(激活 / 收口 / 准备)

    /// 当前普通页项数(密度门输入; displayModel 为内存 COW 结构, 读取零 IO)。
    private var currentPageItemCount: Int {
        let display = store.displayModel()
        guard currentPage >= 0, currentPage < display.pages.count else { return 0 }
        return display.pages[currentPage].count
    }

    /// 表面/状态/密度门(方向无关): paged + 普通 Layout surface + 无 drag/Folder/
    /// Settings/Search/Category detail + 页面达到密度门(默认 ≥20 项)。
    /// 未满足 → 本次手势 live 分页(降级, 绝不阻塞手势起点)。
    private func compositorSurfaceGate() -> Bool {
        guard pageVisualCompositorEnabled,
              !pageCompositor.isActive,
              paging.isEnabled,
              !searchMode,
              currentSurface != .appLibrary,
              !(dragController?.isDragging ?? false),
              currentPageItemCount >= pageVisualMinItemsPerPage else {
            return false
        }
        return true
    }

    /// 诊断: 是否存在至少一个合法方向(普通 layout 邻页)且当前页与该邻页视觉齐备。
    /// 不含页边界检查(激活时另判); 供 `pageCompositorEligibleForDiag` 与测试。
    private func compositorCanActivate() -> Bool {
        guard compositorSurfaceGate() else { return false }
        return validDirectionTargets().contains { target in
            visualsReady(for: [currentPage, target])
        }
    }

    /// 当前页的合法方向目标(普通 layout 邻页; 越界/App Library 排除)。
    private func validDirectionTargets() -> [Int] {
        var targets: [Int] = []
        let next = currentPage + 1
        if next < pageCount { targets.append(next) }
        let prev = currentPage - 1
        if prev >= 0 { targets.append(prev) }
        return targets
    }

    /// 指定页集合的视觉是否齐备(忽略 iconEpoch; 顺序无关)。
    private func visualsReady(for pages: [Int]) -> Bool {
        let scale = currentBackingScale
        let g = geometry
        let visuals = pageVisualCache.visuals(
            for: pages,
            displayRevision: store.displayRevision,
            geometry: PageVisualGeometrySignature(geometry: g),
            backingScale: scale,
            languageRevision: lastPreparedLanguageRevision
        )
        return visuals.count == pages.count
    }

    /// 方向 → 目标普通 layout 页。
    private func targetPage(for direction: PagingDirection) -> Int {
        switch direction {
        case .next: return currentPage + 1
        case .previous: return currentPage - 1
        }
    }

    /// 真实 clip 是否在页边界附近(页宽归一化 + 小容差; 无硬编码像素)。
    /// 激活零跳变前提: 合成器把视觉摆在页边界, 若 clip 停在页中间(如 live
    /// settle 被打断)则激活会跳变 → 必须 live 降级。
    private func isNearPageBoundary(_ offset: CGFloat) -> Bool {
        let pageWidth = geometry.pageWidth
        guard pageWidth > 0 else { return true }
        let page = offset / pageWidth
        let nearest = page.rounded()
        return abs(page - nearest) <= 0.01
    }

    /// 水平轴锁定后按方向尝试激活(仅 idle 准备, 零同步渲染)。
    ///
    /// 激活条件: 表面门通过 + 目标方向是合法普通 layout 邻页 + 真实 clip 在页
    /// 边界附近 + 当前页与目标页视觉齐备。目标为 App Library / 越界 / clip 不在
    /// 边界 / 视觉缺失 → live 降级(绝不阻塞手势起点)。compositor 已激活 → 不重建。
    ///
    /// T-002: 遥测为观察者, 只记录激活结果, 不改变任何激活判断。
    private func tryActivatePageCompositor(direction: PagingDirection) {
        // 方向回调每次手势至多一次 → 在此开始手势遥测并快照 paging 计数(按手势差分)。
        compositorTelemetryStartDisplayFrames = paging.displayFrameCount
        compositorTelemetryStartScrollWrites = paging.scrollWriteCount
        telemetryCompletionReason = .settled
        telemetrySettleDurationMs = nil
        pageCompositorActivationTelemetry.beginGesture(startPage: currentPage, direction: direction)
        pageCompositorActivationTelemetry.recordCacheVisualCount(pageVisualCache.visualCount)
        pageCompositorActivationTelemetry.recordRequiredPages(2)

        let targetPage = targetPage(for: direction)
        if pageCompositor.isActive {
            // A settle can be interrupted while the presentation still covers
            // the old pair. Reuse it only when it covers the new pair too.
            let required = Set([currentPage, targetPage])
            if targetPage >= 0, targetPage < pageCount,
               pageCompositor.covers(pages: required) {
                recordActivationResult(.activeCoverageReuse)
                return
            }

            // Abort before this gesture's first offset write. abort() syncs the
            // clip to the compositor's exact currentOffset and reveals live;
            // it performs no rasterization or cache wait.
            pageCompositor.abort()
            // T-027: compositor active 状态同步(abort teardown 后已不激活)。
            pagingPerfTelemetry.markCompositorActive(false)
            pageCompositor.metrics.recordFallbackLive()
            recordActivationResult(.interruptionFallbackLive)
            return
        }

        guard pageVisualCompositorEnabled else {
            recordActivationResult(.disabled)
            return
        }
        guard compositorSurfaceGate() else {
            recordActivationResult(surfaceGateResult())
            return
        }
        // 目标越界: only a configured leading surface makes a negative target
        // App Library; otherwise it is an ordinary out-of-bounds target.
        guard targetPage >= 0, targetPage < pageCount else {
            let result: PageCompositorActivationResult =
                leadingSurfaceEnabled && targetPage < 0
                    ? .targetIsLibrary
                    : .targetOutOfBounds
            recordActivationResult(result)
            return
        }
        guard isNearPageBoundary(realClipOffset()) else {
            pageCompositor.metrics.recordFallbackLive()
            recordActivationResult(.offsetNotAtBoundary)
            return
        }
        let scale = currentBackingScale
        let g = geometry
        guard g.pageWidth.isFinite, g.pageWidth > 0 else {
            recordActivationResult(.invalidGeometry)
            return
        }
        let visuals = pageVisualCache.visuals(
            for: [currentPage, targetPage],
            displayRevision: store.displayRevision,
            geometry: PageVisualGeometrySignature(geometry: g),
            backingScale: scale,
            languageRevision: lastPreparedLanguageRevision
        )
        guard visuals.count == 2 else {
            pageCompositor.metrics.recordFallbackLive()
            recordActivationResult(visualsMissingResult(visuals: visuals))
            return
        }
        if view.layer == nil { view.wantsLayer = true }
        if collectionView.layer == nil { collectionView.wantsLayer = true }
        guard let hostLayer = view.layer, let liveLayer = collectionView.layer else {
            recordActivationResult(.invalidGeometry)
            return
        }

        var placements: [PageCompositor.Placement] = []
        placements.reserveCapacity(visuals.count)
        for item in visuals {
            let bounds = item.visual.logicalBounds
            guard bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width > 0, bounds.height > 0,
                  bounds.minX.isFinite, bounds.minY.isFinite else {
                recordActivationResult(.invalidGeometry)
                return
            }
            let documentRect = CGRect(
                x: leadingDocumentOffset
                    + CGFloat(item.page) * g.pageWidth
                    + g.gridOrigin.x
                    + bounds.minX,
                y: g.gridOrigin.y + bounds.minY,
                width: bounds.width,
                height: bounds.height
            )
            guard documentRect.origin.x.isFinite, documentRect.origin.y.isFinite,
                  documentRect.width.isFinite, documentRect.height.isFinite else {
                recordActivationResult(.invalidGeometry)
                return
            }
            let inHost = collectionView.convert(documentRect, to: view)
            guard inHost.origin.x.isFinite, inHost.origin.y.isFinite,
                  inHost.width.isFinite, inHost.height.isFinite else {
                recordActivationResult(.invalidGeometry)
                return
            }
            placements.append(PageCompositor.Placement(
                page: item.page, baseFrame: inHost, visual: item.visual
            ))
        }
        guard !placements.isEmpty else {
            recordActivationResult(.invalidGeometry)
            return
        }
        pageCompositor.activate(
            placements: placements,
            pageWidth: g.pageWidth,
            startOffset: realClipOffset(),
            hostLayer: hostLayer,
            liveLayer: liveLayer
        )
        guard pageCompositor.isActive else {
            recordActivationResult(.invalidGeometry)
            return
        }
        // T-027: compositor active 状态同步(激活成功)。
        pagingPerfTelemetry.markCompositorActive(true)
        recordActivationResult(.activated)
    }

    /// T-002: 遥测观察者记录激活结果(默认关时 no-op)。
    /// Activation outcome is deliberately independent from session completion.
    private func recordActivationResult(_ result: PageCompositorActivationResult) {
        recordPagingEventForDiag("compositorDecision")
        pageCompositorActivationTelemetry.recordActivationResult(result)
    }

    /// T-002: 表面门未通过时的具体失败原因(观察者; 不改变门判断)。
    private func surfaceGateResult() -> PageCompositorActivationResult {
        if searchMode { return .search }
        if currentSurface == .appLibrary { return .appLibrary }
        if dragController?.isDragging ?? false { return .dragActive }
        if currentPageItemCount < pageVisualMinItemsPerPage { return .sparsePage }
        return .disabled
    }

    /// T-002: 两页视觉不齐备时, 判定缺失的是当前页还是目标页(观察者)。
    private func visualsMissingResult(
        visuals: [(page: Int, visual: PageVisual)]
    ) -> PageCompositorActivationResult {
        let present = Set(visuals.map(\.page))
        if !present.contains(currentPage) { return .currentVisualMissing }
        return .targetVisualMissing
    }

    /// T-002: 一次手势回到 idle 后, 按手势差分喂入 paging 计数并异步输出摘要。
    private func flushCompositorActivationTelemetry() {
        let telemetry = pageCompositorActivationTelemetry
        telemetry.recordDisplayFrameCount(paging.displayFrameCount - compositorTelemetryStartDisplayFrames)
        telemetry.recordScrollWriteCount(paging.scrollWriteCount - compositorTelemetryStartScrollWrites)
        _ = telemetry.flushGesture(
            completionReason: telemetryCompletionReason,
            settleDurationMs: telemetrySettleDurationMs
        )
        telemetryCompletionReason = .settled
        telemetrySettleDurationMs = nil
    }

    /// 运动停止(idle)→ 收掉 compositor: 同步真实 clip 到精确偏移 → reveal live。
    ///
    /// live 降级路径(compositor 未激活)在快速甩页时同样可能出现“真实 clip 已到
    /// 目标页、cell 尚未物化”的空白揭示帧。收尾时强制一次同步布局，让目标页
    /// cell 在当前 runloop 物化(占位图标立即可见)，与 v0.5.1 的合成器空窗修复
    /// 对齐：两条路径都必须在用户看到页面前完成 cell 物化。
    /// 幂等: compositor 未激活时只做 live 收尾物化。
    private func finalizePageCompositor() {
        if pageCompositor.isActive {
            pageCompositor.finishSettle()
            // T-027: finishSettle teardown 后 compositor 已不激活。
            pagingPerfTelemetry.markCompositorActive(false)
            return
        }
        guard currentSurface != .appLibrary, !searchMode, pageCount > 0 else { return }
        collectionView.layoutSubtreeIfNeeded()
        liveSettleLayoutSyncCountForDiag += 1
    }

    /// 显式 shutdown(search/folder/settings/hide/drag 开始/配置/scale/结构变更)。
    /// 同步收尾: 捕获当前 visual offset → 真实 clip 同步 → reveal → 移除, 无僵尸 layer。
    func shutdownPageCompositor() {
        pageCompositor.shutdown()
        // T-027: shutdown teardown 后 compositor 已不激活。
        pagingPerfTelemetry.markCompositorActive(false)
    }

    /// purge 页面视觉缓存(hide / 内存压力 / scale 变更)。
    func purgePageVisuals() {
        memoryPressurePurgeCountForDiag += 1
        pageVisualCache.removeAll()
    }

    /// 调度 idle 视觉准备(防抖 100ms; 仅 idle 时执行, 绝不阻塞手势起点)。
    /// 触发: settle 完成 / show 稳定 / 数据与几何变化 / 图标安静。
    ///
    /// L15: 每次调度取消在途防抖任务并替换, 快速连续变化只保留最后一个;
    /// 任务完成后若仍是当前代际则置 nil(旧任务被取消/代际过期时不误清新任务)。
    ///
    /// F10 语义澄清: `pageVisualPrepareInFlight` 是 generation-guarded 的共享
    /// 准备任务——`pageVisualPrepareTask?.cancel()` 只取消 100ms 防抖外壳,
    /// 已经开始执行的 idle 视觉准备不会中途被掐断(避免浪费已启动的光栅化),
    /// 这是有意的设计, 不是遗漏。
    func schedulePageVisualPrepare() {
        guard pageVisualCompositorEnabled, isViewLoaded, collectionView != nil else { return }
        pageVisualPrepareGeneration &+= 1
        let generation = pageVisualPrepareGeneration
        pageVisualPrepareTask?.cancel()
        pageVisualPrepareTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self,
                  generation == self.pageVisualPrepareGeneration,
                  self.paging.phase == .idle,
                  self.paging.isEnabled,
                  !self.searchMode,
                  self.currentSurface != .appLibrary else { return }
            await self.prepareWorkingSetVisuals()
            if generation == self.pageVisualPrepareGeneration {
                self.pageVisualPrepareTask = nil
            }
        }
    }

    /// 为当前 working set(previous/current/next)准备/复用页面视觉。
    ///
    /// 逐页(idle):
    /// 1. 每页独立解析图标 → 该页 iconEpoch(页内可用集合的稳定哈希)。
    /// 2. 逐页冻结请求 → 后台光栅化 → 键复验后插入缓存。
    /// 图标集合变化(迟到图标)→ 该页新 epoch → 旧键失效, 下次 idle 只重建
    /// 受影响页。
    ///
    /// 串行化: 多个调用方(防抖 Task / 测试 seam)并发进入时共享同一在途任务,
    /// 保证语言快照与缓存键自洽(并发 prepare 会让语言代数与插入键失配)。
    func prepareWorkingSetVisuals() async {
        if let inFlight = pageVisualPrepareInFlight {
            await inFlight.value
            return
        }
        let task = Task { [weak self] in
            _ = await self?.performWorkingSetPrepare()
        }
        pageVisualPrepareInFlight = task
        await task.value
        pageVisualPrepareInFlight = nil
    }

    private func performWorkingSetPrepare() async {
        guard pageVisualCompositorEnabled, isViewLoaded, collectionView != nil else { return }
        let display = store.displayModel()
        guard currentPage >= 0, currentPage < display.pages.count else { return }
        // 全程快照: 数据修订在准备起点捕获一次, 之后所有键构建与插入复验
        // 都基于它(不再实时读 store.displayRevision)。
        let capturedRevision = store.displayRevision
        let g = geometry
        guard g.pageWidth > 0, g.gridWidth > 0, g.gridHeight > 0 else { return }
        let scale = currentBackingScale
        // 语言代数在准备起点快照一次: 本次 working set 的键/激活检查共用同一值,
        // 自洽(语言切换会走 Settings/refresh 链路 → shutdown + purge + 重建)。
        // 提交时机: 全部页面处理成功且无复验失败之后(guard 早退/复验失败不更新)。
        let languageRevision = Self.languageRevision()

        // 逐页独立解析图标 → 每页独立 iconEpoch: 迟到图标只触发对应页的新
        // epoch 重建, 不再牵动整个 working set(缓存键按页独立)。
        // 方向感知两页: 首页 [0,1], 末页 [last-1,last], 中间页 [c-1,c,c+1]。
        let pages: [Int]
        if currentPage == 0 {
            pages = [0, 1].filter { $0 < display.pages.count }
        } else if currentPage == display.pages.count - 1 {
            pages = [currentPage - 1, currentPage]
        } else {
            pages = [currentPage - 1, currentPage, currentPage + 1]
        }
        // 任一页插入前复验失败 → 本次语言代数不提交(等下一次完整成功)。
        var recheckFailed = false
        for page in pages {
            let iconSet = await pageVisualRenderer.resolveIcons(
                page: page,
                items: display.pages[page],
                folderChildrenPayload: display.folderChildrenPayload,
                geometry: g,
                scale: scale,
                iconProvider: iconProvider
            )
            let iconEpoch = pageVisualRenderer.epoch(for: iconSet)
            let key = pageVisualRenderer.makeKey(
                page: page,
                displayRevision: capturedRevision,
                geometry: g,
                scale: scale,
                languageRevision: languageRevision,
                iconEpoch: iconEpoch
            )
            if pageVisualCache.contains(key) { continue }
            let start = CACurrentMediaTime()
            let visual = await pageVisualRenderer.prepare(
                page: page,
                items: display.pages[page],
                displayName: { [weak self] id in self?.store.displayName(for: id) ?? "" },
                folderName: { [weak self] id in self?.store.folderName(for: id) ?? "" },
                geometry: g,
                scale: scale,
                displayRevision: capturedRevision,
                languageRevision: languageRevision,
                icons: iconSet,
                iconEpoch: iconEpoch
            )
            pageCompositor.metrics.recordVisualBuild(
                durationMs: (CACurrentMediaTime() - start) * 1000
            )
            if let visual {
                // 插入前最终复验: 快照期间数据/语言/几何任一变化 → 直接丢弃
                // (不插入)。currentKey == visual.key 已含几何匹配(shapshot 键
                // vs 实时几何); displayRevision/languageRevision 不在键比较中
                // (键用的是快照值), 需显式校验快照保持。
                let currentKey = pageVisualRenderer.makeKey(
                    page: page,
                    displayRevision: capturedRevision,
                    geometry: self.geometry,
                    scale: scale,
                    languageRevision: languageRevision,
                    iconEpoch: iconEpoch
                )
                if currentKey == visual.key,
                   store.displayRevision == capturedRevision,
                   Self.languageRevision() == languageRevision {
                    pageVisualCache.insert(visual)
                } else {
                    recheckFailed = true
                }
            }
        }
        // 语言代数提交: 全部页面处理成功且无复验失败(guard 早退/复验失败不更新)。
        if !recheckFailed {
            lastPreparedLanguageRevision = languageRevision
        }
    }

    private var currentBackingScale: Int {
        let scale = view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        return max(1, Int(scale.rounded()))
    }

    /// 语言代数(缓存键组成部分; 会话内稳定)。
    private static func languageRevision() -> UInt64 {
        switch L10n.currentLanguage {
        case .system: return 0
        case .english: return 1
        case .simplifiedChinese: return 2
        case .traditionalChinese: return 3
        }
    }

    // MARK: - P2 诊断 seam

    /// 遥测汇总(仅 enabled 时记录数值)。
    func pageCompositorMetricsSummary() -> String {
        pageCompositor.metrics.summary(
            cacheHits: pageVisualCache.hitCount,
            cacheMisses: pageVisualCache.missCount,
            cacheBytes: pageVisualCache.totalBytes
        )
    }

    var pageCompositorActiveForDiag: Bool { pageCompositor.isActive }
    var pageCompositorEligibleForDiag: Bool { compositorCanActivate() }
    var pageCompositorCurrentOffsetForDiag: CGFloat { pageCompositor.currentOffset }
    var pageCompositorLayerFramesForDiag: [CGRect] { pageCompositor.layerFramesForDiag }
    var pageCompositorPageIndicesForDiag: [Int] { pageCompositor.pageIndicesForDiag }
    var pageCompositorLiveOpacityForDiag: Float? { pageCompositor.liveLayerOpacityForDiag }
    var pageCompositorEventsForDiag: [PageCompositor.Event] { pageCompositor.eventsForDiag }
    /// clip 同步时强制同步布局的次数(空窗修复回归观察)。
    private(set) var pageCompositorSyncLayoutCountForDiag = 0
    /// live 降级 settle 收尾强制同步布局的次数(空白页修复回归观察)。
    private(set) var liveSettleLayoutSyncCountForDiag = 0
    /// settling 期间真实 clip 遮盖下渐进跟进的帧数(平滑落地诊断)。
    private(set) var pageVisualRealClipAdvanceCountForDiag = 0
    /// Unified paging event sequence used by the real gesture integration probe.
    /// This is an internal diagnostic seam; it records no product state and is
    /// inactive unless a test explicitly starts a recording.
    private var pagingEventSequenceRecording = false
    private var pagingEventSequence: [String] = []
    private var pagingEventMarkers: Set<String> = []

    var pagingEventSequenceForDiag: [String] { pagingEventSequence }

    func beginPagingEventSequenceForDiag() {
        pagingEventSequenceRecording = true
        pagingEventSequence = []
        pagingEventMarkers = []
    }

    private func recordPagingEventForDiag(_ marker: String) {
        guard pagingEventSequenceRecording, pagingEventMarkers.insert(marker).inserted else { return }
        pagingEventSequence.append(marker)
    }

    /// 目标页已物化 cell 数(测试: 揭露时刻 cell 应就绪)。
    var visibleItemsCountForDiag: Int { collectionView.visibleItems().count }
    var pageVisualCacheCountForDiag: Int { pageVisualCache.visualCount }
    var pageVisualCacheTotalBytesForDiag: Int { pageVisualCache.totalBytes }
    /// 缓存键快照(LRU 序; 测试验证每页独立 iconEpoch 用)。
    var pageVisualKeysForDiag: [PageVisualKey] { pageVisualCache.keysForDiag }

    /// 真实 clip 水平偏移(测试/诊断)。
    var clipOffsetXForDiag: CGFloat {
        collectionView.enclosingScrollView?.contentView.bounds.origin.x ?? -1
    }

    /// 测试 seam: 直接驱动一轮 working set 准备(await 后台渲染完成)。
    func waitForPageVisualPrepareForDiag() async {
        await prepareWorkingSetVisuals()
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

    /// App Library 前景面的水平滚动路由(Stage E9b)。
    ///
    /// 复用外层 `PagingInteractionController`(唯一 settle/display-link 引擎),
    /// 不创建第二套 horizontal 滚动 writer / 第二个 settle。仅当前 surface 为
    /// `.appLibrary` 且非搜索模式时生效; category detail 已由 Library 的
    /// `isScrollPaused` gate 在事件进入本方法前消费, 不重复门控。
    /// 普通 Launcher page 输入路径(handlePageScroll)不改变。
    func handleAppLibraryHorizontalScroll(_ event: NSEvent) -> Bool {
        guard !searchMode, currentSurface == .appLibrary else { return false }
        return paging.handleWheel(event)
    }

    /// 第一排实际布局 frame 的视觉顶部文档 y(布局诊断)。
    func firstRowTopDocumentY() -> CGFloat {
        firstRowDocumentFrame()?.minY ?? geometry.gridOrigin.y
    }

    /// 当前页第一排实际 layout attributes 的文档 frame。
    /// 在 flipped collection view 坐标中, frame.minY 是视觉顶部。
    func firstRowDocumentFrame() -> CGRect? {
        guard isViewLoaded, collectionView != nil,
              let layout = collectionView.collectionViewLayout as? PagingGridLayout else {
            return nil
        }
        view.layoutSubtreeIfNeeded()
        collectionView.layoutSubtreeIfNeeded()

        let section: Int
        if searchMode {
            section = 0
        } else {
            guard collectionView.numberOfSections > 0 else { return nil }
            // 诊断取当前物理 surface 的 section(Library → 0, 普通页 → n + 1)。
            section = min(physicalSurfaceIndex, collectionView.numberOfSections - 1)
        }
        guard section < collectionView.numberOfSections else { return nil }
        let itemCount = collectionView.numberOfItems(inSection: section)
        guard itemCount > 0 else { return nil }
        let firstRowCount = min(layout.columns, itemCount)

        var rowFrame: CGRect?
        for item in 0..<firstRowCount {
            let path = IndexPath(item: item, section: section)
            guard let frame = layout.layoutAttributesForItem(at: path)?.frame else { continue }
            rowFrame = rowFrame?.union(frame) ?? frame
        }
        return rowFrame
    }

    /// 将第一排实际 frame 转换到调用方指定的共同坐标空间。
    func firstRowFrame(in targetView: NSView) -> CGRect? {
        guard let documentFrame = firstRowDocumentFrame() else { return nil }
        return collectionView.convert(documentFrame, to: targetView)
    }

    /// 将页点容器 frame 转换到调用方指定的共同坐标空间。
    func pageDotsFrame(in targetView: NSView) -> CGRect? {
        guard isViewLoaded, let pageDots else { return nil }
        view.layoutSubtreeIfNeeded()
        pageDots.layoutSubtreeIfNeeded()
        return pageDots.convert(pageDots.bounds, to: targetView)
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

    /// PA4 探针: 沿真实 Library 轴仲裁/路由链路驱动 precise 手势
    /// (显式 phase; 合成事件 phase 往返不可靠)。返回是否水平交付外层分页。
    @discardableResult
    func libraryProbeFeed(phase: NSEvent.Phase, event: NSEvent) -> Bool {
        libraryControllerForDiag?.probeFeed(phase: phase, event: event) ?? false
    }

    /// PA4 探针: 沿真实 Library momentum 路由驱动 momentum 事件。
    func libraryProbeFeedMomentum(event: NSEvent) {
        libraryControllerForDiag?.probeFeedMomentum(event: event)
    }

    /// PA4 探针: paging phase 描述。
    func pagingProbePhase() -> String {
        paging.phaseDescription
    }

    /// PA4 探针: display link 是否活动。
    func pagingProbeDisplayLinkActive() -> Bool {
        paging.isDisplayLinkActive
    }

    func pagingProbeGesture(deltaXs: [CGFloat]) {
        paging.probeGesture(deltaXs: deltaXs)
    }

    /// Test-only deterministic time seam for probe-driven paging integration tests.
    /// Real CADisplayLink timing remains unchanged.
    func enableDeterministicPagingProbeClock(frameDuration: CFTimeInterval = 1.0 / 120.0) {
        paging.enableDeterministicProbeClock(frameDuration: frameDuration)
    }

    func pagingProbeDisplayFrame() -> Bool {
        paging.probeDisplayFrame()
    }

    /// Test-only lifecycle probes keep teardown behavior wired through the real
    /// GridViewController/PagingInteractionController callbacks.
    func pagingProbeShutdown() {
        paging.shutdown()
    }

    func pagingProbeDisable() {
        paging.isEnabled = false
    }

    func pagingProbeJumpTo(page: Int) {
        paging.jumpTo(page: page)
    }

    /// 布局诊断(§56/§83): 一次交互中 prepare / attribute query 计数。
    var layoutDiagnostics: String {
        let layout = collectionView.collectionViewLayout as? PagingGridLayout
        return "prepare=\(layout?.prepareCount ?? 0) attributeQueries=\(layout?.attributeQueryCount ?? 0) attributeCandidatesLast=\(layout?.lastAttributeCandidateCount ?? 0) attributeCandidatesMax=\(layout?.maxAttributeCandidateCount ?? 0) itemFrames=\(layout?.itemFrameCount ?? 0)"
    }

    /// 确定性诊断(冒烟验证用): 当前快照结构。
    func diagnostics() -> String {
        let snapshot = dataSource.snapshot()
        return "sections=\(snapshot.numberOfSections) items=\(snapshot.itemIdentifiers.count) pageCount=\(pageCount) search=\(searchMode)"
    }

    /// 快照每 section item 数(测试/诊断)。
    /// paged + leading 模式: section 0 = Library host(1), 普通页从 section 1 开始。
    var snapshotSectionCountsForDiag: [Int] {
        let snapshot = dataSource.snapshot()
        return snapshot.sectionIdentifiers.map { snapshot.numberOfItems(inSection: $0) }
    }

    var diagnosticSnapshotItemCount: Int {
        dataSource.snapshot().itemIdentifiers.count
    }

    /// 更新页码指示点(搜索模式与 Library active 时隐藏)。
    /// 页点只对应普通 Layout page count(Library 不占 dot); 可点击, 复用 paging engine(Stage A8)。
    ///
    /// 增量路径: 可见性不变且数量匹配时只切换 active 态, 不重建视图树。
    /// 本函数在 settle 目标页落地时同步执行(onSettleTargetPage → 第一帧 settle
    /// 之前), 全量销毁重建会直接吃掉首帧预算(PA1)。
    private func updatePageDots() {
        guard let pageDots else { return }
        let dotsVisible = !searchMode && currentSurface != .appLibrary && pageCount > 1
        if dotsVisible, pageDotViews.count == pageCount {
            for (index, dot) in pageDotViews.enumerated() {
                (dot as? PageDotView)?.setActive(index == currentPage)
            }
            return
        }
        for dot in pageDotViews {
            dot.removeFromSuperview()
        }
        pageDotViews = []
        guard dotsVisible else { return }
        for index in 0..<pageCount {
            let dot = PageDotView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 24).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 24).isActive = true
            dot.setAccessibilityLabel(L10n.format(.pageOf, "\(index + 1)", "\(pageCount)"))
            let active = index == currentPage
            dot.setActive(active)
            // 点击 → 现有 paging engine(startSettle), 目标页经 physical 索引映射
            // (普通页 n → 物理 n + 1), 不手动动画/不改 currentPage
            dot.onClick = { [weak self] in
                guard let self else { return }
                self.paging.startSettle(toPage: self.physicalIndex(forLayoutPage: index))
            }
            pageDots.addArrangedSubview(dot)
            pageDotViews.append(dot)
        }
    }

    /// 当前页点数(测试/诊断): 只等于普通 Layout page count, Library 不占 dot。
    var pageDotCountForDiag: Int { pageDotViews.count }

    // MARK: - 拖拽辅助

    /// 诊断: 是否仍有拖拽源 cell 保持隐藏(所有权泄漏检测)。
    var hasHiddenDragSourceForDiag: Bool {
        activeDragSourceIdentity != nil
    }

    /// 扁平显示索引(所有页面槽位)。
    func flatIndex(of item: Item) -> Int? {
        cachedDisplayItems.firstIndex(of: item)
    }

    /// 扁平索引 → IndexPath。
    /// paged + leading 模式: 普通页 page n → 物理 section n + 1(section 0 = Library host);
    /// search / 未启用 leading: 普通 section。
    func indexPath(atFlatIndex index: Int) -> IndexPath? {
        guard index >= 0, cachedDisplayItems.indices.contains(index) else { return nil }
        var sectionStart = 0
        for (section, count) in cachedSectionCounts.enumerated() {
            if index < sectionStart + count {
                return IndexPath(
                    item: index - sectionStart,
                    section: section + ordinarySectionOffset
                )
            }
            sectionStart += count
        }
        return nil
    }

    /// IndexPath(物理 section) → 普通扁平索引。
    /// 物理 section 0(Library host)与越界 section 返回 nil: host 不产生 AppCell/Drag identity。
    private func flatIndex(for indexPath: IndexPath) -> Int? {
        let section = indexPath.section - ordinarySectionOffset
        guard section >= 0,
              section < cachedSectionCounts.count,
              indexPath.item >= 0,
              indexPath.item < cachedSectionCounts[section] else {
            return nil
        }
        return cachedSectionCounts.prefix(section).reduce(0, +) + indexPath.item
    }

    private func cachedItem(at indexPath: IndexPath) -> Item? {
        guard let flatIndex = flatIndex(for: indexPath),
              cachedDisplayItems.indices.contains(flatIndex) else {
            return nil
        }
        return cachedDisplayItems[flatIndex]
    }

    /// 扁平索引 → 文档坐标 frame(二维拖拽预览用, Stage 1 §20-21)。
    /// paged + leading 模式: 文档坐标含 leading `pageWidth`(Library 页)偏移,
    /// 与 PagingGridLayout 的物理 section frame 对齐。
    func frame(atFlatIndex index: Int) -> CGRect {
        geometry.frame(forFlatIndex: index).offsetBy(dx: leadingDocumentOffset, dy: 0)
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

    /// 查询真实可见 Folder cell 的 icon/thumbnail frame，并转换到窗口 contentView。
    /// 该查询只在 Folder transition 开始前调用；动画帧不重新查询 collection view。
    func folderTransitionSource(
        for folderID: FolderID,
        in targetView: NSView
    ) -> FolderTransitionSource? {
        guard isViewLoaded, collectionView != nil, dataSource != nil,
              let index = flatIndex(of: .folder(folderID)),
              let path = indexPath(atFlatIndex: index),
              let cell = collectionView.item(at: path) as? AppCellView,
              let frame = cell.transitionSourceFrame(in: targetView) else {
            return nil
        }

        let revision = folderTransitionRevision.capture(
            synchronizing: gridLayout.liveGeometry
        )
        let representation = cell.dragRepresentation()
        let cornerRadius = cell.transitionSourceCornerRadius
        return FolderTransitionSource(
            folderID: folderID,
            frameInContentView: frame,
            cornerRadius: cornerRadius,
            representation: representation,
            cell: cell,
            isCurrent: { [weak self, weak cell, weak targetView] in
                guard let self, let cell, let targetView else { return false }
                guard self.folderTransitionRevision.isCurrent(revision),
                      cell.transitionSourceIdentity == folderID,
                      cell.view.window === targetView.window else { return false }
                return true
            }
        )
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
    /// 坐标系: 窗口点 → 文档坐标 → 减去 leading `pageWidth` → GridGeometry
    /// (普通 Layout page 数学, 页宽 = clip 可视宽, Stage 1 §5)。
    ///
    /// Library surface active 或指针位于 physical page 0(Library 区域)时返回
    /// 源项自身槽位(自落点 no-op): LayoutTransaction 产生相同布局,
    /// LayoutStore 对相同布局拒绝提交 → drop 被拒绝, 不写 Layout。
    func dragDestination(from point: NSPoint) -> LayoutTransaction.Destination {
        let local = collectionView.convert(point, from: nil)
        let g = geometry
        guard g.pageWidth > 0 else { return LayoutTransaction.Destination(page: 0, slot: 0) }
        if leadingSurfaceEnabled, currentSurface == .appLibrary || local.x < leadingDocumentOffset {
            return noOpDragDestination()
        }
        let documentPoint = CGPoint(x: local.x - leadingDocumentOffset, y: local.y)
        let (page, slot) = g.pageAndSlot(forDocumentPoint: documentPoint, pageCount: pageCount)
        return LayoutTransaction.Destination(page: page, slot: slot)
    }

    /// Library 区域的明确 no-op 落点。
    /// 有拖拽源身份 → 源项自身槽位(自落点, 视觉与布局都不变);
    /// folder-exit 等无源身份 → 当前普通页首槽(确定性, 绝不落进 Library)。
    private func noOpDragDestination() -> LayoutTransaction.Destination {
        if let identity = activeDragSourceIdentity {
            let item: Item
            switch identity {
            case .app(let id):
                item = .app(id)
            case .folder(let id):
                item = .folder(id)
            }
            if let index = flatIndex(of: item) {
                let (page, slot) = geometry.pageAndSlot(forFlatIndex: index)
                return LayoutTransaction.Destination(page: page, slot: slot)
            }
        }
        return LayoutTransaction.Destination(page: currentPage, slot: 0)
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
        return cachedItem(at: indexPath)
    }

    /// 全部显示项(冒烟诊断)。
    /// 只返回普通 `DisplayModel.DisplayItem`: 外层 wrapper 在此剥除,
    /// LauncherWindowController diagnostics/folder-open 调用保持既有语义不变。
    func allItems() -> [Item] {
        dataSource.snapshot().itemIdentifiers.compactMap { item in
            if case .layout(let layoutItem) = item {
                return layoutItem
            }
            return nil
        }
    }

    /// 光标悬停的文件夹(移入文件夹目标)。
    func hoveredFolder(at point: NSPoint) -> FolderID? {
        let local = collectionView.convert(point, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: local),
              let item = cachedItem(at: indexPath),
              case .folder(let id) = item else {
            return nil
        }
        return id
    }

    /// 拖拽命中诊断: dragHitTarget 被调用的次数(§A3 验证每帧单次分类)。
    private(set) var dragHitTargetQueryCount = 0

    /// 光标处的语义化拖拽目标。每帧只调用一次, 分类结果供文件夹悬停与建夹共用。
    func dragHitTarget(at point: NSPoint) -> DragHitTarget {
        dragHitTargetQueryCount += 1
        let local = collectionView.convert(point, from: nil)
        guard let indexPath = collectionView.indexPathForItem(at: local),
              let item = cachedItem(at: indexPath) else {
            return .none
        }
        switch item {
        case .app(let id):
            return .app(id)
        case .folder(let id):
            return .folder(id)
        }
    }

    /// 当前页内可见网格 rect(文档坐标, 边缘翻页判定用, Stage 1 §25)。
    /// paged + leading 模式: 普通页 frame 包含 leading `pageWidth` 文档偏移;
    /// Library active 时 drag edge path 不得把 Library 当普通页(edge 判定落在偏移后矩形)。
    var currentPageRect: CGRect {
        let g = geometry
        let page = min(max(0, currentPage), max(0, pageCount - 1))
        return g.pageRect(page: page).offsetBy(dx: leadingDocumentOffset, dy: 0)
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
