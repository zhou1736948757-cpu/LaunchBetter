import AppKit
import LaunchUI

/// 启动器窗口协调器: 应用级 show/hide/toggle 语义。
@MainActor
public final class LauncherWindowCoordinator {
    private let windowController: LauncherWindowController

    public init(windowController: LauncherWindowController) {
        self.windowController = windowController
    }

    public func show() {
        windowController.show()
    }

    public func hide() {
        windowController.hide()
    }

    public func toggle() {
        windowController.toggle()
    }
}
