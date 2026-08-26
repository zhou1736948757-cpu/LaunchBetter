import Foundation
import QuartzCore

/// Why a gesture telemetry session ended.
enum GestureTelemetryCompletionReason: String, Sendable {
    case settled
    case interrupted
    case cancelled
}

/// Immutable hand-off from the main-actor recorder to the formatter.
struct GestureTelemetrySnapshot: Sendable {
    let gestureIndex: Int
    let startPage: Int
    let direction: PagingDirection
    let firstGestureSinceShow: Bool
    let activationResult: PageCompositorActivationResult
    let cacheVisualCount: Int
    let requiredPages: Int
    /// Processed frames (including deterministic probe frames); real DisplayLink
    /// cadence is represented separately by the displayLinkInterval* fields.
    let displayFrameCount: Int
    let scrollWriteCount: Int
    /// Duration of the settle phase, when one was defined. Cancellation paths
    /// which do not have a meaningful settle duration remain nil.
    let settleDurationMs: Double?
    let intervals: [Double]
    let completionReason: GestureTelemetryCompletionReason
}

/// 页面合成器激活原因遥测(默认关; `--pagingfeeltelemetry` 开启)。
@MainActor
final class PageCompositorActivationTelemetry {
    typealias SummaryFormatter = @Sendable (GestureTelemetrySnapshot) async -> String

    var enabled = false
    var onSummary: (String) -> Void = { print($0) }

    private let summaryFormatter: SummaryFormatter

    init() {
        summaryFormatter = { snapshot in
            PageCompositorActivationTelemetry.format(snapshot: snapshot)
        }
    }

    init(formatter: @escaping SummaryFormatter) {
        summaryFormatter = formatter
    }

    private var gestureIndex = 0
    private var nextSummaryDeliveryIndex = 0
    private var pendingSummaries: [Int: String] = [:]
    private var startPage = 0
    private var direction: PagingDirection = .next
    private var firstGestureSinceShow = true
    private var activationResult: PageCompositorActivationResult = .disabled
    private var cacheVisualCount = 0
    private var requiredPages = 0
    private var displayFrameCount = 0
    private var scrollWriteCount = 0
    private var settleDurationMs: Double?
    private var gestureInProgress = false

    private static let intervalCapacity = 512
    private var intervals = [Double](repeating: 0, count: intervalCapacity)
    private var intervalStart = 0
    private var intervalCount = 0
    private var lastIntervalTime: CFTimeInterval = 0

    /// Called by the real launcher show lifecycle, not by refresh or settling.
    func beginShowSession() {
        firstGestureSinceShow = true
    }

    func beginGesture(startPage: Int, direction: PagingDirection) {
        guard enabled else { return }
        gestureInProgress = true
        self.startPage = startPage
        self.direction = direction
        activationResult = .disabled
        cacheVisualCount = 0
        requiredPages = 0
        displayFrameCount = 0
        scrollWriteCount = 0
        settleDurationMs = nil
        resetIntervals()
    }

    func recordActivationResult(_ result: PageCompositorActivationResult) {
        guard enabled else { return }
        activationResult = result
    }

    func recordCacheVisualCount(_ count: Int) {
        guard enabled else { return }
        cacheVisualCount = count
    }

    func recordRequiredPages(_ count: Int) {
        guard enabled else { return }
        requiredPages = count
    }

    func recordDisplayFrameCount(_ count: Int) {
        guard enabled else { return }
        displayFrameCount = count
    }

    func recordScrollWriteCount(_ count: Int) {
        guard enabled else { return }
        scrollWriteCount = count
    }

    func recordSettleDuration(_ ms: Double) {
        guard enabled else { return }
        settleDurationMs = ms
    }

    func recordDisplayLinkInterval() {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        guard lastIntervalTime > 0 else {
            lastIntervalTime = now
            return
        }
        let interval = now - lastIntervalTime
        lastIntervalTime = now
        guard interval >= 0, interval.isFinite else { return }
        let index = (intervalStart + intervalCount) % Self.intervalCapacity
        intervals[index] = interval
        if intervalCount < Self.intervalCapacity {
            intervalCount += 1
        } else {
            intervalStart = (intervalStart + 1) % Self.intervalCapacity
        }
    }

