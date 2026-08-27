import Foundation
import QuartzCore

/// T-027: 一次 interaction session 的终止原因。
///
/// - `settled`: 弹簧收敛（`finishSettle`）。
/// - `interrupted`: settle 被新手势/新 settle 打断（`beginGesture` / `startSettle`）。
/// - `cancelled`: 手势取消（`.cancelled` 事件 / jump / disable / shutdown）。
/// - `endedWithoutSettle`: 跟手结束但未进入 settle（垂直手势 / 零位移）。
enum PagingPerfSessionReason: String, Sendable {
    case settled
    case interrupted
    case cancelled
    case endedWithoutSettle
}

/// T-027: cell/icon 事件的跨对象归属上下文。
///
/// `AppCellView`（prepareForReuse / icon request）与 `GridViewController`
/// （cell provider / configure）没有互持引用，统一经本上下文把真实调用点
/// 计入当前 recorder。默认 `recorder == nil`（未注册）→ 记录侧零开销；
/// 仅 `--paging-perf` 时由 GridViewController 注册。全部访问都在主线程
/// （AppKit 生命周期），因此 MainActor 隔离即足够，无需锁。
@MainActor
enum PagingPerfContext {
    /// 当前注册的 recorder（弱引用：生命周期归 GridViewController）。
    static weak var recorder: PagingPerfTelemetry?

    /// cell 侧记录入口：cell provider / configure / prepareForReuse / icon
    /// request 的真实调用点调用。enabled 关闭时零记录。
    static func recordCellEvent(_ kind: String) {
        guard let recorder, recorder.enabled else { return }
        recorder.recordCellEvent(kind: kind)
    }
}

/// T-027: 分页性能诊断 recorder（B+ Phase 1，默认关闭；`--paging-perf` 时接线）。
///
/// 采集范围（与任务包 §3 逐条对应）：
/// - **A Interaction/Display Link**：session 生命周期、输入事件、pre-lock
///   事件+累计 deltaX、tracking/settling/total frame、applyScroll、实际
///   offset write、settle skip write、起始/目标页、起始/最终 offset、
///   compositor active、输入→下一次 offset apply 延迟。
/// - **B Live/Compositor 路由**：live tracking/settling 的 clip scroll(to:)；
///   compositor tracking 的 applyOffset；compositor settling 的 layer apply、
///   advanceRealClipBehindCover()、gap 阈值跳过、catch-up clip 写与 gap 最大；
///   teardown 原因 / sync clip / layoutSubtreeIfNeeded / 总时长。
/// - **C Layout**：prepare()、layoutAttributesForElements(in:)、
///   shouldInvalidateLayout(forBoundsChange:)（不改 invalidation 行为）。
/// - **D Cell/Icon**：cell provider / configure / prepareForReuse / icon
///   request 真实调用点计数，按 phase + compositor active 分桶归属。
///
/// 输出：每 session 完成时一行 JSONL（`pagingSessionSummary`）；无 session
/// 归属的 idle 事件在下次 session 开始（或显式 flush）时以
/// `pagingIdleSummary` 一行输出。不逐帧刷屏。默认路径（enabled == false）
/// 每个调用点一次布尔判断，不分配、不构建字符串。
///
/// 明确边界：本 recorder 只做计数与耗时聚合，不参与任何行为决策；
/// 不修改 offset writer / 状态机 / 布局 / 动画 / 产品交互。
@MainActor
final class PagingPerfTelemetry {
    /// 默认关闭；`--paging-perf` 时由 GridViewController 置 true。
    var enabled = false

    /// 摘要输出（JSONL 一行一个 session；默认 stdout）。
    var onSummary: (String) -> Void = { print($0) }

    // MARK: - 聚合小工具

    /// count / total / max 时长桶（毫秒）。
    struct Timing {
        var count = 0
        var totalMs: Double = 0
        var maxMs: Double = 0

        mutating func record(ms: Double) {
            count += 1
            let safe = ms.isFinite && ms >= 0 ? ms : 0
            totalMs += safe
            maxMs = Swift.max(maxMs, safe)
        }
    }

    /// count 桶 + max。
    struct CountMax {
        var total = 0
        var max = 0

