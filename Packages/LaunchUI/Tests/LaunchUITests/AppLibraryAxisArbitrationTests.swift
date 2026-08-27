import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

/// Stage E9b: App Library 垂直/水平滚轮轴仲裁。
///
/// 覆盖: 主导轴锁定不可被后续 burst 抢回、diagonal/低于阈值保持 undecided 无抖动、
/// ended/reset 后可重新选轴、detail paused 消费所有 scroll(E9a gate 优先级最高)、
/// 水平路由复用外层 PagingInteractionController 单一引擎(无第二 writer/第二 settle)。
///
/// 合成 CGEvent 的 phase 字段在本 SDK 不可靠往返(NSEvent.Phase.rawValue 与
/// CGEvent scroll-phase 字段编码不一致), 滚动视图断言全部 phase 无关:
/// 手势级轴仲裁由纯逻辑 `AppLibraryAxisArbiter` 测试覆盖, 滚动视图只验证
/// paused gate / 逐事件主导轴路由 / handler-false 消费契约。
@Suite("App Library axis arbitration", .serialized)
@MainActor
struct AppLibraryAxisArbitrationTests {
    // MARK: - 纯逻辑仲裁器

    @Test("dominant horizontal locks; later vertical burst cannot take back")
    func horizontalLockSurvivesVerticalBurst() {
        var arbiter = AppLibraryAxisArbiter()
        arbiter.begin()
        // 逐事件小样本累计, 未达阈值前 undecided。
        #expect(arbiter.accumulate(deltaX: 2, deltaY: 0) == .undecided)
        #expect(arbiter.accumulate(deltaX: 2, deltaY: 0) == .undecided)
        #expect(arbiter.accumulate(deltaX: 2, deltaY: 0) == .undecided)
        // 累计 8pt > 6pt → 锁定 horizontal。
        #expect(arbiter.accumulate(deltaX: 2, deltaY: 0) == .horizontal)
        // 后续 vertical burst 不能抢回 owner。
        #expect(arbiter.accumulate(deltaX: 0, deltaY: 30) == .horizontal)
        #expect(arbiter.accumulate(deltaX: 0, deltaY: 60) == .horizontal)
        #expect(arbiter.route == .horizontal)
    }

    @Test("dominant vertical locks; later horizontal burst cannot take back")
    func verticalLockSurvivesHorizontalBurst() {
        var arbiter = AppLibraryAxisArbiter()
        arbiter.begin()
        #expect(arbiter.accumulate(deltaX: 0, deltaY: 3) == .undecided)
        #expect(arbiter.accumulate(deltaX: 0, deltaY: 3) == .undecided)
        // 累计 9pt > 6pt → 锁定 vertical。
        #expect(arbiter.accumulate(deltaX: 0, deltaY: 3) == .vertical)
        // 后续 horizontal burst 不能抢回 owner。
        #expect(arbiter.accumulate(deltaX: 40, deltaY: 0) == .vertical)
        #expect(arbiter.accumulate(deltaX: 80, deltaY: 0) == .vertical)
        #expect(arbiter.route == .vertical)
    }

    @Test("below threshold and diagonal stay undecided without route jitter")
    func belowThresholdAndDiagonalStayUndecided() {
        // 低于激活阈值: 恒 undecided, 不抖动。
        var tiny = AppLibraryAxisArbiter()
        tiny.begin()
        #expect(tiny.accumulate(deltaX: 1, deltaY: 1) == .undecided)
        #expect(tiny.accumulate(deltaX: -1, deltaY: 1) == .undecided)
        #expect(tiny.route == .undecided)

        // 45° diagonal: 总 |X| == |Y|, 永不满足 dominance → 恒 undecided。
        var diagonal = AppLibraryAxisArbiter()
        diagonal.begin()
        for _ in 0..<10 {
            #expect(diagonal.accumulate(deltaX: 4, deltaY: 4) == .undecided)
        }
        #expect(diagonal.route == .undecided)
        // diagonal 后明显 vertical 主导 → 才锁定 vertical。
        #expect(diagonal.accumulate(deltaX: -2, deltaY: 30) == .vertical)
    }

    @Test("ended/reset returns to idle and the next gesture re-picks its axis")
    func endedResetsAndNextGestureRePicksAxis() {
        var arbiter = AppLibraryAxisArbiter()
        arbiter.begin()
        _ = arbiter.accumulate(deltaX: 20, deltaY: 0)
        #expect(arbiter.route == .horizontal)
        arbiter.end()
        #expect(arbiter.route == .undecided)
        arbiter.begin()
        #expect(arbiter.accumulate(deltaX: 0, deltaY: 20) == .vertical)
        arbiter.reset()
        #expect(arbiter.route == .undecided)
        arbiter.begin()
        #expect(arbiter.accumulate(deltaX: 20, deltaY: 0) == .horizontal)
    }

