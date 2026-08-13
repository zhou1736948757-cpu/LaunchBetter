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

typealias SettingsSourcePanelPresenter = (NSWindow, @escaping (URL?) -> Void) -> Void
typealias SettingsHiddenPanelPresenter = (
    NSWindow,
    [(id: AppID, name: String)],
    @escaping (AppID?) -> Void
) -> Void

/// Pure mapping for the Settings surface. AppKit values are applied only at
/// the view boundary below, so tests can cover all accessibility combinations
/// without changing system display settings.
struct SettingsAccessibilityAppearance: Equatable, Sendable {
    enum Material: Equatable, Sendable {
        case hudWindow
        case opaqueDark
    }

    enum BlendingMode: Equatable, Sendable {
        case behindWindow
        case withinWindow
    }

    enum SurfaceFill: Equatable, Sendable {
        case existingHudWindow
        case explicitDark
    }

    enum Boundary: Equatable, Sendable {
        case standard
        case emphasized
    }

    enum ForegroundSeparation: Equatable, Sendable {
        case standard
        case enhanced
    }

    let material: Material
    let blendingMode: BlendingMode
    let surfaceFill: SurfaceFill
    let boundary: Boundary
    let foregroundSeparation: ForegroundSeparation

    static func make(for snapshot: MotionEnvironmentSnapshot) -> Self {
        let materialPolicy = AccessibilityMaterialPolicy(snapshot: snapshot)
        return Self(
            material: materialPolicy.usesOpaqueSurface ? .opaqueDark : .hudWindow,
            blendingMode: materialPolicy.usesOpaqueSurface ? .withinWindow : .behindWindow,
            surfaceFill: materialPolicy.usesOpaqueSurface ? .explicitDark : .existingHudWindow,
            boundary: materialPolicy.emphasizesBoundary ? .emphasized : .standard,
            foregroundSeparation: materialPolicy.enhancesForegroundSeparation ? .enhanced : .standard
        )
    }

    /// Apply only surface/material properties. It does not touch window frame,
    /// alpha, transforms, or the Settings transition coordinator.
    @MainActor
    static func apply(_ appearance: Self, to effect: NSVisualEffectView) {
        effect.material = appearance.material == .opaqueDark ? .windowBackground : .hudWindow
        effect.blendingMode = appearance.blendingMode == .withinWindow
            ? .withinWindow
            : .behindWindow
        effect.state = .active
        effect.isEmphasized = appearance.foregroundSeparation == .enhanced

        if appearance.surfaceFill == .explicitDark || appearance.boundary == .emphasized {
            effect.wantsLayer = true
        }

        guard let layer = effect.layer else { return }
        switch appearance.surfaceFill {
        case .existingHudWindow:
            layer.backgroundColor = nil
        case .explicitDark:
            layer.backgroundColor = NSColor(
                calibratedRed: 0.10,
                green: 0.11,
                blue: 0.14,
                alpha: 1
            ).cgColor
        }

        switch appearance.boundary {
        case .standard:
            layer.borderWidth = 0
            layer.borderColor = nil
        case .emphasized:
            layer.borderWidth = 1
            layer.borderColor = NSColor(
                calibratedWhite: 1,
                alpha: 0.32
            ).cgColor
        }
    }
}

/// Settings fresh presentation 的纯定位策略。
///
/// 所有 rect 都使用 AppKit screen coordinates；计算不假设屏幕原点为零。
/// 当 Settings 比可见区域更大时无法完整容纳，保留其尺寸并贴齐可见区域的
/// minX/minY，避免通过缩放窗口改变用户的 resize 语义。
enum SettingsWindowPlacement {
    static let launcherCenterXRatio: CGFloat = 0.70
    static let launcherCenterYRatio: CGFloat = 0.52

    static func shouldPosition(for state: SettingsTransitionState) -> Bool {
        state == .hidden
    }

