import Foundation

/// 布局编辑器(纯逻辑): 把显示空间变更映射回布局空间,产出新的 LayoutSnapshot。
///
/// 这是 Phase 1C 推迟的契约实现:
/// LayoutTransaction 在显示空间(已过滤隐藏/缺失)计算变更;
/// LayoutEditor 把变更应用回布局空间,保持隐藏/缺失应用在布局中的位置不动。
///
/// 规则(确定性):
/// - reorder: 以目标显示索引处的布局项为锚,把被拖项插到锚之前;
///   目标越界 → 追加到最后一页末尾;应用后按 pageCapacity 重分块
/// - addToFolder: 从页面移除应用,按可见子项位置插入文件夹 children
///   (隐藏/缺失子项保持原位)
/// - reorderInFolder: 在可见子项空间内重排,隐藏/缺失子项保持布局引用
/// - moveOutOfFolder: 从 children 移除,插入页面指定显示索引;若实际只剩 0/1 个 child 则原子解散文件夹
/// - renameFolder: 更新文件夹名称
public enum LayoutEditor {
    /// 应用一个变更。无效时返回 nil(状态不变)。
    public static func apply(
        _ mutation: LayoutTransaction.LayoutMutation,
        to layout: LayoutSnapshot,
        display: DisplayModel
    ) -> LayoutSnapshot? {
        let candidate: LayoutSnapshot?
        switch mutation {
        case .reorder(let item, let toDisplayIndex):
            candidate = reorder(item, toDisplayIndex: toDisplayIndex, layout: layout, display: display)
        case .addToFolder(let app, let folder, let at):
            candidate = addToFolder(app: app, folder: folder, at: at, layout: layout, display: display)
        case .reorderInFolder(let app, let folder, let toIndex):
            candidate = reorderInFolder(
                app: app, folder: folder, toIndex: toIndex,
                layout: layout, display: display
            )
        case .moveOutOfFolder(let app, let folder, let toDisplayIndex):
            candidate = moveOutOfFolder(
                app: app, folder: folder, toDisplayIndex: toDisplayIndex,
                layout: layout, display: display
            )
        case .renameFolder(let id, let newName):
            candidate = renameFolder(id, newName: newName, in: layout)
        }
        guard let candidate, hasUniqueLayoutIdentities(candidate) else { return nil }
        return candidate
    }

    /// 创建文件夹: 合并 ≥2 个可见页面槽位应用,文件夹出现在最早应用的位置。
    /// (单应用文件夹会自动解散,因此不能新建)
    public static func createFolder(
        in layout: LayoutSnapshot,
        display: DisplayModel,
        name: String,
        appIDs: [AppID]
    ) -> (layout: LayoutSnapshot, folderID: FolderID)? {
        guard appIDs.count >= 2, Set(appIDs).count == appIDs.count else { return nil }
        let displayOrder = displayLayoutOrder(display)
        // 全部必须是页面槽位应用,且按显示顺序
        let ordered: [(id: AppID, displayIndex: Int)] = appIDs.compactMap { id in
            guard let index = displayOrder.firstIndex(of: .app(id)) else { return nil }
            return (id, index)
        }.sorted { $0.displayIndex < $1.displayIndex }
        guard ordered.count == appIDs.count else { return nil }
        let orderedIDs = ordered.map(\.id)
        let selectedIDs = Set(orderedIDs)          // ← moved up: O(1) contains in loop below
        let folderID = FolderID(normalized: "F-\(UUID().uuidString)")
        let folder = FolderRecord(id: folderID, name: name, children: orderedIDs)

        // 移除应用,插入文件夹槽(最早位置)
        var pages = layout.pages
        let firstIndex = ordered[0].displayIndex
        for page in 0..<pages.count {
            pages[page].removeAll { item in
                if case .app(let id) = item {
                    return selectedIDs.contains(id)  // ← O(1) Set lookup
                }
                return false
            }
        }
        let remainingOrder = displayOrder.filter { item in
            if case .app(let id) = item {
                return !selectedIDs.contains(id)
            }
            return true
        }
        let target = min(max(0, firstIndex), remainingOrder.count)
        pages = insert(
            [.folder(folderID)],
            atDisplayPosition: target,
            remainingOrder: remainingOrder,
            pages: pages
        )

        var folders = layout.folders
        folders[folderID] = folder
        var result = LayoutSnapshot(pages: pages, folders: folders, missingApps: layout.missingApps)
        result = rechunk(result, capacity: display.pageCapacity)
        guard hasUniqueLayoutIdentities(result) else { return nil }
        return (result, folderID)
    }