    // MARK: - 滚动路由(PausableLibraryScrollView)

    @Test("paused consumes all scroll: neither local scroll nor outer handler")
    func pausedConsumesAllScroll() {
        let scrollView = makeLibraryScrollView()
        var horizontalCalls = 0
        scrollView.onHorizontalScroll = { _ in
            horizontalCalls += 1
            return true
        }
        let window = host(scrollView)
        defer { window.orderOut(nil); window.contentView = nil }
        window.layoutIfNeeded()

        let clip = scrollView.contentView
        let before = clip.bounds.origin

        scrollView.isScrollPaused = true
        // 垂直输入: 内部滚动被暂停(E9a gate)。
        scrollView.scrollWheel(with: scrollEvent(deltaX: 0, deltaY: -40))
        scrollView.scrollWheel(with: scrollEvent(deltaX: 0, deltaY: -60))
        scrollView.scrollWheel(with: scrollEvent(deltaX: 0, deltaY: 0))
        // 水平输入: 同样不交给 outer handler。
        scrollView.scrollWheel(with: scrollEvent(deltaX: -50, deltaY: 0))
        scrollView.scrollWheel(with: scrollEvent(deltaX: -80, deltaY: 0))
        scrollView.scrollWheel(with: scrollEvent(deltaX: 0, deltaY: 0))

        #expect(horizontalCalls == 0)
        #expect(clip.bounds.origin == before)
    }

    @Test("vertical input never touches the horizontal handler; arbiter locks vertical")
    func verticalInputNeverTouchesHorizontalHandler() {
        let scrollView = makeLibraryScrollView()
        var horizontalCalls = 0
        scrollView.onHorizontalScroll = { _ in
            horizontalCalls += 1
            return true
        }
        let window = host(scrollView)
        defer { window.orderOut(nil); window.contentView = nil }
        window.layoutIfNeeded()

        // 垂直主导输入: 路由留在内部(phase-less 逐事件决定性), 不触外层 handler。
        // 不断言内部实际滚动 offset(依赖 AppKit 滚动落地, 脆); 只断言
        // no-horizontal-callback 与下方仲裁器的 vertical 源契约。
        scrollView.scrollWheel(with: scrollEvent(deltaX: 0, deltaY: -40))
        scrollView.scrollWheel(with: scrollEvent(deltaX: 0, deltaY: -60))
        scrollView.scrollWheel(with: scrollEvent(deltaX: 0, deltaY: -60))
        #expect(horizontalCalls == 0)

        // 源契约: 同一输入序列经仲裁器累计 → vertical 锁定(纯逻辑)。
        var arbiter = AppLibraryAxisArbiter()
        arbiter.begin()
        _ = arbiter.accumulate(deltaX: 0, deltaY: -40)
        _ = arbiter.accumulate(deltaX: 0, deltaY: -60)
        _ = arbiter.accumulate(deltaX: 0, deltaY: -60)
        #expect(arbiter.route == .vertical)
    }

    @Test("horizontal-dominant input delivers to the outer handler; handler-false still consumes")
    func horizontalInputDeliversToHandlerAndHandlerFalseConsumes() {
        let scrollView = makeLibraryScrollView()
        var horizontalCalls = 0
        scrollView.onHorizontalScroll = { _ in
            horizontalCalls += 1
            return true
        }
        let window = host(scrollView)
        defer { window.orderOut(nil); window.contentView = nil }
        window.layoutIfNeeded()

        // 水平主导输入 → outer handler 收到事件(不依赖 phase 往返)。
        scrollView.scrollWheel(with: scrollEvent(deltaX: -30, deltaY: 2))
        scrollView.scrollWheel(with: scrollEvent(deltaX: -60, deltaY: 5))
        #expect(horizontalCalls == 2)

        // handler 返回 false: 已判 horizontal 的事件仍被消费, 不落回垂直滚动,
        // 本地 clip(宽 400)不得产生任何方向运动。
        let clip = scrollView.contentView
        let before = clip.bounds.origin
        var falseHandlerCalls = 0
        scrollView.onHorizontalScroll = { _ in
            falseHandlerCalls += 1
            return false
        }
        scrollView.scrollWheel(with: scrollEvent(deltaX: -60, deltaY: 0))
        scrollView.scrollWheel(with: scrollEvent(deltaX: -40, deltaY: 1))
        #expect(falseHandlerCalls == 2)
        #expect(clip.bounds.origin == before)
    }

    // MARK: - 未决 began 重放(phase 注入 seam)

