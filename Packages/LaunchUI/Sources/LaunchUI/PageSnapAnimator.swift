import Foundation
import LaunchCore
import QuartzCore

/// 页面吸附动画器(v0.1.6 §23-30): time-based 临界阻尼弹簧 + 打断防护。
/// 由 PagingInteractionController 在 SETTLING 阶段驱动; 唯一职责是 spring 采样与
/// stale 回写防护(token), 不直接写 scroll。
@MainActor
final class PageSnapAnimator {
    /// 每帧回调: (目标位置, 是否已收敛)。返回位置应被唯一 offset writer 应用。
    var onFrame: ((CGFloat, Bool) -> Void)?

    /// settle 收敛完成回调。
    var onSettled: (() -> Void)?

    private var spring: PagingSpring?
    private var generation = 0

    init() {}

    /// 开始一次 settle(打断上一次)。
    func start(startPosition: CGFloat, target: CGFloat, velocity: CGFloat) {
        generation += 1
        spring = PagingSpring(
            startPosition: startPosition, target: target, velocity: velocity
        )
    }

    /// 取消当前 settle(打断): 使任何在途采样结果失效, 不再回写。
    func cancel() {
        generation += 1
        spring = nil
    }

    /// 每 display frame 采样一次。返回 false 表示已收敛(调用方应停 link 并走 onSettled)。
    @discardableResult
    func tick() -> Bool {
        guard let spring else { return false }
        let gen = generation
        let now = CACurrentMediaTime()
        if spring.isSettled(atTime: now) {
            // stale 保护: 仅当未被新手势/新 settle 打断时才结算
            guard gen == generation else { return true }
            onFrame?(spring.target, true)
            onSettled?()
            self.spring = nil
            return false
        }
        guard gen == generation else { return true }
        onFrame?(spring.position(atTime: now), false)
        return true
    }

    var isActive: Bool { spring != nil }
}
