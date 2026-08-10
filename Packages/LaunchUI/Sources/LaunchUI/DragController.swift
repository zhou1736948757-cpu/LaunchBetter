import AppKit
import LaunchCore
import QuartzCore

/// 拖拽控制器(§57/§113): 拖拽状态机 + 拖拽 overlay + 预览变换 + drop。
///
/// 高频路径: 鼠标事件 → GestureSampleBuffer(会话隔离, 仅最新)→ CADisplayLink
/// (每帧触发, 静止也持续处理最后样本, M1)→ FrameCoordinator → 本控制器。
/// 禁止: 逐帧 Diffable snapshot;逐帧进入 LauncherStore(§60)。
///
/// Drop: LayoutTransaction.drop 一次计算 → 一次布局变更 → 一次结构更新。
/// 生命周期: 由窗口控制器在 hide/关闭时调用 shutdown()(M4)。
///
/// 几何(Stage 1, P0): 全部走 GridGeometry —— 页宽 = clip 可视宽;边缘翻页用
/// 当前页可视 rect;预览变换用源/目标 frame 的二维差值(跨行/跨页正确)。
@MainActor
final class DragController {
    enum State: Equatable {
        case idle
        case dragging
    }

    /// 拖拽输入源(Stage 2 §17): 一个 session 只有一个 owner。
    enum DragInputSource: Equatable {
        case mouse
        case threeFinger
    }

    private(set) var state: State = .idle
    private(set) var activeInputSource: DragInputSource?

    /// 弱引用打破与网格的强引用环(M4);网格由窗口控制器持有,生命周期更长。
    private weak var grid: GridViewController?
    private let store: any LauncherStoring
    private let sampleBuffer = GestureSampleBuffer()
    private var frameCoordinator: FrameCoordinator?
    private let overlay = DragOverlayLayer()
    private let insertionIndicator = InsertionIndicatorLayer()

    private var sourceItem: DisplayModel.DisplayItem?
    private var sourceIndex = 0
    private struct FolderExitDragSession {
        let app: AppID
        let folder: FolderID
    }
    private var folderExitSession: FolderExitDragSession?
    private var folderExitLifecycle = FolderExitDragLifecycle()
    /// 仅在 LayoutStore 回执等待期间持有；teardown 会先清空，防止迟到回执重入 UI。
    private var folderExitCompletion: ((Bool) -> Void)?
    /// 根网格 drop 等待持久化期间冻结会话；sessionID 防止迟到回执命中新拖拽。
    private var awaitingRootDropResult = false
    private var rootDropCompletion: ((Bool) -> Void)?
    private var displayAtDragStart: DisplayModel?
    private var lastEdgeAdvance: CFTimeInterval = 0
    private var lastKnownPoint: CGPoint?
    private var sessionID = UUID()
    private var plainLabel = ""
    private var createFolderCandidate: AppID?
    private var createFolderCandidateSince: CFTimeInterval = 0
    /// 拖拽开始时的显示修订(外部变化陈旧防护, 评审 M7)。
    private var dragStartRevision: UInt64 = 0

    /// 文件夹局部拖拽在 handoff 后被取消时, 由窗口控制器恢复文件夹 chrome。
    var onFolderExitDragCancelled: (() -> Void)?

    init(grid: GridViewController, store: any LauncherStoring) {
        self.grid = grid
        self.store = store
    }

    var isDragging: Bool { state == .dragging }

    /// 诊断: overlay 是否仍挂在网格层上(teardown 后应为 false)。
    var hasOverlayForDiag: Bool {
        overlay.layer.superlayer != nil
    }

    /// 诊断: 是否在等待根 drop 持久化回执。
    var awaitingDropResultForDiag: Bool { awaitingRootDropResult }

    /// 诊断: 内部状态字符串。
    var stateForDiag: String { "\(state) awaitingRoot=\(awaitingRootDropResult)" }

    var isFolderExitDragging: Bool {
        state == .dragging && folderExitSession != nil && folderExitLifecycle.isActive
    }

    // MARK: - 拖拽生命周期

