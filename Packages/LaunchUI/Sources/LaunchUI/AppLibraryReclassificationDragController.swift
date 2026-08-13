import AppKit
import LaunchCore

/// 三指重分类拖拽的小型状态机(任务包 V3, A11-A20)。
///
/// 职责边界(规格 §3):
/// - 源身份(被拖 AppID + 源生效分类)
/// - 源视觉(复用已渲染图标 / 内存占位; 拖拽起点零磁盘 / 零 Info.plist / 零图标请求)
/// - 指针跟踪(窗口基坐标)与源视觉 overlay
/// - 目标分类卡命中(仅普通分类卡; Suggestions / Recently Added / 空白无效)
/// - hover 高亮(MotionTokens 约束的轻微 scale/border, 离开即恢复)
/// - drop / cancel(有效目标 → setCategoryOverride; 同分类 no-op; 空白/外部 cancel)
///
/// 明确不负责(规格 §3/§7/§8):
/// - 不触碰 LayoutStore / LayoutSnapshot / DragController / 文件夹 / 页槽
/// - 不跨面(Library↔Page1 不做), 无第二套 reorder/preview/folder-drop 引擎
/// - 不读写磁盘 / 不请求图标(源视觉复用 cell 当前已渲染图像)
///
/// 拖拽期的 Library 垂直滚动与 Library↔Page1 水平翻页挂起由宿主
/// (AppLibraryViewController)经既有 `PausableLibraryScrollView.isScrollPaused`
/// 门控完成, 本类不拥有滚动容器。
@MainActor
final class AppLibraryReclassificationDragController {
    /// 拖拽源快照(开始时刻捕获; 拖拽期间模型冻结, 不重新查询)。
    struct Source {
        let appID: AppID
        /// 源 app 的生效分类(经 model.categoryDetail; 同分类 no-op 判定用)。
        let sourceCategory: AppLibraryCategory
        /// 源视觉: cell 当前显示的图像(provider 图标或内存占位)。
        let visual: NSImage
        /// 图标点尺寸(overlay 尺寸基准)。
        let iconSize: CGFloat
    }

    enum DragState: Equatable {
        case idle
        case active(Source)

