import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

/// PA1 帧预算减负回归测试。
///
/// 覆盖:
/// - 页点增量更新: pageCount 不变的连续翻页保留页点 view 实例(不再全量销毁重建,
///   settle 目标页落地路径在第一帧 settle 之前同步执行)。
/// - 相邻页预热去重: 同一 (page, displayRevision) 只派生一次图标预热任务;
///   refresh()(每次 show 都会走)重置去重键后重新预热。
@Suite("PA1 frame budget", .serialized)
@MainActor
struct PA1FrameBudgetTests {
    private func makeApp(_ n: Int) -> DisplayModel.DisplayItem {
        .app(AppID(normalized: "/Applications/PA1App\(n).app"))
    }

    private func makePages() -> [[DisplayModel.DisplayItem]] {
        [
            [makeApp(1), makeApp(2)],
            [makeApp(3), makeApp(4)],
            [makeApp(5), makeApp(6)],
        ]
    }

    private func makeGrid(
        pages: [[DisplayModel.DisplayItem]],
        iconProvider: (any IconImageProviding)? = nil
    ) -> (grid: GridViewController, store: PA1TestStore, window: NSWindow) {
        let store = PA1TestStore(pages: pages)
        let grid = GridViewController(store: store, iconProvider: iconProvider)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = grid.view
        window.layoutIfNeeded()
        grid.view.layoutSubtreeIfNeeded()
        grid.refresh()
        grid.view.layoutSubtreeIfNeeded()
        return (grid, store, window)
    }

    private func dotIdentifiers(in view: NSView) -> Set<ObjectIdentifier> {
        var result: Set<ObjectIdentifier> = []
        if let dot = view as? PageDotView {
            result.insert(ObjectIdentifier(dot))
        }
        for subview in view.subviews {
            result.formUnion(dotIdentifiers(in: subview))
        }
        return result
    }

    @Test("page dots keep view identity across flips with unchanged page count")
    func pageDotsIdentityPreservedAcrossFlips() throws {
        let (grid, _, _) = makeGrid(pages: makePages())

        grid.goToPage(0, animated: false)
        #expect(grid.pageDotCountForDiag == 3)
        let before = dotIdentifiers(in: grid.view)
        #expect(before.count == 3)

        // 同 pageCount 翻页走增量路径: 只切 active 态, 不重建视图。
        grid.goToPage(1, animated: false)
        grid.goToPage(2, animated: false)
        grid.goToPage(0, animated: false)

        let after = dotIdentifiers(in: grid.view)
        #expect(grid.pageDotCountForDiag == 3)
        #expect(after == before)
    }

    @Test("prewarm skips duplicate (page, revision) until refresh resets it")
    func prewarmDeduplicatedUntilRefresh() async throws {
        let provider = PA1CountingIconProvider()
        let (grid, _, _) = makeGrid(pages: makePages(), iconProvider: provider)
        // 本测试只针对相邻页预热去重; v0.5.0 起 compositor 默认启用且其
        // idle prepare 会额外请求图标, 隔离关闭以保持断言语义。
        grid.pageVisualCompositorEnabled = false

        // 排空 makeGrid 初始 refresh 路径的预热请求(page0 相邻页)。
        try await waitForStable(provider)
        let baseline = provider.requestCount

        grid.goToPage(1, animated: false)
        // 预热 page±1 = page0+page2 各 2 app。
        try await waitForStable(provider)
        let afterFirstWarm = provider.requestCount
        #expect(afterFirstWarm == baseline + 4)

        // 同一 (page, revision) 第二次触发: 去重, 不再派生请求。
        grid.goToPage(1, animated: false)
        try await waitForStable(provider)
        #expect(provider.requestCount == afterFirstWarm)

        // refresh()(show 路径)重置去重键: 下一次翻页重新预热 working set。
        grid.refresh()
        grid.goToPage(1, animated: false)
        try await waitForStable(provider)
        #expect(provider.requestCount == afterFirstWarm + 4)
    }

    /// 等待异步预热请求计数连续两次采样不变(主 actor 排空)。
    private func waitForStable(_ provider: PA1CountingIconProvider) async throws {
        var previous = -1
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if provider.requestCount == previous { return }
            previous = provider.requestCount
        }
    }
}

@MainActor
private final class PA1TestStore: LauncherStoring {
    let pages: [[DisplayModel.DisplayItem]]
    var revision: UInt64 = 7

    var onDataChange: (() -> Void)?
    let gridColumns = 2
    let gridRows = 1
    let iconSize = 64
    let wallpaperBlurRadius = 30
    let searchBarWidth = 320
    var displayRevision: UInt64 { revision }

    init(pages: [[DisplayModel.DisplayItem]]) {
        self.pages = pages
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID { UUID() }

    func removeDataObserver(_ token: UUID) {}

    func displayModel() -> DisplayModel {
        DisplayModel(pages: pages, pageCapacity: gridColumns * gridRows)
    }

    func searchResults(for query: String) -> [DisplayModel.DisplayItem]? { nil }
    func displayName(for appID: AppID) -> String { appID.rawValue }
    func folderName(for folderID: FolderID) -> String { folderID.rawValue }
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
    ) { completion(false) }
    func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int) {}
    func folderNames() -> [FolderID: String] { [:] }
    func folderChildren(_ id: FolderID) -> [AppID]? { nil }
    func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation) {}
    func setHidden(_ appID: AppID, hidden: Bool) {}
    func setCustomName(_ appID: AppID, name: String?) {}
    func moveToTrash(_ appID: AppID) {}
    func isHidden(_ appID: AppID) -> Bool { false }
}

@MainActor
private final class PA1CountingIconProvider: IconImageProviding {
    private(set) var requestCount = 0

    func icon(for appID: AppID, pointSize: Int, scale: Int) async -> CGImage? {
        requestCount += 1
        return nil
    }

    func trimMemoryForHidden() {}
}