    /// 开始拖拽(已通过阈值判定)。inputSource 默认鼠标; 三指拖动显式传入(Stage 2 §17 互斥)。
    func beginDrag(
        item: DisplayModel.DisplayItem,
        at point: NSPoint,
        inputSource: DragInputSource = .mouse
    ) {
        // 已有一个拖动 session → 其他输入源不得二次 begin
        guard state == .idle, activeInputSource == nil else { return }
        guard let grid, !grid.isSearchMode, let sourceIndex = grid.flatIndex(of: item) else { return }
        state = .dragging
        activeInputSource = inputSource
        folderExitSession = nil
        folderExitLifecycle.cancel()
        folderExitCompletion = nil
        sourceItem = item
        self.sourceIndex = sourceIndex
        displayAtDragStart = store.displayModel()
        dragStartRevision = store.displayRevision
        lastEdgeAdvance = 0
        lastKnownPoint = point
        sessionID = UUID()

        switch item {
        case .app(let id):
            plainLabel = store.displayName(for: id)
        case .folder(let id):
            plainLabel = store.folderName(for: id)
        }
        // 复用源单元格已显示的视觉表示(零磁盘 IO)。先登记/隐藏源,
        // 再让 overlay 变为可见, 避免首帧同时存在两个视觉 owner。
        let representation = grid.beginDragSource(for: item)
        overlay.configure(label: plainLabel, representation: representation)
        grid.addOverlayLayer(overlay.layer)
        grid.addOverlayLayer(insertionIndicator.layer)
        overlay.move(to: point, in: grid.view)

        let coordinator = FrameCoordinator(
            view: grid.collectionViewRef, buffer: sampleBuffer, session: sessionID
        )
        coordinator.onFrame = { [weak self] in
            self?.tick()
        }
        frameCoordinator = coordinator
        coordinator.start()
        sampleBuffer.write(point, session: sessionID)
    }

    /// 文件夹子项越过卡片后启动的专用 session。
    /// 源 App 尚不在主网格 display 中, 因此只显示主网格 overlay/插入指示器;
    /// 目的地仍统一由 GridViewController.dragDestination(from:) 计算。
    @discardableResult
    func beginFolderExitDrag(
        app: AppID,
        from folder: FolderID,
        sourceImage: CGImage?,
        at point: NSPoint,
        inputSource: DragInputSource = .mouse
    ) -> Bool {
        // 保留旧 folder-child 调用签名; 内部立即转成语义化表示。
        beginFolderExitDrag(
            app: app,
            from: folder,
            representation: DragVisualRepresentation.legacy(image: sourceImage),
            at: point,
            inputSource: inputSource
        )
    }

    /// 文件夹子项 handoff 的语义化入口。DragController 不处理文件夹渲染细节。
    @discardableResult
    func beginFolderExitDrag(
        app: AppID,
        from folder: FolderID,
        representation: DragVisualRepresentation?,
        at point: NSPoint,
        inputSource: DragInputSource = .mouse
    ) -> Bool {
        guard state == .idle, activeInputSource == nil else { return false }
        guard let grid, !grid.isSearchMode,
              store.folderChildren(folder)?.contains(app) == true else { return false }
        guard folderExitLifecycle.begin() else { return false }

        state = .dragging
        activeInputSource = inputSource
        folderExitSession = FolderExitDragSession(app: app, folder: folder)
        sourceItem = nil
        sourceIndex = 0
        displayAtDragStart = store.displayModel()
        dragStartRevision = store.displayRevision
        lastEdgeAdvance = 0
        lastKnownPoint = point
        sessionID = UUID()
        plainLabel = store.displayName(for: app)

        overlay.configure(label: plainLabel, representation: representation)
        grid.addOverlayLayer(overlay.layer)
        grid.addOverlayLayer(insertionIndicator.layer)
        overlay.move(to: point, in: grid.view)

        let coordinator = FrameCoordinator(
            view: grid.collectionViewRef, buffer: sampleBuffer, session: sessionID
        )
        coordinator.onFrame = { [weak self] in
            self?.tick()
        }
        frameCoordinator = coordinator
        coordinator.start()
        sampleBuffer.write(point, session: sessionID)
        return isFolderExitDragging
    }

    /// 诊断: 手动驱动一帧(无 display link 环境验证缓存, v0.1.6 §69)。
    func probeProcessTick(_ point: NSPoint) {
        guard state == .dragging else { return }
        lastKnownPoint = point
        processTick(point)
    }

