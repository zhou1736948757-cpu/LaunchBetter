import Foundation
import LaunchCore
import Testing
@testable import LaunchPlatform

/// §C4/C5 生命周期: GestureCaptureEngine 停止路径清回调; M1 并发同步修复。
@Suite("GestureCaptureEngine 生命周期")
struct GestureEngineLifecycleTests {
    @Test("stop 清空回调: 停止后不得再向订阅者派发")
    func stopClearsCallbacks() {
        let engine = GestureCaptureEngine()
        engine.onGesture = { _ in }
        engine.onThreeFingerGesture = { _ in }
        engine.onStatusChange = { _ in }

        engine.stop()

        #expect(engine.onGesture == nil)
        #expect(engine.onThreeFingerGesture == nil)
        #expect(engine.onStatusChange == nil)
        #expect(engine.currentStatus() == .unavailable)
    }

    @Test("stop 后迟到回调不派发(running=false 闸断)")
    func noDispatchAfterStop() {
        let engine = GestureCaptureEngine()
        engine.stop()

        let dispatched = Counter()
        engine.onGesture = { _ in dispatched.increment() }
        engine.onThreeFingerGesture = { _ in dispatched.increment() }

        engine.receive(pinchSamples(distance: 0.1), timestamp: 1_000)
        engine.receive(pinchSamples(distance: 0.13), timestamp: 1_000.05)

        #expect(dispatched.current() == 0, "stop 后 receive 必须被 running 闸断")
    }

    @Test("并发 start/stop/restart: 无死锁、最终停止态一致")
    func concurrentLifecycleStress() {
        let engine = GestureCaptureEngine()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "c5.lifecycle", attributes: .concurrent)
        for _ in 0..<4 {
            queue.async(group: group) {
                for _ in 0..<8 {
                    engine.start()
                    engine.stop()
                }
                engine.restart()
                engine.stop()
            }
        }
        _ = group.wait(timeout: .now() + 30)
        engine.stop()
        #expect(engine.currentStatus() == .unavailable)
        #expect(engine.onGesture == nil)
        #expect(engine.onThreeFingerGesture == nil)
        #expect(engine.onStatusChange == nil)
    }

    @Test("并发 install/uninstall 回调与 stop 竞争: 无崩溃、最终清空")
    func concurrentCallbackInstallAndStop() {
        let engine = GestureCaptureEngine()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "c5.callbacks", attributes: .concurrent)
        for _ in 0..<12 {
            queue.async(group: group) {
                for _ in 0..<20 {
                    engine.onGesture = { _ in }
                    engine.onThreeFingerGesture = { _ in }
                    engine.onStatusChange = { _ in }
                    engine.onGesture = nil
                    engine.onThreeFingerGesture = nil
                    engine.onStatusChange = nil
                }
            }
        }
        for _ in 0..<4 {
            queue.async(group: group) {
                engine.start()
                engine.stop()
            }
        }
        _ = group.wait(timeout: .now() + 30)
        engine.stop()
        #expect(engine.onGesture == nil)
        #expect(engine.onThreeFingerGesture == nil)
        #expect(engine.onStatusChange == nil)
    }

    // MARK: - 派发路径(依赖设备; 无设备/无框架时跳过)

    @Test("运行中三指 began 派发, stop 后静默")
    func threeFingerDispatchThenSilent() {
        let engine = GestureCaptureEngine()
        engine.start()
        guard engine.currentStatus() == .running else {
            engine.stop()
            return
        }

        let events = EventLog<ThreeFingerGestureEvent>()
        engine.onThreeFingerGesture = { events.append($0) }
        engine.receive(threeFingerSamples(offset: 0), timestamp: 1_000)
        engine.receive(threeFingerSamples(offset: 0.01), timestamp: 1_000.005)
        engine.receive(threeFingerSamples(offset: 0.02), timestamp: 1_000.010)
        let began = events.all().filter { $0 == .began }.count
        #expect(began == 1, "连续确认帧后应派发 began")

        engine.stop()
        let before = events.all().count
        engine.receive(threeFingerSamples(offset: 0.03), timestamp: 1_000.015)
        #expect(events.all().count == before, "stop 后不得再派发")
    }

    @Test("运行中四指捏合派发, stop 后静默")
    func pinchDispatchThenSilent() {
        let engine = GestureCaptureEngine()
        engine.start()
        guard engine.currentStatus() == .running else {
            engine.stop()
            return
        }

        let events = EventLog<GestureEvent>()
        engine.onGesture = { events.append($0) }
        engine.receive(pinchSamples(distance: 0.1), timestamp: 1_000)
        engine.receive(pinchSamples(distance: 0.13), timestamp: 1_000.05)
        let outs = events.all().filter { $0 == .pinchOut }.count
        #expect(outs == 1, "扩张超阈值应派发 pinchOut")

        engine.stop()
        let before = events.all().count
        engine.receive(pinchSamples(distance: 0.16), timestamp: 1_000.1)
        #expect(events.all().count == before, "stop 后不得再派发")
    }

    // MARK: - 样本构造

    private func pinchSamples(distance: Double) -> [ContactSample] {
        (0..<4).map { index in
            let angle = Double(index) * 2 * .pi / 4
            return ContactSample(
                normalized: CGPoint(
                    x: 0.5 + distance * cos(angle),
                    y: 0.5 + distance * sin(angle)
                ),
                isOnSurface: true
            )
        }
    }

    private func threeFingerSamples(offset: CGFloat) -> [ContactSample] {
        [(0.4, 0.5), (0.5, 0.5), (0.6, 0.5)].map { x, y in
            ContactSample(normalized: CGPoint(x: x + offset, y: y), isOnSurface: true)
        }
    }
}

/// 线程安全计数器(测试用)。
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock(); value += 1; lock.unlock()
    }
    func current() -> Int {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

/// 线程安全事件日志(测试用)。
private final class EventLog<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) {
        lock.lock(); items.append(item); lock.unlock()
    }
    func all() -> [T] {
        lock.lock(); defer { lock.unlock() }; return items
    }
}