    static func frame(
        launcherFrame: NSRect,
        settingsSize: NSSize,
        visibleFrame: NSRect
    ) -> NSRect {
        guard launcherFrame.origin.x.isFinite,
              launcherFrame.origin.y.isFinite,
              launcherFrame.width.isFinite,
              launcherFrame.height.isFinite,
              settingsSize.width.isFinite,
              settingsSize.height.isFinite,
              settingsSize.width >= 0,
              settingsSize.height >= 0,
              visibleFrame.origin.x.isFinite,
              visibleFrame.origin.y.isFinite,
              visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width >= 0,
              visibleFrame.height >= 0 else {
            return NSRect(origin: launcherFrame.origin, size: settingsSize)
        }

        let targetCenter = NSPoint(
            x: launcherFrame.minX + launcherFrame.width * launcherCenterXRatio,
            y: launcherFrame.minY + launcherFrame.height * launcherCenterYRatio
        )
        let desiredOrigin = NSPoint(
            x: targetCenter.x - settingsSize.width / 2,
            y: targetCenter.y - settingsSize.height / 2
        )

        return NSRect(
            x: clampedOrigin(
                desiredOrigin.x,
                windowLength: settingsSize.width,
                visibleMinimum: visibleFrame.minX,
                visibleLength: visibleFrame.width
            ),
            y: clampedOrigin(
                desiredOrigin.y,
                windowLength: settingsSize.height,
                visibleMinimum: visibleFrame.minY,
                visibleLength: visibleFrame.height
            ),
            width: settingsSize.width,
            height: settingsSize.height
        )
    }

    private static func clampedOrigin(
        _ desiredOrigin: CGFloat,
        windowLength: CGFloat,
        visibleMinimum: CGFloat,
        visibleLength: CGFloat
    ) -> CGFloat {
        guard windowLength <= visibleLength else { return visibleMinimum }
        return min(
            max(desiredOrigin, visibleMinimum),
            visibleMinimum + visibleLength - windowLength
        )
    }
}

/// 设置窗口(AppKit; 与启动器一致深色毛玻璃风格)。
@MainActor
public final class SettingsWindowController: NSWindowController {
    private let handler: any SettingsHandling
    private let iconProvider: (any IconImageProviding)?
    private let sourcePanelPresenter: SettingsSourcePanelPresenter
    private let hiddenPanelPresenter: SettingsHiddenPanelPresenter
    private let notificationTokens = NotificationTokenRegistry()
    private var transitionCoordinator: SettingsTransitionCoordinator!
    private var accessibilityDisplayObserver: AccessibilityDisplayObserver?
    private weak var materialEffectView: NSVisualEffectView?
    private var pendingAccessibilityAppearance: SettingsAccessibilityAppearance?
    private var closeRequested = false
    private var closeCallbackDelivered = false
    private var finalizingClose = false

    /// 由启动器作为 child window 挂载(浮在启动器上方, 启动器不退出)。
    public weak var launcherWindow: NSWindow?

    /// 关闭回调: 唯一可靠的 Settings 关闭通知点(按钮/失焦/生命周期)。
    /// 启动器用它恢复交互所有权与移除 shield。不允许用 deinit 承担此职责。
    public var onClose: (() -> Void)?

    public convenience init(
        handler: any SettingsHandling,
        iconProvider: (any IconImageProviding)? = nil
    ) {
        self.init(
            handler: handler,
            iconProvider: iconProvider,
            sourcePanelPresenter: { parentWindow, completion in
                Self.presentSourcePanel(in: parentWindow, completion: completion)
            },
            hiddenPanelPresenter: { parentWindow, apps, completion in
                Self.presentHiddenPanel(
                    in: parentWindow,
                    apps: apps,
                    iconProvider: iconProvider,
                    completion: completion
                )
            }
        )
    }

    init(
        handler: any SettingsHandling,
        iconProvider: (any IconImageProviding)?,
        sourcePanelPresenter: @escaping SettingsSourcePanelPresenter,
        hiddenPanelPresenter: @escaping SettingsHiddenPanelPresenter
    ) {
        self.handler = handler
        self.iconProvider = iconProvider
        self.sourcePanelPresenter = sourcePanelPresenter
        self.hiddenPanelPresenter = hiddenPanelPresenter
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
        for buttonType in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ] {
            window.standardWindowButton(buttonType)?.isHidden = true
        }
        accessibilityDisplayObserver = makeAccessibilityDisplayObserver()
        buildContent()
        transitionCoordinator = SettingsTransitionCoordinator(window: window)
        accessibilityDisplayObserver?.start()
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 兼容旧调用方的显示入口。由启动器先 addChildWindow，再传入齿轮中心
    /// 的 screen point 时应使用 `present(from:)`。
    public func show() {
        present()
    }