        mutating func record(_ value: Int) {
            total += value
            max = Swift.max(max, value)
        }
    }

    /// D 类事件分桶：按 paging phase 计数 + 发生时 compositor active 计数。
    struct PhaseCounts {
        var tracking = 0
        var settling = 0
        var idle = 0
        var compositorActive = 0

        mutating func record(phase: String, compositorActive: Bool) {
            switch phase {
            case "tracking": tracking += 1
            case "settling": settling += 1
            default: idle += 1
            }
            if compositorActive { self.compositorActive += 1 }
        }
    }

    // MARK: - Session

    /// 一次 interaction session 的累计状态（begin → terminal → flush 一次）。
    private final class Session {
        let id: String
        var beganAt: CFTimeInterval = 0
        var axisLockAt: CFTimeInterval?
        var gestureEndAt: CFTimeInterval?
        var settleStartAt: CFTimeInterval?
        var terminalAt: CFTimeInterval = 0
        var phase = "tracking"
        var outcome: PagingPerfSessionReason?
        var inputEvents = 0
        var preLockEvents = 0
        var preLockDeltaX: CGFloat = 0
        var trackingFrames = 0
        var settlingFrames = 0
        var applyScrollCalls = 0
        var offsetWrites = 0
        var settleSkipWrites = 0
        var startPage = 0
        var targetPage: Int?
        var startOffset: CGFloat = 0
        var finalOffset: CGFloat = 0
        var compositorActive = false
        var latencyCount = 0
        var latencyTotal: CFTimeInterval = 0
        var latencyMax: CFTimeInterval = 0
        // B: live / compositor 路由
        var liveTracking = Timing()
        var liveSettling = Timing()
        var compositorTrackingApply = Timing()
        var compositorTrackingRealClipWrites = 0
        var compositorSettlingLayerApply = Timing()
        var advanceRealClipCalls = 0
        var advanceGapSkips = 0
        var catchUpWrites = Timing()
        var catchUpGapMax: CGFloat = 0
        var teardownReason: String?
        var teardownSyncClip = Timing()
        var teardownLayoutExecuted = false
        var teardownLayout = Timing()
        var teardownTotal = Timing()
        // C: layout
        var layoutPrepare = Timing()
        var layoutQuery = Timing()
        var layoutCandidates = CountMax()
        var layoutReturned = CountMax()
        var invalidateCalls = 0
        var invalidateTrue = 0
        var invalidateFalse = 0
        // D: cell / icon
        var cellProvider = PhaseCounts()
        var cellConfigure = PhaseCounts()
        var cellPrepareForReuse = PhaseCounts()
        var iconRequest = PhaseCounts()

        init(id: String) { self.id = id }
    }

    /// 无 open session 时的 idle 归属桶（cell / layout / teardown 事件）。
    private struct IdleBucket {
        var layoutPrepare = Timing()
        var layoutQuery = Timing()
        var layoutCandidates = CountMax()
        var layoutReturned = CountMax()
        var invalidateCalls = 0
        var invalidateTrue = 0
        var invalidateFalse = 0
        var cellProvider = PhaseCounts()
        var cellConfigure = PhaseCounts()
        var cellPrepareForReuse = PhaseCounts()
        var iconRequest = PhaseCounts()
        var teardownReason: String?
        var teardownSyncClip = Timing()
        var teardownLayoutExecuted = false
        var teardownLayout = Timing()
        var teardownTotal = Timing()
    }

    /// 在途 teardown 的归属目标（started → sync/layout/finished 之间固定）。
    private enum TeardownTarget {
        case session(Session)
        case idle
    }

    /// 进程级 session 计数器：sessionId 跨 recorder 实例唯一。
    private static var globalSessionCounter: UInt64 = 0

    private var activeSession: Session?
    private var idle = IdleBucket()
    private var currentCompositorActive = false
    private var lastInputTime: CFTimeInterval?
    private var pendingTeardown: TeardownTarget?
    private var pendingLayoutStart: CFTimeInterval = 0
    private var pendingLayoutTarget: Session?
    private var pendingLayoutIdle = false
    private var pendingQueryStart: CFTimeInterval = 0
    private var pendingQueryTarget: Session?
    private var pendingQueryIdle = false

