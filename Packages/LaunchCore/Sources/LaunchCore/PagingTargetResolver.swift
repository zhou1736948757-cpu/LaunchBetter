import CoreGraphics
import Foundation

/// O(1) 速度估计(EMA, v0.1.6 §9)。只保留 lastTimestamp + estimatedVelocity。
/// 仅用于 release decision 与 spring 初速, 不做历史数组。
public struct PagingVelocityEstimator: Sendable {
    private(set) public var estimatedVelocity: CGFloat = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var lastPosition: CGFloat = 0
    private var hasPrevious = false

    public init() {}

    /// 输入位移增量与时间戳; 返回当前估计速度(pt/s)。
    public mutating func update(position: CGFloat, timestamp: CFTimeInterval) -> CGFloat {
        if hasPrevious {
            let dt = timestamp - lastTimestamp
            if dt > 0 {
                let instant = (position - lastPosition) / CGFloat(dt)
                // EMA: 平滑系数按每事件调整(接近每帧一次的事件率)
                let alpha = 1 - exp(-CGFloat(PagingTuning.velocityEMAPerSecond) * CGFloat(dt))
                estimatedVelocity += alpha * (instant - estimatedVelocity)
            }
        }
        lastPosition = position
        lastTimestamp = timestamp
        hasPrevious = true
        return estimatedVelocity
    }

    /// 手势开始: 重置。
    public mutating func reset() {
        estimatedVelocity = 0
        lastTimestamp = 0
        lastPosition = 0
        hasPrevious = false
    }
}

/// 松手目标解析(v0.1.6 §21-22): 位移 + 速度 → 目标页。
/// 纯逻辑, 可测试。
public enum PagingTargetResolver {
    /// 解析目标页。
    /// - Parameters:
    ///   - currentPage: 手势起始页
    ///   - pageCount: 总页数
    ///   - pageWidth: 页宽(pt)
    ///   - displacement: 手势累计位移(像素, 左滑为负 → 目标向右)
    ///   - releaseVelocity: 松手速度(pt/s, 与位移同向)
    public static func resolve(
        currentPage: Int,
        pageCount: Int,
        pageWidth: CGFloat,
        displacement: CGFloat,
        releaseVelocity: CGFloat
    ) -> Int {
        let pageCount = max(1, pageCount)
        let displacementPages = displacement / max(1, pageWidth)
        var target = currentPage
        if abs(displacementPages) >= PagingTuning.displacementThreshold {
            target = currentPage + (displacement < 0 ? 1 : -1)
        } else if abs(displacementPages) >= PagingTuning.flingMinimumDisplacementPages,
                  abs(releaseVelocity) >= PagingTuning.flingVelocityThreshold {
            target = currentPage + (releaseVelocity < 0 ? 1 : -1)
        }
        return min(max(0, target), pageCount - 1)
    }
}
