import CoreGraphics
import Foundation

/// 时间驱动的临界阻尼弹簧(v0.1.6 §24-26)。纯数学, wall-clock 驱动,
/// 60Hz / 120Hz 时间响应一致。不基于 frame count。
///
/// 解: y(t) = (y0 + (v0 + ω·y0)·t) · exp(−ω·t); x(t) = target + y(t)
public struct PagingSpring: Sendable {
    public let target: CGFloat
    private let y0: CGFloat
    private let v0: CGFloat
    private let omega: CGFloat
    private let startTime: CFTimeInterval

    public init(
        startPosition: CGFloat,
        target: CGFloat,
        velocity: CGFloat,
        omega: CGFloat = PagingTuning.springOmega,
        startTime: CFTimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.target = target
        self.y0 = startPosition - target
        self.v0 = velocity
        self.omega = omega
        self.startTime = startTime
    }

    /// 在给定(绝对)时刻的位置。
    public func position(atTime t: CFTimeInterval) -> CGFloat {
        let dt = max(0, t - startTime)
        let expTerm = exp(-omega * dt)
        let y = (y0 + (v0 + omega * y0) * dt) * expTerm
        return target + y
    }

    /// 在给定(绝对)时刻的速度。
    public func velocity(atTime t: CFTimeInterval) -> CGFloat {
        let dt = max(0, t - startTime)
        let expTerm = exp(-omega * dt)
        // d/dt [ (y0 + a·t)·e^(−ωt) ], a = v0 + ω·y0
        let a = v0 + omega * y0
        let v = (a - omega * (y0 + a * dt)) * expTerm
        return v
    }

    /// 是否已收敛(位置与速度均低于容差)。
    public func isSettled(atTime t: CFTimeInterval) -> Bool {
        abs(position(atTime: t) - target) < PagingTuning.positionTolerance
            && abs(velocity(atTime: t)) < PagingTuning.velocityTolerance
    }
}

/// 外边缘 rubber band(v0.1.6 §18): 纯数学、连续、饱和、无 allocation。
/// 仅当 offset 越过 [minX, maxX] 边界时作用。
public enum PagingRubberBand {
    /// 对原始 offset 施加 rubber band。
    /// - Returns: 施加后位置。正常范围内恒等于输入(direct mapping)。
    public static func clamp(_ offset: CGFloat, minX: CGFloat, maxX: CGFloat) -> CGFloat {
        if offset < minX {
            let overflow = minX - offset
            let damped = overflow * PagingTuning.rubberBandStiffness
            return minX - damped
        } else if offset > maxX {
            let overflow = offset - maxX
            let damped = overflow * PagingTuning.rubberBandStiffness
            return maxX + damped
        }
        return offset
    }

    /// 施加后位置(含边界钳制版本, 用于 settle 目标落位)。
    public static func clampStrict(_ offset: CGFloat, minX: CGFloat, maxX: CGFloat) -> CGFloat {
        min(max(offset, minX), maxX)
    }
}
