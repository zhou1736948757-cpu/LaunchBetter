import AppKit

/// 热角诊断探针: 打印配置 + monitor 状态 + 当前鼠标所在角。
enum HotCornerProbe {
    static func run(container: DependencyContainer) {
        print("HOTCORNER \(MainActor.assumeIsolated { container.activationCoordinator.hotCornerDiagnostics() })")
        print("HOTCORNER OK")
        exit(0)
    }
}
