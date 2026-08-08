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

    init(grid: GridViewController, store: any LauncherStoring) {
        self.grid = grid
        self.store = store
    }

    var isDragging: Bool { state == .dragging }

    // MARK: - 拖拽生命周期

    /// 开始拖拽(已通过阈值判定)。
    func beginDrag(item: DisplayModel.DisplayItem, at point: NSPoint) {
        guard state == .idle else { return }
        guard let grid, let sourceIndex = grid.flatIndex(of: item) else { return }
        state = .dragging
        sourceItem = item
        self.sourceIndex = sourceIndex
        displayAtDragStart = store.displayModel()
        lastEdgeAdvance = 0
        lastKnownPoint = point
        sessionID = UUID()

        switch item {
        case .app(let id):
            plainLabel = store.displayName(for: id)
        case .folder(let id, _):
            plainLabel = store.folderName(for: id)
        }
        overlay.configure(label: plainLabel)
        grid.addOverlayLayer(overlay.layer)
        overlay.move(to: point, in: grid.collectionViewRef)

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

        // 所有分支统一更新 overlay 位置(m1 修复)
        overlay.move(to: point, in: grid?.collectionViewRef ?? NSCollectionView())

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

    private func maybeAdvancePage(_ point: NSPoint) {
        guard let grid else { return }
        let collectionView = grid.collectionViewRef
        let local = collectionView.convert(point, from: nil)
        let width = collectionView.bounds.width
        let edge: CGFloat = 60
        let now = CACurrentMediaTime()
        guard now - lastEdgeAdvance > 0.4 else { return }
        if local.x < edge {
            grid.previousPage()
            lastEdgeAdvance = now
        } else if local.x > width - edge {
            grid.nextPage()
            lastEdgeAdvance = now
        }
    }

    /// 预览变换: 源项与 gap 之间的直接项整体平移一个槽位。
    private func applyPreviewTransforms(gapIndex: Int) {
        resetTransforms()
        guard sourceIndex != gapIndex else { return }
        let lower = min(sourceIndex, gapIndex) + 1
        let upper = max(sourceIndex, gapIndex) - 1
        guard lower <= upper, let grid else { return }
        let direction: CGFloat = sourceIndex < gapIndex ? -1 : 1
        let step = grid.slotStep

        for index in lower...upper {
            guard let path = grid.indexPath(atFlatIndex: index),
                  let cell = grid.cellView(at: path) else { continue }
            cell.view.layer?.transform = CATransform3DMakeTranslation(
                direction * step, 0, 0
            )
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

/// 拖拽 overlay: 跟随光标的图标层 + 文件夹目标提示。
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
        labelLayer.fontSize = 11
        labelLayer.alignmentMode = .center
        labelLayer.foregroundColor = NSColor.white.cgColor
        labelLayer.frame = CGRect(x: 0, y: -20, width: 96, height: 16)
        layer.addSublayer(iconLayer)
        layer.addSublayer(labelLayer)
        layer.isHidden = true
    }

    func configure(label: String) {
        iconLayer.backgroundColor = NSColor.systemGray.cgColor
        labelLayer.string = label
        layer.isHidden = false
    }

    func move(to point: NSPoint, in collectionView: NSCollectionView) {
        let local = collectionView.convert(point, from: nil)
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
        iconLayer.backgroundColor = NSColor.systemGray.cgColor
        labelLayer.string = label
        CATransaction.commit()
    }
}
