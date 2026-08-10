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

/// 设置窗口(AppKit; 与启动器一致深色毛玻璃风格)。
@MainActor
public final class SettingsWindowController: NSWindowController {
    private let handler: any SettingsHandling

    /// 由启动器作为 child window 挂载(浮在启动器上方, 启动器不退出)。
    public weak var launcherWindow: NSWindow?

    public init(handler: any SettingsHandling) {
        self.handler = handler
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.t(.settingsTitle)
        // 与启动器一致的深色毛玻璃风格(用户反馈原窗口微蓝/小/看不清)。
        // isOpaque = true + 深色背景: 标题栏红绿灯保持在面板内(不透明, 无穿透)。
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1)
        window.isOpaque = true
        window.titlebarAppearsTransparent = true
        // 拖动面板空白区域即移动设置窗口, 不会把事件透传/误触发底下的启动器应用(v0.3.4)
        window.isMovableByWindowBackground = true
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 显示(由启动器先 addChildWindow 再调用; 关闭时自动从父窗口移除)。
    public func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// 关闭(含窗口关闭按钮)时从启动器父窗口移除 child。
    public override func close() {
        if let launcherWindow {
            launcherWindow.removeChildWindow(window!)
        }
        super.close()
    }

    deinit {
        // 兜底: 若关闭按钮直接销毁, 从父窗口移除
        if let launcherWindow, let window {
            MainActor.assumeIsolated {
                launcherWindow.removeChildWindow(window)
            }
        }
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
    private var blurSlider: NSSlider!
    private var blurLabel: NSTextField!
    private var searchBarSlider: NSSlider!
    private var searchBarLabel: NSTextField!
    private var hotCornerPopups: [NSPopUpButton] = []
    private var sourcesList: NSTableView!
    private var sourcesData: [String] = []
    private var hiddenList: NSTableView!
    private var hiddenData: [AppID] = []

    private func buildContent() {
        guard let window else { return }
        // 点击面板外(设置失去 key)→ 关闭设置(用户要求)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close()
            }
        }
        // 毛玻璃背景(与启动器一致)
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        window.contentView = effect

        let root = effect
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
            label.font = .boldSystemFont(ofSize: 15)
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
        let blurSlider = NSSlider(value: Double(config.wallpaperBlurRadius), minValue: 0, maxValue: 60, target: self, action: #selector(valueChanged))
        blurSlider.isContinuous = true
        self.blurSlider = blurSlider
        let blurLabel = NSTextField(labelWithString: "\(config.wallpaperBlurRadius)")
        self.blurLabel = blurLabel
        left.addArrangedSubview(row(L10n.t(.blurIntensityLabel), NSStackView(views: [blurLabel, blurSlider])))

        left.addArrangedSubview(sectionLabel(L10n.t(.searchBarSection)))
        let searchBarSlider = NSSlider(value: Double(config.searchBarWidth), minValue: 200, maxValue: 600, target: self, action: #selector(valueChanged))
        searchBarSlider.isContinuous = true
        self.searchBarSlider = searchBarSlider
        let searchBarLabel = NSTextField(labelWithString: "\(config.searchBarWidth)")
        self.searchBarLabel = searchBarLabel
        left.addArrangedSubview(row(L10n.t(.searchBarWidthLabel), NSStackView(views: [searchBarLabel, searchBarSlider])))

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
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        let stack = NSStackView(views: [label, view])
        stack.spacing = 8
        return stack
    }

    private func buildSourcesSection() -> NSStackView {
        sourcesData = config.customSourceDirectories
        let scroll = NSScrollView()
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 300).isActive = true
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
        scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 300).isActive = true
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
        blurLabel?.stringValue = "\(Int(blurSlider?.doubleValue ?? 0))"
        searchBarLabel?.stringValue = "\(Int(searchBarSlider?.doubleValue ?? 320))"
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
        config.wallpaperBlurRadius = Int(blurSlider.doubleValue)
        config.searchBarWidth = Int(searchBarSlider.doubleValue)
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
