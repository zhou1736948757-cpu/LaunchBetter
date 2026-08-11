import AppKit
import QuartzCore

/// Settings window 的单次视觉意图。
public enum SettingsTransitionIntent: Equatable, Sendable {
    case present
    case dismiss
}

/// Settings transition 的生命周期状态。
public enum SettingsTransitionState: Equatable, Sendable {
    case hidden
    case presenting
    case visible
    case dismissing
}

/// 以 points 表示的、只用于 Settings transition 的二维偏移。
public struct SettingsTransitionVector: Equatable, Sendable {
    public let x: CGFloat
    public let y: CGFloat

    public static let zero = SettingsTransitionVector(x: 0, y: 0)

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }
}

/// Settings 在某一帧的可见 presentation 值。
public struct SettingsTransitionPresentation: Equatable, Sendable {
    public let opacity: Float
    public let scale: CGFloat
    public let translation: SettingsTransitionVector

    public init(
        opacity: Float,
        scale: CGFloat,
        translation: SettingsTransitionVector
    ) {
        self.opacity = opacity
        self.scale = scale
        self.translation = translation
    }

    public static let visible = SettingsTransitionPresentation(
        opacity: 1,
        scale: 1,
        translation: .zero
    )

    public static let hidden = SettingsTransitionPresentation(
        opacity: 0,
        scale: SettingsMotionPolicy.standardHiddenScale,
        translation: .zero
    )
}

/// Settings 的克制动效策略。
///
/// 普通模式只使用极小缩放、最多几 points 的 source-biased 平移和淡入淡出，
/// 使用 ease-in/ease-out 而不是 spring，因此不会 bounce。Reduce Motion 时
/// 缩放与平移均固定为终点值，只保留短淡入淡出。
public struct SettingsMotionPolicy: Equatable, Sendable {
    public static let standardDuration: TimeInterval = 0.16
    public static let reducedFadeDuration: TimeInterval = 0.08
    public static let standardHiddenScale: CGFloat = 0.985

    public let reduceMotion: Bool
    public let duration: TimeInterval
    public let hiddenScale: CGFloat

    public var usesSpatialMotion: Bool {
        !reduceMotion
    }

