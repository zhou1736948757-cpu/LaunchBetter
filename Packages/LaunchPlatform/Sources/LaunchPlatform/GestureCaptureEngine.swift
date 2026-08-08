import Foundation

/// 手势捕获引擎(§115): 四指捏合 → 事件;与 UI/Store 完全解耦。
///
/// - 引擎只发出 GestureEvent(闭合回调), 不直接操作 LauncherStore/窗口
/// - 回调在系统线程高频到达 → 事件缓冲仅保留最新一帧(PinchAnalyzer 串行消费)
/// - 优雅不可用: 框架缺失/无设备 → isAvailable == false, 不崩溃
/// - 输入监控权限缺失: 回调不到达 → 启动后无回调超时检测
public final class GestureCaptureEngine: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case unavailable          // 框架缺失或无设备
        case running
        case waitingForPermission // 已启动但长时间无回调(可能缺输入监控权限)
    }

    private let lock = NSLock()
    private var multitouch: MultitouchSupport?
    private var analyzer = PinchAnalyzer()
    private var pendingSamples: [ContactSample]?
    private var receivedAnyCallback = false
    private var status: Status = .unavailable
    private var permissionWatchTimer: DispatchSourceTimer?

    /// 手势事件回调(后台队列; 高频路径仅最新帧)。
    public var onGesture: (@Sendable (GestureEvent) -> Void)?

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
            setStatus(.unavailable)
            return
        }
        lock.lock()
        multitouch = wrapper
        lock.unlock()

        let registered = wrapper.startDevices { [weak self] samples in
            self?.receive(samples)
        }
        setStatus(registered > 0 ? .running : .unavailable)

        // 输入监控权限检测: 3 秒无回调 → 提示(回调不会因权限到达)
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

    // MARK: - 回调路径(系统线程)

    private func receive(_ samples: [ContactSample]) {
        lock.lock()
        receivedAnyCallback = true
        pendingSamples = samples
        lock.unlock()
        // 串行消费最新帧
        lock.lock()
        let frame = pendingSamples
        pendingSamples = nil
        lock.unlock()
        guard let frame else { return }
        var analyzer = self.analyzer
        let event = analyzer.process(contacts: frame, now: Date())
        self.analyzer = analyzer
        if let event {
            onGesture?(event)
        }
    }

    private func checkPermissionTimeout() {
        lock.lock()
        let received = receivedAnyCallback
        let isRunning = multitouch != nil
        lock.unlock()
        if isRunning && !received {
            setStatus(.waitingForPermission)
        }
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
