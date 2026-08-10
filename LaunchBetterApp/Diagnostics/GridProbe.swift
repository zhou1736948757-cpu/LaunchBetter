import AppKit
import LaunchCore
import LaunchUI

/// GRIDTEST: Settings 几何生效验证(改 columns/rows/iconSize → 布局/容量/图标请求尺寸跟随)。
@MainActor
enum GridProbe {
    static func run(container: DependencyContainer) {
        let store = container.store
        let windowController = container.windowController
        let rebuildBefore = store.searchIndexRebuildCount
        let original = store.config
        var test = original
        // 可选参数: --gridtest [columns] [rows] [iconSize] [截图路径]
        let args = CommandLine.arguments
        let base = args.firstIndex(of: "--gridtest") ?? args.endIndex
        func intArg(_ offset: Int, default d: Int) -> Int {
            let idx = base + offset
            return (args.indices.contains(idx) ? Int(args[idx]) : nil) ?? d
        }
        let gColumns = intArg(1, default: 8)
        let gRows = intArg(2, default: 5)
        let gIconSize = intArg(3, default: 48)
        test.gridColumns = gColumns
        test.gridRows = gRows
        test.iconSize = gIconSize
        store.save(test)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            MainActor.assumeIsolated {
                windowController.refreshGrid()
                let display = store.displayModel()
                let diag = windowController.pageTestScrollDiagnostics()
                let applied = store.config.gridColumns == gColumns
                    && store.config.gridRows == gRows
                    && store.config.iconSize == gIconSize
                    && display.pageCapacity == gColumns * gRows
                print("GRIDTEST columns=\(gColumns) rows=\(gRows) iconSize=\(gIconSize) pages=\(display.pages.count) capacity=\(display.pageCapacity) iconSize=\(store.iconSize)")
                print("GRIDTEST \(diag)")
                if let screenshotPath = CommandLine.arguments.last, !screenshotPath.hasPrefix("--") {
                    windowController.captureContentScreenshot(to: screenshotPath)
                }
                store.save(original)
                windowController.refreshGrid()
                let restored = store.config.gridColumns == original.gridColumns
                    && store.config.gridRows == original.gridRows
                    && store.config.iconSize == original.iconSize
                let searchRebuildDelta = store.searchIndexRebuildCount - rebuildBefore
                print("GRIDTEST restored columns=\(store.config.gridColumns) rows=\(store.config.gridRows) iconSize=\(store.config.iconSize)")
                print("GRIDTEST searchRebuildDelta=\(searchRebuildDelta) (期望 0: UI-only config 不重建搜索索引, §71)")
                DiagnosticRunner.finishProbe(
                    "GRIDTEST",
                    ok: applied && restored && searchRebuildDelta == 0,
                    detail: "applied=\(applied) restored=\(restored) searchRebuildDelta=\(searchRebuildDelta)"
                )
            }
        }
    }
}
