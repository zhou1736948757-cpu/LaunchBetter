import Foundation
import LaunchCore

/// 图标内容版本工厂: 从真实稳定内容信号构建 IconContentVersion。
///
/// 信号优先级(§74):
/// 1. 图标资源文件(CFBundleIconFile / CFBundleIconName 定位)的高精度 mtime + 大小
/// 2. Assets.car(现代应用图标资产)的 mtime + 大小
/// 3. 回退: Info.plist mtime + CFBundleVersion
///
/// 要求: 未变化内容 → 不变版本;禁止用 reconcile 代数/扫描代数。
public enum IconContentVersionFactory {
    /// 从应用 bundle 目录与已读取的 Info.plist 构建内容版本。
    public static func make(
        appURL: URL,
        infoPlist: [String: Any],
        infoPlistDate: Date?
    ) -> IconContentVersion {
        let resourcesURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)

        // 1. 图标资源文件
        let iconFile = iconResourceName(from: infoPlist)
        if let iconURL = iconFile.flatMap({
            locateIconResource(named: $0, in: resourcesURL)
        }), let date = modificationNanoseconds(of: iconURL), let size = fileSizeBytes(of: iconURL) {
            return IconContentVersion(
                iconResourceModificationNanoseconds: date,
                iconResourceSizeBytes: size,
                infoPlistModificationNanoseconds: infoPlistDate.map {
                    UInt64($0.timeIntervalSince1970 * 1_000_000_000)
                },
                bundleVersion: infoPlist["CFBundleVersion"] as? String
            )
        }

        // 2. Assets.car
        let assetsURL = resourcesURL.appendingPathComponent("Assets.car")
        if let date = modificationNanoseconds(of: assetsURL), let size = fileSizeBytes(of: assetsURL) {
            return IconContentVersion(
                iconResourceModificationNanoseconds: date,
                iconResourceSizeBytes: size,
                infoPlistModificationNanoseconds: infoPlistDate.map {
                    UInt64($0.timeIntervalSince1970 * 1_000_000_000)
                },
                bundleVersion: infoPlist["CFBundleVersion"] as? String
            )
        }

        // 3. 回退: Info.plist mtime + 版本
        return IconContentVersion(
            iconResourceModificationNanoseconds: nil,
            iconResourceSizeBytes: nil,
            infoPlistModificationNanoseconds: infoPlistDate.map {
                UInt64($0.timeIntervalSince1970 * 1_000_000_000)
            },
            bundleVersion: infoPlist["CFBundleVersion"] as? String
        )
    }

    private static func iconResourceName(from infoPlist: [String: Any]) -> String? {
        if let name = infoPlist["CFBundleIconFile"] as? String {
            return name
        }
        if let name = infoPlist["CFBundleIconName"] as? String {
            return name
        }
        return nil
    }

    private static func locateIconResource(named name: String, in resourcesURL: URL) -> URL? {
        let candidates = [name, "\(name).icns"]
        for candidate in candidates {
            let url = resourcesURL.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func modificationNanoseconds(of url: URL) -> UInt64? {
        guard let date = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate else {
            return nil
        }
        return UInt64(date.timeIntervalSince1970 * 1_000_000_000)
    }

    private static func fileSizeBytes(of url: URL) -> UInt64? {
        guard let size = try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize else {
            return nil
        }
        return UInt64(size)
    }
}
