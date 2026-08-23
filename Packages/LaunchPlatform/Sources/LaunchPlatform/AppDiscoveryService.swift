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
    /// `knownRecords` 提供上次扫描的记录: 仅当 Info.plist 未变时复用其本地化名
    /// (跳过 lproj/InfoPlist.strings 重读), 其余字段仍实时计算。
    public static func discover(sources: [URL], knownRecords: [AppID: AppRecord] = [:]) -> [AppRecord] {
        var records: [AppRecord] = []
        for source in sources {
            records.append(contentsOf: discover(in: source, knownRecords: knownRecords))
        }
        return records
    }

    private static func discover(in source: URL, knownRecords: [AppID: AppRecord] = [:]) -> [AppRecord] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return children.compactMap { child in
            guard child.pathExtension == "app" else { return nil }
            let appID = PathCanonicalizer.canonicalAppID(from: child)
            return makeRecord(from: child, previousRecord: knownRecords[appID])
        }
    }

    /// 从 .app bundle 目录构建 AppRecord;无法读取 Info.plist 时返回 nil。
    /// `previousRecord` 非 nil 且其 `infoPlistModificationDate` 与本次 Info.plist
    /// 修改时间一致时, 直接复用其 `localizedNames`(跳过 lproj 遍历与
    /// InfoPlist.strings 的 Data 读取)。其余字段(displayName/bundleIdentifier/
    /// categoryIdentifier/iconContentVersion)仍从本次读取的 plist 实时计算。
    /// 极少数"只改 lproj 不改 plist"的更新会等到下次 plist 变化才刷新, 可接受
    /// (下一次 app 更新必然带 plist 变化)。
    public static func makeRecord(from url: URL, previousRecord: AppRecord? = nil) -> AppRecord? {
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

        // 本地化名: 仅当 plist 未变时复用 previousRecord 的缓存, 否则重扫 lproj。
        // F7: 必须解包 previousDate —— 两个 nil 相等是误复用(旧记录缺日期信号时
        // 不得跳过重扫, 否则 localizations 更新永远不会被读取)。
        let localizedDisplayNames: [String: String]
        if let previousRecord,
           let previousDate = previousRecord.infoPlistModificationDate,
           previousDate == plistDate {
            localizedDisplayNames = previousRecord.localizedNames
        } else {
            localizedDisplayNames = Self.localizedDisplayNames(from: url)
        }

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
            localizedNames: localizedDisplayNames,
            categoryIdentifier: categoryIdentifier(from: plist)
        )
    }

    /// 从 Info.plist 读取 `LSApplicationCategoryType`;缺失或空字符串视为未知分类(nil)。
    /// 与其它元数据同属 catalog 扫描 IO,不新增 Library/show 读取路径。
    static func categoryIdentifier(from plist: [String: Any]) -> String? {
        guard let raw = plist["LSApplicationCategoryType"] as? String else { return nil }
        return raw.isEmpty ? nil : raw
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
