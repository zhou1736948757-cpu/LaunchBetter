import AppKit
import LaunchCore

/// 拖拽视觉表示: 只携带已在内存中的位图及其 point/pixel 语义。
///
/// 生成方负责渲染细节; DragController 只消费这个值, 不接触 cell/layer 树。
@MainActor
struct DragVisualRepresentation {
    let image: CGImage
    let logicalSize: CGSize
    let rasterScale: CGFloat

    init(image: CGImage, logicalSize: CGSize, rasterScale: CGFloat) {
        self.image = image
        self.logicalSize = logicalSize
        self.rasterScale = rasterScale.isFinite && rasterScale > 0 ? rasterScale : 1
    }

    /// 兼容旧 folder-child API: 旧接口只传 CGImage, 从当前屏幕推导其 raster scale。
    static func legacy(image: CGImage?) -> DragVisualRepresentation? {
        guard let image else { return nil }
        let scale = max(1, NSScreen.main?.backingScaleFactor ?? 2)
        let logicalSize = CGSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        return DragVisualRepresentation(
            image: image,
            logicalSize: logicalSize,
            rasterScale: scale
        )
    }
}

/// 应用/文件夹单元格: 图标或文件夹缩略图 + 标签。
///
/// 图标加载(§85 复用竞态防护):
/// - `representedAppID` + `iconRequestTask`
/// - 复用时: 取消消费者任务、清除 represented ID、恢复占位
/// - 结果应用条件: 任务未取消 AND representedAppID 仍等于期望 ID
/// - 消费者取消不杀死共享图标任务(§81)
///
/// 几何(Stage 1, P0):
/// - 图标显示尺寸 = configure 传入的 pointSize(与 IconKey 请求一致)
/// - 标签位置由 (cellBounds, iconSize, labelHeight) 统一计算, 无魔数
final class AppCellView: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("AppCellView")

    private enum CreateFolderTargetHighlight: Equatable {
        case none
        case waiting
        case active
    }

    /// 标签高度(pt)。
    private static let labelHeight: CGFloat = 13
    private static let maxFolderIconCount = 9

    private let iconLayer = CALayer()
    private let folderThumbnailView = FolderThumbnailView()
    private let label = NSTextField(labelWithString: "")
    private let letterLayer = CATextLayer()
    private var labelBottomConstraint: NSLayoutConstraint?

    private var representedAppID: AppID?
    private var representedFolderID: FolderID?
    private var folderChildAppIDs: [AppID] = []
    private var iconRequestTask: Task<Void, Never>?
    private var folderIconRequestTasks: [Task<Void, Never>] = []
    private var iconProvider: (any IconImageProviding)?
    private var requestGeneration: UInt64 = 0

    /// 当前配置的图标点尺寸(与 IconKey 请求一致)。
    private var iconPointSize: Int = 80
    private var lastRequestedScale = 0
    private var isDragSourceHidden = false
    private var createFolderTargetHighlight: CreateFolderTargetHighlight = .none

    /// 源单元格当前显示的图标(拖拽 overlay 复用, 零磁盘 IO)。
    var visibleIconImage: CGImage? {
        guard let contents = iconLayer.contents else { return nil }
        let ref = contents as CFTypeRef
        // 类型校验后强转, 消除对任意 contents 的裸 force-cast crash point(v0.1.6 §53)
        guard CFGetTypeID(ref) == CGImage.typeID else { return nil }
        return (ref as! CGImage)
    }

    /// 返回当前单元格的语义化拖拽视觉表示。
    /// 普通 App 直接复用已显示的图标; 文件夹由缩略图 view 在内存中栅格化。
    /// 不触发新的图标请求, 也不访问磁盘。
    func dragRepresentation() -> DragVisualRepresentation? {
        if representedFolderID != nil {
            return folderThumbnailView.dragRepresentation()
        }

        guard representedAppID != nil, let image = visibleIconImage else { return nil }
        let logicalSize = iconLayer.bounds.size.width > 0 && iconLayer.bounds.size.height > 0
            ? iconLayer.bounds.size
            : CGSize(width: iconPointSize, height: iconPointSize)
        let scale = lastRequestedScale > 0
            ? CGFloat(lastRequestedScale)
            : max(1, iconLayer.contentsScale)
        return DragVisualRepresentation(
            image: image,
            logicalSize: logicalSize,
            rasterScale: scale
        )
    }

    /// 诊断: 是否已显示真实图标(contents 非空)。
    var hasRealIcon: Bool { iconLayer.contents != nil }

    /// 拖拽期间隐藏源单元格，overlay 成为唯一的源图标。
    /// 只写 layer opacity，避免触发 collection view 结构更新。
    func setDragSourceHidden(_ hidden: Bool) {
        guard hidden != isDragSourceHidden else { return }
        isDragSourceHidden = hidden
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.opacity = hidden ? 0 : 1
        CATransaction.commit()
    }

    /// App B 建夹目标高亮。只变换普通 App 的 iconLayer，避免与写入
    /// cell.view.layer.transform 的 reorder preview 相互覆盖。
    func setCreateFolderTargetHighlighted(_ highlighted: Bool, active: Bool) {
        guard representedAppID != nil, representedFolderID == nil, !iconLayer.isHidden else {
            return
        }
        let nextHighlight: CreateFolderTargetHighlight
        if !highlighted {
            nextHighlight = .none
        } else {
            nextHighlight = active ? .active : .waiting
        }
        guard nextHighlight != createFolderTargetHighlight else { return }
        createFolderTargetHighlight = nextHighlight

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch nextHighlight {
        case .none:
            iconLayer.transform = CATransform3DIdentity
            iconLayer.borderWidth = 0
            iconLayer.borderColor = nil
        case .waiting:
            iconLayer.transform = CATransform3DMakeScale(1.05, 1.05, 1)
            iconLayer.borderWidth = 2
            iconLayer.borderColor = NSColor.white.withAlphaComponent(0.72).cgColor
        case .active:
            iconLayer.transform = CATransform3DMakeScale(1.10, 1.10, 1)
            iconLayer.borderWidth = 3
            iconLayer.borderColor = NSColor.systemBlue.cgColor
        }
        CATransaction.commit()
    }

    override func loadView() {
        let root = CellRootView()
        root.onWindowChange = { [weak self] in
            self?.reRequestIconIfScaleChanged()
        }
        root.onScreenChange = { [weak self] in
            self?.reRequestIconIfScaleChanged()
        }
        root.wantsLayer = true
        iconLayer.cornerRadius = 16
        iconLayer.masksToBounds = true
        root.layer?.addSublayer(iconLayer)

        folderThumbnailView.isHidden = true
        root.addSubview(folderThumbnailView)

        letterLayer.fontSize = 36
        letterLayer.alignmentMode = .center
        letterLayer.foregroundColor = NSColor.white.cgColor
        letterLayer.contentsScale = 2
        iconLayer.addSublayer(letterLayer)

        label.alignment = .center
        label.font = .systemFont(ofSize: 10)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.textColor = .white
        label.shadow = NSShadow()
        label.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.85)
        label.shadow?.shadowBlurRadius = 4
        label.shadow?.shadowOffset = NSSize(width: 0, height: -1)
        root.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        labelBottomConstraint = label.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            label.heightAnchor.constraint(equalToConstant: Self.labelHeight),
            labelBottomConstraint!,
        ])
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutIconAndLabel()
        CATransaction.commit()
    }

    /// 图标/标签统一布局: 图标尺寸 = iconPointSize(与 IconKey 请求一致, 顶部锚定),
    /// 标签与图标间距 = max(6, (单元格高 - 图标高) / 4)(用户反馈"再拉开一些" 的方向)。
    private func layoutIconAndLabel() {
        let bounds = view.bounds
        let size = CGFloat(iconPointSize)
        var iconFrame = bounds
        iconFrame.size.height = size
        iconFrame.origin.y = bounds.height - size
        // frame 在非 identity transform 下是派生值；改写 bounds/position 可保证
        // App B 高亮缩放期间重新布局仍稳定。
        iconLayer.bounds = CGRect(origin: .zero, size: iconFrame.size)
        iconLayer.position = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        letterLayer.frame = iconFrame
        folderThumbnailView.frame = iconFrame
        folderThumbnailView.updateLayout()
        let scale = view.window?.backingScaleFactor ?? 2
        iconLayer.contentsScale = scale
        letterLayer.fontSize = size * 0.5
        letterLayer.contentsScale = scale

        let gap = max(6, (bounds.height - size) / 4)
        labelBottomConstraint?.constant = -gap
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        invalidateIconRequests()
        representedAppID = nil
        representedFolderID = nil
        folderChildAppIDs = []
        iconProvider = nil
        folderThumbnailView.reset()
        resetCreateFolderTargetHighlight()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.contents = nil
        iconLayer.backgroundColor = nil
        iconLayer.isHidden = false
        letterLayer.isHidden = false
        // M3: 复用强制恢复 identity(防止拖拽预览变换污染)
        view.layer?.transform = CATransform3DIdentity
        view.layer?.opacity = 1
        isDragSourceHidden = false
        CATransaction.commit()
    }

    /// 配置单元格。占位图标(色块 + 首字母)立即显示,真实图标异步到达。
    func configure(
        displayName: String,
        colorIndex: Int,
        accessibilityHint: String,
        appID: AppID?,
        pointSize: Int,
        iconProvider: (any IconImageProviding)?
    ) {
        beginConfiguration()
        iconPointSize = max(16, pointSize)
        letterLayer.string = String(displayName.prefix(1)).uppercased()
        letterLayer.isHidden = false
        iconLayer.isHidden = false

        let hue = CGFloat(colorIndex % 12) / 12
        iconLayer.backgroundColor = NSColor(
            hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1
        ).cgColor
        iconLayer.contents = nil

        label.stringValue = displayName
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(displayName)
        view.setAccessibilityHelp(accessibilityHint)

        self.iconProvider = iconProvider
        let scale = currentBackingScale
        lastRequestedScale = scale
        guard let appID else {
            representedAppID = nil
            return
        }

        representedAppID = appID
        guard let iconProvider else { return }
        startAppIconRequest(appID, provider: iconProvider, scale: scale)
    }

    /// 元数据/本地化重配置(重命名/自定义名/目录显示名/语言):
    /// 只更新文本与无障碍信息,不触碰图标层、不取消/重启图标请求。
    /// Diffable 对同 identity cell 复用后不再调用数据源闭包,元数据变化走此路径。
    func reapplyMetadata(displayName: String, accessibilityHint: String) {
        guard representedAppID != nil else { return }
        letterLayer.string = String(displayName.prefix(1)).uppercased()
        label.stringValue = displayName
        view.setAccessibilityLabel(displayName)
        view.setAccessibilityHelp(accessibilityHint)
    }

    /// 配置文件夹单元格。文件夹自身不使用普通 App 的色块/首字母占位，
    /// 只显示透明磨砂容器及其可用的真实子应用图标。
    func configureFolder(
        displayName: String,
        accessibilityHint: String,
        folderID: FolderID,
        children: [AppID],
        pointSize: Int,
        iconProvider: (any IconImageProviding)?
    ) {
        beginConfiguration()
        iconPointSize = max(16, pointSize)
        label.stringValue = displayName
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(displayName)
        view.setAccessibilityHelp(accessibilityHint)

        iconLayer.contents = nil
        iconLayer.backgroundColor = nil
        iconLayer.isHidden = true
        letterLayer.string = ""
        letterLayer.isHidden = true

        let visibleChildren = Array(children.prefix(Self.maxFolderIconCount))
        folderChildAppIDs = visibleChildren
        representedFolderID = folderID
        self.iconProvider = iconProvider

        let scale = currentBackingScale
        lastRequestedScale = scale
        folderThumbnailView.configure(
            iconCount: visibleChildren.count,
            scale: CGFloat(scale)
        )
        guard let iconProvider else { return }
        startFolderIconRequests(
            folderID: folderID,
            children: visibleChildren,
            provider: iconProvider,
            scale: scale
        )
    }

    /// 窗口显示器变更(backing scale 变化)→ 以新 scale 重新请求图标(Stage 1 §32)。
    private func reRequestIconIfScaleChanged() {
        guard view.window != nil else { return }
        let scale = currentBackingScale
        guard scale != lastRequestedScale else { return }
        lastRequestedScale = scale
        invalidateIconRequests()

        if let appID = representedAppID, let iconProvider {
            startAppIconRequest(appID, provider: iconProvider, scale: scale)
        } else if let folderID = representedFolderID, let iconProvider {
            folderThumbnailView.updateScale(CGFloat(scale))
            folderThumbnailView.clearIconContents()
            startFolderIconRequests(
                folderID: folderID,
                children: folderChildAppIDs,
                provider: iconProvider,
                scale: scale
            )
        }
    }

    private var currentBackingScale: Int {
        let scale = view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        return max(1, Int(scale.rounded()))
    }

    private func beginConfiguration() {
        // Reconfiguration must never carry a previous identity's hidden state.
        // GridViewController reapplies the active source identity immediately after
        // this configuration returns.
        setDragSourceHidden(false)
        invalidateIconRequests()
        resetCreateFolderTargetHighlight()
        representedAppID = nil
        representedFolderID = nil
        folderChildAppIDs = []
        iconProvider = nil
        folderThumbnailView.reset()
        iconLayer.isHidden = false
    }

    private func resetCreateFolderTargetHighlight() {
        createFolderTargetHighlight = .none
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.transform = CATransform3DIdentity
        iconLayer.borderWidth = 0
        iconLayer.borderColor = nil
        CATransaction.commit()
    }

    private func invalidateIconRequests() {
        requestGeneration &+= 1
        iconRequestTask?.cancel()
        iconRequestTask = nil
        for task in folderIconRequestTasks {
            task.cancel()
        }
        folderIconRequestTasks.removeAll(keepingCapacity: true)
    }

    /// 启动普通 App 图标请求(消费者任务;取消不杀死共享图标任务)。
    private func startAppIconRequest(
        _ appID: AppID,
        provider: any IconImageProviding,
        scale: Int
    ) {
        let expectedGeneration = requestGeneration
        let size = iconPointSize
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let image = await provider.icon(for: appID, pointSize: size, scale: scale)
            guard !Task.isCancelled,
                  let self,
                  self.representedAppID == appID,
                  self.requestGeneration == expectedGeneration else { return }
            self.applyIcon(image, scale: scale)
        }
        iconRequestTask = task
    }

    /// 启动文件夹子图标请求。每个子项都是可取消的消费者任务，最多 9 个。
    private func startFolderIconRequests(
        folderID: FolderID,
        children: [AppID],
        provider: any IconImageProviding,
        scale: Int
    ) {
        let expectedGeneration = requestGeneration
        let size = iconPointSize
        folderIconRequestTasks = children.prefix(Self.maxFolderIconCount).enumerated().map {
            index, appID in
            Task { [weak self] in
                guard !Task.isCancelled else { return }
                let image = await provider.icon(for: appID, pointSize: size, scale: scale)
                guard !Task.isCancelled,
                      let self,
                      self.representedFolderID == folderID,
                      self.requestGeneration == expectedGeneration else { return }
                self.folderThumbnailView.setIcon(image, at: index, scale: CGFloat(scale))
            }
        }
    }

    private func applyIcon(_ image: CGImage?, scale: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image {
            iconLayer.contents = image
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.contentsScale = CGFloat(scale)
            // 移除占位色块(图标直接显示在壁纸上)
            iconLayer.backgroundColor = nil
            letterLayer.isHidden = true
        } else {
            // 无图标: 保持占位(色块 + 首字母)
            iconLayer.contents = nil
            letterLayer.isHidden = false
        }
        CATransaction.commit()
    }
}