    func recordProbeDisplayFrame() {
        guard enabled else { return }
        displayFrameCount += 1
    }

    /// Captures and ends the mutable session immediately. Formatting happens in
    /// a detached task, after the final DisplayLink callback has returned.
    @discardableResult
    func flushGesture(
        completionReason: GestureTelemetryCompletionReason = .settled,
        settleDurationMs: Double? = nil
    ) -> GestureTelemetrySnapshot? {
        guard enabled, gestureInProgress else { return nil }
        let snapshot = GestureTelemetrySnapshot(
            gestureIndex: gestureIndex,
            startPage: startPage,
            direction: direction,
            firstGestureSinceShow: firstGestureSinceShow,
            activationResult: activationResult,
            cacheVisualCount: cacheVisualCount,
            requiredPages: requiredPages,
            displayFrameCount: displayFrameCount,
            scrollWriteCount: scrollWriteCount,
            settleDurationMs: completionReason == .cancelled
                ? nil
                : settleDurationMs ?? self.settleDurationMs,
            intervals: currentIntervals(),
            completionReason: completionReason
        )
        gestureInProgress = false
        gestureIndex += 1
        firstGestureSinceShow = false
        resetIntervals()

        let formatter = summaryFormatter
        Task.detached(priority: .utility) { [snapshot, formatter] in
            let summary = await formatter(snapshot)
            await MainActor.run { [weak self] in
                self?.deliverSummary(summary, for: snapshot.gestureIndex)
            }
        }
        return snapshot
    }

    /// Formatting may finish out of order, but delivery follows gesture sequence.
    /// The queue is MainActor-owned, so a completed older task cannot be overtaken
    /// by a newer task and no completed session is discarded.
    private func deliverSummary(_ summary: String, for gestureIndex: Int) {
        pendingSummaries[gestureIndex] = summary
        while let nextSummary = pendingSummaries.removeValue(forKey: nextSummaryDeliveryIndex) {
            onSummary(nextSummary)
            nextSummaryDeliveryIndex += 1
        }
    }

    var displayLinkIntervalCountForDiag: Int { intervalCount }
    var gestureInProgressForDiag: Bool { gestureInProgress }

    /// Pure formatting/statistics function; safe to run away from MainActor.
    nonisolated static func format(snapshot: GestureTelemetrySnapshot) -> String {
        let samples = snapshot.intervals
        let avgMs = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count) * 1000
        let sorted = samples.sorted()
        let p95Index = sorted.isEmpty
            ? 0
            : min(sorted.count - 1, max(0, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1))
        let p95Ms = sorted.isEmpty ? 0 : sorted[p95Index] * 1000
        let maxMs = (sorted.last ?? 0) * 1000
        return "gestureIndex=\(snapshot.gestureIndex) startPage=\(snapshot.startPage) direction=\(snapshot.direction) "
            + "firstGestureSinceShow=\(snapshot.firstGestureSinceShow ? 1 : 0) "
            + "activationResult=\(snapshot.activationResult) cacheVisualCount=\(snapshot.cacheVisualCount) "
            + "requiredPages=\(snapshot.requiredPages) displayFrameCount=\(snapshot.displayFrameCount) "
            + "scrollWriteCount=\(snapshot.scrollWriteCount) settleDurationMs="
            + (snapshot.settleDurationMs.map { String(format: "%.1f", $0) } ?? "nil") + " "
            + "completionReason=\(snapshot.completionReason.rawValue) "
            + "displayLinkIntervalAvgMs=\(String(format: "%.2f", avgMs)) "
            + "displayLinkIntervalP95Ms=\(String(format: "%.2f", p95Ms)) "
            + "displayLinkIntervalMaxMs=\(String(format: "%.2f", maxMs))"
    }

    private func currentIntervals() -> [Double] {
        (0..<intervalCount).map { intervals[(intervalStart + $0) % Self.intervalCapacity] }
    }

    private func resetIntervals() {
        intervalStart = 0
        intervalCount = 0
        lastIntervalTime = 0
    }
}
