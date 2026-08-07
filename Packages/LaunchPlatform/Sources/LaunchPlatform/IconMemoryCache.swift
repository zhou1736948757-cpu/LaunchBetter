import CoreGraphics
import Foundation
import LaunchCore

/// 图标内存缓存: 显式 dict + LRU + 字节成本限制(§76)。
///
/// 不用 NSCache(测试需要确定性逐出行为)。成本 ≈ bytesPerRow × height。
/// 非 Sendable: 由 IconRepository actor 独占使用。
public final class IconMemoryCache {
    private struct Entry {
        let image: CGImage
        let cost: Int
    }

    private var entries: [IconKey: Entry] = [:]
    /// LRU 顺序(头部最旧,尾部最新)。
    private var lruOrder: [IconKey] = []
    private var totalCost = 0

    public let costLimitBytes: Int
    public let countLimit: Int?

    public init(costLimitBytes: Int, countLimit: Int? = nil) {
        self.costLimitBytes = costLimitBytes
        self.countLimit = countLimit
    }

    /// 命中: 更新 LRU 新鲜度。
    public func lookup(_ key: IconKey) -> CGImage? {
        guard let entry = entries[key] else { return nil }
        markRecentlyUsed(key)
        return entry.image
    }

    /// 插入(覆盖已有);超过成本/数量限制时按 LRU 逐出,直至合规。
    public func insert(_ image: CGImage, for key: IconKey) {
        let cost = Self.cost(of: image)
        if let previous = entries[key] {
            totalCost -= previous.cost
            removeFromLRU(key)
        }
        entries[key] = Entry(image: image, cost: cost)
        totalCost += cost
        markRecentlyUsed(key)
        trimIfNeeded()
    }

    /// 逐出 LRU 直到不超成本/数量限制。
    private func trimIfNeeded() {
        while totalCost > costLimitBytes || (countLimit.map { entries.count > $0 } ?? false) {
            guard let oldest = lruOrder.first else { break }
            removeEntry(oldest)
        }
    }

    /// 保留指定键(可见页优先),逐出其余;仍超限时在保留集中继续按 LRU 逐出。
    public func trim(keeping keys: Set<IconKey>) {
        for key in Array(entries.keys) where !keys.contains(key) {
            removeEntry(key)
        }
        trimIfNeeded()
    }

    /// 只保留最近使用的 N 个条目(隐藏时裁剪低优先级,§77)。
    public func trim(recentCount: Int) {
        let excess = entries.count - max(0, recentCount)
        guard excess > 0 else { return }
        for _ in 0..<excess {
            guard let oldest = lruOrder.first else { break }
            removeEntry(oldest)
        }
        trimIfNeeded()
    }

    /// 全清(临界内存压力)。
    public func removeAll() {
        entries.removeAll()
        lruOrder.removeAll()
        totalCost = 0
    }

    public var count: Int { entries.count }
    public var totalCostBytes: Int { totalCost }

    /// 全部键(供失效/诊断)。
    public func keys() -> [IconKey] {
        Array(entries.keys)
    }

    /// 显式移除单个键。
    public func remove(key: IconKey) {
        removeEntry(key)
    }

    private func markRecentlyUsed(_ key: IconKey) {
        removeFromLRU(key)
        lruOrder.append(key)
    }

    private func removeFromLRU(_ key: IconKey) {
        lruOrder.removeAll { $0 == key }
    }

    private func removeEntry(_ key: IconKey) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        totalCost -= entry.cost
        removeFromLRU(key)
    }

    /// 图像字节成本 ≈ bytesPerRow × height(§76)。
    public static func cost(of image: CGImage) -> Int {
        max(1, image.bytesPerRow * image.height)
    }
}
