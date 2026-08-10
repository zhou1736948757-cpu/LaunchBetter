import AppKit
import LaunchCore
import LaunchUI

/// PAGINGPROBE: 合成触控板 swipe + momentum, 测量计数器(v0.1.6 §63/§82)。
@MainActor
enum PagingProbe {
    static func run(container: DependencyContainer) {
        let controller = container.windowController
        func makeScroll(dx: CGFloat, phase: Int, momentum: Int) -> NSEvent? {
            guard let src = CGEventSource(stateID: .hidSystemState),
                  let cg = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(dx), wheel3: 0) else { return nil }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
            // 相位经 rawValue 设置(kCGScrollWheelEventPhase=99 / MomentumPhase=123)
            cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: Int64(phase))
            cg.setIntegerValueField(CGEventField(rawValue: 123)!, value: Int64(momentum))
            return NSEvent(cgEvent: cg)
        }
        print("PAGINGPROBE before: \(controller.pagingProbeDiagnostics())")
        // 1. Deterministically feed the same normalized precise deltas that the
        // NSEvent adapter supplies. Synthetic CGEvent phase/timestamp conversion
        // varies across SDKs and previously made this probe test the fixture.
        controller.pagingProbeGesture(
            deltaXs: Array(repeating: -60, count: 4)
                + Array(repeating: -55, count: 4)
        )
        // 2. momentum 序列(应 0 位移 0 snap)
        let beforeMomentum = controller.pagingProbeDiagnostics()
        guard let momentumBegan = makeScroll(dx: -80, phase: 0, momentum: 1),
              let momentumChanged = makeScroll(dx: -80, phase: 0, momentum: 2),
              let momentumEnded = makeScroll(dx: 0, phase: 0, momentum: 3) else {
            DiagnosticRunner.finishProbe("PAGINGPROBE", ok: false, detail: "failed to create synthetic momentum events")
        }
        controller.pagingProbeFeed(momentumBegan)
        controller.pagingProbeFeed(momentumChanged)
        controller.pagingProbeFeed(momentumEnded)
        let afterMomentum = controller.pagingProbeDiagnostics()
        let momentumIgnored = ["input", "scroll", "settles"].allSatisfy { key in
            DiagnosticRunner.diagnosticCounter(key, in: beforeMomentum)
                == DiagnosticRunner.diagnosticCounter(key, in: afterMomentum)
        }
        // A command-line diagnostic process may receive no NSView display-link
        // callbacks. Drive the exact same frame body against wall-clock time and
        // still require the animator to settle at the real document offset.
        var remainingFrames = 240
        @MainActor func advanceProbeFrame() {
            let settled = controller.pagingProbeDisplayFrame()
            remainingFrames -= 1
            if settled || remainingFrames == 0 {
                let page = controller.pageTestCurrentPage()
                print("PAGINGPROBE after: \(controller.pagingProbeDiagnostics()) page=\(page) scrollX=\(Int(controller.pageTestScrollX())) settled=\(settled)")
                let ok = momentumIgnored && settled && page == 1
                    && controller.pageTestScrollX() > 1400
                print("PAGINGPROBE \(ok ? "OK" : "FAIL")")
                DiagnosticRunner.terminateDiagnostic(success: ok)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) {
                MainActor.assumeIsolated {
                    advanceProbeFrame()
                }
            }
        }
        advanceProbeFrame()
    }
}