    @Test("undecided began is replayed before the first horizontal changed, then cleared")
    func pendingBeganReplayedBeforeFirstHorizontalChanged() {
        let scrollView = makeLibraryScrollView()
        var receivedAbsDeltas: [CGFloat] = []
        scrollView.onHorizontalScroll = { event in
            receivedAbsDeltas.append(abs(event.scrollingDeltaX))
            return true
        }
        let window = host(scrollView)
        defer { window.orderOut(nil); window.contentView = nil }
        window.layoutIfNeeded()

        // began 携带小位移(undecided)→ 暂存; 三次 changed 未达阈值, 不外送。
        scrollView.handlePreciseScroll(phase: .began, event: scrollEvent(deltaX: -2, deltaY: -1))
        scrollView.handlePreciseScroll(phase: .changed, event: scrollEvent(deltaX: -1, deltaY: -1))
        scrollView.handlePreciseScroll(phase: .changed, event: scrollEvent(deltaX: -2, deltaY: -1))
        #expect(receivedAbsDeltas.isEmpty)

        // 累计 |X|=8 > 6 且 8 > |Y|=4 * 1.2 → 锁定 horizontal:
        // 先重放 began(|dx|=2)再交付首个 horizontal changed(|dx|=3)。
        scrollView.handlePreciseScroll(phase: .changed, event: scrollEvent(deltaX: -3, deltaY: -1))
        #expect(receivedAbsDeltas == [2, 3])

        // 已锁定: 后续 changed / ended 照常交付, 不重复重放。
        scrollView.handlePreciseScroll(phase: .changed, event: scrollEvent(deltaX: -5, deltaY: 0))
        scrollView.handlePreciseScroll(phase: .ended, event: scrollEvent(deltaX: 0, deltaY: 0))
        #expect(receivedAbsDeltas == [2, 3, 5, 0])

        // 下一手势重新仲裁: 重放的是新手势自己的 began。
        scrollView.handlePreciseScroll(phase: .began, event: scrollEvent(deltaX: -6, deltaY: -2))
        scrollView.handlePreciseScroll(phase: .changed, event: scrollEvent(deltaX: -7, deltaY: -1))
        #expect(receivedAbsDeltas == [2, 3, 5, 0, 6, 7])
    }

    @Test("pending began is discarded on vertical lock or undecided end")
    func pendingBeganDiscardedOnVerticalLockOrUndecidedEnd() {
        let scrollView = makeLibraryScrollView()
        var horizontalCalls = 0
        scrollView.onHorizontalScroll = { _ in
            horizontalCalls += 1
            return true
        }
        let window = host(scrollView)
        defer { window.orderOut(nil); window.contentView = nil }
        window.layoutIfNeeded()

        // began undecided → vertical 锁定(|Y|=7 > 6 且 7 > 2*1.2)→ ended:
        // began 从未交付外层。
        scrollView.handlePreciseScroll(phase: .began, event: scrollEvent(deltaX: -1, deltaY: -2))
        scrollView.handlePreciseScroll(phase: .changed, event: scrollEvent(deltaX: -1, deltaY: -6))
        scrollView.handlePreciseScroll(phase: .ended, event: scrollEvent(deltaX: 0, deltaY: 0))
        #expect(horizontalCalls == 0)

        // 下一手势 began undecided → ended 仍 undecided: 丢弃。
        scrollView.handlePreciseScroll(phase: .began, event: scrollEvent(deltaX: -1, deltaY: -1))
        scrollView.handlePreciseScroll(phase: .ended, event: scrollEvent(deltaX: -1, deltaY: -1))
        #expect(horizontalCalls == 0)

        // 再下一手势 began 即锁定 horizontal: 立即交付(began 不暂存),
        // 前两次未决 began 均未泄漏。
        scrollView.handlePreciseScroll(phase: .began, event: scrollEvent(deltaX: -8, deltaY: -1))
        scrollView.handlePreciseScroll(phase: .changed, event: scrollEvent(deltaX: -9, deltaY: -1))
        #expect(horizontalCalls == 2)
    }

