import AppKit
import QuartzCore

/// App/Folder cell 的短按视觉状态。
///
/// ClickableCollectionView 仍是 mouse session 与 drag threshold 的唯一 owner；
/// 本对象只拥有一个独立的 presentation layer transform，不读写 cell root 的
/// reorder transform 或 source opacity。
@MainActor
final class PressDragPresentation {
    enum Phase: Equatable {
        case idle
        case pressed
        case dragging
    }

    static let dragThreshold: CGFloat = 5

    private static let animationKey = "LaunchBetter.pressFeedback"

    private let layer: CALayer
    private let presentationTransformProvider: () -> CATransform3D?
    private var pressStartPoint: NSPoint?

    private(set) var phase: Phase = .idle
    private(set) var lastAnimationFromScaleForDiagnostics: CGFloat?

    /// 超过阈值时由 AppCell 注册 visual grab offset；不改变语义 pointer。
    var onDragThresholdCrossed: ((NSPoint) -> Void)?

    /// 一次 press session 结束时清除未被 overlay 消费的 pending offset。
    var onSessionEnded: (() -> Void)?

    init(layer: CALayer, presentationTransformProvider: (() -> CATransform3D?)? = nil) {
        self.layer = layer
        self.presentationTransformProvider = presentationTransformProvider ?? {
            layer.presentation()?.transform
        }
        layer.actions = [
            "transform": NSNull(),
        ]
    }

    /// mouseDown 的第一同步步骤：立即进入轻微压缩状态。
    func begin(at point: NSPoint) {
        guard phase == .idle else {
            cancel()
            return
        }
        phase = .pressed
        pressStartPoint = point
        // 压缩本身直接落到 model layer，确保 mouseDown 的第一帧就可见；
        // MotionTokens.pressFeedback 只用于 mouseUp 的恢复，不延迟输入。
        setImmediately(to: MotionTokens.pressScale)
    }

    /// 由 ClickableCollectionView 在每个真实 mouseDragged 事件中调用。
    /// 首次跨过同一阈值时保留当前 presentation，不先回弹再进入 drag。
    func move(to point: NSPoint) {
        guard phase == .pressed, let start = pressStartPoint else { return }
        let dx = point.x - start.x
        let dy = point.y - start.y
        guard dx * dx + dy * dy >= Self.dragThreshold * Self.dragThreshold else { return }

        phase = .dragging
        holdCurrentPresentation()
        onDragThresholdCrossed?(point)
    }

    /// mouseUp 的恢复路径。拖拽结束时直接恢复，避免隐藏 source 在后台继续动画。
    func end(afterDragging: Bool) {
        guard phase != .idle else { return }
        let wasDragging = afterDragging || phase == .dragging
        phase = .idle
        pressStartPoint = nil
        onSessionEnded?()

        if wasDragging {
            restoreImmediately()
        } else {
            animate(to: 1)
        }
    }

    /// 覆盖层切换、复用或取消路径使用无动画恢复。
    func cancel() {
        guard phase != .idle || pressStartPoint != nil else {
            restoreImmediately()
            return
        }
        phase = .idle
        pressStartPoint = nil
        onSessionEnded?()
        restoreImmediately()
    }

    /// 拖拽 controller 隐藏 source 时调用；不清除 pending offset，保证随后
    /// overlay 的首个 move 仍能消费同一物理 mouse session 的抓取偏移。
    func finishForDragLifecycle() {
        guard phase != .idle || pressStartPoint != nil else {
            restoreImmediately()
            return
        }
        phase = .idle
        pressStartPoint = nil
        restoreImmediately()
    }

    /// 测试/诊断用的 model scale；presentation 动画不影响语义状态。
    var modelScaleForDiagnostics: CGFloat {
        layer.transform.m11
    }

    /// 测试/诊断用的 presentation scale。
    var presentationScaleForDiagnostics: CGFloat {
        (layer.presentation()?.transform ?? layer.transform).m11
    }

    private func animate(to targetScale: CGFloat) {
        lastAnimationFromScaleForDiagnostics = nil
        let from = currentTransform()
        let target = CATransform3DMakeScale(targetScale, targetScale, 1)
        layer.removeAnimation(forKey: Self.animationKey)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = target
        CATransaction.commit()

        guard !CATransform3DEqualToTransform(from, target) else { return }

        // MotionTokens.pressFeedback 是临界阻尼的短反馈；这里将 response /
        // dampingRatio 映射到 CASpringAnimation，避免散落另一套时长常数。
        let spec = MotionTokens.pressFeedback
        let angularFrequency = 2 * Double.pi / spec.response
        let animation = CASpringAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: target)
        animation.mass = 1
        animation.stiffness = CGFloat(angularFrequency * angularFrequency)
        animation.damping = CGFloat(2 * Double(spec.dampingRatio) * angularFrequency)
        animation.initialVelocity = 0
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: Self.animationKey)
        lastAnimationFromScaleForDiagnostics = from.m11
    }

    private func holdCurrentPresentation() {
        let current = currentTransform()
        layer.removeAnimation(forKey: Self.animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = current
        CATransaction.commit()
    }

    private func restoreImmediately() {
        layer.removeAnimation(forKey: Self.animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func setImmediately(to targetScale: CGFloat) {
        layer.removeAnimation(forKey: Self.animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(targetScale, targetScale, 1)
        CATransaction.commit()
    }

    private func currentTransform() -> CATransform3D {
        let model = layer.transform
        guard let presentation = presentationTransformProvider() else { return model }

        // A very fast mouseUp can arrive before Core Animation publishes the
        // model change in presentation(). Keep the visible press as the start
        // of release instead of animating identity to identity.
        if CATransform3DEqualToTransform(presentation, CATransform3DIdentity),
           !CATransform3DEqualToTransform(model, CATransform3DIdentity) {
            return model
        }
        return presentation
    }
}
