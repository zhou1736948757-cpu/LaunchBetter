import AppKit
import Testing
@testable import LaunchUI

@Suite("Frame coordinator: display link lifecycle", .serialized)
@MainActor
struct FrameCoordinatorLifecycleTests {
    @Test("orphan display-link target invalidates its next tick")
    func orphanDisplayLinkTargetInvalidates() {
        let target = FrameCoordinator.DisplayLinkTarget(owner: nil)
        var invalidations = 0

        let didInvalidate = target.tickForTesting {
            invalidations += 1
        }

        #expect(didInvalidate)
        #expect(invalidations == 1)
    }

    @Test("owner release leaves display-link target orphaned")
    func ownerReleaseLeavesDisplayLinkTargetOrphaned() {
        weak var weakCoordinator: FrameCoordinator?
        let target: FrameCoordinator.DisplayLinkTarget

        do {
            let coordinator = FrameCoordinator(
                view: NSView(frame: .zero),
                buffer: GestureSampleBuffer(),
                session: UUID()
            )
            weakCoordinator = coordinator
            target = FrameCoordinator.DisplayLinkTarget(owner: coordinator)
        }

        #expect(weakCoordinator == nil)
        #expect(target.owner == nil)
    }

    @Test("shutdown is idempotent")
    func shutdownIsIdempotent() {
        let coordinator = FrameCoordinator(
            view: NSView(frame: .zero),
            buffer: GestureSampleBuffer(),
            session: UUID()
        )

        coordinator.shutdown()
        coordinator.shutdown()

        #expect(coordinator.isRunning == false)
    }
}
