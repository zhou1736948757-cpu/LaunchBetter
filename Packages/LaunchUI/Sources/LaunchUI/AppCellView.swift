import AppKit
import LaunchCore

/// 应用单元格: 图标(CALayer contents)+ 标签。
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

    /// 标签高度(pt)。
    private static let labelHeight: CGFloat = 13

    private let iconLayer = CALayer()
    private let label = NSTextField(labelWithString: "")
    private let letterLayer = CATextLayer()
    private var labelBottomConstraint: NSLayoutConstraint?

    private var representedAppID: AppID?
    private var iconRequestTask: Task<Void, Never>?
    private var iconProvider: (any IconImageProviding)?

    /// 当前配置的图标点尺寸(与 IconKey 请求一致)。
    private var iconPointSize: Int = 80
    private var lastRequestedScale = 0

    /// 源单元格当前显示的图标(拖拽 overlay 复用, 零磁盘 IO)。
    var visibleIconImage: CGImage? {
        guard let contents = iconLayer.contents else { return nil }
        return contents as! CGImage
    }

    override func loadView() {
        let root = CellRootView()
        root.onWindowChange = { [weak self] in
            self?.reRequestIconIfScaleChanged()
        }
        root.wantsLayer = true
        iconLayer.cornerRadius = 16
        iconLayer.masksToBounds = true
        root.layer?.addSublayer(iconLayer)

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
        iconLayer.frame = iconFrame
        letterLayer.frame = iconFrame
        letterLayer.fontSize = size * 0.5
        letterLayer.contentsScale = view.window?.backingScaleFactor ?? 2

        let gap = max(6, (bounds.height - size) / 4)
        labelBottomConstraint?.constant = -gap
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconRequestTask?.cancel()
        iconRequestTask = nil
        representedAppID = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.contents = nil
        // M3: 复用强制恢复 identity(防止拖拽预览变换污染)
        view.layer?.transform = CATransform3DIdentity
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
        iconPointSize = max(16, pointSize)
        letterLayer.string = String(displayName.prefix(1)).uppercased()
        letterLayer.isHidden = false

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

        guard let appID, let iconProvider else {
            representedAppID = nil
            return
        }

        // 启动异步图标加载(消费者任务;取消不杀死共享任务)
        representedAppID = appID
        let expectedID = appID
        iconRequestTask?.cancel()
        let scale = Int(view.window?.backingScaleFactor ?? 2)
        lastRequestedScale = scale
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let image = await iconProvider.icon(
                for: expectedID, pointSize: pointSize, scale: scale
            )
            guard !Task.isCancelled, let self, self.representedAppID == expectedID else { return }
            self.applyIcon(image)
        }
        iconRequestTask = task
    }

    /// 窗口显示器变更(backing scale 变化)→ 以新 scale 重新请求图标(Stage 1 §32)。
    private func reRequestIconIfScaleChanged() {
        guard let window = view.window, let appID = representedAppID, let iconProvider else { return }
        let scale = Int(window.backingScaleFactor)
        guard scale != lastRequestedScale, iconRequestTask != nil else { return }
        iconRequestTask?.cancel()
        let expectedID = appID
        lastRequestedScale = scale
        let provider = iconProvider
        let size = iconPointSize
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let image = await provider.icon(
                for: expectedID, pointSize: size, scale: scale
            )
            guard !Task.isCancelled, let self, self.representedAppID == expectedID else { return }
            self.applyIcon(image)
        }
        iconRequestTask = task
    }

    private func applyIcon(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image {
            iconLayer.contents = image
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.contentsScale = view.window?.backingScaleFactor ?? 2
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

/// 单元格根视图: 感知窗口变更(显示器切换 → backing scale 变化)。
private final class CellRootView: NSView {
    var onWindowChange: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}
