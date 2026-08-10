import AppKit
import LaunchCore
import LaunchUI

/// DRAGCACHE probe: 同 destination 停留 20/50 帧, preview/transform 写应≈1(v0.1.6 §69)。
@MainActor
enum DragProbe {
    static func run(container: DependencyContainer) {
        let controller = container.windowController
        guard let first = controller.dragTestItems().first else {
            DiagnosticRunner.finishProbe("DRAGCACHE", ok: false, detail: "empty drag-test items")
        }
        guard let p = controller.dragCacheProbePoint() else {
            DiagnosticRunner.finishProbe("DRAGCACHE", ok: false, detail: "no deterministic empty gap")
        }
        controller.dragTestBegin(item: first, at: p)
        guard controller.hasActiveDrag() else {
            DiagnosticRunner.finishProbe("DRAGCACHE", ok: false, detail: "drag begin rejected")
        }
        // 停留同一位置 20 帧(手动驱动, 无 display link 环境)
        for _ in 0..<20 {
            controller.dragProbeTick(p)
        }
        let c1 = controller.dragCacheDiagnostics()
        // 再停留 30 帧
        for _ in 0..<30 {
            controller.dragProbeTick(p)
        }
        let c2 = controller.dragCacheDiagnostics()
        print("DRAGCACHE after20: \(c1)")
        print("DRAGCACHE after50: \(c2)")
        let exercised = ["previews", "transformWrites"].allSatisfy { key in
            (DiagnosticRunner.diagnosticCounter(key, in: c1) ?? 0) > 0
        }
        let stable = ["previews", "transformWrites"].allSatisfy { key in
            guard let before = DiagnosticRunner.diagnosticCounter(key, in: c1),
                  let after = DiagnosticRunner.diagnosticCounter(key, in: c2) else {
                return false
            }
            return before == after
        }
        controller.dragTestEnd(at: p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated {
                let ok = exercised && stable && !controller.hasActiveDrag()
                DiagnosticRunner.finishProbe("DRAGCACHE", ok: ok, detail: "exercised=\(exercised) stableCounters=\(stable) activeDrag=\(controller.hasActiveDrag())")
            }
        }
    }
}