    /// 拖拽移动(高频写入缓冲, 仅最新样本生效)。
    /// inputSource 必须与 session owner 一致, 否则拒绝(Stage 2 M5: 迟到事件不污染他源 session)。
    @discardableResult
    func updateDrag(at point: NSPoint, inputSource: DragInputSource = .mouse) -> Bool {
        guard state == .dragging,
              activeInputSource == inputSource,
              !folderExitLifecycle.isAwaitingResult else { return false }
        sampleBuffer.write(point, session: sessionID)
        return true
    }

    /// 结束拖拽: 计算 drop 并应用一次结构更新。
    /// inputSource 必须与 session owner 一致(Stage 2 M5), 否则不提交、直接取消。
    func endDrag(
        at point: NSPoint,
        inputSource: DragInputSource = .mouse,
        leftMouseButtonPressed: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard state == .dragging else {
            completion?(false)
            return
        }
        guard !awaitingRootDropResult else { return }

        switch InputEndArbitration.decide(
            sessionOwner: activeInputSource?.inputEndSource,
            endingSource: inputSource.inputEndSource,
            leftMouseButtonPressed: leftMouseButtonPressed
        ) {
        case .end:
            break
        case .handoffToMouse:
            // raw threeFinger ended 只表示手势识别结束, 不表示左键已真实松开。
            // 立即转移 owner, 让 ended→mouseUp 之间的 mouseDragged 继续更新 overlay。
            activeInputSource = .mouse
            return
        case .reject:
            // 非 owner 的迟到 ended 不得取消另一输入源的有效 session。
            completion?(false)
            return
        }

        if let folderExitSession {
            // 已进入等待态时冻结专用 session；重复 mouseUp 不得重发 mutation。
            guard folderExitLifecycle.phase == .active else { return }
            guard store.displayRevision == dragStartRevision,
                  let grid else {
                teardown()
                completion?(false)
                return
            }
            let destination = grid.dragDestination(from: point)
            let displayIndex = grid.displayIndex(for: destination)
            guard folderExitLifecycle.awaitResult() else { return }
            let requestSessionID = sessionID
            folderExitCompletion = completion
            // 结果前冻结专用 session: 停止逐帧采样,但保留 overlay/目的地/会话身份。
            frameCoordinator?.stop()
            frameCoordinator = nil
            sampleBuffer.clear()
            store.moveOutOfFolder(
                app: folderExitSession.app,
                from: folderExitSession.folder,
                toDisplayIndex: displayIndex
            ) { [weak self] result in
                self?.completeFolderExit(result, sessionID: requestSessionID)
            }
            return
        }

        guard let item = sourceItem else {
            cancelDrag()
            completion?(false)
            return
        }
        // 拖拽期间目录/布局/配置变化 → 陈旧 drop 防护: 取消拖拽(评审 M7)
        if store.displayRevision != dragStartRevision {
            cancelDrag()
            completion?(false)
            return
        }
        let display = displayAtDragStart ?? store.displayModel()
        // mouseUp 可能恰好跨过 dwell 边界；必须用当前 point + 单调时钟重新决策。
        // 单一 hit-test 分类: 文件夹悬停与 App→App 建夹共用一次索引命中(§A3)。
        let hitTarget = grid?.dragHitTarget(at: point) ?? .none
        let hoveredFolder: FolderID? = {
            guard case .app = item, case .folder(let id) = hitTarget else { return nil }
            return id
        }()
        let createFolderDecision = updateCreateFolderTarget(
            item: item, pointedApp: hitTarget.pointedApp
        )
        let destination = grid?.dragDestination(from: point)
            ?? LayoutTransaction.Destination(page: 0, slot: 0)

        // 文件夹悬停 → 移入文件夹；App 悬停达到 dwell → 两 App 建夹。
        // 正式存储提供最终持久化回执；在结果到达前冻结同一拖拽会话。
        if let completingStore = store as? any LayoutMutationCompleting {
            if case .app(let appID) = item, let folder = hoveredFolder {
                awaitRootDropResult(completion: completion) { result in
                    completingStore.addToFolder(app: appID, folder: folder, completion: result)
                }
                return
            }
            if case .app(let appID) = item,
               case .active(let target) = createFolderDecision,
               hitTarget.pointedApp == target {
                awaitRootDropResult(completion: completion) { result in
                    completingStore.createFolder(
                        name: L10n.t(.newFolder),
                        appIDs: [appID, target],
                        completion: result
                    )
                }
                return
            }
            if let drop = LayoutTransaction.drop(
                display: display,
                source: source(from: item),
                destination: destination
            ) {
                awaitRootDropResult(completion: completion) { result in
                    completingStore.applyDragDrop(drop.mutation, completion: result)
                }
                return
            }
            teardown()
            completion?(false)
            return
        }

        // 兼容不提供持久化回执的轻量测试/嵌入式存储。
        if case .app(let appID) = item, let folder = hoveredFolder {
            store.addToFolder(app: appID, folder: folder)
        } else if case .app(let appID) = item,
                  case .active(let target) = createFolderDecision,
                  hitTarget.pointedApp == target {
            store.createFolder(name: L10n.t(.newFolder), appIDs: [appID, target])
        } else if let drop = LayoutTransaction.drop(
            display: display,
            source: source(from: item),
            destination: destination
        ) {
            store.applyDragDrop(drop.mutation)
        } else {
            teardown()
            completion?(false)
            return
        }
        teardown()
        completion?(true)
    }

