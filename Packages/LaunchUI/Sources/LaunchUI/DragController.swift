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

    private(set) var state: State = .idle

    /// 弱引用打破与网格的强引用环(M4);网格由窗口控制器持有,生命周期更长。
    private weak var grid: GridViewController?
    private let store: any LauncherStoring
    private let sampleBuffer = GestureSampleBuffer()
    private var frameCoordinator: FrameCoordinator?
    private let overlay = DragOverlayLayer()

    private var sourceItem: DisplayModel.DisplayItem?
    private var sourceIndex = 0
    private var displayAtDragStart: DisplayModel?
    private var transformedPaths: Set<IndexPath> = []
    private var lastEdgeAdvance: CFTimeInterval = 0
    private var lastKnownPoint: CGPoint?
    private var sessionID = UUID()
    private var plainLabel = ""
    /// 拖拽开始时的显示修订(外部变化陈旧防护, 评审 M7)。
    private var dragStartRevision: UInt64 = 0

    init(grid: GridViewController, store: any LauncherStoring) {
        self.grid = grid
        self.store = store
    }

    var isDragging: Bool { state == .dragging }

    // MARK: - 拖拽生命周期

    /// 开始拖拽(已通过阈值判定)。
    func beginDrag(item: DisplayModel.DisplayItem, at point: NSPoint) {
        guard state == .idle else { return }
        guard let grid, !grid.isSearchMode, let sourceIndex = grid.flatIndex(of: item) else { return }
        state = .dragging
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
        case .folder(let id, _):
            plainLabel = store.folderName(for: id)
        }
        // 复用源单元格已显示的图标(零磁盘 IO, Stage 1 §23-24)
        overlay.configure(label: plainLabel, sourceImage: grid.visibleIconImage(for: item))
        grid.addOverlayLayer(overlay.layer)
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

    /// 拖拽移动(高频写入缓冲, 仅最新样本生效)。
    func updateDrag(at point: NSPoint) {
        guard state == .dragging else { return }
        sampleBuffer.write(point, session: sessionID)
    }

    /// 结束拖拽: 计算 drop 并应用一次结构更新。
    func endDrag(at point: NSPoint) {
        guard state == .dragging, let item = sourceItem else {
            cancelDrag()
            return
        }
        // 拖拽期间目录/布局/配置变化 → 陈旧 drop 防护: 取消拖拽(评审 M7)
        if store.displayRevision != dragStartRevision {
            cancelDrag()
            return
        }
        let display = displayAtDragStart ?? store.displayModel()
        let destination = grid?.dragDestination(from: point)
            ?? LayoutTransaction.Destination(page: 0, slot: 0)

        // 文件夹悬停 → 移入文件夹
        if case .app(let appID) = item, let folder = grid?.hoveredFolder(at: point) {
            store.addToFolder(app: appID, folder: folder)
        } else if let drop = LayoutTransaction.drop(
            display: display,
            source: source(from: item),
            destination: destination
        ) {
            store.applyDragDrop(drop.mutation)
        }
        teardown()
    }

    /// 取消拖拽(状态不变, 无结构更新)。
    func cancelDrag() {
        teardown()
    }

    /// 显式生命周期收尾(M4): 窗口隐藏/关闭时调用。
    func shutdown() {
        teardown()
    }

    private func teardown() {
        state = .idle
        frameCoordinator?.stop()
        frameCoordinator = nil
        sampleBuffer.clear()
        resetTransforms()
        grid?.removeOverlayLayer(overlay.layer)
        sourceItem = nil
        displayAtDragStart = nil
        lastKnownPoint = nil
        dragStartRevision = 0
    }

    private func source(from item: DisplayModel.DisplayItem) -> LayoutTransaction.Source {
        switch item {
        case .app(let id):
            return .app(id)
        case .folder(let id, _):
            return .folder(id)
        }
    }

    // MARK: - 每帧处理(仅 layer 变换)

    /// 每帧(display link): 静止时也持续处理最后样本(M1)。
    private func tick() {
        guard state == .dragging else { return }
        if let point = frameCoordinator?.readLatestSample() {
            lastKnownPoint = point
        }
        guard let point = lastKnownPoint else { return }
        processTick(point)
    }

    private func processTick(_ point: NSPoint) {
        guard state == .dragging, let item = sourceItem,
              let display = displayAtDragStart else { return }

        // 边缘翻页(节流 0.4s; 静止悬停持续触发, M1)
        maybeAdvancePage(point)

        // 文件夹悬停反馈
        let isFolderTarget = (grid?.hoveredFolder(at: point)) != nil && {
            if case .app = item { return true }
            return false
        }()

        // 所有分支统一更新 overlay 位置(m1 修复); 父视图 = 网格容器(视口坐标)
        if let grid {
            overlay.move(to: point, in: grid.view)
        }

        if isFolderTarget, let folder = grid?.hoveredFolder(at: point) {
            overlay.showFolderTarget(folder, store: store)
            resetTransforms()
            return
        }
        overlay.showPlain(label: plainLabel)

        let destination = grid?.dragDestination(from: point)
            ?? LayoutTransaction.Destination(page: 0, slot: 0)
        guard let preview = LayoutTransaction.preview(
            display: display, source: source(from: item), destination: destination
        ) else {
            resetTransforms()
            return
        }
        applyPreviewTransforms(gapIndex: preview.gapIndex)
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
        if atLeftEdge {
            grid.previousPage()
            lastEdgeAdvance = now
        } else if atRightEdge {
            grid.nextPage()
            lastEdgeAdvance = now
        }
    }

    /// 预览变换: 源项与 gap 之间的项整体移动一个槽位。
    /// 二维实现: 每项从当前 frame 移到相邻槽位 frame, dx/dy 由几何差值给出
    /// (跨行/跨页正确, Stage 1 §20-21)。
    /// 预览变换: 源项与 gap 之间的项整体移动一个槽位。
    /// 区间 = [min(source, gap), max(source, gap) - 1](评审 M5: 含 gap 处被挤动项)。
    private func applyPreviewTransforms(gapIndex: Int) {
        resetTransforms()
        guard sourceIndex != gapIndex else { return }
        let lower = min(sourceIndex, gapIndex)
        let upper = max(sourceIndex, gapIndex) - 1
        guard lower <= upper, let grid else { return }
        let step: Int = sourceIndex < gapIndex ? -1 : 1

        for index in lower...upper {
            guard let path = grid.indexPath(atFlatIndex: index),
                  let cell = grid.cellView(at: path) else { continue }
            let target = index + step
            guard target >= 0 else { continue }
            let sourceFrame = grid.frame(atFlatIndex: index)
            let targetFrame = grid.frame(atFlatIndex: target)
            let dx = targetFrame.minX - sourceFrame.minX
            let dy = targetFrame.minY - sourceFrame.minY
            guard dx != 0 || dy != 0 else { continue }
            cell.view.layer?.transform = CATransform3DMakeTranslation(dx, dy, 0)
            transformedPaths.insert(path)
        }
    }

    private func resetTransforms() {
        guard let grid else {
            transformedPaths.removeAll()
            return
        }
        for path in transformedPaths {
            guard let cell = grid.cellView(at: path) else { continue }
            cell.view.layer?.transform = CATransform3DIdentity
        }
        transformedPaths.removeAll()
    }
}

