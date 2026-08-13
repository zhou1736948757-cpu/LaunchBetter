import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("App Library view", .serialized)
@MainActor
struct AppLibraryViewTests {
    private let a1 = AppID("/Applications/Alpha.app")!
    private let a2 = AppID("/Applications/Alto.app")!
    private let a3 = AppID("/Applications/Arlo.app")!
    private let r1 = AppID("/Applications/Red.app")!
    private let r2 = AppID("/Applications/Reed.app")!
    private let r3 = AppID("/Applications/Rose.app")!
    private let r4 = AppID("/Applications/Ruth.app")!
    private let p1 = AppID("/Applications/Pencil.app")!
    private let p2 = AppID("/Applications/Paper.app")!
    private let p3 = AppID("/Applications/Prism.app")!
    private let p4 = AppID("/Applications/Pulse.app")!
    private let s1 = AppID("/Applications/Signal.app")!
    private let s2 = AppID("/Applications/Slate.app")!

    // MARK: - 模型

    private func makeModel() -> AppLibraryModel {
        AppLibraryModel(
            cards: [
                AppLibraryCard(
                    id: .suggestions,
                    primaryAppIDs: [a1, a2, a3],
                    miniAppIDs: [],
                    detailAppIDs: [a1, a2, a3]
                ),
                AppLibraryCard(
                    id: .recentlyAdded,
                    primaryAppIDs: [r1, r2, r3],
                    miniAppIDs: [r4],
                    detailAppIDs: [r1, r2, r3, r4]
                ),
                AppLibraryCard(
                    id: .category(.productivity),
                    primaryAppIDs: [p1, p2, p3],
                    miniAppIDs: [p4],
                    detailAppIDs: [p1, p2, p3, p4]
                ),
                AppLibraryCard(
                    id: .category(.social),
                    primaryAppIDs: [s1],
                    miniAppIDs: [s2],
                    detailAppIDs: [s1, s2]
                ),
            ],
            categoryDetail: [:]
        )
    }

    private func title(for card: AppLibraryCard) -> String {
        switch card.id {
        case .suggestions:
            return L10n.t(.suggestions)
        case .recentlyAdded:
            return L10n.t(.recentlyAdded)
        case .category(let category):
            return L10n.categoryTitle(for: category)
        }
    }

    // MARK: - 卡片顺序与标题

    @Test("cards render in model order with section titles")
    func cardOrderAndTitles() throws {
        let previous = L10n.currentLanguage
        defer { L10n.configure(language: previous) }
        L10n.configure(language: .english)

        let model = makeModel()
        let controller = AppLibraryViewController(
            model: model,
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }

        let cells = cardCells(controller)
        #expect(!cells.isEmpty)
        let visibleIDs = cells.map { $0.cardID }
        let expectedIDs = model.cards.prefix(cells.count).map { Optional($0.id) }
        #expect(visibleIDs == expectedIDs)

        for (cell, card) in zip(cells, model.cards) {
            let titleLabel = descendants(of: cell.view)
                .compactMap { $0 as? NSTextField }.first
            #expect(titleLabel?.stringValue == title(for: card))
        }
    }

    @Test("model without Recently Added shows suggestions then fixed categories")
    func noRecentlyAddedOrder() throws {
        let model = makeModel()
        let filtered = AppLibraryModel(
            cards: Array(model.cards.filter { $0.id != .recentlyAdded }),
            categoryDetail: [:]
        )
        let controller = AppLibraryViewController(
            model: filtered,
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }

        let ids = cardCells(controller).compactMap(\.cardID)
        #expect(ids == [.suggestions, .category(.productivity), .category(.social)])
    }

    // MARK: - 点击路由

    @Test("large primary icon click launches the app")
    func primaryIconClickLaunches() throws {
        var launched: [AppID] = []
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { launched.append($0) }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }

        let cell = try #require(cardCells(controller).first)
        #expect(cell.cardID == .suggestions)
        let firstFrame = try #require(cell.primaryFrames.first)
        cell.handleClick(at: CGPoint(x: firstFrame.midX, y: firstFrame.midY))
        #expect(launched == [a1])

