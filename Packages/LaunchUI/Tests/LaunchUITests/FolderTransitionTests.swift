import AppKit
import LaunchCore
import QuartzCore
import Testing
@testable import LaunchUI

@Suite("Folder motion progress spring")
@MainActor
struct FolderTransitionTests {
    @Test("content inset changes invalidate the cached source geometry")
    func contentInsetChangeInvalidatesSourceGeometry() {
        let initial = makeSourceGeometry()
        let changedInsets = makeSourceGeometry(topInset: 176, bottomInset: 52)
        var revision = FolderTransitionSourceRevision()
        let token = revision.capture(synchronizing: initial)

        revision.synchronizeGeometry(changedInsets)

        #expect(!revision.isCurrent(token))
    }

    @Test("effective viewport geometry changes invalidate the cached source geometry")
    func viewportGeometryChangeInvalidatesSourceGeometry() {
        let initial = makeSourceGeometry()
        let resized = makeSourceGeometry(pageWidth: 1_024, pageHeight: 720)
        var revision = FolderTransitionSourceRevision()
        let token = revision.capture(synchronizing: initial)

        revision.synchronizeGeometry(resized)

        #expect(!revision.isCurrent(token))
    }

    @Test("capture synchronizes geometry before returning an immediately-current token")
    func captureSynchronizesBeforeReturningToken() {
        let geometry = makeSourceGeometry()
        var revision = FolderTransitionSourceRevision()

        let token = revision.capture(synchronizing: geometry)

        #expect(revision.isCurrent(token))

        revision.synchronizeGeometry(geometry)
        #expect(revision.isCurrent(token))

        revision.synchronizeGeometry(makeSourceGeometry(pageWidth: 1_024))

        #expect(!revision.isCurrent(token))
    }

    @Test("t0 keeps position and velocity unchanged")
    func t0() {
        var spring = MotionProgressSpring(progress: 0.2, velocity: 0.7, target: 1)
        let value = spring.advance(by: 0)

        #expect(value == 0.2)
        #expect(spring.currentProgress == 0.2)
        #expect(spring.velocity == 0.7)
    }

    @Test("critical spring settles at its target")
    func settles() {
        var spring = MotionProgressSpring(target: 1)
        for _ in 0..<240 {
            _ = spring.advance(by: 1.0 / 120.0)
        }

        #expect(spring.isSettled)
        #expect(spring.currentProgress == 1)
        #expect(spring.velocity == 0)
    }

    @Test("retarget preserves current progress and velocity")
    func retargetKeepsStateContinuous() {
        var spring = MotionProgressSpring(target: 1)
        _ = spring.advance(by: 0.12)
        let progress = spring.currentProgress
        let velocity = spring.velocity

        spring.retarget(to: 0)

        #expect(spring.currentProgress == progress)
        #expect(spring.velocity == velocity)
        #expect(spring.targetProgress == 0)
    }

    @Test("60 and 120 Hz reach the same state for the same wall clock")
    func frameRateIndependent() {
        var at60 = MotionProgressSpring(target: 1)
        var at120 = MotionProgressSpring(target: 1)
        for _ in 0..<60 { _ = at60.advance(by: 1.0 / 60.0) }
        for _ in 0..<120 { _ = at120.advance(by: 1.0 / 120.0) }

        #expect(abs(at60.currentProgress - at120.currentProgress) < 0.0001)
        #expect(abs(at60.velocity - at120.velocity) < 0.002)
    }

    @Test("zero distance and invalid delta never produce NaN")
    func zeroDistanceIsFinite() {
        var spring = MotionProgressSpring(progress: 0.5, velocity: 0, target: 0.5)
        _ = spring.advance(by: .nan)
        _ = spring.advance(by: 0)
        _ = spring.advance(by: 0.2)

        #expect(spring.currentProgress.isFinite)
        #expect(spring.velocity.isFinite)
        #expect(spring.targetProgress.isFinite)
        #expect(spring.currentProgress == 0.5)
    }

