import Foundation
import Testing
import LaunchCore
@testable import LaunchPlatform

@Suite("PinchAnalyzer 四指捏合分析")
struct PinchAnalyzerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func fingers(
        count: Int,
        distance: Double,
        center: CGPoint = CGPoint(x: 0.5, y: 0.5),
        angle: Double = 0
    ) -> [ContactSample] {
        (0..<count).map { index in
            let a = angle + Double(index) * 2 * .pi / Double(count)
            return ContactSample(
                normalized: CGPoint(
                    x: center.x + distance * cos(a),
                    y: center.y + distance * sin(a)
                ),
                isOnSurface: true
            )
        }
    }

    @Test("少于 4 指 → 无事件")
    func fewFingers() {
        var analyzer = PinchAnalyzer()
        #expect(analyzer.process(contacts: fingers(count: 3, distance: 0.1), now: t0) == nil)
    }

    @Test("4 指稳定距离 → 无事件")
    func stableDistance() {
        var analyzer = PinchAnalyzer()
        _ = analyzer.process(contacts: fingers(count: 4, distance: 0.1), now: t0)
        #expect(analyzer.process(contacts: fingers(count: 4, distance: 0.11), now: t0) == nil)
    }

    @Test("扩张超阈值 → pinchOut")
    func pinchOut() {
        var analyzer = PinchAnalyzer()
        _ = analyzer.process(contacts: fingers(count: 4, distance: 0.1), now: t0)
        // 0.1 → 0.13: 幅度 +0.3 > 0.18
        let event = analyzer.process(
            contacts: fingers(count: 4, distance: 0.13), now: t0.addingTimeInterval(0.05)
        )
        #expect(event == .pinchOut)
    }

    @Test("收缩超阈值 → pinchIn")
    func pinchIn() {
        var analyzer = PinchAnalyzer()
        _ = analyzer.process(contacts: fingers(count: 4, distance: 0.1), now: t0)
        // 0.1 → 0.07: 幅度 -0.3 < -0.18
        let event = analyzer.process(
            contacts: fingers(count: 4, distance: 0.07), now: t0.addingTimeInterval(0.05)
        )
        #expect(event == .pinchIn)
    }

    @Test("冷却期内不重复触发")
    func cooldown() {
        var analyzer = PinchAnalyzer()
        _ = analyzer.process(contacts: fingers(count: 4, distance: 0.1), now: t0)
        let first = analyzer.process(
            contacts: fingers(count: 4, distance: 0.13), now: t0.addingTimeInterval(0.05)
        )
        #expect(first == .pinchOut)
        // 冷却期内再次扩张 → 无事件
        let second = analyzer.process(
            contacts: fingers(count: 4, distance: 0.16), now: t0.addingTimeInterval(0.10)
        )
        #expect(second == nil)
        // 冷却后 → 新事件
        let third = analyzer.process(
            contacts: fingers(count: 4, distance: 0.21), now: t0.addingTimeInterval(0.30)
        )
        #expect(third == .pinchOut)
    }

    @Test("手指离开 → 手势重置(重新起始)")
    func resetOnFingerLoss() {
        var analyzer = PinchAnalyzer()
        _ = analyzer.process(contacts: fingers(count: 4, distance: 0.1), now: t0)
        _ = analyzer.process(contacts: fingers(count: 2, distance: 0.1), now: t0.addingTimeInterval(0.05))
        // 重新 4 指: 重新记录起始距离, 不立即触发
        _ = analyzer.process(contacts: fingers(count: 4, distance: 0.15), now: t0.addingTimeInterval(0.1))
        let event = analyzer.process(
            contacts: fingers(count: 4, distance: 0.20), now: t0.addingTimeInterval(0.15)
        )
        #expect(event == .pinchOut, "重置后首帧为起始(0.15), 次帧 +0.33 超阈值应触发")
    }

    @Test("离表触点被过滤")
    func offSurfaceIgnored() {
        var analyzer = PinchAnalyzer()
        var contacts = fingers(count: 4, distance: 0.1)
        contacts[0] = ContactSample(normalized: contacts[0].normalized, isOnSurface: false)
        #expect(analyzer.process(contacts: contacts, now: t0) == nil, "3 个在表触点不算 4 指")
    }
}
