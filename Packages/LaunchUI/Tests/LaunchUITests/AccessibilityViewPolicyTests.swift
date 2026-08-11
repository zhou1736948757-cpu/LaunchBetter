import AppKit
import Testing
@testable import LaunchUI

@Suite("Accessibility view policy seams")
struct AccessibilityViewPolicyTests {
    @Test("maps the three view combinations without changing motion policy")
    func mapsThreeViewCombinations() {
        let standard = AccessibilityMaterialPolicy(
            snapshot: MotionEnvironmentSnapshot(
                reduceMotion: false,
                reduceTransparency: false,
                increaseContrast: false
            )
        )
        let reducedTransparency = AccessibilityMaterialPolicy(
            snapshot: MotionEnvironmentSnapshot(
                reduceMotion: false,
                reduceTransparency: true,
                increaseContrast: false
            )
        )
        let increasedContrast = AccessibilityMaterialPolicy(
            snapshot: MotionEnvironmentSnapshot(
                reduceMotion: false,
                reduceTransparency: false,
                increaseContrast: true
            )
        )

        #expect(LauncherSurfaceAppearance.make(for: standard).surfaceTreatment == .translucent)
        #expect(
            LauncherSurfaceAppearance.make(for: reducedTransparency).surfaceTreatment == .opaque
        )
        #expect(
            SettingsButtonAppearance.make(for: increasedContrast).boundaryTreatment == .emphasized
        )
        #expect(
            FolderViewAppearance.make(for: increasedContrast).foregroundSeparation == .enhanced
        )
    }

    @Test("apply seams update material but preserve transition-owned opacity and shadow")
    @MainActor
    func applySeamsPreserveMotionValues() {
        let contrastPolicy = AccessibilityMaterialPolicy(
            snapshot: MotionEnvironmentSnapshot(
                reduceMotion: true,
                reduceTransparency: false,
                increaseContrast: true
            )
        )

        let surface = NSView()
        surface.wantsLayer = true
        LauncherSurfaceAppearance.apply(
            LauncherSurfaceAppearance.make(for: contrastPolicy),
            to: surface
        )
        #expect(surface.layer?.backgroundColor == nil)

        let card = NSVisualEffectView()
        card.wantsLayer = true
        card.layer?.shadowOpacity = 0.28
        let dimLayer = CALayer()
        dimLayer.opacity = 0.47
        FolderViewAppearance.apply(
            FolderViewAppearance.make(for: contrastPolicy),
            to: card,
            dimLayer: dimLayer
        )
        #expect(card.material == .hudWindow)
        #expect(card.layer?.borderWidth == 1)
        #expect(card.isEmphasized)
        #expect(card.layer?.shadowOpacity == 0.28)
        #expect(dimLayer.opacity == 0.47)

        let button = SettingsButton()
        button.layer?.shadowOpacity = 0.25
        let opaquePolicy = AccessibilityMaterialPolicy(
            snapshot: MotionEnvironmentSnapshot(
                reduceMotion: false,
                reduceTransparency: true,
                increaseContrast: true
            )
        )
        SettingsButtonAppearance.apply(
            SettingsButtonAppearance.make(for: opaquePolicy),
            to: button
        )
        #expect(button.layer?.backgroundColor != nil)
        #expect(button.layer?.borderWidth == 1.5)
        #expect(button.layer?.shadowOpacity == 0.25)
    }

    @Test("re-present route keeps existing Settings ownership wiring")
    func rePresentRouteIsIdempotent() {
        #expect(
            SettingsPresentationRoute.make(for: .settings) == .rePresentCurrent
        )
        #expect(
            SettingsPresentationRoute.make(for: .launcher) == .installOwnership
        )
        #expect(
            SettingsPresentationRoute.make(for: .folder) == .installOwnership
        )
    }

    @Test("re-present intent makes an in-flight dismiss completion stale")
    func rePresentInvalidatesDismissCompletion() {
        var lifecycle = SettingsTransitionLifecycle()
        let dismissToken = lifecycle.begin(.dismiss)
        let presentToken = lifecycle.begin(.present)

        let staleDismiss = lifecycle.complete(dismissToken)
        let completedPresent = lifecycle.complete(presentToken)
        #expect(!staleDismiss)
        #expect(completedPresent)
        #expect(lifecycle.state == .visible)
    }
}
