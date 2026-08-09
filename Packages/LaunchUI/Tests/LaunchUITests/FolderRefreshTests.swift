import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Folder refresh: structure vs metadata", .serialized)
@MainActor
struct FolderRefreshTests {
    /// 可见 cell 按 item 索引记录实例身份与标签文本。
    private func snapshotVisibleCells(
        _ collectionView: ClickableCollectionView
    ) -> [Int: (identity: ObjectIdentifier, label: String?)] {
        var result: [Int: (ObjectIdentifier, String?)] = [:]
        for cell in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            result[indexPath.item] = (ObjectIdentifier(cell), cellLabel(of: cell))
        }
        return result
    }

    private func cellLabel(of item: NSCollectionViewItem) -> String? {
        descendants(of: item.view).compactMap { $0 as? NSTextField }.first?.stringValue
    }

    @Test("仅元数据变化(显示名)重配置可见 cell, 不重建, 文本即时更新")
    func metadataDisplayNameChangeReconfiguresCellsInPlace() throws {
        let ids = [AppID("/Applications/Alpha.app")!, AppID("/Applications/Beta.app")!]
        let store = FolderRefreshTestStore(
            appIDs: ids,
            folderName: "Work",
            displayNames: [ids[0]: "Alpha", ids[1]: "Beta"]
        )
        let controller = FolderViewController(
            store: store, iconProvider: nil, folderID: store.folderID
        )
        let window = makeWindow(for: controller)
        defer { window.orderOut(nil); window.contentView = nil }

        let collectionView = try #require(
            descendant(of: controller.view, as: ClickableCollectionView.self)
        )
        collectionView.layoutSubtreeIfNeeded()
        let before = snapshotVisibleCells(collectionView)
        #expect(before.count == 2)
        #expect(before[0]?.label == "Alpha")
        #expect(before[1]?.label == "Beta")

        // 仅显示名变化(如自定义名被清除): 子项集合与顺序不变。
        store.displayNames[ids[0]] = "Alpha New"
        store.notifyDataObservers()
        collectionView.layoutSubtreeIfNeeded()

        let after = snapshotVisibleCells(collectionView)
        #expect(after.count == 2)
        // 同一批 cell 实例(未被 reloadData 重建)。
        #expect(after[0]?.identity == before[0]?.identity)
        #expect(after[1]?.identity == before[1]?.identity)
        // 文本已更新。
        #expect(after[0]?.label == "Alpha New")
        #expect(after[1]?.label == "Beta")
    }

    @Test("重命名文件夹: 标题更新, 可见 cell 不重建")
    func folderRenameUpdatesTitleWithoutRebuildingCells() throws {
        let ids = [AppID("/Applications/Alpha.app")!, AppID("/Applications/Beta.app")!]
        let store = FolderRefreshTestStore(
            appIDs: ids,
            folderName: "Work",
            displayNames: [ids[0]: "Alpha", ids[1]: "Beta"]
        )
        let controller = FolderViewController(
            store: store, iconProvider: nil, folderID: store.folderID
        )
        let window = makeWindow(for: controller)
        defer { window.orderOut(nil); window.contentView = nil }

        let collectionView = try #require(
            descendant(of: controller.view, as: ClickableCollectionView.self)
        )
        collectionView.layoutSubtreeIfNeeded()
        let before = snapshotVisibleCells(collectionView)
        #expect(before.count == 2)

        store.folderName = "Renamed Work"
        store.notifyDataObservers()
        collectionView.layoutSubtreeIfNeeded()

        let after = snapshotVisibleCells(collectionView)
        #expect(after.count == 2)
        #expect(after[0]?.identity == before[0]?.identity)
        #expect(after[1]?.identity == before[1]?.identity)
        // 应用 cell 标签不因文件夹重命名而变化。
        #expect(after[0]?.label == "Alpha")
        #expect(after[1]?.label == "Beta")
        // 标题已更新。
        let title = try #require(
            descendants(of: controller.view).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "Renamed Work" }
        )
        #expect(title.stringValue == "Renamed Work")
    }

    @Test("新增子项: 结构刷新出现新 cell, 既有 cell 身份保持")
    func addingChildAppearsWithExistingCellsKept() throws {
        let ids = [
            AppID("/Applications/Alpha.app")!,
            AppID("/Applications/Beta.app")!,
            AppID("/Applications/Gamma.app")!,
        ]
        let store = FolderRefreshTestStore(
            appIDs: Array(ids[0...1]),
            folderName: "Work",
            displayNames: [ids[0]: "Alpha", ids[1]: "Beta", ids[2]: "Gamma"]
        )
        let controller = FolderViewController(
            store: store, iconProvider: nil, folderID: store.folderID
        )
        let window = makeWindow(for: controller)
        defer { window.orderOut(nil); window.contentView = nil }

        let collectionView = try #require(
            descendant(of: controller.view, as: ClickableCollectionView.self)
        )
        collectionView.layoutSubtreeIfNeeded()
        let before = snapshotVisibleCells(collectionView)
        #expect(before.count == 2)

        store.appIDs = Array(ids[0...2])
        store.notifyDataObservers()
        collectionView.layoutSubtreeIfNeeded()

        let after = snapshotVisibleCells(collectionView)
        #expect(after.count == 3)
        #expect(after[0]?.identity == before[0]?.identity)
        #expect(after[1]?.identity == before[1]?.identity)
        #expect(after[2]?.label == "Gamma")
        #expect(after[0]?.label == "Alpha")
        #expect(after[1]?.label == "Beta")
    }

    @Test("移除子项: 结构刷新移除对应 cell")
    func removingChildDropsItsCell() throws {
        let ids = [
            AppID("/Applications/Alpha.app")!,
            AppID("/Applications/Beta.app")!,
            AppID("/Applications/Gamma.app")!,
        ]
        let store = FolderRefreshTestStore(
            appIDs: Array(ids[0...2]),
            folderName: "Work",
            displayNames: [ids[0]: "Alpha", ids[1]: "Beta", ids[2]: "Gamma"]
        )
        let controller = FolderViewController(
            store: store, iconProvider: nil, folderID: store.folderID
        )
        let window = makeWindow(for: controller)
        defer { window.orderOut(nil); window.contentView = nil }

        let collectionView = try #require(
            descendant(of: controller.view, as: ClickableCollectionView.self)
        )
        collectionView.layoutSubtreeIfNeeded()
        #expect(snapshotVisibleCells(collectionView).count == 3)

        store.appIDs = [ids[0], ids[2]]
        store.notifyDataObservers()
        collectionView.layoutSubtreeIfNeeded()

        let after = snapshotVisibleCells(collectionView)
        #expect(after.count == 2)
        #expect(after[0]?.label == "Alpha")
        #expect(after[1]?.label == "Gamma")
    }

    @Test("重排子项: 结构刷新保持新顺序")
    func reorderingChildrenAppliesNewOrder() throws {
        let ids = [AppID("/Applications/Alpha.app")!, AppID("/Applications/Beta.app")!]
        let store = FolderRefreshTestStore(
            appIDs: [ids[0], ids[1]],
            folderName: "Work",
            displayNames: [ids[0]: "Alpha", ids[1]: "Beta"]
        )
        let controller = FolderViewController(
            store: store, iconProvider: nil, folderID: store.folderID
        )
        let window = makeWindow(for: controller)
        defer { window.orderOut(nil); window.contentView = nil }

        let collectionView = try #require(
            descendant(of: controller.view, as: ClickableCollectionView.self)
        )
        collectionView.layoutSubtreeIfNeeded()
        let initial = snapshotVisibleCells(collectionView)
        #expect(initial.count == 2)
        #expect(initial[0]?.label == "Alpha")
        #expect(initial[1]?.label == "Beta")

        store.appIDs = [ids[1], ids[0]]
        store.notifyDataObservers()
        collectionView.layoutSubtreeIfNeeded()

        let after = snapshotVisibleCells(collectionView)
        #expect(after.count == 2)
        #expect(after[0]?.label == "Beta")
        #expect(after[1]?.label == "Alpha")
    }

    private func makeWindow(for controller: FolderViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}