    private func awaitRootDropResult(
        completion: ((Bool) -> Void)?,
        operation: (@escaping (Bool) -> Void) -> Void
    ) {
        guard !awaitingRootDropResult else { return }
        awaitingRootDropResult = true
        rootDropCompletion = completion
        let requestSessionID = sessionID
        frameCoordinator?.stop()
        frameCoordinator = nil
        sampleBuffer.clear()
        operation { [weak self] result in
            self?.completeRootDrop(result, sessionID: requestSessionID)
        }
    }

    private func completeRootDrop(_ result: Bool, sessionID: UUID) {
        guard self.sessionID == sessionID, awaitingRootDropResult else { return }
        let completion = rootDropCompletion
        rootDropCompletion = nil
        awaitingRootDropResult = false
        teardown()
        completion?(result)
    }

    private func completeFolderExit(_ result: Bool, sessionID: UUID) {
        guard self.sessionID == sessionID,
              folderExitSession != nil,
              folderExitLifecycle.resolve(result) else { return }
        let completion = folderExitCompletion
        folderExitCompletion = nil
        rootDropCompletion = nil
        awaitingRootDropResult = false
        // 先释放 overlay/session，再把最终 Bool 交给 FolderViewController。
        teardown()
        completion?(result)
    }

    /// 取消拖拽(状态不变, 无结构更新)。
    func cancelDrag() {
        teardown(restoreFolderExitVisual: true)
    }

    /// 显式生命周期收尾(M4): 窗口隐藏/关闭时调用。
    func shutdown() {
        teardown(restoreFolderExitVisual: true)
    }

    private func teardown(restoreFolderExitVisual: Bool = false) {
        let shouldRestoreFolderExitVisual = restoreFolderExitVisual && folderExitSession != nil
        grid?.setCreateFolderTargetHighlight(appID: nil, active: false)
        if let sourceItem {
            grid?.endDragSource(for: sourceItem)
        }
        folderExitCompletion = nil
        folderExitLifecycle.cancel()
        rootDropCompletion = nil
        awaitingRootDropResult = false
        state = .idle
        activeInputSource = nil
        frameCoordinator?.stop()
        frameCoordinator = nil
        sampleBuffer.clear()
        resetTransforms()
        dragFrameCount = 0
        destinationChangeCount = 0
        previewCalculationCount = 0
        transformWriteCount = 0
        folderHitTestCount = 0
        overlayVisualWriteCount = 0
        // 清拖拽缓存(v0.1.6 §89: teardown 必须 reset 所有 cache)
        lastDestination = nil
        lastGapIndex = nil
        currentTransforms.removeAll()
        lastOverlayVisual = nil
        cachedPageWidth = 0
        grid?.removeOverlayLayer(overlay.layer)
        insertionIndicator.hide()
        grid?.removeOverlayLayer(insertionIndicator.layer)
        sourceItem = nil
        folderExitSession = nil
        // 迟到的 LayoutStore 回执必须不能命中下一次 drag session。
        sessionID = UUID()
        displayAtDragStart = nil
        lastKnownPoint = nil
        dragStartRevision = 0
        createFolderCandidate = nil
        createFolderCandidateSince = 0
        if shouldRestoreFolderExitVisual {
            onFolderExitDragCancelled?()
        }
    }

