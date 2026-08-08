import AppKit
import LaunchCore

/// 可点击集合视图: 把点击坐标(窗口坐标)与右键菜单请求路由出去。
@MainActor
final class ClickableCollectionView: NSCollectionView {
    var onClick: ((NSPoint) -> Void)?
    var onContextMenu: ((NSPoint) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        onClick?(event.locationInWindow)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?(event.locationInWindow)
    }
}
