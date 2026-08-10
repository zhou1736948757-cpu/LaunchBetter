import AppKit

/// 布局诊断: 打印可用内容区保留量 / 设置按钮 / 搜索栏 / 网格首排坐标(验证不重叠)。
enum LayoutProbe {
    static func run(container: DependencyContainer) {
        MainActor.assumeIsolated {
            let wc = container.windowController
            print("LAYOUT contentRect=\(wc.contentInsetsDiagnostics())")
            print("LAYOUT settingsButton=\(wc.settingsButtonFrameDiagnostics())")
            print("LAYOUT searchField=\(wc.searchFieldFrameDiagnostics())")
            print("LAYOUT gridFirstRowTop=\(wc.gridFirstRowTopDiagnostics())")
            print("LAYOUT OK")
            exit(0)
        }
    }
}