    private func source(from item: DisplayModel.DisplayItem) -> LayoutTransaction.Source {
        switch item {
        case .app(let id):
            return .app(id)
        case .folder(let id):
            return .folder(id)
        }
    }

    // MARK: - 每帧处理(仅 layer 变换)

    /// 拖拽缓存(v0.1.6 §39-45): 同 slot 停留时避免重复 preview/transform 写。
    private var lastDestination: LayoutTransaction.Destination?
    private var lastGapIndex: Int?
    private var currentTransforms: [IndexPath: CATransform3D] = [:]
    private var lastOverlayVisual: OverlayVisual?
    /// 缓存绑定的几何指纹(页宽; 变化时清缓存重算, v0.1.6 M5)。
    private var cachedPageWidth: CGFloat = 0

    // 诊断计数(v0.1.6 §64)
    private(set) var dragFrameCount = 0
    private(set) var destinationChangeCount = 0
    private(set) var previewCalculationCount = 0
    private(set) var transformWriteCount = 0
    private(set) var folderHitTestCount = 0
    private(set) var overlayVisualWriteCount = 0

    private enum OverlayVisual: Equatable {
        case plain(String)
        case folderTarget(FolderID)
        case createFolderTarget(AppID)
    }

    /// 每帧(display link): 静止时也持续处理最后样本(M1)。
    private func tick() {
        guard state == .dragging else { return }
        dragFrameCount += 1
        if let point = frameCoordinator?.readLatestSample() {
            lastKnownPoint = point
        }
        guard let point = lastKnownPoint else { return }
        processTick(point)
    }

    private func processTick(_ point: NSPoint) {
        if folderExitSession != nil {
            guard folderExitLifecycle.phase == .active else { return }
            processFolderExitTick(point)
            return
        }
        guard state == .dragging, let item = sourceItem,
              let display = displayAtDragStart else { return }

        // 外部目录/布局/配置变化 → 取消拖拽(陈旧 session 防护, 评审 M5)
        if store.displayRevision != dragStartRevision {
            cancelDrag()
            return
        }
        // 几何(页宽)变化 → 清 preview 缓存, 下次按新几何重算(评审 M5)
        let currentPageWidth = grid?.geometry.pageWidth ?? 0
        if cachedPageWidth > 0, currentPageWidth != cachedPageWidth {
            clearTransformsIfNeeded()
            lastDestination = nil
            lastGapIndex = nil
        }
        cachedPageWidth = currentPageWidth

        // 边缘翻页(节流 0.4s; 静止悬停持续触发, M1)
        maybeAdvancePage(point)

        // 单一语义分类: 每帧一次 hit-test, 文件夹悬停与 App→App 建夹共用(§A3)。
        folderHitTestCount += 1
        let hitTarget = grid?.dragHitTarget(at: point) ?? .none
        let hoveredFolder: FolderID? = {
            guard case .app = item, case .folder(let id) = hitTarget else { return nil }
            return id
        }()
        let createFolderDecision = updateCreateFolderTarget(
            item: item, pointedApp: hitTarget.pointedApp
        )

        // Overlay 位置每帧更新(§40)
        if let grid {
            overlay.move(to: point, in: grid.view)
        }

        if let folder = hoveredFolder {
            grid?.setCreateFolderTargetHighlight(appID: nil, active: false)
            setOverlayVisual(.folderTarget(folder))
            insertionIndicator.hide()
            clearTransformsIfNeeded()
            lastDestination = nil
            lastGapIndex = nil
            return
        }
        switch createFolderDecision {
        case .none:
            // 普通排序 preview 前保证没有残留的 App 建夹高亮。
            grid?.setCreateFolderTargetHighlight(appID: nil, active: false)
            break
        case .waiting(let target):
            // 命中另一个 App 后，等待建夹 dwell 期间也不能显示普通排序预览。
            grid?.setCreateFolderTargetHighlight(appID: target, active: false)
            setOverlayVisual(.plain(plainLabel))
            clearReorderPreview()
            return
        case .active(let target):
            grid?.setCreateFolderTargetHighlight(appID: target, active: true)
            setOverlayVisual(.createFolderTarget(target))
            insertionIndicator.hide()
            clearTransformsIfNeeded()
            lastDestination = nil
            lastGapIndex = nil
            return
        }
        setOverlayVisual(.plain(plainLabel))

        // Destination 没变 → 不重新 preview / 不重写 transform(§40-41)
        guard let destination = grid?.dragDestination(from: point) else {
            insertionIndicator.hide()
            clearTransformsIfNeeded()
            lastDestination = nil
            lastGapIndex = nil
            return
        }
        guard destination != lastDestination else { return }
        destinationChangeCount += 1
        lastDestination = destination
        lastGapIndex = nil
        if let preview = LayoutTransaction.preview(
            display: display, source: source(from: item), destination: destination
        ) {
            previewCalculationCount += 1
            applyPreviewTransforms(gapIndex: preview.gapIndex)
            showInsertionIndicator(gapIndex: preview.gapIndex)
            lastGapIndex = preview.gapIndex
        } else {
            insertionIndicator.hide()
            clearTransformsIfNeeded()
        }
    }

