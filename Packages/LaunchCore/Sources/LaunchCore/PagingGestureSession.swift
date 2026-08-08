import Foundation

/// 双指滑动分页手势状态机(Stage 1, P0)。
///
/// 真实触控板一次滑动会产生多个 NSEvent(began / changed×N / ended / momentum…)。
/// 本状态机保证:
/// - 一次手势最多提交一页(threshold 后 committed, 后续 changed 不再提交)
/// - momentum(惯性)阶段不产生翻页
/// - 只有明显水平主导(deltaX 显著大于 deltaY)才进入分页手势
/// - 小幅抖动不翻页
/// - 下一次独立手势允许再次翻页
///
/// 纯输入模型: 只依赖 (phase, deltaX, deltaY, momentum), 可在无 NSEvent 环境测试。
public struct PagingGestureSession: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case began
        case changed
        case ended
        case cancelled
    }

    /// 触发阈值(pt): 水平累计位移超过该值才提交一次翻页。
    public let threshold: CGFloat

    /// 水平主导比例: |deltaX| 必须 ≥ |deltaY| × dominance 才视为水平手势。
    public let horizontalDominance: CGFloat

    /// 累计方向: 1 = 下一页(左滑), -1 = 上一页(右滑), 0 = 未定向。
    private(set) public var direction: Int

    /// 本手势是否已提交(已提交后不再重复提交)。
    private(set) public var committed: Bool

    /// 累计翻页次数(本会话)。
    private(set) public var pageChanges: Int

    /// 累计水平位移。
    private(set) public var accumulatedDeltaX: CGFloat

    /// 累计垂直位移。
    private(set) public var accumulatedDeltaY: CGFloat

    public init(
        threshold: CGFloat = 16,
        horizontalDominance: CGFloat = 1.5
    ) {
        self.threshold = threshold
        self.horizontalDominance = horizontalDominance
        self.direction = 0
        self.committed = false
        self.pageChanges = 0
        self.accumulatedDeltaX = 0
        self.accumulatedDeltaY = 0
    }

    /// 是否有进行中的手势(未结束)。
    public var isActive: Bool { direction != 0 || accumulatedDeltaX != 0 || accumulatedDeltaY != 0 }

    /// 输入一个事件相位。
    ///
    /// - Returns: 本次输入是否提交了一次翻页(true = 恰好一页)。
    public mutating func feed(phase: Phase, deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        switch phase {
        case .began:
            resetAccumulator()
        case .changed:
            break
        case .ended, .cancelled:
            defer { resetAccumulator() }
            return false
        }
        // momentum 事件直接忽略(不累积, 不提交)
        return accumulate(deltaX: deltaX, deltaY: deltaY)
    }

    /// 带 momentum 标记的输入(惯性事件)。
    public mutating func feed(phase: Phase, deltaX: CGFloat, deltaY: CGFloat, isMomentum: Bool) -> Bool {
        guard !isMomentum else { return false }
        return feed(phase: phase, deltaX: deltaX, deltaY: deltaY)
    }

    /// 开始新手势(重置会话状态)。
    public mutating func reset() {
        resetAccumulator()
        committed = false
        pageChanges = 0
    }

    private mutating func resetAccumulator() {
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        direction = 0
    }

    private mutating func accumulate(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        accumulatedDeltaX += deltaX
        accumulatedDeltaY += deltaY

        guard !committed else { return false }
        // 水平主导判定(防轻微垂直抖动翻页)
        guard abs(accumulatedDeltaX) > abs(accumulatedDeltaY) * horizontalDominance else {
            return false
        }
        guard abs(accumulatedDeltaX) >= threshold else { return false }

        direction = accumulatedDeltaX < 0 ? 1 : -1
        committed = true
        pageChanges += 1
        return true
    }
}
