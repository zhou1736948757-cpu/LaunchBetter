import AppKit
import LaunchCore

/// 应用单元格: 占位图标(圆角色块 + 首字母)+ 标签。
/// Phase 4 将把占位图标替换为 IconRepository 提供的真实图标。
final class AppCellView: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("AppCellView")

    private let iconLayer = CALayer()
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        iconLayer.cornerRadius = 16
        iconLayer.masksToBounds = true
        root.layer?.addSublayer(iconLayer)

        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        root.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
        ])
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.frame = view.bounds
        CATransaction.commit()
    }

    /// 配置占位图标与标签。
    func configure(displayName: String, colorIndex: Int, accessibilityHint: String) {
        let letter = String(displayName.prefix(1)).uppercased()
        iconLayer.contents = nil

        // 占位: 先清除子层再绘制文本图层(避免复用残留)
        iconLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let textLayer = CATextLayer()
        textLayer.string = letter
        textLayer.fontSize = 36
        textLayer.alignmentMode = .center
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.frame = iconLayer.bounds
        textLayer.contentsScale = view.window?.backingScaleFactor ?? 2
        iconLayer.addSublayer(textLayer)

        let hue = CGFloat(colorIndex % 12) / 12
        iconLayer.backgroundColor = NSColor(
            hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1
        ).cgColor

        label.stringValue = displayName
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(displayName)
        view.setAccessibilityHelp(accessibilityHint)
    }
}
