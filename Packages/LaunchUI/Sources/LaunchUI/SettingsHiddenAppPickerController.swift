import AppKit
import LaunchCore

/// A candidate shown by the hidden-application picker.
///
/// The picker deliberately receives display data from SettingsHandling. It
/// does not scan the file system or reach into LaunchPlatform; icons continue
/// to flow through the LaunchUI-facing IconImageProviding boundary.
struct SettingsHiddenAppCandidate: Equatable, Sendable {
    let id: AppID
    let name: String
}

/// Finder-like sheet used to choose one application to hide.
///
/// The controller owns the sheet's view hierarchy and selection lifecycle. It
/// never runs a modal event loop, so AppKit keeps ownership of arrow-key,
/// Return, and Escape handling through the table/search field/button key-view
/// chain.
@MainActor
final class SettingsHiddenAppPickerController: NSWindowController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate,
    NSWindowDelegate
{
    static let iconPointSize = 40
    static let rowHeight: CGFloat = 56

    /// Stable, de-duplicated source order after localized name/path sorting.
    let allCandidates: [SettingsHiddenAppCandidate]

    /// Current rows after search filtering. This is internal for focused UI
    /// tests and is otherwise read-only to the rest of LaunchUI.
    private(set) var filteredCandidates: [SettingsHiddenAppCandidate]

    let searchField = NSSearchField()
    let tableView = NSTableView()
    let emptyStateLabel = NSTextField(labelWithString: "")
    let confirmButton = NSButton()
    let cancelButton = NSButton()

    private let iconProvider: (any IconImageProviding)?
    private weak var presentingParent: NSWindow?
    private var completion: ((AppID?) -> Void)?
    private var didFinish = false

    init(
        apps: [(id: AppID, name: String)],
        iconProvider: (any IconImageProviding)?
    ) {
        let sortedCandidates = Self.sortedCandidates(apps)
        allCandidates = sortedCandidates
        filteredCandidates = sortedCandidates
        self.iconProvider = iconProvider

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.t(.hiddenAppsLabel)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1)
        panel.isOpaque = true
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true

        super.init(window: panel)
        panel.delegate = self
        buildContent()
        applyFilter()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Presents the controller as a sheet owned by `parentWindow`.
    ///
    /// The completion is retained only for the active sheet. The default
    /// Settings presenter captures the controller in that completion so the
    /// controller remains alive until `finish` clears the cycle.
    @discardableResult
    func present(
        in parentWindow: NSWindow,
        completion: @escaping (AppID?) -> Void
    ) -> Bool {
        guard presentingParent == nil,
              self.completion == nil,
              parentWindow.attachedSheet == nil,
              let panel = window else {
            return false
        }

        didFinish = false
        presentingParent = parentWindow
        self.completion = completion
        panel.initialFirstResponder = searchField

        parentWindow.beginSheet(panel) { [weak self, weak panel] response in
            guard let self, let panel, self.window === panel, !self.didFinish else {
                return
            }
            self.finish(
                response == .OK ? self.selectedAppID : nil,
                returnCode: response
            )
        }
        return true
    }

    /// Confirms the current table selection. It is also the action behind the
    /// Return-key default button and is intentionally exposed as a small seam
    /// for direct picker tests.
    @discardableResult
    func confirmSelection() -> Bool {
        guard let selectedAppID else { return false }
        finish(selectedAppID, returnCode: .OK)
        return true
    }

    /// Cancels without changing Settings state. Escape reaches this through
    /// the cancel button's standard AppKit key equivalent.
    @discardableResult
    func cancelSelection() -> Bool {
        finish(nil, returnCode: .cancel)
        return true
    }

    var selectedAppID: AppID? {
        let row = tableView.selectedRow
        guard filteredCandidates.indices.contains(row) else { return nil }
        return filteredCandidates[row].id
    }

    // MARK: - Candidate ordering and filtering

    static func sortedCandidates(
        _ apps: [(id: AppID, name: String)]
    ) -> [SettingsHiddenAppCandidate] {
        var seen = Set<AppID>()
        let indexed = apps.enumerated().compactMap { index, app -> (
            index: Int,
            candidate: SettingsHiddenAppCandidate
        )? in
            guard seen.insert(app.id).inserted else { return nil }
            return (
                index: index,
                candidate: SettingsHiddenAppCandidate(id: app.id, name: app.name)
            )
        }

        return indexed.sorted { lhs, rhs in
            let nameOrder = lhs.candidate.name.localizedCaseInsensitiveCompare(rhs.candidate.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }

            let pathOrder = lhs.candidate.id.rawValue.localizedStandardCompare(
                rhs.candidate.id.rawValue
            )
            if pathOrder != .orderedSame {
                return pathOrder == .orderedAscending
            }
            return lhs.index < rhs.index
        }.map(\.candidate)
    }

    private func applyFilter() {
        let previousSelection = selectedAppID
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            filteredCandidates = allCandidates
        } else {
            filteredCandidates = allCandidates.filter { candidate in
                Self.matches(candidate.name, query: query)
                    || Self.matches(candidate.id.rawValue, query: query)
            }
        }

        tableView.reloadData()

        if let previousSelection,
           let row = filteredCandidates.firstIndex(where: { $0.id == previousSelection }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else if filteredCandidates.indices.contains(0) {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        } else {
            tableView.deselectAll(nil)
        }

        emptyStateLabel.isHidden = !filteredCandidates.isEmpty
        if filteredCandidates.isEmpty {
            emptyStateLabel.stringValue = allCandidates.isEmpty
                ? L10n.t(.hiddenAppNoCandidates)
                : L10n.t(.hiddenAppNoResults)
        }
        confirmButton.isEnabled = selectedAppID != nil
    }

    private static func matches(_ value: String, query: String) -> Bool {
        value.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            range: nil,
            locale: .current
        ) != nil
    }

    // MARK: - View construction

    private func buildContent() {
        guard let panel = window else { return }
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = root

        searchField.identifier = NSUserInterfaceItemIdentifier("settings.hiddenPicker.search")
        searchField.placeholderString = L10n.t(.searchPlaceholder)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        tableView.identifier = NSUserInterfaceItemIdentifier("settings.hiddenPicker.apps")
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.target = self

        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("settings.hiddenPicker.appColumn")
        )
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.identifier = NSUserInterfaceItemIdentifier("settings.hiddenPicker.scroll")
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyStateLabel.identifier = NSUserInterfaceItemIdentifier(
            "settings.hiddenPicker.emptyState"
        )
        emptyStateLabel.alignment = .center
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.font = .systemFont(ofSize: 13)
        emptyStateLabel.maximumNumberOfLines = 2
        emptyStateLabel.lineBreakMode = .byWordWrapping
        emptyStateLabel.isSelectable = false
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        confirmButton.title = L10n.t(.hideApp)
        confirmButton.identifier = NSUserInterfaceItemIdentifier("settings.hiddenPicker.confirm")
        confirmButton.bezelStyle = .rounded
        confirmButton.target = self
        confirmButton.action = #selector(confirmButtonClicked)
        confirmButton.keyEquivalent = "\r"

        cancelButton.title = L10n.t(.cancel)
        cancelButton.identifier = NSUserInterfaceItemIdentifier("settings.hiddenPicker.cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelButtonClicked)
        cancelButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [cancelButton, confirmButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(scrollView)
        root.addSubview(emptyStateLabel)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),

            emptyStateLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollView.leadingAnchor,
                constant: 20
            ),
            emptyStateLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollView.trailingAnchor,
                constant: -20
            ),

            buttons.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Actions and sheet lifecycle

    @objc private func confirmButtonClicked() {
        _ = confirmSelection()
    }

    @objc private func cancelButtonClicked() {
        _ = cancelSelection()
    }

    @objc private func tableDoubleClicked(_ sender: NSTableView) {
        guard sender.clickedRow >= 0 else { return }
        _ = confirmSelection()
    }

    private func finish(_ appID: AppID?, returnCode: NSApplication.ModalResponse) {
        guard !didFinish else { return }
        didFinish = true

        let parent = presentingParent
        presentingParent = nil
        let callback = completion
        completion = nil

        if let panel = window,
           let parent,
           parent.attachedSheet === panel {
            parent.endSheet(panel, returnCode: returnCode)
        }
        callback?(appID)
    }

    // MARK: - AppKit delegates

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        applyFilter()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredCandidates.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard filteredCandidates.indices.contains(row) else { return nil }
        let candidate = filteredCandidates[row]
        let cell = tableView.makeView(
            withIdentifier: SettingsHiddenRowCell.reuseIdentifier,
            owner: self
        ) as? SettingsHiddenRowCell ?? SettingsHiddenRowCell(frame: .zero)
        cell.configure(
            appID: candidate.id,
            name: candidate.name,
            provider: iconProvider,
            pointSize: Self.iconPointSize,
            scale: iconScale
        )
        cell.setAccessibilityLabel(candidate.name)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        confirmButton.isEnabled = selectedAppID != nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        _ = cancelSelection()
        return false
    }

    private var iconScale: Int {
        max(1, Int((window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2).rounded()))
    }
}
