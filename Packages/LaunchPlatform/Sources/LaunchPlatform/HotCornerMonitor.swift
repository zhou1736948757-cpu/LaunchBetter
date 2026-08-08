import AppKit
import Foundation
import LaunchCore

/// 热角监控(legacy 参数: 0.05s 轮询 → 0.1s, 容差 10pt, 停留 0.3s, 冷却 1s)。
/// 事件 → 动作;与 UI 解耦, 由协调器决策。
public final class HotCornerMonitor: @unchecked Sendable {
    private let config: () -> HotCornerConfig
    private var timer: Timer?
    private var dwellStart: Date?
    private var lastActionAt: Date?
    private let lock = NSLock()

    /// 动作回调(主线程)。
    public var onAction: (@Sendable (HotCornerAction) -> Void)?

    public init(config: @escaping () -> HotCornerConfig) {
        self.config = config
    }

    public func start() {
        lock.lock()
        guard timer == nil else {
            lock.unlock()
            return
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        timer?.invalidate()
        timer = nil
        lock.unlock()
    }

    private func tick() {
        let corners = config()
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            return
        }
        let frame = screen.frame
        let tolerance: CGFloat = 10
        var detected: HotCornerAction?
        let top = frame.maxY - point.y < tolerance
        let bottom = point.y - frame.minY < tolerance
        let left = point.x - frame.minX < tolerance
        let right = frame.maxX - point.x < tolerance
        if top && left { detected = corners.topLeft }
        else if top && right { detected = corners.topRight }
        else if bottom && left { detected = corners.bottomLeft }
        else if bottom && right { detected = corners.bottomRight }
        else {
            dwellStart = nil
            return
        }
        guard detected != .none else {
            dwellStart = nil
            return
        }
        // 停留 0.3s 才触发
        if dwellStart == nil {
            dwellStart = Date()
            return
        }
        guard Date().timeIntervalSince(dwellStart!) >= 0.3 else { return }
        // 冷却 1s
        if let last = lastActionAt, Date().timeIntervalSince(last) < 1.0 { return }
        lastActionAt = Date()
        dwellStart = nil
        onAction?(detected!)
    }
}
