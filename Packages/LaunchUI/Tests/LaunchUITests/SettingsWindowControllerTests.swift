import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Settings window live UI", .serialized)
@MainActor
struct SettingsWindowControllerTests {
    @Test("all traffic-light buttons are hidden while native window behavior remains available")
    func trafficLightButtonsAreHidden() {
        let handler = SettingsHandlerStub(config: AppConfiguration(language: .english))
        let controller = SettingsWindowController(handler: handler)
        let window = controller.window

        #expect(window?.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(window?.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        #expect(window?.standardWindowButton(.zoomButton)?.isHidden == true)
        #expect(window?.styleMask.contains(.closable) == true)
        #expect(window?.styleMask.contains(.resizable) == true)
        #expect(window?.isMovableByWindowBackground == true)
    }

    @Test("search size UI uses percentage and preserves the compatible width")
    func searchSizeUsesPercentage() throws {
        let previousLanguage = L10n.currentLanguage
        L10n.configure(language: .english)
        defer { L10n.configure(language: previousLanguage) }

        let handler = SettingsHandlerStub(config: AppConfiguration(searchBarWidth: 512))
        let controller = SettingsWindowController(handler: handler)
        let contentView = try #require(controller.window?.contentView)
        let slider = try #require(descendant(
            of: NSSlider.self,
            identifier: "settings.searchBarSize",
            in: contentView
        ))
        let label = try #require(descendant(
            of: NSTextField.self,
            identifier: "settings.searchBarSizeLabel",
            in: contentView
        ))

        #expect(slider.doubleValue == 160)
        #expect(label.stringValue == "160%")
        #expect(slider.minValue == SearchBarSizing.minimumPercent)
        #expect(slider.maxValue == SearchBarSizing.maximumPercent)
        #expect(handler.config.searchBarWidth == 512)
        #expect(textValues(in: contentView).contains("Size Percentage"))

        slider.doubleValue = 125
        #expect(slider.sendAction(slider.action, to: slider.target))
        #expect(label.stringValue == "125%")
        #expect(handler.config.searchBarWidth == 400)
        #expect(SearchBarSizing.size(forPersistedWidth: 400).height == 27.5)
    }

    @Test("saved source and hidden app immediately appear and survive language rebuild")
    func savedListsAppearAndSurviveLanguageRebuild() throws {
        let previousLanguage = L10n.currentLanguage
        defer { L10n.configure(language: previousLanguage) }

        let appID = AppID(normalized: "/Applications/Hidden.app")
        let handler = SettingsHandlerStub(
            config: AppConfiguration(language: .simplifiedChinese),
            allApps: [(appID, "Hidden")]
        )
        L10n.configure(language: .simplifiedChinese)
        let controller = SettingsWindowController(handler: handler)
        let window = try #require(controller.window)

        controller.addSourcePath("/Users/test/Apps")
        controller.addHiddenAppID(appID)
        #expect(try table(identifier: "settings.sources", in: window).numberOfRows == 1)
        #expect(try table(identifier: "settings.hiddenApps", in: window).numberOfRows == 1)
        #expect(handler.config.customSourceDirectories == ["/Users/test/Apps"])
        #expect(handler.config.hiddenAppIDs == [appID])

        try selectLanguage(at: 1, in: window)
        #expect(try table(identifier: "settings.sources", in: window).numberOfRows == 1)
        #expect(try table(identifier: "settings.hiddenApps", in: window).numberOfRows == 1)
        #expect(handler.config.customSourceDirectories == ["/Users/test/Apps"])
        #expect(handler.config.hiddenAppIDs == [appID])
    }

    @Test("present refreshes lists changed externally after the singleton controller was created")
    func presentRefreshesExternallyChangedLists() throws {
        let appID = AppID(normalized: "/Applications/External.app")
        let handler = SettingsHandlerStub(
            config: AppConfiguration(language: .english),
            allApps: [(appID, "External App")]
        )
        let controller = SettingsWindowController(handler: handler)
        let window = try #require(controller.window)

        #expect(try table(identifier: "settings.sources", in: window).numberOfRows == 0)
        #expect(try table(identifier: "settings.hiddenApps", in: window).numberOfRows == 0)

        handler.replaceConfig(AppConfiguration(
            customSourceDirectories: ["/Users/test/External Apps"],
            hiddenAppIDs: [appID],
            language: .english
        ))
        controller.present()

        let sources = try table(identifier: "settings.sources", in: window)
        let hidden = try table(identifier: "settings.hiddenApps", in: window)
        #expect(sources.numberOfRows == 1)
        #expect(hidden.numberOfRows == 1)
        #expect(try rowText(in: sources, row: 0) == "/Users/test/External Apps")
        #expect(try rowText(in: hidden, row: 0) == "External App")
    }

    @Test("selecting a hidden app enables remove and unhide saves and reloads")
    func removingSelectedHiddenAppSavesAndRefreshes() throws {
        let first = AppID(normalized: "/Applications/First.app")
        let second = AppID(normalized: "/Applications/Second.app")
        let handler = SettingsHandlerStub(
            config: AppConfiguration(hiddenAppIDs: [first, second], language: .english),
            allApps: [(first, "First"), (second, "Second")]
        )
        let controller = SettingsWindowController(handler: handler)
        let window = try #require(controller.window)
        let table = try table(identifier: "settings.hiddenApps", in: window)
        let contentView = try #require(window.contentView)
        let remove = try #require(descendant(
            of: NSButton.self,
            identifier: "removeHidden",
            in: contentView
        ))

        #expect(!remove.isEnabled)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: table)
        )
        #expect(remove.isEnabled)

        #expect(remove.sendAction(remove.action, to: remove.target))

        #expect(handler.config.hiddenAppIDs == [second])
        #expect(table.numberOfRows == 1)
        #expect(try rowText(in: table, row: 0) == "Second")
    }

    @Test("hidden add uses the Settings-owned sheet presenter and refreshes the launch filter")
    func hiddenAddConfirmSavesAndFiltersImmediately() throws {
        let appID = AppID(normalized: "/Applications/HiddenFromLaunch.app")
        let store = MiniStoreStub(
            config: AppConfiguration(language: .english),
            allApps: [(appID, "Hidden From Launch")],
            layout: LayoutSnapshot(pages: [[.app(appID)]])
        )
        let panels = SettingsPanelStub()
        let controller = SettingsWindowController(
            handler: store,
            iconProvider: nil,
            sourcePanelPresenter: panels.sourcePresenter,
            hiddenPanelPresenter: panels.hiddenPresenter
        )
        let window = try #require(controller.window)
        let contentView = try #require(window.contentView)
        let add = try #require(descendant(
            of: NSButton.self,
            identifier: "addHidden",
            in: contentView
        ))

        #expect(add.sendAction(add.action, to: add.target))
        #expect(panels.hiddenParent === window)
        #expect(panels.hiddenApps.map(\.id) == [appID])
        #expect(store.config.hiddenAppIDs.isEmpty)

        panels.completeHidden(appID)

        #expect(store.config.hiddenAppIDs == [appID])
        #expect(try table(identifier: "settings.hiddenApps", in: window).numberOfRows == 1)
        #expect(store.visibleAppIDs().isEmpty)
    }

    @Test("hidden add cancel and duplicate selection leave hidden state unchanged")
    func hiddenAddCancelAndDuplicateAreNoOps() throws {
        let alreadyHidden = AppID(normalized: "/Applications/AlreadyHidden.app")
        let candidate = AppID(normalized: "/Applications/Candidate.app")
        let handler = SettingsHandlerStub(
            config: AppConfiguration(hiddenAppIDs: [alreadyHidden], language: .english),
            allApps: [(alreadyHidden, "Already Hidden"), (candidate, "Candidate")]
        )
        let panels = SettingsPanelStub()
        let controller = SettingsWindowController(
            handler: handler,
            iconProvider: nil,
            sourcePanelPresenter: panels.sourcePresenter,
            hiddenPanelPresenter: panels.hiddenPresenter
        )
        let window = try #require(controller.window)
        let contentView = try #require(window.contentView)
        let add = try #require(descendant(
            of: NSButton.self,
            identifier: "addHidden",
            in: contentView
        ))

        #expect(add.sendAction(add.action, to: add.target))
        #expect(panels.hiddenApps.map(\.id) == [candidate])
        panels.completeHidden(nil)
        #expect(handler.config.hiddenAppIDs == [alreadyHidden])

        #expect(add.sendAction(add.action, to: add.target))
        panels.completeHidden(alreadyHidden)
        #expect(handler.config.hiddenAppIDs == [alreadyHidden])
        #expect(try table(identifier: "settings.hiddenApps", in: window).numberOfRows == 1)
    }

    @Test("add controls do not present duplicate sheets and hidden add disables when no candidates remain")
    func addControlsGateDuplicateSheetsAndEmptyHiddenCandidates() throws {
        let appID = AppID(normalized: "/Applications/Only.app")
        let handler = SettingsHandlerStub(
            config: AppConfiguration(language: .english),
            allApps: [(appID, "Only")]
        )
        let panels = SettingsPanelStub()
        let controller = SettingsWindowController(
            handler: handler,
            iconProvider: nil,
            sourcePanelPresenter: panels.sourcePresenter,
            hiddenPanelPresenter: panels.hiddenPresenter
        )
        let contentView = try #require(controller.window?.contentView)
        let addHidden = try #require(descendant(
            of: NSButton.self,
            identifier: "addHidden",
            in: contentView
        ))
        let addSource = try #require(descendant(
            of: NSButton.self,
            identifier: "addSource",
            in: contentView
        ))

        #expect(addHidden.sendAction(addHidden.action, to: addHidden.target))
        #expect(addHidden.sendAction(addHidden.action, to: addHidden.target))
        #expect(panels.hiddenPresentationCount == 1)
        panels.completeHidden(appID)
        #expect(!addHidden.isEnabled)

        #expect(addSource.sendAction(addSource.action, to: addSource.target))
        #expect(addSource.sendAction(addSource.action, to: addSource.target))
        #expect(panels.sourcePresentationCount == 1)
        panels.completeSource(nil)
        #expect(addSource.sendAction(addSource.action, to: addSource.target))
        #expect(panels.sourcePresentationCount == 2)
    }

    @Test("source add confirm/cancel saves normalized unique paths and refreshes the list")
    func sourceAddConfirmCancelAndDeduplicate() throws {
        let store = MiniStoreStub(
            config: AppConfiguration(language: .english),
            allApps: [],
            layout: LayoutSnapshot()
        )
        var scanRequests: [[String]] = []
        store.onCustomSourcesChange = { scanRequests.append($0) }
        let panels = SettingsPanelStub()
        let controller = SettingsWindowController(
            handler: store,
            iconProvider: nil,
            sourcePanelPresenter: panels.sourcePresenter,
            hiddenPanelPresenter: panels.hiddenPresenter
        )
        let window = try #require(controller.window)
        let contentView = try #require(window.contentView)
        let add = try #require(descendant(
            of: NSButton.self,
            identifier: "addSource",
            in: contentView
        ))

        #expect(add.sendAction(add.action, to: add.target))
        #expect(panels.sourceParent === window)
        panels.completeSource(URL(fileURLWithPath: "/Users/test/Apps/../Apps"))

        #expect(store.config.customSourceDirectories == ["/Users/test/Apps"])
        #expect(try table(identifier: "settings.sources", in: window).numberOfRows == 1)
        #expect(scanRequests == [["/Users/test/Apps"]])

        #expect(add.sendAction(add.action, to: add.target))
        panels.completeSource(nil)
        #expect(store.config.customSourceDirectories == ["/Users/test/Apps"])
        #expect(store.saveCount == 1)

        #expect(add.sendAction(add.action, to: add.target))
        panels.completeSource(URL(fileURLWithPath: "/Users/test/Apps/"))
        #expect(store.config.customSourceDirectories == ["/Users/test/Apps"])
        #expect(store.saveCount == 1)
        #expect(scanRequests.count == 1)
    }

    @Test("source removal keeps the stable button reference in sync after reload")
    func sourceRemovalUsesStableButtonReference() throws {
        let handler = SettingsHandlerStub(config: AppConfiguration(
            customSourceDirectories: ["/Applications", "/Users/test/Apps"],
            language: .english
        ))
        let controller = SettingsWindowController(handler: handler)
        let window = try #require(controller.window)
        let sources = try table(identifier: "settings.sources", in: window)
        let contentView = try #require(window.contentView)
        let remove = try #require(descendant(
            of: NSButton.self,
            identifier: "removeSource",
            in: contentView
        ))

        #expect(!remove.isEnabled)
        sources.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: sources)
        )
        #expect(remove.isEnabled)
        #expect(remove.sendAction(remove.action, to: remove.target))

        #expect(handler.config.customSourceDirectories == ["/Users/test/Apps"])
        #expect(sources.numberOfRows == 1)
        #expect(remove.isEnabled == (sources.selectedRow >= 0))
    }

    @Test("hidden app rows place the icon before the name")
    func hiddenRowIconIsLeftOfName() throws {
        let appID = AppID(normalized: "/Applications/Hidden.app")
        let handler = SettingsHandlerStub(
            config: AppConfiguration(hiddenAppIDs: [appID], language: .english),
            allApps: [(appID, "Hidden")]
        )
        let controller = SettingsWindowController(handler: handler)
        let cell = try hiddenCell(in: try #require(controller.window), row: 0)

        #expect(cell.contentStack.arrangedSubviews.first === cell.iconView)
        #expect(cell.contentStack.arrangedSubviews.dropFirst().first === cell.nameLabel)
        #expect(cell.nameLabel.stringValue == "Hidden")
        #expect(cell.iconView.image != nil)
    }

    @Test("hidden row applies an asynchronous real icon and rejects a late reused result")
    func hiddenRowAsyncIconIsIdentitySafe() async throws {
        let first = AppID(normalized: "/Applications/First.app")
        let second = AppID(normalized: "/Applications/Second.app")
        let provider = SettingsIconProviderStub(deferred: true)
        let firstImage = makeTestImage(red: 1, green: 0, blue: 0)
        let secondImage = makeTestImage(red: 0, green: 0, blue: 1)
        provider.images[first] = firstImage
        provider.images[second] = secondImage
        let handler = SettingsHandlerStub(
            config: AppConfiguration(hiddenAppIDs: [first], language: .english),
            allApps: [(first, "First"), (second, "Second")]
        )
        let controller = SettingsWindowController(handler: handler, iconProvider: provider)
        let cell = try hiddenCell(in: try #require(controller.window), row: 0)

        await Task.yield()
        cell.configure(
            appID: second,
            name: "Second",
            provider: provider,
            pointSize: 32,
            scale: 2
        )
        provider.resolve(first, with: firstImage)
        await Task.yield()
        #expect(cell.appliedCGImage == nil)

        provider.resolve(second, with: secondImage)
        await cell.waitForIcon()
        #expect(cell.appliedCGImage === secondImage)
        #expect(cell.nameLabel.stringValue == "Second")
    }

    @Test("nil and unknown hidden apps keep a stable fallback icon")
    func hiddenRowUsesFallbackWhenIconUnavailable() throws {
        let known = AppID(normalized: "/Applications/NoIcon.app")
        let unknown = AppID(normalized: "/Applications/Uninstalled.app")
        let provider = SettingsIconProviderStub(images: [:], returnNilFor: [known])
        let handler = SettingsHandlerStub(
            config: AppConfiguration(hiddenAppIDs: [known, unknown], language: .english),
            allApps: [(known, "No Icon")]
        )
        let controller = SettingsWindowController(handler: handler, iconProvider: provider)
        let window = try #require(controller.window)
        let knownCell = try hiddenCell(in: window, row: 0)
        let unknownCell = try hiddenCell(in: window, row: 1)

        #expect(knownCell.iconView.image != nil)
        #expect(knownCell.appliedCGImage == nil)
        #expect(unknownCell.iconView.image != nil)
        #expect(unknownCell.appliedCGImage == nil)
        #expect(unknownCell.nameLabel.stringValue == unknown.rawValue)
        #expect(!provider.requestedAppIDs.contains(unknown))
    }

    @Test("unhide flows through the real save path: store config, revision, data change and main panel filter sync")
    func unhideSyncsStoreRevisionDataChangeAndMainPanel() throws {
        let appID = AppID(normalized: "/Applications/Restored.app")
        let layout = LayoutSnapshot(pages: [[.app(appID)]])
        let store = MiniStoreStub(
            config: AppConfiguration(hiddenAppIDs: [appID], language: .english),
            allApps: [(appID, "Restored App")],
            layout: layout
        )
        #expect(store.visibleAppIDs() == [])
        var changeCount = 0
        store.onDataChange = { changeCount += 1 }

        let controller = SettingsWindowController(handler: store)
        let window = try #require(controller.window)
        let table = try table(identifier: "settings.hiddenApps", in: window)
        let contentView = try #require(window.contentView)
        let remove = try #require(descendant(
            of: NSButton.self,
            identifier: "removeHidden",
            in: contentView
        ))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: table)
        )
        #expect(remove.isEnabled)

        #expect(remove.sendAction(remove.action, to: remove.target))

        #expect(store.saveCount == 1)
        #expect(store.revision == 1)
        #expect(changeCount == 1)
        #expect(store.config.hiddenAppIDs.isEmpty)
        #expect(store.visibleAppIDs() == [appID])
    }

    @Test("hidden row keeps a stable placeholder when no icon provider is injected")
    func hiddenRowPlaceholderWithoutIconProvider() throws {
        let appID = AppID(normalized: "/Applications/NoProvider.app")
        let handler = SettingsHandlerStub(
            config: AppConfiguration(hiddenAppIDs: [appID], language: .english),
            allApps: [(appID, "No Provider")]
        )
        let controller = SettingsWindowController(handler: handler)
        let cell = try hiddenCell(in: try #require(controller.window), row: 0)

        #expect(cell.nameLabel.stringValue == "No Provider")
        #expect(cell.iconView.image != nil)
        #expect(cell.appliedCGImage == nil)
    }

    @Test("wallpaper section has a blur slider but no standalone checkbox")
    func wallpaperCheckboxIsAbsent() throws {
        let previousLanguage = L10n.currentLanguage
        L10n.configure(language: .english)
        defer { L10n.configure(language: previousLanguage) }

        let handler = SettingsHandlerStub(config: AppConfiguration(language: .english))
        let controller = SettingsWindowController(handler: handler)
        let contentView = try #require(controller.window?.contentView)
        let buttons = descendants(of: NSButton.self, in: contentView)
        let identifiedCheckboxes = buttons.filter {
            ["settings.showLabels", "settings.hotkeyEnabled"].contains($0.identifier?.rawValue)
        }
        let untitledButtons = buttons.filter(\.title.isEmpty)
        let sliders = descendants(of: NSSlider.self, in: contentView)

        #expect(identifiedCheckboxes.count == 2)
        #expect(untitledButtons.count == 1)
        #expect(untitledButtons.first?.identifier?.rawValue == "settings.showLabels")
        #expect(sliders.contains { $0.minValue == 0 && $0.maxValue == 60 })
        #expect(textValues(in: contentView).contains("Blurred Wallpaper"))
        #expect(textValues(in: contentView).contains("Blur Intensity"))
    }

    @Test("every row's value control shares one value column across all form sections, in three languages")
    func valueColumnSharedAcrossSectionsInThreeLanguages() throws {
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            try assertSharedValueColumn(language: language)
        }
    }

    @Test("showLabels and hotkey checkboxes start exactly at the shared value column")
    func checkboxesAlignToValueColumn() throws {
        try assertControlAlignment(language: .simplifiedChinese)
        try assertControlAlignment(language: .english)
    }

    @Test("hot corner popups, icon size, language, blur and search bar values share one value column")
    func popupsAndSlidersShareValueColumn() throws {
        try assertControlAlignment(language: .traditionalChinese)
        try assertControlAlignment(language: .english)
    }

    @Test("three-language labels fit their column and no control is pushed outside the window")
    func threeLanguageLabelsFitWithoutOverflow() throws {
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            try assertLabelsFitAndNoOverflow(language: language)
        }
    }

    @Test("English and Traditional Chinese refresh in place without losing state")
    func languageRefreshesInPlace() throws {
        let previousLanguage = L10n.currentLanguage
        defer { L10n.configure(language: previousLanguage) }

        let firstApp = AppID(normalized: "/Applications/Alpha.app")
        let secondApp = AppID(normalized: "/Applications/Beta.app")
        let initialConfig = AppConfiguration(
            gridColumns: 9,
            gridRows: 7,
            iconSize: 96,
            showIconLabels: false,
            wallpaperBlurRadius: 42,
            searchBarWidth: 512,
            customSourceDirectories: ["/Applications", "/Users/test/Apps"],
            hiddenAppIDs: [firstApp, secondApp],
            language: .simplifiedChinese,
            hotkey: HotkeyConfig(enabled: true, keyCode: 49, modifiers: [.option]),
            hotCorner: HotCornerConfig(
                topLeft: .showLauncher,
                topRight: .hideLauncher,
                bottomLeft: .toggleLauncher,
                bottomRight: .none
            )
        )
        L10n.configure(language: initialConfig.language)
        let handler = SettingsHandlerStub(
            config: initialConfig,
            allApps: [(firstApp, "Alpha"), (secondApp, "Beta")]
        )
        let controller = SettingsWindowController(handler: handler)
        let child = try #require(controller.window)
        let parent = NSWindow(
            contentRect: NSRect(x: 10, y: 20, width: 1_000, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        parent.addChildWindow(child, ordered: .above)
        let originalFrame = NSRect(x: 321, y: 234, width: 760, height: 680)
        child.setFrame(originalFrame, display: false)

        try table(identifier: "settings.sources", in: child).selectRowIndexes(
            IndexSet(integer: 1),
            byExtendingSelection: false
        )
        try table(identifier: "settings.hiddenApps", in: child).selectRowIndexes(
            IndexSet(integer: 1),
            byExtendingSelection: false
        )

        try selectLanguage(at: 1, in: child)
        #expect(child.title == "LaunchBetter Settings")
        #expect(textValues(in: try #require(child.contentView)).contains("Grid"))
        #expect(textValues(in: try #require(child.contentView)).contains("Blur Intensity"))
        #expect(buttonTitles(in: try #require(child.contentView)).contains("Add Folder…"))
        #expect(try hotCornerTitles(in: child) == ["None", "Show Launcher", "Hide Launcher", "Toggle Launcher"])
        assertConfiguration(handler.config, language: .english)
        try assertWindowAndSelectionState(child: child, parent: parent, frame: originalFrame)

        try selectLanguage(at: 3, in: child)
        #expect(child.title == "LaunchBetter 設定")
        #expect(textValues(in: try #require(child.contentView)).contains("網格"))
        #expect(textValues(in: try #require(child.contentView)).contains("模糊強度"))
        #expect(buttonTitles(in: try #require(child.contentView)).contains("加入目錄…"))
        #expect(try hotCornerTitles(in: child) == ["無", "顯示啟動器", "隱藏啟動器", "切換啟動器"])
        assertConfiguration(handler.config, language: .traditionalChinese)
        try assertWindowAndSelectionState(child: child, parent: parent, frame: originalFrame)
    }

    @Test("language refresh preserves the exact selected occurrence of a duplicate source")
    func languageRefreshPreservesDuplicateSourceSelection() throws {
        let previousLanguage = L10n.currentLanguage
        defer { L10n.configure(language: previousLanguage) }

        let duplicatePath = "/Applications"
        let handler = SettingsHandlerStub(config: AppConfiguration(
            customSourceDirectories: [duplicatePath, duplicatePath, "/Users/test/Apps"],
            language: .simplifiedChinese
        ))
        L10n.configure(language: .simplifiedChinese)
        let controller = SettingsWindowController(handler: handler)
        let window = try #require(controller.window)
        try table(identifier: "settings.sources", in: window).selectRowIndexes(
            IndexSet(integer: 1),
            byExtendingSelection: false
        )

        try selectLanguage(at: 1, in: window)

        #expect(handler.config.customSourceDirectories == [
            duplicatePath, duplicatePath, "/Users/test/Apps",
        ])
        #expect(try table(identifier: "settings.sources", in: window).selectedRow == 1)
    }

    private func assertSharedValueColumn(language: AppLanguage) throws {
        let previousLanguage = L10n.currentLanguage
        L10n.configure(language: language)
        defer { L10n.configure(language: previousLanguage) }

        let controller = SettingsWindowController(
            handler: SettingsHandlerStub(config: AppConfiguration(language: language))
        )
        let window = try #require(controller.window)
        let contentView = try #require(window.contentView)
        window.layoutIfNeeded()
        contentView.layoutSubtreeIfNeeded()

        let grids = descendants(of: NSGridView.self, in: contentView)
        #expect(grids.count >= 6)
        #expect(grids.allSatisfy { $0.numberOfColumns == 2 && $0.numberOfRows >= 1 })

        let referenceWidth = try #require(grids.first?.column(at: 0).width)
        for grid in grids {
            #expect(abs(grid.column(at: 0).width - referenceWidth) < 0.5)
        }

        let valueXs = grids.flatMap { grid in
            (0..<grid.numberOfRows).compactMap { row in
                grid.cell(atColumnIndex: 1, rowIndex: row).contentView.map {
                    contentView.convert($0.bounds, from: $0).minX
                }
            }
        }
        let referenceX = try #require(valueXs.first)
        for x in valueXs {
            #expect(abs(x - referenceX) < 0.5, "language=\(language) value x \(x) vs \(referenceX)")
        }
    }

    private func assertLabelsFitAndNoOverflow(language: AppLanguage) throws {
        let previousLanguage = L10n.currentLanguage
        L10n.configure(language: language)
        defer { L10n.configure(language: previousLanguage) }

        let controller = SettingsWindowController(
            handler: SettingsHandlerStub(config: AppConfiguration(language: language))
        )
        let window = try #require(controller.window)
        let contentView = try #require(window.contentView)
        window.layoutIfNeeded()
        contentView.layoutSubtreeIfNeeded()

        let grids = descendants(of: NSGridView.self, in: contentView)
        #expect(!grids.isEmpty)
        for grid in grids {
            let labelColumnWidth = grid.column(at: 0).width
            for row in 0..<grid.numberOfRows {
                let label = try #require(
                    grid.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField
                )
                let value = try #require(grid.cell(atColumnIndex: 1, rowIndex: row).contentView)
                #expect(label.intrinsicContentSize.width <= labelColumnWidth + 0.5)
                let labelFrame = contentView.convert(label.bounds, from: label)
                let valueFrame = contentView.convert(value.bounds, from: value)
                #expect(labelFrame.maxX <= valueFrame.minX + 0.5)
                #expect(valueFrame.maxX <= contentView.bounds.maxX)
                #expect(valueFrame.minX >= contentView.bounds.minX)
            }
        }
    }

    private func assertControlAlignment(language: AppLanguage) throws {
        let previousLanguage = L10n.currentLanguage
        L10n.configure(language: language)
        defer { L10n.configure(language: previousLanguage) }

        let controller = SettingsWindowController(
            handler: SettingsHandlerStub(config: AppConfiguration(language: language))
        )
        let window = try #require(controller.window)
        let contentView = try #require(window.contentView)
        window.layoutIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        let sharedX = try sharedValueX(in: contentView)

        let showLabels = try #require(descendant(
            of: NSButton.self,
            identifier: "settings.showLabels",
            in: contentView
        ))
        #expect(abs(minX(of: showLabels, in: contentView) - sharedX) < 0.5)
        let hotkeyEnabled = try #require(descendant(
            of: NSButton.self,
            identifier: "settings.hotkeyEnabled",
            in: contentView
        ))
        #expect(abs(minX(of: hotkeyEnabled, in: contentView) - sharedX) < 0.5)
        let hotkeyPopup = try #require(descendant(
            of: NSPopUpButton.self,
            identifier: "settings.hotkey",
            in: contentView
        ))
        #expect(minX(of: hotkeyPopup, in: contentView) > sharedX)
        let iconSize = try #require(descendant(
            of: NSPopUpButton.self,
            identifier: "settings.iconSize",
            in: contentView
        ))
        #expect(abs(minX(of: iconSize, in: contentView) - sharedX) < 0.5)
        let languagePopup = try #require(descendant(
            of: NSPopUpButton.self,
            identifier: "settings.language",
            in: contentView
        ))
        #expect(abs(minX(of: languagePopup, in: contentView) - sharedX) < 0.5)
        for index in 0..<4 {
            let corner = try #require(descendant(
                of: NSPopUpButton.self,
                identifier: "settings.hotCorner.\(index)",
                in: contentView
            ))
            #expect(abs(minX(of: corner, in: contentView) - sharedX) < 0.5)
        }
        let blurSlider = try #require(descendant(
            of: NSSlider.self,
            identifier: "settings.blur",
            in: contentView
        ))
        let blurValueStack = try #require(blurSlider.superview)
        #expect(abs(minX(of: blurValueStack, in: contentView) - sharedX) < 0.5)
        let searchSlider = try #require(descendant(
            of: NSSlider.self,
            identifier: "settings.searchBarSize",
            in: contentView
        ))
        let searchValueStack = try #require(searchSlider.superview)
        #expect(abs(minX(of: searchValueStack, in: contentView) - sharedX) < 0.5)
    }

    private func sharedValueX(in contentView: NSView) throws -> CGFloat {
        let grids = descendants(of: NSGridView.self, in: contentView)
        let xs = grids.flatMap { grid in
            (0..<grid.numberOfRows).compactMap { row in
                grid.cell(atColumnIndex: 1, rowIndex: row).contentView.map {
                    contentView.convert($0.bounds, from: $0).minX
                }
            }
        }
        return try #require(xs.first)
    }

    private func minX(of view: NSView, in contentView: NSView) -> CGFloat {
        contentView.convert(view.bounds, from: view).minX
    }

    private func selectLanguage(at index: Int, in window: NSWindow) throws {
        let contentView = try #require(window.contentView)
        let popup = try #require(descendant(
            of: NSPopUpButton.self,
            identifier: "settings.language",
            in: contentView
        ))
        popup.selectItem(at: index)
        #expect(popup.sendAction(popup.action, to: popup.target))
    }

    private func hotCornerTitles(in window: NSWindow) throws -> [String] {
        let contentView = try #require(window.contentView)
        let popup = try #require(descendants(of: NSPopUpButton.self, in: contentView).first {
            $0.identifier?.rawValue == "settings.hotCorner.0"
        })
        return popup.itemTitles
    }

    private func table(identifier: String, in window: NSWindow) throws -> NSTableView {
        let contentView = try #require(window.contentView)
        return try #require(descendant(
            of: NSTableView.self,
            identifier: identifier,
            in: contentView
        ))
    }

    private func rowText(in table: NSTableView, row: Int) throws -> String {
        let view = table.view(atColumn: 0, row: row, makeIfNecessary: true)
        if let cell = view as? SettingsHiddenRowCell {
            return cell.nameLabel.stringValue
        }
        return try #require(view as? NSTextField).stringValue
    }

    private func hiddenCell(in window: NSWindow, row: Int) throws -> SettingsHiddenRowCell {
        let hidden = try table(identifier: "settings.hiddenApps", in: window)
        return try #require(
            hidden.view(atColumn: 0, row: row, makeIfNecessary: true) as? SettingsHiddenRowCell
        )
    }

    private func assertWindowAndSelectionState(
        child: NSWindow,
        parent: NSWindow,
        frame: NSRect
    ) throws {
        #expect(child.frame == frame)
        #expect(child.parent === parent)
        #expect(try table(identifier: "settings.sources", in: child).selectedRow == 1)
        #expect(try table(identifier: "settings.hiddenApps", in: child).selectedRow == 1)
    }

    private func assertConfiguration(_ config: AppConfiguration, language: AppLanguage) {
        #expect(config.gridColumns == 9)
        #expect(config.gridRows == 7)
        #expect(config.iconSize == 96)
        #expect(!config.showIconLabels)
        #expect(config.wallpaperBlurRadius == 42)
        #expect(config.searchBarWidth == 512)
        #expect(config.customSourceDirectories == ["/Applications", "/Users/test/Apps"])
        #expect(config.hiddenAppIDs.map(\.rawValue) == [
            "/Applications/Alpha.app", "/Applications/Beta.app",
        ])
        #expect(config.language == language)
        #expect(config.hotkey == HotkeyConfig(enabled: true, keyCode: 49, modifiers: [.option]))
        #expect(config.hotCorner == HotCornerConfig(
            topLeft: .showLauncher,
            topRight: .hideLauncher,
            bottomLeft: .toggleLauncher,
            bottomRight: .none
        ))
    }

    private func textValues(in root: NSView) -> [String] {
        descendants(of: NSTextField.self, in: root).map(\.stringValue)
    }

    private func buttonTitles(in root: NSView) -> [String] {
        descendants(of: NSButton.self, in: root).map(\.title)
    }

    private func descendant<View: NSView>(
        of type: View.Type,
        identifier: String,
        in root: NSView
    ) -> View? {
        descendants(of: type, in: root).first { $0.identifier?.rawValue == identifier }
    }

    private func descendants<View: NSView>(of type: View.Type, in root: NSView) -> [View] {
        root.subviews.flatMap { view -> [View] in
            let current = (view as? View).map { [$0] } ?? []
            return current + descendants(of: type, in: view)
        }
    }
}