    // MARK: - Session 生命周期（PagingInteractionController 调用）

    func beginSession(startPage: Int, startOffset: CGFloat, at time: CFTimeInterval) {
        guard enabled else { return }
        flushIdleSummaryIfAny()
        // 防御性收口：理论上 begin 前必已 idle（onPhaseIdle 恒收口）。
        if let previous = activeSession, previous.outcome == nil {
            previous.outcome = .endedWithoutSettle
            previous.terminalAt = time
        }
        emitActiveSessionIfClosed()
        Self.globalSessionCounter &+= 1
        let session = Session(id: String(format: "S%06llu", Self.globalSessionCounter))
        session.beganAt = time
        session.startPage = startPage
        session.startOffset = startOffset
        session.phase = "tracking"
        session.compositorActive = currentCompositorActive
        activeSession = session
        lastInputTime = nil
    }

    /// 无 open session 时开启（programmatic settle / discrete 滚轮路径）。
    /// T-027 R2: 已收口（outcome 已置）但尚未 emit 的 session 也视为"需要重建"
    /// —— 例如 settle 进行中被 discrete 输入打断：startSettle 先记 interrupted
    /// 收口旧 session，紧接着 beginSessionIfNeeded 若不重建，旧 session 永不被
    /// emit、新 settle 的指标全部丢失。重建走 beginSession（其内部含 flushIdle
    /// + 防御收口 + emitActiveSessionIfClosed + 开新，幂等安全）。
    func beginSessionIfNeeded(startPage: Int, startOffset: CGFloat, at time: CFTimeInterval) {
        guard enabled else { return }
        if let current = activeSession, current.outcome == nil { return }
        beginSession(startPage: startPage, startOffset: startOffset, at: time)
    }

    /// 运动停止（onPhaseIdle）时收口：未显式终止的 session 记为 endedWithoutSettle。
    func flushOpenSession() {
        guard enabled else { return }
        if let session = activeSession, session.outcome == nil {
            session.terminalAt = ProcessInfo.processInfo.systemUptime
            session.outcome = .endedWithoutSettle
        }
        emitActiveSessionIfClosed()
    }

    func recordInputEvent(at time: CFTimeInterval) {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.inputEvents += 1
        lastInputTime = time
    }

    /// discrete 滚轮输入：无 session 时先开一个（随后 startSettle 复用）。
    func recordDiscreteInput(startPage: Int, startOffset: CGFloat, at time: CFTimeInterval) {
        guard enabled else { return }
        beginSessionIfNeeded(startPage: startPage, startOffset: startOffset, at: time)
        recordInputEvent(at: time)
    }

    /// axis lock 前未进入 displacement 的事件（deltaX 累计）。
    func recordPreLockEvent(deltaX: CGFloat) {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.preLockEvents += 1
        session.preLockDeltaX += deltaX
    }

    func recordAxisLock(at time: CFTimeInterval) {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        if session.axisLockAt == nil { session.axisLockAt = time }
    }

    func recordGestureEnd(at time: CFTimeInterval) {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.gestureEndAt = time
    }

    func recordSettleStart(targetPage: Int, at time: CFTimeInterval) {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.targetPage = targetPage
        session.settleStartAt = time
        session.phase = "settling"
    }

    func recordSettleCompleted(finalOffset: CGFloat, at time: CFTimeInterval) {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.finalOffset = finalOffset
        session.terminalAt = time
        session.outcome = .settled
    }

    func recordSettleInterrupted(at time: CFTimeInterval) {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.terminalAt = time
        session.outcome = .interrupted
    }

    func recordSettleCancelled(at time: CFTimeInterval) {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.terminalAt = time
        session.outcome = .cancelled
    }

    func recordTrackingCancelled(at time: CFTimeInterval) {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.terminalAt = time
        session.outcome = .cancelled
    }

    func recordTrackingEndedWithoutSettle(at time: CFTimeInterval) {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.terminalAt = time
        session.outcome = .endedWithoutSettle
    }

    // MARK: - 帧 / 写入（PagingInteractionController 调用）

    func recordTrackingFrame() {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.trackingFrames += 1
    }