    /// 解散文件夹: children(布局顺序)重新插入页面,文件夹槽移除。
    public static func dissolveFolder(
        in layout: LayoutSnapshot,
        display: DisplayModel,
        id: FolderID
    ) -> LayoutSnapshot? {
        guard let folder = layout.folders[id] else { return nil }
        let displayOrder = displayLayoutOrder(display)
        guard let folderDisplayIndex = displayOrder.firstIndex(of: .folder(id)) else { return nil }

        var pages = layout.pages
        // 移除文件夹槽
        var removed = false
        outer: for page in 0..<pages.count {
            for itemIndex in 0..<pages[page].count {
                if pages[page][itemIndex] == .folder(id) {
                    pages[page].remove(at: itemIndex)
                    removed = true
                    break outer
                }
            }
        }
        guard removed else { return nil }

        // 插入 children(布局顺序)到文件夹显示位置
        let children = folder.children.map(LayoutItem.app)
        let remainingOrder = displayOrder.filter { $0 != .folder(id) }
        let target = min(max(0, folderDisplayIndex), remainingOrder.count)
        pages = insert(
            children,
            atDisplayPosition: target,
            remainingOrder: remainingOrder,
            pages: pages
        )

        var folders = layout.folders
        folders.removeValue(forKey: id)
        var result = LayoutSnapshot(pages: pages, folders: folders, missingApps: layout.missingApps)
        result = rechunk(result, capacity: display.pageCapacity)
        guard hasUniqueLayoutIdentities(result) else { return nil }
        return result
    }

    // MARK: - 单个变更

    private static func reorder(
        _ item: DisplayModel.DisplayItem,
        toDisplayIndex: Int,
        layout: LayoutSnapshot,
        display: DisplayModel
    ) -> LayoutSnapshot? {
        let displayOrder = displayLayoutOrder(display)
        let itemLayout = layoutItem(from: item)
        guard displayOrder.contains(itemLayout) else { return nil }

        // 从页面移除
        var pages = layout.pages
        var found = false
        outer: for page in 0..<pages.count {
            for itemIndex in 0..<pages[page].count {
                if pages[page][itemIndex] == itemLayout {
                    pages[page].remove(at: itemIndex)
                    found = true
                    break outer
                }
            }
        }
        guard found else { return nil }

        // 契约(Phase 1C): toDisplayIndex 是移除源项后的显示列表中的插入位置(gap 位置)
        let remainingOrder = displayOrder.filter { $0 != itemLayout }
        let target = min(max(0, toDisplayIndex), remainingOrder.count)
        pages = insert([itemLayout], atDisplayPosition: target, remainingOrder: remainingOrder, pages: pages)

        var result = LayoutSnapshot(pages: pages, folders: layout.folders, missingApps: layout.missingApps)
        result = rechunk(result, capacity: display.pageCapacity)
        return result
    }

    private static func addToFolder(
        app: AppID,
        folder: FolderID,
        at: Int,
        layout: LayoutSnapshot,
        display: DisplayModel
    ) -> LayoutSnapshot? {
        guard var folderRecord = layout.folders[folder] else { return nil }
        // app 必须当前是页面槽位
        guard displayLayoutOrder(display).contains(.app(app)) else { return nil }

        var pages = layout.pages
        var found = false
        outer: for page in 0..<pages.count {
            for itemIndex in 0..<pages[page].count {
                if pages[page][itemIndex] == .app(app) {
                    pages[page].remove(at: itemIndex)
                    found = true
                    break outer
                }
            }
        }
        guard found else { return nil }

        // 按可见子项位置插入(隐藏/缺失子项保持原位)
        let visibleChildren = folderRecord.children.filter { isVisible($0, layout: layout, display: display) }
        let clampedAt = min(max(0, at), visibleChildren.count)
        var insertIndex = folderRecord.children.count
        var seenVisible = 0
        for (i, child) in folderRecord.children.enumerated() {
            if isVisible(child, layout: layout, display: display) {
                if seenVisible == clampedAt {
                    insertIndex = i
                    break
                }
                seenVisible += 1
            }
        }
        folderRecord.children.insert(app, at: insertIndex)
        var folders = layout.folders
        folders[folder] = folderRecord
        var result = LayoutSnapshot(pages: pages, folders: folders, missingApps: layout.missingApps)
        result = rechunk(result, capacity: display.pageCapacity)
        return result
    }

