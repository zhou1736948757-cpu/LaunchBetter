import AppKit
import Testing
@testable import LaunchUI

@Suite("Settings transition policy")
struct SettingsTransitionTests {
    @Test("fresh Settings placement matches the launcher screenshot ratios")
    func freshPlacementMatchesLauncherRatios() {
        let launcher = NSRect(x: 100, y: 200, width: 1_000, height: 800)
        let settingsSize = NSSize(width: 400, height: 300)
        let visibleFrame = NSRect(x: 0, y: 0, width: 2_000, height: 1_500)

        let frame = SettingsWindowPlacement.frame(
            launcherFrame: launcher,
            settingsSize: settingsSize,
            visibleFrame: visibleFrame
        )

        #expect(frame.midX == launcher.minX + launcher.width * 0.70)
        #expect(frame.midY == launcher.minY + launcher.height * 0.52)
        #expect(frame.size == settingsSize)
    }

    @Test("placement respects non-zero and negative screen origins")
    func placementRespectsScreenOrigins() {
        let launcher = NSRect(x: -1_700, y: 250, width: 900, height: 700)
        let settingsSize = NSSize(width: 500, height: 400)
        let visibleFrame = NSRect(x: -1_920, y: 120, width: 1_920, height: 1_000)

        let frame = SettingsWindowPlacement.frame(
            launcherFrame: launcher,
            settingsSize: settingsSize,
            visibleFrame: visibleFrame
        )

        #expect(frame.midX == launcher.minX + launcher.width * 0.70)
        #expect(frame.midY == launcher.minY + launcher.height * 0.52)
        #expect(frame.minX >= visibleFrame.minX)
        #expect(frame.maxX <= visibleFrame.maxX)
        #expect(frame.minY >= visibleFrame.minY)
        #expect(frame.maxY <= visibleFrame.maxY)
    }

    @Test(
        "placement clamps independently to every visible edge",
        arguments: [
            (
                NSRect(x: -500, y: 398, width: 100, height: 100),
                NSPoint(x: 100, y: 300)
            ),
            (
                NSRect(x: 1_900, y: 398, width: 100, height: 100),
                NSPoint(x: 1_500, y: 300)
            ),
            (
                NSRect(x: 630, y: -500, width: 100, height: 100),
                NSPoint(x: 500, y: 200)
            ),
            (
                NSRect(x: 630, y: 1_500, width: 100, height: 100),
                NSPoint(x: 500, y: 700)
            ),
        ]
    )
    func placementClampsToEachVisibleEdge(
        launcher: NSRect,
        expectedOrigin: NSPoint
    ) {
        let frame = SettingsWindowPlacement.frame(
            launcherFrame: launcher,
            settingsSize: NSSize(width: 400, height: 300),
            visibleFrame: NSRect(x: 100, y: 200, width: 1_800, height: 800)
        )

        #expect(frame.origin == expectedOrigin)
    }

    @Test("oversized Settings keeps its size and aligns to the visible minimum")
    func oversizedPlacementPreservesSize() {
        let settingsSize = NSSize(width: 1_200, height: 900)
        let visibleFrame = NSRect(x: -800, y: 140, width: 1_000, height: 700)

        let frame = SettingsWindowPlacement.frame(
            launcherFrame: NSRect(x: -700, y: 200, width: 800, height: 600),
            settingsSize: settingsSize,
            visibleFrame: visibleFrame
        )

        #expect(frame.origin == visibleFrame.origin)
        #expect(frame.size == settingsSize)
        #expect(frame.origin.x.isFinite)
        #expect(frame.origin.y.isFinite)
    }

    @Test("only a hidden transition receives automatic placement")
    func onlyFreshPresentationPositionsWindow() {
        #expect(SettingsWindowPlacement.shouldPosition(for: .hidden))
        #expect(!SettingsWindowPlacement.shouldPosition(for: .presenting))
        #expect(!SettingsWindowPlacement.shouldPosition(for: .visible))
        #expect(!SettingsWindowPlacement.shouldPosition(for: .dismissing))
    }

