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
    /// 当前已触发动作的角(触发后鼠标仍在同角不重复触发, 离开才重置)。
    private var activeCorner: String?
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

    /// 屏幕命中判定：包含 min/max 边界。
    ///
    /// `CGRect.contains` 不含 maxX/maxY。鼠标压到屏幕最顶/最右边时，
    /// `NSEvent.mouseLocation` 会返回恰好等于 frame.maxY/maxX 的坐标，
    /// 用 contains 会把热角整体漏掉（旧版实现用 <= 包含边界）。
    public static func screenFrameContains(_ frame: NSRect, point: NSPoint) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX
            && point.y >= frame.minY && point.y <= frame.maxY
    }

    private func tick() {
        let corners = config()
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            Self.screenFrameContains($0.frame, point: point)
        }) else {
            return
        }
        let frame = screen.frame
        let tolerance: CGFloat = 24
        var detected: HotCornerAction?
        var cornerKey: String?
        let top = frame.maxY - point.y < tolerance
        let bottom = point.y - frame.minY < tolerance
        let left = point.x - frame.minX < tolerance
        let right = frame.maxX - point.x < tolerance
        if top && left { detected = corners.topLeft; cornerKey = "topLeft" }
        else if top && right { detected = corners.topRight; cornerKey = "topRight" }
        else if bottom && left { detected = corners.bottomLeft; cornerKey = "bottomLeft" }
        else if bottom && right { detected = corners.bottomRight; cornerKey = "bottomRight" }
        else {
            // 离开角: 重置 dwell 与 activeCorner(允许下次再触发)
            dwellStart = nil
            activeCorner = nil
            return
        }
        // 鼠标仍停留在同一角(已触发过)→ 不重复触发(toggle 不会闪开关)
        if activeCorner == cornerKey {
            return
        }
        guard let detected, detected != HotCornerAction.none else {
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
        activeCorner = cornerKey
        onAction?(detected)
    }
}