        /// `Source` 携带非 Equatable 的 `NSImage`, 合成实现不可用; 相等性只
        /// 比较身份语义(appID + 源生效分类), 视觉/几何不参与状态相等。
        static func == (lhs: DragState, rhs: DragState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle):
                return true
            case let (.active(a), .active(b)):
                return a.appID == b.appID && a.sourceCategory == b.sourceCategory
            default:
                return false
            }
        }
    }

    /// overlay 相对源图标尺寸的放大倍率(轻微抬升, 无大弹跳)。
    private static let overlayScale: CGFloat = 1.15

    private let hostView: NSView
    private let modelProvider: () -> AppLibraryModel
    private let categoryOverriding: (any AppLibraryCategoryOverriding)?
    /// 窗口点 → (卡片, cell)。仅用于目标命中(集合视图几何由宿主提供)。
    private let targetResolver: (NSPoint) -> (card: AppLibraryCard, cell: AppLibraryCardCell)?

    private let overlay = NSImageView()

    private(set) var state: DragState = .idle
    private(set) var hoveredCategory: AppLibraryCategory?
    private(set) var hoveredCell: AppLibraryCardCell?
    /// 目标变化次数(诊断: hover 高亮切换不应逐帧增长)。
    private(set) var targetChangeCount = 0

    /// drop 保存覆盖后的回调(宿主热刷新观察; 生产经 store 通知链路到达)。
    var onOverrideApplied: ((AppID, AppLibraryCategory) -> Void)?

    var isActive: Bool { state != .idle }

    var activeSource: Source? {
        if case .active(let source) = state { return source }
        return nil
    }

    /// 诊断: overlay 是否已挂到宿主视图上。
    var overlayVisibleForDiag: Bool { overlay.superview != nil }

    init(
        hostView: NSView,
        modelProvider: @escaping () -> AppLibraryModel,
        categoryOverriding: (any AppLibraryCategoryOverriding)?,
        targetResolver: @escaping (NSPoint) -> (card: AppLibraryCard, cell: AppLibraryCardCell)?
    ) {
        self.hostView = hostView
        self.modelProvider = modelProvider
        self.categoryOverriding = categoryOverriding
        self.targetResolver = targetResolver
        overlay.wantsLayer = true
        overlay.imageScaling = .scaleProportionallyUpOrDown
        overlay.layer?.shadowOpacity = 0.3
        overlay.layer?.shadowRadius = 10
        overlay.layer?.shadowOffset = CGSize(width: 0, height: -6)
        overlay.isHidden = true
    }

    /// 开始拖拽(宿主已确认源命中)。已激活时拒绝第二次 begin。
    @discardableResult
    func begin(source: Source, at point: NSPoint) -> Bool {
        guard !isActive else { return false }
        state = .active(source)
        hoveredCategory = nil
        hoveredCell = nil
        targetChangeCount = 0
        overlay.image = source.visual
        let size = source.iconSize * Self.overlayScale
        overlay.frame = CGRect(x: 0, y: 0, width: size, height: size)
        hostView.addSubview(overlay)
        moveOverlay(to: point, animated: false)
        overlay.isHidden = false
        return true
    }

    /// 指针跟踪: 移动 overlay + 重新命中目标分类卡。
    func update(at point: NSPoint) {
        guard isActive else { return }
        moveOverlay(to: point, animated: true)
        resolveHover(at: point)
    }

    /// 结束: 有效目标(不同分类的普通分类卡) → 保存覆盖; 同分类 / 空白 /
    /// 外部 → no-op / cancel。随后统一清理视觉与高亮。
    func end(at point: NSPoint) {
        guard let source = activeSource else { return }
        let local = hostView.convert(point, from: nil)
        guard hostView.bounds.contains(local) else {
            cancel()
            return
        }
        if let (card, _) = targetResolver(point),
           case .category(let category) = card.id,
           category != source.sourceCategory,
           let overriding = categoryOverriding {
            let appID = source.appID
            Task { [weak overriding] in
                await overriding?.setCategoryOverride(appID: appID, category: category)
            }
            onOverrideApplied?(appID, category)
        }
        finish()
    }

    /// 取消(无变更)。
    func cancel() {
        guard isActive else { return }
        finish()
    }

    /// 清除当前 hover(宿主在模型刷新/复用后调用, 防止 stale cell 高亮)。
    /// 不影响拖拽会话本身。
    func clearHover() {
        guard isActive, hoveredCell != nil || hoveredCategory != nil else { return }
        hoveredCell?.setReclassificationHoverHighlighted(false)
        hoveredCell = nil
        hoveredCategory = nil
    }

    // MARK: - Internal

    private func resolveHover(at point: NSPoint) {
        guard let source = activeSource else { return }
        guard let (card, cell) = targetResolver(point) else {
            clearHover()
            return
        }
        guard case .category(let category) = card.id, category != source.sourceCategory else {
            clearHover()
            return
        }
        guard hoveredCategory != category || hoveredCell !== cell else { return }
        if let previous = hoveredCell, previous !== cell {
            previous.setReclassificationHoverHighlighted(false)
        }
        hoveredCell = cell
        hoveredCategory = category
        cell.setReclassificationHoverHighlighted(true)
        targetChangeCount += 1
    }

    private func finish() {
        hoveredCell?.setReclassificationHoverHighlighted(false)
        hoveredCell = nil
        hoveredCategory = nil
        overlay.removeFromSuperview()
        overlay.isHidden = true
        state = .idle
    }

    private func moveOverlay(to point: NSPoint, animated: Bool) {
        let local = hostView.convert(point, from: nil)
        let origin = CGPoint(
            x: local.x - overlay.bounds.width / 2,
            y: local.y - overlay.bounds.height / 2
        )
        guard !animated
                || abs(overlay.frame.origin.x - origin.x) > 0.5
                || abs(overlay.frame.origin.y - origin.y) > 0.5 else {
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? MotionTokens.pressFeedback.response : 0
            context.allowsImplicitAnimation = animated
            overlay.frame.origin = origin
        }
    }
}
