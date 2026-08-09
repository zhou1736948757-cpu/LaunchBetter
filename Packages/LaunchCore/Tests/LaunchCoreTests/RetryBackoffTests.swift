import XCTest
@testable import LaunchCore

/// RetryBackoff 序列推进/cap/重置/边界测试(v0.2.3 §A1)。
final class RetryBackoffTests: XCTestCase {
    func testDefaultDelaysAreExact() {
        XCTAssertEqual(RetryBackoff.defaultDelays, [250, 1000, 4000, 15000, 30000])
    }

    func testSequenceAdvancesToCap() {
        var retry = RetryBackoff()
        XCTAssertEqual(retry.nextDelayMilliseconds(), 250)
        XCTAssertEqual(retry.nextDelayMilliseconds(), 1000)
        XCTAssertEqual(retry.nextDelayMilliseconds(), 4000)
        XCTAssertEqual(retry.nextDelayMilliseconds(), 15000)
        XCTAssertEqual(retry.nextDelayMilliseconds(), 30000)
    }

    func testStaysAtCapAfterSequenceEnd() {
        var retry = RetryBackoff()
        for _ in 0..<5 { _ = retry.nextDelayMilliseconds() }
        XCTAssertEqual(retry.nextDelayMilliseconds(), 30000)
        XCTAssertEqual(retry.nextDelayMilliseconds(), 30000)
        XCTAssertEqual(retry.nextDelayMilliseconds(), 30000)
    }

    func testResetRestartsFromFirst() {
        var retry = RetryBackoff()
        XCTAssertEqual(retry.nextDelayMilliseconds(), 250)
        XCTAssertEqual(retry.nextDelayMilliseconds(), 1000)
        retry.reset()
        XCTAssertEqual(retry.nextDelayMilliseconds(), 250)
        XCTAssertEqual(retry.nextDelayMilliseconds(), 1000)
    }

    func testResetAfterCapRestarts() {
        var retry = RetryBackoff()
        for _ in 0..<6 { _ = retry.nextDelayMilliseconds() }
        retry.reset()
        XCTAssertEqual(retry.nextDelayMilliseconds(), 250)
    }

    func testEmptySequenceFallsBackToDefault() {
        var retry = RetryBackoff(delays: [])
        XCTAssertEqual(retry.delays, RetryBackoff.defaultDelays)
        XCTAssertEqual(retry.nextDelayMilliseconds(), 250)
    }

    func testSingleElementSequenceStaysConstant() {
        var retry = RetryBackoff(delays: [500])
        XCTAssertEqual(retry.nextDelayMilliseconds(), 500)
        XCTAssertEqual(retry.nextDelayMilliseconds(), 500)
        XCTAssertEqual(retry.nextDelayMilliseconds(), 500)
    }
}
