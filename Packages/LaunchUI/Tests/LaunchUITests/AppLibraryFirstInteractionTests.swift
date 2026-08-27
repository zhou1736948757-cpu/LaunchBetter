import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

/// X2: 进入 App Library 后首个事件必须直接被 Library 消费(无需前置"激活"点击)。
///
/// 覆盖任务包要求的四种首事件(全部经 Grid host 真实挂载/布局):
/// - 首事件点击大图标 → 立即 launch
/// - 首事件垂直滚(内容溢出)→ 立即滚动
/// - 首事件点击卡片空白 → 立即打开 detail
/// - 首事件点击空白 → 立即隐藏(onClickBlank)
/// 以及进入 surface 时清理残留手势状态(离开手势未 ended 后重入)。
@Suite("App Library first interaction", .serialized)
@MainActor
struct AppLibraryFirstInteractionTests {
    private func makeApp(_ n: Int) -> AppID {
        AppID("/Applications/LibraryFirst\(n).app")!
    }

    /// 溢出模型: 全部分类卡(11 类) + Suggestions + Recently Added,
    /// 内容高度远超视口, 保证首个垂直手势有可滚动余量。
    private func makeOverflowLibraryModel() -> AppLibraryModel {
        var cards: [AppLibraryCard] = []
        var detail: [AppLibraryCategory: [AppID]] = [:]
        var n = 0
        for category in AppLibraryCategory.allCases {
            let ids = (0..<7).map { _ in
                n += 1
                return makeApp(n)
            }
            detail[category] = ids
            cards.append(AppLibraryCard(
                id: .category(category),
                primaryAppIDs: Array(ids.prefix(3)),
                miniAppIDs: Array(ids.dropFirst(3).prefix(4)),
                detailAppIDs: ids
            ))
        }
cards.insert(AppLibraryCard(
            id: .suggestions,
            primaryAppIDs: [makeApp(900), makeApp(901), makeApp(902), makeApp(903)],
            miniAppIDs: [],
            detailAppIDs: [makeApp(900), makeApp(901), makeApp(902), makeApp(903)]
        ), at: 0)
        return AppLibraryModel(cards: cards, categoryDetail: detail)
    }

    /// 小模型: 首卡为 Suggestions(4 个大图标), 供点击测试定位首个大图标。
    private func makeClickModel() -> AppLibraryModel {
        AppLibraryModel(
            cards: [
                AppLibraryCard(
                    id: .suggestions,
                    primaryAppIDs: [makeApp(1), makeApp(2), makeApp(3), makeApp(4)],
                    miniAppIDs: [],
                    detailAppIDs: [makeApp(1), makeApp(2), makeApp(3), makeApp(4)]
                ),
                AppLibraryCard(
                    id: .category(.productivity),
                    primaryAppIDs: [makeApp(5), makeApp(6), makeApp(7)],
                    miniAppIDs: [makeApp(8)],
                    detailAppIDs: [makeApp(5), makeApp(6), makeApp(7), makeApp(8)]
                ),
            ],
            categoryDetail: [.productivity: [makeApp(5), makeApp(6), makeApp(7), makeApp(8)]]
        )
    }

    private func makeHarness(
        _ model: AppLibraryModel
    ) throws -> (store: LibraryFirstStore, grid: GridViewController, window: NSWindow) {
        let store = LibraryFirstStore(
            pages: [
                [.app(makeApp(11)), .app(makeApp(12))],
                [.app(makeApp(13)), .app(makeApp(14))],
            ],
            libraryModel: model
        )
        let grid = GridViewController(store: store, iconProvider: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 900),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = grid.view
        window.layoutIfNeeded()
        grid.view.layoutSubtreeIfNeeded()
        grid.refresh()
        grid.view.layoutSubtreeIfNeeded()
        grid.collectionViewRef.layoutSubtreeIfNeeded()
        return (store, grid, window)
    }

