import AppKit
import CoreGraphics
import Foundation
import LaunchCore
import Testing
@testable import LaunchUI

/// T-025: searchQuery 移出 LauncherStore 后的 revision 语义。
///
/// 搜索是 UI ephemeral state:
/// 1. 输入搜索字符(p/ph/photo)不得递增 displayRevision —— 修复前每次键入
///    didSet bumpRevision, 产生 5 个 revision。
/// 2. 搜索状态变化不得改变普通 PageVisual cache identity —— PageVisualKey
///    含 displayRevision, 搜索键入使普通页视觉键失效, 退出搜索后需重新光栅化。
///
/// 全部使用真实密度门(默认 ≥20 项/页), 测试替身每页 24 项。
@Suite("Search revision semantics", .serialized)
@MainActor
struct SearchRevisionSemanticsTests {
    // MARK: - 1. 输入搜索字符不递增 displayRevision

    @Test("输入 p/ph/photo 不递增 displayRevision(修复前红)")
    func searchTypingDoesNotBumpDisplayRevision() throws {
        let store = SearchRevisionTestStore()
        let grid = GridViewController(store: store, iconProvider: nil)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        let baseline = store.displayRevision
        #expect(!grid.isSearchMode)

        store.searchResultsValue = [.app(makeApp(1))]
        grid.searchQuery = "p"
        grid.refresh()
        #expect(grid.isSearchMode, "输入 'p' 进入搜索态")
        #expect(store.displayRevision == baseline, "输入 'p' 不递增 displayRevision")

        grid.searchQuery = "ph"
        grid.refresh()
        #expect(grid.isSearchMode, "输入 'ph' 保持搜索态")
        #expect(store.displayRevision == baseline, "输入 'ph' 不递增 displayRevision")

        grid.searchQuery = "photo"
        grid.refresh()
        #expect(grid.isSearchMode, "输入 'photo' 保持搜索态")
        #expect(store.displayRevision == baseline, "输入 'photo' 不递增 displayRevision")

        // 清空搜索退出搜索态, 同样不递增。
        grid.searchQuery = ""
        grid.refresh()
        #expect(!grid.isSearchMode, "清空搜索退出搜索态")
        #expect(store.displayRevision == baseline, "清空搜索不递增 displayRevision")
    }

    // MARK: - 2. 搜索状态变化不影响普通 PageVisual cache identity

    @Test("搜索状态变化不改变普通 PageVisual cache identity")
    func searchDoesNotInvalidatePageVisualCacheIdentity() async throws {
        let store = SearchRevisionTestStore()
        let grid = GridViewController(store: store, iconProvider: SearchRevisionIconProvider())
        grid.pageVisualCompositorEnabled = true
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        await waitPrepared(grid)
        #expect(grid.pageVisualCacheCountForDiag > 0, "working set 视觉已准备")
        let keysBefore = grid.pageVisualKeysForDiag
        #expect(!keysBefore.isEmpty, "搜索前普通页视觉键非空")

        // 进入搜索(输入 photo) → 搜索态。
        store.searchResultsValue = [.app(makeApp(1))]
        grid.searchQuery = "photo"
        grid.refresh()
        #expect(grid.isSearchMode)

        // 搜索中改词(ph) → 仍搜索态。
        grid.searchQuery = "ph"
        grid.refresh()
        #expect(grid.isSearchMode)

        // 退出搜索 → 普通页恢复(回到搜索前页 1)。
        store.searchResultsValue = nil
        grid.searchQuery = ""
        grid.refresh()
        #expect(!grid.isSearchMode)
        #expect(grid.currentPageValue == 1, "退出搜索恢复到搜索前页")

        // 重新准备 working set: 键与搜索前一致(displayRevision 未变 → identity 未失效)。
        grid.schedulePageVisualPrepare()
        await waitPrepared(grid)
        #expect(grid.pageVisualCacheCountForDiag > 0, "退出搜索后 working set 重新就绪")
        #expect(
            grid.pageVisualKeysForDiag == keysBefore,
            "搜索状态变化不改变普通 PageVisual cache identity"
        )
    }

    // MARK: - 测试基础设施

    private func makeApp(_ n: Int) -> AppID {
        AppID("/Applications/SearchRevResult\(n).app")!
    }

    private func makeWindow(for controller: GridViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    /// 等待 working set 三页齐备(重试版; 容忍并行 suite 的语言翻转)。
    private func waitPrepared(_ grid: GridViewController, maxAttempts: Int = 8) async {
        for _ in 0..<maxAttempts {
            await grid.waitForPageVisualPrepareForDiag()
            if grid.pageVisualCacheCountForDiag == 3 { return }
        }
    }
}

// MARK: - 测试替身

/// 每页 24 项(≥ 默认密度门 20), 4 页; 搜索词非空时返回 searchResultsValue。
@MainActor
private final class SearchRevisionTestStore: LauncherStoring {
    var searchResultsValue: [DisplayModel.DisplayItem]?
    var revision: UInt64 = 1
    let gridColumns = 6
    let gridRows = 4
    let iconSize = 64

    var onDataChange: (() -> Void)?
    let wallpaperBlurRadius = 30
    let searchBarWidth = 320
    var displayRevision: UInt64 { revision }

    let pages: [[DisplayModel.DisplayItem]]

    init() {
        pages = (0..<4).map { page in
            (0..<24).map { index in
                .app(AppID("/Applications/SearchRevA\(page)\(index).app")!)
            }
        }
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID { UUID() }
    func removeDataObserver(_ token: UUID) {}

    func displayModel() -> DisplayModel {
        DisplayModel(pages: pages, pageCapacity: gridColumns * gridRows)
    }

    func searchResults(for query: String) -> [DisplayModel.DisplayItem]? {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : searchResultsValue
    }
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
private final class SearchRevisionIconProvider: IconImageProviding {
    func icon(for appID: AppID, pointSize: Int, scale: Int) async -> CGImage? {
        let context = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let hue = CGFloat(abs(appID.rawValue.hashValue) % 12) / 12
        context.setFillColor(
            NSColor(hue: hue, saturation: 0.6, brightness: 0.7, alpha: 1).cgColor
        )
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return context.makeImage()
    }

    func trimMemoryForHidden() {}
}
