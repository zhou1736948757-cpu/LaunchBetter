import CoreGraphics
import Foundation

/// 轴锁状态机(v0.1.6 §7): idle → undecided → horizontal。
/// undecided 期间按累计位移判定水平主导; 一旦锁定 horizontal, 直到 ended 不再退出。
public struct PagingAxisLock: Sendable, Equatable {
    private(set) public var state: PagingAxisState = .idle

    public init() {}

    /// 手势开始: 进入 undecided, 清累计。
    public mutating func began() {
        state = .undecided
        accumulatedX = 0
        accumulatedY = 0
    }

    /// 手势结束/取消: 回 idle。
    public mutating func ended() {
        state = .idle
        accumulatedX = 0
        accumulatedY = 0
    }

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0

    /// 输入一个增量(像素单位, 已含系统滚动方向语义)。
    /// - Returns: 当前是否水平锁定。
    public mutating func accumulate(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        switch state {
        case .idle:
            return false
        case .undecided:
            accumulatedX += deltaX
            accumulatedY += deltaY
            let totalX = abs(accumulatedX)
            let totalY = abs(accumulatedY)
            if totalX > PagingTuning.axisActivationThreshold,
               totalX > totalY * PagingTuning.horizontalDominance {
                state = .horizontal
            }
            return state == .horizontal
        case .horizontal:
            // 已锁定: 不再重新判定(单帧 dy 突然大于 dx 不退出水平)
            return true
        }
    }

    public var isHorizontal: Bool { state == .horizontal }
}