    func recordSettlingFrame() {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.settlingFrames += 1
    }

    func recordApplyScroll() {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.applyScrollCalls += 1
    }

    func recordOffsetWrite(at time: CFTimeInterval) {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.offsetWrites += 1
        // 输入→下一次 offset apply 延迟（低成本：一次时间差，取首个 apply）。
        if let last = lastInputTime {
            let delta = time - last
            if delta >= 0 {
                session.latencyCount += 1
                session.latencyTotal += delta
                session.latencyMax = Swift.max(session.latencyMax, delta)
            }
            lastInputTime = nil
        }
    }

    func recordSettleSkipWrite() {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.settleSkipWrites += 1
    }

    // MARK: - B: live / compositor 路由（GridViewController 调用）

    /// 记录 compositor active 状态变化（激活成功 / teardown 后）。
    func markCompositorActive(_ active: Bool) {
        currentCompositorActive = active
        guard enabled, let session = activeSession else { return }
        if active { session.compositorActive = true }
    }

    /// live 路径真实 clip `scroll(to:)`（按 phase 分 tracking / settling）。
    func recordLiveScroll(phase: String, durationMs: Double) {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        if phase == "settling" {
            session.liveSettling.record(ms: durationMs)
        } else {
            session.liveTracking.record(ms: durationMs)
        }
    }

    /// compositor 路径 `applyOffset`（按 phase 分 tracking / settling layer apply）。
    func recordCompositorApplyOffset(phase: String, durationMs: Double) {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        if phase == "settling" {
            session.compositorSettlingLayerApply.record(ms: durationMs)
        } else {
            session.compositorTrackingApply.record(ms: durationMs)
        }
    }

    /// compositor tracking 期间的真实 clip 写（当前架构下 routeScroll 不写
    /// 真实 clip，该计数恒 0；计数器如实保留，供真机 profile 验证）。
    func recordCompositorTrackingRealClipWrite() {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.compositorTrackingRealClipWrites += 1
    }

    func recordAdvanceRealClipCall() {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.advanceRealClipCalls += 1
    }

    /// gap ≤ 0.5pt 阈值跳过（advanceRealClipBehindCover 的 35% 追赶未执行）。
    func recordCatchUpGapSkip() {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.advanceGapSkips += 1
    }

    /// catch-up clip 写（35% 追赶执行）。
    func recordCatchUpWrite(durationMs: Double, gap: CGFloat) {
        guard enabled, let session = activeSession, session.outcome == nil else { return }
        session.catchUpWrites.record(ms: durationMs)
        if gap.isFinite { session.catchUpGapMax = Swift.max(session.catchUpGapMax, gap) }
    }

    // MARK: - B: compositor teardown（PageCompositor / GridViewController 调用）

    func recordCompositorTeardownStarted(reason: String) {
        guard enabled else { return }
        if let session = activeSession {
            session.teardownReason = reason
            pendingTeardown = .session(session)
        } else {
            idle.teardownReason = reason
            pendingTeardown = .idle
        }
    }

    func recordCompositorTeardownSyncClip(durationMs: Double) {
        guard enabled else { return }
        switch pendingTeardown {
        case .session(let session): session.teardownSyncClip.record(ms: durationMs)
        case .idle: idle.teardownSyncClip.record(ms: durationMs)
        case nil: break
        }
    }

    /// layoutSubtreeIfNeeded() 是否执行 + 耗时（onSyncClip 闭包内测得）。
    func recordCompositorTeardownLayout(durationMs: Double) {
        guard enabled else { return }
        switch pendingTeardown {
        case .session(let session):
            session.teardownLayoutExecuted = true
            session.teardownLayout.record(ms: durationMs)
        case .idle:
            idle.teardownLayoutExecuted = true
            idle.teardownLayout.record(ms: durationMs)
        case nil: break
        }
    }

    func recordCompositorTeardownFinished(durationMs: Double) {
        guard enabled else { return }
        switch pendingTeardown {
        case .session(let session): session.teardownTotal.record(ms: durationMs)
        case .idle: idle.teardownTotal.record(ms: durationMs)
        case nil: break
        }
        pendingTeardown = nil
    }

    // MARK: - C: layout（PagingGridLayout 调用；不改 invalidation 行为）

