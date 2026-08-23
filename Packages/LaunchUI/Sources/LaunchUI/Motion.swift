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
    static let pressScale: CGFloat = 0.95

    /// 标题按压反馈幅度(克制)。
    static let titlePressScale: CGFloat = 0.98
}

/// 单个 spring 规格(response/dampingRatio 命名, 与 apple-design 一致)。
struct MotionSpringSpec: Equatable {
    let response: TimeInterval
    let dampingRatio: CGFloat
}

/// 一次动效决策使用的无障碍环境快照。
///
/// 读取在过渡开始时完成；逐帧动画只消费这个值，不在 display frame 中访问
/// NSWorkspace。测试可以直接构造快照，而产品代码仍通过 `liveSnapshot()` 实时读取。
struct MotionEnvironmentSnapshot: Equatable, Sendable {
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increaseContrast: Bool
}

/// Launcher M1/M2 的纯动效策略。
///
/// 背景只改变 alpha，前景 surface 才有克制的 0.985 → 1 缩放。Reduce Motion
/// 时两端 scale 都固定为 1，因此策略只留下短淡入淡出；material/contrast
/// 的具体视觉实现留给后续阶段。
struct LauncherMotionPolicy: Equatable, Sendable {
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let increaseContrast: Bool
    let materialPolicy: AccessibilityMaterialPolicy
    let duration: TimeInterval

    let hiddenSurfaceScale: CGFloat
    let visibleSurfaceScale: CGFloat
    let hiddenSurfaceOpacity: Float
    let visibleSurfaceOpacity: Float
    let hiddenBackgroundOpacity: Float
    let visibleBackgroundOpacity: Float
    let hiddenDimOpacity: Float
    let visibleDimOpacity: Float

    var animatesSurfaceScale: Bool {
        !reduceMotion
    }

    init(snapshot: MotionEnvironmentSnapshot) {
        reduceMotion = snapshot.reduceMotion
        reduceTransparency = snapshot.reduceTransparency
        increaseContrast = snapshot.increaseContrast
        materialPolicy = AccessibilityMaterialPolicy(snapshot: snapshot)
        duration = snapshot.reduceMotion
            ? MotionEnvironment.reducedFadeDuration
            : MotionEnvironment.standardFadeDuration

        hiddenSurfaceScale = snapshot.reduceMotion ? 1 : 0.985
        visibleSurfaceScale = 1
        hiddenSurfaceOpacity = 0
        visibleSurfaceOpacity = 1
        hiddenBackgroundOpacity = 0
        visibleBackgroundOpacity = 1
        hiddenDimOpacity = 0
        visibleDimOpacity = 1
    }

    func presentation(for intent: LauncherTransitionIntent) -> LauncherTransitionPresentation {
        switch intent {
        case .show:
            return LauncherTransitionPresentation(
                surfaceScale: visibleSurfaceScale,
                surfaceOpacity: visibleSurfaceOpacity,
                backgroundOpacity: visibleBackgroundOpacity,
                dimOpacity: visibleDimOpacity
            )
        case .hide:
            return LauncherTransitionPresentation(
                surfaceScale: hiddenSurfaceScale,
                surfaceOpacity: hiddenSurfaceOpacity,
                backgroundOpacity: hiddenBackgroundOpacity,
                dimOpacity: hiddenDimOpacity
            )
        }
    }
}

/// 系统无障碍动效环境(随系统设置实时变化)。
enum MotionEnvironment {
    /// 每次访问都从系统读取，不能缓存为进程级常量。
    @MainActor
    static func liveSnapshot() -> MotionEnvironmentSnapshot {
        MotionEnvironmentSnapshot(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
    }

    /// 测试和过渡入口使用的策略工厂；不会读取系统状态。
    static func policy(for snapshot: MotionEnvironmentSnapshot) -> LauncherMotionPolicy {
        LauncherMotionPolicy(snapshot: snapshot)
    }

    /// 过渡开始时取得一次实时快照。
    @MainActor
    static var launcherPolicy: LauncherMotionPolicy {
        policy(for: liveSnapshot())
    }

    /// Reduce Motion 读取(L5): 每次访问 3 次 NSWorkspace 查询。reload/过渡级
    /// 入口应读取一次快照并在逐 cell 配置中复用(如 AppLibraryViewController 的
    /// reloadReduceMotion 缓存); 不要在 per-cell / display frame 热路径重复调用。
    @MainActor
    static var reduceMotion: Bool {
        liveSnapshot().reduceMotion
    }

    @MainActor
    static var reduceTransparency: Bool {
        liveSnapshot().reduceTransparency
    }

    @MainActor
    static var increaseContrast: Bool {
        liveSnapshot().increaseContrast
    }

    /// Reduce Motion 下的短淡入淡出时长(保留反馈, 不做大位移)。
    static var reducedFadeDuration: TimeInterval { 0.08 }
    static var standardFadeDuration: TimeInterval { 0.12 }

    @MainActor
    static var launcherFadeDuration: TimeInterval {
        reduceMotion ? reducedFadeDuration : standardFadeDuration
    }

    /// 无障碍显示选项变化通知(Register once in a central place)。
    static let displayOptionsDidChange = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
}
