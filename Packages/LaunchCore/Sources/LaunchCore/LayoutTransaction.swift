import Foundation

/// 拖拽事务: 纯逻辑阴影布局模型(禁止 AppKit / 禁止直接修改 LayoutStore)。
///
/// 职责:
/// - 计算源项、源槽位、悬停目标、gap 位置、被挤动项、页面边界、跨页目标
/// - 生成最终 drop 变更(LayoutMutation),由 LayoutStore(Phase 5)应用
///
/// 使用方式:
/// - 拖拽中: `preview` 计算预览(gap 位置),UI 以 CALayer 变换呈现
/// - 放下时: `drop` 一次完成,UI 仅做一次结构更新
/// - 文件夹操作: `moveIntoFolder` / `moveOutOfFolder`
///
/// 所有索引都在显示空间(已过滤隐藏/缺失应用)进行;操作确定性、可测试。
public struct LayoutTransaction {
    /// 被拖拽的源项。
    public enum Source: Sendable, Hashable {
        case app(AppID)
        case folder(FolderID)
    }

    /// 悬停目标(显示空间): 页 + 页内槽位。
    public struct Destination: Sendable, Equatable {
        public let page: Int
        public let slot: Int

        public init(page: Int, slot: Int) {
            self.page = page
            self.slot = slot
        }
    }

    /// 拖拽预览: 源项已移除, gap 位于 gapIndex。
    public struct Preview: Sendable, Equatable {
        public let slots: [DisplayModel.DisplayItem]
        public let gapIndex: Int
        public let sourceIndex: Int
        public let displacedCount: Int
    }

    /// 最终布局变更(布局存储层应用)。
    public enum LayoutMutation: Sendable, Equatable {
        case reorder(item: DisplayModel.DisplayItem, toDisplayIndex: Int)
        case addToFolder(app: AppID, folder: FolderID, at: Int)
        case moveOutOfFolder(app: AppID, from: FolderID, toDisplayIndex: Int)
        case renameFolder(FolderID, newName: String)
    }

    /// drop 结果: 新的显示模型 + 变更描述 + 需要结构更新的页。
    public struct DropResult: Sendable, Equatable {
        public let display: DisplayModel
        public let mutation: LayoutMutation
        public let changedPages: Set<Int>
    }

    // MARK: - Reorder

    /// 计算拖拽预览。源项不在显示中时返回 nil。
    public static func preview(
        display: DisplayModel,
        source: Source,
        destination: Destination
    ) -> Preview? {
        let slots = display.flatSlots
        guard let sourceIndex = flatIndex(of: source, in: slots) else { return nil }
        var remaining = slots
        remaining.remove(at: sourceIndex)
        let gapIndex = clampedTarget(
            destination, capacity: display.pageCapacity, count: remaining.count
        )
        return Preview(
            slots: remaining,
            gapIndex: gapIndex,
            sourceIndex: sourceIndex,
            displacedCount: abs(sourceIndex - gapIndex)
        )
    }

    /// 执行重排 drop(同页或跨页),按 pageCapacity 归一化分页。
    public static func drop(
        display: DisplayModel,
        source: Source,
        destination: Destination
    ) -> DropResult? {
        let slots = display.flatSlots
        guard let sourceIndex = flatIndex(of: source, in: slots) else { return nil }
        var remaining = slots
        remaining.remove(at: sourceIndex)
        let insertAt = clampedTarget(
            destination, capacity: display.pageCapacity, count: remaining.count
        )
        remaining.insert(slots[sourceIndex], at: insertAt)
        return finalize(
            display: display,
            slots: remaining,
            mutation: .reorder(item: slots[sourceIndex], toDisplayIndex: insertAt)
        )
    }

    // MARK: - Folder operations

