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

    /// 推进默认 run loop, 对应真实 AppKit 空闲事件循环。
    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    @Test("title mouse down cannot move its window")
    func titleMouseDownCannotMoveWindow() {
        let view = makeView()

        #expect(view.mouseDownCanMoveWindow == false)
    }

    @Test("press-and-hold past duration triggers rename once")
    func longPressActivatesRename() {
        let view = makeView()
        var renames = 0
        view.onRenameActivate = { renames += 1 }

        view.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 100, y: 15)))
        pump(0.45)
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

    @Test("0.3 second threshold separates short and long presses")
    func pressDurationThreshold() {
        let shortView = makeView()
        var shortRenames = 0
        shortView.onRenameActivate = { shortRenames += 1 }

        shortView.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 100, y: 15)))
        pump(0.2)
        shortView.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 100, y: 15)))

        let longView = makeView()
        var longRenames = 0
        longView.onRenameActivate = { longRenames += 1 }

        longView.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 100, y: 15)))
        pump(0.4)
        longView.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 100, y: 15)))

        #expect(shortRenames == 0)
        #expect(longRenames == 1)
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

    @Test("font changes invalidate the title intrinsic width")
    func fontChangeInvalidatesIntrinsicWidth() {
        let view = makeView()
        let originalWidth = view.intrinsicContentSize.width

        view.titleFont = .boldSystemFont(ofSize: 36)

        #expect(view.intrinsicContentSize.width > originalWidth)
    }
}