    private static func reorderInFolder(
        app: AppID,
        folder: FolderID,
        toIndex: Int,
        layout: LayoutSnapshot,
        display: DisplayModel
    ) -> LayoutSnapshot? {
        guard var folderRecord = layout.folders[folder] else { return nil }
        // 只能重排当前显示中的可见子项;隐藏/缺失项不应由 UI 的可见索引误移动。
        guard let visibleChildren = display.folderVisibleChildren(folder),
              visibleChildren.contains(app),
              let sourceIndex = folderRecord.children.firstIndex(of: app) else {
            return nil
        }

        folderRecord.children.remove(at: sourceIndex)
        let remainingVisible = folderRecord.children.filter {
            isVisible($0, layout: layout, display: display)
        }
        let clampedAt = min(max(0, toIndex), remainingVisible.count)

        // 将可见 gap 索引映射回持久化 children 索引,保留不可见子项。
        var insertIndex = folderRecord.children.count
        var seenVisible = 0
        for (index, child) in folderRecord.children.enumerated() {
            guard isVisible(child, layout: layout, display: display) else { continue }
            if seenVisible == clampedAt {
                insertIndex = index
                break
            }
            seenVisible += 1
        }
        folderRecord.children.insert(app, at: insertIndex)

        var folders = layout.folders
        folders[folder] = folderRecord
        return LayoutSnapshot(
            pages: layout.pages,
            folders: folders,
            missingApps: layout.missingApps
        )
    }

    private static func moveOutOfFolder(
        app: AppID,
        folder: FolderID,
        toDisplayIndex: Int,
        layout: LayoutSnapshot,
        display: DisplayModel
    ) -> LayoutSnapshot? {
        guard var folderRecord = layout.folders[folder] else { return nil }
        guard let childIndex = folderRecord.children.firstIndex(of: app) else { return nil }
        folderRecord.children.remove(at: childIndex)

        var pages = layout.pages
        var folders = layout.folders
        var remainingOrder = displayLayoutOrder(display).filter { $0 != .app(app) }

        if folderRecord.children.isEmpty {
            // 历史/损坏状态下的单 child 文件夹移出后,必须在同一候选快照中
            // 同时删除空文件夹槽位和记录,再插入被移出的应用,不能留下 ghost folder。
            var removedFolder = false
            outer: for page in 0..<pages.count {
                for itemIndex in 0..<pages[page].count {
                    guard pages[page][itemIndex] == .folder(folder) else { continue }
                    pages[page].remove(at: itemIndex)
                    removedFolder = true
                    break outer
                }
            }
            guard removedFolder else { return nil }
            folders.removeValue(forKey: folder)
            remainingOrder.removeAll { $0 == .folder(folder) }
        } else if folderRecord.children.count == 1 {
            // 文件夹不能在一次 move-out 后短暂保留为单 App 文件夹:
            // 剩余 child 直接占据原文件夹槽位,并在同一候选快照中删除记录。
            guard let remainingApp = folderRecord.children.first else { return nil }
            var replacedFolder = false
            outer: for page in 0..<pages.count {
                for itemIndex in 0..<pages[page].count {
                    guard pages[page][itemIndex] == .folder(folder) else { continue }
                    pages[page][itemIndex] = .app(remainingApp)
                    replacedFolder = true
                    break outer
                }
            }
            guard replacedFolder else { return nil }

            folders.removeValue(forKey: folder)

            // 目标索引来自原显示空间。若剩余 app 可见,它继承 folder 的显示槽;
            // 若它隐藏/缺失,该持久槽位不进入显示空间,但仍留在 pages 原位置。
            if let folderDisplayIndex = remainingOrder.firstIndex(of: .folder(folder)) {
                if isVisible(remainingApp, layout: layout, display: display) {
                    remainingOrder[folderDisplayIndex] = .app(remainingApp)
                } else {
                    remainingOrder.remove(at: folderDisplayIndex)
                }
            }
        } else {
            folders[folder] = folderRecord
        }

        // 应用成为新页面槽位,插入指定显示索引
        let target = min(max(0, toDisplayIndex), remainingOrder.count)
        pages = insert([.app(app)], atDisplayPosition: target, remainingOrder: remainingOrder, pages: pages)

        var result = LayoutSnapshot(pages: pages, folders: folders, missingApps: layout.missingApps)
        result = rechunk(result, capacity: display.pageCapacity)
        return result
    }

