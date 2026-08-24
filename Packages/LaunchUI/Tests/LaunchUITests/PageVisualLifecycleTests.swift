import AppKit
import CoreGraphics
import Foundation
import LaunchCore
import Testing
@testable import LaunchUI

/// P3-A: GridViewController 页面视觉生命周期聚焦测试。
///
/// 覆盖 PageVisual 所有权审计识别的四个缺口:
/// 1. 几何变更 → 收掉 active compositor + 缓存键失效 + 新几何键重建。
/// 2. backing scale 变更(viewDidLayout 分支)→ purge + 新 scale 键重建。
/// 3. 内存压力 purge → 重排恢复 working set。
/// 4. drag-begin 的 Grid 级 compositor shutdown 幂等。
///
/// 全部使用真实密度门(默认 ≥20 项/页), 测试替身每页 24 项。
@Suite("PageVisual lifecycle", .serialized)
@MainActor
struct PageVisualLifecycleTests {
    // MARK: - 测试基础设施

    private func makeApp(_ page: Int, _ index: Int) -> AppID {
        AppID("/Applications/LifecycleA\(page)\(index).app")!
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

    private func makeGrid(_ store: LifecycleStore) -> GridViewController {
        let grid = GridViewController(store: store, iconProvider: LifecycleIconProvider())
        grid.pageVisualCompositorEnabled = true
        return grid
    }

    /// 等待 working set 三页齐备(重试版; 容忍并行 suite 的语言翻转)。
    private func waitPrepared(_ grid: GridViewController, maxAttempts: Int = 8) async {
        for _ in 0..<maxAttempts {
            await grid.waitForPageVisualPrepareForDiag()
            if grid.pageVisualCacheCountForDiag == 3 { return }
        }
    }

    /// 等待 compositor 可激活(重试版)。几何/scale 变更后旧键仍驻留缓存,
    /// 缓存计数不能作为"新键就绪"信号, 必须以 eligibility 为准。
    private func waitEligible(_ grid: GridViewController, maxAttempts: Int = 8) async {
        for _ in 0..<maxAttempts {
            await grid.waitForPageVisualPrepareForDiag()
            if grid.pageCompositorEligibleForDiag { return }
        }
    }

    // MARK: - 1. 几何变更

    @Test("geometry change shuts down active compositor, invalidates cache, repopulates with new keys")
    func geometryChangeInvalidatesCompositorAndCache() async throws {
        let store = LifecycleStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        await waitPrepared(grid)
        #expect(grid.pageVisualCacheCountForDiag > 0, "working set 视觉已准备")
        #expect(grid.pageCompositorEligibleForDiag)

        // 手势起点激活 compositor(让"收掉 active compositor"成为真实断言)。
        grid.pagingProbeGesture(deltaXs: [-100, -150])
        #expect(grid.pageCompositor.isActive, "手势起点激活 compositor")

        // 变更几何(列/行/图标尺寸)。
        store.gridColumns = 4
        store.gridRows = 3
        store.iconSize = 48
        grid.applyGeometryConfig(columns: 4, rows: 3, iconSize: 48)

        // (a) active compositor 被收掉。
        #expect(!grid.pageCompositor.isActive, "几何变更收掉 active compositor")

        // (b) 旧几何键失效: 回到普通页后, 旧键不再匹配新几何 → 不可合成。
        // 注: applyGeometryConfig 不显式 purge 缓存(键自失效), 故此处断言
        // "不可合成"而非"缓存计数 == 0"(见 [RISKS])。
        grid.goToPage(1, animated: false)
        #expect(!grid.pageCompositorEligibleForDiag, "旧几何键失效 → 不可合成")

        // (c) 重新准备 → 新几何键重建, working set 齐备。
        grid.schedulePageVisualPrepare()
        await waitEligible(grid)
        #expect(grid.pageCompositorEligibleForDiag, "新几何键重建后可合成")
        let expected = PageVisualGeometrySignature(geometry: grid.geometry)
        #expect(
            grid.pageVisualKeysForDiag.allSatisfy { $0.geometry == expected },
            "缓存键几何已更新到新几何"
        )
    }

    // MARK: - 2. backing scale 变更

