import AppKit
import LaunchCore
import LaunchUI

/// PAGETEST: 翻页 0→1→2→1→0 序列 + 几何 + hide/show 复位验证。
@MainActor
enum PageTestProbe {
    static func run(container: DependencyContainer) {
        let controller = container.windowController
        // 翻页为动画(0.35s), 每步等待动画完成再读数
        func step(_ action: () -> Void) {
            action()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        // Stage 1 §36: 0→1→2→1→0 序列 + 诊断字段
        var observedPages: [Int] = []
        var observedOffsets: [Double] = []
        func report(_ label: String) {
            let scrollX = controller.pageTestScrollX()
            let page = controller.pageTestCurrentPage()
            observedPages.append(page)
            observedOffsets.append(scrollX)
            let count = controller.pageTestPageCount()
            let pageW = controller.pageTestPageWidth()
            let docW = controller.pageTestDocumentWidth()
            print("PAGETEST \(label) scrollX=\(Int(scrollX)) currentPage=\(page) pageCount=\(count) pageWidth=\(Int(pageW)) documentWidth=\(Int(docW))")
        }
        print("PAGETEST before: \(controller.pageTestScrollDiagnostics())")
        // 序列自适应页数(用户网格设置可变, 如 6×8=48 → 2 页): 0→1→(若≥3页→2)→1→0
        let pageCount = controller.pageTestPageCount()
        report("p0")
        step { _ = controller.pageTestGoTo(1) }
        report("p1")
        if pageCount >= 3 {
            step { _ = controller.pageTestGoTo(2) }
            report("p2")
            step { _ = controller.pageTestGoTo(1) }
            report("p3")
        }
        step { _ = controller.pageTestGoTo(0) }
        report("p4")
        print("PAGETEST after: \(controller.pageTestScrollDiagnostics())")
        let lastVisited = pageCount >= 3 ? 2 : 1
        let sequenceOK = observedPages.first == 0 && observedPages.last == 0
            && observedPages.max() == lastVisited && observedPages.contains(1)
        let pageWidth = controller.pageTestPageWidth()
        let expectedOffsets = pageCount >= 3
            ? [0, pageWidth, pageWidth * 2, pageWidth, 0]
            : [0, pageWidth, 0]
        let offsetsOK = zip(observedOffsets, expectedOffsets).allSatisfy {
            abs($0.0 - $0.1) < 1
        }
        let documentWidth = controller.pageTestDocumentWidth()
        let geometryOK = pageWidth > 0 && pageCount >= 2
            && documentWidth >= pageWidth * Double(pageCount)
        let ok = controller.pageTestCurrentPage() == 0 && sequenceOK && offsetsOK && geometryOK
        // v0.1.4: 重开面板回到第一页
        _ = controller.pageTestGoTo(lastVisited)
        step {}
        let reset = controller.pageTestHideShowReset()
        step {}
        print("PAGETEST hideShowReset=\(reset ? "OK" : "FAIL") page=\(controller.pageTestCurrentPage())")
        let passed = ok && reset
        print("PAGETEST \(passed ? "OK" : "FAIL") sequence=\(observedPages)")
        DiagnosticRunner.terminateDiagnostic(success: passed)
    }
}