    /// 重命名文件夹(窄 API): 纯持久化状态变更,不要求显示几何。
    /// 重命名不改变布局结构,因此不需要 DisplayModel;失败(文件夹不存在)返回 nil。
    public static func renameFolder(
        _ id: FolderID,
        newName: String,
        in layout: LayoutSnapshot
    ) -> LayoutSnapshot? {
        guard var folder = layout.folders[id] else { return nil }
        folder.name = newName
        var folders = layout.folders
        folders[id] = folder
        let candidate = LayoutSnapshot(
            pages: layout.pages, folders: folders, missingApps: layout.missingApps
        )
        guard hasUniqueLayoutIdentities(candidate) else { return nil }
        return candidate
    }

    // MARK: - 工具

    /// DisplayItem → LayoutItem(文件夹身份即 FolderID)。
    private static func layoutItem(from item: DisplayModel.DisplayItem) -> LayoutItem {
        switch item {
        case .app(let id):
            return .app(id)
        case .folder(let id):
            return .folder(id)
        }
    }

    /// 显示空间的布局项顺序(与 DisplayModel 派生一致: 已过滤隐藏/缺失, 已分块)。
    static func displayLayoutOrder(_ display: DisplayModel) -> [LayoutItem] {
        display.flatSlots.map { slot in
            switch slot {
            case .app(let id):
                return .app(id)
            case .folder(let id):
                return .folder(id)
            }
        }
    }

    private static func isVisible(_ id: AppID, layout: LayoutSnapshot, display: DisplayModel) -> Bool {
        !display.hiddenAppIDs.contains(id) && !display.missingAppIDs.contains(id)
    }

    /// 把 items 插到锚(remainingOrder[target] 对应布局项)之前; 越界或锚缺失 → 追加末尾。
    private static func insert(
        _ items: [LayoutItem],
        atDisplayPosition target: Int,
        remainingOrder: [LayoutItem],
        pages: [[LayoutItem]]
    ) -> [[LayoutItem]] {
        guard !items.isEmpty else { return pages }
        let clampedTarget = min(max(0, target), remainingOrder.count)
        if clampedTarget >= remainingOrder.count {
            var result = pages
            if result.isEmpty { result = [[]] }
            result[result.count - 1].append(contentsOf: items)
            return result
        }
        let anchor = remainingOrder[clampedTarget]
        var result = pages
        var found = false
        outer: for page in 0..<result.count {
            for itemIndex in 0..<result[page].count {
                if result[page][itemIndex] == anchor {
                    result[page].insert(contentsOf: items, at: itemIndex)
                    found = true
                    break outer
                }
            }
        }
        if !found {
            if result.isEmpty { result = [[]] }
            result[result.count - 1].append(contentsOf: items)
        }
        return result
    }

    /// AppID 在页面槽位和文件夹 children 中只能出现一次。
    private static func hasUniqueLayoutIdentities(_ layout: LayoutSnapshot) -> Bool {
        var seen = Set<AppID>()
        var seenFolders = Set<FolderID>()
        for page in layout.pages {
            for item in page {
                switch item {
                case .app(let id):
                    guard seen.insert(id).inserted else { return false }
                case .folder(let id):
                    guard layout.folders[id] != nil,
                          seenFolders.insert(id).inserted else { return false }
                }
            }
        }
        for folder in layout.folders.values {
            for id in folder.children where !seen.insert(id).inserted {
                return false
            }
        }
        return true
    }

    /// 按容量重分块(确定性;空页移除)。
    static func rechunk(_ layout: LayoutSnapshot, capacity: Int) -> LayoutSnapshot {
        guard capacity > 0 else { return layout }
        var flat: [LayoutItem] = []
        for page in layout.pages {
            flat.append(contentsOf: page)
        }
        var pages: [[LayoutItem]] = []
        var index = 0
        while index < flat.count {
            pages.append(Array(flat[index..<min(index + capacity, flat.count)]))
            index += capacity
        }
        return LayoutSnapshot(pages: pages, folders: layout.folders, missingApps: layout.missingApps)
    }
}
