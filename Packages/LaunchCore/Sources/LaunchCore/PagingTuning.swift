import CoreGraphics
import Foundation

/// 分页交互调参(唯一参数集中点, Stage v0.1.6 PART A)。
/// 所有手感参数必须经过实机调整确认后才允许改动。
public enum PagingTuning {
    /// 手势起始"未定轴"阶段的最小累计位移(pt), 超过才判定 axis。
    public static let axisActivationThreshold: CGFloat = 6

    /// 水平主导倍率: |累计X| > |累计Y| × 该值 → 锁定水平。
    public static let horizontalDominance: CGFloat = 1.2

    /// 一次手势最多翻一页: 跟手位移钳制在 ±页宽。
    public static let maxGestureDisplacementPages: CGFloat = 1.0

    /// 跟手阻尼/灵敏度: 页面位移 = 手指位移 × 该系数。
    /// 1.0 = 1:1; >1 = 页面比手指移动更多(更轻松); <1 = 页面比手指慢(阻尼感强)。
    /// v0.1.10: 用户实测 0.85 偏费力 → 1.1(同样距离页面移动更多, 更轻松)。
    public static let followSensitivity: CGFloat = 1.1

    /// 松手吸附: 位移达到页宽的该比例即翻页。
    /// v0.1.10: 用户实机调参, 0.15 → 0.18(配合 followSensitivity 1.1 平衡误翻)。
    public static let displacementThreshold: CGFloat = 0.18

    /// 松手吸附: fling 最小方向性位移(页宽比例), 防止零位移误翻。
    public static let flingMinimumDisplacementPages: CGFloat = 0.12

    /// 松手吸附: fling 速度阈值(pt/s)。
    public static let flingVelocityThreshold: CGFloat = 900

    /// 速度 EMA 平滑系数(0~1, 越大越跟手)。
    public static let velocityEMAPerSecond: CGFloat = 12

    /// 弹簧角频率 ω(rad/s); 越小越慢越软。
    public static let springOmega: CGFloat = 14

    /// settle 结束: 位置误差阈值(pt)。
    public static let positionTolerance: CGFloat = 0.5

    /// settle 结束: 速度阈值(pt/s)。
    public static let velocityTolerance: CGFloat = 5

    /// 外边缘 rubber band 刚度(越大约硬)。
    public static let rubberBandStiffness: CGFloat = 0.18

    /// rubber band 最大外溢(页宽比例)。
    public static let rubberBandMaxOverflowPages: CGFloat = 0.12
}

/// 分页手势状态机(idle / tracking / settling)。
/// 纯逻辑, 与 AppKit 解耦, 可测试。
public enum PagingPhase: Sendable, Equatable {
    case idle
    case tracking
    case settling
}

/// 手势轴锁状态: idle → undecided → horizontal(锁定直到手势结束)。
public enum PagingAxisState: Sendable, Equatable {
    case idle
    case undecided
    case horizontal
}