@MainActor
private final class FolderRefreshTestStore: LauncherStoring {
    var appIDs: [AppID]
    let folderID: FolderID
    var folderName: String
    var displayNames: [AppID: String]

    init(appIDs: [AppID], folderName: String, displayNames: [AppID: String]) {
        self.appIDs = appIDs
        self.folderID = FolderID("folder://refresh-test")!
        self.folderName = folderName
        self.displayNames = displayNames
    }

    var onDataChange: (() -> Void)?
    var searchQuery = ""
    let gridColumns = 7
    let gridRows = 6
    let iconSize = 64
    let displayRevision: UInt64 = 1

    private var observers: [UUID: () -> Void] = [:]

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeDataObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    func notifyDataObservers() {
        for observer in observers.values {
            observer()
        }
    }

    func displayModel() -> DisplayModel {
        DisplayModel(
            pages: [[.folder(folderID, visibleChildren: appIDs)]],
            pageCapacity: gridColumns * gridRows
        )
    }

    func searchResults() -> [DisplayModel.DisplayItem]? { nil }
    func displayName(for appID: AppID) -> String {
        displayNames[appID] ?? appID.rawValue
    }
    func folderName(for folderID: FolderID) -> String {
        folderID == self.folderID ? folderName : folderID.rawValue
    }
    func launch(_ appID: AppID) {}
    func createFolder(name: String, appIDs: [AppID]) {}
    func renameFolder(_ id: FolderID, to name: String) {}
    func dissolveFolder(_ id: FolderID) {}
    func addToFolder(app: AppID, folder: FolderID) {}
    func moveOutOfFolder(
        app: AppID,
        from folder: FolderID,
        toDisplayIndex: Int,
        completion: @escaping (Bool) -> Void
    ) {
        completion(false)
    }
    func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int) {}
    func folderNames() -> [FolderID: String] { [folderID: folderName] }
    func folderChildren(_ id: FolderID) -> [AppID]? { id == folderID ? appIDs : nil }
    func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation) {}
    func setHidden(_ appID: AppID, hidden: Bool) {}
    func setCustomName(_ appID: AppID, name: String?) {}
    func moveToTrash(_ appID: AppID) {}
    func isHidden(_ appID: AppID) -> Bool { false }
}

@MainActor
private func descendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
    if let match = view as? T {
        return match
    }
    for subview in view.subviews {
        if let match = descendant(of: subview, as: type) {
            return match
        }
    }
    return nil
}
