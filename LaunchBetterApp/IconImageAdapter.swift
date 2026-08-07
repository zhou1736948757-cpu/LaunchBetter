import AppKit
import Foundation
import LaunchCore
import LaunchPlatform
import LaunchUI

/// 图标协议适配器: 把 LaunchUI 的 IconImageProviding 映射到 LaunchPlatform.IconRepository。
///
/// 从 LauncherStore 取 IconContentVersion 构建 IconKey(内容版本信号驱动缓存身份)。
@MainActor
public final class IconImageAdapter: IconImageProviding {
    private let repository: IconRepository
    private weak var store: LauncherStore?

    public init(repository: IconRepository, store: LauncherStore) {
        self.repository = repository
        self.store = store
    }

    public func icon(for appID: AppID, pointSize: Int, scale: Int) async -> CGImage? {
        guard let version = store?.iconContentVersion(for: appID) else { return nil }
        let key = IconKey(
            appID: appID,
            pointSize: pointSize,
            scale: scale,
            contentVersion: version
        )
        let image = await repository.image(for: key)
        // M2: await 后复验内容版本,防止陈旧结果应用到已更新的应用
        guard let current = store?.iconContentVersion(for: appID), current == version else {
            return nil
        }
        return image
    }

    public func trimMemoryForHidden() {
        Task { await repository.trimForHidden() }
    }

    /// 统计(诊断/基准)。
    public func diagnosticStats() async -> String {
        let stats = await repository.stats()
        return "memoryHits=\(stats.memoryHits) diskHits=\(stats.diskHits) liveResolves=\(stats.liveResolves) diskWrites=\(stats.diskWrites)"
    }

    /// 基准: 依次请求全部可见应用图标(冷/热各跑一次)。
    public func benchmarkVisibleIcons(scale: Int) async -> (
        resolved: Int, milliseconds: Double, live: Int, disk: Int, memoryHits: Int
    ) {
        guard let store else { return (0, 0, 0, 0, 0) }
        let apps = store.displayModel().visibleAppIDs
        let start = Date()
        var resolved = 0
        for appID in apps {
            let version = store.iconContentVersion(for: appID)
            let key = IconKey(appID: appID, pointSize: 96, scale: scale, contentVersion: version)
            if await repository.image(for: key) != nil {
                resolved += 1
            }
        }
        let ms = Date().timeIntervalSince(start) * 1000
        let stats = await repository.stats()
        return (resolved, ms, stats.liveResolves, stats.diskHits, stats.memoryHits)
    }
}