/// 主网格文件夹缩略图: AppKit 磨砂背景承载最多 3x3 个真实图标。
///
/// 未拿到图标时对应位置保持透明，不绘制首字母或色块占位，避免把文件夹
/// 缩略图误认为普通 App 单元格。所有尺寸都按当前 cell 的 point/Retina scale
/// 重新计算，图标 layer 不跨 cell 共享。
private final class FolderThumbnailView: NSVisualEffectView {
    private static let maxIconCount = 9

    private let iconContainerLayer = CALayer()
    private let sheenLayer = CAGradientLayer()
    private var iconLayers: [CALayer] = []
    private var iconCount = 0
    private var backingScale: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true

        iconContainerLayer.masksToBounds = true
        sheenLayer.colors = [
            NSColor.white.withAlphaComponent(0.18).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor,
        ]
        sheenLayer.startPoint = CGPoint(x: 0.2, y: 1)
        sheenLayer.endPoint = CGPoint(x: 0.8, y: 0)
        iconContainerLayer.addSublayer(sheenLayer)

        for _ in 0..<Self.maxIconCount {
            let iconLayer = CALayer()
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.masksToBounds = true
            iconLayer.isHidden = true
            iconLayers.append(iconLayer)
            iconContainerLayer.addSublayer(iconLayer)
        }

