import AppKit

/// 可点击页码指示点(Stage A8, 借鉴 Buho 逆向的交互式页点概念, 独立实现)。
///
/// - 视觉: 6×6 圆点(active 高亮)
/// - 交互: 24×24 命中区域(视觉点周围更大的可点区域)
/// - 点击复用现有 paging engine(PagingInteractionController.startSettle),
///   不手动动画 NSClipView / 不直接改 currentPage。
/// - 无障碍: button 语义 + 本地化 "Page X of Y"
@MainActor
final class PageDotView: NSView {
    var onClick: (() -> Void)?

    private let dot = NSView()
    private var isActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        setAccessibilityRole(.button)
        setAccessibilityElement(true)
    }

    func setActive(_ active: Bool) {
        isActive = active
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.layer?.backgroundColor = (active
            ? NSColor.white
            : NSColor.white.withAlphaComponent(0.4)).cgColor
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 24, height: 24)
    }
}
