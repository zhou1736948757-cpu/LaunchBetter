import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

/// 任务包 V3: 三指拖 App → 分类卡(重分类)。
///
/// 覆盖 A21 必写清单: 路由矩阵 / 源命中(仅 large primary) / hover 高亮 /
/// drop 保存覆盖 / 同分类 no-op / 空白 cancel / 拖拽期滚动与翻页挂起及恢复 /
/// 无 LayoutStore 变更。
@Suite("App Library 三指重分类拖拽", .serialized)
@MainActor
struct AppLibraryReclassificationDragTests {
    private let p1 = AppID("/Applications/Pencil.app")!
    private let p2 = AppID("/Applications/Paper.app")!
    private let p3 = AppID("/Applications/Prism.app")!
    private let s1 = AppID("/Applications/Signal.app")!
    private let s2 = AppID("/Applications/Slate.app")!
    private let a1 = AppID("/Applications/Alpha.app")!
    private let r1 = AppID("/Applications/Red.app")!

    // MARK: - 模型

    /// 与 `AppLibraryViewTests.makeModel` 同构, 但补全 `categoryDetail` 分区
    /// (生产不变量: 每个可见 app 恰好属于一个分类; 源命中依赖该反查)。
    private func makeModel() -> AppLibraryModel {
        AppLibraryModel(
            cards: [
                AppLibraryCard(
                    id: .suggestions,
                    primaryAppIDs: [a1],
                    miniAppIDs: [],
                    detailAppIDs: [a1]
                ),
                AppLibraryCard(
                    id: .recentlyAdded,
                    primaryAppIDs: [r1],
                    miniAppIDs: [],
                    detailAppIDs: [r1]
                ),
                AppLibraryCard(
                    id: .category(.productivity),
                    primaryAppIDs: [p1, p2, p3],
                    miniAppIDs: [],
                    detailAppIDs: [p1, p2, p3]
                ),
                AppLibraryCard(
                    id: .category(.social),
                    primaryAppIDs: [s1],
                    miniAppIDs: [s2],
                    detailAppIDs: [s1, s2]
                ),
            ],
            categoryDetail: [
                .productivity: [p1, p2, p3],
                .social: [s1, s2],
                .utilities: [a1],
                .entertainment: [r1],
            ]
        )
    }

    // MARK: - 路由矩阵(A11)

    @Test("路由矩阵: .launcher → 既有 DragController; .appLibrary → 重分类; 其余阻塞")
    func routeMatrixDispatch() {
        #expect(ThreeFingerDragRoute.make(for: .launcher) == .gridDrag)
        #expect(ThreeFingerDragRoute.make(for: .appLibrary) == .libraryReclassification)
        #expect(ThreeFingerDragRoute.make(for: .settings) == .blocked)
        #expect(ThreeFingerDragRoute.make(for: .appLibraryCategory) == .blocked)
        #expect(ThreeFingerDragRoute.make(for: .folder) == .blocked)
    }

    // MARK: - 源命中(A13)

    @Test(".appLibrary + 指针在大图标 → begin 重分类; overlay 挂载; 滚动挂起")
    func primaryIconBeginsReclassification() throws {
        let store = FakeCategoryOverridingStore()
        let controller = makeController(store: store)
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let point = try windowPoint(ofPrimaryApp: p1, in: controller)
        let began = controller.beginReclassificationDrag(at: point)
        #expect(began)
        #expect(controller.isReclassificationDragging)
        #expect(controller.reclassificationDragStateForDiag.contains("overlay=1"))
        #expect(isScrollPaused(controller))
    }

    @Test("源命中仅 large primary: mini / 标题 / 空白 / detail 打开均不启动")
    func nonPrimaryAreasDoNotBegin() throws {
        let controller = makeController(store: FakeCategoryOverridingStore())
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let socialCell = try #require(
            cardCells(controller).first { $0.cardID == .category(.social) }
        )
        let mini = socialCell.view.convert(
            CGPoint(x: socialCell.miniFrame.midX, y: socialCell.miniFrame.midY), to: nil
        )
        #expect(!controller.beginReclassificationDrag(at: mini))

        let title = socialCell.view.convert(
            CGPoint(x: socialCell.titleFrame.midX, y: socialCell.titleFrame.midY), to: nil
        )
        #expect(!controller.beginReclassificationDrag(at: title))

        let blank = try blankPoint(in: controller)
        #expect(!controller.beginReclassificationDrag(at: blank))
        #expect(!controller.isReclassificationDragging)
        #expect(!isScrollPaused(controller))

