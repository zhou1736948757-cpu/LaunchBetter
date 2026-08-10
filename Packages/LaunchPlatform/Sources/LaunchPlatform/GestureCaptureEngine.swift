import Foundation
import LaunchCore

/// 手势捕获引擎(§115): 四指捏合 + 三指拖动 → 事件;与 UI/Store 完全解耦。
///
/// - 引擎只发出 GestureEvent / ThreeFingerGestureEvent(闭合回调), 不直接操作 LauncherStore/窗口
/// - 回调在系统线程高频到达 → 事件缓冲仅保留最新一帧(PinchAnalyzer / ThreeFingerDragRecognizer 串行消费)
/// - 优雅不可用: 框架缺失/无设备 → isAvailable == false, 不崩溃
/// - 输入监控权限缺失: 回调不到达 → 启动后无回调超时检测
/// - 单一 MTDevice subscription, 按 finger count 路由: 3 指 → 三指拖动, 4+ 指 → pinch(Stage 2 §19)
///
/// 并发模型(C5 M1): 全部可变状态(回调属性 / wrapper / 状态 / 生命周期标志)由单一 NSLock 保护;
/// 生命周期 start/stop/restart 在同一把锁内串行化(注册/注销设备亦在锁内, 消除交错窗口);
/// 回调线程在锁内读取回调快照、锁外派发(避免持锁进入用户代码); running 标志使 stop 后的迟到
/// 回调直接丢弃(不处理/不派发)。
public final class GestureCaptureEngine: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case unavailable          // 框架缺失或无设备
        case running
        case waitingForPermission // 已启动但长时间无回调(可能缺输入监控权限)
    }

    private let lock = NSLock()
    private var multitouch: MultitouchSupport?
    /// 设备生命周期 owner token: 每次 start 递增; stop 只清自己的回调 box(Luna M1-1)。
    private var deviceOwner: UInt64 = 0
    /// 生命周期代数: stop 递增; restart 捕获后校验, 防 stop 后重启(意图竞态, Luna C5)。
    private var lifecycleGeneration = 0
    private var analyzer = PinchAnalyzer()
    private var threeFinger = ThreeFingerDragRecognizer()
    private var pendingSamples: [ContactSample]?
    private var receivedAnyCallback = false
    /// 设备是否成功枚举(>0 = 授权已生效, 回调只在触摸时到达, 不能据此判断权限)
    private var hadDevices = false
    /// 引擎是否在运行(stop/restart 先置 false; 迟到回调据此闸断不处理)。
    private var running = false
    private var status: Status = .unavailable
    private var permissionWatchTimer: DispatchSourceTimer?
    private var lastStartDetailStorage = "notStarted"

    /// 最近一次启动细节诊断。
    public var lastStartDetail: String {
        lock.lock()
        defer { lock.unlock() }
        return lastStartDetailStorage
    }

    private var onGestureStorage: (@Sendable (GestureEvent) -> Void)?
    private var onThreeFingerGestureStorage: (@Sendable (ThreeFingerGestureEvent) -> Void)?
    private var onStatusChangeStorage: (@Sendable (Status) -> Void)?

    /// 手势事件回调(后台队列; 高频路径仅最新帧)。读写加锁(外部安装/卸载与回调线程读并发安全)。
    public var onGesture: (@Sendable (GestureEvent) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return onGestureStorage }
        set { lock.lock(); onGestureStorage = newValue; lock.unlock() }
    }

    /// 三指拖动手势事件回调(后台线程; 与 pinch 同源、按 finger count 路由)。读写加锁。
    public var onThreeFingerGesture: (@Sendable (ThreeFingerGestureEvent) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return onThreeFingerGestureStorage }
        set { lock.lock(); onThreeFingerGestureStorage = newValue; lock.unlock() }
    }

    /// 状态变化回调。读写加锁。
    public var onStatusChange: (@Sendable (Status) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return onStatusChangeStorage }
        set { lock.lock(); onStatusChangeStorage = newValue; lock.unlock() }
    }

    public init() {}

    /// 启动(设备注册失败 → unavailable)。整段临界区持锁: start/stop/restart 互斥,
    /// 注册期间 stop 无法交错(消除 M1 交错窗口); 状态回调锁外派发。
    public func start() {
        lock.lock()
        guard multitouch == nil else {
            lock.unlock()
            return
        }
        guard let wrapper = MultitouchSupport() else {
            lastStartDetailStorage = "dlopenFailed"
            hadDevices = false
            running = false
            let changed = setStatusLocked(.unavailable)
            let callback = changed ? onStatusChangeStorage : nil
            lock.unlock()
            callback?(.unavailable)
            return
        }
        multitouch = wrapper
        deviceOwner &+= 1
        let owner = deviceOwner
        let result = wrapper.startDevices(
            callback: { [weak self] samples, timestamp in
                self?.receive(samples, timestamp: timestamp)
            },
            owner: owner
        )
        let newStatus: Status
        switch result {
        case .ok(let devices):
            lastStartDetailStorage = "ok(devices=\(devices))"
            hadDevices = true
            running = true
            newStatus = .running
        case .noDevices:
            lastStartDetailStorage = "noDevices"
            hadDevices = false
            running = false
            multitouch = nil
            wrapper.stopDevices(owner: deviceOwner)
            newStatus = .unavailable
        case .dlopenFailed:
            lastStartDetailStorage = "dlopenFailed"
            hadDevices = false
            running = false
            multitouch = nil
            wrapper.stopDevices(owner: deviceOwner)
            newStatus = .unavailable
        }

        // 输入监控权限检测: 启动后单次检查(3s 无回调 → waitingForPermission)。
        // 之后的重查由设置界面触发(restart(), Phase 9), 不做周期轮询(性能)。
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.checkPermissionTimeout()
        }
        timer.resume()
        permissionWatchTimer = timer

        let changed = setStatusLocked(newStatus)
        let callback = changed ? onStatusChangeStorage : nil
        lock.unlock()
        callback?(newStatus)
    }

    public func stop() {
        lock.lock()
        running = false
        permissionWatchTimer?.cancel()
        permissionWatchTimer = nil
        let wrapper = multitouch
        multitouch = nil
        // C4: 停止路径清回调; 且 running=false 双保险, 迟到回调不派发。
        onGestureStorage = nil
        onThreeFingerGestureStorage = nil
        onStatusChangeStorage = nil
        lifecycleGeneration += 1
        setStatusLocked(.unavailable)
        let owner = deviceOwner
        lock.unlock()
        wrapper?.stopDevices(owner: owner)
    }

    // MARK: - 回调路径(系统线程, 125-250Hz)

    /// 每帧开销测量(GESTURE_DEBUG 启用时)。
    private var debugFrameCount = 0
    private var debugAccumulatedNanoseconds: UInt64 = 0
    private var debugWindowStart = Date()

    func receive(_ samples: [ContactSample], timestamp: Double) {
        // 单次加锁: 更新最新帧 + 记录收到回调
        lock.lock()
        // C5 M1: stop 后迟到回调直接丢弃(不处理/不派发)。
        guard running else {
            lock.unlock()
            return
        }
        receivedAnyCallback = true
        pendingSamples = samples
        guard let frame = pendingSamples else {
            lock.unlock()
            return
        }
        pendingSamples = nil

        // 分析(纯计算, ~微秒级): 在回调线程就地执行, 不跳线程(§88/§90:
        // 离散事件零额外线程开销; 无触点时无回调 → 空闲 CPU ≈ 0, §6)
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

        if ProcessInfo.processInfo.environment["GESTURE_DEBUG"] != nil {
            debugFrameCount += 1
            debugAccumulatedNanoseconds += elapsed
            if debugFrameCount > 0, Date().timeIntervalSince(debugWindowStart) >= 1.0 {
                let perFrame = Double(debugAccumulatedNanoseconds) / Double(debugFrameCount) / 1_000
                fputs("GESTURE_DEBUG frames/sec=\(debugFrameCount) analysis=\(String(format: "%.1f", perFrame))us/frame touches=\(samples.count)\n", stderr)
                debugFrameCount = 0
                debugAccumulatedNanoseconds = 0
                debugWindowStart = Date()
            }
        }

        // C5 M1: 回调在锁内读取快照, 锁外派发(避免回调重入引擎锁)。
        let gestureHandler = onGestureStorage
        let threeFingerHandler = onThreeFingerGestureStorage
        lock.unlock()

        if let event, let gestureHandler {
            gestureHandler(event)
        }
        if let threeEvent, let threeFingerHandler {
            threeFingerHandler(threeEvent)
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
        let isRunning = running
        lock.unlock()
        guard isRunning else { return }
        // 仅当设备枚举为 0(权限缺失的典型表现)且无回调时提示;
        // 设备已枚举 → 授权已生效, 无回调只是用户尚未触摸(§90 回调驱动, 空闲零开销)
        if !received && !devices {
            setStatus(.waitingForPermission)
        }
    }

    /// 重新注册设备(用户授权后调用)。
    public func restart() {
        lock.lock()
        running = false
        permissionWatchTimer?.cancel()
        permissionWatchTimer = nil
        let wrapper = multitouch
        multitouch = nil
        let owner = deviceOwner
        let gen = lifecycleGeneration
        receivedAnyCallback = false
        hadDevices = false
        lock.unlock()
        wrapper?.stopDevices(owner: owner)
        // 串行意图: 若 teardown 期间被 stop(gen 变化), 不重新启动。
        lock.lock()
        let stillCurrent = lifecycleGeneration == gen
        lock.unlock()
        guard stillCurrent else { return }
        start()
    }

    /// 在锁已持有的前提下更新状态; 返回是否变化(调用方应于解锁后据此派发状态回调)。
    @discardableResult
    private func setStatusLocked(_ newStatus: Status) -> Bool {
        let changed = status != newStatus
        status = newStatus
        return changed
    }

    private func setStatus(_ newStatus: Status) {
        lock.lock()
        let changed = setStatusLocked(newStatus)
        let callback = changed ? onStatusChangeStorage : nil
        lock.unlock()
        callback?(newStatus)
    }

    /// 当前状态。
    public func currentStatus() -> Status {
        lock.lock()
        defer { lock.unlock() }
        return status
    }
}
