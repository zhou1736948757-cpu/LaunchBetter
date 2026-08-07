import Foundation

/// 布局对账(纯逻辑,无文件系统访问)。
///
/// 输入: Catalog + Layout;输出: 更新后的 Layout。
/// 规则(确定性):
/// - 新应用: 追加到最后一页末尾(按 AppID 排序,确定性)
/// - 缺失应用: 创建/保留墓碑,布局引用保留(显示层隐藏)
/// - 应用回归: 清除墓碑,恢复原位置(引用本就在布局中)
/// - 过期墓碑(超宽限期): 从页面与文件夹子项移除
/// - 孤儿文件夹项: 从页面移除
/// - 空文件夹: 确定性解散
public enum LayoutReconciler {
    public static let defaultGracePeriod: TimeInterval = 30 * 24 * 60 * 60

    public static func reconcile(
        catalog: CatalogSnapshot,
        layout: LayoutSnapshot,
        now: Date,
        gracePeriod: TimeInterval = LayoutReconciler.defaultGracePeriod
    ) -> LayoutSnapshot {
        var pages = layout.pages
        var folders = layout.folders
        var missing = layout.missingApps

        let catalogIDs = Set(catalog.apps.map(\.id))

        // 移除孤儿文件夹项(引用了不存在的 FolderID)
        var cleanedPages: [[LayoutItem]] = []
        for page in pages {
            let cleaned = page.filter { item in
                switch item {
                case .app:
                    return true
                case .folder(let id):
                    return folders[id] != nil
                }
            }
            if !cleaned.isEmpty {
                cleanedPages.append(cleaned)
            }
        }
        pages = cleanedPages

        let referenced = LayoutSnapshot(
            pages: pages,
            folders: folders
        ).referencedAppIDs

        // 新应用: 在 Catalog 中、布局未引用 → 追加到最后一页(按 AppID 排序,确定性)
        // 若存在无引用的墓碑(罕见: 引用已被手动移除),清除墓碑并重新加入。
        let newApps = catalog.apps
            .filter { !referenced.contains($0.id) }
            .map(\.id)
        if !newApps.isEmpty {
            for id in newApps {
                missing.removeValue(forKey: id)
            }
            if pages.isEmpty {
                pages = [[]]
            }
            pages[pages.count - 1].append(contentsOf: newApps.map(LayoutItem.app))
        }

        // 缺失应用: 布局引用但不在 Catalog → 保留布局引用,创建/保留墓碑
        let missingIDs = referenced.subtracting(catalogIDs)
        for id in missingIDs.sorted(by: { $0.rawValue < $1.rawValue }) {
            if missing[id] == nil {
                missing[id] = MissingAppState(missingSince: now)
            }
        }

        // 应用回归: 在 Catalog 且存在墓碑 → 清除墓碑(布局引用从未移除,位置自然恢复)
        for id in missing.keys.sorted(by: { $0.rawValue < $1.rawValue })
        where catalogIDs.contains(id) {
            missing.removeValue(forKey: id)
        }

        // 过期墓碑: 从页面与文件夹子项移除,清除墓碑
        let expiredIDs = missing
            .filter { $0.value.missingSince.addingTimeInterval(gracePeriod) <= now }
            .map(\.key)
        if !expiredIDs.isEmpty {
            let expiredSet = Set(expiredIDs)
            pages = pages.compactMap { page in
                let cleaned = page.filter { item in
                    switch item {
                    case .app(let id):
                        return !expiredSet.contains(id)
                    case .folder:
                        return true
                    }
                }
                return cleaned.isEmpty ? nil : cleaned
            }
            for (folderID, var folder) in folders {
                let before = folder.children.count
                folder.children.removeAll { expiredSet.contains($0) }
                if folder.children.count != before {
                    folders[folderID] = folder
                }
            }
            for id in expiredIDs {
                missing.removeValue(forKey: id)
            }
        }

        // 空文件夹: 确定性解散(从页面与文件夹表移除)
        let emptyFolderIDs = folders.filter { $0.value.children.isEmpty }.map(\.key)
        if !emptyFolderIDs.isEmpty {
            let emptySet = Set(emptyFolderIDs)
            pages = pages.compactMap { page in
                let cleaned = page.filter { item in
                    switch item {
                    case .app:
                        return true
                    case .folder(let id):
                        return !emptySet.contains(id)
                    }
                }
                return cleaned.isEmpty ? nil : cleaned
            }
            for id in emptyFolderIDs {
                folders.removeValue(forKey: id)
            }
        }

        return LayoutSnapshot(
            pages: pages,
            folders: folders,
            missingApps: missing
        )
    }
}