    @Test("backing scale change shuts down compositor, purges cache, repopulates at new scale")
    func backingScaleChangeInvalidatesVisuals() async throws {
        let store = LifecycleStore()
        let grid = makeGrid(store)
        let window = ScalableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.testBackingScale = 2
        window.contentView = grid.view
        window.layoutIfNeeded()
        grid.view.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        await waitPrepared(grid)
        #expect(grid.pageVisualCacheTotalBytesForDiag > 0, "视觉已光栅化")
        #expect(grid.pageVisualKeysForDiag.allSatisfy { $0.backingScale == 2 })

        // 模拟换屏: 改变 backing scale 并强制布局(viewDidLayout 的 scale 分支)。
        window.testBackingScale = 3
        grid.view.needsLayout = true
        grid.view.layoutSubtreeIfNeeded()

        #expect(!grid.pageCompositor.isActive, "scale 变更收掉 compositor")
        #expect(grid.pageVisualCacheCountForDiag == 0, "scale 变更 purge 视觉缓存")

        // 重新准备 → 新 scale 键重建。
        grid.schedulePageVisualPrepare()
        await waitPrepared(grid)
        #expect(grid.pageVisualCacheCountForDiag == 3)
        #expect(
            grid.pageVisualKeysForDiag.allSatisfy { $0.backingScale == 3 },
            "缓存键 scale 已更新到新 scale"
        )
    }

    // MARK: - 3. 内存压力 purge 后重排

    @Test("memory pressure purge then repopulation restores working set")
    func memoryPressurePurgeThenRepopulate() async throws {
        let store = LifecycleStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        await waitPrepared(grid)
        #expect(grid.pageVisualCacheCountForDiag > 0)

        let baseline = grid.memoryPressurePurgeCountForDiag
        grid.triggerMemoryPressurePurgeForDiag()
        #expect(grid.pageVisualCacheCountForDiag == 0, "内存压力 purge 清空缓存")
        #expect(grid.memoryPressurePurgeCountForDiag == baseline + 1)

        // purge 后重排一次 idle 视觉准备(与事件源回调路径一致)。
        grid.schedulePageVisualPrepare()
        await waitPrepared(grid)
        #expect(grid.pageVisualCacheCountForDiag > 0, "purge 后重排恢复 working set")
        #expect(grid.pageVisualCacheCountForDiag <= 3, "working set 有界(≤3)")
    }

    // MARK: - 4. drag-begin compositor shutdown(Grid 级)

    @Test("drag-begin compositor shutdown at grid level is idempotent")
    func dragBeginCompositorShutdownIdempotent() async throws {
        let store = LifecycleStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        await waitPrepared(grid)
        #expect(grid.pageCompositorEligibleForDiag)

        // 手势起点激活 compositor。
        grid.pagingProbeGesture(deltaXs: [-100, -150])
        #expect(grid.pageCompositor.isActive, "手势起点激活 compositor")

        // LauncherWindowController 在 drag-begin 调用的 shutdown 路径。
        grid.shutdownPageCompositor()
        #expect(!grid.pageCompositor.isActive, "shutdown 收掉 compositor")

        // 幂等: 重复调用不崩溃、保持关闭。
        grid.shutdownPageCompositor()
        grid.shutdownPageCompositor()
        #expect(!grid.pageCompositor.isActive, "重复 shutdown 幂等")
    }
}

// MARK: - 测试替身

/// 每页 24 项(≥ 默认密度门 20), 4 页; 几何参数可变(几何变更测试)。
@MainActor
private final class LifecycleStore: LauncherStoring {
    var searchResultsValue: [DisplayModel.DisplayItem]?
    var revision: UInt64 = 1
    var gridColumns = 6
    var gridRows = 4
    var iconSize = 64

    var onDataChange: (() -> Void)?
    var searchQuery = ""
    let wallpaperBlurRadius = 30
    let searchBarWidth = 320
    var displayRevision: UInt64 { revision }

    let pages: [[DisplayModel.DisplayItem]]

    init() {
        pages = (0..<4).map { page in
            (0..<24).map { index in
                .app(AppID("/Applications/LifecycleA\(page)\(index).app")!)
            }
        }
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID { UUID() }
    func removeDataObserver(_ token: UUID) {}

    func displayModel() -> DisplayModel {
        DisplayModel(pages: pages, pageCapacity: gridColumns * gridRows)
    }

    func searchResults() -> [DisplayModel.DisplayItem]? { searchResultsValue }
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
private final class LifecycleIconProvider: IconImageProviding {
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

/// 可编程 backing scale 的窗口替身: 覆盖 `backingScaleFactor` 以模拟换屏。
/// `NSWindow.backingScaleFactor` 是 open get-only 属性, 子类可覆盖。
@MainActor
private final class ScalableWindow: NSWindow {
    var testBackingScale: CGFloat = 2
    override var backingScaleFactor: CGFloat { testBackingScale }
}
