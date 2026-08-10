import AppKit
import LaunchCore

/// 设置数据处理器(由应用层实现)。
@MainActor
public protocol SettingsHandling: AnyObject {
    var config: AppConfiguration { get }
    func save(_ config: AppConfiguration)
    /// 全部应用(隐藏应用选择用)。
    var allApps: [(id: AppID, name: String)] { get }
}

/// 设置窗口(AppKit; SwiftUI 许可但保持本层一致性)。
@MainActor
public final class SettingsWindowController: NSWindowController {
    private let handler: any SettingsHandling

    public init(handler: any SettingsHandling) {
        self.handler = handler
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.t(.settingsTitle)
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - UI

    private var config: AppConfiguration { handler.config }
    private var columnsStepper: NSStepper!
    private var rowsStepper: NSStepper!
    private var columnsLabel: NSTextField!
    private var rowsLabel: NSTextField!
    private var iconSizePopup: NSPopUpButton!
    private var showLabelsCheck: NSButton!
    private var languagePopup: NSPopUpButton!
    private var hotkeyCheck: NSButton!
    private var hotkeyPopup: NSPopUpButton!
    private var wallpaperCheck: NSButton!
    private var hotCornerPopups: [NSPopUpButton] = []
    private var sourcesList: NSTableView!
    private var sourcesData: [String] = []
    private var hiddenList: NSTableView!
    private var hiddenData: [AppID] = []

    private func buildContent() {
        guard let window else { return }
        let root = NSView()
        window.contentView = root

        let grid = NSGridView(views: [])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)

        // 网格
        columnsStepper = NSStepper()
        columnsStepper.minValue = 4
        columnsStepper.maxValue = 10
        columnsStepper.integerValue = config.gridColumns
        columnsStepper.target = self
        columnsStepper.action = #selector(gridChanged)
        columnsLabel = NSTextField(labelWithString: "\(config.gridColumns)")
        rowsStepper = NSStepper()
        rowsStepper.minValue = 3
        rowsStepper.maxValue = 8
        rowsStepper.integerValue = config.gridRows
        rowsStepper.target = self
        rowsStepper.action = #selector(gridChanged)
        rowsLabel = NSTextField(labelWithString: "\(config.gridRows)")
        let colsRow = NSStackView(views: [columnsLabel, columnsStepper])
        colsRow.spacing = 8
        let rowsRow = NSStackView(views: [rowsLabel, rowsStepper])
        rowsRow.spacing = 8

        iconSizePopup = NSPopUpButton()
        iconSizePopup.addItems(withTitles: ["48", "64", "80", "96"])
        iconSizePopup.selectItem(withTitle: "\(config.iconSize)")
        iconSizePopup.target = self
        iconSizePopup.action = #selector(valueChanged)

        showLabelsCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(valueChanged))
        showLabelsCheck.state = config.showIconLabels ? .on : .off