    /// 从齿轮 source point 呈现 Settings。source point 使用 screen coordinates；
    /// 此方法不负责 addChildWindow，保留调用方的 child-window ownership 语义。
    public func present(
        from sourcePoint: NSPoint? = nil,
        completion: (() -> Void)? = nil
    ) {
        synchronizeSavedListsForPresentation()
        registerWindowNotificationObserverIfNeeded()
        startAccessibilityDisplayObservationIfNeeded()
        guard let transitionCoordinator else {
            completion?()
            return
        }

        closeRequested = false
        closeCallbackDelivered = false
        positionWindowForFreshPresentationIfNeeded(
            transitionState: transitionCoordinator.state
        )
        transitionCoordinator.present(from: sourcePoint) { [weak self] in
            self?.applyPendingAccessibilityAppearanceIfSettled()
            completion?()
        }
    }

    /// 解散 Settings。未传 source point 时复用最近一次齿轮点；过渡只使用
    /// 当前 window frame 的 presentation，不会把已手动移动的窗口跳回原中心。
    public func dismiss(
        to sourcePoint: NSPoint? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard let transitionCoordinator else {
            completion?()
            return
        }
        guard !closeCallbackDelivered else {
            completion?()
            return
        }
        guard !closeRequested else { return }

        closeRequested = true
        transitionCoordinator.dismiss(to: sourcePoint) { [weak self] in
            MainActor.assumeIsolated {
                self?.finalizeClose()
                completion?()
            }
        }
    }

    /// 关闭(含窗口关闭按钮/失焦)时从启动器父窗口移除 child，并通知所有权恢复。
    /// 实际 close 延后到 dismiss transition 完成，保留原生 close callback 语义。
    public override func close() {
        dismiss()
    }

