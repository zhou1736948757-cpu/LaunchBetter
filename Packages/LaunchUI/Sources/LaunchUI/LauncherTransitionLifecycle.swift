import AppKit

/// 启动器视觉过渡生命周期(纯逻辑, 无 AppKit 动画依赖, 可单测)。
///
/// 防止 stale completion 破坏更新的过渡:
/// - hide() 启动 dismiss, show() 立刻重开时, 旧的 dismiss completion 不得 orderOut。
/// - show() 启动 present, 立即 dismiss 时, 旧的 present completion 不得标记 visible。
///
/// generation 每次 begin* 递增。completion 必须同时携带当前 token 和它期待
/// 完成时仍处于的 state，并且每个 token 只能成功一次。
struct LauncherTransitionLifecycle: Equatable {
    enum State: Equatable, Sendable {
        case hidden
        case presenting
        case visible
        case dismissing
    }

    struct Token: Equatable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let expectedState: State
    }

    private(set) var state: State = .hidden
    private var generation: UInt64 = 0
    private var completedGeneration: UInt64?

    /// 开始呈现。返回本次过渡的 generation 令牌。
    mutating func beginShow() -> Token {
        generation &+= 1
        state = .presenting
        completedGeneration = nil
        return Token(generation: generation, expectedState: .presenting)
    }

    /// 开始解散。返回本次过渡的 generation 令牌。
    mutating func beginHide() -> Token {
        generation &+= 1
        state = .dismissing
        completedGeneration = nil
        return Token(generation: generation, expectedState: .dismissing)
    }

    /// 呈现完成。令牌、期待状态或一次性约束不满足时忽略。
    @discardableResult
    mutating func completeShow(_ token: Token, expectedState: State) -> Bool {
        guard canComplete(token, expectedState: expectedState, requiredState: .presenting) else {
            return false
        }
        state = .visible
        completedGeneration = token.generation
        return true
    }

    /// 解散完成。令牌、期待状态或一次性约束不满足时忽略。
    @discardableResult
    mutating func completeHide(_ token: Token, expectedState: State) -> Bool {
        guard canComplete(token, expectedState: expectedState, requiredState: .dismissing) else {
            return false
        }
        state = .hidden
        completedGeneration = token.generation
        return true
    }

    private func canComplete(
        _ token: Token,
        expectedState: State,
        requiredState: State
    ) -> Bool {
        token.generation == generation
            && token.expectedState == expectedState
            && expectedState == requiredState
            && state == expectedState
            && completedGeneration != token.generation
    }

    var isTransitioning: Bool {
        state == .presenting || state == .dismissing
    }
}