/// 拖拽 overlay: 跟随光标的真实图标层 + 文件夹目标提示。
@MainActor
final class DragOverlayLayer {
    let layer = CALayer()
    private let iconLayer = CALayer()
    private let labelLayer = CATextLayer()

    init() {
        layer.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: -4)
        iconLayer.cornerRadius = 16
        iconLayer.masksToBounds = true
        iconLayer.frame = layer.bounds
        iconLayer.contentsGravity = .resizeAspect
        labelLayer.fontSize = 11
        labelLayer.alignmentMode = .center
        labelLayer.foregroundColor = NSColor.white.cgColor
        labelLayer.frame = CGRect(x: 0, y: -20, width: 96, height: 16)
        layer.addSublayer(iconLayer)
        layer.addSublayer(labelLayer)
        layer.isHidden = true
    }

    /// 配置 overlay: 复用源单元格已渲染图标(零磁盘 IO), 无图标时保留占位。
    func configure(label: String, sourceImage: CGImage?) {
        if let sourceImage {
            iconLayer.contents = sourceImage
            iconLayer.backgroundColor = nil
        } else {
            iconLayer.contents = nil
            iconLayer.backgroundColor = NSColor.systemGray.cgColor
        }
        labelLayer.string = label
        layer.isHidden = false
    }

    /// 位置必须转 overlay 挂载父视图(视口)坐标 —— 分页滚动后 document 坐标含页偏移(评审 M6)。
    func move(to point: NSPoint, in container: NSView) {
        let local = container.convert(point, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = CGPoint(x: local.x, y: local.y - 60)
        CATransaction.commit()
    }

    func showFolderTarget(_ folder: FolderID, store: any LauncherStoring) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.backgroundColor = NSColor.systemGreen.cgColor
        labelLayer.string = "放入 \(store.folderName(for: folder))"
        CATransaction.commit()
    }

    func showPlain(label: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labelLayer.string = label
        CATransaction.commit()
    }
}