@MainActor
private final class SettingsIconProviderStub: IconImageProviding {
    var images: [AppID: CGImage]
    var returnNilFor: Set<AppID>
    let deferred: Bool
    private var pending: [AppID: CheckedContinuation<CGImage?, Never>] = [:]
    private(set) var requestedAppIDs: [AppID] = []

    init(
        images: [AppID: CGImage] = [:],
        returnNilFor: Set<AppID> = [],
        deferred: Bool = false
    ) {
        self.images = images
        self.returnNilFor = returnNilFor
        self.deferred = deferred
    }

    func icon(for appID: AppID, pointSize: Int, scale: Int) async -> CGImage? {
        requestedAppIDs.append(appID)
        if returnNilFor.contains(appID) { return nil }
        if deferred {
            return await withCheckedContinuation { continuation in
                pending[appID] = continuation
            }
        }
        if let image = images[appID] { return image }
        return nil
    }

    func resolve(_ appID: AppID, with image: CGImage?) {
        pending.removeValue(forKey: appID)?.resume(returning: image)
    }

    func trimMemoryForHidden() {}
}

private func makeTestImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
    let context = CGContext(
        data: nil,
        width: 2,
        height: 2,
        bitsPerComponent: 8,
        bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    return context.makeImage()!
}

@MainActor
private final class SettingsHandlerStub: SettingsHandling {
    private(set) var config: AppConfiguration
    let allApps: [(id: AppID, name: String)]

