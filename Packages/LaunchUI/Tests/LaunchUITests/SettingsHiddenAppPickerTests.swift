import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Settings hidden app picker", .serialized)
@MainActor
struct SettingsHiddenAppPickerTests {
    @Test("initial list is complete, stable, and uses the icon-left row layout")
    func initialListAndLayout() throws {
        let first = AppID(normalized: "/Applications/Alpha.app")
        let second = AppID(normalized: "/Applications/Beta.app")
        let third = AppID(normalized: "/Users/test/Tools/Toolbox.app")
        let picker = SettingsHiddenAppPickerController(
            apps: [
                (third, "Toolbox"),
                (second, "Beta"),
                (first, "Alpha"),
                (first, "Duplicate Alpha"),
            ],
            iconProvider: nil
        )

        #expect(picker.allCandidates.map(\.name) == ["Alpha", "Beta", "Toolbox"])
        #expect(picker.filteredCandidates == picker.allCandidates)
        #expect(picker.tableView.numberOfRows == 3)
        #expect(picker.selectedAppID == first)

        let contentView = try #require(picker.window?.contentView)
        #expect(descendant(of: NSSearchField.self, in: contentView) === picker.searchField)
        #expect(descendant(of: NSTableView.self, in: contentView) === picker.tableView)
        #expect(descendant(of: NSPopUpButton.self, in: contentView) == nil)

        let cell = try #require(
            picker.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? SettingsHiddenRowCell
        )
        #expect(cell.contentStack.arrangedSubviews.first === cell.iconView)
        #expect(cell.contentStack.arrangedSubviews.dropFirst().first === cell.nameLabel)
        #expect(cell.nameLabel.stringValue == "Alpha")
        #expect(cell.iconView.image != nil)
    }

    @Test("search filters by localized-insensitive name and path")
    func searchFiltersNameAndPath() {
        let alpha = AppID(normalized: "/Applications/Alpha.app")
        let toolbox = AppID(normalized: "/Users/test/Tools/Toolbox.app")
        let picker = SettingsHiddenAppPickerController(
            apps: [(alpha, "Résumé"), (toolbox, "Toolbox")],
            iconProvider: nil
        )

        picker.searchField.stringValue = "resume"
        picker.controlTextDidChange(
            Notification(name: NSSearchField.textDidChangeNotification, object: picker.searchField)
        )
        #expect(picker.filteredCandidates.map(\.id) == [alpha])

        picker.searchField.stringValue = "TOOLBOX.APP"
        picker.controlTextDidChange(
            Notification(name: NSSearchField.textDidChangeNotification, object: picker.searchField)
        )
        #expect(picker.filteredCandidates.map(\.id) == [toolbox])
    }

    @Test("no search result exposes an explicit empty state and disables confirmation")
    func emptyState() {
        let appID = AppID(normalized: "/Applications/Only.app")
        let picker = SettingsHiddenAppPickerController(
            apps: [(appID, "Only")],
            iconProvider: nil
        )

        picker.searchField.stringValue = "does-not-exist"
        picker.controlTextDidChange(
            Notification(name: NSSearchField.textDidChangeNotification, object: picker.searchField)
        )

        #expect(picker.filteredCandidates.isEmpty)
        #expect(picker.tableView.numberOfRows == 0)
        #expect(!picker.emptyStateLabel.isHidden)
        #expect(!picker.emptyStateLabel.stringValue.isEmpty)
        #expect(!picker.confirmButton.isEnabled)
        #expect(!picker.confirmSelection())
    }

    @Test("async icon result is scoped to the reused app identity")
    func asyncIconIdentity() async throws {
        let first = AppID(normalized: "/Applications/First.app")
        let second = AppID(normalized: "/Applications/Second.app")
        let provider = PickerIconProviderStub()
        let firstImage = makePickerImage(red: 1, green: 0, blue: 0)
        let secondImage = makePickerImage(red: 0, green: 0, blue: 1)
        let picker = SettingsHiddenAppPickerController(
            apps: [(first, "First"), (second, "Second")],
            iconProvider: provider
        )
        let cell = try #require(
            picker.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true)
                as? SettingsHiddenRowCell
        )

        provider.images = [first: firstImage, second: secondImage]
        cell.configure(
            appID: first,
            name: "First",
            provider: provider,
            pointSize: SettingsHiddenAppPickerController.iconPointSize,
            scale: 2
        )
        cell.configure(
            appID: second,
            name: "Second",
            provider: provider,
            pointSize: SettingsHiddenAppPickerController.iconPointSize,
            scale: 2
        )
        await cell.waitForIcon()
        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(cell.appliedCGImage === secondImage)
        #expect(cell.nameLabel.stringValue == "Second")
    }

    @Test("confirm and cancel are sheet-owned and cancel has no side effect")
    func confirmAndCancel() throws {
        let first = AppID(normalized: "/Applications/First.app")
        let second = AppID(normalized: "/Applications/Second.app")
        let parent = makeParentWindow()
        let picker = SettingsHiddenAppPickerController(
            apps: [(first, "First"), (second, "Second")],
            iconProvider: nil
        )

        var confirmed: AppID?
        #expect(picker.present(in: parent) { confirmed = $0 })
        #expect(parent.attachedSheet === picker.window)
        picker.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(picker.confirmSelection())
        #expect(confirmed == second)

        var cancelled = false
        let cancelPicker = SettingsHiddenAppPickerController(
            apps: [(first, "First")],
            iconProvider: nil
        )
        #expect(cancelPicker.present(in: parent) { appID in
            cancelled = appID == nil
        })
        #expect(cancelPicker.cancelButton.keyEquivalent == "\u{1b}")
        #expect(cancelPicker.cancelSelection())
        #expect(cancelled)
    }

    @Test("Settings presenter excludes hidden apps and default wiring shows the picker sheet")
    func settingsPresenterFiltersAndWiresPicker() throws {
        let hidden = AppID(normalized: "/Applications/AlreadyHidden.app")
        let beta = AppID(normalized: "/Applications/Beta.app")
        let alpha = AppID(normalized: "/Applications/Alpha.app")
        let handler = PickerSettingsHandler(
            config: AppConfiguration(hiddenAppIDs: [hidden], language: .english),
            allApps: [
                (hidden, "Already Hidden"),
                (beta, "Beta"),
                (alpha, "Alpha"),
            ]
        )
        let controller = SettingsWindowController(handler: handler)
        let settingsWindow = try #require(controller.window)
        let settingsContent = try #require(settingsWindow.contentView)
        let addButton = try #require(
            descendant(of: NSButton.self, identifier: "addHidden", in: settingsContent)
        )

        #expect(addButton.sendAction(addButton.action, to: addButton.target))
        let sheet = try #require(settingsWindow.attachedSheet)
        let sheetContent = try #require(sheet.contentView)
        let search = try #require(descendant(of: NSSearchField.self, in: sheetContent))
        let table = try #require(descendant(of: NSTableView.self, in: sheetContent))
        #expect(search.identifier?.rawValue == "settings.hiddenPicker.search")
        #expect(table.numberOfRows == 2)
        #expect(descendant(of: NSPopUpButton.self, in: sheetContent) == nil)
        #expect(descendant(of: NSTextField.self, identifier: "settings.hiddenPicker.emptyState", in: sheetContent)?.isHidden == true)
        #expect(handler.config.hiddenAppIDs == [hidden])

        let cancel = try #require(
            descendant(of: NSButton.self, identifier: "settings.hiddenPicker.cancel", in: sheetContent)
        )
        #expect(cancel.sendAction(cancel.action, to: cancel.target))
        #expect(handler.config.hiddenAppIDs == [hidden])
    }

    private func makeParentWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    private func descendant<View: NSView>(
        of type: View.Type,
        identifier: String? = nil,
        in root: NSView
    ) -> View? {
        descendants(of: type, in: root).first { view in
            identifier == nil || view.identifier?.rawValue == identifier
        }
    }

    private func descendants<View: NSView>(of type: View.Type, in root: NSView) -> [View] {
        root.subviews.flatMap { view in
            let current = (view as? View).map { [$0] } ?? []
            return current + descendants(of: type, in: view)
        }
    }
}

@MainActor
private final class PickerIconProviderStub: IconImageProviding {
    var images: [AppID: CGImage] = [:]

    func icon(for appID: AppID, pointSize: Int, scale: Int) async -> CGImage? {
        if appID.rawValue.contains("First.app") {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return images[appID]
    }

    func trimMemoryForHidden() {}
}

@MainActor
private final class PickerSettingsHandler: SettingsHandling {
    private(set) var config: AppConfiguration
    let allApps: [(id: AppID, name: String)]

    init(
        config: AppConfiguration,
        allApps: [(id: AppID, name: String)]
    ) {
        self.config = config
        self.allApps = allApps
    }

    func save(_ config: AppConfiguration) {
        self.config = config
        L10n.configure(language: config.language)
    }
}

private func makePickerImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
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
