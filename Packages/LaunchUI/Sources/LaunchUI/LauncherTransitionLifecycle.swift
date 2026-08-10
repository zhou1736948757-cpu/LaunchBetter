import AppKit

/// 启动器视觉过渡生命周期(纯逻辑, 无 AppKit 动画依赖, 可单测)。
///
/// 防止 stale completion 破坏更新的过渡:
/// - hide() 启动 dismiss, show() 立刻重开时, 旧的 dismiss completion 不得 orderOut。
/// - show() 启动 present, 立即 dismiss 时, 旧的 present completion 不得标记 visible。
///
/// generation 每次 begin* 递增; completion 只有携带当前 generation 才生效。
struct LauncherTransitionLifecycle: Equatable {
    enum State: Equatable {
        case hidden
        case presenting
        case visible
        case dismissing
    }

    private(set) var state: State = .hidden
    private var generation = 0

    /// 开始呈现。返回本次过渡的 generation 令牌。
    mutating func beginShow() -> Int {
        generation += 1
        state = .presenting
        return generation
    }

    /// 开始解散。返回本次过渡的 generation 令牌。
    mutating func beginHide() -> Int {
        generation += 1
        state = .dismissing
        return generation
    }

    /// 呈现完成。令牌过期则忽略(不覆盖更新的状态)。
    @discardableResult
    mutating func completeShow(_ token: Int) -> Bool {
        guard token == generation else { return false }
        state = .visible
        return true
    }

    /// 解散完成。令牌过期则忽略(不允许过期 orderOut)。
    @discardableResult
    mutating func completeHide(_ token: Int) -> Bool {
        guard token == generation else { return false }
        state = .hidden
        return true
    }

    var isTransitioning: Bool {
        state == .presenting || state == .dismissing
    }
}