    init(
        config: AppConfiguration,
        allApps: [(id: AppID, name: String)] = []
    ) {
        self.config = config
        self.allApps = allApps
    }

    func save(_ config: AppConfiguration) {
        self.config = config
        L10n.configure(language: config.language)
    }

    func replaceConfig(_ config: AppConfiguration) {
        self.config = config
    }
}

/// 模拟 LauncherStore.save 语义(持久化成功 → config 替换 → revision 递增 →
/// onDataChange 通知), 并用与 LauncherStore.displayModel() 相同的 DisplayModel
/// 派生路径验证主 Launch 面板的过滤结果。
@MainActor
private final class MiniStoreStub: SettingsHandling {
    private(set) var config: AppConfiguration
    let allApps: [(id: AppID, name: String)]
    private(set) var saveCount = 0
    private(set) var revision: UInt64 = 0
    var onDataChange: (() -> Void)?
    var onCustomSourcesChange: (([String]) -> Void)?
    private let layout: LayoutSnapshot

    init(
        config: AppConfiguration,
        allApps: [(id: AppID, name: String)],
        layout: LayoutSnapshot
    ) {
        self.config = config
        self.allApps = allApps
        self.layout = layout
    }

    func save(_ config: AppConfiguration) {
        let customSourcesChanged = config.customSourceDirectories != self.config.customSourceDirectories
        saveCount += 1
        self.config = config
        revision &+= 1
        L10n.configure(language: config.language)
        if customSourcesChanged {
            onCustomSourcesChange?(config.customSourceDirectories)
        }
        onDataChange?()
    }

