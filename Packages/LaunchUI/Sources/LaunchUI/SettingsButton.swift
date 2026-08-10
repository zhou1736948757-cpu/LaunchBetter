import AppKit

/// 右上角设置齿轮按钮(LaunchBetter 简洁 macOS 风格)。
///
/// - 40×40, 半透明玻璃背景, 圆角 11pt, 轻微边框 + 阴影
/// - 齿轮 22pt systemBlue(systemSymbolName "gearshape")
/// - Hover: 背景稍亮 + 轻微放大(1.05); Pressed: 轻微缩小(0.92)
/// - 无文字、无持续动画、不抢眼
/// - 自定义绘制(无 bezel): 单一设置入口, 消除箭头/边框视觉干扰
final class SettingsButton: NSButton {
    private static let normalBackground = NSColor.white.withAlphaComponent(0.10)
    private static let hoverBackground = NSColor.white.withAlphaComponent(0.20)
    private static let borderColor = NSColor.white.withAlphaComponent(0.28)

    private let gearImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        return NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }()

    private var isHovering = false
    private var isPressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        isBordered = false
        setButtonType(.momentaryChange)
        image = gearImage
        contentTintColor = .systemBlue
        imagePosition = .imageOnly
        toolTip = L10n.t(.settings)
        setAccessibilityLabel(L10n.t(.settings))
        setAccessibilityRole(.button)

        wantsLayer = true
        layer?.backgroundColor = Self.normalBackground.cgColor
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        layer?.borderColor = Self.borderColor.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.masksToBounds = false
    }

    // MARK: - 状态

    private func updateAppearance() {
        let bg = isPressed ? Self.hoverBackground : (isHovering ? Self.hoverBackground : Self.normalBackground)
        let scale: CGFloat = isPressed ? 0.92 : (isHovering ? 1.05 : 1.0)
        CATransaction.begin()
        CATransaction.setDisableActions(false)
        layer?.backgroundColor = bg.cgColor
        layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressed = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateAppearance()
        // 保留 action 触发(松手时)
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        updateAppearance()
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside {
            sendAction(action, to: target)
        }
    }
}
