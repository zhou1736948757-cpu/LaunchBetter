import Foundation
import Testing
@testable import LaunchUI

private actor FormatterGate {
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
    private var completed: Set<Int> = []
    private var completionWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var started: Set<Int> = []

    func wait(for gestureIndex: Int) async {
        started.insert(gestureIndex)
        for waiter in startWaiters.removeValue(forKey: gestureIndex) ?? [] {
            waiter.resume()
        }
        guard !completed.contains(gestureIndex) else { return }
        await withCheckedContinuation { continuation in
            releases[gestureIndex] = continuation
        }
    }

    func waitUntilStarted(_ gestureIndex: Int) async {
        guard !started.contains(gestureIndex) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[gestureIndex, default: []].append(continuation)
        }
    }

    func release(_ gestureIndex: Int) {
        releases.removeValue(forKey: gestureIndex)?.resume()
    }

    func markCompleted(_ gestureIndex: Int) {
        completed.insert(gestureIndex)
        for waiter in completionWaiters.removeValue(forKey: gestureIndex) ?? [] {
            waiter.resume()
        }
    }

    func waitUntilCompleted(_ gestureIndex: Int) async {
        guard !completed.contains(gestureIndex) else { return }
        await withCheckedContinuation { continuation in
            completionWaiters[gestureIndex, default: []].append(continuation)
        }
    }
}

@Suite("PageCompositorActivationTelemetry", .serialized)
@MainActor
struct PageCompositorActivationTelemetryTests {
    @Test("激活结果枚举各 case 可正确产生")
    func activationResultCases() {
        let cases: [PageCompositorActivationResult] = [
            .activated, .disabled, .alreadyActive, .search, .appLibrary,
            .dragActive, .sparsePage, .offsetNotAtBoundary, .targetIsLibrary,
            .targetOutOfBounds, .currentVisualMissing, .targetVisualMissing,
            .invalidGeometry, .activeCoverageReuse, .interruptionFallbackLive,
        ]
        #expect(cases.count == 15)
        #expect(PageCompositorActivationResult.activated == .activated)
        #expect(PageCompositorActivationResult.disabled != .activated)
        for c in cases {
            #expect(c == c, "每个 case 可独立产生且可比较")
        }
    }

    @Test("默认关闭: 不输出遥测摘要")
    func defaultOffNoSummary() {
        let telemetry = PageCompositorActivationTelemetry()
        var outputCount = 0
        telemetry.onSummary = { _ in outputCount += 1 }
        telemetry.beginGesture(startPage: 1, direction: .next)
        telemetry.recordActivationResult(.activated)
        telemetry.flushGesture()
        #expect(outputCount == 0, "默认产品路径不输出遥测摘要")
    }

    @Test("开启后: 输出正确摘要格式")
    func enabledOutputsSummary() async {
        let telemetry = PageCompositorActivationTelemetry()
        telemetry.enabled = true
        let summary = await withCheckedContinuation { cont in
            telemetry.onSummary = { cont.resume(returning: $0) }
            telemetry.beginGesture(startPage: 1, direction: .next)
            telemetry.recordActivationResult(.activated)
            telemetry.recordCacheVisualCount(2)
            telemetry.recordRequiredPages(2)
            telemetry.recordDisplayFrameCount(12)
            telemetry.recordScrollWriteCount(10)
            telemetry.recordSettleDuration(120.5)
            telemetry.flushGesture()
        }
        #expect(summary.contains("gestureIndex=0"))
        #expect(summary.contains("startPage=1"))
        #expect(summary.contains("direction=next"))
        #expect(summary.contains("firstGestureSinceShow=1"))
        #expect(summary.contains("activationResult=activated"))
        #expect(summary.contains("cacheVisualCount=2"))
        #expect(summary.contains("requiredPages=2"))
        #expect(summary.contains("displayFrameCount=12"))
        #expect(summary.contains("scrollWriteCount=10"))
        #expect(summary.contains("settleDurationMs=120.5"))
        #expect(summary.contains("displayLinkIntervalAvgMs="))
        #expect(summary.contains("displayLinkIntervalP95Ms="))
        #expect(summary.contains("displayLinkIntervalMaxMs="))
    }

