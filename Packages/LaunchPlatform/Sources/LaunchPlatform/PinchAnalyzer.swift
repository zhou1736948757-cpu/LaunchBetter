import Foundation
import CoreGraphics

/// 触点样本(跨线程安全, 纯数据)。
public struct ContactSample: Sendable, Equatable {
    /// 规范化位置(0.0-1.0, 左上原点)
    public let normalized: CGPoint
    /// 触控板上方还是接触表面
    public let isOnSurface: Bool

    public init(normalized: CGPoint, isOnSurface: Bool) {
        self.normalized = normalized
        self.isOnSurface = isOnSurface
    }
}

/// 捏合手势事件(与 UI/Store 解耦)。
public enum GestureEvent: Sendable, Equatable {
    case pinchIn
    case pinchOut
}

/// 四指捏合分析器(纯逻辑, 可确定性测试)。
///
/// 参数(§91 旧版经验, 需实测复核):
/// - 手指数 >= 4
/// - 相对距离变化阈值 ≈ 0.18
/// - 冷却 ≈ 0.2s
public struct PinchAnalyzer: Sendable {
    public let requiredFingerCount: Int
    public let threshold: Double
    public let cooldown: TimeInterval

    private var gestureActive = false
    private var startDistance: Double?
    private var lastEmittedAt: Date?

    public init(
        requiredFingerCount: Int = 4,
        threshold: Double = 0.18,
        cooldown: TimeInterval = 0.2
    ) {
        self.requiredFingerCount = requiredFingerCount
        self.threshold = threshold
        self.cooldown = cooldown
    }

    /// 处理一帧触点, 返回触发的事件(通常为空)。
    public mutating func process(
        contacts: [ContactSample],
        now: Date
    ) -> GestureEvent? {
        let onSurface = contacts.filter(\.isOnSurface)

        // 手指不足 → 重置手势状态
        guard onSurface.count >= requiredFingerCount else {
            reset()
            return nil
        }

        // 质心与平均距离
        let centroid = CGPoint(
            x: onSurface.map(\.normalized.x).reduce(0, +) / Double(onSurface.count),
            y: onSurface.map(\.normalized.y).reduce(0, +) / Double(onSurface.count)
        )
        let meanDistance = onSurface
            .map { contact in
                let dx = contact.normalized.x - centroid.x
                let dy = contact.normalized.y - centroid.y
                return (dx * dx + dy * dy).squareRoot()
            }
            .reduce(0, +) / Double(onSurface.count)

        // 手势起始
        if startDistance == nil {
            startDistance = meanDistance
            return nil
        }
        guard let start = startDistance, start > 0 else {
            reset()
            return nil
        }

        // 冷却
        if let last = lastEmittedAt, now.timeIntervalSince(last) < cooldown {
            return nil
        }

        let magnitude = (meanDistance - start) / start
        if magnitude > threshold {
            lastEmittedAt = now
            startDistance = meanDistance
            return .pinchOut
        }
        if magnitude < -threshold {
            lastEmittedAt = now
            startDistance = meanDistance
            return .pinchIn
        }
        return nil
    }

    private mutating func reset() {
        gestureActive = false
        startDistance = nil
    }
}
