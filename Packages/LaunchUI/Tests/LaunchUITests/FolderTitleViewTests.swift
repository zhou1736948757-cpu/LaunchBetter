import AppKit
import Testing
@testable import LaunchUI

@Suite("Folder title long-press rename")
@MainActor
struct FolderTitleViewTests {
    private func makeView() -> FolderTitleView {
        let view = FolderTitleView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        view.text = "New Folder"
        return view
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint = .zero) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 0
        )!
    }

    /// 推进 eventTracking mode 的 run loop, 让长按 Timer 触发。
    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }
    }

    @Test("press-and-hold past duration triggers rename once")
    func longPressActivatesRename() {
        let view = makeView()
        var renames = 0
        view.onRenameActivate = { renames += 1 }

        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 100, y: 15)))
        pump(0.7)
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 100, y: 15)))

        #expect(renames == 1)
    }

    @Test("short click before duration does not rename")
    func shortClickDoesNotRename() {
        let view = makeView()
        var renames = 0
        view.onRenameActivate = { renames += 1 }

        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 100, y: 15)))
        pump(0.1)
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 100, y: 15)))
        pump(0.6)

        #expect(renames == 0)
    }

    @Test("movement beyond allowable cancels the press")
    func movementBeyondAllowableCancels() {
        let view = makeView()
        var renames = 0
        view.onRenameActivate = { renames += 1 }

        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 100, y: 15)))
        view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 160, y: 15)))
        pump(0.7)
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 160, y: 15)))

        #expect(renames == 0)
    }

    @Test("mouseUp after duration does not double-trigger")
    func noDoubleTrigger() {
        let view = makeView()
        var renames = 0
        view.onRenameActivate = { renames += 1 }

        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 100, y: 15)))
        pump(0.7)
        view.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 100, y: 15)))
        pump(0.3)

        #expect(renames == 1)
    }
}
