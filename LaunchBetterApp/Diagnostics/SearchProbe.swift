import AppKit
import LaunchCore
import LaunchUI

/// SEARCHPROBE: 搜索溢出运行时验证(宽查询 → 全部结果可滚动访问 + 自定义名重建索引)。
@MainActor
enum SearchProbe {
    static func run(container: DependencyContainer) {
        let store = container.store
        let windowController = container.windowController
        let capacity = store.displayModel().pageCapacity
        let query = "com"
        // 搜索前截图(同壁纸基线)
        windowController.captureContentScreenshot(to: "/tmp/lb-search-before.png")
        store.searchQuery = query
        windowController.refreshGrid()
        // 等搜索布局 + 图标异步加载完成后再测量/截图
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            MainActor.assumeIsolated {
                let results = store.searchResults() ?? []
                let diag = windowController.pageTestScrollDiagnostics()
                let overflow = results.count > capacity
                print("SEARCHPROBE query=\(query) results=\(results.count) capacity=\(capacity) overflow=\(overflow)")
                print("SEARCHPROBE \(diag)")
                let realIcons = windowController.realIconCount()
                let visibleItems = windowController.visibleItemCountForDiag()
                let iconsOK = visibleItems > 0 && realIcons == visibleItems
                let searchUIOK = windowController.isSearchModeForDiag()
                    && windowController.snapshotItemCountForDiag() == results.count
                let layoutDiagnostics = windowController.runtimeLayoutDiagnostics()
                let layoutOK = layoutDiagnostics?.searchMode == true
                    && layoutDiagnostics?.isValid == true
                print("SEARCHPROBE realIcons=\(realIcons)/\(visibleItems)")
                print("SEARCHPROBE uiMode=\(searchUIOK) snapshotItems=\(windowController.snapshotItemCountForDiag())")
                if let layoutDiagnostics {
                    print("SEARCHPROBE searchRect=\(layoutDiagnostics.searchRectInContent)")
                    print("SEARCHPROBE firstRowRect=\(layoutDiagnostics.firstRowRectInContent)")
                    print("SEARCHPROBE searchGridGap=\(layoutDiagnostics.actualSearchGridGap) overlap=\(layoutDiagnostics.searchGridOverlap)")
                } else {
                    print("SEARCHPROBE layout=FAIL missing runtime frames")
                }
                if let screenshotPath = CommandLine.arguments.last, !screenshotPath.hasPrefix("--") {
                    windowController.captureContentScreenshot(to: screenshotPath)
                }
                // §71: customDisplayName 变化应触发搜索索引重建
                let rb0 = store.searchIndexRebuildCount
                let target = store.displayModel().visibleAppIDs.first
                var customNameRebuilt = false
                if let target {
                    store.setCustomName(target, name: "SearchInvProbeName")
                    let rb1 = store.searchIndexRebuildCount
                    store.setCustomName(target, name: nil)
                    let delta = rb1 - rb0
                    customNameRebuilt = delta > 0
                    print("SEARCHPROBE searchRebuildOnCustomName=\(delta > 0 ? "OK (+\(delta))" : "FAIL (0)")")
                }
                store.searchQuery = ""
                windowController.refreshGrid()
                let restored = store.searchResults() == nil
                let restoredUI = !windowController.isSearchModeForDiag()
                print("SEARCHPROBE restored search=\(restored) ui=\(restoredUI)")
                let ok = overflow && iconsOK && searchUIOK && layoutOK
                    && customNameRebuilt && restored && restoredUI
                DiagnosticRunner.finishProbe("SEARCHPROBE", ok: ok, detail: "overflow=\(overflow) icons=\(iconsOK) ui=\(searchUIOK) layout=\(layoutOK) customName=\(customNameRebuilt) restored=\(restored && restoredUI)")
            }
        }
    }
}
