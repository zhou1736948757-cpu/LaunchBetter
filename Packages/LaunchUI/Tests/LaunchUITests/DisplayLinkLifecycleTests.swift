import AppKit
import Testing
@testable import LaunchUI

@Suite("Display-link target lifecycle", .serialized)
@MainActor
struct DisplayLinkLifecycleTests {
    @Test("FrameCoordinator live target does not take orphan path")
    func frameCoordinatorLiveTargetDoesNotTakeOrphanPath() {
        let coordinator = FrameCoordinator(
            view: NSView(frame: .zero),
            buffer: GestureSampleBuffer(),
            session: UUID()
        )
        let target = FrameCoordinator.DisplayLinkTarget(owner: coordinator)
        var invalidations = 0

        let didInvalidate = target.tickForTesting {
            invalidations += 1
        }

        #expect(!didInvalidate)
        #expect(invalidations == 0)
    }

    @Test("PagingInteractionController live target does not take orphan path")
    func pagingInteractionControllerLiveTargetDoesNotTakeOrphanPath() {
        let controller = PagingInteractionController()
        let target = PagingInteractionController.DisplayLinkTarget(owner: controller)
        var invalidations = 0

        let didInvalidate = target.tickForTesting {
            invalidations += 1
        }

        #expect(!didInvalidate)
        #expect(invalidations == 0)
    }
}
