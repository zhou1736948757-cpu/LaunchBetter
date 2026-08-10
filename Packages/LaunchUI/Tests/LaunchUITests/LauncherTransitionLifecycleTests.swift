import Testing
@testable import LaunchUI

@Suite("Launcher transition lifecycle")
struct LauncherTransitionLifecycleTests {
    @Test("show completes to visible")
    func showCompletesToVisible() {
        var lifecycle = LauncherTransitionLifecycle()
        let token = lifecycle.beginShow()
        #expect(lifecycle.state == .presenting)
        let completed = lifecycle.completeShow(token)
        #expect(completed)
        #expect(lifecycle.state == .visible)
    }

    @Test("hide completes to hidden")
    func hideCompletesToHidden() {
        var lifecycle = LauncherTransitionLifecycle()
        let token = lifecycle.beginHide()
        #expect(lifecycle.state == .dismissing)
        let completed = lifecycle.completeHide(token)
        #expect(completed)
        #expect(lifecycle.state == .hidden)
    }

    @Test("stale hide completion cannot fire after a newer show")
    func staleHideCompletionRejectedAfterReopen() {
        var lifecycle = LauncherTransitionLifecycle()
        let hideToken = lifecycle.beginHide()
        _ = lifecycle.beginShow() // user reopens during dismissal
        // Old hide completion must be ignored: no orderOut of the reopened window.
        let staleRejected = lifecycle.completeHide(hideToken)
        #expect(staleRejected == false)
        #expect(lifecycle.state == .presenting)
    }

    @Test("stale show completion cannot mark visible after a newer hide")
    func staleShowCompletionRejectedAfterHide() {
        var lifecycle = LauncherTransitionLifecycle()
        let showToken = lifecycle.beginShow()
        _ = lifecycle.beginHide() // user dismisses during presentation
        let staleRejected = lifecycle.completeShow(showToken)
        #expect(staleRejected == false)
        #expect(lifecycle.state == .dismissing)
    }

    @Test("repeated begin increments generation so earlier tokens stale")
    func repeatedBeginInvalidatesEarlierTokens() {
        var lifecycle = LauncherTransitionLifecycle()
        let first = lifecycle.beginShow()
        let second = lifecycle.beginHide()
        #expect(lifecycle.completeShow(first) == false)
        #expect(lifecycle.completeHide(first) == false)
        let completed = lifecycle.completeHide(second)
        #expect(completed)
        #expect(lifecycle.state == .hidden)
    }
}