        // detail 打开期间不启动(源命中 gate 第一道)。
        try openProductivityDetail(in: controller)
        let primary = try windowPoint(ofPrimaryApp: p1, in: controller)
        #expect(!controller.beginReclassificationDrag(at: primary))
        controller.presentedDetail?.handleEscape()
    }

    // MARK: - hover 高亮(A18)

    @Test("悬停有效分类卡 → 高亮; 同分类 / Suggestions / Recently Added 不高亮")
    func hoverHighlightsValidCategoryCardOnly() throws {
        let controller = makeController(store: FakeCategoryOverridingStore())
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let source = try windowPoint(ofPrimaryApp: p1, in: controller)
        #expect(controller.beginReclassificationDrag(at: source))

        // 悬停 social(不同分类) → 高亮。
        let socialPoint = try windowPoint(ofPrimaryApp: s1, in: controller)
        controller.updateReclassificationDrag(at: socialPoint)
        #expect(controller.reclassificationDragHoveredCategoryForDiag == .social)
        let socialCell = try #require(
            cardCells(controller).first { $0.cardID == .category(.social) }
        )
        #expect(socialCell.reclassificationHoverActive)

        // 悬停同分类(productivity) → 清除高亮。
        let sameCategoryPoint = try windowPoint(ofPrimaryApp: p2, in: controller)
        controller.updateReclassificationDrag(at: sameCategoryPoint)
        #expect(controller.reclassificationDragHoveredCategoryForDiag == nil)
        #expect(!socialCell.reclassificationHoverActive)

        // 悬停 Suggestions / Recently Added(非分类卡) → 不高亮。
        let suggestionsPoint = try windowPoint(ofPrimaryApp: a1, in: controller)
        controller.updateReclassificationDrag(at: suggestionsPoint)
        #expect(controller.reclassificationDragHoveredCategoryForDiag == nil)
        let suggestionsCell = try #require(
            cardCells(controller).first { $0.cardID == .suggestions }
        )
        #expect(!suggestionsCell.reclassificationHoverActive)

        let recentlyPoint = try windowPoint(ofPrimaryApp: r1, in: controller)
        controller.updateReclassificationDrag(at: recentlyPoint)
        #expect(controller.reclassificationDragHoveredCategoryForDiag == nil)

        controller.cancelReclassificationDrag()
        #expect(!controller.isReclassificationDragging)
        #expect(!socialCell.reclassificationHoverActive)
    }

    // MARK: - drop / cancel 语义(A15/A16/A17)

    @Test("drop 到 Social 卡 → setCategoryOverride 保存; 拖拽结束; 滚动恢复")
    func dropOnSocialSavesOverride() async throws {
        let store = FakeCategoryOverridingStore()
        let controller = makeController(store: store)
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let source = try windowPoint(ofPrimaryApp: p1, in: controller)
        #expect(controller.beginReclassificationDrag(at: source))
        #expect(isScrollPaused(controller))

        let socialPoint = try windowPoint(ofPrimaryApp: s1, in: controller)
        controller.updateReclassificationDrag(at: socialPoint)
        controller.endReclassificationDrag(at: socialPoint)
        await drainMainActor()

        #expect(store.setCalls.count == 1 && store.setCalls[0].0 == p1 && store.setCalls[0].1 == .social)
        #expect(store.categoryOverrides == [p1: .social])
        #expect(!controller.isReclassificationDragging)
        #expect(!isScrollPaused(controller))
        #expect(controller.reclassificationDragStateForDiag.contains("overlay=0"))
    }

    @Test("同分类 drop → no-op(不保存覆盖、不高亮、立即恢复)")
    func sameCategoryDropIsNoOp() async throws {
        let store = FakeCategoryOverridingStore()
        let controller = makeController(store: store)
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let source = try windowPoint(ofPrimaryApp: p1, in: controller)
        #expect(controller.beginReclassificationDrag(at: source))

        let samePoint = try windowPoint(ofPrimaryApp: p2, in: controller)
        controller.updateReclassificationDrag(at: samePoint)
        #expect(controller.reclassificationDragHoveredCategoryForDiag == nil)

        controller.endReclassificationDrag(at: samePoint)
        await drainMainActor()

        #expect(store.setCalls.isEmpty)
        #expect(store.categoryOverrides.isEmpty)
        #expect(!controller.isReclassificationDragging)
        #expect(!isScrollPaused(controller))
    }

    @Test("drop 到空白 → cancel 无变更")
    func blankDropCancelsWithoutChanges() async throws {
        let store = FakeCategoryOverridingStore()
        let controller = makeController(store: store)
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let source = try windowPoint(ofPrimaryApp: p1, in: controller)
        #expect(controller.beginReclassificationDrag(at: source))

        let blank = try blankPoint(in: controller)
        controller.updateReclassificationDrag(at: blank)
        #expect(controller.reclassificationDragHoveredCategoryForDiag == nil)
        controller.endReclassificationDrag(at: blank)
        await drainMainActor()

        #expect(store.setCalls.isEmpty)
        #expect(store.categoryOverrides.isEmpty)
        #expect(!controller.isReclassificationDragging)
        #expect(!isScrollPaused(controller))
        #expect(controller.reclassificationDragStateForDiag.contains("overlay=0"))
    }

    @Test("cancel → 无变更; 滚动与状态恢复")
    func cancelRestoresWithoutChanges() async throws {
        let store = FakeCategoryOverridingStore()
        let controller = makeController(store: store)
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let source = try windowPoint(ofPrimaryApp: p1, in: controller)
        #expect(controller.beginReclassificationDrag(at: source))
        #expect(isScrollPaused(controller))

        let socialPoint = try windowPoint(ofPrimaryApp: s1, in: controller)
        controller.updateReclassificationDrag(at: socialPoint)
        controller.cancelReclassificationDrag()
        await drainMainActor()

        #expect(store.setCalls.isEmpty)
        #expect(!controller.isReclassificationDragging)
        #expect(!isScrollPaused(controller))
        #expect(controller.reclassificationDragStateForDiag.contains("overlay=0"))
    }

    // MARK: - 拖拽期滚动/翻页挂起(A19)

    @Test("拖拽激活 → 垂直滚动阻塞; end → 恢复")
    func verticalScrollSuspendedDuringDragAndRestored() throws {
        let controller = makeController(store: FakeCategoryOverridingStore())
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let scroll = try #require(
            controller.verticalScrollView as? PausableLibraryScrollView
        )
        let document = try #require(scroll.documentView)
        let source = try windowPoint(ofPrimaryApp: p1, in: controller)

        #expect(controller.beginReclassificationDrag(at: source))
        #expect(scroll.isScrollPaused)
        let before = document.bounds.origin
        // 拖拽激活: 垂直事件被 paused gate 消费(不滚动、不污染仲裁器)。
        scroll.scrollWheel(with: scrollEvent(deltaX: 0, deltaY: -80))
        scroll.scrollWheel(with: scrollEvent(deltaX: 0, deltaY: -80))
        #expect(document.bounds.origin == before)

        controller.endReclassificationDrag(at: source)
        #expect(!scroll.isScrollPaused)
        #expect(!controller.isReclassificationDragging)
        // 恢复后事件重新进入路由(离屏宿主下 NSClipView 不产生可见位移,
        // 交付恢复由水平测试的同一条 scrollWheel gate 断言)。
    }

    @Test("拖拽激活 → Library 水平翻页阻塞; end → 恢复")
    func horizontalPagingSuspendedDuringDragAndRestored() throws {
        var horizontalCalls = 0
        let controller = makeController(store: FakeCategoryOverridingStore())
        controller.onHorizontalScroll = { _ in
            horizontalCalls += 1
            return true
        }
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let scroll = try #require(
            controller.verticalScrollView as? PausableLibraryScrollView
        )
        let horizontal = scrollEvent(deltaX: -80, deltaY: 0)
        // 前置: 未拖拽时水平手势交付外层分页(唯一 paging seam)。
        scroll.scrollWheel(with: horizontal)
        #expect(horizontalCalls == 1)

        let source = try windowPoint(ofPrimaryApp: p1, in: controller)
        #expect(controller.beginReclassificationDrag(at: source))

        scroll.scrollWheel(with: scrollEvent(deltaX: -80, deltaY: 0))
        scroll.scrollWheel(with: scrollEvent(deltaX: -40, deltaY: 0))
        #expect(horizontalCalls == 1)

        controller.endReclassificationDrag(at: source)
        scroll.scrollWheel(with: scrollEvent(deltaX: -80, deltaY: 0))
        #expect(horizontalCalls == 2)
    }

    // MARK: - 无 LayoutStore 变更

    @Test("drop 只写覆盖 store; 控制器模型与卡片布局零变更(不进 LayoutStore)")
    func dropDoesNotTouchLayoutStore() async throws {
        let store = FakeCategoryOverridingStore()
        let controller = makeController(store: store)
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let modelBefore = controller.modelForDiag
        let cardsBefore = cardCells(controller).compactMap(\.cardID)

        let source = try windowPoint(ofPrimaryApp: p1, in: controller)
        #expect(controller.beginReclassificationDrag(at: source))
        let socialPoint = try windowPoint(ofPrimaryApp: s1, in: controller)
        controller.endReclassificationDrag(at: socialPoint)
        await drainMainActor()

        #expect(store.setCalls.count == 1 && store.setCalls[0].0 == p1 && store.setCalls[0].1 == .social)
        // 拖拽本身不驱动任何模型/布局变更: 热刷新由宿主 store 通知链路负责,
        // 本控制器只触发覆盖写入, 不触碰 LayoutStore / LayoutSnapshot / 网格身份。
        #expect(controller.modelForDiag == modelBefore)
        #expect(cardCells(controller).compactMap(\.cardID) == cardsBefore)
    }

    // MARK: - Helpers

    private func isScrollPaused(_ controller: AppLibraryViewController) -> Bool {
        (controller.verticalScrollView as? PausableLibraryScrollView)?.isScrollPaused ?? false
    }

    private func makeController(store: FakeCategoryOverridingStore) -> AppLibraryViewController {
        AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in },
            categoryOverriding: store
        )
    }

    private func host(
        _ controller: NSViewController,
        size: NSSize = NSSize(width: 1200, height: 800)
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private func cardCells(_ controller: AppLibraryViewController) -> [AppLibraryCardCell] {
        let visible: [NSCollectionViewItem] = controller.collectionView.visibleItems()
        let typed: [(index: Int, cell: AppLibraryCardCell)] = visible.compactMap { item in
            guard let cell = item as? AppLibraryCardCell,
                  let indexPath = controller.collectionView.indexPath(for: item)
            else { return nil }
            return (index: indexPath.item, cell: cell)
        }
        return typed.sorted { $0.index < $1.index }.map(\.cell)
    }

    /// 返回指定 app 主区大图标中心的窗口坐标点。
    private func windowPoint(
        ofPrimaryApp appID: AppID,
        in controller: AppLibraryViewController
    ) throws -> NSPoint {
        let cell = try #require(
            cardCells(controller).first { $0.primaryAppIDs.contains(appID) }
        )
        let index = try #require(cell.primaryAppIDs.firstIndex(of: appID))
        let frame = cell.primaryFrames[index]
        return cell.view.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
    }

    /// 网格内一个"真空白"点的窗口坐标(不在任何卡片 frame 内)。
    private func blankPoint(in controller: AppLibraryViewController) throws -> NSPoint {
        let collectionView = controller.collectionView
        let layout = try #require(collectionView.collectionViewLayout)
        let count = collectionView.numberOfItems(inSection: 0)
        let frames = (0..<count).compactMap {
            layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame
        }
        let bounds = collectionView.bounds
        let maxCardY = frames.map(\.maxY).max() ?? 0
        let candidate = CGPoint(x: bounds.midX, y: maxCardY + 4)
        let point = try #require(
            bounds.contains(candidate) && frames.allSatisfy { !$0.contains(candidate) }
                ? candidate : nil
        )
        return collectionView.convert(point, to: nil)
    }

    private func openProductivityDetail(in controller: AppLibraryViewController) throws {
        let cell = try #require(
            cardCells(controller).first { $0.cardID == .category(.productivity) }
        )
        let title = cell.titleFrame
        cell.handleClick(at: CGPoint(x: title.midX, y: title.midY))
        controller.view.window?.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.presentedDetail != nil)
    }

    /// 构造 precise scrollWheel 事件(pixel 单位; 无 phase, 与轴仲裁测试一致)。
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

    private func drainMainActor() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        for _ in 0..<5 { await Task.yield() }
    }
}

/// 可控分类覆盖 store(PA2 同型测试替身, 本文件私有)。
@MainActor
private final class FakeCategoryOverridingStore: AppLibraryCategoryOverriding {
    var categoryOverrides: [AppID: AppLibraryCategory] = [:]
    var setCalls: [(AppID, AppLibraryCategory)] = []
    var clearCalls: [AppID] = []

    func setCategoryOverride(appID: AppID, category: AppLibraryCategory) async {
        setCalls.append((appID, category))
        categoryOverrides[appID] = category
    }

    func clearCategoryOverride(appID: AppID) async {
        clearCalls.append(appID)
        categoryOverrides.removeValue(forKey: appID)
    }
}