        let secondFrame = try #require(cell.primaryFrames.dropFirst().first)
        cell.handleClick(at: CGPoint(x: secondFrame.midX, y: secondFrame.midY))
        #expect(launched == [a1, a2])
    }

    @Test("mini cluster and card title open the category detail")
    func miniAndTitleOpenDetail() throws {
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }

        let cell = try #require(cardCells(controller).first { $0.cardID == .category(.productivity) })

        let mini = cell.miniFrame
        #expect(mini.width > 0)
        cell.handleClick(at: CGPoint(x: mini.midX, y: mini.midY))
        let detail = try #require(controller.presentedDetail)
        #expect(detail.view.superview == controller.view)
        detail.handleEscape()
        #expect(controller.presentedDetail == nil)

        let titleFrame = cell.titleFrame
        #expect(titleFrame.width > 0)
        cell.handleClick(at: CGPoint(x: titleFrame.midX, y: titleFrame.midY))
        #expect(controller.presentedDetail != nil)
        controller.presentedDetail?.handleEscape()
        #expect(controller.presentedDetail == nil)
    }

    @Test("detail closes on Escape key and on outside click")
    func detailEscapeAndOutsideClose() throws {
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }

        try openProductivityDetail(in: controller)

        let detail = try #require(controller.presentedDetail)
        let escapeEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        )!
        detail.view.keyDown(with: escapeEvent)
        #expect(controller.presentedDetail == nil)

        try openProductivityDetail(in: controller)
        let detail2 = try #require(controller.presentedDetail)
        let mouseEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        detail2.view.mouseDown(with: mouseEvent)
        #expect(controller.presentedDetail == nil)
    }

    @Test("selecting a row in the detail launches and closes the detail")
    func detailRowSelectionLaunches() throws {
        var launched: [AppID] = []
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { launched.append($0) }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }

        try openProductivityDetail(in: controller)
        let detail = try #require(controller.presentedDetail)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        detail.view.layoutSubtreeIfNeeded()
        detail.collectionView.layoutSubtreeIfNeeded()
        let row = try #require(
            detail.collectionView.visibleItems()
                .compactMap { $0 as? AppLibraryDetailRowCell }.first
        )
        row.dispatchSelection()
        #expect(launched == [p1])
        #expect(controller.presentedDetail == nil)
    }

    @Test("mouseDown inside a detail row then mouseUp far outside does not select")
    func detailRowMouseUpFarOutsideDoesNotSelect() throws {
        var launched: [AppID] = []
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { launched.append($0) }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }

        try openProductivityDetail(in: controller)
        let detail = try #require(controller.presentedDetail)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        detail.view.layoutSubtreeIfNeeded()
        detail.collectionView.layoutSubtreeIfNeeded()
        let row = try #require(
            detail.collectionView.visibleItems()
                .compactMap { $0 as? AppLibraryDetailRowCell }.first
        )
        let downPoint = row.view.convert(
            CGPoint(x: row.view.bounds.midX, y: row.view.bounds.midY), to: nil
        )
        row.view.mouseDown(with: mouseEvent(.leftMouseDown, at: downPoint, window: window))
        row.view.mouseUp(
            with: mouseEvent(.leftMouseUp, at: CGPoint(x: downPoint.x + 100, y: downPoint.y), window: window)
        )
        #expect(launched.isEmpty)
        #expect(controller.presentedDetail != nil)
    }

    @Test("mouseDown then mouseUp within 6pt of a detail row still selects")
    func detailRowMouseUpWithinThresholdSelects() throws {
        var launched: [AppID] = []
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { launched.append($0) }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }

        try openProductivityDetail(in: controller)
        let detail = try #require(controller.presentedDetail)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        detail.view.layoutSubtreeIfNeeded()
        detail.collectionView.layoutSubtreeIfNeeded()
        let row = try #require(
            detail.collectionView.visibleItems()
                .compactMap { $0 as? AppLibraryDetailRowCell }.first
        )
        let downPoint = row.view.convert(
            CGPoint(x: row.view.bounds.midX, y: row.view.bounds.midY), to: nil
        )
        row.view.mouseDown(with: mouseEvent(.leftMouseDown, at: downPoint, window: window))
        row.view.mouseUp(
            with: mouseEvent(.leftMouseUp, at: CGPoint(x: downPoint.x + 4, y: downPoint.y - 4), window: window)
        )
        #expect(launched == [p1])
        #expect(controller.presentedDetail == nil)
    }

    // MARK: - 模型会话

    @Test("beginSession freezes the model; later apply is ignored")
    func sessionFreeze() throws {
        let model = makeModel()
        let controller = AppLibraryViewController(
            model: model,
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }

        let small = AppLibraryModel(
            cards: [model.cards[0]],
            categoryDetail: [:]
        )
        controller.beginSession(model: small)
        controller.apply(model: model)
        #expect(controller.collectionView.numberOfItems(inSection: 0) == 1)
    }

    @Test("apply keeps card identity/payload and frames stable")
    func applyPreservesIdentity() throws {
        let model = makeModel()
        let provider = LibraryFakeIconProvider()
        let controller = AppLibraryViewController(
            model: model,
            displayName: { $0.rawValue },
            iconProvider: provider,
            onLaunch: { _ in }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let socialBefore = cardCells(controller).first { $0.cardID == .category(.social) }
        #expect(socialBefore != nil)
        let socialCardBefore = try #require(
            model.cards.first { $0.id == .category(.social) }
        )
        let lastIndex = IndexPath(item: model.cards.count - 1, section: 0)
        let frameBefore = controller.collectionView.collectionViewLayout?
            .layoutAttributesForItem(at: lastIndex)?.frame
        #expect(frameBefore != nil)

        var changedCards = model.cards
        changedCards[2] = AppLibraryCard(
            id: model.cards[2].id,
            primaryAppIDs: model.cards[2].primaryAppIDs,
            miniAppIDs: [p4],
            detailAppIDs: [p1, p2, p3, p4, r1]
        )
        let changed = AppLibraryModel(cards: changedCards, categoryDetail: model.categoryDetail)
        controller.apply(model: changed)
        window.layoutIfNeeded()
        controller.collectionView.layoutSubtreeIfNeeded()

        let socialAfter = cardCells(controller).first { $0.cardID == .category(.social) }
        #expect(socialAfter != nil)
        let socialCardAfter = try #require(
            changed.cards.first { $0.id == .category(.social) }
        )
        #expect(socialCardAfter == socialCardBefore)
        let frameAfter = controller.collectionView.collectionViewLayout?
            .layoutAttributesForItem(at: lastIndex)?.frame
        #expect(frameAfter == frameBefore)
    }

    @Test("applying the identical model is a no-op for icon requests")
    func applyIdenticalModelIsNoOp() async throws {
        let provider = LibraryFakeIconProvider()
        let model = makeModel()
        let controller = AppLibraryViewController(
            model: model,
            displayName: { $0.rawValue },
            iconProvider: provider,
            onLaunch: { _ in }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()
        await drainMainActor()

        let before = provider.requested.count
        #expect(before > 0)
        controller.apply(model: model)
        window.layoutIfNeeded()
        controller.collectionView.layoutSubtreeIfNeeded()
        await drainMainActor()
        #expect(provider.requested.count == before)
    }

    @Test("empty model renders zero cards; apply(empty) removes all")
    func emptyModel() throws {
        let empty = AppLibraryModel(cards: [], categoryDetail: [:])
        let controller = AppLibraryViewController(
            model: empty,
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        #expect(controller.collectionView.numberOfItems(inSection: 0) == 0)
        #expect(cardCells(controller).isEmpty)

        controller.apply(model: makeModel())
        window.layoutIfNeeded()
        #expect(controller.collectionView.numberOfItems(inSection: 0) == 4)

        controller.apply(model: empty)
        window.layoutIfNeeded()
        #expect(controller.collectionView.numberOfItems(inSection: 0) == 0)
    }

    // MARK: - 图标请求

    @Test("only visible cards request icons")
    func onlyVisibleCardsRequestIcons() async throws {
        var cards: [AppLibraryCard] = []
        var allSlots = 0
        for (index, category) in AppLibraryCategory.allCases.enumerated() {
            let base = "Cat\(index)"
            let ids = (0..<7).map { AppID("/Applications/\(base)-\($0).app")! }
            cards.append(
                AppLibraryCard(
                    id: .category(category),
                    primaryAppIDs: Array(ids.prefix(3)),
                    miniAppIDs: Array(ids.dropFirst(3).prefix(4)),
                    detailAppIDs: ids
                )
            )
            allSlots += 7
        }
        let model = AppLibraryModel(cards: cards, categoryDetail: [:])
        let provider = LibraryFakeIconProvider()
        let controller = AppLibraryViewController(
            model: model,
            displayName: { $0.rawValue },
            iconProvider: provider,
            onLaunch: { _ in }
        )
        let window = host(controller, size: NSSize(width: 1200, height: 800))
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()
        await drainMainActor()

        let requested = Set(provider.requested)
        #expect(!requested.isEmpty)
        #expect(requested.count < allSlots)

        let clip = controller.collectionView.enclosingScrollView?.contentView
        let visibleRect = clip?.convert(
            clip?.bounds ?? .zero, to: controller.collectionView
        ) ?? controller.collectionView.bounds
        let visibleFrames = controller.collectionView.collectionViewLayout?
            .layoutAttributesForElements(in: visibleRect) ?? []
        var visibleSlots = Set<AppID>()
        for attributes in visibleFrames {
            guard let itemIndex = attributes.indexPath?.item,
                  model.cards.indices.contains(itemIndex) else { continue }
            visibleSlots.formUnion(model.cards[itemIndex].primaryAppIDs)
            visibleSlots.formUnion(model.cards[itemIndex].miniAppIDs)
        }
        #expect(requested.isSubset(of: visibleSlots))
    }

    @Test("late provider result never crosses to a reused cell's new app")
    func lateIconResultDoesNotCrossApps() async throws {
        let provider = LibraryFakeIconProvider()
        provider.holdRequested = true
        let cell = AppLibraryCardCell()
        cell.loadView()

        let alpha = AppID("/Applications/Alpha.app")!
        let beta = AppID("/Applications/Beta.app")!
        let imageA = makeTestImage(8)
        let imageB = makeTestImage(16)

        cell.configure(
            cardID: .suggestions,
            title: "Suggestions",
            primary: [(appID: alpha, name: "Alpha")],
            mini: [],
            provider: provider,
            backingScale: 2,
            reducedMotion: true
        )
        await drainMainActor()

        cell.configure(
            cardID: .suggestions,
            title: "Suggestions",
            primary: [(appID: beta, name: "Beta")],
            mini: [],
            provider: provider,
            backingScale: 2,
            reducedMotion: true
        )
        await drainMainActor()

        provider.release(alpha, image: imageA)
        provider.release(beta, image: imageB)
        await drainMainActor()

        #expect(cell.appliedIconImage(for: alpha) == nil)
        #expect(cell.appliedIconImage(for: beta) != nil)
    }

    // MARK: - Helpers

    @Test("setContentInsets before view load is cached and applied at loadView")
    func contentInsetsBeforeViewLoad() throws {
        let model = makeModel()
        let controller = AppLibraryViewController(
            model: model,
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        // view 未加载(loadView 未执行, layout 尚不存在)时设置 insets → 缓存。
        controller.setContentInsets(top: 120, bottom: 20)

        let window = host(controller, size: NSSize(width: 1200, height: 800))
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let layout = try #require(
            controller.collectionView.collectionViewLayout as? AppLibraryLayout
        )
        let first = try #require(
            layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        #expect(first.frame.minY == 120)
        let last = try #require(
            layout.layoutAttributesForItem(
                at: IndexPath(item: model.cards.count - 1, section: 0)
            )
        )
        #expect(layout.collectionViewContentSize.height - last.frame.maxY >= 20)
    }

    @Test("setContentInsets after view load applies immediately")
    func contentInsetsAfterViewLoad() throws {
        let model = makeModel()
        let controller = AppLibraryViewController(
            model: model,
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        let window = host(controller, size: NSSize(width: 1200, height: 800))
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        controller.setContentInsets(top: 96, bottom: 20)
        controller.collectionView.layoutSubtreeIfNeeded()

        let layout = try #require(
            controller.collectionView.collectionViewLayout as? AppLibraryLayout
        )
        let first = try #require(
            layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        #expect(first.frame.minY == 96)
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

    private func openProductivityDetail(in controller: AppLibraryViewController) throws {
        let cell = try #require(cardCells(controller).first { $0.cardID == .category(.productivity) })
        let mini = cell.miniFrame
        cell.handleClick(at: CGPoint(x: mini.midX, y: mini.midY))
        controller.view.window?.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        controller.presentedDetail?.view.layoutSubtreeIfNeeded()
        #expect(controller.presentedDetail != nil)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func makeTestImage(_ size: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func drainMainActor() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        for _ in 0..<5 { await Task.yield() }
    }
}

/// 可控图标 provider: 记录请求; 可选挂起每个 AppID 的请求, 由测试 release。
@MainActor
private final class LibraryFakeIconProvider: IconImageProviding {
    var requested: [AppID] = []
    var images: [AppID: CGImage] = [:]
    var holdRequested = false
    private var held: [AppID: CheckedContinuation<Void, Never>] = [:]

    func icon(for appID: AppID, pointSize: Int, scale: Int) async -> CGImage? {
        requested.append(appID)
        if holdRequested {
            await withCheckedContinuation { continuation in
                held[appID] = continuation
            }
        }
        return images[appID]
    }

    func release(_ appID: AppID, image: CGImage) {
        images[appID] = image
        held.removeValue(forKey: appID)?.resume()
    }

    func trimMemoryForHidden() {}
}
