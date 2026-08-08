import AppKit
import LaunchCore

/// 可点击/可拖拽集合视图:
/// - 单击(无拖动)→ onClick
/// - 按住移动超过阈值 → 进入拖拽(经 onDragBegin/onDragMove/onDragEnd)
/// - 右键 → onContextMenu
@MainActor
final class ClickableCollectionView: NSCollectionView {
    var onClick: ((NSPoint) -> Void)?
    var onContextMenu: ((NSPoint) -> NSMenu?)?
    var onDragBegin: ((NSPoint) -> Void)?
    var onDragMove: ((NSPoint) -> Void)?
    var onDragEnd: ((NSPoint) -> Void)?

    /// 拖拽阈值(pt)。
    private let dragThreshold: CGFloat = 5

    private var mouseDownPoint: NSPoint?
    private var dragging = false

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let point = event.locationInWindow
        if !dragging {
            guard let start = mouseDownPoint else { return }
            let dx = point.x - start.x
            let dy = point.y - start.y
            if (dx * dx + dy * dy) >= dragThreshold * dragThreshold {
                dragging = true
                onDragBegin?(point)
            }
        } else {
            onDragMove?(point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = event.locationInWindow
        if dragging {
            dragging = false
            onDragEnd?(point)
        } else {
            onClick?(point)
        }
        mouseDownPoint = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?(event.locationInWindow)
    }
}
