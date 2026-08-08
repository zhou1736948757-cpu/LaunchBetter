import AppKit
import LaunchCore

/// 应用单元格: 图标(CALayer contents)+ 标签。
///
/// 图标加载(§85 复用竞态防护):
/// - `representedAppID` + `iconRequestTask`
/// - 复用时: 取消消费者任务、清除 represented ID、恢复占位
/// - 结果应用条件: 任务未取消 AND representedAppID 仍等于期望 ID
/// - 消费者取消不杀死共享图标任务(§81)
final class AppCellView: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("AppCellView")

    private let iconLayer = CALayer()
    private let label = NSTextField(labelWithString: "")
    private let letterLayer = CATextLayer()

    private var representedAppID: AppID?
    private var iconRequestTask: Task<Void, Never>?
    private var iconProvider: (any IconImageProviding)?

    override func loadView() {
        let root = NSView()
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
        label.maximumNumberOfLines = 2
        label.textColor = .white
        label.shadow = NSShadow()
        label.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.6)
        label.shadow?.shadowBlurRadius = 2
        label.shadow?.shadowOffset = NSSize(width: 0, height: -1)
        root.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            label.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2),
        ])
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.frame = view.bounds
        letterLayer.frame = view.bounds
        letterLayer.contentsScale = view.window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconRequestTask?.cancel()
        iconRequestTask = nil
        representedAppID = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.contents = nil
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
        let scale = view.window?.backingScaleFactor ?? 2
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let image = await iconProvider.icon(for: expectedID, pointSize: pointSize, scale: Int(scale))
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
            letterLayer.isHidden = true
        } else {
            // 无图标: 保持占位
            iconLayer.contents = nil
            letterLayer.isHidden = false
        }
        CATransaction.commit()
    }
}
