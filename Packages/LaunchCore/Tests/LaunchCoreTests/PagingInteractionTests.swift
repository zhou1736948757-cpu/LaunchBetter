import CoreGraphics
import Foundation
import XCTest
@testable import LaunchCore

/// 分页轴锁状态机测试(v0.1.6 §7/§67)。
final class PagingAxisLockTests: XCTestCase {
    func testUndecidedToHorizontal() {
        var lock = PagingAxisLock()
        lock.began()
        // 纵向动一小点, 未激活
        XCTAssertFalse(lock.accumulate(deltaX: 0, deltaY: 1))
        // 水平累计超过激活阈值且主导 → 锁定水平
        XCTAssertFalse(lock.accumulate(deltaX: 5, deltaY: 0)) // 累计 5 < 6
        XCTAssertTrue(lock.accumulate(deltaX: 4, deltaY: 0))  // 累计 9 > 6, 9 > 1*1.2
    }

    func testHorizontalLockedCannotExitOnVerticalBurst() {
        var lock = PagingAxisLock()
        lock.began()
        _ = lock.accumulate(deltaX: 10, deltaY: 0)
        XCTAssertTrue(lock.isHorizontal)
        // 已锁定: 单帧 dy 巨大也不能退出
        XCTAssertTrue(lock.accumulate(deltaX: 0, deltaY: 500))
        XCTAssertTrue(lock.isHorizontal)
    }

    func testEndedResets() {
        var lock = PagingAxisLock()
        lock.began()
        _ = lock.accumulate(deltaX: 10, deltaY: 0)
        XCTAssertTrue(lock.isHorizontal)
        lock.ended()
        XCTAssertFalse(lock.isHorizontal)
        XCTAssertEqual(lock.state, .idle)
    }

    func testVerticalDominantStaysUndecided() {
        var lock = PagingAxisLock()
        lock.began()
        _ = lock.accumulate(deltaX: 3, deltaY: 20)
        _ = lock.accumulate(deltaX: 2, deltaY: 30)
        XCTAssertEqual(lock.state, .undecided)
    }
}

/// 目标解析测试(v0.1.6 §21-22/§67): 位移 + 速度。
final class PagingTargetResolverTests: XCTestCase {
    let pageWidth: CGFloat = 1470

    func testSmallDisplacementStays() {
        let target = PagingTargetResolver.resolve(
            currentPage: 1, pageCount: 3, pageWidth: pageWidth,
            displacement: -pageWidth * 0.06, releaseVelocity: 0
        )
        XCTAssertEqual(target, 1)
    }

    func testDisplacementThresholdAdvances() {
        // 左滑(负位移)→ 下一页
        let target = PagingTargetResolver.resolve(
            currentPage: 1, pageCount: 3, pageWidth: pageWidth,
            displacement: -pageWidth * 0.4, releaseVelocity: 0
        )
        XCTAssertEqual(target, 2)
        // 右滑(正位移)→ 上一页
        let back = PagingTargetResolver.resolve(
            currentPage: 1, pageCount: 3, pageWidth: pageWidth,
            displacement: pageWidth * 0.4, releaseVelocity: 0
        )
        XCTAssertEqual(back, 0)
    }

    func testVelocityFling() {
        // 位移不足阈值但速度够 → fling 翻页(位移 0.08 < 阈值 0.10)
        let target = PagingTargetResolver.resolve(
            currentPage: 1, pageCount: 3, pageWidth: pageWidth,
            displacement: -pageWidth * 0.08, releaseVelocity: -1200
        )
        XCTAssertEqual(target, 2)
    }

    func testVelocityFlingUsesBothSignsAtShortDisplacements() {
        for fraction in [CGFloat(0.05), 0.08, 0.09] {
            XCTAssertEqual(PagingTargetResolver.resolve(
                currentPage: 1,
                pageCount: 3,
                pageWidth: pageWidth,
                displacement: -pageWidth * fraction,
                releaseVelocity: -PagingTuning.flingVelocityThreshold - 1
            ), 2, "left fling at \(fraction) page")

            XCTAssertEqual(PagingTargetResolver.resolve(
                currentPage: 1,
                pageCount: 3,
                pageWidth: pageWidth,
                displacement: pageWidth * fraction,
                releaseVelocity: PagingTuning.flingVelocityThreshold + 1
            ), 0, "right fling at \(fraction) page")
        }
    }

