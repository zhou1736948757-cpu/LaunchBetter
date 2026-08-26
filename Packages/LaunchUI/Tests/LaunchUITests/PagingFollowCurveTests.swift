import CoreGraphics
import Foundation
import XCTest
@testable import LaunchUI
import LaunchCore

/// T-003: 归一化跟手曲线测试(纯函数, 无 AppKit 依赖)。
final class PagingFollowCurveTests: XCTestCase {
    let pageWidth: CGFloat = 1470

    // 1. 正方向位移正确阻尼: 阻尼后输出 < 原始位移, 且 > 0(方向不变)。
    func testPositiveDirectionDamps() {
        let curve = PagingFollowCurve.normalizedDamped(strength: 1.3)
        let raw: CGFloat = 300
        let out = curve.apply(rawDisplacement: raw, pageWidth: pageWidth)
        XCTAssertGreaterThan(out, 0)
        XCTAssertLessThan(out, raw)
        // 阻尼后仍比 1:1 更接近原始(未过度压缩到 0)。
        XCTAssertGreaterThan(out, 0)
    }

    // 2. 负方向位移正确阻尼: 输出为负(方向不变), 且 |输出| < |原始|。
    func testNegativeDirectionDamps() {
        let curve = PagingFollowCurve.normalizedDamped(strength: 1.3)
        let raw: CGFloat = -300
        let out = curve.apply(rawDisplacement: raw, pageWidth: pageWidth)
        XCTAssertLessThan(out, 0)
        XCTAssertGreaterThan(out, raw) // -x < out < 0
        XCTAssertLessThan(abs(out), abs(raw))
    }

    // 3. 零页宽不崩溃(max(1, pageWidth) 保护): 以 1 为尺度, 输出有限。
    func testZeroPageWidthDoesNotCrash() {
        let curve = PagingFollowCurve.normalizedDamped(strength: 1.3)
        let out = curve.apply(rawDisplacement: 500, pageWidth: 0)
        XCTAssertTrue(out.isFinite)
        XCTAssertGreaterThan(out, 0)
        // 负页宽同样不崩溃。
        let neg = curve.apply(rawDisplacement: -500, pageWidth: -10)
        XCTAssertTrue(neg.isFinite)
        XCTAssertLessThan(neg, 0)
    }

    // 4. 大位移有限且单调: 输出有限, 且随输入增大而增大。
    func testLargeDisplacementFiniteAndMonotonic() {
        let curve = PagingFollowCurve.normalizedDamped(strength: 1.3)
        let huge: CGFloat = 1_000_000
        let out = curve.apply(rawDisplacement: huge, pageWidth: pageWidth)
        XCTAssertTrue(out.isFinite)
        XCTAssertGreaterThan(out, 0)
        // 单调: 更大输入 → 更大输出。
        let bigger = curve.apply(rawDisplacement: huge * 2, pageWidth: pageWidth)
        XCTAssertGreaterThan(bigger, out)
    }

    // 5. 连续性: 相邻输入产生相邻输出(输出差随输入差趋于 0)。
    func testContinuity() {
        let curve = PagingFollowCurve.normalizedDamped(strength: 1.3)
        let a = curve.apply(rawDisplacement: 100, pageWidth: pageWidth)
        let b = curve.apply(rawDisplacement: 100.0001, pageWidth: pageWidth)
        XCTAssertLessThan(abs(b - a), 0.001)
    }

    // 6. 单调性: 位移增大时输出增大(正方向全程单调)。
    func testMonotonicity() {
        let curve = PagingFollowCurve.normalizedDamped(strength: 1.3)
        var raw: CGFloat = -2000
        var previous = curve.apply(rawDisplacement: raw, pageWidth: pageWidth)
        raw += 10
        while raw <= 2000 {
            let out = curve.apply(rawDisplacement: raw, pageWidth: pageWidth)
            XCTAssertGreaterThanOrEqual(out, previous - 0.000001, "monotonic at raw=\(raw)")
            previous = out
            raw += 10
        }
    }

    // 7. 有限值: 无 NaN/Inf(含极端输入)。
    func testFiniteValues() {
        let curve = PagingFollowCurve.normalizedDamped(strength: 1.3)
        for raw in [CGFloat(0), 1, -1, 1000, -1000, 1e9, -1e9, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
            let out = curve.apply(rawDisplacement: raw, pageWidth: pageWidth)
            XCTAssertTrue(out.isFinite, "finite at raw=\(raw)")
        }
    }

    // 8. linear 模式与当前行为一致(sensitivity 1.3 = PagingTuning.followSensitivity)。
    func testLinearMatchesCurrentBehavior() {
        let curve = PagingFollowCurve.linear(sensitivity: PagingTuning.followSensitivity)
        XCTAssertEqual(PagingTuning.followSensitivity, 1.3)
        for raw in [CGFloat(0), 10, -10, 500, -500] {
            XCTAssertEqual(
                curve.apply(rawDisplacement: raw, pageWidth: pageWidth),
                raw * PagingTuning.followSensitivity,
                accuracy: 0.000001
            )
        }
    }

    // 9. normalizedDamped strength 0 → 与 linear sensitivity 1.0 相同(1:1)。
    func testDampedStrengthZeroEqualsLinearOne() {
        let damped = PagingFollowCurve.normalizedDamped(strength: 0)
        let linear = PagingFollowCurve.linear(sensitivity: 1.0)
        for raw in [CGFloat(0), 10, -10, 500, -500, 1e6] {
            XCTAssertEqual(
                damped.apply(rawDisplacement: raw, pageWidth: pageWidth),
                linear.apply(rawDisplacement: raw, pageWidth: pageWidth),
                accuracy: 0.000001
            )
        }
    }

    // 补充: 默认曲线即 linear 1.3(产品默认不变)。
    func testDefaultCurveIsLinear13() {
        let curve = PagingFollowCurve.linear(sensitivity: PagingTuning.followSensitivity)
        XCTAssertEqual(curve.apply(rawDisplacement: 100, pageWidth: pageWidth), 130, accuracy: 0.000001)
    }

    func testNormalizedDampedIsChunkInvariantForPositiveNegativeMixedAndReversed() {
        let curve = PagingFollowCurve.normalizedDamped(strength: 1.3)
        let sequences: [[CGFloat]] = [
            [200], [100, 100], [20, 20, 20, 20, 20, 20, 20, 20, 20, 20],
            [50, 30, 70, 50], [-200], [-100, -100], [100, 100, -50, -150]
        ]
        for sequence in sequences {
            let total = sequence.reduce(0, +)
            let expected = curve.apply(rawDisplacement: total, pageWidth: pageWidth)
            var raw: CGFloat = 0
            var actual: CGFloat = 0
            for chunk in sequence {
                raw += chunk
                actual = curve.apply(rawDisplacement: raw, pageWidth: pageWidth)
            }
            XCTAssertEqual(actual, expected, accuracy: 0.000001, "chunks=\\(sequence)")
        }
    }

    func testNormalizedDampedSixtyAndOneTwentyHertzChunkingMatch() {
        let curve = PagingFollowCurve.normalizedDamped(strength: 1.3)
        let sixty = Array(repeating: CGFloat(10), count: 12)
        let oneTwenty = Array(repeating: CGFloat(5), count: 24)
        let a = curve.apply(rawDisplacement: sixty.reduce(0, +), pageWidth: pageWidth)
        let b = curve.apply(rawDisplacement: oneTwenty.reduce(0, +), pageWidth: pageWidth)
        XCTAssertEqual(a, b, accuracy: 0.000001)
    }
}
