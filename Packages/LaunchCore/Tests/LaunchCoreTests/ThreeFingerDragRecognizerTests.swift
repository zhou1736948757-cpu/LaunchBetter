import CoreGraphics
import Foundation
import XCTest
@testable import LaunchCore

/// 三指拖动识别状态机测试(Stage 2 §22): 对齐 legacy 语义(0.005/0.15/2帧)。
final class ThreeFingerDragRecognizerTests: XCTestCase {
    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    /// 稳定的三指帧(固定位置)。
    private func stableThree() -> [CGPoint] { [p(0.3, 0.3), p(0.5, 0.5), p(0.7, 0.3)] }

    /// 三指整体右移 0.05(归一化)——超过 minTranslation 0.005。
    private func movedThree() -> [CGPoint] { [p(0.35, 0.3), p(0.55, 0.5), p(0.75, 0.3)] }

    func testNoFingers() {
        var r = ThreeFingerDragRecognizer()
        XCTAssertNil(r.process(points: []))
        XCTAssertEqual(r.phase, .idle)
    }

    func testTwoFingersNeverBegin() {
        var r = ThreeFingerDragRecognizer()
        XCTAssertNil(r.process(points: [p(0.3, 0.3), p(0.5, 0.5)]))
        XCTAssertNil(r.process(points: [p(0.4, 0.3), p(0.6, 0.5)]))
        XCTAssertNil(r.process(points: [p(0.5, 0.3), p(0.7, 0.5)]))
        XCTAssertEqual(r.phase, .idle)
    }

    func testFourFingersNeverBegin() {
        var r = ThreeFingerDragRecognizer()
        XCTAssertNil(r.process(points: [p(0.2, 0.2), p(0.4, 0.2), p(0.2, 0.4), p(0.4, 0.4)]))
        XCTAssertEqual(r.phase, .idle)
    }

    func testStableThreeFingersRemainCandidate() {
        var r = ThreeFingerDragRecognizer()
        XCTAssertNil(r.process(points: stableThree()))
        XCTAssertNil(r.process(points: stableThree()))
        XCTAssertNil(r.process(points: stableThree()))
        XCTAssertEqual(r.phase, .confirming)
    }

    func testMovementBelowThresholdNoBegin() {
        var r = ThreeFingerDragRecognizer()
        // 轻微位移(0.001 < 0.005)不应触发
        let slight: [CGPoint] = [p(0.301, 0.3), p(0.501, 0.5), p(0.701, 0.3)]
        XCTAssertNil(r.process(points: stableThree()))
        XCTAssertNil(r.process(points: slight))
        XCTAssertEqual(r.phase, .confirming)
    }

    func testMovementAboveThresholdBeginsExactlyOnce() {
        var r = ThreeFingerDragRecognizer()
        XCTAssertNil(r.process(points: stableThree()))     // 记录基线
        XCTAssertNil(r.process(points: movedThree()))      // 第 1 帧确认
        XCTAssertEqual(r.process(points: movedThree()), .began)  // 第 2 帧 → began
        // 继续移动 → 只 update
        XCTAssertEqual(r.process(points: movedThree()), .changed)
        XCTAssertEqual(r.phase, .dragging)
    }

    func testContinuingFramesUpdateOnly() {
        var r = ThreeFingerDragRecognizer()
        _ = r.process(points: stableThree())
        _ = r.process(points: movedThree())
        XCTAssertEqual(r.process(points: movedThree()), .began)
        let further = [p(0.4, 0.3), p(0.6, 0.5), p(0.8, 0.3)]
        for _ in 0..<5 {
            XCTAssertEqual(r.process(points: further), .changed)
        }
    }

    func testOneFingerDisappearsEnds() {
        var r = ThreeFingerDragRecognizer()
        _ = r.process(points: stableThree())
        _ = r.process(points: movedThree())
        XCTAssertEqual(r.process(points: movedThree()), .began)
        XCTAssertEqual(r.process(points: [p(0.4, 0.3), p(0.6, 0.5)]), .ended)
        XCTAssertEqual(r.phase, .idle)
    }

    func testAllFingersReleasedEnds() {
        var r = ThreeFingerDragRecognizer()
        _ = r.process(points: stableThree())
        _ = r.process(points: movedThree())
        XCTAssertEqual(r.process(points: movedThree()), .began)
        XCTAssertEqual(r.process(points: []), .ended)
    }

    func testPinchDuringDragEnds() {
        var r = ThreeFingerDragRecognizer()
        _ = r.process(points: stableThree())
        _ = r.process(points: movedThree())
        XCTAssertEqual(r.process(points: movedThree()), .began)
        // 明显捏合: 三指靠拢(半径骤减 > 15%)
        let pinched = [p(0.48, 0.45), p(0.52, 0.5), p(0.5, 0.55)]
        XCTAssertEqual(r.process(points: pinched), .ended)
        XCTAssertEqual(r.phase, .idle)
    }

    func testNoisyCountResetsWithoutAccidentalBegin() {
        var r = ThreeFingerDragRecognizer()
        // 2→3→2 抖动
        XCTAssertNil(r.process(points: [p(0.3, 0.3), p(0.5, 0.5)]))
        XCTAssertNil(r.process(points: stableThree()))
        XCTAssertNil(r.process(points: [p(0.3, 0.3), p(0.5, 0.5)]))
        XCTAssertNil(r.process(points: stableThree()))
        XCTAssertEqual(r.phase, .confirming)
    }

    func testBeginCountExactlyOncePerGesture() {
        var r = ThreeFingerDragRecognizer()
        var beganCount = 0
        _ = r.process(points: stableThree())
        _ = r.process(points: movedThree())
        let e1 = r.process(points: movedThree())
        let e2 = r.process(points: movedThree())
        if e1 == .began { beganCount += 1 }
        if e2 == .began { beganCount += 1 }
        XCTAssertEqual(beganCount, 1)
    }
}