        // 语言
        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: ["跟随系统", "English", "简体中文", "繁體中文"])
        languagePopup.selectItem(at: index(for: config.language))
        languagePopup.target = self
        languagePopup.action = #selector(valueChanged)

        // 热键
        hotkeyCheck = NSButton(checkboxWithTitle: L10n.t(.hotkeyEnabled), target: self, action: #selector(valueChanged))
        hotkeyCheck.state = config.hotkey.enabled ? .on : .off
        hotkeyPopup = NSPopUpButton()
        hotkeyPopup.addItems(withTitles: ["⌘L", "⌘Space", "⌥Space", "⇧⌘L", "⌃⌥L"])
        hotkeyPopup.selectItem(at: hotkeyPresetIndex)

        // 壁纸
        wallpaperCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(valueChanged))
        wallpaperCheck.state = wallpaperBlurEnabled ? .on : .off

        // 热角
        hotCornerPopups = (0..<4).map { _ in
            let popup = NSPopUpButton()
            popup.addItems(withTitles: [L10n.t(.none), L10n.t(.cornerShow), L10n.t(.cornerHide), L10n.t(.cornerToggle)])
            popup.target = self
            popup.action = #selector(valueChanged)
            return popup
        }
        let cornerActions = [config.hotCorner.topLeft, config.hotCorner.topRight, config.hotCorner.bottomLeft, config.hotCorner.bottomRight]
        for (popup, action) in zip(hotCornerPopups, cornerActions) {
            popup.selectItem(at: index(for: action))
        }

        // 布局: 分两列 section
        let sectionLabel = { (text: String) -> NSTextField in
            let label = NSTextField(labelWithString: text)
            label.font = .boldSystemFont(ofSize: 13)
            return label
        }

        let left = NSStackView()
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 10
        left.addArrangedSubview(sectionLabel(L10n.t(.gridSection)))
        left.addArrangedSubview(row(L10n.t(.columnsLabel), colsRow))
        left.addArrangedSubview(row(L10n.t(.rowsLabel), rowsRow))
        left.addArrangedSubview(row(L10n.t(.iconSizeLabel), iconSizePopup))
        left.addArrangedSubview(row(L10n.t(.showLabelsLabel), showLabelsCheck))
        left.addArrangedSubview(sectionLabel(L10n.t(.languageLabel)))
        left.addArrangedSubview(languagePopup)
        left.addArrangedSubview(sectionLabel(L10n.t(.hotkeyLabel)))
        left.addArrangedSubview(row("", NSStackView(views: [hotkeyCheck, hotkeyPopup])))
        left.addArrangedSubview(sectionLabel(L10n.t(.hotCornerLabel)))
        left.addArrangedSubview(row("↖", hotCornerPopups[0]))
        left.addArrangedSubview(row("↗", hotCornerPopups[1]))
        left.addArrangedSubview(row("↙", hotCornerPopups[2]))
        left.addArrangedSubview(row("↘", hotCornerPopups[3]))
        left.addArrangedSubview(sectionLabel(L10n.t(.wallpaperLabel)))
        left.addArrangedSubview(wallpaperCheck)

        // 关于(Stage B5): 版本 + 来源链接
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        left.addArrangedSubview(sectionLabel(L10n.t(.aboutLabel)))
        left.addArrangedSubview(NSTextField(labelWithString: "LaunchBetter v\(version)"))

        let right = NSStackView()
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        right.addArrangedSubview(sectionLabel(L10n.t(.customSourcesLabel)))
        right.addArrangedSubview(buildSourcesSection())
        right.addArrangedSubview(sectionLabel(L10n.t(.hiddenAppsLabel)))
        right.addArrangedSubview(buildHiddenSection())

        let content = NSStackView(views: [left, right])
        content.orientation = .horizontal
        content.spacing = 30
        content.alignment = .top
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20),
        ])
    }

    private func row(_ title: String, _ view: NSView) -> NSStackView {
        let stack = NSStackView(views: [NSTextField(labelWithString: title), view])
        stack.spacing = 8
        return stack
    }

    private func buildSourcesSection() -> NSStackView {
        sourcesData = config.customSourceDirectories
        let scroll = NSScrollView()
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 240).isActive = true
        sourcesList = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("src"))
        column.width = 220
        sourcesList.addTableColumn(column)
        sourcesList.headerView = nil
        sourcesList.dataSource = self
        sourcesList.delegate = self
        scroll.documentView = sourcesList

        let add = NSButton(title: L10n.t(.addSource), target: self, action: #selector(addSource))
        let remove = NSButton(title: L10n.t(.remove), target: self, action: #selector(removeSource))
        remove.isEnabled = false
        remove.identifier = NSUserInterfaceItemIdentifier("removeSource")
        let buttons = NSStackView(views: [add, remove])
        buttons.spacing = 8
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 6
        return stack
    }

    private func buildHiddenSection() -> NSStackView {
        hiddenData = config.hiddenAppIDs
        let scroll = NSScrollView()
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 240).isActive = true
        hiddenList = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hid"))
        column.width = 220
        hiddenList.addTableColumn(column)
        hiddenList.headerView = nil
        hiddenList.dataSource = self
        hiddenList.delegate = self
        scroll.documentView = hiddenList

        let add = NSButton(title: L10n.t(.addHiddenApp), target: self, action: #selector(addHiddenApp))
        let remove = NSButton(title: L10n.t(.remove), target: self, action: #selector(removeHiddenApp))
        remove.isEnabled = false
        remove.identifier = NSUserInterfaceItemIdentifier("removeHidden")
        let buttons = NSStackView(views: [add, remove])
        buttons.spacing = 8
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 6
        return stack
    }

    // MARK: - 值映射

    private func index(for language: AppLanguage) -> Int {
        switch language {
        case .system: return 0
        case .english: return 1
        case .simplifiedChinese: return 2
        case .traditionalChinese: return 3
        }
    }

    private func index(for action: HotCornerAction) -> Int {
        switch action {
        case .none: return 0
        case .showLauncher: return 1
        case .hideLauncher: return 2
        case .toggleLauncher: return 3
        }
    }

    private var hotkeyPresetIndex: Int {
        let key = config.hotkey.keyCode
        let mods = config.hotkey.modifiers
        if key == 49 && mods == [.command] { return 1 } // Cmd+Space
        if key == 49 && mods == [.option] { return 2 }
        if key == 37 && mods == [.command, .shift] { return 3 }
        if key == 37 && mods == [.control, .option] { return 4 }
        return 0 // Cmd+L
    }

    private var wallpaperBlurEnabled: Bool {
        UserDefaults.standard.object(forKey: "wallpaperBlurEnabled") as? Bool ?? true
    }

    private func saveWallpaperPreference() {
        UserDefaults.standard.set(wallpaperCheck.state == .on, forKey: "wallpaperBlurEnabled")
    }

    // MARK: - 动作

    @objc private func gridChanged() {
        columnsLabel.stringValue = "\(columnsStepper.integerValue)"
        rowsLabel.stringValue = "\(rowsStepper.integerValue)"
        commit()
    }

    @objc private func valueChanged() {
        commit()
    }

    @objc private func addSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourcesData.append(url.path)
        sourcesList.reloadData()
        commit()
    }

    @objc private func removeSource() {
        let row = sourcesList.selectedRow
        guard row >= 0, row < sourcesData.count else { return }
        sourcesData.remove(at: row)
        sourcesList.reloadData()
        commit()
    }

    @objc private func addHiddenApp() {
        let panel = NSAlert()
        panel.messageText = L10n.t(.hiddenAppsLabel)
        let popup = NSPopUpButton()
        for app in handler.allApps {
            popup.addItem(withTitle: app.name)
            popup.lastItem?.representedObject = app.id
        }
        panel.accessoryView = popup
        panel.addButton(withTitle: L10n.t(.ok))
        panel.addButton(withTitle: L10n.t(.cancel))
        guard panel.runModal() == .alertFirstButtonReturn,
              let id = popup.selectedItem?.representedObject as? AppID,
              !hiddenData.contains(id) else { return }
        hiddenData.append(id)
        hiddenList.reloadData()
        commit()
    }

    @objc private func removeHiddenApp() {
        let row = hiddenList.selectedRow
        guard row >= 0, row < hiddenData.count else { return }
        hiddenData.remove(at: row)
        hiddenList.reloadData()
        commit()
    }

    /// 收集配置并保存(即时生效)。
    private func commit() {
        var config = self.config
        config.gridColumns = columnsStepper.integerValue
        config.gridRows = rowsStepper.integerValue
        config.iconSize = iconSizePopup.indexOfSelectedItem == 0 ? 48
            : iconSizePopup.indexOfSelectedItem == 1 ? 64
            : iconSizePopup.indexOfSelectedItem == 2 ? 80 : 96
        config.showIconLabels = showLabelsCheck.state == .on
        switch languagePopup.indexOfSelectedItem {
        case 1: config.language = .english
        case 2: config.language = .simplifiedChinese
        case 3: config.language = .traditionalChinese
        default: config.language = .system
        }
        let presets: [(UInt32, HotkeyModifiers)] = [
            (37, [.command]), (49, [.command]), (49, [.option]),
            (37, [.command, .shift]), (37, [.control, .option]),
        ]
        let preset = presets[min(hotkeyPopup.indexOfSelectedItem, presets.count - 1)]
        config.hotkey = HotkeyConfig(
            enabled: hotkeyCheck.state == .on,
            keyCode: preset.0,
            modifiers: preset.1
        )
        let cornerActions: [HotCornerAction] = hotCornerPopups.map {
            switch $0.indexOfSelectedItem {
            case 1: return .showLauncher
            case 2: return .hideLauncher
            case 3: return .toggleLauncher
            default: return .none
            }
        }
        config.hotCorner = HotCornerConfig(
            topLeft: cornerActions[0], topRight: cornerActions[1],
            bottomLeft: cornerActions[2], bottomRight: cornerActions[3]
        )
        config.customSourceDirectories = sourcesData
        config.hiddenAppIDs = hiddenData
        saveWallpaperPreference()
        handler.save(config)
    }
}

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        tableView == sourcesList ? sourcesData.count : hiddenData.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView == sourcesList {
            text = (row < sourcesData.count) ? sourcesData[row] : ""
        } else {
            text = (row < hiddenData.count)
                ? handler.allApps.first { $0.id == hiddenData[row] }?.name ?? hiddenData[row].rawValue
                : ""
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        if let tableView = notification.object as? NSTableView {
            let button = tableView == sourcesList
                ? tableView.superview?.subviews.compactMap { $0 as? NSStackView }.first?.views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "removeSource" }
                : tableView.superview?.subviews.compactMap { $0 as? NSStackView }.first?.views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "removeHidden" }
            button?.isEnabled = tableView.selectedRow >= 0
        }
    }
}
