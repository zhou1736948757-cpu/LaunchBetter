import Foundation
import LaunchCore

/// 手势捕获引擎(§115): 四指捏合 + 三指拖动 → 事件;与 UI/Store 完全解耦。
///
/// - 引擎只发出 GestureEvent / ThreeFingerGestureEvent(闭合回调), 不直接操作 LauncherStore/窗口
/// - 回调在系统线程高频到达 → 事件缓冲仅保留最新一帧(PinchAnalyzer / ThreeFingerDragRecognizer 串行消费)
/// - 优雅不可用: 框架缺失/无设备 → isAvailable == false, 不崩溃
/// - 输入监控权限缺失: 回调不到达 → 启动后无回调超时检测
/// - 单一 MTDevice subscription, 按 finger count 路由: 3 指 → 三指拖动, 4+ 指 → pinch(Stage 2 §19)
public final class GestureCaptureEngine: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case unavailable          // 框架缺失或无设备
        case running
        case waitingForPermission // 已启动但长时间无回调(可能缺输入监控权限)
    }

    private let lock = NSLock()
    private var multitouch: MultitouchSupport?
    private var analyzer = PinchAnalyzer()
    private var threeFinger = ThreeFingerDragRecognizer()
    private var pendingSamples: [ContactSample]?
    private var receivedAnyCallback = false
    /// 设备是否成功枚举(>0 = 授权已生效, 回调只在触摸时到达, 不能据此判断权限)
    private var hadDevices = false
    private var status: Status = .unavailable
    private var permissionWatchTimer: DispatchSourceTimer?
    /// 最近一次启动细节诊断。
    public private(set) var lastStartDetail = "notStarted"

    /// 手势事件回调(后台队列; 高频路径仅最新帧)。
    public var onGesture: (@Sendable (GestureEvent) -> Void)?

    /// 三指拖动手势事件回调(后台线程; 与 pinch 同源、按 finger count 路由)。
    public var onThreeFingerGesture: (@Sendable (ThreeFingerGestureEvent) -> Void)?

    /// 状态变化回调。
    public var onStatusChange: (@Sendable (Status) -> Void)?

    public init() {}

    /// 启动(设备注册失败 → unavailable)。
    public func start() {
        lock.lock()
        guard multitouch == nil else {
            lock.unlock()
            return
        }
        let wrapper = MultitouchSupport()
        lock.unlock()
        guard let wrapper else {
            lastStartDetail = "dlopenFailed"
            setStatus(.unavailable)
            return
        }
        lock.lock()
        multitouch = wrapper
        lock.unlock()

        let result = wrapper.startDevices { [weak self] samples, timestamp in
            self?.receive(samples, timestamp: timestamp)
        }
        switch result {
        case .ok(let devices):
            lastStartDetail = "ok(devices=\(devices))"
            hadDevices = true
            setStatus(.running)
        case .noDevices:
            lastStartDetail = "noDevices"
            hadDevices = false
            setStatus(.unavailable)
        case .dlopenFailed:
            lastStartDetail = "dlopenFailed"
            hadDevices = false
            setStatus(.unavailable)
        }

        // 输入监控权限检测: 启动后单次检查(3s 无回调 → waitingForPermission)。
        // 之后的重查由设置界面触发(restart(), Phase 9), 不做周期轮询(性能)。
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.checkPermissionTimeout()
        }
        timer.resume()
        lock.lock()
        permissionWatchTimer = timer
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        permissionWatchTimer?.cancel()
        permissionWatchTimer = nil
        let wrapper = multitouch
        multitouch = nil
        lock.unlock()
        wrapper?.stopDevices()
        setStatus(.unavailable)
    }

    // MARK: - 回调路径(系统线程, 125-250Hz)

    /// 每帧开销测量(GESTURE_DEBUG 启用时)。
    private var debugFrameCount = 0
    private var debugAccumulatedNanoseconds: UInt64 = 0
    private var debugWindowStart = Date()

    private func receive(_ samples: [ContactSample], timestamp: Double) {
        // 单次加锁: 更新最新帧 + 记录收到回调
        lock.lock()
        receivedAnyCallback = true
        pendingSamples = samples

        // 分析(纯计算, ~微秒级): 在回调线程就地执行, 不跳线程(§88/§90:
        // 离散事件零额外线程开销; 无触点时无回调 → 空闲 CPU ≈ 0, §6)
        guard let frame = pendingSamples else {
            lock.unlock()
            return
        }
        pendingSamples = nil

        let start = DispatchTime.now().uptimeNanoseconds
        var analyzer = self.analyzer
        let event = analyzer.process(contacts: frame, now: Date(timeIntervalSince1970: timestamp))
        self.analyzer = analyzer
        // 三指: 提取活跃触点归一化坐标 → 纯逻辑识别(微秒级, 就地执行)
        var threeFinger = self.threeFinger
        let activePoints = frame
            .filter(\.isOnSurface)
            .map(\.normalized)
        threeFingerRawFrameCount += 1
        let threeEvent = threeFinger.process(points: activePoints)
        self.threeFinger = threeFinger
        if let threeEvent {
            switch threeEvent {
            case .began: threeFingerBeginCount += 1
            case .changed: threeFingerUpdateCount += 1
            case .ended: threeFingerEndCount += 1
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        lock.unlock()

        if ProcessInfo.processInfo.environment["GESTURE_DEBUG"] != nil {
            debugFrameCount += 1
            debugAccumulatedNanoseconds += elapsed
            let window = debugWindowStart
            if Date().timeIntervalSince(window) >= 1.0 {
                let perFrame = debugFrameCount > 0
                    ? Double(debugAccumulatedNanoseconds) / Double(debugFrameCount) / 1_000
                    : 0
                fputs("GESTURE_DEBUG frames/sec=\(debugFrameCount) analysis=\(String(format: "%.1f", perFrame))us/frame touches=\(samples.count)\n", stderr)
                debugFrameCount = 0
                debugAccumulatedNanoseconds = 0
                debugWindowStart = Date()
            }
        }

        if let event {
            onGesture?(event)
        }
        if let threeEvent, let onThreeFingerGesture {
            onThreeFingerGesture(threeEvent)
        }
    }

    // MARK: - 三指诊断计数(Stage 2 §37)

    /// 三指原始帧计数 / 各阶段事件计数。
    private var threeFingerRawFrameCount = 0
    private var threeFingerBeginCount = 0
    private var threeFingerUpdateCount = 0
    private var threeFingerEndCount = 0

    /// 三指诊断快照。
    public func threeFingerStats() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "rawFrames=\(threeFingerRawFrameCount) begin=\(threeFingerBeginCount) update=\(threeFingerUpdateCount) end=\(threeFingerEndCount)"
    }

    private func checkPermissionTimeout() {
        lock.lock()
        let received = receivedAnyCallback
        let devices = hadDevices
        lock.unlock()
        // 仅当设备枚举为 0(权限缺失的典型表现)且无回调时提示;
        // 设备已枚举 → 授权已生效, 无回调只是用户尚未触摸(§90 回调驱动, 空闲零开销)
        if !received && !devices {
            setStatus(.waitingForPermission)
        }
    }

    /// 重新注册设备(用户授权后调用)。
    public func restart() {
        lock.lock()
        permissionWatchTimer?.cancel()
        permissionWatchTimer = nil
        let wrapper = multitouch
        multitouch = nil
        receivedAnyCallback = false
        hadDevices = false
        lock.unlock()
        wrapper?.stopDevices()
        start()
    }

    private func setStatus(_ newStatus: Status) {
        lock.lock()
        let changed = status != newStatus
        status = newStatus
        lock.unlock()
        if changed {
            onStatusChange?(newStatus)
        }
    }

    /// 当前状态。
    public func currentStatus() -> Status {
        lock.lock()
        defer { lock.unlock() }
        return status
    }
}
