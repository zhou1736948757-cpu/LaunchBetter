import Foundation
import XCTest
@testable import LaunchCore

/// 双指滑动分页状态机测试(Stage 1 §10): 纯输入模型。
final class PagingGestureSessionTests: XCTestCase {
    // Case 1: began + changed×4 + ended → 只翻 1 页
    func testOneGestureCommitsExactlyOnePage() {
        var session = PagingGestureSession(threshold: 16)
        XCTAssertFalse(session.feed(phase: .began, deltaX: 0, deltaY: 0))
        XCTAssertFalse(session.feed(phase: .changed, deltaX: 5, deltaY: 0))
        XCTAssertFalse(session.feed(phase: .changed, deltaX: 10, deltaY: 0)) // 累计 15 < 阈值
        XCTAssertTrue(session.feed(phase: .changed, deltaX: 20, deltaY: 0))  // 累计 35 → 提交第 1 页
        XCTAssertFalse(session.feed(phase: .changed, deltaX: 20, deltaY: 0)) // 已提交 → 不再翻页
        XCTAssertFalse(session.feed(phase: .ended, deltaX: 0, deltaY: 0))
        XCTAssertEqual(session.pageChanges, 1)
    }

    // Case 2: momentum → 0 page change
    func testMomentumAddsZeroPageChange() {
        var session = PagingGestureSession(threshold: 16)
        session.feed(phase: .began, deltaX: 0, deltaY: 0)
        XCTAssertFalse(session.feed(phase: .changed, deltaX: 10, deltaY: 0))
        XCTAssertTrue(session.feed(phase: .changed, deltaX: 20, deltaY: 0))
        XCTAssertEqual(session.pageChanges, 1)
        // momentum 事件全部忽略
        XCTAssertFalse(session.feed(phase: .changed, deltaX: -50, deltaY: 0, isMomentum: true))
        XCTAssertFalse(session.feed(phase: .changed, deltaX: -50, deltaY: 0, isMomentum: true))
        XCTAssertFalse(session.feed(phase: .ended, deltaX: 0, deltaY: 0, isMomentum: true))
        XCTAssertEqual(session.pageChanges, 1)
    }

    // Case 3: 下一次独立手势允许再次翻一页
    func testNewGestureCanCommitAgain() {
        var session = PagingGestureSession(threshold: 16)
        session.feed(phase: .began, deltaX: 0, deltaY: 0)
        XCTAssertFalse(session.feed(phase: .changed, deltaX: 10, deltaY: 0))
        XCTAssertTrue(session.feed(phase: .changed, deltaX: 30, deltaY: 0))
        XCTAssertFalse(session.feed(phase: .changed, deltaX: 30, deltaY: 0))
        session.feed(phase: .ended, deltaX: 0, deltaY: 0)
        XCTAssertEqual(session.pageChanges, 1)

        session.reset()
        session.feed(phase: .began, deltaX: 0, deltaY: 0)
        XCTAssertFalse(session.feed(phase: .changed, deltaX: 10, deltaY: 0))
        XCTAssertTrue(session.feed(phase: .changed, deltaX: 20, deltaY: 0))
        XCTAssertFalse(session.feed(phase: .changed, deltaX: 20, deltaY: 0))
        XCTAssertEqual(session.pageChanges, 1)
    }

    // Case 4: 小幅水平抖动 → 0 page change
    func testSmallHorizontalJitterCommitsNothing() {
        var session = PagingGestureSession(threshold: 16)
        session.feed(phase: .began, deltaX: 0, deltaY: 0)
        XCTAssertFalse(session.feed(phase: .changed, deltaX: 3, deltaY: 0))
        XCTAssertFalse(session.feed(phase: .changed, deltaX: -4, deltaY: 0))
        XCTAssertFalse(session.feed(phase: .changed, deltaX: 2, deltaY: 0))
        session.feed(phase: .ended, deltaX: 0, deltaY: 0)
        XCTAssertEqual(session.pageChanges, 0)
    }

    // Case 5: 明显纵向手势 → 0 horizontal page change
    func testVerticalGestureCommitsNothing() {
        var session = PagingGestureSession(threshold: 16, horizontalDominance: 1.5)
        session.feed(phase: .began, deltaX: 0, deltaY: 0)
        XCTAssertFalse(session.feed(phase: .changed, deltaX: 30, deltaY: 60)) // 纵主导
        XCTAssertFalse(session.feed(phase: .changed, deltaX: 40, deltaY: 80))
        session.feed(phase: .ended, deltaX: 0, deltaY: 0)
        XCTAssertEqual(session.pageChanges, 0)
    }

    // 方向: 左滑(deltaX < 0)= 下一页; 右滑 = 上一页
    func testDirectionSign() {
        var session = PagingGestureSession(threshold: 16)
        session.feed(phase: .began, deltaX: 0, deltaY: 0)
        _ = session.feed(phase: .changed, deltaX: -20, deltaY: 0)
        XCTAssertEqual(session.direction, 1) // 左滑 → 下一页

        var session2 = PagingGestureSession(threshold: 16)
        session2.feed(phase: .began, deltaX: 0, deltaY: 0)
        _ = session2.feed(phase: .changed, deltaX: 20, deltaY: 0)
        XCTAssertEqual(session2.direction, -1) // 右滑 → 上一页
    }

    // 阈值内纵向先动不污染后续横向判定(水平主导按累计值)
    func testThresholdUsesCumulative() {
        var session = PagingGestureSession(threshold: 16, horizontalDominance: 1.5)
        session.feed(phase: .began, deltaX: 0, deltaY: 0)
        XCTAssertFalse(session.feed(phase: .changed, deltaX: 5, deltaY: 5))
        XCTAssertFalse(session.feed(phase: .changed, deltaX: 10, deltaY: 6)) // 累计 (15, 11) 未过阈值
        XCTAssertTrue(session.feed(phase: .changed, deltaX: 30, deltaY: 8))  // 累计 (45, 19) → 水平主导 + 阈值
        XCTAssertEqual(session.pageChanges, 1)
    }
}
