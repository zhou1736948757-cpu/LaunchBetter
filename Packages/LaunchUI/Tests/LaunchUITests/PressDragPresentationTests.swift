import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Stage D press feedback and drag grab offset")
@MainActor
struct PressDragPresentationTests {
    @Test("App and Folder cells compress immediately and restore on cancel")
    func appAndFolderPressLifecycle() throws {
        let app = AppCellView()
        app.view.frame = NSRect(x: 0, y: 0, width: 120, height: 120)
        app.configure(
            displayName: "App",
            colorIndex: 0,
            accessibilityHint: "App",
            appID: AppID("/Applications/PressApp.app")!,
            pointSize: 64,
            iconProvider: nil
        )

        let folder = AppCellView()
        folder.view.frame = NSRect(x: 0, y: 0, width: 120, height: 120)
        folder.configureFolder(
            displayName: "Folder",
            accessibilityHint: "Folder",
            folderID: FolderID("folder://press")!,
            children: [],
            pointSize: 64,
            iconProvider: nil
        )

        for cell in [app, folder] {
            let presentation = try #require(cell.pressPresentationForDiagnostics)
            cell.beginPressFeedback(at: NSPoint(x: 40, y: 40))

            #expect(presentation.phase == .pressed)
            #expect(presentation.modelScaleForDiagnostics == MotionTokens.pressScale)
            #expect(
                CATransform3DEqualToTransform(
                    cell.view.layer?.transform ?? CATransform3DIdentity,
                    CATransform3DIdentity
                )
            )

            cell.cancelPressFeedback()
            #expect(presentation.phase == .idle)
            #expect(presentation.modelScaleForDiagnostics == 1)
        }
    }

    @Test("crossing the real threshold preserves press state before drag callback")
    func thresholdHandoffDoesNotRebound() throws {
        let layer = CALayer()
        let presentation = PressDragPresentation(layer: layer)
        var thresholdPoint: NSPoint?
        presentation.onDragThresholdCrossed = { thresholdPoint = $0 }

        presentation.begin(at: NSPoint(x: 10, y: 10))
        presentation.move(to: NSPoint(x: 14.9, y: 10))
        #expect(presentation.phase == .pressed)
        #expect(presentation.modelScaleForDiagnostics == MotionTokens.pressScale)

        presentation.move(to: NSPoint(x: 15, y: 10))
        #expect(presentation.phase == .dragging)
        #expect(thresholdPoint == NSPoint(x: 15, y: 10))
        #expect(presentation.modelScaleForDiagnostics == MotionTokens.pressScale)

        presentation.end(afterDragging: true)
        #expect(presentation.phase == .idle)
        #expect(presentation.modelScaleForDiagnostics == 1)
    }

    @Test("fast release uses the pressed model when presentation is still identity")
    func fastReleaseUsesPressedModelWhenPresentationLags() {
        let layer = CALayer()
        let presentation = PressDragPresentation(
            layer: layer,
            presentationTransformProvider: { CATransform3DIdentity }
        )

        presentation.begin(at: NSPoint(x: 10, y: 10))
        presentation.end(afterDragging: false)

        #expect(presentation.lastAnimationFromScaleForDiagnostics == MotionTokens.pressScale)
        #expect(presentation.lastAnimationFromScaleForDiagnostics != 1)
        #expect(layer.animation(forKey: "LaunchBetter.pressFeedback") != nil)
        #expect(presentation.modelScaleForDiagnostics == 1)
    }

    @Test("normal press release records a non-identity animation start")
    func normalPressReleaseRestoresIdentity() {
        let layer = CALayer()
        let presentation = PressDragPresentation(
            layer: layer,
            presentationTransformProvider: {
                CATransform3DMakeScale(MotionTokens.pressScale, MotionTokens.pressScale, 1)
            }
        )

        presentation.begin(at: NSPoint(x: 10, y: 10))
        presentation.end(afterDragging: false)

        #expect(presentation.lastAnimationFromScaleForDiagnostics == MotionTokens.pressScale)
        #expect(layer.animation(forKey: "LaunchBetter.pressFeedback") != nil)
        #expect(presentation.modelScaleForDiagnostics == 1)
    }

    @Test("drag end and cancellation restore identity immediately")
    func dragEndAndCancellationRestoreIdentity() {
        let layer = CALayer()
        let presentation = PressDragPresentation(layer: layer)

        presentation.begin(at: NSPoint(x: 10, y: 10))
        presentation.move(to: NSPoint(x: 15, y: 10))
        presentation.end(afterDragging: true)
        #expect(presentation.modelScaleForDiagnostics == 1)
        #expect(presentation.presentationScaleForDiagnostics == 1)

        presentation.begin(at: NSPoint(x: 10, y: 10))
        presentation.cancel()
        #expect(presentation.modelScaleForDiagnostics == 1)
        #expect(presentation.presentationScaleForDiagnostics == 1)
    }

    @Test("threshold keeps mouseDown source anchor and passes current pointer separately")
    func clickableSourceAnchor() {
        let collectionView = ClickableCollectionView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 180)
        )
        let sourcePoint = NSPoint(x: 42, y: 56)
        let thresholdPoint = NSPoint(x: 47, y: 56)
        var callbackPoint: NSPoint?
        var sourceAwareAnchor: NSPoint?
        var sourceAwareCurrent: NSPoint?
        collectionView.onDragBegin = { callbackPoint = $0 }
        collectionView.onDragBeginWithSource = { source, current in
            sourceAwareAnchor = source
            sourceAwareCurrent = current
        }

        collectionView.mouseDown(with: mouseEvent(.leftMouseDown, at: sourcePoint))
        collectionView.mouseDragged(
            with: mouseEvent(.leftMouseDragged, at: thresholdPoint)
        )

        #expect(collectionView.activeDragSourcePoint == sourcePoint)
        #expect(callbackPoint == thresholdPoint)
        #expect(sourceAwareAnchor == sourcePoint)
        #expect(sourceAwareCurrent == thresholdPoint)

        collectionView.mouseUp(with: mouseEvent(.leftMouseUp, at: thresholdPoint))
        #expect(collectionView.activeDragSourcePoint == nil)
    }

    @Test("Launcher source routing keeps A when current pointer reaches adjacent B")
    func launcherSourceRoutingUsesMouseDownIdentity() throws {
        let appA = DisplayModel.DisplayItem.app(
            AppID("/Applications/AnchorA.app")!
        )
        let appB = DisplayModel.DisplayItem.app(
            AppID("/Applications/AdjacentB.app")!
        )
        let sourcePoint = NSPoint(x: 100, y: 120)
        let adjacentPoint = NSPoint(x: 148, y: 120)
        var queriedPoints: [NSPoint] = []

        let selection = try #require(
            DragSourceAnchorResolver.resolve(
                sourcePoint: sourcePoint,
                currentPoint: adjacentPoint,
                valueAt: { point in
                    queriedPoints.append(point)
                    return point == sourcePoint ? appA : appB
                }
            )
        )

        #expect(selection.source == appA)
        #expect(selection.currentPoint == adjacentPoint)
        #expect(queriedPoints == [sourcePoint])
    }

    @Test("Folder source routing keeps child A when current pointer reaches child B")
    func folderSourceRoutingUsesMouseDownIdentity() throws {
        let childA = AppID("/Applications/FolderChildA.app")!
        let childB = AppID("/Applications/FolderChildB.app")!
        let sourceIndexPath = IndexPath(item: 0, section: 0)
        let adjacentIndexPath = IndexPath(item: 1, section: 0)
        let sourcePoint = NSPoint(x: 96, y: 160)
        let adjacentPoint = NSPoint(x: 144, y: 160)

        let selection = try #require(
            DragSourceAnchorResolver.resolve(
                sourcePoint: sourcePoint,
                currentPoint: adjacentPoint,
                valueAt: { point in
                    if point == sourcePoint {
                        return (
                            sourceIndexPath,
                            DisplayModel.DisplayItem.app(childA)
                        )
                    }
                    return (
                        adjacentIndexPath,
                        DisplayModel.DisplayItem.app(childB)
                    )
                }
            )
        )

        #expect(selection.source.0 == sourceIndexPath)
        guard case .app(let selectedChild) = selection.source.1 else {
            Issue.record("Folder source seam did not resolve an app child")
            return
        }
        #expect(selectedChild == childA)
        #expect(selection.currentPoint == adjacentPoint)
    }

    @Test("visual grab offset moves only overlay and keeps semantic pointer")
    func overlayGrabOffsetAndPointerSemantics() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let overlay = DragOverlayLayer()
        let pointerAtThreshold = NSPoint(x: 82, y: 96)
        let sourceCenter = NSPoint(x: 120, y: 140)
        DragOverlayLayer.registerPendingSourceVisualCenter(
            centerInWindow: sourceCenter,
            pointerInWindow: pointerAtThreshold
        )

        overlay.configure(label: "App", representation: nil)
        overlay.move(to: pointerAtThreshold, in: container)

        #expect(overlay.lastPointerPosition == pointerAtThreshold)
        #expect(overlay.grabOffsetForDiagnostics == DragGrabOffset(dx: 38, dy: 44))
        #expect(overlay.layer.position == sourceCenter)

        let nextPointer = NSPoint(x: 100, y: 110)
        overlay.move(to: nextPointer, in: container)
        #expect(overlay.lastPointerPosition == nextPointer)
        #expect(overlay.layer.position == NSPoint(x: 138, y: 154))
    }

    @Test("unmatched pending offset cannot alter a new semantic pointer")
    func staleGrabOffsetIsRejected() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let overlay = DragOverlayLayer()
        DragOverlayLayer.registerPendingSourceVisualCenter(
            centerInWindow: NSPoint(x: 120, y: 140),
            pointerInWindow: NSPoint(x: 82, y: 96)
        )

        overlay.configure(label: "App", representation: nil)
        let newPointer = NSPoint(x: 200, y: 210)
        overlay.move(to: newPointer, in: container)

        #expect(overlay.lastPointerPosition == newPointer)
        #expect(overlay.grabOffsetForDiagnostics == DragGrabOffset(dx: 0, dy: 0))
        #expect(overlay.layer.position == newPointer)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: type == .leftMouseDragged ? 0 : 1,
            pressure: 0
        )!
    }
}