    @Test("interruption flush preserves old session and completion reason")
    func interruptionFlushPreservesOldSession() async {
        let gate = FormatterGate()
        let telemetry = PageCompositorActivationTelemetry { snapshot in
            await gate.wait(for: snapshot.gestureIndex)
            let summary = PageCompositorActivationTelemetry.format(snapshot: snapshot)
            await gate.markCompleted(snapshot.gestureIndex)
            return summary
        }
        telemetry.enabled = true
        var summaries: [String] = []
        var streamContinuation: AsyncStream<String>.Continuation!
        let summaryStream = AsyncStream<String> { streamContinuation = $0 }
        var summaryIterator = summaryStream.makeAsyncIterator()
        telemetry.onSummary = { summary in
            summaries.append(summary)
            streamContinuation.yield(summary)
        }

        // Flush the interrupted gesture before starting the replacement gesture.
        telemetry.beginGesture(startPage: 0, direction: .next)
        telemetry.recordActivationResult(.activated)
        _ = telemetry.flushGesture(completionReason: .interrupted)
        await gate.waitUntilStarted(0)

        telemetry.beginGesture(startPage: 1, direction: .next)
        telemetry.recordActivationResult(.activeCoverageReuse)
        _ = telemetry.flushGesture()
        await gate.waitUntilStarted(1)

        // Complete the newer formatter first. FIFO must buffer it behind gesture 0.
        await gate.release(1)
        await gate.waitUntilCompleted(1)
        #expect(summaries.isEmpty)

        // Releasing the older formatter makes both summaries deliver in gesture order.
        await gate.release(0)
        await gate.waitUntilCompleted(0)
        let first = await summaryIterator.next() ?? ""
        let second = await summaryIterator.next() ?? ""
        #expect(first.contains("gestureIndex=0"))
        #expect(first.contains("completionReason=interrupted"))
        #expect(second.contains("gestureIndex=1"))
        #expect(second.contains("completionReason=settled"))
        #expect(summaries.count == 2)
    }

    @Test("cancellation uses nil duration and every session flushes at most once")
    func cancellationUsesNilDurationAndFlushesOnce() {
        let telemetry = PageCompositorActivationTelemetry()
        telemetry.enabled = true
        telemetry.beginGesture(startPage: 0, direction: .next)
        telemetry.recordSettleDuration(120)
        let snapshot = telemetry.flushGesture(completionReason: .cancelled, settleDurationMs: nil)
        #expect(snapshot?.completionReason == .cancelled)
        #expect(snapshot?.settleDurationMs == nil)
        #expect(telemetry.flushGesture(completionReason: .settled) == nil)
    }

    @Test("activation fallback does not become a completion reason")
    func activationFallbackDoesNotBecomeCompletionReason() async {
        let telemetry = PageCompositorActivationTelemetry()
        telemetry.enabled = true
        let summary = await withCheckedContinuation { continuation in
            telemetry.onSummary = { continuation.resume(returning: $0) }
            telemetry.beginGesture(startPage: 0, direction: .next)
            telemetry.recordActivationResult(.targetOutOfBounds)
            _ = telemetry.flushGesture()
        }
        #expect(summary.contains("activationResult=targetOutOfBounds"))
        #expect(summary.contains("completionReason=settled"))
        #expect(!summary.contains("completionReason=liveFallback"))
    }

    @Test("show session resets first gesture marker without refresh")
    func showSessionResetsFirstGestureMarker() async {
        let gate = FormatterGate()
        let telemetry = PageCompositorActivationTelemetry { snapshot in
            await gate.wait(for: snapshot.gestureIndex)
            let summary = PageCompositorActivationTelemetry.format(snapshot: snapshot)
            await gate.markCompleted(snapshot.gestureIndex)
            return summary
        }
        telemetry.enabled = true
        var streamContinuation: AsyncStream<String>.Continuation!
        let summaryStream = AsyncStream<String> { streamContinuation = $0 }
        var summaryIterator = summaryStream.makeAsyncIterator()
        telemetry.onSummary = { summary in
            streamContinuation.yield(summary)
        }

        telemetry.beginGesture(startPage: 0, direction: .next)
        _ = telemetry.flushGesture()
        await gate.waitUntilStarted(0)
        await gate.release(0)
        await gate.waitUntilCompleted(0)
        let firstSummary = await summaryIterator.next() ?? ""

        telemetry.beginShowSession()
        telemetry.beginGesture(startPage: 0, direction: .next)
        _ = telemetry.flushGesture()
        await gate.waitUntilStarted(1)
        await gate.release(1)
        await gate.waitUntilCompleted(1)
        let secondSummary = await summaryIterator.next() ?? ""

        #expect(firstSummary.contains("firstGestureSinceShow=1"))
        #expect(secondSummary.contains("firstGestureSinceShow=1"))
    }

    @Test("真实 DisplayLink 间隔与 probeDisplayFrame 分开统计")
    func displayLinkIntervalSeparateFromProbe() {
        let telemetry = PageCompositorActivationTelemetry()
        telemetry.enabled = true
        // 真实回调: 首次设基准, 第二次记录 1 个间隔。
        telemetry.recordDisplayLinkInterval()
        telemetry.recordDisplayLinkInterval()
        #expect(telemetry.displayLinkIntervalCountForDiag == 1)
        // probeDisplayFrame 只计帧数, 不增加 displayLink 间隔。
        telemetry.recordProbeDisplayFrame()
        telemetry.recordProbeDisplayFrame()
        #expect(telemetry.displayLinkIntervalCountForDiag == 1, "probe 不记录 displayLink 间隔")
    }
}
