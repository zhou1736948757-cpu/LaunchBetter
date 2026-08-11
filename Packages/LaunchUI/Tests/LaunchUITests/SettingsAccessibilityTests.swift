import AppKit
import Testing
@testable import LaunchUI

@Suite("Settings accessibility surface")
struct SettingsAccessibilityTests {
    @Test("normal mode preserves the existing HUD window appearance")
    func normalModePreservesHudWindow() {
        let appearance = SettingsAccessibilityAppearance.make(
            for: MotionEnvironmentSnapshot(
                reduceMotion: false,
                reduceTransparency: false,
                increaseContrast: false
            )
        )

        #expect(appearance.material == .hudWindow)
        #expect(appearance.blendingMode == .behindWindow)
        #expect(appearance.surfaceFill == .existingHudWindow)
        #expect(appearance.boundary == .standard)
        #expect(appearance.foregroundSeparation == .standard)
    }

    @Test("Reduce Transparency selects an opaque dark within-window surface")
    func reduceTransparencyUsesOpaqueSurface() {
        let appearance = SettingsAccessibilityAppearance.make(
            for: MotionEnvironmentSnapshot(
                reduceMotion: false,
                reduceTransparency: true,
                increaseContrast: false
            )
        )

        #expect(appearance.material == .opaqueDark)
        #expect(appearance.blendingMode == .withinWindow)
        #expect(appearance.surfaceFill == .explicitDark)
    }

    @Test("Increase Contrast emphasizes boundary and foreground without shadow policy")
    func increaseContrastSeparatesForeground() {
        let appearance = SettingsAccessibilityAppearance.make(
            for: MotionEnvironmentSnapshot(
                reduceMotion: false,
                reduceTransparency: false,
                increaseContrast: true
            )
        )

        #expect(appearance.material == .hudWindow)
        #expect(appearance.blendingMode == .behindWindow)
        #expect(appearance.boundary == .emphasized)
        #expect(appearance.foregroundSeparation == .enhanced)
    }

    @Test("AppKit apply seam updates surface and resets it without touching window motion")
    @MainActor
    func appKitApplySeam() {
        let effect = NSVisualEffectView()
        let opaqueContrast = SettingsAccessibilityAppearance.make(
            for: MotionEnvironmentSnapshot(
                reduceMotion: true,
                reduceTransparency: true,
                increaseContrast: true
            )
        )
        SettingsAccessibilityAppearance.apply(opaqueContrast, to: effect)

        #expect(effect.material == .windowBackground)
        #expect(effect.blendingMode == .withinWindow)
        #expect(effect.isEmphasized)
        #expect(effect.layer?.backgroundColor != nil)
        #expect(effect.layer?.borderWidth == 1)

        let normal = SettingsAccessibilityAppearance.make(
            for: MotionEnvironmentSnapshot(
                reduceMotion: false,
                reduceTransparency: false,
                increaseContrast: false
            )
        )
        SettingsAccessibilityAppearance.apply(normal, to: effect)

        #expect(effect.material == .hudWindow)
        #expect(effect.blendingMode == .behindWindow)
        #expect(!effect.isEmphasized)
        #expect(effect.layer?.backgroundColor == nil)
        #expect(effect.layer?.borderWidth == 0)
    }
}
