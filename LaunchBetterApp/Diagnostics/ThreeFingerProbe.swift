import AppKit
import LaunchCore
import LaunchUI

/// 3FDIAG: 三指协调器安装/启用 + 窗口可见性诊断。
@MainActor
enum ThreeFingerProbe {
    static func run(container: DependencyContainer) {
        let engine = container.activationCoordinator.diagnostics()
        let coordinator = container.threeFingerCoordinator.diagnostics()
        let windowVisible = container.windowController.isVisible
        let windowActuallyVisible = container.windowController.isActuallyVisible
        let ok = engine.contains("gesture=running")
            && coordinator.contains("installed=true")
            && coordinator.contains("enabled=true")
            && windowVisible
            && windowActuallyVisible
        print("3FDIAG engine=\(engine)")
        print("3FDIAG coordinator=\(coordinator)")
        print("3FDIAG windowVisible=\(windowVisible)")
        print("3FDIAG windowActuallyVisible=\(windowActuallyVisible)")
        print("3FDIAG \(ok ? "OK" : "FAIL")")
        DiagnosticRunner.terminateDiagnostic(success: ok)
    }
}
