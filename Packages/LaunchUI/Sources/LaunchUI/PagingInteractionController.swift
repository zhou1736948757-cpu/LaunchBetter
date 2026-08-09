import AppKit
import Foundation
import LaunchCore
import QuartzCore

/// 分页交互控制器(v0.1.6 PART A): 唯一手势/动画状态持有者。
///
/// 职责:
/// - NSEvent → 状态更新(axis lock / displacement / velocity EMA / latest desired)
/// - momentum 全拦截, 0 位移 0 snap
/// - CADisplayLink = 唯一 offset writer(每 frame 最多一次 clip.scroll)
/// - SETTLING 经 PageSnapAnimator(time-based spring), 可被新手势无缝打断
/// - 一次手势最多一页; 外边缘 rubber band; 不做位置低通滤波
///
/// 所有 UI 状态(phase/displacement/velocity/counts)都在本层, 不进 LauncherStore(§62)。
@MainActor
final class PagingInteractionController {
    enum Phase {
        case idle
        case tracking
        case settling
    }

    // 数据访问(由 GridViewController 注入, 避免反向依赖)
    var onReadCurrentOffset: () -> CGFloat = { 0 }
    var onReadPageWidth: () -> CGFloat = { 0 }
    var onReadPageCount: () -> Int = { 1 }
    /// 唯一 offset writer: 真正执行 clip.scroll。
    var onScroll: (CGFloat) -> Void = { _ in }
    /// settle 目标页确定时回调(更新 currentPage / page dots)。
    var onSettleTargetPage: (Int) -> Void = { _ in }
    /// settle 收敛完成回调。
    var onSettleComplete: () -> Void = {}

    private(set) var phase: Phase = .idle

    private var axisLock = PagingAxisLock()
    private var velocity = PagingVelocityEstimator()
    private var displacement: CGFloat = 0
    private var baseOffset: CGFloat = 0
    private var latestDesiredOffset: CGFloat = 0
    private var lastAppliedOffset: CGFloat = 0

    private var displayLink: CADisplayLink?
    private let animator = PageSnapAnimator()

    // 搜索模式: 禁用分页交互。
    var isEnabled = true

    /// 创建 DisplayLink 所绑定的视图(macOS 14+ NSView.displayLink)。
    weak var linkView: NSView?

    // 诊断计数(§63)
    private(set) var inputEventCount = 0
    private(set) var displayFrameCount = 0
    private(set) var scrollWriteCount = 0
    private(set) var settlingSkippedWriteCount = 0
    private(set) var interruptionCount = 0
    private(set) var settleCount = 0
    private(set) var lastGestureDuration: CFTimeInterval = 0
    private(set) var lastSettleDuration: CFTimeInterval = 0
    private var gestureStartTime: CFTimeInterval = 0
    private var settleStartTime: CFTimeInterval = 0

    init() {
        animator.onFrame = { [weak self] position, settled in
            guard let self else { return }
            self.applyScroll(position, allowSkip: true)
            if settled {
                self.finishSettle()
            }
        }
        animator.onSettled = { [weak self] in
            self?.onSettleComplete()
        }
    }

    func resetCounters() {
        inputEventCount = 0
        displayFrameCount = 0
        scrollWriteCount = 0
        settlingSkippedWriteCount = 0
        interruptionCount = 0
        settleCount = 0
        lastGestureDuration = 0
        lastSettleDuration = 0
    }

    func diagnostics() -> String {
        "phase=\(phase) input=\(inputEventCount) frames=\(displayFrameCount) scroll=\(scrollWriteCount) skipped=\(settlingSkippedWriteCount) interrupts=\(interruptionCount) settles=\(settleCount) gestureMs=\(Int(lastGestureDuration * 1000)) settleMs=\(Int(lastSettleDuration * 1000))"
    }

    // MARK: - 事件入口

