import AppKit
import LaunchCore

/// Source-aware threshold routing: resolve identity only at the paired
/// mouseDown point, while preserving the threshold-crossing point for the
/// semantic drag stream.
@MainActor
struct DragSourceAnchorSelection<Value> {
    let source: Value
    let currentPoint: NSPoint
}

@MainActor
enum DragSourceAnchorResolver {
    static func resolve<Value>(
        sourcePoint: NSPoint,
        currentPoint: NSPoint,
        valueAt: (NSPoint) -> Value?
    ) -> DragSourceAnchorSelection<Value>? {
        guard let source = valueAt(sourcePoint) else { return nil }
        return DragSourceAnchorSelection(source: source, currentPoint: currentPoint)
    }
}

/// 可点击/可拖拽集合视图:
/// - 单击(无拖动)→ onClick
/// - 按住移动超过阈值 → 进入拖拽(经 onDragBegin/onDragMove/onDragEnd)
/// - 右键 → onContextMenu
/// - 分页文档: 宽度锁定(NSClipView 滚动时会约束文档视图宽度, 导致分页失效)
@MainActor
final class ClickableCollectionView: NSCollectionView {
    /// 必须 flipped(y-down): 非 flipped 文档视图垂直滚动时 bounds.origin 不同步,
    /// 单元格可见区计算错误 → 滚动后内容消失(搜索模式实测证据, Stage 1 §11)。
    override var isFlipped: Bool { true }
    var onClick: ((NSPoint) -> Void)?
    var onContextMenu: ((NSPoint) -> NSMenu?)?
    var onDragBegin: ((NSPoint) -> Void)?
    var onDragMove: ((NSPoint) -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?

    /// Source-aware drag callback. `sourcePoint` is the paired mouseDown anchor;
    /// `currentPoint` is the pointer at threshold crossing. The legacy callback
    /// remains unchanged for existing callers.
    var onDragBeginWithSource: ((NSPoint, NSPoint) -> Void)?

    /// During the active drag callback, this remains the original mouseDown
    /// point rather than the threshold-crossing pointer.
    private(set) var activeDragSourcePoint: NSPoint?

    /// 分页锁定的文档宽度(0 = 未锁定)。
    private var lockedDocumentWidth: CGFloat = 0

    /// 锁定文档宽度(分页滚动用)。高度保持灵活(缩放/屏幕变化)。
    func lockDocumentWidth(_ width: CGFloat) {
        lockedDocumentWidth = width
        if frame.width != width {
            frame.size.width = width
        }
    }

    /// 设置文档尺寸: 宽度锁定(分页防 NSClipView 收缩), 高度按需(搜索溢出时垂直滚动)。
    func setDocumentSize(_ size: NSSize) {
        lockedDocumentWidth = size.width
        if frame.size != size {
            frame.size = size
        }
    }

    /// 解除文档宽度锁定(模式切换时恢复弹性)。
    func unlockDocumentWidth() {
        lockedDocumentWidth = 0
    }

    override func setFrameSize(_ newSize: NSSize) {
        if lockedDocumentWidth > 0 {
            super.setFrameSize(NSSize(width: lockedDocumentWidth, height: newSize.height))
        } else {
            super.setFrameSize(newSize)
        }
    }

    /// 拖拽阈值(pt)。
    private let dragThreshold: CGFloat = 5

    private var mouseDownPoint: NSPoint?
    private var dragging = false
    /// 当前 mouse session 的视觉 press owner。实际拖拽 session 仍由上层
    /// onDragBegin/onDragMove/onDragEnd callback 负责，这里只负责 AppCell 反馈。
    private weak var pressedAppCell: AppCellView?
    /// 本鼠标会话是否收到过 mouseDown。
    /// 覆盖层(Folder/Settings)可能在同一物理点击中于 mouseDown 后移除祖先,
    /// 导致后续 mouseUp 落到本视图; 无配对 mouseDown 的 mouseUp 必须忽略,
    /// 否则会误触发底层 click(启动/隐藏 Launcher)。
    private var receivedMouseDown = false

    override func mouseDown(with event: NSEvent) {
        receivedMouseDown = true
        mouseDownPoint = event.locationInWindow
        dragging = false
        activeDragSourcePoint = nil
        pressedAppCell?.cancelPressFeedback()
        pressedAppCell = appCell(at: event.locationInWindow)
        pressedAppCell?.beginPressFeedback(at: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = event.locationInWindow
        if !dragging {
            guard let start = mouseDownPoint else { return }
            let dx = point.x - start.x
            let dy = point.y - start.y
            if (dx * dx + dy * dy) >= dragThreshold * dragThreshold {
                dragging = true
                activeDragSourcePoint = start
                // 先通知 press owner 保留当前 presentation，再交给既有 drag
                // callback；因此 threshold crossing 不会先回弹。
                pressedAppCell?.updatePressFeedback(at: point)
                onDragBeginWithSource?(start, point)
                onDragBegin?(point)
            }
        } else {
            onDragMove?(point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            receivedMouseDown = false
            pressedAppCell = nil
            activeDragSourcePoint = nil
        }
        guard receivedMouseDown else { return }
        let point = event.locationInWindow
        if dragging {
            dragging = false
            pressedAppCell?.endPressFeedback(afterDragging: true)
            onDragEnd?(point)
        } else {
            pressedAppCell?.endPressFeedback(afterDragging: false)
            onClick?(point)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?(event.locationInWindow)
    }

    private func appCell(at point: NSPoint) -> AppCellView? {
        let local = convert(point, from: nil)
        guard let indexPath = indexPathForItem(at: local) else { return nil }
        return item(at: indexPath) as? AppCellView
    }

    // MARK: - 翻页滚轮/滑动(响应链: 集合视图最先收到)

    var onPageScroll: ((NSEvent) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        // 横向双指滑动 → 翻页; 纵向滚轮 → 翻页; 其余交给内部滚动
        if let onPageScroll, onPageScroll(event) {
            return
        }
        super.scrollWheel(with: event)
    }
}