    private func finalizeClose() {
        guard !closeCallbackDelivered else { return }
        closeCallbackDelivered = true
        finalizingClose = true
        defer { finalizingClose = false }

        notificationTokens.teardown()
        if let launcherWindow, let window {
            launcherWindow.removeChildWindow(window)
        }
        teardownAccessibilityDisplayObservation()
        super.close()
        onClose?()
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
    private var blurSlider: NSSlider!
    private var blurLabel: NSTextField!
    private var searchBarSlider: NSSlider!
    private var searchBarLabel: NSTextField!
    private var hotCornerPopups: [NSPopUpButton] = []
    private var sourcesList: NSTableView!
    private var sourcesData: [String] = []
    private var hiddenList: NSTableView!
    private var hiddenData: [AppID] = []
    private var addHiddenButton: NSButton!
    private var isSourcePanelPresented = false
    private var isHiddenPanelPresented = false

    /// 稳定的移除按钮引用(避免经 superview/子视图层级猜测按钮, NSClipView/
    /// NSScrollView 会打断旧实现)。语言重建会重建按钮并重新赋值。
    private var removeSourceButton: NSButton!
    private var removeHiddenButton: NSButton!

    /// 隐藏应用行图标点尺寸(与行高匹配)。
    private static let hiddenIconPointSize = 32

    private var hiddenIconScale: Int {
        max(1, Int((window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2).rounded()))
    }

    /// Settings 控制器是应用生命周期内的单实例。窗口关闭期间，store 可能通过
    /// 上下文菜单等入口更新隐藏应用或自定义来源；每次呈现前只同步这两份列表，
    /// 避免用全量 buildContent 掩盖 datasource 的陈旧快照。
    private func synchronizeSavedListsForPresentation(reloadTables: Bool = true) {
        let savedConfig = handler.config
        sourcesData = savedConfig.customSourceDirectories
        hiddenData = savedConfig.hiddenAppIDs
        if reloadTables {
            sourcesList?.reloadData()
            hiddenList?.reloadData()
            refreshRemoveButtonEnabledState()
        }
    }

    /// 选择变化/列表刷新后同步移除按钮的可用状态(不依赖事件时序)。
    private func refreshRemoveButtonEnabledState() {
        removeSourceButton?.isEnabled = (sourcesList?.selectedRow ?? -1) >= 0
        removeHiddenButton?.isEnabled = (hiddenList?.selectedRow ?? -1) >= 0
        addHiddenButton?.isEnabled = !availableHiddenApps.isEmpty
    }

    var availableHiddenApps: [(id: AppID, name: String)] {
        handler.allApps.filter { !hiddenData.contains($0.id) }
    }

    private func positionWindowForFreshPresentationIfNeeded(
        transitionState: SettingsTransitionState
    ) {
        guard SettingsWindowPlacement.shouldPosition(for: transitionState),
              let launcherWindow,
              let window else {
            return
        }

        let visibleFrame = launcherWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? launcherWindow.frame
        let targetFrame = SettingsWindowPlacement.frame(
            launcherFrame: launcherWindow.frame,
            settingsSize: window.frame.size,
            visibleFrame: visibleFrame
        )
        window.setFrame(targetFrame, display: false)
    }

    private func registerWindowNotificationObserverIfNeeded() {
        guard notificationTokens.isEmpty, let window else { return }
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let window, window.attachedSheet == nil else { return }
                self?.close()
            }
        })
    }

    private func buildContent() {
        guard let window else { return }
        registerWindowNotificationObserverIfNeeded()
        // 点击面板外(设置失去 key)→ 关闭设置(用户要求)
        // 毛玻璃背景(与启动器一致)
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        materialEffectView = effect
        window.contentView = effect

        if let snapshot = accessibilityDisplayObserver?.snapshot {
            applyAccessibilitySnapshot(snapshot)
        }

        let root = effect

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
        iconSizePopup.identifier = NSUserInterfaceItemIdentifier("settings.iconSize")
        iconSizePopup.addItems(withTitles: ["48", "64", "80", "96"])
        iconSizePopup.selectItem(withTitle: "\(config.iconSize)")
        iconSizePopup.target = self
        iconSizePopup.action = #selector(valueChanged)

        showLabelsCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(valueChanged))
        showLabelsCheck.identifier = NSUserInterfaceItemIdentifier("settings.showLabels")
        showLabelsCheck.state = config.showIconLabels ? .on : .off

        // 语言
        languagePopup = NSPopUpButton()
        languagePopup.identifier = NSUserInterfaceItemIdentifier("settings.language")
        languagePopup.addItems(withTitles: ["跟随系统", "English", "简体中文", "繁體中文"])
        languagePopup.selectItem(at: index(for: config.language))
        languagePopup.target = self
        languagePopup.action = #selector(valueChanged)

        // 热键
        hotkeyCheck = NSButton(checkboxWithTitle: L10n.t(.hotkeyEnabled), target: self, action: #selector(valueChanged))
        hotkeyCheck.identifier = NSUserInterfaceItemIdentifier("settings.hotkeyEnabled")
        hotkeyCheck.state = config.hotkey.enabled ? .on : .off
        hotkeyPopup = NSPopUpButton()
        hotkeyPopup.identifier = NSUserInterfaceItemIdentifier("settings.hotkey")
        hotkeyPopup.addItems(withTitles: ["⌘L", "⌘Space", "⌥Space", "⇧⌘L", "⌃⌥L"])
        hotkeyPopup.selectItem(at: hotkeyPresetIndex)

        // 热角
        hotCornerPopups = (0..<4).map { index in
            let popup = NSPopUpButton()
            popup.identifier = NSUserInterfaceItemIdentifier("settings.hotCorner.\(index)")
            popup.addItems(withTitles: [L10n.t(.none), L10n.t(.cornerShow), L10n.t(.cornerHide), L10n.t(.cornerToggle)])
            popup.target = self
            popup.action = #selector(valueChanged)
            return popup
        }
        let cornerActions = [config.hotCorner.topLeft, config.hotCorner.topRight, config.hotCorner.bottomLeft, config.hotCorner.bottomRight]
        for (popup, action) in zip(hotCornerPopups, cornerActions) {
            popup.selectItem(at: index(for: action))
        }

        // 布局: 左侧两列表单 section(共享标签列宽), 右侧独立 section
        let gridRows = [
            SettingsFormRow(title: L10n.t(.columnsLabel), value: colsRow),
            SettingsFormRow(title: L10n.t(.rowsLabel), value: rowsRow),
            SettingsFormRow(title: L10n.t(.iconSizeLabel), value: iconSizePopup),
            SettingsFormRow(title: L10n.t(.showLabelsLabel), value: showLabelsCheck),
        ]
        let languageRow = SettingsFormRow(
            title: L10n.t(.languageLabel),
            value: languagePopup
        )
        let hotkeyRow = SettingsFormRow(
            title: L10n.t(.hotkeyLabel),
            value: NSStackView(views: [hotkeyCheck, hotkeyPopup])
        )
        let cornerRows = (0..<4).map { index in
            SettingsFormRow(
                title: ["↖", "↗", "↙", "↘"][index],
                value: hotCornerPopups[index]
            )
        }

        // 布局: 分两列 section
        let left = NSStackView()
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 10

        let blurSlider = NSSlider(value: Double(config.wallpaperBlurRadius), minValue: 0, maxValue: 60, target: self, action: #selector(valueChanged))
        blurSlider.isContinuous = true
        blurSlider.identifier = NSUserInterfaceItemIdentifier("settings.blur")
        self.blurSlider = blurSlider
        let blurLabel = NSTextField(labelWithString: "\(config.wallpaperBlurRadius)")
        self.blurLabel = blurLabel

        let searchBarPercent = SearchBarSizing.percent(
            forPersistedWidth: config.searchBarWidth
        )
        let searchBarSlider = NSSlider(
            value: searchBarPercent,
            minValue: SearchBarSizing.minimumPercent,
            maxValue: SearchBarSizing.maximumPercent,
            target: self,
            action: #selector(valueChanged)
        )
        searchBarSlider.isContinuous = true
        searchBarSlider.identifier = NSUserInterfaceItemIdentifier("settings.searchBarSize")
        self.searchBarSlider = searchBarSlider
        let searchBarLabel = NSTextField(
            labelWithString: Self.percentLabel(searchBarPercent)
        )
        searchBarLabel.identifier = NSUserInterfaceItemIdentifier("settings.searchBarSizeLabel")
        self.searchBarLabel = searchBarLabel

        let wallpaperRow = SettingsFormRow(
            title: L10n.t(.blurIntensityLabel),
            value: NSStackView(views: [blurLabel, blurSlider])
        )
        let searchRow = SettingsFormRow(
            title: L10n.t(.searchBarSizeLabel),
            value: NSStackView(views: [searchBarLabel, searchBarSlider])
        )

        let allRows = gridRows + [languageRow, hotkeyRow] + cornerRows
            + [wallpaperRow, searchRow]
        let sharedLabelWidth = allRows.map(\.labelIntrinsicWidth).max() ?? 0

        left.addArrangedSubview(makeFormSection(
            title: L10n.t(.gridSection),
            rows: gridRows,
            labelColumnWidth: sharedLabelWidth
        ))
        left.addArrangedSubview(makeFormSection(
            title: L10n.t(.languageLabel),
            rows: [languageRow],
            labelColumnWidth: sharedLabelWidth
        ))
        left.addArrangedSubview(makeFormSection(
            title: L10n.t(.hotkeyLabel),
            rows: [hotkeyRow],
            labelColumnWidth: sharedLabelWidth
        ))
        left.addArrangedSubview(makeFormSection(
            title: L10n.t(.hotCornerLabel),
            rows: cornerRows,
            labelColumnWidth: sharedLabelWidth
        ))
        left.addArrangedSubview(makeFormSection(
            title: L10n.t(.wallpaperLabel),
            rows: [wallpaperRow],
            labelColumnWidth: sharedLabelWidth
        ))
        left.addArrangedSubview(makeFormSection(
            title: L10n.t(.searchBarSection),
            rows: [searchRow],
            labelColumnWidth: sharedLabelWidth
        ))

        // 关于(Stage B5): 版本 + 来源链接
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        left.addArrangedSubview(sectionHeader(L10n.t(.aboutLabel)))
        left.addArrangedSubview(NSTextField(labelWithString: "LaunchBetter v\(version)"))

        let right = NSStackView()
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        right.addArrangedSubview(sectionHeader(L10n.t(.customSourcesLabel)))
        right.addArrangedSubview(buildSourcesSection())
        right.addArrangedSubview(sectionHeader(L10n.t(.hiddenAppsLabel)))
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

    private func makeAccessibilityDisplayObserver() -> AccessibilityDisplayObserver {
        AccessibilityDisplayObserver(
            initialSnapshot: MotionEnvironment.liveSnapshot(),
            snapshotProvider: { [weak self] in
                let snapshot = MotionEnvironment.liveSnapshot()
                self?.applyAccessibilitySnapshot(snapshot)
                return snapshot
            }
        )
    }

    private func startAccessibilityDisplayObservationIfNeeded() {
        guard accessibilityDisplayObserver == nil else { return }
        let observer = makeAccessibilityDisplayObserver()
        accessibilityDisplayObserver = observer
        observer.start()
        applyAccessibilitySnapshot(observer.snapshot)
    }

    private func teardownAccessibilityDisplayObservation() {
        accessibilityDisplayObserver?.teardown()
        accessibilityDisplayObserver = nil
        pendingAccessibilityAppearance = nil
    }

    private func applyAccessibilitySnapshot(_ snapshot: MotionEnvironmentSnapshot) {
        let appearance = SettingsAccessibilityAppearance.make(for: snapshot)
        guard let materialEffectView else {
            pendingAccessibilityAppearance = appearance
            return
        }

        guard transitionCoordinator?.isTransitioning != true else {
            pendingAccessibilityAppearance = appearance
            return
        }

        pendingAccessibilityAppearance = nil
        SettingsAccessibilityAppearance.apply(appearance, to: materialEffectView)
    }

    private func applyPendingAccessibilityAppearanceIfSettled() {
        guard transitionCoordinator?.isTransitioning != true,
              let pendingAccessibilityAppearance,
              let materialEffectView else {
            return
        }

        self.pendingAccessibilityAppearance = nil
        SettingsAccessibilityAppearance.apply(
            pendingAccessibilityAppearance,
            to: materialEffectView
        )
    }

    /// 两列表单 section: header + 行网格(标签列 + 值列)。
    /// 标签列宽由调用方统一传入(全表单共享), 值列因此跨 section 对齐。
    private func makeFormSection(
        title: String,
        rows: [SettingsFormRow],
        labelColumnWidth: CGFloat
    ) -> NSStackView {
        let grid = NSGridView(views: rows.map { [$0.label, $0.value] })
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).width = labelColumnWidth
        let stack = NSStackView(views: [sectionHeader(title), grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 15)
        return label
    }

    private func buildSourcesSection() -> NSStackView {
        sourcesData = config.customSourceDirectories
        let scroll = NSScrollView()
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 300).isActive = true
        sourcesList = NSTableView()
        sourcesList.identifier = NSUserInterfaceItemIdentifier("settings.sources")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("src"))
        column.width = 220
        sourcesList.addTableColumn(column)
        sourcesList.headerView = nil
        sourcesList.dataSource = self
        sourcesList.delegate = self
        scroll.documentView = sourcesList

        let add = NSButton(title: L10n.t(.addSource), target: self, action: #selector(addSource))
        add.identifier = NSUserInterfaceItemIdentifier("addSource")
        let remove = NSButton(title: L10n.t(.remove), target: self, action: #selector(removeSource))
        remove.isEnabled = false
        remove.identifier = NSUserInterfaceItemIdentifier("removeSource")
        removeSourceButton = remove
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
        hiddenList.identifier = NSUserInterfaceItemIdentifier("settings.hiddenApps")
        hiddenList.rowHeight = CGFloat(Self.hiddenIconPointSize + 8)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hid"))
        column.width = 220
        hiddenList.addTableColumn(column)
        hiddenList.headerView = nil
        hiddenList.dataSource = self
        hiddenList.delegate = self
        scroll.documentView = hiddenList

        let add = NSButton(title: L10n.t(.addHiddenApp), target: self, action: #selector(addHiddenApp))
        add.identifier = NSUserInterfaceItemIdentifier("addHidden")
        add.isEnabled = !availableHiddenApps.isEmpty
        addHiddenButton = add
        let remove = NSButton(
            title: L10n.t(.remove),
            target: self,
            action: #selector(removeSelectedHiddenApp)
        )
        remove.isEnabled = false
        remove.identifier = NSUserInterfaceItemIdentifier("removeHidden")
        removeHiddenButton = remove
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

    // MARK: - 动作

    @objc private func gridChanged() {
        columnsLabel.stringValue = "\(columnsStepper.integerValue)"
        rowsLabel.stringValue = "\(rowsStepper.integerValue)"
        commit()
    }

    @objc private func valueChanged() {
        blurLabel?.stringValue = "\(Int(blurSlider?.doubleValue ?? 0))"
        searchBarLabel?.stringValue = Self.percentLabel(
            searchBarSlider?.doubleValue ?? 100
        )
        commit()
    }

    private static func percentLabel(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }

    @objc private func addSource() {
        guard !isSourcePanelPresented,
              let window,
              window.attachedSheet == nil else { return }
        isSourcePanelPresented = true
        sourcePanelPresenter(window) { [weak self] url in
            guard let self else { return }
            self.isSourcePanelPresented = false
            self.submitSourceDirectory(url)
        }
    }

    @objc private func removeSource() {
        let row = sourcesList.selectedRow
        guard row >= 0, row < sourcesData.count else { return }
        sourcesData.remove(at: row)
        commit()
    }

    @objc private func addHiddenApp() {
        guard !isHiddenPanelPresented,
              let window,
              window.attachedSheet == nil else { return }
        let availableApps = availableHiddenApps
        guard !availableApps.isEmpty else { return }
        isHiddenPanelPresented = true
        hiddenPanelPresenter(window, availableApps) { [weak self] appID in
            guard let self else { return }
            self.isHiddenPanelPresented = false
            self.submitHiddenAppSelection(appID)
        }
    }

    func submitSourceDirectory(_ url: URL?) {
        guard let url else { return }
        addSourcePath(url.path)
    }

    func submitHiddenAppSelection(_ appID: AppID?) {
        guard let appID else { return }
        addHiddenAppID(appID)
    }

    @objc private func removeSelectedHiddenApp() {
        removeHiddenApp(at: hiddenList.selectedRow)
    }

    /// 按行移除隐藏应用(测试 seam; 与按钮 action 共用同一实现)。
    func removeHiddenApp(at row: Int) {
        guard row >= 0, row < hiddenData.count else { return }
        hiddenData.remove(at: row)
        commit()
    }

    func addSourcePath(_ path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }
        let normalizedPath = URL(
            fileURLWithPath: trimmedPath,
            isDirectory: true
        ).standardizedFileURL.path
        guard !sourcesData.contains(where: {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path == normalizedPath
        }) else { return }
        sourcesData.append(normalizedPath)
        commit()
    }

    func addHiddenAppID(_ id: AppID) {
        guard !hiddenData.contains(id) else { return }
        hiddenData.append(id)
        commit()
    }

    private static func presentSourcePanel(
        in parentWindow: NSWindow,
        completion: @escaping (URL?) -> Void
    ) {
        guard parentWindow.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: parentWindow) { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    private static func presentHiddenPanel(
        in parentWindow: NSWindow,
        apps: [(id: AppID, name: String)],
        iconProvider: (any IconImageProviding)?,
        completion: @escaping (AppID?) -> Void
    ) {
        guard parentWindow.attachedSheet == nil else { return }
        let picker = SettingsHiddenAppPickerController(
            apps: apps,
            iconProvider: iconProvider
        )
        guard picker.present(in: parentWindow, completion: { appID in
            withExtendedLifetime(picker) {
                completion(appID)
            }
        }) else {
            completion(nil)
            return
        }
    }

    /// 收集配置并保存(即时生效)。
    private func commit() {
        let previousLanguage = config.language
        let selectedSourceRow = sourcesList.selectedRow
        let selectedHiddenRow = hiddenList.selectedRow
        var config = self.config
        config.gridColumns = columnsStepper.integerValue
        config.gridRows = rowsStepper.integerValue
        config.iconSize = iconSizePopup.indexOfSelectedItem == 0 ? 48
            : iconSizePopup.indexOfSelectedItem == 1 ? 64
            : iconSizePopup.indexOfSelectedItem == 2 ? 80 : 96
        config.showIconLabels = showLabelsCheck.state == .on
        config.wallpaperBlurRadius = Int(blurSlider.doubleValue)
        config.searchBarWidth = SearchBarSizing.persistedWidth(
            forPercent: searchBarSlider.doubleValue
        )
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
        handler.save(config)
        let languageChanged = handler.config.language != previousLanguage
        synchronizeSavedListsForPresentation(reloadTables: !languageChanged)

        // LauncherStore configures L10n synchronously as part of save. Rebuild
        // only after the requested language was actually accepted, keeping the
        // same NSWindow and transition coordinator alive.
        if languageChanged {
            rebuildLocalizedContentPreservingState(
                selectedSourceRow: selectedSourceRow,
                selectedHiddenRow: selectedHiddenRow
            )
        }
    }

    private func rebuildLocalizedContentPreservingState(
        selectedSourceRow: Int,
        selectedHiddenRow: Int
    ) {
        let frame = window?.frame

        window?.title = L10n.t(.settingsTitle)
        buildContent()

        if sourcesData.indices.contains(selectedSourceRow) {
            sourcesList.selectRowIndexes(
                IndexSet(integer: selectedSourceRow),
                byExtendingSelection: false
            )
        }
        if hiddenData.indices.contains(selectedHiddenRow) {
            hiddenList.selectRowIndexes(
                IndexSet(integer: selectedHiddenRow),
                byExtendingSelection: false
            )
        }
        if let frame, window?.frame != frame {
            window?.setFrame(frame, display: false)
        }
    }
}

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        tableView == sourcesList ? sourcesData.count : hiddenData.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == sourcesList {
            let field = NSTextField(labelWithString: (row < sourcesData.count) ? sourcesData[row] : "")
            field.lineBreakMode = .byTruncatingMiddle
            return field
        }

        guard hiddenData.indices.contains(row) else { return nil }
        let appID = hiddenData[row]
        let app = handler.allApps.first { $0.id == appID }
        let cell = tableView.makeView(
            withIdentifier: SettingsHiddenRowCell.reuseIdentifier,
            owner: self
        ) as? SettingsHiddenRowCell ?? SettingsHiddenRowCell(frame: .zero)
        cell.configure(
            appID: appID,
            name: app?.name ?? appID.rawValue,
            provider: app == nil ? nil : iconProvider,
            pointSize: Self.hiddenIconPointSize,
            scale: hiddenIconScale
        )
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView == sourcesList {
            removeSourceButton?.isEnabled = tableView.selectedRow >= 0
        } else if tableView == hiddenList {
            removeHiddenButton?.isEnabled = tableView.selectedRow >= 0
        }
    }
}

extension SettingsWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        notificationTokens.teardown()
        teardownAccessibilityDisplayObservation()
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if finalizingClose || closeCallbackDelivered {
            return true
        }
        dismiss()
        return false
    }

    /// AppKit native movement wins over Settings presentation immediately.
    public func windowWillMove(_ notification: Notification) {
        transitionCoordinator?.cancelForManualMove()
        applyPendingAccessibilityAppearanceIfSettled()
    }

    /// Resize is also direct manipulation; do not leave a presentation transform
    /// competing with AppKit's live resize path.
    public func windowWillStartLiveResize(_ notification: Notification) {
        transitionCoordinator?.cancelForManualMove()
        applyPendingAccessibilityAppearanceIfSettled()
    }
}
