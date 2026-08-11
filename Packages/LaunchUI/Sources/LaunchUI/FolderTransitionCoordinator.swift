import AppKit
import LaunchCore
import QuartzCore

/// Folder 专属的标量进度弹簧。
///
/// 这是一个小型、确定性的临界阻尼解：不依赖帧率，也不保存任何 UI 或
/// Store 状态。retarget 只改变目标，当前位置和速度保持连续。
struct MotionProgressSpring: Equatable {
    private(set) var currentProgress: CGFloat
    private(set) var velocity: CGFloat
    private(set) var targetProgress: CGFloat

    let angularFrequency: CGFloat

    init(
        progress: CGFloat = 0,
        velocity: CGFloat = 0,
        target: CGFloat = 0,
        angularFrequency: CGFloat = 18
    ) {
        self.currentProgress = Self.finite(progress, fallback: 0)
        self.velocity = Self.finite(velocity, fallback: 0)
        self.targetProgress = Self.clamped(target)
        let frequency = Self.finite(angularFrequency, fallback: 18)
        self.angularFrequency = max(0.001, frequency)
    }

    mutating func retarget(to target: CGFloat) {
        targetProgress = Self.clamped(target)
    }

    @discardableResult
    mutating func advance(by delta: TimeInterval) -> CGFloat {
        let seconds = delta.isFinite ? max(0, delta) : 0
        guard seconds > 0 else { return currentProgress }

        let dt = CGFloat(seconds)
        let displacement = currentProgress - targetProgress
        let accelerationTerm = velocity + angularFrequency * displacement
        let decay = CGFloat(exp(-Double(angularFrequency) * seconds))

        // Exact critically-damped solution for x'' + 2ωx' + ω²x = 0.
        let nextDisplacement = (displacement + accelerationTerm * dt) * decay
        let nextVelocity = (
            velocity - angularFrequency * accelerationTerm * dt
        ) * decay

        currentProgress = Self.finite(targetProgress + nextDisplacement, fallback: targetProgress)
        velocity = Self.finite(nextVelocity, fallback: 0)

        if isSettled {
            currentProgress = targetProgress
            velocity = 0
        }
        return currentProgress
    }

    var isSettled: Bool {
        abs(currentProgress - targetProgress) <= 0.0005
            && abs(velocity) <= 0.002
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(finite(value, fallback: 0), 0), 1)
    }

    private static func finite(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite ? value : fallback
    }
}

enum FolderTransitionIntent: Equatable {
    case open
    case close
}

/// Proxy 的完整可见 presentation。validity 中途失效时会原样捕获这个值，
/// 作为 fallback 路径的连续锚点。
struct FolderTransitionProxyPresentation: Equatable {
    let frame: CGRect
    let imageSize: CGSize
    let opacity: Float
    let imageOpacity: Float
    let cornerRadius: CGFloat
    let shadowOpacity: Float

    static let zero = FolderTransitionProxyPresentation(
        frame: .zero,
        imageSize: .zero,
        opacity: 0,
        imageOpacity: 0,
        cornerRadius: 0,
        shadowOpacity: 0
    )
}

/// 从主网格查询到的真实 Folder source。它只保留一次捕获的几何和内存中的
/// DragVisualRepresentation；有效性检查不触发布局、snapshot、Store 或 IO。
@MainActor
final class FolderTransitionSource {
    let folderID: FolderID
    let frameInContentView: CGRect
    let cornerRadius: CGFloat
    let representation: DragVisualRepresentation?

    private weak var cell: AppCellView?
    private let isCurrent: () -> Bool
    private(set) var isSuppressed = false

    init(
        folderID: FolderID,
        frameInContentView: CGRect,
        cornerRadius: CGFloat,
        representation: DragVisualRepresentation?,
        cell: AppCellView,
        isCurrent: @escaping () -> Bool
    ) {
        self.folderID = folderID
        self.frameInContentView = frameInContentView
        self.cornerRadius = max(0, cornerRadius)
        self.representation = representation
        self.cell = cell
        self.isCurrent = isCurrent
    }

    var isValid: Bool {
        guard let cell else { return false }
        return isCurrent() && cell.transitionSourceIdentity == folderID
    }

    func suppress() {
        guard let cell else { return }
        cell.setTransitionSourceSuppressed(true)
        isSuppressed = true
    }

    func restore() {
        guard isSuppressed else { return }
        cell?.setTransitionSourceSuppressed(false)
        isSuppressed = false
    }
}

