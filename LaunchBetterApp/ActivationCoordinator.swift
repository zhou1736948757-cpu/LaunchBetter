import AppKit
import Foundation
import LaunchCore
import LaunchPlatform
import LaunchUI

/// 激活协调器(§115): 手势/热键事件 → show/hide/toggle 决策。
///
/// 引擎只发事件, 本协调器决定窗口行为; 引擎不直接操作 LauncherStore/窗口。
@MainActor
public final class ActivationCoordinator {
    private let windowController: LauncherWindowController
    private let gestureEngine: GestureCaptureEngine
    private let hotkey: GlobalHotkey

    private var gestureStatus: GestureCaptureEngine.Status = .unavailable
    private var permissionPromptShown = false
    private var hotCornerMonitor: HotCornerMonitor?

    /// 冒烟/截图等非交互模式不弹窗。
    private var isInteractive: Bool {
        let args = CommandLine.arguments
        let nonInteractiveFlags = [
            "--smoke", "--dragtest", "--folders", "--screenshot",
            "--iconbench", "--pagetest", "--threefingerdiag",
            "--dragcacheprobe", "--pagingprobe", "--searchprobe", "--gridtest", "--perf",
            "--motionprobe", "--libraryshot", "--pagingscrollprobe",
            "--pagingeventtrace", "--pagingstressprobe", "--libraryblanktrace",
            "--libraryinteracttrace",
        ]
        return !nonInteractiveFlags.contains { args.contains($0) }
    }

    /// 按配置注册热键/热角(设置变更即时生效)。
    public func reconfigure(with config: AppConfiguration) {
        hotkey.stop()
        if config.hotkey.enabled {
            _ = hotkey.start(keyCode: config.hotkey.keyCode, modifiers: hotkeyModifiers(config.hotkey.modifiers))
        }
        reconfigureHotCorners(config.hotCorner)
    }

    private func hotkeyModifiers(_ modifiers: HotkeyModifiers) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= 256 }
        if modifiers.contains(.shift) { value |= 512 }
        if modifiers.contains(.option) { value |= 2048 }
        if modifiers.contains(.control) { value |= 4096 }
        return value
    }

    private func reconfigureHotCorners(_ corners: HotCornerConfig) {
        hotCornerConfigSnapshot = corners
        hotCornerMonitor?.stop()
        hotCornerMonitor = nil
        let hasAction = corners.topLeft != .none || corners.topRight != .none
            || corners.bottomLeft != .none || corners.bottomRight != .none
        guard hasAction else { return }
        let monitor = HotCornerMonitor { [weak self] in
            self?.hotCornerConfigSnapshot ?? corners
        }
        monitor.onAction = { [weak self] action in
            Task { @MainActor in
                self?.handleCornerAction(action)
            }
        }
        monitor.start()
        hotCornerMonitor = monitor
    }

    private var hotCornerConfigSnapshot: HotCornerConfig?

    /// 热角诊断(v0.3.4): 配置 + monitor 状态 + 当前鼠标所在角。
    public func hotCornerDiagnostics() -> String {
        let corners = hotCornerConfigSnapshot
        let point = NSEvent.mouseLocation
        var detected = "outside"
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let f = screen.frame
            let top = f.maxY - point.y < 24, bottom = point.y - f.minY < 24
            let left = point.x - f.minX < 24, right = f.maxX - point.x < 24
            if top && left { detected = "topLeft" }
            else if top && right { detected = "topRight" }
            else if bottom && left { detected = "bottomLeft" }
            else if bottom && right { detected = "bottomRight" }
        }
        return "config=\(String(describing: corners)) monitorRunning=\(hotCornerMonitor != nil) mouse=\(Int(point.x)),\(Int(point.y)) corner=\(detected)"
    }

    private func handleCornerAction(_ action: HotCornerAction) {
        switch action {
        case .none: break
        case .showLauncher: windowController.show()
        case .hideLauncher: windowController.hide()
        case .toggleLauncher: windowController.toggle()
        }
    }

    public init(
        windowController: LauncherWindowController,
        gestureEngine: GestureCaptureEngine,
        hotkey: GlobalHotkey
    ) {
        self.windowController = windowController
        self.gestureEngine = gestureEngine
        self.hotkey = hotkey
    }

    public func start() {
        gestureEngine.onGesture = { [weak self] event in
            Task { @MainActor in
                self?.handleGesture(event)
            }
        }
        gestureEngine.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.handleStatus(status)
            }
        }
        gestureEngine.start()
        // 初始状态直接读取(首次 setStatus 可能因状态相同被跳过)
        handleStatus(gestureEngine.currentStatus())
        print("ACTIVATION engineDetail=\(gestureEngine.lastStartDetail)")

        hotkey.onTrigger = { [weak self] in
            Task { @MainActor in
                self?.windowController.toggle()
            }
        }
        // 默认 Cmd+L(Carbon keyCode 37, cmd 修饰符 256); 设置变更经 reconfigure
        let registered = hotkey.start(keyCode: 37, modifiers: 256)
        print("ACTIVATION hotkey=Cmd+L registered=\(registered)")

        // 旧版应用冲突提示(§115: 两者同时监听触控板需退出旧版)
        checkLegacyConflict()
    }

    private func handleGesture(_ event: GestureEvent) {
        if CommandLine.arguments.contains("--touchdebug") {
            print("GESTURE_EVENT \(event == .pinchIn ? "pinchIn" : "pinchOut")")
        }
        switch event {
        case .pinchIn:
            windowController.show()
        case .pinchOut:
            windowController.hide()
        }
    }

    private func handleStatus(_ status: GestureCaptureEngine.Status) {
        gestureStatus = status
        switch status {
        case .waitingForPermission:
            print("ACTIVATION 四指手势等待输入监控权限")
            promptForPermissionIfNeeded()
        case .running:
            print("ACTIVATION 四指手势运行中")
        case .unavailable:
            print("ACTIVATION 四指手势不可用(框架/设备缺失)")
        }
    }

    /// 未授权 → 弹窗请求, 可跳转系统设置(启动时单次, 重查放设置界面)。
    private func promptForPermissionIfNeeded() {
        guard !permissionPromptShown, isInteractive else { return }
        permissionPromptShown = true
        let alert = NSAlert()
        alert.messageText = L10n.t(.permissionTitle)
        alert.informativeText = L10n.t(.permissionMessage)
        alert.addButton(withTitle: L10n.t(.permissionOpenSettings))
        alert.addButton(withTitle: L10n.t(.later))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func checkLegacyConflict() {
        let legacyRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.Eric-Yang.Launchpad-Back"
        }
        if legacyRunning {
            print("ACTIVATION WARN: 旧版 LaunchHistory 正在运行, 可能同时监听触控板; 建议退出后再测试手势")
        }
    }

    /// 诊断。
    public func diagnostics() -> String {
        "gesture=\(gestureStatus)"
    }
}