    func recordLayoutPrepareStarted() {
        guard enabled else { return }
        if let session = activeSession {
            pendingLayoutTarget = session
            pendingLayoutIdle = false
        } else {
            pendingLayoutTarget = nil
            pendingLayoutIdle = true
        }
        pendingLayoutStart = CACurrentMediaTime()
    }

    func recordLayoutPrepareFinished() {
        guard enabled else { return }
        let ms = (CACurrentMediaTime() - pendingLayoutStart) * 1000
        if let target = pendingLayoutTarget {
            target.layoutPrepare.record(ms: ms)
        } else if pendingLayoutIdle {
            idle.layoutPrepare.record(ms: ms)
        }
        pendingLayoutTarget = nil
        pendingLayoutIdle = false
    }

    func recordLayoutQueryStarted() {
        guard enabled else { return }
        if let session = activeSession {
            pendingQueryTarget = session
            pendingQueryIdle = false
        } else {
            pendingQueryTarget = nil
            pendingQueryIdle = true
        }
        pendingQueryStart = CACurrentMediaTime()
    }

    func recordLayoutQueryFinished(candidates: Int, returned: Int) {
        guard enabled else { return }
        let ms = (CACurrentMediaTime() - pendingQueryStart) * 1000
        if let target = pendingQueryTarget {
            target.layoutQuery.record(ms: ms)
            target.layoutCandidates.record(candidates)
            target.layoutReturned.record(returned)
        } else if pendingQueryIdle {
            idle.layoutQuery.record(ms: ms)
            idle.layoutCandidates.record(candidates)
            idle.layoutReturned.record(returned)
        }
        pendingQueryTarget = nil
        pendingQueryIdle = false
    }

    func recordLayoutInvalidationDecision(_ invalidate: Bool) {
        guard enabled else { return }
        if let session = activeSession {
            session.invalidateCalls += 1
            if invalidate { session.invalidateTrue += 1 } else { session.invalidateFalse += 1 }
        } else {
            idle.invalidateCalls += 1
            if invalidate { idle.invalidateTrue += 1 } else { idle.invalidateFalse += 1 }
        }
    }

    // MARK: - D: cell / icon（PagingPerfContext 转发；真实调用点）

    func recordCellEvent(kind: String) {
        guard enabled else { return }
        let phase = activeSession?.phase ?? "idle"
        let compositor = currentCompositorActive
        if let session = activeSession {
            switch kind {
            case "cellProvider":
                session.cellProvider.record(phase: phase, compositorActive: compositor)
            case "cellConfigure":
                session.cellConfigure.record(phase: phase, compositorActive: compositor)
            case "prepareForReuse":
                session.cellPrepareForReuse.record(phase: phase, compositorActive: compositor)
            case "iconRequest":
                session.iconRequest.record(phase: phase, compositorActive: compositor)
            default:
                break
            }
        } else {
            switch kind {
            case "cellProvider":
                idle.cellProvider.record(phase: phase, compositorActive: compositor)
            case "cellConfigure":
                idle.cellConfigure.record(phase: phase, compositorActive: compositor)
            case "prepareForReuse":
                idle.cellPrepareForReuse.record(phase: phase, compositorActive: compositor)
            case "iconRequest":
                idle.iconRequest.record(phase: phase, compositorActive: compositor)
            default:
                break
            }
        }
    }

    // MARK: - Flush

    /// 输出无 session 归属的 idle 事件（下次 session 开始前 / 显式调用时）。
    func flushIdleSummaryIfAny() {
        guard enabled else { return }
        let hasIdleData =
            idle.layoutPrepare.count > 0 || idle.layoutQuery.count > 0
            || idle.invalidateCalls > 0
            || idle.cellProvider.tracking + idle.cellProvider.settling + idle.cellProvider.idle > 0
            || idle.cellConfigure.tracking + idle.cellConfigure.settling + idle.cellConfigure.idle > 0
            || idle.cellPrepareForReuse.tracking + idle.cellPrepareForReuse.settling + idle.cellPrepareForReuse.idle > 0
            || idle.iconRequest.tracking + idle.iconRequest.settling + idle.iconRequest.idle > 0
            || idle.teardownSyncClip.count > 0 || idle.teardownTotal.count > 0
        guard hasIdleData else { return }
        emitIdleSummary()
        idle = IdleBucket()
    }

