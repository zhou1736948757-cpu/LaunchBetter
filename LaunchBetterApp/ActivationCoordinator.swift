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

    /// 冒烟/截图等非交互模式不弹窗。
    private var isInteractive: Bool {
        let args = CommandLine.arguments
        return !args.contains("--smoke")
            && !args.contains("--dragtest")
            && !args.contains("--folders")
            && !args.contains("--screenshot")
            && !args.contains("--iconbench")
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

        hotkey.onTrigger = { [weak self] in
            Task { @MainActor in
                self?.windowController.toggle()
            }
        }
        // 默认 Cmd+L(Carbon keyCode 37, cmd 修饰符 256); 设置化属 Phase 9
        let registered = hotkey.start(keyCode: 37, modifiers: 256)
        print("ACTIVATION hotkey=Cmd+L registered=\(registered)")

        // 旧版应用冲突提示(§115: 两者同时监听触控板需退出旧版)
        checkLegacyConflict()
    }

    private func handleGesture(_ event: GestureEvent) {
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
        alert.messageText = "需要输入监控权限"
        alert.informativeText = "四指捏合手势需要“输入监控”权限才能工作。\n请点击“打开系统设置”,在 隐私与安全性 → 输入监控 中启用 LaunchBetter,然后回到应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
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
