import AppKit
import QuartzCore

/// Launcher 自己的过渡意图；不抽象成跨功能的动画框架。
enum LauncherTransitionIntent: Equatable, Sendable {
    case show
    case hide
}

/// Launcher 前景与背景在某一帧的可见值。
///
/// 这些值只描述视觉 presentation，不进入 LauncherStore，也不触发布局或 IO。
struct LauncherTransitionPresentation: Equatable, Sendable {
    let surfaceScale: CGFloat
    let surfaceOpacity: Float
    let backgroundOpacity: Float
    let dimOpacity: Float

    static let hidden = LauncherTransitionPresentation(
        surfaceScale: 0.985,
        surfaceOpacity: 0,
        backgroundOpacity: 0,
        dimOpacity: 0
    )

    static let visible = LauncherTransitionPresentation(
        surfaceScale: 1,
        surfaceOpacity: 1,
        backgroundOpacity: 1,
        dimOpacity: 1
    )

    func withSurfaceScale(_ scale: CGFloat) -> LauncherTransitionPresentation {
        LauncherTransitionPresentation(
            surfaceScale: scale,
            surfaceOpacity: surfaceOpacity,
            backgroundOpacity: backgroundOpacity,
            dimOpacity: dimOpacity
        )
    }
}

/// 纯策略层：从当前可见值到最新意图的单段过渡。
///
/// 反转时 `from` 原样保留 presentation 值；这保证 show→hide→show 与
/// hide→show→hide 不会先回到旧终点再开始新动画。
struct LauncherTransitionPlan: Equatable, Sendable {
    let intent: LauncherTransitionIntent
    let from: LauncherTransitionPresentation
    let to: LauncherTransitionPresentation
    let duration: TimeInterval
    let animatesSurfaceScale: Bool

    init(
        intent: LauncherTransitionIntent,
        from: LauncherTransitionPresentation,
        policy: LauncherMotionPolicy
    ) {
        let target = policy.presentation(for: intent)
        self.intent = intent
        self.from = policy.animatesSurfaceScale
            ? from
            : from.withSurfaceScale(target.surfaceScale)
        to = target
        duration = policy.duration
        animatesSurfaceScale = policy.animatesSurfaceScale
    }
}

/// Launcher M1/M2 专属 Core Animation 驱动器。
///
/// - foreground surface 包含 Grid/Search/Settings/Page dots，作为一个 layer 动画。
/// - 背景层只改变 opacity，保持空间位置稳定。
/// - 每次新意图先读取 presentation layer，再移除旧动画并从该值继续。
/// - 生命周期 token 由 LauncherWindowController 持有；这里的 serial 只负责
///   丢弃被中断的 CA transaction completion。
@MainActor
final class LauncherTransitionCoordinator {
    private weak var window: NSWindow?
    private weak var surfaceLayer: CALayer?
    private weak var backgroundLayer: CALayer?
    private weak var dimLayer: CALayer?

    private var serial: UInt64 = 0
    private var activePlan: LauncherTransitionPlan?
    private var activeCompletion: (() -> Void)?

    private static let surfaceAnimationKey = "launchbetter.launcher.surfaceTransition"
    private static let backgroundAnimationKey = "launchbetter.launcher.backgroundTransition"
    private static let dimAnimationKey = "launchbetter.launcher.dimTransition"

    init(
        window: NSWindow,
        surfaceLayer: CALayer,
        backgroundLayer: CALayer,
        dimLayer: CALayer
    ) {
        self.window = window
        self.surfaceLayer = surfaceLayer
        self.backgroundLayer = backgroundLayer
        self.dimLayer = dimLayer
    }

    /// window alpha 是 order/front 的可见性闸门；真正的连续值由本 coordinator
    /// 的 layer animation 管理，避免 NSWindow animator 的 model 值参与反转。
    func prepareForShow() {
        window?.alphaValue = 1
    }

    func prepareForHide() {
        window?.alphaValue = 1
    }

