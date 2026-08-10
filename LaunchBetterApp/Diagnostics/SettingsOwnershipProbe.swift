import AppKit
import LaunchCore
import LaunchUI

/// SETTINGSOWNER: Settings 交互所有权断言探针。
///
/// 断言(非打印): open→settings 面 / 三指 blocked / 根拖拽 blocked /
/// 无 overlay / 无隐藏源 / 空白点击只关设置 / 关闭后恢复 / 之后拖拽可用。
///
/// 严格顺序链: 每步完成后 DispatchQueue.main.asyncAfter 进入下一步,
/// 让 MainActor continuation 有机会执行(RunLoop.run(until:) 不驱动它)。
@MainActor
enum SettingsOwnershipProbe {
    static func run(container: DependencyContainer) {
        let wc = container.windowController
        let settingsController = container.settingsController
        var ok = true
        func check(_ condition: Bool, _ name: String) {
            print("SETTINGSOWNER \(name)=\(condition ? "OK" : "FAIL")")
            if !condition { ok = false }
        }
        func later(delay: TimeInterval = 0.4, _ step: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    step()
                }
            }
        }
        func anchor() -> NSPoint {
            wc.diagnosticFirstItemAnchor() ?? NSPoint(x: 735, y: 500)
        }

        // 0. 基线
        check(wc.currentInteractionSurface == .launcher, "baseline surface launcher")
        check(wc.isActuallyVisible, "launcher visible baseline")

        // 1. 打开 Settings
        later {
            wc.openSettingsFromMenu()
            check(wc.currentInteractionSurface == .settings, "surface settings after open")
            check(settingsController.window?.isVisible == true, "settings window visible")

            // 2. 三指 blocked
            check(wc.threeFingerDragBegin() == false, "three-finger blocked while settings")

            // 3. 根拖拽 blocked; 无 overlay / 无隐藏源
            check(wc.diagnosticBeginRootDrag(at: anchor()) == false, "root drag blocked while settings")
            check(wc.hasActiveDrag() == false, "no active drag while settings")
            check(wc.diagnosticHasHiddenDragSource() == false, "no hidden source while settings")
            check(wc.diagnosticHasDragOverlay() == false, "no overlay while settings")

            // 4. 空白点击只关设置
            let wasVisible = wc.isActuallyVisible
            wc.diagnosticRequestSettingsClose()
            later {
                wc.diagnosticShieldMouseUp()
                check(settingsController.window?.isVisible == false, "settings closed on outside click")
                check(wc.isActuallyVisible == wasVisible, "launcher remains visible")
                check(wc.currentInteractionSurface == .launcher, "surface restored after close")
                check(wc.hasActiveDrag() == false, "no drag after outside click")

                // 5. 活动拖拽 → 打开 Settings → 取消清理
                check(wc.diagnosticBeginRootDrag(at: anchor()), "root drag starts in launcher")
                check(wc.hasActiveDrag(), "drag active before settings open")
                wc.openSettingsFromMenu()
                check(wc.currentInteractionSurface == .settings, "surface settings after open during drag")
                check(wc.hasActiveDrag() == false, "drag cancelled on settings open")
                check(wc.diagnosticHasHiddenDragSource() == false, "source restored after cancel")
                check(wc.diagnosticHasDragOverlay() == false, "overlay removed after cancel")
                wc.diagnosticRequestSettingsClose()
                later {
                    wc.diagnosticShieldMouseUp()
                    check(wc.currentInteractionSurface == .launcher, "surface restored after close 2")

                    // 6. 关闭后根拖拽仍可用
                    check(wc.diagnosticBeginRootDrag(at: anchor()), "root drag works after settings close")
                    wc.dragTestEnd(at: anchor())
                    pollForIdle()
                }
            }
        }

        func pollForIdle() {
            if wc.hasActiveDrag() {
                later(delay: 0.1) { pollForIdle() }
            } else {
                check(wc.hasActiveDrag() == false, "drag ended cleanly")
                DiagnosticRunner.finishProbe(
                    "SETTINGSOWNER",
                    ok: ok,
                    detail: "surface=\(wc.currentInteractionSurface)"
                )
            }
        }
    }
}