/// FolderViewController 在 Auto Layout 落定后暴露的真实 target。过渡期间只
/// 改这些 layer 的 presentation 属性；target view 本身不被 reparent。
@MainActor
final class FolderTransitionTarget {
    let frameInContentView: CGRect
    let cornerRadius: CGFloat
    let baseShadowOpacity: Float

    private let dimLayer: CALayer
    private let cardLayer: CALayer
    private let materialLayer: CALayer
    private let contentLayers: [CALayer]
    private let isCurrent: () -> Bool

    init(
        frameInContentView: CGRect,
        cornerRadius: CGFloat,
        baseShadowOpacity: Float,
        dimLayer: CALayer,
        cardLayer: CALayer,
        materialLayer: CALayer,
        contentLayers: [CALayer],
        isCurrent: @escaping () -> Bool
    ) {
        self.frameInContentView = frameInContentView
        self.cornerRadius = max(0, cornerRadius)
        self.baseShadowOpacity = min(max(baseShadowOpacity, 0), 1)
        self.dimLayer = dimLayer
        self.cardLayer = cardLayer
        self.materialLayer = materialLayer
        self.contentLayers = contentLayers
        self.isCurrent = isCurrent
    }

    var isValid: Bool { isCurrent() }

    func prepareHidden() {
        apply(dimOpacity: 0, materialOpacity: 0, contentOpacity: 0)
    }

    func apply(dimOpacity: Float, materialOpacity: Float, contentOpacity: Float) {
        withoutActions {
            dimLayer.opacity = clamped(dimOpacity)
            cardLayer.opacity = clamped(materialOpacity)
            cardLayer.shadowOpacity = baseShadowOpacity * clamped(materialOpacity)
            materialLayer.opacity = clamped(materialOpacity)
            for layer in contentLayers {
                layer.opacity = clamped(contentOpacity)
            }
        }
    }

    func finishVisible() {
        apply(dimOpacity: 1, materialOpacity: 1, contentOpacity: 1)
    }

    func finishHidden() {
        apply(dimOpacity: 0, materialOpacity: 0, contentOpacity: 0)
    }

