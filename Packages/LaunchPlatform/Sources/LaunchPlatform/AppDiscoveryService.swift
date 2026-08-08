import Foundation
import LaunchCore

/// 应用发现: 枚举应用源目录中的 .app bundle,提取元数据。
///
/// 约束:
/// - 只枚举源目录顶层(不递归进 bundle 内部)
/// - 不调用 NSWorkspace.icon(图标提取集中到 AppIconProvider, Phase 4)
/// - 不可读 Info.plist 的 .app 目录跳过(无法可靠建立身份)
/// - 纯同步函数,由 AppCatalogActor 在后台执行器调用,不阻塞 actor
public enum AppDiscoveryService {
    /// 默认应用源目录。
    ///
    /// 排除 /System/Applications(系统应用, 46 个, 用户一般不需要在自定义启动器中
    /// 显示; 文档 §69 将其列为低优先级)。需要时可经自定义源加入。
    public static var defaultSources: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// 枚举源目录中的全部应用并提取记录。
    /// 不存在的源目录跳过;忽略隐藏项与非 .app 目录。
    public static func discover(sources: [URL]) -> [AppRecord] {
        var records: [AppRecord] = []
        for source in sources {
            records.append(contentsOf: discover(in: source))
        }
        return records
    }

    private static func discover(in source: URL) -> [AppRecord] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return children.compactMap { child in
            guard child.pathExtension == "app" else { return nil }
            return makeRecord(from: child)
        }
    }

    /// 从 .app bundle 目录构建 AppRecord;无法读取 Info.plist 时返回 nil。
    public static func makeRecord(from url: URL) -> AppRecord? {
        let infoURL = url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else {
            return nil
        }
        let plistDate = (try? infoURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate)

        let canonicalURL = URL(fileURLWithPath: PathCanonicalizer.canonicalPath(from: url))
        let appID = PathCanonicalizer.canonicalAppID(from: url)

        let bundleIdentifier = plist["CFBundleIdentifier"] as? String
        let displayName = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        // 图标内容版本: 真实内容信号(图标资源/Assets.car/Info.plist + 版本)
        let iconVersion = IconContentVersionFactory.make(
            appURL: url,
            infoPlist: plist,
            infoPlistDate: plistDate
        )

        return AppRecord(
            id: appID,
            url: canonicalURL,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            infoPlistModificationDate: plistDate,
            iconContentVersion: iconVersion
        )
    }
}