    @Test("target hooks only change layer presentation values")
    func targetHooks() {
        let dim = CALayer()
        let card = CALayer()
        let material = CALayer()
        let content = CALayer()
        let target = FolderTransitionTarget(
            frameInContentView: CGRect(x: 40, y: 30, width: 200, height: 180),
            cornerRadius: 24,
            baseShadowOpacity: 0.28,
            dimLayer: dim,
            cardLayer: card,
            materialLayer: material,
            contentLayers: [content],
            isCurrent: { true }
        )

        target.prepareHidden()
        #expect(dim.opacity == 0)
        #expect(card.opacity == 0)
        #expect(content.opacity == 0)

        target.apply(dimOpacity: 0.4, materialOpacity: 0.8, contentOpacity: 0.2)
        #expect(dim.opacity == 0.4)
        #expect(card.opacity == 0.8)
        #expect(card.shadowOpacity == 0.224)
        #expect(material.opacity == 0.8)
        #expect(content.opacity == 0.2)
    }

    @Test("invalid source falls back to a restrained center geometry")
    func invalidSourceUsesCenterFallback() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        host.wantsLayer = true
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let target = makeTarget()
        let source = FolderTransitionSource(
            folderID: FolderID("folder://invalid-source")!,
            frameInContentView: CGRect(x: 5, y: 5, width: 40, height: 40),
            cornerRadius: 12,
            representation: nil,
            cell: AppCellView(),
            isCurrent: { false }
        )
        let coordinator = FolderTransitionCoordinator(
            hostView: host,
            source: source,
            target: target,
            reduceMotion: false
        )
        coordinator.startOpening()
        coordinator.advanceForTesting(by: 0)

