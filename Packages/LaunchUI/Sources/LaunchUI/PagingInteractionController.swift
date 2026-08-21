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

    /// E13 遥测开关(默认 false, 零开销路径不变: 仅一次布尔判断)。
    var telemetryEnabled = false

    /// PA4: 逐事件 trace(默认 false; 仅 `--pagingeventtrace` 时开启)。
    /// 开启时每事件记录到共享 `PagingTraceLog`, 诊断用途不参与行为。
    var traceEnabled = false

    private var axisLock = PagingAxisLock()
    private var velocity = PagingVelocityEstimator()
    private var displacement: CGFloat = 0
    private var baseOffset: CGFloat = 0
    private var latestDesiredOffset: CGFloat = 0
    private var lastAppliedOffset: CGFloat = 0

    /// PA4 根因修复: 当前 settle 的目标页(经 clamp 后)。settle 启动时记录,
    /// 收敛/打断/跳转/禁用时清理。
    private var settleTargetPage: Int?
    /// PA4 根因修复: beginGesture 打断在途 settle 时暂存的被打断目标页。
    /// 新手势未锁定水平(垂直/微动)而走 finishTrackingWithoutSettle 时, 用它
    /// 重启 settle 回到原目标, 防止停在页面中间。
    private var interruptedSettleTarget: Int?

    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?
    private let animator = PageSnapAnimator()

    // 搜索模式: 禁用分页交互。禁用时中断在途手势/动画并停止 display link(§C4 停止路径),
    // 防止 display link 在搜索模式下持续驱动, 无残留状态。
    var isEnabled = true {
        didSet {
            guard !isEnabled else { return }
            animator.cancel()
            phase = .idle
            interruptedSettleTarget = nil
            settleTargetPage = nil
            stopDisplayLinkIfIdle()
            trace("disable isEnabled=false")
        }
    }

    /// 诊断/测试: display link 当前是否活动(§C4 生命周期验证)。
    var isDisplayLinkActive: Bool { displayLink != nil }

    /// PA4 探针: 当前 phase 描述(idle/tracking/settling)。
    var phaseDescription: String { "\(phase)" }

    /// PA4 探针: 最后一次实际写入的 clip offset。
    var currentAppliedOffset: CGFloat { lastAppliedOffset }

    /// PA4 测试/诊断观察: 当前 settle 目标页。
    var settleTargetPageForTest: Int? { settleTargetPage }

    /// PA4 测试/诊断观察: 被打断 settle 目标页。
    var interruptedSettleTargetForTest: Int? { interruptedSettleTarget }

    /// 显式生命周期收尾；可安全重复调用。
    func shutdown() {
        animator.cancel()
        phase = .idle
        interruptedSettleTarget = nil
        settleTargetPage = nil
        stopDisplayLink()
        trace("shutdown")
    }

    /// 创建 DisplayLink 所绑定的视图(macOS 14+ NSView.displayLink)。
    weak var linkView: NSView?

    // MARK: - E13 真机帧耗时遥测(仅 telemetryEnabled 时启用)

    /// 环形缓冲容量: 单次手势远超 512 帧时覆盖最旧样本。
    private static let telemetryCapacity = 512
    /// 相邻 displayTick 的 `CACurrentMediaTime()` 间隔(秒)。
    private var telemetryIntervals = [CFTimeInterval](
        repeating: 0,
        count: PagingInteractionController.telemetryCapacity
    )
    /// 最旧样本下标(环形缓冲满后推进)。
    private var telemetryStart = 0
    /// 当前手势有效样本数。
    private var telemetryCount = 0
    /// 上一次 displayTick 时间戳; 0 = 无前帧(手势起点)。
    private var lastDisplayTickTime: CFTimeInterval = 0

    /// 一次手势结束后, 把当前环形缓冲写成一行追加到 `/tmp/lb-paging-telemetry.log`:
    /// 帧数、avg/p95/max(ms)、phase。写后清空缓冲。
    ///
    /// 排序/格式化/文件 IO 全部延后到下一个 runloop hop: 本函数会在 settle
    /// 收敛帧(最后一个 animator.onFrame)内被调用, 同步做这些事会污染被测的
    /// 帧间隔本身。样本数组在此同步拷出(O(n) memcpy), 随后立即复位缓冲,
    /// 保证紧接的新手势从空缓冲开始且不丢样本。
    private func flushTelemetry(phase: String) {
        guard telemetryEnabled, telemetryCount > 0 else { return }
        let samples = (0..<telemetryCount).map {
            telemetryIntervals[(telemetryStart + $0) % Self.telemetryCapacity]
        }
        resetTelemetry()
        DispatchQueue.main.async { [weak self] in
            self?.writeTelemetryLine(samples: samples, phase: phase)
        }
    }

    /// 遥测统计与落盘(仅在 runloop hop 后执行, 不在任何帧预算内)。
    private func writeTelemetryLine(samples: [CFTimeInterval], phase: String) {
        let sorted = samples.sorted()
        let avgMs = samples.reduce(0, +) / Double(samples.count) * 1000
        let p95Index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1))
        let line = "telemetry frames=\(samples.count) "
            + "avgMs=\(String(format: "%.2f", avgMs)) "
            + "p95Ms=\(String(format: "%.2f", sorted[p95Index] * 1000)) "
            + "maxMs=\(String(format: "%.2f", (sorted.last ?? 0) * 1000)) "
            + "phase=\(phase)"
        appendTelemetryLine(line)
    }

    /// O(1) 环形缓冲追加。
    private func recordTelemetryInterval() {
        let now = CACurrentMediaTime()
        guard lastDisplayTickTime > 0 else {
            lastDisplayTickTime = now
            return
        }
        let interval = now - lastDisplayTickTime
        lastDisplayTickTime = now
        guard interval >= 0, interval.isFinite else { return }
        let index = (telemetryStart + telemetryCount) % Self.telemetryCapacity
        telemetryIntervals[index] = interval
        if telemetryCount < Self.telemetryCapacity {
            telemetryCount += 1
        } else {
            telemetryStart = (telemetryStart + 1) % Self.telemetryCapacity
        }
    }

    private func resetTelemetry() {
        telemetryStart = 0
        telemetryCount = 0
        lastDisplayTickTime = 0
    }

    /// 追加一行到 /tmp/lb-paging-telemetry.log(不存在则创建)。诊断用途,
    /// 每次手势一次写, 非热路径。
    private func appendTelemetryLine(_ line: String) {
        let path = "/tmp/lb-paging-telemetry.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// 诊断计数(§63)
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
            // 收敛帧必须无条件写入 target；否则 target 与上一帧相差
            // <0.5pt 时会被 epsilon skip，留下不可见但真实的残余偏移。
            self.applyScroll(position, allowSkip: !settled)
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

    /// PA4 trace 辅助: 汇总当前状态一行(调用方负责拼事件信息)。
    ///
    /// @autoclosure: traceEnabled 关闭时实参(含 NSEvent phase 描述、clip bounds
    /// 读取)完全不求值——scrollWheel 可达 120-240 事件/秒, 每事件的字符串
    /// 构建是输入热路径上的稳定分配源。
    private func trace(_ detail: @autoclosure () -> String) {
        guard traceEnabled else { return }
        let detail = detail()
        let offset = onReadCurrentOffset()
        let pageCount = onReadPageCount()
        let pageWidth = onReadPageWidth()
        PagingTraceLog.record(
            "paging \(detail) phase=\(phase) base=\(Int(baseOffset)) "
                + "desired=\(Int(latestDesiredOffset)) clip=\(Int(offset)) "
                + "settleTarget=\(settleTargetPage.map(String.init) ?? "-") "
                + "interrupted=\(interruptedSettleTarget.map(String.init) ?? "-") "
                + "animatorTarget=\(animator.currentTarget.map { Int($0) }.map(String.init) ?? "-") "
                + "link=\(isDisplayLinkActive ? 1 : 0) pageWidth=\(Int(pageWidth)) pageCount=\(pageCount)"
        )
    }

    /// 处理 scrollWheel 事件。返回 true = 已处理(不再交给系统滚动)。
    func handleWheel(_ event: NSEvent) -> Bool {
        trace(
            "event phase=\(event.phase) momentum=\(event.momentumPhase) "
                + "dx=\(Int(event.scrollingDeltaX)) dy=\(Int(event.scrollingDeltaY))"
        )
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
    func probeGesture(deltaXs: [CGFloat], deltaYs: [CGFloat] = []) {
        resetCounters()
        beginGesture()
        for (index, deltaX) in deltaXs.enumerated() {
            let deltaY = deltaYs.indices.contains(index) ? deltaYs[index] : 0
            feedTracking(deltaX: deltaX, deltaY: deltaY)
        }
        endGesture()
    }

    // MARK: - 手势生命周期

    private func beginGesture() {
        if phase == .settling {
            // 打断旧 settle: 从当前实际位置重新跟手, 视觉 discontinuity ≈ 0(§29)
            animator.cancel()
            interruptionCount += 1
            // PA4 根因修复: 记录被打断 settle 的目标页。若新手势从未锁定水平
            // 位移(垂直/微动), endGesture 走 finishTrackingWithoutSettle 时
            // 据此重启 settle, 避免停在中间偏移。
            interruptedSettleTarget = settleTargetPage
            trace("begin interruptSettle target=\(settleTargetPage.map(String.init) ?? "-")")
            // E13: 被打断的 settle 也是一次手势结束, 收掉其缓冲。
            flushTelemetry(phase: "settling")
        }
        // 未确认水平轴之前不需要 display link；若这里打断了旧 settle，
        // 也先移除旧 link，待新的水平位移真正到来时再创建。
        stopDisplayLink()
        axisLock.began()
        velocity.reset()
        displacement = 0
        baseOffset = onReadCurrentOffset()
        lastAppliedOffset = baseOffset
        latestDesiredOffset = baseOffset
        gestureStartTime = ProcessInfo.processInfo.systemUptime
        resetTelemetry()
        phase = .tracking
    }

    private func feedTracking(deltaX: CGFloat, deltaY: CGFloat) {
        inputEventCount += 1
        guard phase == .tracking else { return }
        guard axisLock.accumulate(deltaX: deltaX, deltaY: deltaY) else {
            return
        }
        let pageWidth = onReadPageWidth()
        guard pageWidth > 0 else { return }
        // 一次手势最多一页(§17); 跟手位移应用灵敏度系数(§16, v0.1.7 0.85)
        let maxDisp = pageWidth * PagingTuning.maxGestureDisplacementPages
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
        lastGestureDuration = ProcessInfo.processInfo.systemUptime - gestureStartTime
        guard axisLock.isHorizontal, displacement != 0 else {
            finishTrackingWithoutSettle()
            return
        }
        // 解析目标页: 位移 + 速度(§21-22)
        let pageWidth = onReadPageWidth()
        let pageCount = onReadPageCount()
        let currentPage = min(max(0, Int((baseOffset / max(1, pageWidth)).rounded())), max(0, pageCount - 1))
        // velocity 在跟手阶段记录的是 offset 轴速度(offset = base - displacement)，
        // 而 resolver 的 releaseVelocity 必须与 displacement 同向；settle 仍使用
        // offset 轴速度，保持既有 spring 方向与动量语义。
        let offsetVelocity = velocity.estimatedVelocity
        let targetPage = PagingTargetResolver.resolve(
            currentPage: currentPage,
            pageCount: pageCount,
            pageWidth: pageWidth,
            displacement: displacement,
            releaseVelocity: -offsetVelocity
        )
        trace("end horizontal displacement=\(Int(displacement)) target=\(targetPage)")
        startSettle(toPage: targetPage, fromOffset: onReadCurrentOffset(), velocity: offsetVelocity)
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
        // PA4: 记录本次 settle 目标(重 clamp 后); 新 settle 即新意图,
        // 清除被打断目标(重启 settle / 正常手势都走这里)。
        settleTargetPage = targetPage
        interruptedSettleTarget = nil
        settleCount += 1
        settleStartTime = ProcessInfo.processInfo.systemUptime
        phase = .settling
        ensureDisplayLink()
        trace("settleStart target=\(targetPage) start=\(Int(fromOffset ?? onReadCurrentOffset())) v=\(Int(velocity))")
    }

    /// 立即(无动画)跳到某页, 并停交互(初始化 / 测试)。
    func jumpTo(page: Int) {
        animator.cancel()
        stopDisplayLink()
        phase = .idle
        // PA4: jump 是权威目标, 清掉任何待重启目标。
        interruptedSettleTarget = nil
        settleTargetPage = nil
        let pageWidth = onReadPageWidth()
        let pageCount = onReadPageCount()
        let targetPage = min(max(0, page), max(0, pageCount - 1))
        let target = CGFloat(targetPage) * pageWidth
        // jump 也必须经过统一写入路径, 禁止绕过 clamp/计数直接调用 onScroll。
        applyScroll(target, allowSkip: false)
        trace("jumpTo target=\(targetPage)")
    }

    private func finishSettle() {
        lastSettleDuration = ProcessInfo.processInfo.systemUptime - settleStartTime
        settleTargetPage = nil
        // E13: settle 收敛 = 手势结束, 收掉本手势缓冲(phase 置 idle 前记录)。
        flushTelemetry(phase: "settling")
        trace("settleEnd clip=\(Int(onReadCurrentOffset()))")
        phase = .idle
        stopDisplayLinkIfIdle()
    }

    private func finishTrackingWithoutSettle() {
        // PA4 根因修复: 新手势未锁定水平位移就结束时, 若它打断了在途 settle,
        // 重启 settle 回到被打断的目标(重 clamp), 而不是停在中间偏移。
        // 覆盖两条路径: 纯垂直手势 + 零位移水平手势(axisLock 水平但 displacement == 0)。
        if let target = interruptedSettleTarget {
            trace("finishWithoutSettle resumeSettle target=\(target)")
            axisLock.ended()
            velocity.reset()
            displacement = 0
            startSettle(toPage: target)
            return
        }
        phase = .idle
        axisLock.ended()
        velocity.reset()
        displacement = 0
        // E13: 无 settle 的手势结束, 收掉 tracking 段缓冲。
        flushTelemetry(phase: "tracking")
        trace("finishWithoutSettle idle")
        stopDisplayLinkIfIdle()
    }

    // MARK: - DisplayLink(唯一 offset writer)

    private func ensureDisplayLink() {
        guard displayLink == nil, let view = linkView else { return }
        // macOS 14+ API: NSView.displayLink(target:selector:), 随视图刷新驱动
        let target = DisplayLinkTarget(owner: self)
        let link = view.displayLink(
            target: target,
            selector: #selector(DisplayLinkTarget.tick(_:))
        )
        displayLinkTarget = target
        link.add(to: .main, forMode: .common)
        displayLink = link
        trace("linkStart")
    }

    private func stopDisplayLinkIfIdle() {
        guard phase == .idle else { return }
        stopDisplayLink()
    }

    private func stopDisplayLink() {
        let wasActive = displayLink != nil
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        if wasActive {
            trace("linkStop")
        }
    }

    private func displayTick() {
        if telemetryEnabled {
            recordTelemetryInterval()
        }
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
            guard axisLock.isHorizontal, displacement != 0 else {
                stopDisplayLink()
                return
            }
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
        let clamped = PagingRubberBand.clamp(
            offset,
            minX: 0,
            maxX: maxOffset,
            pageWidth: pageWidth
        )
        if allowSkip, abs(clamped - lastAppliedOffset) < PagingTuning.positionTolerance {
            settlingSkippedWriteCount += 1
            return
        }
        onScroll(clamped)
        lastAppliedOffset = clamped
        scrollWriteCount += 1
    }

    @MainActor
    final class DisplayLinkTarget: NSObject {
        weak var owner: PagingInteractionController?

        init(owner: PagingInteractionController?) {
            self.owner = owner
        }

        @objc func tick(_ link: CADisplayLink) {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.displayTick()
        }

        /// 确定性测试 seam：owner 已释放时，下一帧必须 invalidate。
        @discardableResult
        func tickForTesting(invalidate: () -> Void) -> Bool {
            guard owner == nil else { return false }
            invalidate()
            return true
        }
    }
}
