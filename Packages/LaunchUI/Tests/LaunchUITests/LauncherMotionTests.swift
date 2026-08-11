import Testing
@testable import LaunchUI

@Suite("Launcher motion policy")
struct LauncherMotionTests {
    @Test("standard policy keeps background stable and uses restrained surface scale")
    func standardPolicy() {
        let snapshot = MotionEnvironmentSnapshot(
            reduceMotion: false,
            reduceTransparency: false,
            increaseContrast: false
        )
        let policy = MotionEnvironment.policy(for: snapshot)

        #expect(policy.animatesSurfaceScale)
        #expect(policy.hiddenSurfaceScale == 0.985)
        #expect(policy.visibleSurfaceScale == 1)
        #expect(policy.hiddenBackgroundOpacity == 0)
        #expect(policy.visibleBackgroundOpacity == 1)
        #expect(policy.duration == MotionEnvironment.standardFadeDuration)
    }

    @Test("reduce motion removes scale and preserves only the short fade")
    func reduceMotionIsFadeOnly() {
        let policy = MotionEnvironment.policy(
            for: MotionEnvironmentSnapshot(
                reduceMotion: true,
                reduceTransparency: true,
                increaseContrast: true
            )
        )
        let current = LauncherTransitionPresentation(
            surfaceScale: 0.991,
            surfaceOpacity: 0.45,
            backgroundOpacity: 0.45,
            dimOpacity: 0.45
        )
        let plan = LauncherTransitionPlan(intent: .show, from: current, policy: policy)

        #expect(!policy.animatesSurfaceScale)
        #expect(policy.hiddenSurfaceScale == 1)
        #expect(plan.from.surfaceScale == 1)
        #expect(plan.to.surfaceScale == 1)
        #expect(plan.duration == MotionEnvironment.reducedFadeDuration)
        #expect(policy.reduceTransparency)
        #expect(policy.increaseContrast)
    }

    @Test("interruption plans retain the current presentation as their start")
    func interruptionUsesCurrentPresentation() {
        let policy = MotionEnvironment.policy(
            for: MotionEnvironmentSnapshot(
                reduceMotion: false,
                reduceTransparency: false,
                increaseContrast: false
            )
        )
        let current = LauncherTransitionPresentation(
            surfaceScale: 0.993,
            surfaceOpacity: 0.58,
            backgroundOpacity: 0.61,
            dimOpacity: 0.60
        )

        let hidePlan = LauncherTransitionPlan(intent: .hide, from: current, policy: policy)
        #expect(hidePlan.from == current)
        #expect(hidePlan.to == policy.presentation(for: .hide))

        let showPlan = LauncherTransitionPlan(intent: .show, from: current, policy: policy)
        #expect(showPlan.from == current)
        #expect(showPlan.to == policy.presentation(for: .show))
    }
}
