import AppKit
import LaunchCore

/// 拖拽 overlay: 跟随光标的真实图标层 + 文件夹目标提示。
@MainActor
final class DragOverlayLayer {
    let layer = CALayer()
    private let iconLayer = CALayer()
    private let labelLayer = CATextLayer()
    private var hasSourceImage = false

    init() {
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = local
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