    func testVelocityTooLowNoFling() {
        let target = PagingTargetResolver.resolve(
            currentPage: 1, pageCount: 3, pageWidth: pageWidth,
            displacement: -pageWidth * 0.08, releaseVelocity: -200
        )
        XCTAssertEqual(target, 1)
    }

    func testNoDisplacementNoFling() {
        // 位移低于 fling 最小方向性位移, 即使速度高也不翻
        let target = PagingTargetResolver.resolve(
            currentPage: 1, pageCount: 3, pageWidth: pageWidth,
            displacement: 0, releaseVelocity: -1200
        )
        XCTAssertEqual(target, 1)
    }

    func testBoundaryClamped() {
        XCTAssertEqual(PagingTargetResolver.resolve(
            currentPage: 0, pageCount: 3, pageWidth: pageWidth,
            displacement: pageWidth, releaseVelocity: 1000
        ), 0)
        XCTAssertEqual(PagingTargetResolver.resolve(
            currentPage: 2, pageCount: 3, pageWidth: pageWidth,
            displacement: -pageWidth, releaseVelocity: -1000
        ), 2)
    }
}

/// 弹簧测试(v0.1.6 §24-27/§67): 60/120 一致性、收敛、时间驱动。
final class PagingSpringTests: XCTestCase {
    func testConvergesToTarget() {
        let spring = PagingSpring(
            startPosition: 1470, target: 2940, velocity: 0, omega: 14, startTime: 0
        )
        var p: CGFloat = 0
        for i in 0..<200 {
            p = spring.position(atTime: CFTimeInterval(i) / 60.0)
        }
        XCTAssertEqual(p, 2940, accuracy: 0.6)
    }

    func test60And120HertzConsistent() {
        // 同一 wall-clock 时间点, 60Hz 与 120Hz 采样位置一致(时间驱动, 非帧驱动)
        let spring60 = PagingSpring(startPosition: 0, target: 1470, velocity: 300, omega: 14, startTime: 0)
        let spring120 = PagingSpring(startPosition: 0, target: 1470, velocity: 300, omega: 14, startTime: 0)
        // 60Hz: 6 帧 = 0.1s; 120Hz: 12 帧 = 0.1s
        let at60 = spring60.position(atTime: 0.1)
        let at120 = spring120.position(atTime: 0.1)
        XCTAssertEqual(at60, at120, accuracy: 0.001)
    }

    func testIsSettledEventually() {
        let spring = PagingSpring(startPosition: 0, target: 1470, velocity: -500, omega: 14, startTime: 0)
        XCTAssertFalse(spring.isSettled(atTime: 0.02))
        XCTAssertTrue(spring.isSettled(atTime: 1.0))
    }

    func testVelocityDecaysToZero() {
        let spring = PagingSpring(startPosition: 0, target: 1470, velocity: 800, omega: 14, startTime: 0)
        XCTAssertTrue(abs(spring.velocity(atTime: 1.0)) < 1)
    }

    func testOvershootNoneForCriticalDamping() {
        // 临界阻尼: 单调趋近, 不越过 target
        let spring = PagingSpring(startPosition: 0, target: 1470, velocity: 2000, omega: 14, startTime: 0)
        var prev = spring.position(atTime: 0)
        var monotonic = true
        for i in 1...60 {
            let p = spring.position(atTime: CFTimeInterval(i) / 60.0)
            if p < prev - 0.1 { monotonic = false }
            prev = p
        }
        XCTAssertTrue(monotonic)
    }
}

/// 外边缘 rubber band 测试(v0.1.6 §18)。
final class PagingRubberBandTests: XCTestCase {
    func testDirectMappingInsideRange() {
        XCTAssertEqual(PagingRubberBand.clamp(0, minX: 0, maxX: 2940, pageWidth: 1470), 0)
        XCTAssertEqual(PagingRubberBand.clamp(1470, minX: 0, maxX: 2940, pageWidth: 1470), 1470)
        XCTAssertEqual(PagingRubberBand.clamp(2940, minX: 0, maxX: 2940, pageWidth: 1470), 2940)
    }

