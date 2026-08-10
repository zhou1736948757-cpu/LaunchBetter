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
        report("p0")
        step { _ = controller.pageTestGoTo(1) }
        report("p1")
        step { _ = controller.pageTestGoTo(2) }
        report("p2")
        step { _ = controller.pageTestGoTo(1) }
        report("p3")
        step { _ = controller.pageTestGoTo(0) }
        report("p4")
        print("PAGETEST after: \(controller.pageTestScrollDiagnostics())")
        let sequenceOK = observedPages == [0, 1, 2, 1, 0]
        let pageWidth = controller.pageTestPageWidth()
        let pageCount = controller.pageTestPageCount()
        let documentWidth = controller.pageTestDocumentWidth()
        let expectedOffsets = [0, pageWidth, pageWidth * 2, pageWidth, 0]
        let offsetsOK = zip(observedOffsets, expectedOffsets).allSatisfy {
            abs($0.0 - $0.1) < 1
        }
        let geometryOK = pageWidth > 0 && pageCount >= 3
            && documentWidth >= pageWidth * Double(pageCount)
        let ok = controller.pageTestCurrentPage() == 0 && sequenceOK && offsetsOK && geometryOK
        // v0.1.4: 重开面板回到第一页
        _ = controller.pageTestGoTo(2)
        step {}
        let reset = controller.pageTestHideShowReset()
        step {}
        print("PAGETEST hideShowReset=\(reset ? "OK" : "FAIL") page=\(controller.pageTestCurrentPage())")
        let passed = ok && reset
        print("PAGETEST \(passed ? "OK" : "FAIL") sequence=\(observedPages)")
        DiagnosticRunner.terminateDiagnostic(success: passed)
    }
}
