import AppKit
import Foundation
import LaunchCore
import LaunchUI

/// PAGECOMPOSITOR: `--pagecompositor` A/B 遥测探针。
///
/// 组合器自 v0.5.0 起默认启用; 该 flag 现在只负责开启遥测
/// (`--disable-pagecompositor` 仍可强制关闭组合器)。探针做确定性场景:
/// 1. show + 导航到 Page1(物理 2)+ 等待视觉齐备。
/// 2. 事件级手势(合成 kCGScrollPhase)前移 → 断言组合器激活、clip 不动。
/// 3. 驱动帧直到 settle 收敛 → 断言 clip 精确同步 + live reveal + 无残留层。
/// 4. 输出遥测汇总(PAGECOMPOSITOR summary=...), 供与 `--pagingtelemetry`
///    基线对比(live vs compositor 帧间隔)。
@MainActor
enum PageCompositorProbe {
    static func run(container: DependencyContainer) {
        let controller = container.windowController

        // 1. 显示 + 导航到中间页。
        controller.show()
        controller.pageTestGoTo(1)
        print("PAGECOMPOSITOR shown page=\(controller.pageTestCurrentPage()) clip=\(Int(controller.pageTestScrollX()))")

        // 2. 等待视觉齐备(带超时轮询)。
        var ready = false
        for _ in 0..<50 {
            if controller.pageCompositorEligibleForDiag { ready = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if !ready {
            print("PAGECOMPOSITOR visuals not ready eligible=\(controller.pageCompositorEligibleForDiag) cache=\(controller.pageVisualCacheCountForDiag) summary=\(controller.pageCompositorMetricsSummary())")
        }

        // 3. 合成精确手势(带 phase 的 precise 滚动), 前移到下一页。
        let startClip = controller.pageTestScrollX()
        if let began = makeScroll(dx: -120), let changed1 = makeScroll(dx: -180),
           let changed2 = makeScroll(dx: -160), let ended = makeScroll(dx: 0, phaseField: 4) {
            controller.pagingProbeFeed(began)
            _ = controller.pagingProbeDisplayFrame()
            controller.pagingProbeFeed(changed1)
            _ = controller.pagingProbeDisplayFrame()
            controller.pagingProbeFeed(changed2)
            _ = controller.pagingProbeDisplayFrame()
            controller.pagingProbeFeed(ended)
            print("PAGECOMPOSITOR gesture fed active=\(controller.pageCompositorActiveForDiag) clipUnchanged=\(controller.pageTestScrollX() == startClip)")
        } else {
            DiagnosticRunner.finishProbe("PAGECOMPOSITOR", ok: false, detail: "event synthesis failed")
        }

        // 4. 驱动帧直到 settle 收敛(120Hz 节奏, 最多 3s)。
        var settled = false
        var remainingFrames = 360
        @MainActor func advanceFrame() {
            if controller.pagingProbeDisplayFrame() || controller.pagingProbePhase() == "idle" {
                settled = true
            }
            remainingFrames -= 1
            if settled || remainingFrames == 0 {
                finish(controller: controller, settled: settled, startClip: startClip)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) {
                MainActor.assumeIsolated {
                    advanceFrame()
                }
            }
        }
        advanceFrame()
    }

    @MainActor
    private static func finish(
        controller: LauncherWindowController,
        settled: Bool,
        startClip: CGFloat
    ) -> Never {
        let pageWidth = controller.pageTestPageWidth()
        let expectedClip = startClip + pageWidth
        let clipOK = abs(controller.pageTestScrollX() - expectedClip) < 1
        let released = !controller.pageCompositorActiveForDiag
            && controller.pageCompositorLayerCountForDiag == 0
        let summary = controller.pageCompositorMetricsSummary()
        print("PAGECOMPOSITOR settled=\(settled) clip=\(Int(controller.pageTestScrollX())) expected=\(Int(expectedClip)) clipOK=\(clipOK) released=\(released)")
        print("PAGECOMPOSITOR summary=\(summary)")
        let ok = settled && clipOK && released
        DiagnosticRunner.terminateDiagnostic(success: ok)
    }

    /// 合成 precise 滚动事件。phase 字段用 kCGScrollPhase 编码
    /// (1=began, 4=ended; changed 用 0 — 与 handleWheel 的 default 分支等价)。
    private static func makeScroll(dx: CGFloat, phaseField: Int = 0) -> NSEvent? {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let cg = CGEvent(
                  scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                  wheel1: 0, wheel2: Int32(dx), wheel3: 0
              ) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: Int64(phaseField))
        return NSEvent(cgEvent: cg)
    }
}
