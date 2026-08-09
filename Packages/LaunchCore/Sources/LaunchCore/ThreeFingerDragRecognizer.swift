import CoreGraphics
import Foundation

/// 三指拖动识别调参(唯一参数集中点, Stage 2)。
/// 数值对齐 legacy LaunchHistory 源码证据(MultitouchGestureRecognizer.swift):
/// - minTranslation 0.005(归一化坐标)
/// - pinchTolerance 0.15(半径相对变化)
/// - confirmFrames 2(连续确认帧)
public enum ThreeFingerTuning {
    /// 手指数(严格 3 才进入拖动判定)。
    public static let fingerCount = 3

    /// 平移最小位移(归一化坐标): 质心相对起始位移 ≥ 该值才算平移。
    public static let minTranslation: CGFloat = 0.005

    /// 捏合容忍: 平均半径相对起始变化 > 该值视为捏合(非平移), 忽略/结束拖动。
    public static let pinchTolerance: CGFloat = 0.15

    /// 连续确认帧数: 达标帧数 ≥ 该值才正式 began(防误触)。
    public static let confirmFrames = 2
}

/// 三指拖动手势事件(UI 层消费; 位置由 UI 层用指针/鼠标位置决定, 与旧行为一致)。
public enum ThreeFingerGestureEvent: Sendable, Equatable {
    case began
    case changed
    case ended
}

/// 三指拖动识别状态机(Stage 2, 纯逻辑可测试)。
///
/// 对齐 legacy LaunchHistory 语义:
/// - 仅当活跃指 == 3 进入判定; 手指数变化为非 3 立即 ended
/// - 平移(质心位移达标)且非捏合(半径变化小)→ 连续确认 confirmFrames 帧后 began
/// - 拖动中检测到明显捏合 → ended
///
/// 输入为活跃触点归一化坐标数组(0.0-1.0), 不依赖 AppKit / 私有框架。
public struct ThreeFingerDragRecognizer: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle
        case confirming
        case dragging
    }

    private(set) public var phase: Phase = .idle

    private var startCentroid: CGPoint = .zero
    private var startAvgRadius: CGFloat = 0
    private var confirmCount = 0

    public init() {}

    /// 处理一帧活跃触点(归一化坐标)。
    /// - Returns: 本帧产生的手势事件(可能为 nil)。
    public mutating func process(points: [CGPoint]) -> ThreeFingerGestureEvent? {
        // 仅当正好 3 指时维持判定; 非 3 指(含 4 指捏合起手)一律立即结束
        guard points.count == ThreeFingerTuning.fingerCount else {
            defer { reset() }
            return phase == .dragging ? .ended : nil
        }

        let c = centroid(points)
        let avgR = averageRadius(points, centroid: c)

        // 已 began: 持续更新
        if phase == .dragging {
            let radiusChange = startAvgRadius > 0.001
                ? abs(avgR - startAvgRadius) / startAvgRadius
                : 0
            // 拖动中明显捏合 → 视为意图捏合, 立即结束
            if radiusChange > ThreeFingerTuning.pinchTolerance {
                reset()
                return .ended
            }
            return .changed
        }

        // 未 began: 累积确认帧
        if phase == .idle {
            startCentroid = c
            startAvgRadius = avgR
            confirmCount = 0
            phase = .confirming
            return nil
        }

        // confirming
        let dx = c.x - startCentroid.x
        let dy = c.y - startCentroid.y
        let translation = (dx * dx + dy * dy).squareRoot()
        let radiusChange = startAvgRadius > 0.001
            ? abs(avgR - startAvgRadius) / startAvgRadius
            : 0

        let isPan = translation >= ThreeFingerTuning.minTranslation
        let isPinch = radiusChange > ThreeFingerTuning.pinchTolerance

        if isPan && !isPinch {
            confirmCount += 1
            if confirmCount >= ThreeFingerTuning.confirmFrames {
                phase = .dragging
                confirmCount = 0
                return .began
            }
        } else if isPinch {
            // 捏合倾向明显 → 直接放弃(可能发展为四指捏合)
            confirmCount = 0
        }
        return nil
    }

    /// 复位(手指数异常 / 结束 / 取消)。
    public mutating func reset() {
        phase = .idle
        startCentroid = .zero
        startAvgRadius = 0
        confirmCount = 0
    }

    private func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func averageRadius(_ points: [CGPoint], centroid c: CGPoint) -> CGFloat {
        guard !points.isEmpty else { return 0 }
        let sum = points.reduce(CGFloat(0)) {
            let dx = $1.x - c.x, dy = $1.y - c.y
            return $0 + (dx * dx + dy * dy).squareRoot()
        }
        return sum / CGFloat(points.count)
    }
}