    public init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        duration = reduceMotion ? Self.reducedFadeDuration : Self.standardDuration
        hiddenScale = reduceMotion ? 1 : Self.standardHiddenScale
    }

    /// 在过渡开始时读取一次系统 Reduce Motion 状态。
    @MainActor
    public static func live() -> SettingsMotionPolicy {
        SettingsMotionPolicy(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    public func presentation(
        for intent: SettingsTransitionIntent,
        sourceTranslation: SettingsTransitionVector = .zero
    ) -> SettingsTransitionPresentation {
        switch intent {
        case .present:
            return .visible
        case .dismiss:
            return SettingsTransitionPresentation(
                opacity: 0,
                scale: hiddenScale,
                translation: usesSpatialMotion ? sourceTranslation : .zero
            )
        }
    }
}

/// Settings source geometry 的纯计算。
public enum SettingsTransitionGeometry {
    /// Settings transition 只允许几 points 的 source bias，避免大幅飞入/飞出。
    public static let maximumSourceTranslation: CGFloat = 4

    /// `sourcePoint` 和 `windowFrame` 使用同一坐标系，产品调用方应传 screen coordinates。
    /// 返回从窗口中心朝 source point 的有界偏移；没有有效 source 时返回零。
    public static func sourceTranslation(
        in windowFrame: NSRect,
        from sourcePoint: NSPoint?,
        maximumDistance: CGFloat = Self.maximumSourceTranslation
    ) -> SettingsTransitionVector {
        guard let sourcePoint,
              windowFrame.width.isFinite,
              windowFrame.height.isFinite,
              sourcePoint.x.isFinite,
              sourcePoint.y.isFinite else {
            return .zero
        }

        let dx = sourcePoint.x - windowFrame.midX
        let dy = sourcePoint.y - windowFrame.midY
        let distance = hypot(dx, dy)
        guard distance.isFinite, distance > 0.001 else { return .zero }

        let limit = max(0, maximumDistance.isFinite ? maximumDistance : 0)
        let length = min(distance, limit)
        guard length > 0 else { return .zero }

        return SettingsTransitionVector(
            x: dx / distance * length,
            y: dy / distance * length
        )
    }
}

/// 纯生命周期状态机：每个新意图都会使旧 completion 失效。
struct SettingsTransitionLifecycle: Equatable {
    struct Token: Equatable, Sendable {
        let generation: UInt64
        let expectedState: SettingsTransitionState
        let terminalState: SettingsTransitionState
    }

    private(set) var state: SettingsTransitionState = .hidden
    private var generation: UInt64 = 0
    private var completedGeneration: UInt64?

    mutating func begin(_ intent: SettingsTransitionIntent) -> Token {
        generation &+= 1
        completedGeneration = nil

        let expectedState: SettingsTransitionState
        let terminalState: SettingsTransitionState
        switch intent {
        case .present:
            expectedState = .presenting
            terminalState = .visible
        case .dismiss:
            expectedState = .dismissing
            terminalState = .hidden
        }

        state = expectedState
        return Token(
            generation: generation,
            expectedState: expectedState,
            terminalState: terminalState
        )
    }

    @discardableResult
    mutating func complete(_ token: Token) -> Bool {
        guard token.generation == generation,
              token.expectedState == state,
              completedGeneration != token.generation else {
            return false
        }

        state = token.terminalState
        completedGeneration = token.generation
        return true
    }

    /// Native move/resize wins immediately. The current intent is finalized at
    /// its terminal state and all in-flight completions become stale.
    mutating func cancelForManualMove() -> SettingsTransitionState {
        generation &+= 1
        completedGeneration = nil

        switch state {
        case .presenting, .visible:
            state = .visible
        case .dismissing, .hidden:
            state = .hidden
        }
        return state
    }
}

/// Settings 专属的 AppKit transition controller。
///
/// 只对 `NSWindow.contentView` 的公开 backing layer 做视觉变换；不访问
/// titlebar 私有层，也不驱动 `NSWindow.frame`。因此原生移动、resize 和
/// traffic lights 保持 AppKit 语义。新的 present/dismiss 会从 layer 的
/// presentation 值继续，旧 completion 会被 generation 丢弃。
@MainActor
public final class SettingsTransitionCoordinator {
    private weak var window: NSWindow?
    private weak var surfaceLayer: CALayer?

    private var lifecycle = SettingsTransitionLifecycle()
    private var activeToken: SettingsTransitionLifecycle.Token?
    private var activeTarget: SettingsTransitionPresentation?
    private var activeCompletion: (() -> Void)?
    private var lastSourcePoint: NSPoint?

    // Narrow test seams for deterministically reproducing Core Animation's
    // completion behavior when an in-flight animation is removed.
    var testWillRemoveAnimations: (() -> Void)?
    var testDidInstallAnimationCompletion: ((@escaping () -> Void) -> Void)?

    private static let animationKey = "launchbetter.settings.transition"

    public init(window: NSWindow) {
        self.window = window
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            surfaceLayer = contentView.layer
        }
    }

    public var state: SettingsTransitionState {
        lifecycle.state
    }

    public var isTransitioning: Bool {
        lifecycle.state == .presenting || lifecycle.state == .dismissing
    }

    /// 当前可见 presentation；有 CA presentation layer 时优先读取它。
    public var presentation: SettingsTransitionPresentation {
        currentPresentation()
    }

    /// 从 gear source point 呈现 Settings。source point 使用 screen coordinates。
    public func present(
        from sourcePoint: NSPoint? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard let window else {
            completion?()
            return
        }

        let policy = SettingsMotionPolicy.live()
        if let sourcePoint {
            lastSourcePoint = sourcePoint
        }
        let sourceTranslation = policy.usesSpatialMotion
            ? SettingsTransitionGeometry.sourceTranslation(
                in: window.frame,
                from: sourcePoint ?? lastSourcePoint
            )
            : .zero

        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)

        // A completed dismissal leaves the layer at its hidden model value. For
        // a fresh presentation, establish that hidden value without animation;
        // an in-flight dismissal instead keeps its current presentation below.
        if lifecycle.state == .hidden {
            let hidden = policy.presentation(
                for: .dismiss,
                sourceTranslation: sourceTranslation
            )
            withoutAnimations { apply(hidden) }
        }

        let current = currentPresentation()
        let target = policy.presentation(for: .present)
        transition(
            to: .present,
            from: current,
            target: target,
            policy: policy,
            completion: completion
        )
    }

    /// 解散 Settings。未传 source point 时复用最近一次 gear point，但几何
    /// 始终从当前 `window.frame` 重新计算，不把窗口跳回原中心。
    public func dismiss(
        to sourcePoint: NSPoint? = nil,
        completion: (() -> Void)? = nil
    ) {
        guard let window else {
            completion?()
            return
        }

        guard lifecycle.state != .hidden else {
            completion?()
            return
        }

        if let sourcePoint {
            lastSourcePoint = sourcePoint
        }
        let policy = SettingsMotionPolicy.live()
        let sourceTranslation = policy.usesSpatialMotion
            ? SettingsTransitionGeometry.sourceTranslation(
                in: window.frame,
                from: sourcePoint ?? lastSourcePoint
            )
            : .zero
        let current = currentPresentation()
        let target = policy.presentation(
            for: .dismiss,
            sourceTranslation: sourceTranslation
        )
        transition(
            to: .dismiss,
            from: current,
            target: target,
            policy: policy,
            completion: completion
        )
    }

    /// Native window move/resize begins: stop the visual transition now and
    /// finalize its current intent before AppKit takes ownership of the window.
    public func cancelForManualMove() {
        guard activeToken != nil else {
            removeAnimations()
            if lifecycle.state == .visible {
                withoutAnimations { apply(.visible) }
            }
            return
        }

        let completion = activeCompletion
        let target = activeTarget
        activeToken = nil
        activeTarget = nil
        activeCompletion = nil
        removeAnimations()

        let finalState = lifecycle.cancelForManualMove()
        let terminal = finalState == .hidden
            ? (target ?? SettingsTransitionPresentation.hidden)
            : .visible
        withoutAnimations { apply(terminal) }
        completion?()
    }

    private func transition(
        to intent: SettingsTransitionIntent,
        from current: SettingsTransitionPresentation,
        target: SettingsTransitionPresentation,
        policy: SettingsMotionPolicy,
        completion: (() -> Void)?
    ) {
        let token = lifecycle.begin(intent)
        activeToken = token
        activeTarget = target
        activeCompletion = completion

        // Publish the new generation before removing the old animation:
        // Core Animation may synchronously run the removed transaction's
        // completion, which must already be stale at that point.
        removeAnimations()

        // Removing animations is allowed to re-enter transition handling. If
        // that happened, the nested transition owns the active state and the
        // outer transition must not install an animation for its stale token.
        guard activeToken == token else { return }

        guard let layer = surfaceLayer else {
            finish(generation: token.generation)
            return
        }

        let animationCompletion = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.finish(generation: token.generation)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(animationCompletion)
        testDidInstallAnimationCompletion?(animationCompletion)

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = current.opacity
        opacity.toValue = target.opacity
        opacity.duration = policy.duration
        opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = Self.transformValue(for: current)
        transform.toValue = Self.transformValue(for: target)
        transform.duration = policy.duration
        transform.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let group = CAAnimationGroup()
        group.animations = [opacity, transform]
        group.duration = policy.duration
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        apply(target)
        layer.add(group, forKey: Self.animationKey)
        CATransaction.commit()
    }

    private func finish(generation: UInt64) {
        guard let token = activeToken,
              token.generation == generation,
              lifecycle.complete(token) else {
            return
        }

        let completion = activeCompletion
        activeToken = nil
        activeTarget = nil
        activeCompletion = nil
        completion?()
    }

    private func currentPresentation() -> SettingsTransitionPresentation {
        guard let layer = surfaceLayer else { return .visible }
        let visibleLayer = layer.presentation() ?? layer
        let transform = CATransform3DGetAffineTransform(visibleLayer.transform)
        let xScale = hypot(transform.a, transform.b)
        let yScale = hypot(transform.c, transform.d)
        let scale = ((xScale + yScale) / 2).isFinite
            ? max(0.001, (xScale + yScale) / 2)
            : 1
        let x = transform.tx.isFinite ? transform.tx : 0
        let y = transform.ty.isFinite ? transform.ty : 0
        let opacity = visibleLayer.opacity.isFinite
            ? min(max(visibleLayer.opacity, 0), 1)
            : 1

        return SettingsTransitionPresentation(
            opacity: opacity,
            scale: scale,
            translation: SettingsTransitionVector(x: x, y: y)
        )
    }

    private func apply(_ presentation: SettingsTransitionPresentation) {
        guard let layer = surfaceLayer else { return }
        layer.opacity = presentation.opacity
        layer.transform = Self.transformValue(for: presentation)
    }

    private func removeAnimations() {
        testWillRemoveAnimations?()
        surfaceLayer?.removeAnimation(forKey: Self.animationKey)
    }

    private func withoutAnimations(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private static func transformValue(
        for presentation: SettingsTransitionPresentation
    ) -> CATransform3D {
        CATransform3DMakeAffineTransform(
            CGAffineTransform(
                a: presentation.scale,
                b: 0,
                c: 0,
                d: presentation.scale,
                tx: presentation.translation.x,
                ty: presentation.translation.y
            )
        )
    }
}
