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
    /// 含 /System/Applications(用户要求显示系统应用; 其变更极少, §69 视为低优先级)。
    public static var defaultSources: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
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
            iconContentVersion: iconVersion,
            localizedNames: localizedDisplayNames(from: url)
        )
    }

    /// 从 bundle 的 `Contents/Resources/*.lproj/InfoPlist.strings` 提取各本地化显示名。
    ///
    /// 键为 .lproj 目录名(如 "en" / "zh-Hans");每个本地化内按 macOS 语义
    /// CFBundleDisplayName → CFBundleName 回退。无 / 畸形 strings 的本地化跳过。
    /// 纯 catalog 元数据工作,非 per-launcher-show 路径。
    static func localizedDisplayNames(from url: URL) -> [String: String] {
        let resourcesDir = url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        guard let lprojDirs = try? FileManager.default.contentsOfDirectory(
            at: resourcesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        var result: [String: String] = [:]
        for dir in lprojDirs where dir.pathExtension == "lproj" {
            let localization = dir.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("InfoPlist.strings")),
                  let strings = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil
                  ) as? [String: Any] else {
                continue
            }
            let name = (strings["CFBundleDisplayName"] as? String)
                ?? (strings["CFBundleName"] as? String)
            if let name, !name.isEmpty {
                result[localization] = name
            }
        }
        return result
    }
}