    /// 从当前 layer presentation 启动一段最新意图的动画。
    func transition(
        to intent: LauncherTransitionIntent,
        policy: LauncherMotionPolicy,
        completion: @escaping () -> Void
    ) {
        let current = presentation()

        // 先让旧 completion 失效，再移除旧动画。AppKit/Core Animation 可能
        // 在移除或 transaction 收尾时回调旧 completion；serial 会挡住它。
        serial &+= 1
        let currentSerial = serial
        activePlan = nil
        activeCompletion = nil
        removeAnimations()

        let plan = LauncherTransitionPlan(intent: intent, from: current, policy: policy)
        activePlan = plan
        activeCompletion = completion

        guard surfaceLayer != nil, backgroundLayer != nil, dimLayer != nil else {
            finish(serial: currentSerial)
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(plan.to)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.finish(serial: currentSerial)
            }
        }

        let surfaceAnimations = surfaceAnimations(for: plan)
        let surfaceGroup = CAAnimationGroup()
        surfaceGroup.animations = surfaceAnimations
        surfaceGroup.duration = plan.duration
        surfaceGroup.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        surfaceLayer?.add(surfaceGroup, forKey: Self.surfaceAnimationKey)

        backgroundLayer?.add(
            opacityAnimation(
                from: plan.from.backgroundOpacity,
                to: plan.to.backgroundOpacity,
                duration: plan.duration
            ),
            forKey: Self.backgroundAnimationKey
        )
        dimLayer?.add(
            opacityAnimation(
                from: plan.from.dimOpacity,
                to: plan.to.dimOpacity,
                duration: plan.duration
            ),
            forKey: Self.dimAnimationKey
        )
        CATransaction.commit()
    }

    /// 用于诊断和纯策略测试的当前可见值；有 presentation 时优先读取它。
    func presentation() -> LauncherTransitionPresentation {
        LauncherTransitionPresentation(
            surfaceScale: scale(of: surfaceLayer),
            surfaceOpacity: opacity(of: surfaceLayer),
            backgroundOpacity: opacity(of: backgroundLayer),
            dimOpacity: opacity(of: dimLayer)
        )
    }

    private func finish(serial finishedSerial: UInt64) {
        guard serial == finishedSerial,
              let plan = activePlan,
              let completion = activeCompletion else {
            return
        }

        activePlan = nil
        activeCompletion = nil
        withoutAnimations {
            apply(plan.to)
        }
        completion()
    }

    private func removeAnimations() {
        surfaceLayer?.removeAnimation(forKey: Self.surfaceAnimationKey)
        backgroundLayer?.removeAnimation(forKey: Self.backgroundAnimationKey)
        dimLayer?.removeAnimation(forKey: Self.dimAnimationKey)
    }

    private func apply(_ presentation: LauncherTransitionPresentation) {
        surfaceLayer?.opacity = presentation.surfaceOpacity
        surfaceLayer?.transform = CATransform3DMakeScale(
            presentation.surfaceScale,
            presentation.surfaceScale,
            1
        )
        backgroundLayer?.opacity = presentation.backgroundOpacity
        dimLayer?.opacity = presentation.dimOpacity
    }

    private func withoutAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func surfaceAnimations(for plan: LauncherTransitionPlan) -> [CAAnimation] {
        var animations: [CAAnimation] = [
            opacityAnimation(
                from: plan.from.surfaceOpacity,
                to: plan.to.surfaceOpacity,
                duration: plan.duration
            )
        ]
        if plan.animatesSurfaceScale {
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = CATransform3DMakeScale(
                plan.from.surfaceScale,
                plan.from.surfaceScale,
                1
            )
            scale.toValue = CATransform3DMakeScale(
                plan.to.surfaceScale,
                plan.to.surfaceScale,
                1
            )
            scale.duration = plan.duration
            scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animations.append(scale)
        }
        return animations
    }

    private func opacityAnimation(
        from: Float,
        to: Float,
        duration: TimeInterval
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

    private func opacity(of layer: CALayer?) -> Float {
        guard let layer else { return 0 }
        let value = layer.presentation()?.opacity ?? layer.opacity
        return min(max(value, 0), 1)
    }

    private func scale(of layer: CALayer?) -> CGFloat {
        guard let layer else { return 1 }
        let transform = layer.presentation()?.transform ?? layer.transform
        let x = sqrt(Double(transform.m11 * transform.m11 + transform.m12 * transform.m12))
        let y = sqrt(Double(transform.m21 * transform.m21 + transform.m22 * transform.m22))
        return CGFloat((x + y) / 2)
    }
}
