import AppKit
import LaunchCore
import LaunchUI

/// SMOKE probe: 冒烟诊断 + --dragtest / --folders 子模式。
@MainActor
enum SmokeProbe {
    static func run(container: DependencyContainer) {
        let store = container.store
        let windowController = container.windowController
        let display = store.displayModel()
        print("SMOKE catalogApps=\(store.diagnosticCatalogAppCount())")
        print("SMOKE layoutPages=\(display.pages.count) flatSlots=\(display.flatSlots.count) capacity=\(display.pageCapacity)")

        // T-025: query 归 UI 层, 经窗口控制器诊断 seam 写入
        windowController.diagnosticSetSearchQuery("chrome")
        let results = store.searchResults(for: "chrome") ?? []
        print("SMOKE searchQuery=chrome results=\(results.count)")
        windowController.diagnosticSetSearchQuery("")

        print("SMOKE window [\(windowController.diagnostics())]")
        let baseOK = store.diagnosticCatalogAppCount() > 0
            && !display.pages.isEmpty
            && !display.flatSlots.isEmpty
            && display.pageCapacity > 0
            && windowController.isActuallyVisible
        guard baseOK else {
            DiagnosticRunner.finishSmoke(store: store, ok: false, detail: "invalid catalog/layout/capacity/window baseline")
        }

        // 拖拽引擎: 程序化驱动 beginDrag → updateDrag ×N → endDrag(真实代码路径)
        if CommandLine.arguments.contains("--dragtest") {
            runDragTest(store: store, windowController: windowController)
            return
        }

        if CommandLine.arguments.contains("--folders") {
            FolderProbe.run(store: store, display: display)
            return
        }

        DiagnosticRunner.finishSmoke(store: store)
    }

    private static func runDragTest(store: LauncherStore, windowController: LauncherWindowController) {
        let items = windowController.dragTestItems()
        guard let first = items.first else {
            DiagnosticRunner.finishSmoke(store: store, ok: false, detail: "dragtest has no visible items")
        }
        let orderBefore = store.displayModel().flatSlots
        guard Set(orderBefore).count == orderBefore.count else {
            DiagnosticRunner.finishSmoke(store: store, ok: false, detail: "dragtest baseline contains duplicate display items")
        }
        let previousOnDataChange = store.onDataChange
        var completed = false
        var verificationScheduled = false
        func finishDrag(_ ok: Bool, detail: String) {
            guard !completed else { return }
            completed = true
            store.onDataChange = previousOnDataChange
            print("SMOKE dragtest \(ok ? "OK" : "FAIL") \(detail)")
            DiagnosticRunner.finishSmoke(store: store, ok: ok, detail: detail)
        }
        store.onDataChange = { [weak store] in
            previousOnDataChange?()
            guard let store, !completed else { return }
            let orderAfter = store.displayModel().flatSlots
            guard orderAfter != orderBefore else { return }
            let unique = Set(orderAfter).count == orderAfter.count
            guard !verificationScheduled else { return }
            verificationScheduled = true
            // Committed layout publication precedes the completion callback that
            // tears down the overlay. Verify after that callback has run.
            DispatchQueue.main.async {
                let activeDrag = windowController.hasActiveDrag()
                finishDrag(
                    unique && !activeDrag,
                    detail: "changed=true unique=\(unique) activeDrag=\(activeDrag) items=\(orderAfter.count)"
                )
            }
        }
        // 目标点: 窗口中心偏右(模拟拖到末尾)
        let targetPoint = NSPoint(x: 900, y: 400)
        windowController.dragTestBegin(item: first, at: targetPoint)
        guard windowController.hasActiveDrag() else {
            finishDrag(false, detail: "drag begin rejected")
            return
        }
        var lastPoint = targetPoint
        for i in 0..<20 {
            lastPoint = NSPoint(x: 700 + CGFloat(i) * 15, y: 400)
            windowController.dragTestUpdate(at: lastPoint)
            windowController.dragProbeTick(lastPoint)
        }
        windowController.dragTestEnd(at: lastPoint)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            MainActor.assumeIsolated {
                guard !completed else { return }
                finishDrag(false, detail: "timeout waiting for a changed, unique layout")
            }
        }
    }
}