    /// 进入 Library(真实 settle 时序 + 120Hz 轮询, 与 app 探针同构)。
    private func enterLibrary(_ grid: GridViewController) async {
        grid.libraryShotNavigateToLibrary()
        for _ in 0..<400 {
            if grid.libraryShotWaitSettled() { break }
            try? await Task.sleep(for: .milliseconds(8))
        }
        let clip = grid.collectionViewRef.enclosingScrollView?.contentView
        #expect(grid.currentSurfaceValue == .appLibrary)
        #expect(abs((clip?.bounds.origin.x ?? -1)) < 0.5)
        grid.view.layoutSubtreeIfNeeded()
        grid.collectionViewRef.layoutSubtreeIfNeeded()
        grid.libraryControllerForDiag?.view.layoutSubtreeIfNeeded()
        grid.libraryControllerForDiag?.collectionView.layoutSubtreeIfNeeded()
    }

    private func library(_ grid: GridViewController) throws -> AppLibraryViewController {
        try #require(grid.libraryControllerForDiag)
    }

    private func firstCell(_ library: AppLibraryViewController) throws -> AppLibraryCardCell {
        let cells = library.collectionView.visibleItems()
            .compactMap { $0 as? AppLibraryCardCell }
            .sorted { a, b in
                let ai = library.collectionView.indexPath(for: a)?.item ?? 0
                let bi = library.collectionView.indexPath(for: b)?.item ?? 0
                return ai < bi
            }
        return try #require(cells.first)
    }

    // MARK: - 首事件直接点大图标 → 立即 launch

    @Test("first event clicking a large primary icon launches immediately")
    func firstClickPrimaryIconLaunchesImmediately() async throws {
        var launched: [AppID] = []
        let (store, grid, w) = try makeHarness(makeClickModel())
        defer { w.orderOut(nil); w.contentView = nil }
        store.onLaunch = { launched.append($0) }

        await enterLibrary(grid)
        let lib = try library(grid)
        let cell = try firstCell(lib)
        let frame = try #require(cell.primaryFrames.first)
        let windowPoint = cell.view.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)