    /// folder-exit session 的每帧路径: 复用主网格目的地算法, 不对主网格结构做预览位移。
    private func processFolderExitTick(_ point: NSPoint) {
        guard state == .dragging,
              folderExitSession != nil,
              folderExitLifecycle.phase == .active,
              let grid else { return }

        if store.displayRevision != dragStartRevision {
            cancelDrag()
            return
        }

        let currentPageWidth = grid.geometry.pageWidth
        if cachedPageWidth > 0, currentPageWidth != cachedPageWidth {
            lastDestination = nil
            lastGapIndex = nil
        }
        cachedPageWidth = currentPageWidth
        maybeAdvancePage(point)

        grid.setCreateFolderTargetHighlight(appID: nil, active: false)
        overlay.move(to: point, in: grid.view)
        setOverlayVisual(.plain(plainLabel))

        let destination = grid.dragDestination(from: point)
        guard destination != lastDestination else { return }
        destinationChangeCount += 1
        lastDestination = destination
        let displayIndex = grid.displayIndex(for: destination)
        lastGapIndex = displayIndex
        insertionIndicator.show(at: grid.overlayFrame(forFlatIndex: displayIndex))
    }

    /// Overlay 视觉状态缓存: 相同则不重复写 layer/string(§44)。
    private func setOverlayVisual(_ visual: OverlayVisual) {
        guard lastOverlayVisual != visual else { return }
        switch visual {
        case .plain(let label):
            overlay.showPlain(label: label)
        case .folderTarget(let folder):
            overlay.showFolderTarget(folder, store: store)
        case .createFolderTarget(let appID):
            overlay.showCreateFolderTarget(name: store.displayName(for: appID))
        }
        overlayVisualWriteCount += 1
        lastOverlayVisual = visual
    }

    /// App→App 建夹需要稳定悬停，避免普通排序松手时误建文件夹。
    /// pointedApp 来自每帧单次 dragHitTarget 分类, 不再重复做索引命中。
    private func updateCreateFolderTarget(
        item: DisplayModel.DisplayItem,
        pointedApp: AppID?
    ) -> CreateFolderHoverDecision {
        guard case .app(let sourceApp) = item,
              let target = pointedApp,
              target != sourceApp else {
            createFolderCandidate = nil
            createFolderCandidateSince = 0
            return .none
        }
        let now = CACurrentMediaTime()
        if createFolderCandidate != target {
            createFolderCandidate = target
            createFolderCandidateSince = now
        }

        return CreateFolderHoverDecision.resolve(
            sourceApp: sourceApp,
            pointedApp: target,
            candidate: createFolderCandidate,
            elapsed: now - createFolderCandidateSince
        )
    }

    /// 普通排序 preview 的统一清理；候选建夹等待态必须立即调用。
    private func clearReorderPreview() {
        insertionIndicator.hide()
        clearTransformsIfNeeded()
        lastDestination = nil
        lastGapIndex = nil
    }