    /// 把页面槽位中的应用放入文件夹 children 的指定位置。
    /// 应用必须位于页面槽位(不在任何文件夹内),文件夹必须显示中。
    public static func moveIntoFolder(
        display: DisplayModel,
        app: AppID,
        folder: FolderID,
        at: Int
    ) -> DropResult? {
        let slots = display.flatSlots
        guard flatIndex(of: .app(app), in: slots) != nil else { return nil }
        guard let folderIndex = folderSlotIndex(folder, in: slots) else { return nil }

        var working = slots
        let appIndex = flatIndex(of: .app(app), in: working)!
        working.remove(at: appIndex)
        let adjustedFolderIndex = folderIndex - (appIndex < folderIndex ? 1 : 0)
        guard case .folder(let fid, let children) = working[adjustedFolderIndex] else {
            return nil
        }
        let clampedAt = min(max(0, at), children.count)
        var newChildren = children
        newChildren.insert(app, at: clampedAt)
        working[adjustedFolderIndex] = .folder(fid, visibleChildren: newChildren)

        return finalize(
            display: display,
            slots: working,
            mutation: .addToFolder(app: app, folder: folder, at: clampedAt)
        )
    }

    /// 把应用移出文件夹,插入页面槽位。
    /// 应用必须是文件夹的可见子项。
    public static func moveOutOfFolder(
        display: DisplayModel,
        app: AppID,
        from folder: FolderID,
        to: Destination
    ) -> DropResult? {
        let slots = display.flatSlots
        guard let folderIndex = folderSlotIndex(folder, in: slots) else { return nil }
        guard case .folder(let fid, var children) = slots[folderIndex],
              let childIndex = children.firstIndex(of: app) else {
            return nil
        }
        children.remove(at: childIndex)

        var working = slots
        if children.isEmpty {
            // 无可见子项 → 文件夹从显示中隐藏(布局保留,由对账器决定解散)
            working.remove(at: folderIndex)
        } else {
            working[folderIndex] = .folder(fid, visibleChildren: children)
        }
        let insertAt = clampedTarget(to, capacity: display.pageCapacity, count: working.count)
        working.insert(.app(app), at: insertAt)

        return finalize(
            display: display,
            slots: working,
            mutation: .moveOutOfFolder(app: app, from: folder, toDisplayIndex: insertAt)
        )
    }

    // MARK: - Helpers

    private static func flatIndex(
        of source: Source,
        in slots: [DisplayModel.DisplayItem]
    ) -> Int? {
        slots.firstIndex { slot in
            switch (source, slot) {
            case (.app(let a), .app(let b)):
                return a == b
            case (.folder(let a), .folder(let b, _)):
                return a == b
            default:
                return false
            }
        }
    }

    private static func folderSlotIndex(
        _ folder: FolderID,
        in slots: [DisplayModel.DisplayItem]
    ) -> Int? {
        slots.firstIndex { slot in
            if case .folder(let fid, _) = slot {
                return fid == folder
            }
            return false
        }
    }

    private static func clampedTarget(
        _ destination: Destination,
        capacity: Int,
        count: Int
    ) -> Int {
        min(max(0, destination.page * capacity + destination.slot), count)
    }

    private static func chunk(
        _ slots: [DisplayModel.DisplayItem],
        capacity: Int
    ) -> [[DisplayModel.DisplayItem]] {
        guard !slots.isEmpty else { return [] }
        var pages: [[DisplayModel.DisplayItem]] = []
        for start in stride(from: 0, to: slots.count, by: capacity) {
            pages.append(Array(slots[start..<min(start + capacity, slots.count)]))
        }
        return pages
    }

    private static func finalize(
        display: DisplayModel,
        slots: [DisplayModel.DisplayItem],
        mutation: LayoutMutation
    ) -> DropResult {
        let newPages = chunk(slots, capacity: display.pageCapacity)
        let newDisplay = DisplayModel(
            pages: newPages,
            pageCapacity: display.pageCapacity,
            hiddenAppIDs: display.hiddenAppIDs,
            missingAppIDs: display.missingAppIDs
        )
        let changed = changedPages(between: display.pages, and: newPages)
        return DropResult(display: newDisplay, mutation: mutation, changedPages: changed)
    }

    private static func changedPages(
        between old: [[DisplayModel.DisplayItem]],
        and new: [[DisplayModel.DisplayItem]]
    ) -> Set<Int> {
        var changed = Set<Int>()
        let count = max(old.count, new.count)
        for index in 0..<count {
            let oldPage = index < old.count ? old[index] : []
            let newPage = index < new.count ? new[index] : []
            if oldPage != newPage {
                changed.insert(index)
            }
        }
        return changed
    }
}
