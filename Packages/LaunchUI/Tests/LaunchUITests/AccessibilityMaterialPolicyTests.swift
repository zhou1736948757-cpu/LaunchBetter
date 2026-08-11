import Testing
@testable import LaunchUI

@Suite("Accessibility material policy")
struct AccessibilityMaterialPolicyTests {
    @Test("maps every combination of the three display options")
    func mapsEveryDisplayOptionCombination() {
        for reduceMotion in [false, true] {
            for reduceTransparency in [false, true] {
                for increaseContrast in [false, true] {
                    let snapshot = MotionEnvironmentSnapshot(
                        reduceMotion: reduceMotion,
                        reduceTransparency: reduceTransparency,
                        increaseContrast: increaseContrast
                    )
                    let policy = AccessibilityMaterialPolicy(snapshot: snapshot)

                    if reduceTransparency {
                        #expect(policy.surfaceTreatment == .opaque)
                        #expect(policy.blurTreatment == .avoided)
                        #expect(policy.surfaceOpacity > 0.9)
                    } else {
                        #expect(policy.surfaceTreatment == .translucent)
                        #expect(policy.blurTreatment == .allowed)
                        #expect(policy.surfaceOpacity < 0.9)
                    }

                    if increaseContrast {
                        #expect(policy.boundaryTreatment == .emphasized)
                        #expect(policy.foregroundSeparation == .enhanced)
                    } else {
                        #expect(policy.boundaryTreatment == .standard)
                        #expect(policy.foregroundSeparation == .standard)
                    }

                    #expect(policy.shadowTreatment == .preserveExistingWeight)
                }
            }
        }
    }

    @Test("launcher policy exposes the pure material policy")
    func launcherPolicyExposesMaterialPolicy() {
        let snapshot = MotionEnvironmentSnapshot(
            reduceMotion: false,
            reduceTransparency: true,
            increaseContrast: true
        )
        let policy = MotionEnvironment.policy(for: snapshot)

        #expect(policy.materialPolicy == AccessibilityMaterialPolicy(snapshot: snapshot))
        #expect(policy.materialPolicy.usesOpaqueSurface)
        #expect(policy.materialPolicy.avoidsBlur)
        #expect(policy.materialPolicy.emphasizesBoundary)
        #expect(policy.materialPolicy.enhancesForegroundSeparation)
    }

    @Test("reduce motion still removes scale while material remains deterministic")
    func reduceMotionRemovesScale() {
        let policy = MotionEnvironment.policy(
            for: MotionEnvironmentSnapshot(
                reduceMotion: true,
                reduceTransparency: false,
                increaseContrast: false
            )
        )

        #expect(!policy.animatesSurfaceScale)
        #expect(policy.hiddenSurfaceScale == 1)
        #expect(policy.materialPolicy.surfaceTreatment == .translucent)
    }
}