    private func emitActiveSessionIfClosed() {
        guard let session = activeSession, session.outcome != nil else { return }
        emitSessionSummary(session)
        activeSession = nil
    }

    // MARK: - JSONL 输出

    private func emitSessionSummary(_ session: Session) {
        guard enabled else { return }
        let trackingMs = ((session.settleStartAt ?? session.terminalAt) - session.beganAt) * 1000
        let settlingMs = session.settleStartAt.map { (session.terminalAt - $0) * 1000 } ?? 0
        let totalMs = (session.terminalAt - session.beganAt) * 1000
        let json: [String: Any] = [
            "event": "pagingSessionSummary",
            "sessionId": session.id,
            "ts": round3(session.terminalAt),
            "reason": session.outcome?.rawValue ?? "unknown",
            "a": [
                "beginAt": round3(session.beganAt),
                "axisLockAt": session.axisLockAt.map(round3) ?? NSNull(),
                "gestureEndAt": session.gestureEndAt.map(round3) ?? NSNull(),
                "settleStartAt": session.settleStartAt.map(round3) ?? NSNull(),
                "terminalAt": round3(session.terminalAt),
                "inputEvents": session.inputEvents,
                "preLockEvents": session.preLockEvents,
                "preLockDeltaX": round3(Double(session.preLockDeltaX)),
                "trackingFrames": session.trackingFrames,
                "settlingFrames": session.settlingFrames,
                "totalFrames": session.trackingFrames + session.settlingFrames,
                "trackingDurationMs": round3(Swift.max(0, trackingMs)),
                "settlingDurationMs": round3(Swift.max(0, settlingMs)),
                "totalDurationMs": round3(Swift.max(0, totalMs)),
                "applyScrollCalls": session.applyScrollCalls,
                "offsetWrites": session.offsetWrites,
                "settleSkipWrites": session.settleSkipWrites,
                "startPage": session.startPage,
                "targetPage": (session.targetPage as Any?) ?? NSNull(),
                "startOffset": round3(Double(session.startOffset)),
                "finalOffset": round3(Double(session.finalOffset)),
                "compositorActive": session.compositorActive,
                "inputToApplyLatencyCount": session.latencyCount,
                "inputToApplyLatencyTotalMs": round3(session.latencyTotal * 1000),
                "inputToApplyLatencyMaxMs": round3(session.latencyMax * 1000),
            ],
            "b": [
                "liveTracking": timingJSON(session.liveTracking),
                "liveSettling": timingJSON(session.liveSettling),
                "compositorTracking": [
                    "applyOffsetCount": session.compositorTrackingApply.count,
                    "totalMs": round3(session.compositorTrackingApply.totalMs),
                    "maxMs": round3(session.compositorTrackingApply.maxMs),
                    "realClipWriteCount": session.compositorTrackingRealClipWrites,
                ],
                "compositorSettling": [
                    "layerApplyCount": session.compositorSettlingLayerApply.count,
                    "totalMs": round3(session.compositorSettlingLayerApply.totalMs),
                    "maxMs": round3(session.compositorSettlingLayerApply.maxMs),
                    "advanceRealClipCalls": session.advanceRealClipCalls,
                    "gapSkipCount": session.advanceGapSkips,
                    "catchUpClipWriteCount": session.catchUpWrites.count,
                    "catchUpTotalMs": round3(session.catchUpWrites.totalMs),
                    "catchUpMaxMs": round3(session.catchUpWrites.maxMs),
                    "catchUpGapMax": round3(Double(session.catchUpGapMax)),
                ],
                "teardown": teardownJSON(
                    reason: session.teardownReason,
                    syncClip: session.teardownSyncClip,
                    layoutExecuted: session.teardownLayoutExecuted,
                    layout: session.teardownLayout,
                    total: session.teardownTotal
                ),
            ],
            "c": [
                "prepare": timingJSON(session.layoutPrepare),
                "query": [
                    "count": session.layoutQuery.count,
                    "totalMs": round3(session.layoutQuery.totalMs),
                    "maxMs": round3(session.layoutQuery.maxMs),
                    "candidatesTotal": session.layoutCandidates.total,
                    "candidatesMax": session.layoutCandidates.max,
                    "returnedTotal": session.layoutReturned.total,
                    "returnedMax": session.layoutReturned.max,
                ],
                "invalidate": [
                    "calls": session.invalidateCalls,
                    "true": session.invalidateTrue,
                    "false": session.invalidateFalse,
                ],
            ],
            "d": [
                "cellProvider": phaseJSON(session.cellProvider),
                "cellConfigure": phaseJSON(session.cellConfigure),
                "cellPrepareForReuse": phaseJSON(session.cellPrepareForReuse),
                "iconRequest": phaseJSON(session.iconRequest),
            ],
        ]
        emit(json)
    }