    private func clamped(_ value: Float) -> Float {
        min(max(value.isFinite ? value : 0, 0), 1)
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

@MainActor
private final class FolderTransitionProxy {
    let layer = CALayer()
    private let imageLayer = CALayer()
    private(set) var currentPresentation: FolderTransitionProxyPresentation = .zero
    private var isRemoved = false

    init(hostView: NSView, representation: DragVisualRepresentation?) {
        hostView.wantsLayer = true
        layer.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        layer.borderWidth = 1
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowRadius = 18
        layer.shadowOffset = NSSize(width: 0, height: -8)
        layer.masksToBounds = false
        layer.contentsScale = max(1, hostView.window?.backingScaleFactor ?? 2)

        imageLayer.contentsGravity = .resizeAspect
        imageLayer.masksToBounds = true
        imageLayer.contents = representation?.image
        imageLayer.contentsScale = representation?.rasterScale
            ?? layer.contentsScale
        layer.addSublayer(imageLayer)
        hostView.layer?.addSublayer(layer)
    }

    func apply(
        frame: CGRect,
        imageSize: CGSize,
        opacity: Float,
        imageOpacity: Float,
        cornerRadius: CGFloat,
        shadowOpacity: Float
    ) {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width >= 0, frame.height >= 0 else { return }
        let appliedOpacity = min(max(opacity.isFinite ? opacity : 0, 0), 1)
        let appliedImageOpacity = min(max(imageOpacity.isFinite ? imageOpacity : 0, 0), 1)
        let appliedCornerRadius = max(0, cornerRadius.isFinite ? cornerRadius : 0)
        let appliedShadowOpacity = min(
            max(shadowOpacity.isFinite ? shadowOpacity : 0, 0),
            1
        )
        let width = min(max(0, imageSize.width), frame.width)
        let height = min(max(0, imageSize.height), frame.height)
        currentPresentation = FolderTransitionProxyPresentation(
            frame: frame,
            imageSize: CGSize(width: width, height: height),
            opacity: appliedOpacity,
            imageOpacity: appliedImageOpacity,
            cornerRadius: appliedCornerRadius,
            shadowOpacity: appliedShadowOpacity
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame
        layer.opacity = appliedOpacity
        layer.cornerRadius = appliedCornerRadius
        layer.shadowOpacity = appliedShadowOpacity
        imageLayer.frame = CGRect(
            x: (frame.width - width) / 2,
            y: (frame.height - height) / 2,
            width: width,
            height: height
        )
        imageLayer.opacity = appliedImageOpacity
        imageLayer.cornerRadius = min(layer.cornerRadius, min(width, height) / 2)
        CATransaction.commit()
    }

    func apply(_ presentation: FolderTransitionProxyPresentation) {
        apply(
            frame: presentation.frame,
            imageSize: presentation.imageSize,
            opacity: presentation.opacity,
            imageOpacity: presentation.imageOpacity,
            cornerRadius: presentation.cornerRadius,
            shadowOpacity: presentation.shadowOpacity
        )
    }

    func remove() {
        guard !isRemoved else { return }
        isRemoved = true
        imageLayer.removeFromSuperlayer()
        layer.removeFromSuperlayer()
    }
}

/// Folder M3 的 feature-specific driver/coordinator。它只拥有临时 proxy、
/// display link 和 Folder 生命周期，不触碰 Store、Auto Layout 或 collection cell。
@MainActor
final class FolderTransitionCoordinator {
    private struct FallbackContinuityAnchor {
        let progress: CGFloat
        let presentation: FolderTransitionProxyPresentation
    }

    private weak var hostView: NSView?
    private let source: FolderTransitionSource?
    private let target: FolderTransitionTarget
    private let reduceMotion: Bool
    private let proxy: FolderTransitionProxy

    private var spring = MotionProgressSpring()
    private var intent: FolderTransitionIntent = .open
    private var generation: UInt64 = 0
    private var lastTimestamp: CFTimeInterval?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?
    private var closeCompletion: (() -> Void)?
    private var closeCompletionGeneration: UInt64?
    private var fallback = false
    private var fallbackContinuityAnchor: FallbackContinuityAnchor?
    private var hasStarted = false
    private var tornDown = false

    init(
        hostView: NSView,
        source: FolderTransitionSource?,
        target: FolderTransitionTarget,
        reduceMotion: Bool
    ) {
        self.hostView = hostView
        self.source = source
        self.target = target
        self.reduceMotion = reduceMotion
        self.proxy = FolderTransitionProxy(
            hostView: hostView,
            representation: source?.representation
        )
    }

    var currentProgress: CGFloat { spring.currentProgress }
    var currentVelocity: CGFloat { spring.velocity }
    var currentIntent: FolderTransitionIntent { intent }
    var transitionGeneration: UInt64 { generation }
    var proxyPresentationForTesting: FolderTransitionProxyPresentation {
        proxy.currentPresentation
    }

    /// 确定性测试 seam；生产路径仍由 display link 提供墙钟 delta。
    func advanceForTesting(by delta: TimeInterval) {
        guard !tornDown else { return }
        activateFallbackIfNeeded()
        advanceMotion(by: delta)
    }

    func startOpening() {
        guard !tornDown else { return }
        generation &+= 1
        intent = .open
        closeCompletion = nil
        closeCompletionGeneration = nil
        if !hasStarted {
            fallback = reduceMotion || !(source?.isValid ?? false) || !target.isValid
            fallbackContinuityAnchor = nil
            hasStarted = true
        } else {
            activateFallbackIfNeeded()
        }
        source?.suppress()
        target.prepareHidden()
        spring.retarget(to: 1)
        apply(progress: spring.currentProgress)
        startDisplayLinkIfNeeded()
    }

    func requestClose(completion: @escaping () -> Void) {
        guard !tornDown else {
            completion()
            return
        }
        generation &+= 1
        intent = .close
        closeCompletion = completion
        closeCompletionGeneration = generation
        activateFallbackIfNeeded()
        spring.retarget(to: 0)
        apply(progress: spring.currentProgress)
        startDisplayLinkIfNeeded()
    }

    /// 用于强制生命周期 teardown(Settings/Launcher hide)。不调用关闭 completion。
    func cancelAndTeardown() {
        guard !tornDown else { return }
        generation &+= 1
        closeCompletion = nil
        closeCompletionGeneration = nil
        stopDisplayLink()
        target.finishHidden()
        proxy.remove()
        source?.restore()
        tornDown = true
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        guard hostView?.window != nil else {
            // 无窗口时仍保持确定性状态；真实窗口挂载后由下一次 lifecycle 调用启动。
            return
        }
        let target = DisplayLinkTarget(owner: self)
        displayLinkTarget = target
        guard let link = hostView?.displayLink(
            target: target,
            selector: #selector(DisplayLinkTarget.tick(_:))
        ) else { return }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func displayTick(_ link: CADisplayLink) {
        guard !tornDown else {
            stopDisplayLink()
            return
        }
        let timestamp = link.timestamp
        let delta: TimeInterval
        if let lastTimestamp {
            delta = min(max(timestamp - lastTimestamp, 0), 0.1)
        } else {
            delta = 0
        }
        lastTimestamp = timestamp

        activateFallbackIfNeeded()

        advanceMotion(by: delta)
    }

    private func advanceMotion(by delta: TimeInterval) {
        let progress = spring.advance(by: delta)
        apply(progress: progress)
        guard spring.isSettled else { return }

        stopDisplayLink()
        if spring.targetProgress >= 1 {
            target.finishVisible()
            proxy.apply(
                frame: target.frameInContentView,
                imageSize: .zero,
                opacity: 0,
                imageOpacity: 0,
                cornerRadius: target.cornerRadius,
                shadowOpacity: 0
            )
        } else {
            finishClose()
        }
    }

    private func apply(progress: CGFloat) {
        let p = min(max(progress.isFinite ? progress : 0, 0), 1)
        let materialOpacity = smoothStep((p - 0.12) / 0.42)
        let contentOpacity = smoothStep((p - 0.56) / 0.44)
        let proxyOpacity = 1 - smoothStep((p - 0.70) / 0.30)
        let imageOpacity = fallback || reduceMotion
            ? 0
            : 1 - smoothStep((p - 0.18) / 0.60)
        let dimOpacity = p

        let frame: CGRect
        let cornerRadius: CGFloat
        if reduceMotion {
            frame = scaled(target.frameInContentView, by: 0.985 + 0.015 * p)
            cornerRadius = target.cornerRadius
        } else {
            let from = fallback
                ? scaled(target.frameInContentView, by: 0.82)
                : source?.frameInContentView ?? scaled(target.frameInContentView, by: 0.82)
            frame = interpolate(from, target.frameInContentView, amount: p)
            cornerRadius = interpolate(
                fallback ? target.cornerRadius * 0.85 : source?.cornerRadius ?? target.cornerRadius,
                target.cornerRadius,
                amount: p
            )
        }

        let sourceSize = source?.frameInContentView.size ?? .zero
        let targetImageSize = source?.representation?.logicalSize ?? sourceSize
        let maxTargetSide = min(target.frameInContentView.width, target.frameInContentView.height) * 0.22
        let endSide = min(
            max(0, max(targetImageSize.width, targetImageSize.height)),
            max(0, maxTargetSide)
        )
        let startImageSize = sourceSize
        let endImageSize = CGSize(width: endSide, height: endSide)
        let imageSize = CGSize(
            width: interpolate(startImageSize.width, endImageSize.width, amount: p),
            height: interpolate(startImageSize.height, endImageSize.height, amount: p)
        )

        target.apply(
            dimOpacity: Float(dimOpacity),
            materialOpacity: Float(materialOpacity),
            contentOpacity: Float(contentOpacity)
        )
        let calculatedPresentation = FolderTransitionProxyPresentation(
            frame: frame,
            imageSize: imageSize,
            opacity: Float(proxyOpacity),
            imageOpacity: Float(imageOpacity),
            cornerRadius: cornerRadius,
            shadowOpacity: Float(0.30 * proxyOpacity)
        )
        if fallback, let fallbackContinuityAnchor {
            proxy.apply(
                continuousFallbackPresentation(
                    progress: p,
                    anchor: fallbackContinuityAnchor
                )
            )
        } else {
            proxy.apply(calculatedPresentation)
        }
    }

    /// validity 的第一次失效只切换一次路径。锚点取切换前已经写入 layer 的
    /// current presentation，因此在同一 progress 重新 apply 时所有可见标量相等。
    private func activateFallbackIfNeeded() {
        guard !fallback,
              !(source?.isValid ?? false) || !target.isValid else { return }
        fallbackContinuityAnchor = FallbackContinuityAnchor(
            progress: clampedProgress(spring.currentProgress),
            presentation: proxy.currentPresentation
        )
        fallback = true
    }

    /// 同一条 progress→presentation 分段路径同时服务 close 与 reopen：
    /// p=anchor 时严格等于捕获值，向 0/1 两端移动时分别趋向 centered fallback
    /// 与真实 target，retarget 不会更换路径或重置几何。
    private func continuousFallbackPresentation(
        progress: CGFloat,
        anchor: FallbackContinuityAnchor
    ) -> FolderTransitionProxyPresentation {
        let p = clampedProgress(progress)
        let anchorProgress = clampedProgress(anchor.progress)
        if p == anchorProgress {
            return anchor.presentation
        }
        if p < anchorProgress {
            let amount = anchorProgress > 0 ? p / anchorProgress : 0
            return interpolate(
                fallbackCloseEndpoint(),
                anchor.presentation,
                amount: amount
            )
        }
        let remaining = 1 - anchorProgress
        let amount = remaining > 0 ? (p - anchorProgress) / remaining : 1
        return interpolate(
            anchor.presentation,
            fallbackOpenEndpoint(),
            amount: amount
        )
    }

    private func fallbackCloseEndpoint() -> FolderTransitionProxyPresentation {
        FolderTransitionProxyPresentation(
            frame: scaled(target.frameInContentView, by: 0.82),
            imageSize: .zero,
            opacity: 1,
            imageOpacity: 0,
            cornerRadius: target.cornerRadius * 0.85,
            shadowOpacity: 0.30
        )
    }

    private func fallbackOpenEndpoint() -> FolderTransitionProxyPresentation {
        FolderTransitionProxyPresentation(
            frame: target.frameInContentView,
            imageSize: .zero,
            opacity: 0,
            imageOpacity: 0,
            cornerRadius: target.cornerRadius,
            shadowOpacity: 0
        )
    }

    private func interpolate(
        _ from: FolderTransitionProxyPresentation,
        _ to: FolderTransitionProxyPresentation,
        amount: CGFloat
    ) -> FolderTransitionProxyPresentation {
        let t = clampedProgress(amount)
        return FolderTransitionProxyPresentation(
            frame: interpolate(from.frame, to.frame, amount: t),
            imageSize: CGSize(
                width: interpolate(from.imageSize.width, to.imageSize.width, amount: t),
                height: interpolate(from.imageSize.height, to.imageSize.height, amount: t)
            ),
            opacity: Float(interpolate(CGFloat(from.opacity), CGFloat(to.opacity), amount: t)),
            imageOpacity: Float(
                interpolate(CGFloat(from.imageOpacity), CGFloat(to.imageOpacity), amount: t)
            ),
            cornerRadius: interpolate(from.cornerRadius, to.cornerRadius, amount: t),
            shadowOpacity: Float(
                interpolate(CGFloat(from.shadowOpacity), CGFloat(to.shadowOpacity), amount: t)
            )
        )
    }

    private func clampedProgress(_ value: CGFloat) -> CGFloat {
        min(max(value.isFinite ? value : 0, 0), 1)
    }

    private func finishClose() {
        guard intent == .close, !tornDown,
              closeCompletionGeneration == generation else { return }
        let completion = closeCompletion
        closeCompletion = nil
        closeCompletionGeneration = nil
        target.finishHidden()
        proxy.remove()
        source?.restore()
        tornDown = true
        completion?()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        lastTimestamp = nil
    }

    private func smoothStep(_ value: CGFloat) -> CGFloat {
        let t = min(max(value.isFinite ? value : 0, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func interpolate(_ from: CGFloat, _ to: CGFloat, amount: CGFloat) -> CGFloat {
        from + (to - from) * amount
    }

    private func interpolate(_ from: CGRect, _ to: CGRect, amount: CGFloat) -> CGRect {
        CGRect(
            x: interpolate(from.origin.x, to.origin.x, amount: amount),
            y: interpolate(from.origin.y, to.origin.y, amount: amount),
            width: interpolate(from.width, to.width, amount: amount),
            height: interpolate(from.height, to.height, amount: amount)
        )
    }

    private func scaled(_ rect: CGRect, by scale: CGFloat) -> CGRect {
        let width = rect.width * scale
        let height = rect.height * scale
        return CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    @MainActor
    final class DisplayLinkTarget: NSObject {
        weak var owner: FolderTransitionCoordinator?

        init(owner: FolderTransitionCoordinator?) {
            self.owner = owner
        }

        @objc func tick(_ link: CADisplayLink) {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.displayTick(link)
        }

        /// Deterministic seam for the orphan branch.
        @discardableResult
        func tickForTesting(invalidate: () -> Void) -> Bool {
            guard owner == nil else { return false }
            invalidate()
            return true
        }
    }
}