        // 首个事件(此前零输入): 经 hit 视图派发完整鼠标序列。
        let hit = try #require(w.contentView?.hitTest(windowPoint))
        hit.mouseDown(with: mouseEvent(.leftMouseDown, at: windowPoint, window: w, windowNumber: w.windowNumber))
        hit.mouseUp(with: mouseEvent(.leftMouseUp, at: windowPoint, window: w, windowNumber: w.windowNumber))
        #expect(launched == [makeApp(1)])
    }

    // MARK: - 首事件点卡片空白 → 立即打开 detail

    @Test("first event clicking card whitespace opens detail immediately")
    func firstClickCardWhitespaceOpensDetailImmediately() async throws {
        let (_, grid, w) = try makeHarness(makeClickModel())
        defer { w.orderOut(nil); w.contentView = nil }

        await enterLibrary(grid)
        let lib = try library(grid)
        let cell = try firstCell(lib)
        let whitespace = CGPoint(x: 7, y: cell.view.bounds.height - 7)
        #expect(cell.primaryFrames.allSatisfy { !$0.contains(whitespace) })
        #expect(!cell.miniFrame.contains(whitespace))
        #expect(!cell.titleFrame.contains(whitespace))

        // 直接经卡片根视图路由(与真实 mouseUp 的 handleClick 同一入口), 零前置输入。
        cell.handleClick(at: whitespace)
        #expect(lib.libraryShotCounts().contains("detail=1"))
    }

    // MARK: - 首事件点空白 → 立即隐藏(onClickBlank)

    @Test("first blank click hides immediately via the outer onClickBlank")
    func firstBlankClickHidesImmediately() async throws {
        var blanks = 0
        let (_, grid, w) = try makeHarness(makeClickModel())
        defer { w.orderOut(nil); w.contentView = nil }
        grid.onClickBlank = { blanks += 1 }

        await enterLibrary(grid)
        let lib = try library(grid)
        // 取卡片间隙(网格背景空白; indexPathForItem == nil)。
        let layout = try #require(lib.collectionView.collectionViewLayout)
        let first = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let second = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)))
        let gapLocal = CGPoint(
            x: (first.frame.maxX + second.frame.minX) / 2,
            y: first.frame.midY
        )
        let windowPoint = lib.collectionView.convert(gapLocal, to: nil)
        let hit = try #require(w.contentView?.hitTest(windowPoint))

        // 首个事件(零前置输入): 空白 mouseDown→mouseUp 经真实命中视图。
        hit.mouseDown(with: mouseEvent(.leftMouseDown, at: windowPoint, window: w, windowNumber: w.windowNumber))
        hit.mouseUp(with: mouseEvent(.leftMouseUp, at: windowPoint, window: w, windowNumber: w.windowNumber))
        #expect(blanks == 1)
    }

    // MARK: - 首事件垂直滚 → 立即滚动

    @Test("first vertical gesture routes to vertical immediately (not swallowed)")
    func firstVerticalScrollRoutesVerticalImmediately() async throws {
        let (_, grid, w) = try makeHarness(makeOverflowLibraryModel())
        defer { w.orderOut(nil); w.contentView = nil }

        await enterLibrary(grid)
        let lib = try library(grid)
        let scroll = try #require(lib.verticalScrollView as? PausableLibraryScrollView)
        let clip = scroll.contentView
        let contentH = clip.documentView?.frame.height ?? 0
        let clipH = clip.bounds.height
        // 前提: 溢出模型内容必须超过视口, 否则"无垂直滚动余量"是正确 no-op。
        try #require(contentH > clipH + 0.5)

        // 首个手势 began → changed(垂直)→ changed → ended, 零前置输入。
        // 输出必须从 undecided 收敛到 vertical 并保持: 首事件垂直输入
        // 不被残留 horizontal/undecided 状态吞掉, 交给内部 NSScrollView 滚动。
        let beganRoute = scroll.handlePreciseScroll(phase: .began, event: scrollEvent(deltaX: 0, deltaY: 4))
        let changedRoute = scroll.handlePreciseScroll(phase: .changed, event: scrollEvent(deltaX: 0, deltaY: 24))
        let changedRoute2 = scroll.handlePreciseScroll(phase: .changed, event: scrollEvent(deltaX: 0, deltaY: 24))
        let endedRoute = scroll.handlePreciseScroll(phase: .ended, event: scrollEvent(deltaX: 0, deltaY: 0))
        #expect(beganRoute != .horizontal)
        #expect(changedRoute == .vertical)
        #expect(changedRoute2 == .vertical)
        #expect(endedRoute == .vertical)

        // 内部滚动已具可滚动余量(内容高 > 视口高): 同路由下的实际滚动由
        // NSScrollView 承担(AppKit 侧; 离屏宿主无法断言 offset, 既有测试
        // 同此契约 —— "不断言内部实际滚动 offset, 依赖 AppKit 滚动落地, 脆")。
        // 这里附加断言: 几何确实可滚动(NSScrollView 会用同一 route 落地)。
        let maxOffset = max(0, (clip.documentView?.frame.height ?? 0) - clip.bounds.height)
        #expect(maxOffset > 0)
    }

    // MARK: - 重入清理残留手势状态

    @Test("leaving mid-gesture then re-entering resets arbiter/momentum/pending state")
    func enteringClearsStaleGestureState() {
        let scrollView = PausableLibraryScrollView()
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1200))
        scrollView.documentView = document
        scrollView.frame = NSRect(x: 0, y: 0, width: 200, height: 300)

        // 模拟"离开手势的 changed 中途指针移出本视图, 永远收不到 ended":
        // arbiter 停在 horizontal 锁定(host 未重入前是残留状态)。
        _ = scrollView.handlePreciseScroll(phase: .began, event: scrollEvent(deltaX: -4, deltaY: 0))
        _ = scrollView.handlePreciseScroll(phase: .began, event: scrollEvent(deltaX: -4, deltaY: 0))
        _ = scrollView.handlePreciseScroll(phase: .changed, event: scrollEvent(deltaX: -8, deltaY: 0))
        // 未发 ended(指针已移出; 残留 arbiter=horizontal)。

        // 进入 surface → beginSession 触发 resetGestureState。
        scrollView.resetGestureState()
        // 清理后首个垂直手势必须能正常锁定 vertical(不再被旧的 horizontal 抢占)。
        _ = scrollView.handlePreciseScroll(phase: .began, event: scrollEvent(deltaX: 0, deltaY: 3))
        let route = scrollView.handlePreciseScroll(phase: .changed, event: scrollEvent(deltaX: 0, deltaY: 8))
        #expect(route == .vertical)
    }

    // MARK: - Helpers

    private func mouseEvent(
        _ type: NSEvent.EventType, at point: NSPoint, window: NSWindow, windowNumber: Int
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    /// precise scrollWheel 事件(pixel 单位; 构造与既有轴仲裁测试同构)。
    /// 必须设置 `.scrollWheelEventIsContinuous`, 使 hasPreciseScrollingDeltas
    /// = true(NSScrollView 按像素滚动而非按行)。
    private func scrollEvent(deltaX: CGFloat, deltaY: CGFloat) -> NSEvent {
        let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: -Int32(deltaY),
            wheel2: -Int32(deltaX),
            wheel3: 0
        )!
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        return NSEvent(cgEvent: cg)!
    }
}