    /// 边缘翻页: 使用当前可视页 rect(非文档宽度), 并考虑当前页边界(Stage 1 §25)。
    /// 只在指针位于当前页内时判定边缘, 防止翻页后指针落在前一页边缘造成来回振荡(§26)。
    private func maybeAdvancePage(_ point: NSPoint) {
        guard let grid else { return }
        let collectionView = grid.collectionViewRef
        let local = collectionView.convert(point, from: nil)
        let pageRect = grid.currentPageRect
        guard pageRect.width > 0 else { return }
        let edge: CGFloat = 60
        let now = CACurrentMediaTime()
        guard now - lastEdgeAdvance > 0.4 else { return }
        let atLeftEdge = local.x >= pageRect.minX && local.x < pageRect.minX + edge
        let atRightEdge = local.x <= pageRect.maxX && local.x > pageRect.maxX - edge
        // v0.1.6 m4: 首/尾页不再启动 no-op settle
        if atLeftEdge, grid.currentPageValue > 0 {
            grid.previousPage()
            lastEdgeAdvance = now
        } else if atRightEdge, grid.currentPageValue < grid.pageCountValue - 1 {
            grid.nextPage()
            lastEdgeAdvance = now
        }
    }

    /// 预览变换: 源项与 gap 之间的项整体移动一个槽位。
    /// 二维 diff 实现(v0.1.6 §42): 只写视觉结果真正变化的 layer。
    /// 区间 = [min(source, gap), max(source, gap) - 1](评审 M5: 含 gap 处被挤动项)。
    private func applyPreviewTransforms(gapIndex: Int) {
        var next: [IndexPath: CATransform3D] = [:]
        if let grid {
            for move in DragPreviewPlan.moves(sourceIndex: sourceIndex, gapIndex: gapIndex) {
                guard let path = grid.indexPath(atFlatIndex: move.itemIndex),
                      grid.cellView(at: path) != nil else { continue }
                let sourceFrame = grid.frame(atFlatIndex: move.itemIndex)
                let targetFrame = grid.frame(atFlatIndex: move.targetIndex)
                let dx = targetFrame.minX - sourceFrame.minX
                let dy = targetFrame.minY - sourceFrame.minY
                guard dx != 0 || dy != 0 else { continue }
                next[path] = CATransform3DMakeTranslation(dx, dy, 0)
            }
        }
        applyTransformDiff(next)
    }

    private func showInsertionIndicator(gapIndex: Int) {
        guard let grid else { return }
        insertionIndicator.show(at: grid.overlayFrame(forFlatIndex: gapIndex))
    }

    /// 目标状态 diff: old-only → identity; changed/new → 新变换; unchanged → 0 写。
    private func applyTransformDiff(_ next: [IndexPath: CATransform3D]) {
        guard let grid else {
            currentTransforms = next
            return
        }
        for path in currentTransforms.keys where next[path] == nil {
            guard let cell = grid.cellView(at: path) else { continue }
            cell.view.layer?.transform = CATransform3DIdentity
            transformWriteCount += 1
        }
        for (path, newTransform) in next {
            let isChange: Bool
            if let old = currentTransforms[path] {
                isChange = !CATransform3DEqualToTransform(old, newTransform)
            } else {
                isChange = true
            }
            guard isChange, let cell = grid.cellView(at: path) else { continue }
            cell.view.layer?.transform = newTransform
            transformWriteCount += 1
        }
        currentTransforms = next
    }

    /// 清空预览变换(仅当有需要时写 identity)。
    private func clearTransformsIfNeeded() {
        guard !currentTransforms.isEmpty else { return }
        applyTransformDiff([:])
    }

    private func resetTransforms() {
        guard let grid else {
            currentTransforms.removeAll()
            return
        }
        // v0.1.6 M4 修复: 预览位移写回 identity(currentTransforms 为目标状态源,
        // 不再依赖已废弃的 transformedPaths, 否则取消/结束时 layer 残留非 identity)
        for path in currentTransforms.keys {
            guard let cell = grid.cellView(at: path) else { continue }
            cell.view.layer?.transform = CATransform3DIdentity
        }
        currentTransforms.removeAll()
    }
}

private extension DragController.DragInputSource {
    var inputEndSource: InputEndArbitration.Source {
        switch self {
        case .mouse:
            return .mouse
        case .threeFinger:
            return .threeFinger
        }
    }
}