    private func emitIdleSummary() {
        guard enabled else { return }
        let json: [String: Any] = [
            "event": "pagingIdleSummary",
            "attribution": "idle",
            "sessionId": NSNull(),
            "ts": round3(ProcessInfo.processInfo.systemUptime),
            "c": [
                "prepare": timingJSON(idle.layoutPrepare),
                "query": [
                    "count": idle.layoutQuery.count,
                    "totalMs": round3(idle.layoutQuery.totalMs),
                    "maxMs": round3(idle.layoutQuery.maxMs),
                    "candidatesTotal": idle.layoutCandidates.total,
                    "candidatesMax": idle.layoutCandidates.max,
                    "returnedTotal": idle.layoutReturned.total,
                    "returnedMax": idle.layoutReturned.max,
                ],
                "invalidate": [
                    "calls": idle.invalidateCalls,
                    "true": idle.invalidateTrue,
                    "false": idle.invalidateFalse,
                ],
            ],
            "d": [
                "cellProvider": phaseJSON(idle.cellProvider),
                "cellConfigure": phaseJSON(idle.cellConfigure),
                "cellPrepareForReuse": phaseJSON(idle.cellPrepareForReuse),
                "iconRequest": phaseJSON(idle.iconRequest),
            ],
            "b": [
                "teardown": teardownJSON(
                    reason: idle.teardownReason,
                    syncClip: idle.teardownSyncClip,
                    layoutExecuted: idle.teardownLayoutExecuted,
                    layout: idle.teardownLayout,
                    total: idle.teardownTotal
                ),
            ],
        ]
        emit(json)
    }

    private func emit(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.sortedKeys]
        ), let line = String(data: data, encoding: .utf8) else { return }
        onSummary(line)
    }

    private func timingJSON(_ timing: Timing) -> [String: Any] {
        [
            "count": timing.count,
            "totalMs": round3(timing.totalMs),
            "maxMs": round3(timing.maxMs),
        ]
    }

    private func phaseJSON(_ counts: PhaseCounts) -> [String: Any] {
        [
            "tracking": counts.tracking,
            "settling": counts.settling,
            "idle": counts.idle,
            "compositorActive": counts.compositorActive,
        ]
    }

    private func teardownJSON(
        reason: String?,
        syncClip: Timing,
        layoutExecuted: Bool,
        layout: Timing,
        total: Timing
    ) -> [String: Any] {
        [
            "reason": reason ?? NSNull(),
            "syncClipCount": syncClip.count,
            "syncClipTotalMs": round3(syncClip.totalMs),
            "syncClipMaxMs": round3(syncClip.maxMs),
            "layoutSubtreeExecuted": layoutExecuted,
            "layoutSubtreeTotalMs": round3(layout.totalMs),
            "layoutSubtreeMaxMs": round3(layout.maxMs),
            "totalCount": total.count,
            "totalTotalMs": round3(total.totalMs),
            "totalMaxMs": round3(total.maxMs),
        ]
    }

    private func round3(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    // MARK: - 诊断 / 测试访问

    var hasOpenSessionForDiag: Bool { activeSession != nil }

    var currentPhaseForDiag: String { activeSession?.phase ?? "idle" }

    var pendingOutcomeForDiag: String? { activeSession?.outcome?.rawValue }

    var currentCompositorActiveForDiag: Bool { currentCompositorActive }
}
