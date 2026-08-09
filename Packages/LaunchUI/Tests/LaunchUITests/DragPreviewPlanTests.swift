import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Drag preview visual plan")
struct DragPreviewPlanTests {
    @Test("moving right excludes source and shifts following cells left")
    func movingRight() {
        #expect(DragPreviewPlan.moves(sourceIndex: 2, gapIndex: 5) == [
            .init(itemIndex: 3, targetIndex: 2),
            .init(itemIndex: 4, targetIndex: 3),
            .init(itemIndex: 5, targetIndex: 4),
        ])
    }

    @Test("moving left excludes source and shifts preceding cells right")
    func movingLeft() {
        #expect(DragPreviewPlan.moves(sourceIndex: 5, gapIndex: 2) == [
            .init(itemIndex: 2, targetIndex: 3),
            .init(itemIndex: 3, targetIndex: 4),
            .init(itemIndex: 4, targetIndex: 5),
        ])
    }

    @Test("same slot has no transforms")
    func sameSlot() {
        #expect(DragPreviewPlan.moves(sourceIndex: 3, gapIndex: 3).isEmpty)
    }
}

@Suite("Create-folder hover decision")
struct CreateFolderHoverDecisionTests {
    private let source = AppID("/Applications/A.app")!
    private let target = AppID("/Applications/B.app")!
    private let otherTarget = AppID("/Applications/C.app")!

    @Test("another App waits immediately and does not activate early")
    func waitsBeforeDwell() {
        let decision = CreateFolderHoverDecision.resolve(
            sourceApp: source,
            pointedApp: target,
            candidate: target,
            elapsed: 0.299
        )
        #expect(decision == .waiting(target))
    }

    @Test("activation begins at exactly 0.3 seconds")
    func activatesAtDwell() {
        #expect(CreateFolderHoverDecision.activationDwell == 0.3)
        let decision = CreateFolderHoverDecision.resolve(
            sourceApp: source,
            pointedApp: target,
            candidate: target,
            elapsed: 0.3
        )
        #expect(decision == .active(target))
    }

    @Test("drop-time reevaluation activates when the dwell boundary is crossed")
    func dropTimeReevaluation() {
        let frameDecision = CreateFolderHoverDecision.resolve(
            sourceApp: source,
            pointedApp: target,
            candidate: target,
            elapsed: 0.299
        )
        let dropDecision = CreateFolderHoverDecision.resolve(
            sourceApp: source,
            pointedApp: target,
            candidate: target,
            elapsed: 0.3
        )

        #expect(frameDecision == .waiting(target))
        #expect(dropDecision == .active(target))
    }

    @Test("changing the pointed App restarts the candidate dwell")
    func changingTargetRestartsDwell() {
        let decision = CreateFolderHoverDecision.resolve(
            sourceApp: source,
            pointedApp: target,
            candidate: otherTarget,
            elapsed: 1
        )
        #expect(decision == .waiting(target))
    }

    @Test("source or non-App hit has no folder candidate")
    func clearsCandidate() {
        #expect(
            CreateFolderHoverDecision.resolve(
                sourceApp: source,
                pointedApp: source,
                candidate: source,
                elapsed: 1
            ) == .none
        )
        #expect(
            CreateFolderHoverDecision.resolve(
                sourceApp: source,
                pointedApp: nil,
                candidate: target,
                elapsed: 1
            ) == .none
        )
    }
}

@Suite("Drag visual layers")
@MainActor
struct DragVisualLayerTests {
    @Test("insertion indicator uses blue vertical frame and clears")
    func insertionIndicatorLifecycle() {
        let indicator = InsertionIndicatorLayer()
        indicator.show(at: CGRect(x: 100, y: 40, width: 96, height: 110))
        #expect(indicator.layer.isHidden == false)
        #expect(indicator.layer.frame == CGRect(x: 94, y: 46, width: 4, height: 98))
        indicator.hide()
        #expect(indicator.layer.isHidden)
    }

    @Test("overlay center follows pointer without a hidden vertical offset")
    func overlayHotspot() {
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let overlay = DragOverlayLayer()
        overlay.move(to: NSPoint(x: 120, y: 180), in: container)
        #expect(overlay.layer.position == CGPoint(x: 120, y: 180))
    }
}

@Suite("Folder panel and exit placement")
struct FolderPanelAndExitPlacementTests {
    @Test("folder panel keeps a fixed three-column near-square geometry")
    func folderPanelGeometry() {
        #expect(FolderPanelMetrics.cardSize == CGSize(width: 420, height: 440))
        #expect(FolderPanelMetrics.columns == 3)
        #expect(FolderPanelMetrics.rows == 3)
        #expect(FolderPanelMetrics.cellSize == 96)
        #expect(FolderPanelMetrics.spacing == 20)
    }

    @Test("folder icon size follows configuration but is capped at 80")
    func folderIconSizeCap() {
        #expect(FolderPanelMetrics.iconPointSize(for: 64) == 64)
        #expect(FolderPanelMetrics.iconPointSize(for: 120) == 80)
    }

    @Test("folder exit uses the current main-grid destination index")
    func folderExitPlacement() {
        let destination = LayoutTransaction.Destination(page: 1, slot: 2)
        #expect(
            FolderExitDragPlacement.displayIndex(
                for: destination, pageCapacity: 9, pageCount: 3
            ) == 11
        )
        #expect(
            FolderExitDragPlacement.displayIndex(
                for: LayoutTransaction.Destination(page: 99, slot: 99),
                pageCapacity: 9,
                pageCount: 3
            ) == 26
        )
    }
}

@Suite("Folder exit result lifecycle")
struct FolderExitDragLifecycleTests {
    @Test("keeps the dedicated session pending until the store result")
    func waitsForResultBeforeResolution() {
        var lifecycle = FolderExitDragLifecycle()

        let began = lifecycle.begin()
        #expect(began)
        #expect(lifecycle.phase == .active)
        let awaiting = lifecycle.awaitResult()
        #expect(awaiting)
        #expect(lifecycle.phase == .awaitingResult)
        #expect(lifecycle.isActive)
        #expect(lifecycle.isAwaitingResult)
        let resolved = lifecycle.resolve(true)
        #expect(resolved)
        #expect(lifecycle.phase == .idle)
        #expect(lifecycle.result == true)
    }

    @Test("accepts only one result and ignores a late duplicate")
    func resolvesOnlyOnce() {
        var lifecycle = FolderExitDragLifecycle()
        let began = lifecycle.begin()
        #expect(began)
        let awaiting = lifecycle.awaitResult()
        #expect(awaiting)

        let resolved = lifecycle.resolve(false)
        #expect(resolved)
        let duplicate = lifecycle.resolve(true)
        #expect(!duplicate)
        #expect(lifecycle.result == false)
    }

    @Test("cancellation invalidates a pending result")
    func cancellationDropsPendingSession() {
        var lifecycle = FolderExitDragLifecycle()
        let began = lifecycle.begin()
        #expect(began)
        let awaiting = lifecycle.awaitResult()
        #expect(awaiting)

        lifecycle.cancel()

        #expect(lifecycle.phase == .idle)
        #expect(lifecycle.result == nil)
        let lateResult = lifecycle.resolve(true)
        #expect(!lateResult)
    }
}