    func visibleAppIDs() -> [AppID] {
        DisplayModel(
            catalog: CatalogSnapshot(apps: []),
            layout: layout,
            config: config
        ).visibleAppIDs
    }
}

@MainActor
private final class SettingsPanelStub {
    private(set) var sourceParent: NSWindow?
    private(set) var hiddenParent: NSWindow?
    private(set) var hiddenApps: [(id: AppID, name: String)] = []
    private(set) var sourcePresentationCount = 0
    private(set) var hiddenPresentationCount = 0
    private var sourceCompletion: ((URL?) -> Void)?
    private var hiddenCompletion: ((AppID?) -> Void)?

    var sourcePresenter: SettingsSourcePanelPresenter {
        { [weak self] parent, completion in
            self?.sourcePresentationCount += 1
            self?.sourceParent = parent
            self?.sourceCompletion = completion
        }
    }

    var hiddenPresenter: SettingsHiddenPanelPresenter {
        { [weak self] parent, apps, completion in
            self?.hiddenPresentationCount += 1
            self?.hiddenParent = parent
            self?.hiddenApps = apps
            self?.hiddenCompletion = completion
        }
    }

    func completeSource(_ url: URL?) {
        let completion = sourceCompletion
        sourceCompletion = nil
        completion?(url)
    }

    func completeHidden(_ appID: AppID?) {
        let completion = hiddenCompletion
        hiddenCompletion = nil
        completion?(appID)
    }
}