        let proxyFrame = host.layer?.sublayers?.first?.frame ?? .zero
        #expect(proxyFrame.midX == target.frameInContentView.midX)
        #expect(proxyFrame.midY == target.frameInContentView.midY)
        #expect(proxyFrame.width > source.frameInContentView.width)
        coordinator.cancelAndTeardown()
    }

    @Test("mid-animation invalidation preserves current proxy presentation")
    func midAnimationInvalidationDoesNotJump() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        host.wantsLayer = true
        var sourceIsCurrent = true
        let source = makeSource(isCurrent: { sourceIsCurrent })
        let coordinator = FolderTransitionCoordinator(
            hostView: host,
            source: source,
            target: makeTarget(),
            reduceMotion: false
        )

        coordinator.startOpening()
        coordinator.advanceForTesting(by: 0.08)
        let beforeInvalidation = coordinator.proxyPresentationForTesting
        #expect(beforeInvalidation.frame.minX != 120)
        #expect(beforeInvalidation.opacity > 0)

        sourceIsCurrent = false
        coordinator.advanceForTesting(by: 0)
        let afterInvalidation = coordinator.proxyPresentationForTesting

        #expect(afterInvalidation == beforeInvalidation)
        coordinator.cancelAndTeardown()
    }

    @Test("mid-animation target invalidation also preserves proxy presentation")
    func midAnimationTargetInvalidationDoesNotJump() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        host.wantsLayer = true
        var targetIsCurrent = true
        let coordinator = FolderTransitionCoordinator(
            hostView: host,
            source: makeSource(isCurrent: { true }),
            target: makeTarget(isCurrent: { targetIsCurrent }),
            reduceMotion: false
        )

        coordinator.startOpening()
        coordinator.advanceForTesting(by: 0.08)
        let beforeInvalidation = coordinator.proxyPresentationForTesting
        targetIsCurrent = false
        coordinator.advanceForTesting(by: 0)

        #expect(coordinator.proxyPresentationForTesting == beforeInvalidation)
        coordinator.cancelAndTeardown()
    }

    @Test("close and reopen retarget preserve fallback presentation and spring state")
    func closeReopenRetargetIsContinuous() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        host.wantsLayer = true
        var sourceIsCurrent = true
        let source = makeSource(isCurrent: { sourceIsCurrent })
        let coordinator = FolderTransitionCoordinator(
            hostView: host,
            source: source,
            target: makeTarget(),
            reduceMotion: false
        )

        coordinator.startOpening()
        coordinator.advanceForTesting(by: 0.08)
        sourceIsCurrent = false
        coordinator.advanceForTesting(by: 0)

        let beforeCloseProgress = coordinator.currentProgress
        let beforeCloseVelocity = coordinator.currentVelocity
        let beforeClosePresentation = coordinator.proxyPresentationForTesting
        var staleCloseCompletions = 0
        coordinator.requestClose { staleCloseCompletions += 1 }

        #expect(coordinator.currentProgress == beforeCloseProgress)
        #expect(coordinator.currentVelocity == beforeCloseVelocity)
        #expect(coordinator.proxyPresentationForTesting == beforeClosePresentation)
        #expect(coordinator.currentIntent == .close)

        coordinator.advanceForTesting(by: 0.04)
        let beforeReopenProgress = coordinator.currentProgress
        let beforeReopenVelocity = coordinator.currentVelocity
        let beforeReopenPresentation = coordinator.proxyPresentationForTesting
        coordinator.startOpening()

        #expect(coordinator.currentProgress == beforeReopenProgress)
        #expect(coordinator.currentVelocity == beforeReopenVelocity)
        #expect(coordinator.proxyPresentationForTesting == beforeReopenPresentation)
        #expect(coordinator.currentIntent == .open)

        coordinator.advanceForTesting(by: 1)
        #expect(staleCloseCompletions == 0)
        #expect(coordinator.currentProgress == 1)
        coordinator.cancelAndTeardown()
    }

    @Test("close completion is one-shot and teardown is idempotent")
    func closeCompletionAndTeardown() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        host.wantsLayer = true
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let target = makeTarget()
        let coordinator = FolderTransitionCoordinator(
            hostView: host,
            source: nil,
            target: target,
            reduceMotion: true
        )
        coordinator.startOpening()
        coordinator.advanceForTesting(by: 1)

        var completions = 0
        coordinator.requestClose { completions += 1 }
        coordinator.advanceForTesting(by: 1)
        coordinator.advanceForTesting(by: 1)
        coordinator.cancelAndTeardown()

        #expect(completions == 1)
        let hasNoProxy = host.layer?.sublayers?.isEmpty ?? true
        #expect(hasNoProxy)
        #expect(target.frameInContentView.width == 200)
    }

    @Test("orphan display-link target invalidates its next tick")
    func orphanDisplayLinkTargetInvalidates() {
        let target = FolderTransitionCoordinator.DisplayLinkTarget(owner: nil)
        var invalidations = 0

        let didInvalidate = target.tickForTesting {
            invalidations += 1
        }

        #expect(didInvalidate)
        #expect(invalidations == 1)
    }

    @Test("explicit teardown detaches the proxy idempotently")
    func explicitTeardownDetachesProxyIdempotently() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        host.wantsLayer = true
        let coordinator = FolderTransitionCoordinator(
            hostView: host,
            source: nil,
            target: makeTarget(),
            reduceMotion: true
        )

        #expect(host.layer?.sublayers?.isEmpty == false)
        coordinator.cancelAndTeardown()
        coordinator.cancelAndTeardown()

        #expect(host.layer?.sublayers?.isEmpty ?? true)
    }

    private func makeTarget(
        isCurrent: @escaping () -> Bool = { true }
    ) -> FolderTransitionTarget {
        FolderTransitionTarget(
            frameInContentView: CGRect(x: 120, y: 100, width: 200, height: 180),
            cornerRadius: 24,
            baseShadowOpacity: 0.28,
            dimLayer: CALayer(),
            cardLayer: CALayer(),
            materialLayer: CALayer(),
            contentLayers: [CALayer()],
            isCurrent: isCurrent
        )
    }

    private func makeSourceGeometry(
        pageWidth: CGFloat = 900,
        pageHeight: CGFloat = 700,
        topInset: CGFloat = 160,
        bottomInset: CGFloat = 40
    ) -> GridGeometry {
        GridGeometry(
            columns: 7,
            rows: 6,
            cellSize: 92,
            iconSize: 64,
            horizontalSpacing: 28,
            verticalSpacing: 28,
            pageWidth: pageWidth,
            pageHeight: pageHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )
    }

    private func makeSource(isCurrent: @escaping () -> Bool) -> FolderTransitionSource {
        let folderID = FolderID("folder://continuity-source")!
        let cell = AppCellView()
        cell.configureFolder(
            displayName: "Continuity",
            accessibilityHint: "Continuity",
            folderID: folderID,
            children: [],
            pointSize: 64,
            iconProvider: nil
        )
        return FolderTransitionSource(
            folderID: folderID,
            frameInContentView: CGRect(x: 18, y: 22, width: 64, height: 64),
            cornerRadius: 14,
            representation: nil,
            cell: cell,
            isCurrent: { [cell] in
                _ = cell
                return isCurrent()
            }
        )
    }
}
