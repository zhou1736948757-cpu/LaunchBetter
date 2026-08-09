import Foundation

/// 布局对账(纯逻辑,无文件系统访问)。
///
/// 输入: Catalog + Layout;输出: 更新后的 Layout。
/// 规则(确定性):
/// - 新应用: 追加到最后一页末尾(按 AppID 排序,确定性)
/// - 缺失应用: 创建/保留墓碑,布局引用保留(显示层隐藏)
/// - 应用回归: 清除墓碑,恢复原位置(引用本就在布局中)
/// - 过期墓碑(超宽限期): 从页面与文件夹子项移除
/// - 孤儿文件夹记录: 按 FolderID 排序恢复到末尾,或确定性解散
/// - 空/单应用文件夹: 确定性解散
public enum LayoutReconciler {
    public static let defaultGracePeriod: TimeInterval = 30 * 24 * 60 * 60

    /// 在目录对账前把持久化布局收敛到可安全交给显示层的形态。
    ///
    /// 页面是持久化布局的主遍历顺序;页面中首次出现的文件夹槽位及其
    /// children 先取得对应的 AppID。未被页面引用的文件夹记录按 FolderID
    /// 排序追加,因此字典遍历顺序不会影响结果。
    private static func normalize(
        layout: LayoutSnapshot,
        excluding excludedAppIDs: Set<AppID>
    ) -> LayoutSnapshot {
        var normalizedPages: [[LayoutItem]] = []
        var normalizedFolders: [FolderID: FolderRecord] = [:]
        var seenAppIDs = Set<AppID>()
        var seenFolderSlots = Set<FolderID>()
        var consumedFolderIDs = Set<FolderID>()

        func uniqueChildren(of folder: FolderRecord) -> [AppID] {
            var children: [AppID] = []
            children.reserveCapacity(folder.children.count)
            for child in folder.children {
                guard !excludedAppIDs.contains(child),
                      seenAppIDs.insert(child).inserted else {
                    continue
                }
                children.append(child)
            }
            return children
        }

        func appendAtEnd(_ item: LayoutItem) {
            if normalizedPages.isEmpty {
                normalizedPages = [[]]
            }
            normalizedPages[normalizedPages.count - 1].append(item)
        }

        for page in layout.pages {
            var normalizedPage: [LayoutItem] = []
            normalizedPage.reserveCapacity(page.count)

            for item in page {
                switch item {
                case .app(let id):
                    guard !excludedAppIDs.contains(id),
                          seenAppIDs.insert(id).inserted else {
                        continue
                    }
                    normalizedPage.append(.app(id))

                case .folder(let folderID):
                    // 同一个 FolderID 只保留首次出现的有效槽位。
                    guard seenFolderSlots.insert(folderID).inserted,
                          let folder = layout.folders[folderID] else {
                        continue
                    }
                    consumedFolderIDs.insert(folderID)

                    let children = uniqueChildren(of: folder)
                    if children.count >= 2 {
                        var normalizedFolder = folder
                        normalizedFolder.children = children
                        normalizedFolders[folderID] = normalizedFolder
                        normalizedPage.append(.folder(folderID))
                    } else if let child = children.first {
                        // 单 child 文件夹确定性解散到原槽位。
                        normalizedPage.append(.app(child))
                    }
                }
            }

            if !normalizedPage.isEmpty {
                normalizedPages.append(normalizedPage)
            }
        }

        // 页面未引用的文件夹记录不能被静默丢弃,否则其 children 会成为布局孤儿。
        // 按 rawValue 排序后追加,保证跨运行结果一致。
        let orphanFolderIDs = layout.folders.keys
            .filter { !consumedFolderIDs.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }

        for folderID in orphanFolderIDs {
            guard let folder = layout.folders[folderID] else { continue }
            let children = uniqueChildren(of: folder)

            if children.count >= 2 {
                var normalizedFolder = folder
                normalizedFolder.children = children
                normalizedFolders[folderID] = normalizedFolder
                appendAtEnd(.folder(folderID))
            } else if let child = children.first {
                appendAtEnd(.app(child))
            }
        }

        return LayoutSnapshot(
            pages: normalizedPages,
            folders: normalizedFolders,
            missingApps: layout.missingApps
        )
    }

    public static func reconcile(
        catalog: CatalogSnapshot,
        layout: LayoutSnapshot,
        now: Date,
        gracePeriod: TimeInterval = LayoutReconciler.defaultGracePeriod
    ) -> LayoutSnapshot {
        let catalogIDs = Set(catalog.apps.map(\.id))
        var missing = layout.missingApps

        // 先计算当前调用中真正会过期的墓碑,让同一归一化遍历同时移除其引用。
        // 已回归目录的 AppID 与旧逻辑一致: 不因旧墓碑过期而删除。
        let expiredIDs: Set<AppID> = Set(
            missing.compactMap { id, state in
                guard !catalogIDs.contains(id),
                      state.missingSince.addingTimeInterval(gracePeriod) <= now else {
                    return nil
                }
                return id
            }
        )

        let normalized = normalize(layout: layout, excluding: expiredIDs)
        var pages = normalized.pages

        for id in expiredIDs {
            missing.removeValue(forKey: id)
        }

        let referenced = normalized.referencedAppIDs

        // 新应用: 在 Catalog 中、布局未引用 → 追加到最后一页(按 AppID 排序,确定性)
        // 若存在无引用的墓碑(罕见: 引用已被手动移除),清除墓碑并重新加入。
        var appendedAppIDs = Set<AppID>()
        let newApps = catalog.apps.compactMap { record -> AppID? in
            guard !referenced.contains(record.id),
                  appendedAppIDs.insert(record.id).inserted else {
                return nil
            }
            return record.id
        }
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

        return LayoutSnapshot(
            pages: pages,
            folders: normalized.folders,
            missingApps: missing
        )
    }
}
