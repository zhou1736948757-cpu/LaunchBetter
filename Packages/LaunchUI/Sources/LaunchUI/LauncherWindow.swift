import AppKit

/// 启动器窗口: 无边框、可成为 key/main、浮于普通窗口之上。
///
/// 旧版教训(§92): 无边框窗口默认不可成为 key/main,必须显式重写。
public final class LauncherWindow: NSWindow {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    /// 按键转发(窗口控制器处理导航)。
    public var onKeyDown: ((NSEvent) -> Void)?

    public override func keyDown(with event: NSEvent) {
        if let onKeyDown {
            onKeyDown(event)
        } else {
            super.keyDown(with: event)
        }
    }

    public init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        animationBehavior = .none
    }

    /// 显示在当前屏幕上(跟随鼠标所在屏幕, §94 多显示器基础)。
    public func showOnScreen(containing point: NSPoint?) {
        // 注意: 本 SDK(Swift 6.3 + macOS 26)对 NSScreen 可选值的 `??` 推断异常,
        // 会保留 Optional;必须用 if-let 显式解包。
        let screen: NSScreen
        if let s = Self.screenFor(point) {
            screen = s
        } else if let s = NSScreen.main {
            screen = s
        } else {
            return
        }
        let frame: NSRect = screen.frame
        setFrame(frame, display: true)
        makeKeyAndOrderFront(nil)
    }

    private static func screenFor(_ point: NSPoint?) -> NSScreen? {
        guard let point else { return nil }
        for screen in NSScreen.screens {
            let frame: NSRect = screen.frame
            if frame.contains(point) {
                return screen
            }
        }
        return nil
    }
}