    /// 处理 scrollWheel 事件。返回 true = 已处理(不再交给系统滚动)。
    func handleWheel(_ event: NSEvent) -> Bool {
        guard isEnabled else { return false }

        // momentum: 全拦截, 0 位移 0 snap 0 重结算(§20);
        // 若同事件同时携带 ended/cancelled, 同步结束交互生命周期(评审 m1)
        if event.momentumPhase != [] {
            if event.phase == .ended || event.phase == .cancelled {
                endGesture()
            }
            return true
        }

        switch event.phase {
        case .began:
            beginGesture()
        case .ended, .cancelled:
            endGesture()
            return true
        default:
            break
        }

        // 触控板 precise delta(§5): 像素单位, 含系统滚动方向语义(§6, 不手工反转)
        if event.hasPreciseScrollingDeltas {
            feedTracking(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            return true
        }

        // 非 precise(鼠标滚轮): discrete paging(§31), 动画走同一 snap animator
        feedDiscrete(deltaY: event.scrollingDeltaY)
        return true
    }

    /// Deterministic diagnostic entry after NSEvent normalization. This keeps the
    /// probe focused on axis lock, target resolution, animation, and page writes.
    func probeGesture(deltaXs: [CGFloat]) {
        resetCounters()
        beginGesture()
        for deltaX in deltaXs {
            feedTracking(deltaX: deltaX, deltaY: 0)
        }
        endGesture()
    }

    // MARK: - 手势生命周期

    private func beginGesture() {
        if phase == .settling {
            // 打断旧 settle: 从当前实际位置重新跟手, 视觉 discontinuity ≈ 0(§29)
            animator.cancel()
            interruptionCount += 1
        }
        axisLock.began()
        velocity.reset()
        displacement = 0
        baseOffset = onReadCurrentOffset()
        lastAppliedOffset = baseOffset
        latestDesiredOffset = baseOffset
        gestureStartTime = ProcessInfo.processInfo.systemUptime
        phase = .tracking
        ensureDisplayLink()
    }

    private func feedTracking(deltaX: CGFloat, deltaY: CGFloat) {
        inputEventCount += 1
        guard phase == .tracking else { return }
        guard axisLock.accumulate(deltaX: deltaX, deltaY: deltaY) else {
            return
        }
        // 一次手势最多一页(§17); 跟手位移应用灵敏度系数(§16, v0.1.7 0.85)
        let maxDisp = onReadPageWidth() * PagingTuning.maxGestureDisplacementPages
        let applied = deltaX * PagingTuning.followSensitivity
        displacement = min(max(displacement + applied, -maxDisp), maxDisp)
        // 方向: 手指左滑(deltaX 负, 自然滚动)→ 内容左移 → offset 增加
        latestDesiredOffset = baseOffset - displacement
        _ = velocity.update(position: -displacement, timestamp: CACurrentMediaTime())
        ensureDisplayLink()
    }

    private func feedDiscrete(deltaY: CGFloat) {
        inputEventCount += 1
        guard abs(deltaY) > 0.5 else { return }
        let current = onReadCurrentOffset()
        let pageWidth = onReadPageWidth()
        let pageCount = onReadPageCount()
        let currentPage = min(max(0, Int((current / max(1, pageWidth)).rounded())), max(0, pageCount - 1))
        let targetPage = min(max(0, currentPage + (deltaY < 0 ? 1 : -1)), max(0, pageCount - 1))
        startSettle(toPage: targetPage, fromOffset: current, velocity: 0)
    }

    private func endGesture() {
        guard phase == .tracking else { return }
        // 解析目标页: 位移 + 速度(§21-22)
        let pageWidth = onReadPageWidth()
        let pageCount = onReadPageCount()
        let currentPage = min(max(0, Int((baseOffset / max(1, pageWidth)).rounded())), max(0, pageCount - 1))
        let targetPage = PagingTargetResolver.resolve(
            currentPage: currentPage,
            pageCount: pageCount,
            pageWidth: pageWidth,
            displacement: displacement,
            releaseVelocity: velocity.estimatedVelocity
        )
        lastGestureDuration = ProcessInfo.processInfo.systemUptime - gestureStartTime
        startSettle(toPage: targetPage, fromOffset: onReadCurrentOffset(), velocity: velocity.estimatedVelocity)
    }

    /// 启动一次 settle(目标页动画), 供键盘翻页 / 鼠标滚轮 / 手势松手共用(§31)。
    func startSettle(toPage page: Int, fromOffset: CGFloat? = nil, velocity: CGFloat = 0) {
        let pageCount = onReadPageCount()
        let targetPage = min(max(0, page), max(0, pageCount - 1))
        let targetOffset = CGFloat(targetPage) * onReadPageWidth()
        onSettleTargetPage(targetPage)
        animator.start(
            startPosition: fromOffset ?? onReadCurrentOffset(),
            target: targetOffset,
            velocity: velocity
        )
        settleCount += 1
        settleStartTime = ProcessInfo.processInfo.systemUptime
        phase = .settling
        ensureDisplayLink()
    }

    /// 立即(无动画)跳到某页, 并停交互(初始化 / 测试)。
    func jumpTo(page: Int) {
        animator.cancel()
        phase = .idle
        let target = CGFloat(page) * onReadPageWidth()
        onScroll(target)
        lastAppliedOffset = target
        stopDisplayLinkIfIdle()
    }

    private func finishSettle() {
        lastSettleDuration = ProcessInfo.processInfo.systemUptime - settleStartTime
        phase = .idle
        stopDisplayLinkIfIdle()
    }

    // MARK: - DisplayLink(唯一 offset writer)

    private func ensureDisplayLink() {
        guard displayLink == nil, let view = linkView else { return }
        // macOS 14+ API: NSView.displayLink(target:selector:), 随视图刷新驱动
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLinkIfIdle() {
        guard phase == .idle else { return }
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        processDisplayFrame()
    }

    /// Diagnostic fallback for processes where AppKit does not schedule a view
    /// display link. Returns true once the real animator reaches idle.
    func probeDisplayFrame() -> Bool {
        processDisplayFrame()
        return phase == .idle
    }

    private func processDisplayFrame() {
        displayFrameCount += 1
        switch phase {
        case .tracking:
            // TRACKING: 直接应用最新目标, 不做 epsilon skip(§15, 慢速也保持直接操作)
            applyScroll(latestDesiredOffset, allowSkip: false)
        case .settling:
            _ = animator.tick()
        case .idle:
            stopDisplayLinkIfIdle()
        }
    }

    private func applyScroll(_ offset: CGFloat, allowSkip: Bool) {
        let pageWidth = onReadPageWidth()
        let pageCount = onReadPageCount()
        let maxOffset = max(0, CGFloat(pageCount) * pageWidth - pageWidth)
        // rubber band 仅作用于边缘(§18); 正常范围 direct mapping
        let clamped = PagingRubberBand.clamp(offset, minX: 0, maxX: maxOffset)
        if allowSkip, abs(clamped - lastAppliedOffset) < PagingTuning.positionTolerance {
            settlingSkippedWriteCount += 1
            return
        }
        onScroll(clamped)
        lastAppliedOffset = clamped
        scrollWriteCount += 1
    }
}
