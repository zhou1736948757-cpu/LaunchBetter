import AppKit
import Testing
@testable import LaunchUI

@Suite("Clickable collection view mouse-session guard")
@MainActor
struct ClickableCollectionViewSessionTests {
    private func makeEvent(at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
    }

    @Test("mouseUp without a matching mouseDown must not trigger click")
    func strayMouseUpIgnored() {
        let view = ClickableCollectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        var clicked = 0
        view.onClick = { _ in clicked += 1 }
        // 覆盖层在 mouseDown 后移除了祖先, 只把 mouseUp 漏到这里。
        view.mouseUp(with: makeEvent(at: NSPoint(x: 100, y: 100)))
        #expect(clicked == 0)
    }

    @Test("paired mouseDown+mouseUp triggers click")
    func pairedClickWorks() {
        let view = ClickableCollectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        var clicked = 0
        view.onClick = { _ in clicked += 1 }
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 50, y: 50), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 0
        )!
        view.mouseDown(with: down)
        view.mouseUp(with: makeEvent(at: NSPoint(x: 52, y: 52)))
        #expect(clicked == 1)
    }

    @Test("drag requires a matching mouseDown session")
    func dragRequiresMouseDown() {
        let view = ClickableCollectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        var began = false
        view.onDragBegin = { _ in began = true }
        let dragged = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: 300, y: 300), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 0, pressure: 0
        )!
        view.mouseDragged(with: dragged)
        #expect(!began)
    }
}
