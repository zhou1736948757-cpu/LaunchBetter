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
    private let a4 = AppID("/Applications/Amber.app")!
    private let r1 = AppID("/Applications/Red.app")!
    private let r2 = AppID("/Applications/Reed.app")!
    private let r3 = AppID("/Applications/Rose.app")!
    private let r4 = AppID("/Applications/Ruth.app")!
    private let p1 = AppID("/Applications/Pencil.app")!
    private let p2 = AppID("/Applications/Paper.app")!
    private let p3 = AppID("/Applications/Prism.app")!
    private let p4 = AppID("/Applications/Pulse.app")!
    private let p5 = AppID("/Applications/Paint.app")!
    private let p6 = AppID("/Applications/Photo.app")!
    private let p7 = AppID("/Applications/Pages.app")!
    private let s1 = AppID("/Applications/Signal.app")!
    private let s2 = AppID("/Applications/Slate.app")!

    // MARK: - 模型

    private func makeModel() -> AppLibraryModel {
        AppLibraryModel(
            cards: [
                AppLibraryCard(
                    id: .suggestions,
                    primaryAppIDs: [a1, a2, a3, a4],
                    miniAppIDs: [],
                    detailAppIDs: [a1, a2, a3, a4]
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
                    miniAppIDs: [p4, p5, p6, p7],
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

        let thirdFrame = try #require(cell.primaryFrames.dropFirst(2).first)
        cell.handleClick(at: CGPoint(x: thirdFrame.midX, y: thirdFrame.midY))
        #expect(launched == [a1, a2, a3])

        let fourthFrame = try #require(cell.primaryFrames.dropFirst(3).first)
        cell.handleClick(at: CGPoint(x: fourthFrame.midX, y: fourthFrame.midY))
        #expect(launched == [a1, a2, a3, a4])
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

    // MARK: - PA3 空白点击

    @Test("blank click on grid background fires hide callback once (PA3)")
    func blankClickHidesOnce() throws {
        var blanks = 0
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        controller.onBlankClick = { blanks += 1 }
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let point = try blankPoint(in: controller)
        controller.collectionView.mouseDown(with: mouseEvent(.leftMouseDown, at: point, window: window))
        controller.collectionView.mouseUp(with: mouseEvent(.leftMouseUp, at: point, window: window))
        #expect(blanks == 1)

        // mouseUp 后会话已清空: 无配对 mouseDown 的 mouseUp 不产生第二次回调。
        controller.collectionView.mouseUp(with: mouseEvent(.leftMouseUp, at: point, window: window))
        #expect(blanks == 1)
    }

    @Test("click on a card region does not blank (PA3)")
    func cardRegionClickDoesNotBlank() throws {
        var blanks = 0
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        controller.onBlankClick = { blanks += 1 }
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        // 网格层: 点在卡片 frame 内 → 非空白, 不 arm。
        let cell = try #require(cardCells(controller).first)
        let cardCenter = cell.view.convert(
            CGPoint(x: cell.view.bounds.midX, y: cell.view.bounds.midY), to: nil
        )
        controller.collectionView.mouseDown(with: mouseEvent(.leftMouseDown, at: cardCenter, window: window))
        controller.collectionView.mouseUp(with: mouseEvent(.leftMouseUp, at: cardCenter, window: window))
        #expect(blanks == 0)

        // 卡片自身消费完整序列(不调用 super) → 事件不到网格, 亦无 blank。
        cell.view.mouseDown(with: mouseEvent(.leftMouseDown, at: cardCenter, window: window))
        cell.view.mouseUp(with: mouseEvent(.leftMouseUp, at: cardCenter, window: window))
        #expect(blanks == 0)
    }

    @Test("large icon click launches without blank (PA3)")
    func primaryIconClickLaunchesWithoutBlank() throws {
        var blanks = 0
        var launched: [AppID] = []
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { launched.append($0) }
        )
        controller.onBlankClick = { blanks += 1 }
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let cell = try #require(cardCells(controller).first)
        let first = try #require(cell.primaryFrames.first)
        cell.handleClick(at: CGPoint(x: first.midX, y: first.midY))
        #expect(launched == [a1])
        #expect(blanks == 0)
    }

    @Test("mini cluster and title open detail without blank (PA3)")
    func miniAndTitleOpenDetailWithoutBlank() throws {
        var blanks = 0
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        controller.onBlankClick = { blanks += 1 }
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let cell = try #require(cardCells(controller).first { $0.cardID == .category(.productivity) })
        let mini = cell.miniFrame
        #expect(mini.width > 0)
        cell.handleClick(at: CGPoint(x: mini.midX, y: mini.midY))
        #expect(controller.presentedDetail != nil)
        #expect(blanks == 0)
        controller.presentedDetail?.handleEscape()
        #expect(controller.presentedDetail == nil)

        let titleFrame = cell.titleFrame
        #expect(titleFrame.width > 0)
        cell.handleClick(at: CGPoint(x: titleFrame.midX, y: titleFrame.midY))
        #expect(controller.presentedDetail != nil)
        #expect(blanks == 0)
        controller.presentedDetail?.handleEscape()
        #expect(controller.presentedDetail == nil)
    }

    @Test("blank mouseDown then mouseUp far outside does not blank (PA3)")
    func blankMouseDownDragOutDoesNotBlank() throws {
        var blanks = 0
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        controller.onBlankClick = { blanks += 1 }
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let down = try blankPoint(in: controller)
        let up = CGPoint(x: down.x + 100, y: down.y)
        controller.collectionView.mouseDown(with: mouseEvent(.leftMouseDown, at: down, window: window))
        controller.collectionView.mouseUp(with: mouseEvent(.leftMouseUp, at: up, window: window))
        #expect(blanks == 0)

        // 拖出作废的会话不污染下一次: 随后的正常空白点击仍触发一次。
        controller.collectionView.mouseDown(with: mouseEvent(.leftMouseDown, at: down, window: window))
        controller.collectionView.mouseUp(with: mouseEvent(.leftMouseUp, at: down, window: window))
        #expect(blanks == 1)
    }

    @Test("blank click while detail is open closes detail, never hides (PA3)")
    func blankClickWhileDetailOpenDoesNotHide() throws {
        var blanks = 0
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        controller.onBlankClick = { blanks += 1 }
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        try openProductivityDetail(in: controller)

        // 网格空白点击: controller 层门控(detailController != nil / isScrollPaused)拦截。
        let point = try blankPoint(in: controller)
        controller.collectionView.mouseDown(with: mouseEvent(.leftMouseDown, at: point, window: window))
        controller.collectionView.mouseUp(with: mouseEvent(.leftMouseUp, at: point, window: window))
        #expect(blanks == 0)
        #expect(controller.presentedDetail != nil)

        // 真实路径: detail 根视图覆盖并消费点击 → 关闭 detail, 不触发 hide。
        let detail = try #require(controller.presentedDetail)
        detail.view.mouseDown(with: mouseEvent(.leftMouseDown, at: point, window: window))
        #expect(controller.presentedDetail == nil)
        #expect(blanks == 0)
    }

    @Test("two blank clicks each fire once, as independent sessions (PA3)")
    func twoBlankClicksFireTwice() throws {
        var blanks = 0
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        controller.onBlankClick = { blanks += 1 }
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let point = try blankPoint(in: controller)
        controller.collectionView.mouseDown(with: mouseEvent(.leftMouseDown, at: point, window: window))
        controller.collectionView.mouseUp(with: mouseEvent(.leftMouseUp, at: point, window: window))
        #expect(blanks == 1)

        controller.collectionView.mouseDown(with: mouseEvent(.leftMouseDown, at: point, window: window))
        controller.collectionView.mouseUp(with: mouseEvent(.leftMouseUp, at: point, window: window))
        #expect(blanks == 2)
    }

    // MARK: - V1 空白点击修复(文档外容器空白 + hitTest 接管)

    @Test("gap between two cards in a row hides once (V1)")
    func gapBetweenCardsHidesOnce() throws {
        var blanks = 0
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        controller.onBlankClick = { blanks += 1 }
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        // 同一行相邻两卡之间的水平间隙: 网格背景空白(indexPathForItem == nil)。
        let layout = try #require(controller.collectionView.collectionViewLayout)
        let first = try #require(
            layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
        )
        let second = try #require(
            layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))
        )
        #expect(abs(first.frame.midY - second.frame.midY) < 0.5)
        let gapLocal = CGPoint(
            x: (first.frame.maxX + second.frame.minX) / 2,
            y: first.frame.midY
        )
        let point = controller.collectionView.convert(gapLocal, to: nil)

        controller.collectionView.mouseDown(
            with: mouseEvent(.leftMouseDown, at: point, window: window)
        )
        controller.collectionView.mouseUp(
            with: mouseEvent(.leftMouseUp, at: point, window: window)
        )
        #expect(blanks == 1)
    }

    @Test("bottom blank below document hides once via scroll container (V1)")
    func bottomBlankHidesOnceViaScrollContainer() throws {
        var blanks = 0
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        controller.onBlankClick = { blanks += 1 }
        // 窗口加高: 文档高度 < 视口 → 底部留白属于 scroll 容器(NSClipView 区域)。
        let window = host(controller, size: NSSize(width: 1200, height: 1000))
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let scroll = try #require(
            controller.verticalScrollView as? PausableLibraryScrollView
        )
        let point = try scrollContainerBlankPoint(in: controller)
        let local = scroll.convert(point, from: nil)
        // 断言点确实在文档 frame 之外(scroll 容器空白), 会话会 arm。
        #expect(scroll.bounds.contains(local))

        scroll.mouseDown(with: mouseEvent(.leftMouseDown, at: point, window: window))
        scroll.mouseUp(with: mouseEvent(.leftMouseUp, at: point, window: window))
        #expect(blanks == 1)
    }

    @Test("card whitespace opens detail, never hides (V1)")
    func cardWhitespaceOpensDetailNotHide() throws {
        var blanks = 0
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        controller.onBlankClick = { blanks += 1 }
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let cell = try #require(cardCells(controller).first { $0.cardID == .category(.productivity) })
        // 标题左上角外侧 padding 区: 不在 primary/mini/title 任何热区。
        let whitespace = CGPoint(x: 7, y: cell.view.bounds.height - 7)
        #expect(cell.primaryFrames.allSatisfy { !$0.contains(whitespace) })
        #expect(!cell.miniFrame.contains(whitespace))
        #expect(!cell.titleFrame.contains(whitespace))

        cell.handleClick(at: whitespace)
        #expect(controller.presentedDetail != nil)
        #expect(blanks == 0)
        controller.presentedDetail?.handleEscape()
        #expect(controller.presentedDetail == nil)
    }

    @Test("settings shield consumes blank clicks; ownership restored after (V1)")
    func settingsShieldConsumesBlankClicksOwnershipUnchanged() throws {
        var blanks = 0
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        controller.onBlankClick = { blanks += 1 }
        let window = host(controller, size: NSSize(width: 1200, height: 1000))
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let scroll = try #require(
            controller.verticalScrollView as? PausableLibraryScrollView
        )
        let point = try scrollContainerBlankPoint(in: controller)
        let local = controller.view.convert(point, from: nil)

        // Settings 打开: 屏蔽层覆盖整个内容 → 空白命中 shield, 不是 scroll view。
        let shield = SettingsInteractionShield(frame: controller.view.bounds)
        var shieldDowns = 0
        var shieldUps = 0
        shield.onShieldMouseDown = { shieldDowns += 1 }
        shield.onShieldMouseUp = { shieldUps += 1 }
        controller.view.addSubview(shield)
        // 屏蔽层在最上层, 命中优先于 scroll 内容(离屏宿主下 scroll 自身
        // hitTest 结果不可靠, 这里断言"shield 存在时命中 shield"这一契约)。
        #expect(controller.view.hitTest(local) === shield)

        // AppKit 把事件交给 shield(消费完整序列): 不 arm 空白会话, 不隐藏。
        shield.mouseDown(with: mouseEvent(.leftMouseDown, at: point, window: window))
        shield.mouseUp(with: mouseEvent(.leftMouseUp, at: point, window: window))
        #expect(shieldDowns == 1)
        #expect(shieldUps == 1)
        #expect(blanks == 0)
        #expect(controller.presentedDetail == nil)

        // 关闭 Settings → 移除 shield → 空白所有权恢复, 点击再次触发隐藏。
        shield.removeFromSuperview()
        scroll.mouseDown(with: mouseEvent(.leftMouseDown, at: point, window: window))
        scroll.mouseUp(with: mouseEvent(.leftMouseUp, at: point, window: window))
        #expect(blanks == 1)
    }

    @Test("scroll container blank mouseDown then mouseUp far outside does not blank (V1)")
    func scrollBlankDragOutDoesNotBlank() throws {
        var blanks = 0
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        controller.onBlankClick = { blanks += 1 }
        let window = host(controller, size: NSSize(width: 1200, height: 1000))
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let scroll = try #require(
            controller.verticalScrollView as? PausableLibraryScrollView
        )
        let down = try scrollContainerBlankPoint(in: controller)
        let up = CGPoint(x: down.x + 100, y: down.y)
        scroll.mouseDown(with: mouseEvent(.leftMouseDown, at: down, window: window))
        scroll.mouseUp(with: mouseEvent(.leftMouseUp, at: up, window: window))
        #expect(blanks == 0)

        // 拖出作废的会话不污染下一次: 随后的正常空白点击仍触发一次。
        scroll.mouseDown(with: mouseEvent(.leftMouseDown, at: down, window: window))
        scroll.mouseUp(with: mouseEvent(.leftMouseUp, at: down, window: window))
        #expect(blanks == 1)
    }

    @Test("scroll container unpaired mouseUp does not blank (V1)")
    func scrollBlankUnpairedMouseUpDoesNotBlank() throws {
        var blanks = 0
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        controller.onBlankClick = { blanks += 1 }
        let window = host(controller, size: NSSize(width: 1200, height: 1000))
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let scroll = try #require(
            controller.verticalScrollView as? PausableLibraryScrollView
        )
        let point = try scrollContainerBlankPoint(in: controller)

        // 无配对 mouseDown 的 mouseUp: 会话未 arm, 不触发。
        scroll.mouseUp(with: mouseEvent(.leftMouseUp, at: point, window: window))
        #expect(blanks == 0)

        // 正常会话仍触发一次。
        scroll.mouseDown(with: mouseEvent(.leftMouseDown, at: point, window: window))
        scroll.mouseUp(with: mouseEvent(.leftMouseUp, at: point, window: window))
        #expect(blanks == 1)
    }

    @Test("two scroll container blank clicks fire twice as independent sessions (V1)")
    func twoScrollBlanksFireTwice() throws {
        var blanks = 0
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        controller.onBlankClick = { blanks += 1 }
        let window = host(controller, size: NSSize(width: 1200, height: 1000))
        defer { window.orderOut(nil); window.contentView = nil }
        controller.collectionView.layoutSubtreeIfNeeded()

        let scroll = try #require(
            controller.verticalScrollView as? PausableLibraryScrollView
        )
        let point = try scrollContainerBlankPoint(in: controller)
        scroll.mouseDown(with: mouseEvent(.leftMouseDown, at: point, window: window))
        scroll.mouseUp(with: mouseEvent(.leftMouseUp, at: point, window: window))
        #expect(blanks == 1)

        scroll.mouseDown(with: mouseEvent(.leftMouseDown, at: point, window: window))
        scroll.mouseUp(with: mouseEvent(.leftMouseUp, at: point, window: window))
        #expect(blanks == 2)
    }

    // MARK: - 卡片象限布局

    @Test("suggestions card renders 2×2 four large icons, no mini area")
    func suggestionsQuadrants() throws {
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }

        let cell = try #require(cardCells(controller).first { $0.cardID == .suggestions })
        let bounds = cell.view.bounds
        #expect(bounds.width > 0)
        let primary = cell.primaryFrames
        #expect(primary.count == 4)
        for frame in primary {
            #expect(bounds.contains(frame))
        }
        // 2×2: 上行同高、下行同高、左列同 x、右列同 x, 两行不重叠。
        #expect(almostEqual(primary[0].midY, primary[1].midY))
        #expect(almostEqual(primary[2].midY, primary[3].midY))
        #expect(almostEqual(primary[0].midX, primary[2].midX))
        #expect(almostEqual(primary[1].midX, primary[3].midX))
        #expect(primary[2].minY >= primary[0].maxY)
        #expect(primary[1].minX > primary[0].maxX)
        #expect(cell.miniFrame == .zero)
    }

    @Test("regular card renders 3 large icons plus bottom-right mini quadrant, no overlap")
    func regularCardQuadrants() throws {
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }

        let cell = try #require(cardCells(controller).first { $0.cardID == .category(.productivity) })
        let bounds = cell.view.bounds
        #expect(bounds.width > 0)

        let primary = cell.primaryFrames
        #expect(primary.count == 3)
        for frame in primary {
            #expect(bounds.contains(frame))
        }
        #expect(bounds.contains(cell.miniFrame))
        #expect(cell.miniFrame.width > 0)
        for i in 0..<primary.count {
            for j in (i + 1)..<primary.count {
                #expect(!primary[i].intersects(primary[j]))
            }
            #expect(!primary[i].intersects(cell.miniFrame))
        }
        // 象限关系: 大图标 0/1 同顶行, 大图标 2 在其正下方, mini 象限在右下。
        #expect(almostEqual(primary[0].midY, primary[1].midY))
        #expect(primary[2].minY >= primary[0].maxY)
        #expect(cell.miniFrame.minY >= primary[1].maxY)
        #expect(cell.miniFrame.minX > primary[0].maxX)
        #expect(almostEqual(cell.miniFrame.maxX, bounds.maxX, tolerance: 14))
    }

    @Test("mini cluster is a 2×2 grid inside the bottom-right quadrant")
    func miniClusterQuadrantGrid() throws {
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }

        let cell = try #require(cardCells(controller).first { $0.cardID == .category(.productivity) })
        let frames = cell.miniIconFrames
        #expect(frames.count == 4)
        for frame in frames {
            #expect(cell.miniFrame.contains(frame))
            #expect(cell.view.bounds.contains(frame))
        }
        #expect(almostEqual(frames[0].midY, frames[1].midY))
        #expect(almostEqual(frames[2].midY, frames[3].midY))
        #expect(almostEqual(frames[0].midX, frames[2].midX))
        #expect(almostEqual(frames[1].midX, frames[3].midX))
        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count {
                #expect(!frames[i].intersects(frames[j]))
            }
        }
    }

    @Test("card title sits top-left and card contains no app label text")
    func titleTopLeftNoAppLabels() throws {
        let controller = AppLibraryViewController(
            model: makeModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        let window = host(controller)
        defer { window.orderOut(nil); window.contentView = nil }

        let cell = try #require(cardCells(controller).first { $0.cardID == .category(.productivity) })
        let bounds = cell.view.bounds
        #expect(almostEqual(cell.titleFrame.minX, 14))
        #expect(almostEqual(cell.titleFrame.maxY, bounds.height - 14, tolerance: 0.5))
        #expect(cell.titleFrame.minX < bounds.width / 2)
        // 卡片内唯一 NSTextField 是标题本身(无 app 标签)。
        let textFields = descendants(of: cell.view).compactMap { $0 as? NSTextField }
        #expect(textFields.count == 1)
        #expect(textFields[0].frame == cell.titleFrame)
        #expect(textFields[0].alignment == .left)
    }

    @Test("cell frames derive from bounds; identical at backingScale 1 and 2")
    func framesScaleWithBoundsNotPixels() throws {
        func makeCell(scale: Int) -> AppLibraryCardCell {
            let cell = AppLibraryCardCell()
            cell.loadView()
            cell.configure(
                cardID: .category(.productivity),
                title: "Productivity",
                primary: [(appID: p1, name: "P1"), (appID: p2, name: "P2"), (appID: p3, name: "P3")],
                mini: [(appID: p4, name: "P4"), (appID: p5, name: "P5"),
                        (appID: p6, name: "P6"), (appID: p7, name: "P7")],
                provider: nil,
                backingScale: scale,
                reducedMotion: true
            )
            cell.view.frame = NSRect(x: 0, y: 0, width: 340, height: 340)
            cell.view.needsLayout = true
            cell.view.layoutSubtreeIfNeeded()
            cell.viewDidLayout()
            return cell
        }
        let scale1 = makeCell(scale: 1)
        let scale2 = makeCell(scale: 2)
        #expect(scale1.primaryFrames == scale2.primaryFrames)
        #expect(scale1.miniFrame == scale2.miniFrame)
        #expect(scale1.miniIconFrames == scale2.miniIconFrames)
        #expect(scale1.titleFrame == scale2.titleFrame)
        #expect(!scale1.primaryFrames.isEmpty)
        for frame in scale1.primaryFrames {
            #expect(scale1.view.bounds.contains(frame))
        }
        for frame in scale1.miniIconFrames {
            #expect(scale1.miniFrame.contains(frame))
        }
    }

    // MARK: - PA2 手动分类覆盖菜单

    /// 覆盖测试模型: 仅 productivity 卡(2 app, 不稀疏)。
    private func makeOverrideModel() -> AppLibraryModel {
        AppLibraryModel(
            cards: [
                AppLibraryCard(
                    id: .category(.productivity),
                    primaryAppIDs: [p1, p2],
                    miniAppIDs: [],
                    detailAppIDs: [p1, p2]
                ),
            ],
            categoryDetail: [.productivity: [p1, p2]]
        )
    }

    private func makeOverrideController(store: FakeCategoryOverridingStore) -> AppLibraryViewController {
        AppLibraryViewController(
            model: makeOverrideModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in },
            categoryOverriding: store
        )
    }

    private func moveItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == L10n.t(.moveToCategory) }
    }

    private func categoryItem(in submenu: NSMenu, category: AppLibraryCategory) -> NSMenuItem? {
        submenu.items.first { $0.title == L10n.categoryTitle(for: category) }
    }

    @Test("menu: Move to Category 子菜单含全部分类; 当前生效分类打勾")
    func menuCheckmarkEffectiveCategory() throws {
        let previous = L10n.currentLanguage
        defer { L10n.configure(language: previous) }
        L10n.configure(language: .english)

        let controller = makeOverrideController(store: FakeCategoryOverridingStore())
        let menu = try #require(controller.makeCategoryMenu(for: p1))

        let move = try #require(moveItem(in: menu))
        let submenu = try #require(move.submenu)
        #expect(submenu.items.count == AppLibraryCategory.allCases.count)
        for category in AppLibraryCategory.allCases {
            let item = try #require(categoryItem(in: submenu, category: category))
            #expect(item.state == (category == .productivity ? .on : .off))
            #expect(item.action != nil)
            #expect(item.target === controller)
        }
    }

    @Test("menu: 手动覆盖时 Automatic Classification 无勾选且选择即移除")
    func menuAutomaticRemovesOverride() async throws {
        let previous = L10n.currentLanguage
        defer { L10n.configure(language: previous) }
        L10n.configure(language: .english)

        let store = FakeCategoryOverridingStore()
        store.categoryOverrides = [p1: .games]
        let controller = makeOverrideController(store: store)

        let menu = try #require(controller.makeCategoryMenu(for: p1))
        let automatic = try #require(
            menu.items.first { $0.title == L10n.t(.automaticClassification) }
        )
        #expect(automatic.state == .off)

        controller.clearCategoryOverride(automatic)
        await drainMainActor()
        #expect(store.clearCalls == [p1])
        #expect(store.categoryOverrides[p1] == nil)

        // 无覆盖后: Automatic Classification 打勾
        let menu2 = try #require(controller.makeCategoryMenu(for: p1))
        let automatic2 = try #require(
            menu2.items.first { $0.title == L10n.t(.automaticClassification) }
        )
        #expect(automatic2.state == .on)
    }

    @Test("menu: 选择分类项 → store 覆盖; 生效分类随覆盖移动")
    func menuSelectionWritesOverride() async throws {
        let previous = L10n.currentLanguage
        defer { L10n.configure(language: previous) }
        L10n.configure(language: .english)

        let store = FakeCategoryOverridingStore()
        let controller = makeOverrideController(store: store)

        let menu = try #require(controller.makeCategoryMenu(for: p1))
        let move = try #require(moveItem(in: menu))
        let submenu = try #require(move.submenu)
        let games = try #require(categoryItem(in: submenu, category: .games))

        controller.applyCategoryOverride(games)
        await drainMainActor()
        #expect(store.setCalls.count == 1)
        #expect(store.setCalls[0].0 == p1)
        #expect(store.setCalls[0].1 == .games)
        #expect(store.categoryOverrides[p1] == .games)

        // 真实链路: store 重建 model 后经 updateModel 推回控制器 → 勾选随生效分类移动。
        // 这里用等效重建后的模型(仅 games 卡, p1 在 games)。
        store.categoryOverrides = [p1: .games]
        let rebuilt = AppLibraryModel(
            cards: [AppLibraryCard(
                id: .category(.games),
                primaryAppIDs: [p1, p2],
                miniAppIDs: [],
                detailAppIDs: [p1, p2]
            )],
            categoryDetail: [.games: [p1, p2]]
        )
        controller.updateModel(rebuilt)
        let menu2 = try #require(controller.makeCategoryMenu(for: p1))
        let move2 = try #require(moveItem(in: menu2))
        let submenu2 = try #require(move2.submenu)
        #expect(categoryItem(in: submenu2, category: .games)?.state == .on)
        #expect(categoryItem(in: submenu2, category: .productivity)?.state == .off)
    }

    @Test("menu: 无覆盖能力(store 不实现 AppLibraryCategoryOverriding) → nil")
    func menuNilWithoutOverriding() throws {
        let controller = AppLibraryViewController(
            model: makeOverrideModel(),
            displayName: { $0.rawValue },
            iconProvider: nil,
            onLaunch: { _ in }
        )
        #expect(controller.makeCategoryMenu(for: p1) == nil)
    }

    @Test("卡片大图标右键: 命中 primary 图标回调 AppID; mini 区/标题不回调")
    func cardRightClickRoutesToPrimaryApp() throws {
        var routed: [(appID: AppID, point: NSPoint)] = []
        let cell = AppLibraryCardCell()
        cell.loadView()
        cell.configure(
            cardID: .category(.productivity),
            title: "Productivity",
            primary: [(appID: p1, name: "P1"), (appID: p2, name: "P2")],
            mini: [(appID: p3, name: "P3")],
            provider: nil,
            backingScale: 2,
            reducedMotion: true
        )
        cell.view.frame = NSRect(x: 0, y: 0, width: 340, height: 340)
        cell.view.needsLayout = true
        cell.view.layoutSubtreeIfNeeded()
        cell.viewDidLayout()
        cell.onCategoryMenu = { appID, point in
            routed.append((appID, point))
        }

        let first = try #require(cell.primaryFrames.first)
        let second = try #require(cell.primaryFrames.dropFirst().first)
        cell.handleRightClick(at: CGPoint(x: first.midX, y: first.midY))
        #expect(routed.count == 1)
        #expect(routed[0].appID == p1)

        cell.handleRightClick(at: CGPoint(x: second.midX, y: second.midY))
        #expect(routed.count == 2)
        #expect(routed[1].appID == p2)

        // mini 簇与标题右键不回调
        cell.handleRightClick(at: CGPoint(x: cell.miniFrame.midX, y: cell.miniFrame.midY))
        cell.handleRightClick(at: CGPoint(x: cell.titleFrame.midX, y: cell.titleFrame.midY))
        cell.handleRightClick(at: CGPoint(x: 5, y: 5))
        #expect(routed.count == 2)
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

    @Test("updateModel 绕过冻结 session: 冻结期模型仍可刷新; apply 仍被屏蔽")
    func updateModelBypassesFreeze() throws {
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
        #expect(controller.collectionView.numberOfItems(inSection: 0) == 1)

        // 冻结期间 updateModel 生效(PA2 live 刷新, diffable 身份稳定)
        controller.updateModel(model)
        window.layoutIfNeeded()
        #expect(controller.collectionView.numberOfItems(inSection: 0) == model.cards.count)

        // 冻结仍未解除: apply 继续被屏蔽
        controller.apply(model: small)
        #expect(controller.collectionView.numberOfItems(inSection: 0) == model.cards.count)

        // 相同模型 updateModel 为 no-op(不重建)
        controller.updateModel(model)
        #expect(controller.collectionView.numberOfItems(inSection: 0) == model.cards.count)
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

    @Test("detail 行右键: 命中行回调 AppID(PA2)")
    func detailRowRightClickRoutes() throws {
        var routed: [(appID: AppID, point: NSPoint)] = []
        let detail = AppLibraryDetailViewController(
            title: "Productivity",
            appIDs: [p1],
            displayName: { $0.rawValue },
            iconProvider: nil,
            onSelect: { _ in },
            onClose: {},
            onCategoryMenu: { appID, point in
                routed.append((appID, point))
            }
        )
        let window = host(detail, size: NSSize(width: 600, height: 400))
        defer { window.orderOut(nil); window.contentView = nil }
        detail.view.layoutSubtreeIfNeeded()
        detail.collectionView.layoutSubtreeIfNeeded()

        let row = try #require(
            detail.collectionView.visibleItems()
                .compactMap { $0 as? AppLibraryDetailRowCell }.first
        )
        row.handleRightClick(at: CGPoint(x: row.view.bounds.midX, y: row.view.bounds.midY))
        #expect(routed.count == 1)
        // 单 app detail: 任意可见行即 p1; 回调点为窗口坐标(位于 contentView 内)。
        #expect(routed[0].appID == p1)
        #expect(window.contentView?.bounds.contains(routed[0].point) == true)
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

    private func almostEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.001) -> Bool {
        abs(lhs - rhs) <= tolerance
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

    /// PA3: 返回网格中一个"真空白"点的窗口坐标(不在任何卡片 frame 内,
    /// `indexPathForItem` 为 nil)。取底部保留带(最后一排卡片之下)。
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

    /// V1: 返回 scroll 容器"文档外底部空白"的窗口坐标点(在 scroll bounds 内、
    /// 文档 frame 外)。需要窗口足够高(文档高度 < 视口), 底部留白才存在。
    /// 离屏测试宿主不会自动触发 `viewDidLayout`(文档 frame 保持 clip 全尺寸),
    /// 先显式调用让文档 frame 收缩到 contentSize。
    private func scrollContainerBlankPoint(in controller: AppLibraryViewController) throws -> NSPoint {
        controller.viewDidLayout()
        let scroll = try #require(
            controller.verticalScrollView as? PausableLibraryScrollView
        )
        let document = try #require(scroll.documentView)
        let docFrame = scroll.convert(document.frame, from: document.superview)
        // 优先取文档下沿之外(flipped: maxY 为视觉底部); 若不在 bounds 内,
        // 回退文档上沿之外。两者都必须是 scroll 可视区内且非文档区域。
        let below = CGPoint(x: scroll.bounds.midX, y: docFrame.maxY + 20)
        let above = CGPoint(x: scroll.bounds.midX, y: docFrame.minY - 20)
        let local: CGPoint? = {
            if scroll.bounds.contains(below), !docFrame.contains(below) {
                return below
            }
            if scroll.bounds.contains(above), !docFrame.contains(above) {
                return above
            }
            return nil
        }()
        let point = try #require(local)
        return scroll.convert(point, to: nil)
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

/// 可控分类覆盖 store(PA2 测试替身)。
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
