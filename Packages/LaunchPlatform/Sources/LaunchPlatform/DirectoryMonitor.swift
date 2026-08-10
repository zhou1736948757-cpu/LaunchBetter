import CoreServices
import Foundation

/// 目录监控(FSEvents): 监控应用源目录,输出折叠后的变更摘要(§69-72)。
///
/// - FSEventStream 后台回调 → 折叠(.app root / scope 脏)→ 去抖 → onChange
/// - 事件丢失标志(MustScanSubDirs/UserDropped/KernelDropped/RootChanged)→
///   eventLossDetected, 调用方执行恢复性重扫
/// - C 指针包装保持窄接口;所有跨线程状态由锁保护
public final class DirectoryMonitor: @unchecked Sendable {
    public struct ChangeSummary: Sendable, Equatable {
        /// 目录级脏的 scope
        public let dirtyScopes: Set<String>
        /// 折叠后的 .app 根
        public let dirtyAppRoots: Set<String>
        /// 事件丢失, 需要恢复性重扫
        public let eventLossDetected: Bool

        public init(
            dirtyScopes: Set<String>,
            dirtyAppRoots: Set<String>,
            eventLossDetected: Bool
        ) {
            self.dirtyScopes = dirtyScopes
            self.dirtyAppRoots = dirtyAppRoots
            self.eventLossDetected = eventLossDetected
        }

        public var isEmpty: Bool {
            dirtyScopes.isEmpty && dirtyAppRoots.isEmpty && !eventLossDetected
        }
    }

    /// 当前监控根(规范化; 由 `lock` 保护读写, FSEvents 回调线程读取)。
    private var scopes: [String]
    private let latency: TimeInterval
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var pendingScopes: Set<String> = []
    private var pendingAppRoots: Set<String> = []
    private var pendingEventLoss = false
    private var debounceWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "dev.launchbetter.fsevents", qos: .utility)

    /// 变更回调(去抖后, 后台队列)。
    public var onChange: (@Sendable (ChangeSummary) -> Void)?

    public init(scopes: [String], latency: TimeInterval = 1.0) {
        // FSEvents 始终报告真实路径(/private/var 等), 统一规范化避免前缀失配
        self.scopes = scopes.map {
            PathCanonicalizer.canonicalPath(from: URL(fileURLWithPath: $0))
        }
        self.latency = latency
    }

    deinit {
        stop()
    }

    public func start() {
        guard stream == nil else { return }
        let scopesToWatch = currentScopes()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            DirectoryMonitor.streamCallback,
            &context,
            scopesToWatch as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        lock.lock()
        debounceWork?.cancel()
        debounceWork = nil
        lock.unlock()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    /// 动态更新监控根(设置中自定义源增删后调用)。
    ///
    /// 仅在 scope 集合实际变化时重建 FSEventStream(新增/移除源目录)。
    /// 旧流已停止且 pending 去重, 回调不会携带已移除 scope 的陈旧摘要。
    public func reconfigure(scopes newScopes: [String]) {
        let normalized = newScopes.map {
            PathCanonicalizer.canonicalPath(from: URL(fileURLWithPath: $0))
        }
        lock.lock()
        let changed = normalized != scopes
        if changed {
            scopes = normalized
        }
        lock.unlock()
        guard changed else { return }
        stop()
        start()
    }

    private func currentScopes() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return scopes
    }

    // MARK: - 回调处理

    private static let streamCallback: FSEventStreamCallback = {
        _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let monitor = Unmanaged<DirectoryMonitor>.fromOpaque(info).takeUnretainedValue()
        var paths: [String] = []
        var flags: [FSEventStreamEventFlags] = []
        let pathPointers = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
        for index in 0..<Int(count) {
            if let pathPointer = pathPointers[index] {
                paths.append(String(cString: pathPointer))
                flags.append(eventFlags[index])
            }
        }
        monitor.process(paths: paths, flags: flags)
    }

    private func process(paths: [String], flags: [FSEventStreamEventFlags]) {
        let scopes = currentScopes()
        if ProcessInfo.processInfo.environment["FSEVENTS_DEBUG"] != nil {
            for index in 0..<paths.count {
                fputs("FSEVENTS_DEBUG path=\(paths[index]) flag=\(flags[index])\n", stderr)
            }
        }
        var scopesDirty = Set<String>()
        var appRoots = Set<String>()
        var loss = false
        for index in 0..<paths.count {
            let flag = flags[index]
            if (flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs)) != 0
                || (flag & UInt32(kFSEventStreamEventFlagUserDropped)) != 0
                || (flag & UInt32(kFSEventStreamEventFlagKernelDropped)) != 0
                || (flag & UInt32(kFSEventStreamEventFlagRootChanged)) != 0
                || (flag & UInt32(kFSEventStreamEventFlagEventIdsWrapped)) != 0 {
                loss = true
            }
            switch AppRootFolding.fold(paths[index], scopes: scopes) {
            case .scopeDirty(let scope):
                scopesDirty.insert(scope)
            case .appRoot(let root):
                appRoots.insert(root)
            case .ignored:
                if ProcessInfo.processInfo.environment["FSEVENTS_DEBUG"] != nil {
                    fputs("FSEVENTS_DEBUG ignored path=\(paths[index]) scopes=\(scopes)\n", stderr)
                }
            }
        }
        lock.lock()
        pendingScopes.formUnion(scopesDirty)
        pendingAppRoots.formUnion(appRoots)
        pendingEventLoss = pendingEventLoss || loss
        lock.unlock()
        scheduleDebounce()
    }

    private func scheduleDebounce() {
        lock.lock()
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.deliverPending()
        }
        debounceWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func deliverPending() {
        lock.lock()
        let summary = ChangeSummary(
            dirtyScopes: pendingScopes,
            dirtyAppRoots: pendingAppRoots,
            eventLossDetected: pendingEventLoss
        )
        pendingScopes = []
        pendingAppRoots = []
        pendingEventLoss = false
        lock.unlock()
        if ProcessInfo.processInfo.environment["FSEVENTS_DEBUG"] != nil {
            fputs("FSEVENTS_DEBUG deliver scopes=\(summary.dirtyScopes.count) apps=\(summary.dirtyAppRoots.count) loss=\(summary.eventLossDetected)\n", stderr)
        }
        guard !summary.isEmpty else { return }
        onChange?(summary)
    }
}