    @Test("paused mid-gesture clears pending began; next gesture replays its own began")
    func pausedClearsPendingBegan() {
        let scrollView = makeLibraryScrollView()
        var receivedAbsDeltas: [CGFloat] = []
        scrollView.onHorizontalScroll = { event in
            receivedAbsDeltas.append(abs(event.scrollingDeltaX))
            return true
        }
        let window = host(scrollView)
        defer { window.orderOut(nil); window.contentView = nil }
        window.layoutIfNeeded()

        // began undecided → 暂存; 暂停 gate 触发时清除未决 began(E9a 优先级最高)。
        scrollView.handlePreciseScroll(phase: .began, event: scrollEvent(deltaX: -2, deltaY: -1))
        scrollView.isScrollPaused = true
        scrollView.scrollWheel(with: scrollEvent(deltaX: 0, deltaY: 0))
        scrollView.isScrollPaused = false

        // 新手势锁定 horizontal 后: 重放的必须是新 began(|dx|=4),
        // 不是暂停前的旧 began(|dx|=2)。
        scrollView.handlePreciseScroll(phase: .began, event: scrollEvent(deltaX: -4, deltaY: -1))
        scrollView.handlePreciseScroll(phase: .changed, event: scrollEvent(deltaX: -5, deltaY: -1))
        #expect(receivedAbsDeltas == [4, 5])
    }

    // MARK: - Grid 窄方法(同一分页引擎)

    @Test("grid horizontal library scroll reuses the single paging seam")
    func gridReusesSinglePagingSeam() {
        let store = LibraryAxisTestStore()
        let grid = GridViewController(store: store, iconProvider: nil)
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
        grid.collectionViewRef.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil); window.contentView = nil }

        // 普通 Launcher 面: guard 拒绝(普通页输入路径不改变)。
        #expect(grid.currentSurfaceValue == .layoutPage(0))
        #expect(!grid.handleAppLibraryHorizontalScroll(scrollEvent(deltaX: -10, deltaY: 0)))

        // Library 面: 消费(返回 true), 事件不驱动任何动态 settle(表面状态稳定,
        // 不依赖 phase 往返/display link tick)。
        grid.previousPage()
        #expect(grid.currentSurfaceValue == .appLibrary)
        #expect(grid.handleAppLibraryHorizontalScroll(scrollEvent(deltaX: -10, deltaY: 0)))
        #expect(grid.handleAppLibraryHorizontalScroll(scrollEvent(deltaX: -120, deltaY: 0)))
        #expect(grid.currentSurfaceValue == .appLibrary)
        #expect(grid.physicalSurfaceIndex == 0)

        // 同一分页引擎(唯一 settle 引擎): 经确定性 seam(pagingProbeGesture)
        // 驱动 Library 面 → Page1, 不创建第二套 writer/settle。
        grid.pagingProbeGesture(deltaXs: [-120])
        #expect(grid.currentSurfaceValue == .layoutPage(1))
        #expect(grid.currentPageValue == 1)
        #expect(grid.physicalSurfaceIndex == 2)
    }

    // MARK: - Helpers

    private func makeLibraryScrollView() -> PausableLibraryScrollView {
        let scrollView = PausableLibraryScrollView()
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1200))
        scrollView.documentView = document
        scrollView.frame = NSRect(x: 0, y: 0, width: 200, height: 300)
        return scrollView
    }

    private func host(_ scrollView: NSScrollView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        return window
    }

    /// 构造 precise scrollWheel 事件(pixel 单位)。
    /// 不构造 phase: 本 SDK 下 NSEvent.Phase.rawValue 与 CGEvent scroll-phase
    /// 字段编码不一致, 合成事件 phase 往返不可靠; 滚动视图对 phase-less 输入
    /// 逐事件按主导轴决定性路由(断言只依赖该路径与纯逻辑仲裁器)。
    private func scrollEvent(deltaX: CGFloat, deltaY: CGFloat) -> NSEvent {
        let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: -Int32(deltaY),
            wheel2: -Int32(deltaX),
            wheel3: 0
        )!
        return NSEvent(cgEvent: cg)!
    }
}

/// Grid 窄方法测试存储(3 普通页 + AppLibraryDataProviding)。
@MainActor
private final class LibraryAxisTestStore: LauncherStoring, AppLibraryDataProviding {
    var searchResultsValue: [DisplayModel.DisplayItem]?
    var revision: UInt64 = 1

    var onDataChange: (() -> Void)?
    let gridColumns = 2
    let gridRows = 1
    let iconSize = 64
    let wallpaperBlurRadius = 30
    let searchBarWidth = 320
    var displayRevision: UInt64 { revision }

    private let pages: [[DisplayModel.DisplayItem]] = (0..<3).map { page in
        [
            .app(AppID("/Applications/AxisA\(page).app")!),
            .app(AppID("/Applications/AxisB\(page).app")!),
        ]
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID { UUID() }

    func removeDataObserver(_ token: UUID) {}

    func displayModel() -> DisplayModel {
        DisplayModel(pages: pages, pageCapacity: gridColumns * gridRows)
    }

    func searchResults(for query: String) -> [DisplayModel.DisplayItem]? { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : searchResultsValue }
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

    func appLibraryModel() -> AppLibraryModel {
        AppLibraryModel(cards: [], categoryDetail: [:])
    }
}