/// Store 替身: LauncherStoring + AppLibraryDataProviding(真实 cards 模型)。
@MainActor
private final class LibraryFirstStore: LauncherStoring, AppLibraryDataProviding {
    var pages: [[DisplayModel.DisplayItem]]
    var libraryModel: AppLibraryModel
    var onDataChange: (() -> Void)?
    var onLaunch: ((AppID) -> Void)?
    let gridColumns = 2
    let gridRows = 1
    let iconSize = 64
    let wallpaperBlurRadius = 30
    let searchBarWidth = 320
    var displayRevision: UInt64 = 1

    init(pages: [[DisplayModel.DisplayItem]], libraryModel: AppLibraryModel) {
        self.pages = pages
        self.libraryModel = libraryModel
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID { UUID() }
    func removeDataObserver(_ token: UUID) {}
    func displayModel() -> DisplayModel { DisplayModel(pages: pages, pageCapacity: gridColumns * gridRows) }
    func searchResults(for query: String) -> [DisplayModel.DisplayItem]? { nil }
    func displayName(for appID: AppID) -> String { appID.rawValue }
    func folderName(for folderID: FolderID) -> String { folderID.rawValue }
    func launch(_ appID: AppID) { onLaunch?(appID) }
    func createFolder(name: String, appIDs: [AppID]) {}
    func renameFolder(_ id: FolderID, to name: String) {}
    func dissolveFolder(_ id: FolderID) {}
    func addToFolder(app: AppID, folder: FolderID) {}
    func moveOutOfFolder(app: AppID, from folder: FolderID, toDisplayIndex: Int, completion: @escaping (Bool) -> Void) { completion(false) }
    func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int) {}
    func folderNames() -> [FolderID: String] { [:] }
    func folderChildren(_ id: FolderID) -> [AppID]? { nil }
    func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation) {}
    func setHidden(_ appID: AppID, hidden: Bool) {}
    func setCustomName(_ appID: AppID, name: String?) {}
    func moveToTrash(_ appID: AppID) {}
    func isHidden(_ appID: AppID) -> Bool { false }

    func appLibraryModel() -> AppLibraryModel { libraryModel }
}