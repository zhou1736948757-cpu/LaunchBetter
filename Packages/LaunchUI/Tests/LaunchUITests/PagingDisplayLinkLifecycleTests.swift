import Testing
@testable import LaunchUI

@Suite("Paging interaction: display link lifecycle", .serialized)
@MainActor
struct PagingDisplayLinkLifecycleTests {
    @Test("orphan display-link target invalidates its next tick")
    func orphanDisplayLinkTargetInvalidates() {
        let target = PagingInteractionController.DisplayLinkTarget(owner: nil)
        var invalidations = 0

        let didInvalidate = target.tickForTesting {
            invalidations += 1
        }

        #expect(didInvalidate)
        #expect(invalidations == 1)
    }

    @Test("owner release leaves display-link target orphaned")
    func ownerReleaseLeavesDisplayLinkTargetOrphaned() {
        weak var weakController: PagingInteractionController?
        let target: PagingInteractionController.DisplayLinkTarget

        do {
            let controller = PagingInteractionController()
            weakController = controller
            target = PagingInteractionController.DisplayLinkTarget(owner: controller)
        }

        #expect(weakController == nil)
        #expect(target.owner == nil)
    }

    @Test("shutdown is idempotent")
    func shutdownIsIdempotent() {
        let controller = PagingInteractionController()
        controller.startSettle(toPage: 1)

        controller.shutdown()
        controller.shutdown()

        #expect(controller.phase == .idle)
        #expect(controller.isDisplayLinkActive == false)
    }
}
