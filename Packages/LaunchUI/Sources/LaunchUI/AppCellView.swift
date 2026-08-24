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

    private let iconLayer = CALayer()
    /// Press feedback 的独立 visual owner。root.layer.transform 仍由拖拽排序拥有，
    /// iconLayer.transform 仍由 App→App 建夹高亮拥有，二者不与此层抢写。
    private let pressContainerView = NSView()
    /// 文件夹缩略图视图懒分配: 普通 App 配置不实例化/不加入层级。
    /// 仅 configureFolder 经 ensureFolderThumbnailView() 创建并复用同一实例;
    /// App 配置(configure)经 releaseFolderThumbnailView() 真正移除并置 nil。
    private var folderThumbnailView: FolderThumbnailView?
    private let label = NSTextField(labelWithString: "")
    private let letterLayer = CATextLayer()
    private var labelBottomConstraint: NSLayoutConstraint?
    private var pressPresentation: PressDragPresentation?

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
    private var isTransitionSourceSuppressed = false
    private var createFolderTargetHighlight: CreateFolderTargetHighlight = .none

    /// 当前 cell 的 Folder source identity；只供真实可见 source 查询使用。
    var transitionSourceIdentity: FolderID? { representedFolderID }

    /// 源单元格当前显示的图标(拖拽 overlay 复用, 零磁盘 IO)。
    var visibleIconImage: CGImage? {
        guard let contents = iconLayer.contents else { return nil }
        let ref = contents as CFTypeRef
        // 类型校验后强转, 消除对任意 contents 的裸 force-cast crash point(v0.1.6 §53)
        guard CFGetTypeID(ref) == CGImage.typeID else { return nil }
        return (ref as! CGImage)
    }

    /// 仅供 LaunchUI 的确定性 press/drag 测试读取；生产路径不依赖此属性。
    var pressPresentationForDiagnostics: PressDragPresentation? { pressPresentation }

    /// 返回当前单元格的语义化拖拽视觉表示。
    /// 普通 App 直接复用已显示的图标; 文件夹由缩略图 view 在内存中栅格化。
    /// 不触发新的图标请求, 也不访问磁盘。
    func dragRepresentation() -> DragVisualRepresentation? {
        if representedFolderID != nil {
            return folderThumbnailView?.dragRepresentation()
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

    /// 当前真正被拖拽视觉表示占据的 frame。该 frame 只用于视觉 grab offset，
    /// 不参与 hit-test 或 drop 目的地计算。
    func dragVisualFrame(in targetView: NSView) -> CGRect? {
        guard view.window != nil, view.window === targetView.window,
              !view.isHidden, view.bounds.width > 0, view.bounds.height > 0 else {
            return nil
        }

        let frame: CGRect
        if representedFolderID != nil {
            guard let folderThumbnailView, !folderThumbnailView.isHidden else { return nil }
            frame = folderThumbnailView.convert(folderThumbnailView.bounds, to: targetView)
        } else {
            guard representedAppID != nil, !iconLayer.isHidden else { return nil }
            // iconLayer 在 pressContainerView 的 bounds 坐标中；只取图标，
            // 不把 label 的位置误算进抓取中心。
            frame = pressContainerView.convert(iconLayer.frame, to: targetView)
        }
        guard frame.width > 0, frame.height > 0,
              frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite else {
            return nil
        }
        return frame
    }

    /// ClickableCollectionView 是 mouse session/threshold owner；以下方法只转发
    /// 到独立 presentation owner，不启动 App，也不改变 drag callback 语义。
    func beginPressFeedback(at point: NSPoint) {
        pressPresentation?.begin(at: point)
    }

    func updatePressFeedback(at point: NSPoint) {
        pressPresentation?.move(to: point)
    }

    func endPressFeedback(afterDragging: Bool) {
        pressPresentation?.end(afterDragging: afterDragging)
    }

    func cancelPressFeedback() {
        pressPresentation?.cancel()
    }

    /// 诊断: 是否已显示真实图标(contents 非空)。
    var hasRealIcon: Bool { iconLayer.contents != nil }

    /// 拖拽期间隐藏源单元格，overlay 成为唯一的源图标。
    /// 只写 layer opacity，避免触发 collection view 结构更新。
    func setDragSourceHidden(_ hidden: Bool) {
        guard hidden != isDragSourceHidden else { return }
        isDragSourceHidden = hidden
        // DragController 的 source opacity owner 与 press layer 分离。进入/离开
        // hidden 状态时只直接复位 press，避免 source 在后台保留压缩状态。
        pressPresentation?.finishForDragLifecycle()
        applySourceVisibility()
    }

    /// Folder spatial transition 期间隐藏真实 source，避免 proxy 与 cell 重影。
    /// 只改变 cell layer opacity，不移动/reparent collection cell。
    func setTransitionSourceSuppressed(_ suppressed: Bool) {
        guard suppressed != isTransitionSourceSuppressed else { return }
        isTransitionSourceSuppressed = suppressed
        if suppressed {
            pressPresentation?.cancel()
        }
        applySourceVisibility()
    }

    /// source 的实际 icon/thumbnail frame，转换到调用方提供的窗口 contentView。
    func transitionSourceFrame(in targetView: NSView) -> CGRect? {
        guard view.window != nil, view.window === targetView.window,
              !view.isHidden, view.bounds.width > 0, view.bounds.height > 0 else {
            return nil
        }
        let sourceView: NSView
        if representedFolderID != nil {
            guard let folderThumbnailView, !folderThumbnailView.isHidden else { return nil }
            sourceView = folderThumbnailView
        } else {
            guard representedAppID != nil, !iconLayer.isHidden else { return nil }
            sourceView = view
        }
        let frame = sourceView.convert(sourceView.bounds, to: targetView)
        guard frame.width > 0, frame.height > 0,
              frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite else {
            return nil
        }
        return frame
    }

    /// 真实 source 的圆角语义，供 proxy 几何起点使用。
    var transitionSourceCornerRadius: CGFloat {
        if representedFolderID != nil {
            return folderThumbnailView?.layer?.cornerRadius ?? 16
        }
        return iconLayer.cornerRadius
    }

    /// source 被 suppression 后仍可检查 cell 是否仍属于同一可见窗口；不读取
    /// Store，也不触发布局。
    func isTransitionSourceVisible(in targetView: NSView) -> Bool {
        transitionSourceFrame(in: targetView) != nil
    }

    private func applySourceVisibility() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.opacity = (isDragSourceHidden || isTransitionSourceSuppressed) ? 0 : 1
        CATransaction.commit()
    }

    /// E13: 图标遮罩按需开启。占位(色块 + 首字母)与建夹高亮期间保持圆角裁剪;
    /// 真实图标(macOS ICNS 自带圆角 alpha)应用后关闭 masksToBounds,
    /// 省掉每帧 offscreen mask。cornerRadius 始终保留(transitionSourceCornerRadius 语义)。
    private func updateIconMasking() {
        iconLayer.masksToBounds = createFolderTargetHighlight != .none || iconLayer.contents == nil
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
            // 高亮退出: 按当前状态恢复(占位 → true, 真实图标 → false)。
            updateIconMasking()
        case .waiting:
            iconLayer.masksToBounds = true
            iconLayer.transform = CATransform3DMakeScale(1.05, 1.05, 1)
            iconLayer.borderWidth = 2
            iconLayer.borderColor = NSColor.white.withAlphaComponent(0.72).cgColor
        case .active:
            iconLayer.masksToBounds = true
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
        pressContainerView.wantsLayer = true
        pressContainerView.frame = root.bounds
        pressContainerView.autoresizingMask = [.width, .height]
        root.addSubview(pressContainerView)

        iconLayer.cornerRadius = 16
        iconLayer.masksToBounds = true
        pressContainerView.layer?.addSublayer(iconLayer)

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
        pressContainerView.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        labelBottomConstraint = label.bottomAnchor.constraint(
            equalTo: pressContainerView.bottomAnchor, constant: -9
        )
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pressContainerView.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: pressContainerView.trailingAnchor, constant: -2),
            label.heightAnchor.constraint(equalToConstant: Self.labelHeight),
            labelBottomConstraint!,
        ])
        view = root

        guard let layer = pressContainerView.layer else { return }
        let presentation = PressDragPresentation(layer: layer)
        presentation.onDragThresholdCrossed = { [weak self] pointer in
            self?.registerPendingDragGrabOffset(pointerInWindow: pointer)
        }
        presentation.onSessionEnded = {
            DragOverlayLayer.clearPendingSourceVisualCenter()
        }
        pressPresentation = presentation
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
        let bounds = pressContainerView.bounds
        let size = CGFloat(iconPointSize)
        // 图标/文件夹容器统一为正方形(边长 = iconSize), 水平居中。
        // 原实现宽 = 单元格宽 → 文件夹容器呈矩形(用户反馈); App 图标因 resizeAspect
        // 不显形, 文件夹背景则暴露为矩形。
        var iconFrame = bounds
        iconFrame.size.height = size
        iconFrame.size.width = size
        iconFrame.origin.x = (bounds.width - size) / 2
        iconFrame.origin.y = bounds.height - size
        // frame 在非 identity transform 下是派生值；改写 bounds/position 可保证
        // App B 高亮缩放期间重新布局仍稳定。
        iconLayer.bounds = CGRect(origin: .zero, size: iconFrame.size)
        iconLayer.position = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        letterLayer.frame = iconFrame
        if let folderThumbnailView {
            folderThumbnailView.frame = iconFrame
            folderThumbnailView.updateLayout()
        }
        let scale = view.window?.backingScaleFactor ?? 2
        iconLayer.contentsScale = scale
        letterLayer.fontSize = size * 0.5
        letterLayer.contentsScale = scale

        let gap = max(6, (bounds.height - size) / 4)
        labelBottomConstraint?.constant = -gap
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        pressPresentation?.cancel()
        invalidateIconRequests()
        representedAppID = nil
        representedFolderID = nil
        folderChildAppIDs = []
        iconProvider = nil
        // 复用只隐藏/重置已存在的缩略图, 不释放: 若复用为文件夹则复用同一实例;
        // 若复用为 App 则由 configure() 在 beginConfiguration 之后显式 release。
        folderThumbnailView?.reset()
        resetCreateFolderTargetHighlight()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.contents = nil
        iconLayer.backgroundColor = nil
        iconLayer.isHidden = false
        letterLayer.isHidden = false
        // E13: 复用回到占位状态, 恢复圆角裁剪。
        updateIconMasking()
        // M3: 复用强制恢复 identity(防止拖拽预览变换污染)
        view.layer?.transform = CATransform3DIdentity
        pressContainerView.layer?.transform = CATransform3DIdentity
        view.layer?.opacity = 1
        isDragSourceHidden = false
        isTransitionSourceSuppressed = false
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
        // App 配置: 显式释放文件夹缩略图层级(文件夹→App 复用/重配置时真正
        // 移除并置 nil)。beginConfiguration 只隐藏/重置, 释放在此完成。
        releaseFolderThumbnailView()
        // 极小可用高度下，分页网格会继续缩小图标以保证最后一行不越界。
        iconPointSize = max(1, pointSize)
        letterLayer.string = String(displayName.prefix(1)).uppercased()
        letterLayer.isHidden = false
        iconLayer.isHidden = false

        let hue = CGFloat(colorIndex % 12) / 12
        iconLayer.backgroundColor = NSColor(
            hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1
        ).cgColor
        iconLayer.contents = nil
        // E13: 占位状态(色块 + 首字母)恢复圆角裁剪。
        updateIconMasking()

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
        iconPointSize = max(1, pointSize)
        // 懒创建: 普通 App 配置不实例化; 文件夹配置在此创建唯一实例。
        let thumbnail = ensureFolderThumbnailView()
        // 新创建的缩略图立即按当前几何定位(不依赖后续 layout pass; 懒创建
        // 发生在首次布局之后, 不能等 viewDidLayout 才给 frame)。
        layoutIconAndLabel()
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
        // E13: 文件夹单元格不复用普通 App 图标层; 遮罩状态随占位信号恢复。
        updateIconMasking()

        let visibleChildren = Array(children.prefix(FolderThumbnailMetrics.maxIconCount))
        folderChildAppIDs = visibleChildren
        representedFolderID = folderID
        self.iconProvider = iconProvider

        let scale = currentBackingScale
        lastRequestedScale = scale
        thumbnail.configure(
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
            folderThumbnailView?.updateScale(CGFloat(scale))
            folderThumbnailView?.clearIconContents()
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
        pressPresentation?.cancel()
        invalidateIconRequests()
        resetCreateFolderTargetHighlight()
        representedAppID = nil
        representedFolderID = nil
        folderChildAppIDs = []
        iconProvider = nil
        // 只隐藏/重置已存在的缩略图, 不释放: 文件夹重配置经 ensure 复用同一实例;
        // App 配置在 beginConfiguration 之后显式 release。
        folderThumbnailView?.reset()
        iconLayer.isHidden = false
    }

    /// 懒创建文件夹缩略图视图并加入 pressContainer 层级; 若已存在则复用同一
    /// 实例(文件夹重配置不销毁重建)。普通 App 配置不调用; 仅 configureFolder 调用。
    private func ensureFolderThumbnailView() -> FolderThumbnailView {
        if let folderThumbnailView { return folderThumbnailView }
        let thumbnail = FolderThumbnailView()
        thumbnail.isHidden = true
        pressContainerView.addSubview(thumbnail)
        folderThumbnailView = thumbnail
        return thumbnail
    }

    /// 释放文件夹缩略图层级: reset 状态、从 superview 移除并置 nil, 使
    /// NSVisualEffectView + container/sheen + 9 个图标 layer 真正被释放。
    /// 仅 App 配置(configure)在 beginConfiguration 之后调用; 下一次文件夹
    /// 配置经 ensure 重新创建。
    private func releaseFolderThumbnailView() {
        guard let folderThumbnailView else { return }
        folderThumbnailView.reset()
        folderThumbnailView.removeFromSuperview()
        self.folderThumbnailView = nil
    }

    private func registerPendingDragGrabOffset(pointerInWindow: NSPoint) {
        guard let window = view.window,
              let contentView = window.contentView,
              let frame = dragVisualFrame(in: contentView) else {
            return
        }
        let centerInContent = NSPoint(x: frame.midX, y: frame.midY)
        let centerInWindow = contentView.convert(centerInContent, to: nil)
        DragOverlayLayer.registerPendingSourceVisualCenter(
            centerInWindow: centerInWindow,
            pointerInWindow: pointerInWindow
        )
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
        // P0-05: 子图标按缩略图实际显示尺寸请求(metrics.iconSide, 向下取整,
        // 与 PageVisualRenderer.resolveIcons 同一取整约定 → 同一 IconKey 缓存
        // 身份)。旧实现按整格 iconPointSize 请求(~4.1× 线性超采)。
        let size = max(
            1,
            Int(FolderThumbnailMetrics(side: CGFloat(iconPointSize)).iconSide.rounded(.down))
        )
        folderIconRequestTasks = children.prefix(FolderThumbnailMetrics.maxIconCount).enumerated().map {
            index, appID in
            Task { [weak self] in
                guard !Task.isCancelled else { return }
                let image = await provider.icon(for: appID, pointSize: size, scale: scale)
                guard !Task.isCancelled,
                      let self,
                      self.representedFolderID == folderID,
                      self.requestGeneration == expectedGeneration else { return }
                self.folderThumbnailView?.setIcon(image, at: index, scale: CGFloat(scale))
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
        // E13: 真实图标应用成功后关闭 masksToBounds(图标自带圆角 alpha);
        // 无图标仍为占位, 保持圆角裁剪。
        updateIconMasking()
        CATransaction.commit()
    }
}

/// 主网格文件夹缩略图: AppKit 磨砂背景承载最多 3x3 个真实图标。
///
/// 未拿到图标时对应位置保持透明，不绘制首字母或色块占位，避免把文件夹
/// 缩略图误认为普通 App 单元格。所有尺寸都按当前 cell 的 point/Retina scale
/// 重新计算，图标 layer 不跨 cell 共享。
private final class FolderThumbnailView: NSVisualEffectView {
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

        for _ in 0..<FolderThumbnailMetrics.maxIconCount {
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
        self.iconCount = FolderThumbnailMetrics.clampedIconCount(iconCount)
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
        // P0-04: 几何唯一真值来自 FolderThumbnailMetrics(与 PageVisualRenderer
        // 共用同一公式, 消除两处硬编码漂移)。
        let metrics = FolderThumbnailMetrics(side: min(bounds.width, bounds.height))
        layer?.cornerRadius = metrics.radius
        iconContainerLayer.frame = bounds
        iconContainerLayer.cornerRadius = metrics.radius
        sheenLayer.frame = bounds
        sheenLayer.cornerRadius = metrics.radius

        for (index, iconLayer) in iconLayers.enumerated() {
            let frame = metrics.childFrame(index: index)
            // AppKit 非翻转视图: 子图标网格锚定到完整 bounds 底部(top-down
            // childFrame 的 y 翻转; 非正方形 bounds 用 bounds.height 而非 side)。
            iconLayer.frame = CGRect(
                x: frame.minX,
                y: bounds.height - frame.maxY,
                width: frame.width,
                height: frame.height
            )
            iconLayer.cornerRadius = metrics.childRadius
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

/// 单元格根视图: 感知 backing scale 变化(显示器切换 → Retina 变体重请求)。
/// 使用标准 AppKit 生命周期 viewDidChangeBackingProperties()(系统在 scale 变化时
/// 直接回调, 零全局通知; Stage A7 替代 per-cell didChangeScreenNotification)。
private final class CellRootView: NSView {
    var onWindowChange: (() -> Void)?
    var onScreenChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }

    /// 标准回调: backing properties(含 backingScaleFactor)变化时触发。
    /// 同 scale 显示器切换不会调用; 1x↔2x 会调用。lastRequestedScale guard 防重复请求。
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onScreenChange?()
    }
}