    @Test("standard policy is restrained and source-biased")
    func standardPolicy() {
        let policy = SettingsMotionPolicy(reduceMotion: false)
        let frame = NSRect(x: 100, y: 100, width: 760, height: 680)
        let source = SettingsTransitionGeometry.sourceTranslation(
            in: frame,
            from: NSPoint(x: 1_200, y: 900)
        )
        let hidden = policy.presentation(
            for: .dismiss,
            sourceTranslation: source
        )

        #expect(policy.usesSpatialMotion)
        #expect(policy.duration == SettingsMotionPolicy.standardDuration)
        #expect(hidden.opacity == 0)
        #expect(hidden.scale == SettingsMotionPolicy.standardHiddenScale)
        #expect(hidden.translation.x > 0)
        #expect(hidden.translation.y > 0)
        #expect(
            hypot(hidden.translation.x, hidden.translation.y)
                <= SettingsTransitionGeometry.maximumSourceTranslation + 0.0001
        )
    }

    @Test("Reduce Motion keeps only the short fade")
    func reduceMotionIsFadeOnly() {
        let policy = SettingsMotionPolicy(reduceMotion: true)
        let hidden = policy.presentation(
            for: .dismiss,
            sourceTranslation: SettingsTransitionVector(x: 4, y: 4)
        )

        #expect(!policy.usesSpatialMotion)
        #expect(policy.duration == SettingsMotionPolicy.reducedFadeDuration)
        #expect(policy.hiddenScale == 1)
        #expect(hidden.scale == 1)
        #expect(hidden.translation == .zero)
        #expect(SettingsTransitionPresentation.visible.translation == .zero)
    }

    @Test("source geometry is bounded and has a safe fallback")
    func sourceGeometryIsBounded() {
        let frame = NSRect(x: 200, y: 300, width: 760, height: 680)
        let center = NSPoint(x: frame.midX, y: frame.midY)

        #expect(
            SettingsTransitionGeometry.sourceTranslation(in: frame, from: nil)
                == .zero
        )
        #expect(
            SettingsTransitionGeometry.sourceTranslation(in: frame, from: center)
                == .zero
        )

        let customLimit: CGFloat = 2
        let translation = SettingsTransitionGeometry.sourceTranslation(
            in: frame,
            from: NSPoint(x: -10_000, y: -10_000),
            maximumDistance: customLimit
        )
        #expect(hypot(translation.x, translation.y) <= customLimit + 0.0001)
        #expect(translation.x < 0)
        #expect(translation.y < 0)
    }

    @Test("menu source stays neutral while gear source is explicit")
    func menuAndGearSourcesAreDistinct() {
        let settingsFrame = NSRect(x: 400, y: 240, width: 760, height: 680)
        let gearCenterOnScreen = NSPoint(x: 1_300, y: 920)

        let menuTranslation = SettingsTransitionGeometry.sourceTranslation(
            in: settingsFrame,
            from: nil
        )
        let gearTranslation = SettingsTransitionGeometry.sourceTranslation(
            in: settingsFrame,
            from: gearCenterOnScreen
        )

        #expect(menuTranslation == .zero)
        #expect(gearTranslation != .zero)
    }

    @Test("ownership gate waits for mouseUp before releasing")
    func ownershipGateNormalMouseUp() {
        var gate = SettingsOwnershipGate()
        gate.beginSession()
        gate.beginConsumingSequence()

        let fallback = gate.receiveCloseCallback()
        #expect(fallback != nil)
        #expect(!gate.canRelease())

        gate.consumeSequence()
        #expect(gate.canRelease())
        let finished = gate.finishSession()
        #expect(finished)
    }

    @Test("ownership gate force releases a lost mouseUp after callback")
    func ownershipGateFallbackReleasesLostMouseUp() {
        var gate = SettingsOwnershipGate()
        gate.beginSession()
        gate.beginConsumingSequence()

        let fallback = gate.receiveCloseCallback()
        #expect(fallback != nil)
        #expect(gate.acceptsFallback(fallback!))
        let forcedFinish = gate.finishSession(force: true)
        #expect(forcedFinish)
        #expect(!gate.acceptsFallback(fallback!))
    }

    @Test("stale ownership fallback cannot release a new session")
    func ownershipGateRejectsStaleFallback() {
        var gate = SettingsOwnershipGate()
        gate.beginSession()
        gate.beginConsumingSequence()
        let staleFallback = gate.receiveCloseCallback()
        #expect(staleFallback != nil)
        let forcedFinish = gate.finishSession(force: true)
        #expect(forcedFinish)

        gate.beginSession()
        gate.beginConsumingSequence()
        #expect(!gate.acceptsFallback(staleFallback!))
        #expect(!gate.canRelease())

        gate.consumeSequence()
        #expect(gate.receiveCloseCallback() == nil)
        let finished = gate.finishSession()
        #expect(finished)
    }

    @Test("re-present generation rejects an in-flight close fallback")
    func ownershipGateRePresentRejectsInFlightFallback() {
        var gate = SettingsOwnershipGate()
        gate.beginSession()
        gate.beginConsumingSequence()
        let staleFallback = gate.receiveCloseCallback()
        let closingGeneration = gate.generation

        #expect(staleFallback != nil)
        #expect(gate.acceptsFallback(staleFallback!))

        // Re-present happens after finalizeClose removed the child, but before
        // the shield mouseUp (or its fallback) released launcher ownership.
        gate.beginSession()

        #expect(gate.generation != closingGeneration)
        #expect(!gate.acceptsFallback(staleFallback!))
        #expect(!gate.closeCallbackReceived)
        #expect(!gate.consumingSequence)
        #expect(!gate.canRelease(force: true))
    }

    @Test("Settings child attachment repairs ownership and stays idempotent")
    @MainActor
    func settingsChildAttachmentRepairsOwnership() {
        let launcher = NSWindow()
        let staleParent = NSWindow()
        let settings = NSWindow()

        let attached = SettingsChildWindowAttachment.attach(settings, to: launcher)
        #expect(attached == .attached)
        #expect(settings.parent === launcher)
        #expect(launcher.childWindows?.filter { $0 === settings }.count == 1)

        let repeated = SettingsChildWindowAttachment.attach(settings, to: launcher)
        #expect(repeated == .alreadyAttached)
        #expect(launcher.childWindows?.filter { $0 === settings }.count == 1)

        launcher.removeChildWindow(settings)
        staleParent.addChildWindow(settings, ordered: .above)
        let reattached = SettingsChildWindowAttachment.attach(settings, to: launcher)

        #expect(reattached == .reattached)
        #expect(settings.parent === launcher)
        #expect(staleParent.childWindows?.contains { $0 === settings } != true)
        #expect(launcher.childWindows?.filter { $0 === settings }.count == 1)
    }

    @Test("removing dismissal animation cannot complete a new presentation")
    @MainActor
    func removalCompletionIsStaleBeforeNewAnimationStarts() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentLayoutRect)

        let coordinator = SettingsTransitionCoordinator(window: window)
        var installedAnimationCompletion: (() -> Void)?
        coordinator.testDidInstallAnimationCompletion = { completion in
            installedAnimationCompletion = completion
        }

        coordinator.present()
        installedAnimationCompletion?()
        #expect(coordinator.state == .visible)

        var dismissCompletionCount = 0
        coordinator.dismiss {
            dismissCompletionCount += 1
        }
        let staleDismissAnimationCompletion = installedAnimationCompletion

        var presentCompletionCount = 0
        coordinator.testWillRemoveAnimations = {
            staleDismissAnimationCompletion?()
        }
        coordinator.present {
            presentCompletionCount += 1
        }

        #expect(dismissCompletionCount == 0)
        #expect(presentCompletionCount == 0)
        #expect(coordinator.state == .presenting)

        let presentAnimationCompletion = installedAnimationCompletion
        presentAnimationCompletion?()
        presentAnimationCompletion?()

        #expect(dismissCompletionCount == 0)
        #expect(presentCompletionCount == 1)
        #expect(coordinator.state == .visible)
    }

    @Test("new intent rejects stale completion")
    func staleCompletionIsRejected() {
        var lifecycle = SettingsTransitionLifecycle()
        let presentToken = lifecycle.begin(.present)
        let dismissToken = lifecycle.begin(.dismiss)

        let stalePresent = lifecycle.complete(presentToken)
        let completedDismiss = lifecycle.complete(dismissToken)
        let repeatedDismiss = lifecycle.complete(dismissToken)

        #expect(!stalePresent)
        #expect(completedDismiss)
        #expect(lifecycle.state == .hidden)
        #expect(!repeatedDismiss)
    }

    @Test("manual move finalizes present and invalidates its completion")
    func manualMoveCancelsPresentation() {
        var lifecycle = SettingsTransitionLifecycle()
        let presentToken = lifecycle.begin(.present)

        let finalState = lifecycle.cancelForManualMove()
        let staleCompletion = lifecycle.complete(presentToken)

        #expect(finalState == .visible)
        #expect(lifecycle.state == .visible)
        #expect(!staleCompletion)
    }

    @Test("manual move finalizes dismissal as hidden")
    func manualMoveCancelsDismissal() {
        var lifecycle = SettingsTransitionLifecycle()
        let presentToken = lifecycle.begin(.present)
        let completedPresent = lifecycle.complete(presentToken)
        let dismissToken = lifecycle.begin(.dismiss)

        let finalState = lifecycle.cancelForManualMove()
        let staleCompletion = lifecycle.complete(dismissToken)

        #expect(completedPresent)
        #expect(finalState == .hidden)
        #expect(lifecycle.state == .hidden)
        #expect(!staleCompletion)
    }
}