    func testRubberBandAtFirstEdge() {
        // 越过 0 → 阻尼外溢(不直接钳死, 有饱和)
        let clamped = PagingRubberBand.clamp(-100, minX: 0, maxX: 2940, pageWidth: 1470)
        XCTAssertLessThan(clamped, 0)
        XCTAssertGreaterThan(clamped, -100) // 被阻尼
    }

    func testRubberBandAtLastEdge() {
        let clamped = PagingRubberBand.clamp(3040, minX: 0, maxX: 2940, pageWidth: 1470)
        XCTAssertGreaterThan(clamped, 2940)
        XCTAssertLessThan(clamped, 3040)
    }

    func testRubberBandCapUsesSinglePageWidthForTwoThreeAndFivePages() {
        let pageWidth: CGFloat = 1000
        let cap = PagingTuning.rubberBandMaxOverflowPages * pageWidth
        let epsilon: CGFloat = 0.001

        for pageCount in [2, 3, 5] {
            let minX: CGFloat = 0
            let maxX = CGFloat(pageCount - 1) * pageWidth
            let clamp: (CGFloat) -> CGFloat = { offset in
                PagingRubberBand.clamp(offset, minX: minX, maxX: maxX, pageWidth: pageWidth)
            }

            // Within-range mapping remains identity, including both boundaries.
            for offset in [minX, pageWidth * 0.25, maxX - pageWidth * 0.25, maxX] {
                XCTAssertEqual(clamp(offset), offset, accuracy: 0.0001)
            }

            // The edge remains continuous and the single-page cap is invariant
            // as the number of pages changes.
            XCTAssertEqual(clamp(minX - epsilon), minX - epsilon * PagingTuning.rubberBandStiffness, accuracy: 0.000001)
            XCTAssertEqual(clamp(maxX + epsilon), maxX + epsilon * PagingTuning.rubberBandStiffness, accuracy: 0.000001)
            XCTAssertEqual(clamp(minX - 2 * pageWidth), minX - cap, accuracy: 0.0001)
            XCTAssertEqual(clamp(maxX + 2 * pageWidth), maxX + cap, accuracy: 0.0001)

            // The complete mapping is monotonic and bounded by the same cap.
            let lowerBound = minX - cap
            let upperBound = maxX + cap
            var previous = clamp(minX - 2 * pageWidth)
            var offset = minX - 2 * pageWidth + pageWidth / 20
            while offset <= maxX + 2 * pageWidth {
                let current = clamp(offset)
                XCTAssertGreaterThanOrEqual(current, previous - 0.000001)
                XCTAssertGreaterThanOrEqual(current, lowerBound - 0.000001)
                XCTAssertLessThanOrEqual(current, upperBound + 0.000001)
                previous = current
                offset += pageWidth / 20
            }
        }
    }

    func testClampStrict() {
        XCTAssertEqual(PagingRubberBand.clampStrict(-50, minX: 0, maxX: 2940), 0)
        XCTAssertEqual(PagingRubberBand.clampStrict(5000, minX: 0, maxX: 2940), 2940)
    }
}

/// 速度 EMA 测试(v0.1.6 §9)。
final class PagingVelocityEstimatorTests: XCTestCase {
    func testConstantVelocity() {
        var est = PagingVelocityEstimator()
        est.reset()
        var v: CGFloat = 0
        for i in 1...30 {
            v = est.update(position: CGFloat(i) * 10, timestamp: CFTimeInterval(i) / 60.0)
        }
        // 恒定 600 pt/s, EMA 应收敛接近
        XCTAssertEqual(v, 600, accuracy: 20)
    }

    func testResetClears() {
        var est = PagingVelocityEstimator()
        _ = est.update(position: 10, timestamp: 0)
        _ = est.update(position: 100, timestamp: 0.1)
        est.reset()
        // 重置后第一次 update 不产生速度
        let v = est.update(position: 200, timestamp: 0.2)
        XCTAssertEqual(v, 0)
    }
}
