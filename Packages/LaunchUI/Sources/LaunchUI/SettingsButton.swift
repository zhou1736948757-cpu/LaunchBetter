import AppKit
import QuartzCore

/// 右上角设置齿轮按钮(LaunchBetter 简洁 macOS 风格)。
///
/// 不依赖 `.texturedRounded`/`NSButton.image` 决定外形(内部 image 视图约束会把
/// 按钮撑高成纵向圆角矩形, v0.3.5 实测 40×52)。改用:
/// - borderless NSButton + 自绘 CALayer 背景 → 形状完全可控
/// - 40×40 真圆角正方形, cornerRadius 11
/// - gearshape 22pt systemBlue(手动 tint, 不依赖 contentTintColor)
/// - Hover: 背景稍亮 + 轻微放大(1.05); Pressed: 轻微缩小(0.92)
/// - 无文字、无持续动画、不抢眼
final class SettingsButton: NSButton {
    private static let normalBackground = NSColor.white.withAlphaComponent(0.10)
    private static let hoverBackground = NSColor.white.withAlphaComponent(0.20)
    private static let borderColor = NSColor.white.withAlphaComponent(0.28)

    private let iconLayer = CALayer()
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

        iconLayer.contents = Self.tintedGearImage()
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.minificationFilter = .linear
        iconLayer.magnificationFilter = .linear
        layer?.addSublayer(iconLayer)
    }

    override func layout() {
        super.layout()
        // 齿轮 22pt 居中(背景 40×40, cornerRadius 11 不影响居中的 22pt 内容)
        let side: CGFloat = 22
        iconLayer.frame = CGRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
    }

    /// 生成 systemBlue 齿轮 CGImage: 先画 symbol 再用 sourceAtop 填充颜色
    /// (顺序必须是 先 draw 后 fill, 否则填充无效, 齿轮呈灰白)。
    private static func tintedGearImage() -> CGImage? {
        guard let base = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        guard let sized = base.withSymbolConfiguration(config) else { return nil }

        let tinted = NSImage(size: sized.size)
        tinted.lockFocus()
        let rect = NSRect(origin: .zero, size: sized.size)
        sized.draw(in: rect)
        NSColor.systemBlue.set()
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        var proposed = NSRect(origin: .zero, size: sized.size)
        return tinted.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    // MARK: - 状态

    private func updateAppearance() {
        let bg = (isPressed || isHovering) ? Self.hoverBackground : Self.normalBackground
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
