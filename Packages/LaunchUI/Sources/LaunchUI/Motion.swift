import AppKit
import QuartzCore

/// 语义化动效令牌(单一定义, 禁止散落 duration/scale 魔法数)。
///
/// 对应 apple-design 的 response(秒, 越低越跟手)与 dampingRatio(1.0 临界阻尼无过冲,
/// <1.0 有过冲, 仅在动量驱动时使用)。
enum MotionTokens {
    /// 微反馈(按压/恢复)。
    static let pressFeedback = MotionSpringSpec(response: 0.12, dampingRatio: 1.0)

    /// 非动量面板呈现/解散(克制, 临界阻尼, 不过冲)。
    static let standardPresentation = MotionSpringSpec(response: 0.30, dampingRatio: 1.0)
    static let standardDismissal = MotionSpringSpec(response: 0.26, dampingRatio: 1.0)

    /// 空间过渡(Folder 从源缩放到目标)。
    static let spatialPresentation = MotionSpringSpec(response: 0.36, dampingRatio: 1.0)
    static let spatialDismissal = MotionSpringSpec(response: 0.30, dampingRatio: 1.0)

    /// 动量 settle(轻微过冲, 仅在真实手势动量之后)。
    static let momentumSettle = MotionSpringSpec(response: 0.40, dampingRatio: 0.8)

    /// 按压反馈幅度。
    static let pressScale: CGFloat = 0.97

    /// 标题按压反馈幅度(克制)。
    static let titlePressScale: CGFloat = 0.98
}

/// 单个 spring 规格(response/dampingRatio 命名, 与 apple-design 一致)。
struct MotionSpringSpec: Equatable {
    let response: TimeInterval
    let dampingRatio: CGFloat
}

/// 系统无障碍动效环境(随系统设置实时变化)。
enum MotionEnvironment {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Reduce Motion 下的短淡入淡出时长(保留反馈, 不做大位移)。
    static var reducedFadeDuration: TimeInterval { 0.08 }
    static var standardFadeDuration: TimeInterval { 0.12 }

    static var launcherFadeDuration: TimeInterval {
        reduceMotion ? reducedFadeDuration : standardFadeDuration
    }

    /// 无障碍显示选项变化通知(Register once in a central place)。
    static let displayOptionsDidChange = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
}
