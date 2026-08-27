import AppKit
import Foundation
import LaunchCore
import LaunchPlatform
import LaunchUI

/// SOURCESPROBE: 自定义源目录端到端验证(Stage B §B2)。
/// 设置保存(持久化) → monitor 重配 → catalog 增量重扫新增源 → UI 发布;
/// 移除源 → 对账消失。验证完整接线(非仅 actor 单元逻辑)。
@MainActor
enum SourcesProbe {
    static func run(container: DependencyContainer) {
        let store = container.store
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchBetter-SourcesProbe-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = root.appendingPathComponent("CustomApps", isDirectory: true)
        let appURL = sourceDir.appendingPathComponent("SourceProbeApp.app")
        do {
            try FileManager.default.createDirectory(
                at: appURL.appendingPathComponent("Contents", isDirectory: true),
                withIntermediateDirectories: true
            )
            let plist: [String: Any] = [
                "CFBundleIdentifier": "dev.launchbetter.probe.SourceProbeApp",
                "CFBundleName": "SourceProbeApp",
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        } catch {
            DiagnosticRunner.finishProbe("SOURCESPROBE", ok: false, detail: "fixture failed \(error)")
        }
        let probeID = PathCanonicalizer.canonicalAppID(from: appURL)

        let original = store.config
        var added = original
        if !added.customSourceDirectories.contains(sourceDir.path) {
            added.customSourceDirectories.append(sourceDir.path)
        }
        store.save(added)

        poll(until: { store.allApps.contains { $0.name == "SourceProbeApp" } }) { appeared in
            guard appeared else {
                store.save(original)
                try? FileManager.default.removeItem(at: root)
                DiagnosticRunner.finishProbe("SOURCESPROBE", ok: false, detail: "app did not appear after adding source")
            }
            // 搜索可达(T-025: query 归 UI 层, 经窗口控制器诊断 seam 写入)
            container.windowController.diagnosticSetSearchQuery("sourceprobe")
            let searchable = (store.searchResults(for: "sourceprobe") ?? []).contains { item in
                if case .app(let id) = item { return id == probeID }
                return false
            }
            container.windowController.diagnosticSetSearchQuery("")
            // 移除源 → 消失
            store.save(original)
            poll(until: { !store.allApps.contains { $0.name == "SourceProbeApp" } }) { disappeared in
                let ok = appeared && searchable && disappeared
                print("SOURCESPROBE appeared=\(appeared) searchable=\(searchable) disappeared=\(disappeared)")
                try? FileManager.default.removeItem(at: root)
                DiagnosticRunner.finishProbe(
                    "SOURCESPROBE",
                    ok: ok,
                    detail: "appeared=\(appeared) searchable=\(searchable) disappeared=\(disappeared)"
                )
            }
        }
    }

    /// 有界轮询(避免探针挂起), MainActor 上等待条件。
    private static func poll(
        until condition: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 12.0,
        interval: TimeInterval = 0.2,
        then completion: @escaping @MainActor (Bool) -> Void
    ) {
        var elapsed: TimeInterval = 0
        func attempt() {
            if condition() {
                completion(true)
                return
            }
            elapsed += interval
            if elapsed >= timeout {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                MainActor.assumeIsolated { attempt() }
            }
        }
        attempt()
    }
}
