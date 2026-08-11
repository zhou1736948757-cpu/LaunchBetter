import AppKit
import LaunchCore

/// 只影响拖拽视觉 overlay 的中心位置；hit-test/drop 继续消费原始 pointer。
struct DragGrabOffset: Equatable {
    let dx: CGFloat
    let dy: CGFloat

    init(sourceVisualCenter: NSPoint, pointerAtStart: NSPoint) {
        dx = sourceVisualCenter.x - pointerAtStart.x
        dy = sourceVisualCenter.y - pointerAtStart.y
    }

    init(dx: CGFloat, dy: CGFloat) {
        self.dx = dx
        self.dy = dy
    }

    func visualCenter(for pointer: NSPoint) -> NSPoint {
        NSPoint(x: pointer.x + dx, y: pointer.y + dy)
    }
}

/// 拖拽 overlay: 跟随光标的真实图标层 + 文件夹目标提示。
@MainActor
final class DragOverlayLayer {
    private struct PendingSourceVisualCenter {
        let centerInWindow: NSPoint
        let pointerInWindow: NSPoint
    }

    private static var pendingSourceVisualCenter: PendingSourceVisualCenter?

    /// AppCell 在真实 threshold crossing 时登记 source visual center；
    /// overlay 首个 move 消费它。该注册不改变任何语义目的地。
    static func registerPendingSourceVisualCenter(
        centerInWindow: NSPoint,
        pointerInWindow: NSPoint
    ) {
        pendingSourceVisualCenter = PendingSourceVisualCenter(
            centerInWindow: centerInWindow,
            pointerInWindow: pointerInWindow
        )
    }

    static func clearPendingSourceVisualCenter() {
        pendingSourceVisualCenter = nil
    }

    let layer = CALayer()
    private let iconLayer = CALayer()
    private let labelLayer = CATextLayer()
    private var hasSourceImage = false
    private var grabOffset: DragGrabOffset?

    /// 最近一次传入的 semantic pointer；仅供确定性测试审计。
    private(set) var lastPointerPosition: NSPoint?

    /// 当前仅作用于 overlay visual position 的 offset；仅供确定性测试审计。
    var grabOffsetForDiagnostics: DragGrabOffset { grabOffset ?? DragGrabOffset(sourceVisualCenter: .zero, pointerAtStart: .zero) }

    init() {
        layer.name = "LaunchBetter.DragOverlayLayer"
        layer.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: -4)
        iconLayer.cornerRadius = 16
        iconLayer.masksToBounds = true
        iconLayer.frame = layer.bounds
        iconLayer.contentsGravity = .resizeAspect
        labelLayer.fontSize = 11
        labelLayer.alignmentMode = .center
        labelLayer.foregroundColor = NSColor.white.cgColor
        labelLayer.frame = CGRect(x: 0, y: -20, width: 96, height: 16)
        layer.addSublayer(iconLayer)
        layer.addSublayer(labelLayer)
        layer.isHidden = true
    }

    /// 配置 overlay: 复用源单元格已渲染视觉表示(零磁盘 IO), 无图像时保留占位。
    func configure(label: String, representation: DragVisualRepresentation?) {
        grabOffset = nil
        lastPointerPosition = nil
        let scale = representation?.rasterScale
            ?? max(1, NSScreen.main?.backingScaleFactor ?? 2)
        layer.contentsScale = scale
        iconLayer.contentsScale = scale
        labelLayer.contentsScale = scale
        iconLayer.frame = fittedIconFrame(for: representation?.logicalSize)

        hasSourceImage = representation != nil
        if let representation {
            iconLayer.contents = representation.image
            iconLayer.backgroundColor = nil
        } else {
            iconLayer.contents = nil
            iconLayer.backgroundColor = NSColor.systemGray.cgColor
        }
        labelLayer.string = label
        layer.isHidden = false
    }

    /// 保留 FolderViewController 现有的 folder-child 调用签名。
    func configure(label: String, sourceImage: CGImage?) {
        configure(
            label: label,
            representation: DragVisualRepresentation.legacy(image: sourceImage)
        )
    }

    private func fittedIconFrame(for logicalSize: CGSize?) -> CGRect {
        guard let logicalSize,
              logicalSize.width > 0,
              logicalSize.height > 0,
              layer.bounds.width > 0,
              layer.bounds.height > 0 else {
            return layer.bounds
        }
        let factor = min(
            layer.bounds.width / logicalSize.width,
            layer.bounds.height / logicalSize.height
        )
        let size = CGSize(
            width: logicalSize.width * factor,
            height: logicalSize.height * factor
        )
        return CGRect(
            x: layer.bounds.midX - size.width / 2,
            y: layer.bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// 位置必须转 overlay 挂载父视图(视口)坐标 —— 分页滚动后 document 坐标含页偏移(评审 M6)。
    func move(to point: NSPoint, in container: NSView) {
        let local = container.convert(point, from: nil)
        lastPointerPosition = point

        if grabOffset == nil {
            let pending = Self.pendingSourceVisualCenter
            Self.pendingSourceVisualCenter = nil
            if let pending,
               abs(pending.pointerInWindow.x - point.x) <= 0.5,
               abs(pending.pointerInWindow.y - point.y) <= 0.5 {
                let sourceCenter = container.convert(pending.centerInWindow, from: nil)
                let pointerAtStart = container.convert(pending.pointerInWindow, from: nil)
                grabOffset = DragGrabOffset(
                    sourceVisualCenter: sourceCenter,
                    pointerAtStart: pointerAtStart
                )
            } else {
                // 没有可证明的同一 threshold pointer 时不猜 offset，保持旧的
                // center=pointer 语义，避免迟到/无关 session 污染当前 drag。
                grabOffset = DragGrabOffset(sourceVisualCenter: local, pointerAtStart: local)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = grabOffset?.visualCenter(for: local) ?? local
        CATransaction.commit()
    }

    func showFolderTarget(_ folder: FolderID, store: any LauncherStoring) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.backgroundColor = NSColor.systemGreen.cgColor
        labelLayer.string = L10n.format(.dropIntoFolder, store.folderName(for: folder))
        CATransaction.commit()
    }

    func showCreateFolderTarget(name: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.backgroundColor = NSColor.systemBlue.cgColor
        labelLayer.string = L10n.format(.createFolderWith, name)
        CATransaction.commit()
    }

    func showPlain(label: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.backgroundColor = hasSourceImage ? nil : NSColor.systemGray.cgColor
        labelLayer.string = label
        CATransaction.commit()
    }
}
