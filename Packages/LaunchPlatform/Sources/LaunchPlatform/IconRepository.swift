import AppKit
import CoreGraphics
import Foundation
import LaunchCore
import os

/// 图标存储库(actor): 内存 LRU → 磁盘 → 实时提取(§75 管道)。
///
/// 管道(严格顺序):
/// ```
/// image(for:) → memory hit? → 返回
///            → inFlight[key]? → 等待共享任务
///            → 创建任务并注册(首个挂起点之前)→ 磁盘 → 实时 → 内存 + 异步磁盘写
/// ```
/// 约束:
/// - in-flight 条目必须在首个挂起点前注册(防重复磁盘请求, §75)
/// - 消费者取消不杀死共享任务(§81): 取消语义 = 不应用结果给该消费者
/// - 图标完成只更新对应缓存条目,不触发目录/布局刷新
/// - 内存压力: 保留集裁剪 → 激进裁剪 → 全清(§77);磁盘缓存保留
/// - live 结果不再二次光栅化(§A5): provider 已输出精确 pixelSize 显示就绪位图
/// - 磁盘写交独立 DiskCacheWriter(§A6): resolve 不等 PNG encode + 原子写盘
public actor IconRepository {
    public enum MemoryPressureLevel: Sendable {
        case hidden        // 启动器隐藏: 裁剪低优先级
        case warning       // 系统警告: 激进裁剪
        case critical      // 系统临界: 内存全清(磁盘保留)
    }

    private let memoryCache: IconMemoryCache
    private let diskCache: IconDiskCache
    private let provider: any AppIconProviding
    private let diskWriter: any IconDiskWriting

    private var inFlight: [IconKey: Task<CGImage?, Never>] = [:]
    private let log = OSLog(subsystem: "dev.launchbetter", category: "IconRepository")
    private let memoryPressureSource: DispatchSourceMemoryPressure

    // MARK: - 统计(诊断/基准)

    public private(set) var memoryHits = 0
    public private(set) var diskHits = 0
    public private(set) var liveResolves = 0

    /// 已提交给 writer 的磁盘写请求数(写异步执行;成功与否由 writer 记录,§A6)。
    public private(set) var diskWrites = 0

    public struct IconStats: Sendable {
        public let memoryHits: Int
        public let diskHits: Int
        public let liveResolves: Int
        public let diskWrites: Int
    }

    /// 统计快照(跨 actor 边界的 Sendable 值)。
    public func stats() -> IconStats {
        IconStats(
            memoryHits: memoryHits,
            diskHits: diskHits,
            liveResolves: liveResolves,
            diskWrites: diskWrites
        )
    }

    public init(
        memoryCache: IconMemoryCache,
        diskCache: IconDiskCache,
        provider: any AppIconProviding,
        diskWriter: (any IconDiskWriting)? = nil
    ) {
        self.memoryCache = memoryCache
        self.diskCache = diskCache
        self.provider = provider
        self.diskWriter = diskWriter ?? DiskCacheWriter(rootURL: diskCache.rootURL)

        // L4/F5: 后台一次性 prune 过期磁盘缓存(不阻塞 init)。prune 只删 30 天前的
        // 旧文件,与 DiskCacheWriter 的新写入按 age 隔离;任务纳入 shutdown 生命周期。
        // 必须在首个 self 捕获(下方 setEventHandler [weak self])之前初始化 pruneTask。
        let prune = Task.detached(priority: .utility) {
            _ = diskCache.pruneStaleFiles(
                olderThan: Date().addingTimeInterval(-IconDiskCache.defaultRetentionInterval)
            )
        }
        self.pruneTask = prune

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility)
        )
        self.memoryPressureSource = source
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let critical = source.data.contains(.critical)
            let warning = source.data.contains(.warning)
            Task { await self?.handleSystemMemoryPressure(critical: critical, warning: warning) }
        }
        source.resume()
    }

    /// 显式生命周期收尾(M3): 取消内存压力源、清除 in-flight 与内存缓存,
    /// 并等待已提交的磁盘写完成(§A6 干净 shutdown)。
    /// 幂等;调用后存储库仍可用于读取(缓存重建),但不再接收系统内存压力事件。
    public func shutdown() async {
        guard !shutdownCalled else { return }
        shutdownCalled = true
        memoryPressureSource.cancel()
        inFlight.removeAll()
        memoryCache.removeAll()
        // F5: 等待后台 prune 完成后再 flush。prune 只删 30 天前旧文件,
        // 与 writer 的新写入按 age 隔离,不会互相影响。
        if let pruneTask {
            await pruneTask.value
        }
        await diskWriter.flush()
    }

    private var shutdownCalled = false

    /// 启动时后台 prune 任务(F5): shutdown 等待其完成。
    /// 用 let: actor 的 nonisolated init 中只能初始化性地写入属性,
    /// var 一旦被默认值初始化就不能再从 init 写入(编译错误)。
    /// 任务完成后自行释放,不置 nil。
    private let pruneTask: Task<Void, Never>?

    /// 等待所有已提交的磁盘写完成(干净 shutdown / 测试同步)。幂等。
    public func waitForPendingDiskWrites() async {
        await diskWriter.flush()
    }

    /// 请求图标(异步,幂等)。
    ///
    /// 取消语义(M1, §81): 消费者取消后,本方法在返回点检查 `Task.isCancelled`
    /// 并返回 nil —— 取消只影响该消费者,不取消共享 in-flight 任务。
    /// 陈旧防护(M2): 请求携带应用代际;invalidate 后旧任务不发布结果。
    public func image(for key: IconKey) async -> CGImage? {
        if Task.isCancelled { return nil }
        if let cached = memoryCache.lookup(key) {
            memoryHits += 1
            os_signpost(.event, log: log, name: "IconMemoryHit")
            return Task.isCancelled ? nil : cached
        }
        if let existing = inFlight[key] {
            let result = await existing.value
            if inFlight[key] == existing {
                inFlight.removeValue(forKey: key)
            }
            return Task.isCancelled ? nil : result
        }
        let generation = appGenerations[key.appID] ?? 0
        let task: Task<CGImage?, Never> = Task { [weak self] in
            guard let self else { return nil }
            return await self.resolve(key, generation: generation)
        }
        inFlight[key] = task
        let result = await task.value
        if inFlight[key] == task {
            inFlight.removeValue(forKey: key)
        }
        return Task.isCancelled ? nil : result
    }

    /// 内存压力处理: 保留指定键(可见页/最近使用),逐出其余。
    public func trimMemory(keeping keys: Set<IconKey>, level: MemoryPressureLevel) {
        switch level {
        case .hidden:
            memoryCache.trim(keeping: keys)
        case .warning:
            memoryCache.trim(keeping: keys)
        case .critical:
            memoryCache.removeAll()
        }
    }

    /// 启动器隐藏: 裁剪低优先级,保留最近使用条目(§77)。
    public func trimForHidden() {
        memoryCache.trim(recentCount: 32)
    }

    /// 内容失效(应用图标更新): 清内存中该应用条目;磁盘按新版本键自然隔离。
    /// 同时提升该应用的代际(in-flight 旧任务不得发布结果, M2)。
    public func invalidate(appID: AppID) {
        for key in memoryCache.keys() where key.appID == appID {
            memoryCache.remove(key: key)
        }
        appGenerations[appID, default: 0] &+= 1
    }

    /// 每应用的代际(陈旧结果防护, M2)。
    private var appGenerations: [AppID: UInt64] = [:]

    // MARK: - 解析管道

    private func resolve(_ key: IconKey, generation: UInt64) async -> CGImage? {
        // 磁盘命中
        if let diskImage = diskCache.load(key: key) {
            guard isCurrent(key.appID, generation: generation) else { return nil }
            diskHits += 1
            os_signpost(.event, log: log, name: "IconDiskHit")
            let decoded = preDecode(diskImage, pixelSize: key.pixelSize)
            if let decoded {
                storeInMemory(decoded, key: key)
            }
            return decoded ?? diskImage
        }

        // 实时提取
        guard let record = recordURL(for: key) else { return nil }
        os_signpost(.begin, log: log, name: "IconLiveResolve")
        let live = await provider.liveIcon(for: record, pixelSize: key.pixelSize)
        os_signpost(.end, log: log, name: "IconLiveResolve")
        guard let live else { return nil }
        guard isCurrent(key.appID, generation: generation) else { return nil }
        liveResolves += 1

        // A5: live provider 已输出"精确 pixelSize + 显示就绪"位图,不再二次光栅化;
        // 仅当尺寸与请求不符时回退 preDecode(防御,provider 契约之外)。
        let decoded = isDisplayReady(live, pixelSize: key.pixelSize)
            ? live
            : (preDecode(live, pixelSize: key.pixelSize) ?? live)
        storeInMemory(decoded, key: key)
        // A6: 磁盘写交独立 writer(有界/按 key 去重/异步),resolve 不等写盘。
        if await diskWriter.enqueue(key: key, image: decoded) {
            diskWrites += 1
        }
        // M2: 入队挂起点后复验代际,陈旧任务不得发布结果。
        guard isCurrent(key.appID, generation: generation) else { return nil }
        return decoded
    }

    private func isCurrent(_ appID: AppID, generation: UInt64) -> Bool {
        (appGenerations[appID] ?? 0) == generation
    }

    private func recordURL(for key: IconKey) -> URL? {
        // 从 AppID(路径)反查 URL;AppID 即规范化路径
        URL(fileURLWithPath: key.appID.rawValue)
    }

    private func storeInMemory(_ image: CGImage, key: IconKey) {
        memoryCache.insert(image, for: key)
    }

    /// A5: live provider 契约输出"精确 pixelSize 显示就绪"位图(渲染自 NSImage, 非惰性解码)。
    /// 尺寸与请求一致视为显示就绪,跳过二次光栅化。
    private func isDisplayReady(_ image: CGImage, pixelSize: Int) -> Bool {
        image.width == pixelSize && image.height == pixelSize
    }

    /// 预解码: 绘制到显示就绪位图(BGRA premultiplied),避免惰性解码上显示路径(§79)。
    /// 仅磁盘加载路径需要(磁盘 PNG 非显示就绪);live 路径由 isDisplayReady 短路。
    private func preDecode(_ image: CGImage, pixelSize: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        return context.makeImage()
    }

    // MARK: - 内存压力通知

    private func handleSystemMemoryPressure(critical: Bool, warning: Bool) {
        if critical {
            trimMemory(keeping: [], level: .critical)
        } else if warning {
            // L1: warning 分级——保留最近使用 32 个图标,避免压力恢复后整屏重解码
            memoryCache.trim(recentCount: 32)
        }
    }
}