        if let layer {
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            layer.borderColor = NSColor.white.withAlphaComponent(0.38).cgColor
            layer.borderWidth = 1 / backingScale
            layer.masksToBounds = true
            layer.addSublayer(iconContainerLayer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(iconCount: Int, scale: CGFloat) {
        self.iconCount = min(max(0, iconCount), Self.maxIconCount)
        updateScale(scale)
        for iconLayer in iconLayers {
            iconLayer.contents = nil
            // 子图标异步到达前保持透明；不绘制任何伪占位。
            iconLayer.isHidden = true
        }
        isHidden = false
        updateLayout()
    }

    func reset() {
        iconCount = 0
        for iconLayer in iconLayers {
            iconLayer.contents = nil
            iconLayer.isHidden = true
        }
        isHidden = true
    }

    func clearIconContents() {
        for iconLayer in iconLayers {
            iconLayer.contents = nil
            iconLayer.isHidden = true
        }
    }

    func updateScale(_ scale: CGFloat) {
        backingScale = max(1, scale)
        layer?.contentsScale = backingScale
        iconContainerLayer.contentsScale = backingScale
        sheenLayer.contentsScale = backingScale
        layer?.borderWidth = 1 / backingScale
        for iconLayer in iconLayers {
            iconLayer.contentsScale = backingScale
        }
    }

    func updateLayout() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let side = min(bounds.width, bounds.height)
        let radius = min(18, max(10, side * 0.2))
        layer?.cornerRadius = radius
        iconContainerLayer.frame = bounds
        iconContainerLayer.cornerRadius = radius
        sheenLayer.frame = bounds
        sheenLayer.cornerRadius = radius

        let padding = max(5, side * 0.11)
        let gap = max(2, side * 0.025)
        let iconSide = max(1, (side - (padding * 2) - (gap * 2)) / 3)
        for (index, iconLayer) in iconLayers.enumerated() {
            let row = index / 3
            let column = index % 3
            iconLayer.frame = CGRect(
                x: padding + CGFloat(column) * (iconSide + gap),
                y: bounds.height - padding - CGFloat(row + 1) * iconSide
                    - CGFloat(row) * gap,
                width: iconSide,
                height: iconSide
            )
            iconLayer.cornerRadius = min(5, max(2, iconSide * 0.16))
        }
    }

    func setIcon(_ image: CGImage?, at index: Int, scale: CGFloat) {
        guard iconLayers.indices.contains(index), index < iconCount else { return }
        updateScale(scale)
        let iconLayer = iconLayers[index]
        iconLayer.contents = image
        iconLayer.isHidden = image == nil
    }

    /// 将当前已渲染的文件夹缩略图复制到内存 bitmap; 不重新请求子图标。
    /// context 像素尺寸显式按 point × backing scale 计算, 覆盖 1x/2x 显示器。
    func dragRepresentation() -> DragVisualRepresentation? {
        guard !isHidden, bounds.width > 0, bounds.height > 0,
              let layer else { return nil }

        let scale = max(1, backingScale)
        let pixelWidth = max(1, Int(ceil(bounds.width * scale)))
        let pixelHeight = max(1, Int(ceil(bounds.height * scale)))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        context.restoreGState()

        guard let image = context.makeImage() else { return nil }
        return DragVisualRepresentation(
            image: image,
            logicalSize: bounds.size,
            rasterScale: scale
        )
    }
}

/// 单元格根视图: 感知窗口/屏幕变更(显示器切换 → backing scale 变化)。
/// viewDidMoveToWindow 只在挂载时触发; 跨显示器移动需监听 screen 变化通知(评审 M3)。
private final class CellRootView: NSView {
    var onWindowChange: (() -> Void)?
    var onScreenChange: (() -> Void)?
    private var screenObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let window {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onScreenChange?()
                }
            }
        }
        onWindowChange?()
    }

    // 注: 不在此 deinit 移除观察者(Swift 6 隔离限制, 非 Sendable token)。
    // 观察者随窗口销毁自动清理; 弱引用回调保证单元格释放后无副作用。
    // 重复挂窗时 viewDidMoveToWindow 会先移除旧观察者。
}
