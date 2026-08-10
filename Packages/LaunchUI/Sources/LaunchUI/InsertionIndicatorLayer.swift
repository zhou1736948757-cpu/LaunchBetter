import AppKit
import LaunchCore

/// 蓝色垂直插入指示器；仅在普通 reorder preview 时显示。
@MainActor
final class InsertionIndicatorLayer {
    let layer = CALayer()

    init() {
        layer.backgroundColor = NSColor.systemBlue.cgColor
        layer.cornerRadius = 2
        layer.shadowColor = NSColor.systemBlue.cgColor
        layer.shadowOpacity = 0.8
        layer.shadowRadius = 4
        layer.zPosition = 10_000
        layer.isHidden = true
    }

    func show(at slotFrame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(
            x: slotFrame.minX - 6,
            y: slotFrame.minY + 6,
            width: 4,
            height: max(16, slotFrame.height - 12)
        )
        layer.isHidden = false
        CATransaction.commit()
    }

    func hide() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = true
        CATransaction.commit()
    }
}
