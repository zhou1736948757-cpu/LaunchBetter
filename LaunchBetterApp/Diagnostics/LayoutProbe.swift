import AppKit

/// 布局诊断: 用真实 AppKit frame 验证搜索框/首排/设置按钮 invariant。
enum LayoutProbe {
    static func run(container: DependencyContainer) {
        MainActor.assumeIsolated {
            let wc = container.windowController
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?"
            print("LAYOUT binary=\(Bundle.main.bundleURL.path) version=\(version)")
            print("LAYOUT contentRect=\(wc.contentInsetsDiagnostics())")
            print("LAYOUT settingsButton=\(wc.settingsButtonFrameDiagnostics())")
            print("LAYOUT searchField=\(wc.searchFieldFrameDiagnostics())")
            print("LAYOUT gridFirstRowTop=\(wc.gridFirstRowTopDiagnostics())")
            guard let diagnostics = wc.runtimeLayoutDiagnostics() else {
                print("LAYOUT FAIL missing runtime frames")
                DiagnosticRunner.terminateDiagnostic(success: false)
            }

            print("LAYOUT searchRect=\(diagnostics.searchRectInContent)")
            print("LAYOUT firstRowRect=\(diagnostics.firstRowRectInContent)")
            print("LAYOUT firstRowDocumentRect=\(diagnostics.firstRowDocumentRect)")
            print("LAYOUT pageDotsRect=\(String(describing: diagnostics.pageDotsRectInContent))")
            print("LAYOUT settingsBounds=\(diagnostics.settingsButtonBounds)")
            print("LAYOUT settingsFrame=\(diagnostics.settingsButtonRectInContent)")
            print("LAYOUT searchGridGap=\(diagnostics.actualSearchGridGap) intended=\(diagnostics.intendedSearchGridGap)")
            print("LAYOUT overlap=\(diagnostics.searchGridOverlap)")
            print("LAYOUT flipped collection=\(diagnostics.collectionViewIsFlipped) content=\(diagnostics.contentViewIsFlipped)")

            let ok = diagnostics.isValid && diagnostics.collectionViewIsFlipped
            if !ok {
                print("LAYOUT FAIL invariant")
            } else {
                print("LAYOUT OK")
            }
            DiagnosticRunner.terminateDiagnostic(success: ok)
        }
    }
}
