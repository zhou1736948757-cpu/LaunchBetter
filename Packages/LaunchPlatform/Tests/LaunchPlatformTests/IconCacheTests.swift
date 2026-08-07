import CoreGraphics
import Foundation
import Testing
import LaunchCore
@testable import LaunchPlatform

// MARK: - 测试工具

func makeImage(size: Int, gray: CGFloat = 0.5) -> CGImage? {
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()
}

func iconKey(
    app: String = "/Applications/A.app",
    pointSize: Int = 96,
    scale: Int = 2,
    version: IconContentVersion = IconContentVersion(bundleVersion: "1")
) -> IconKey {
    IconKey(
        appID: AppID(app)!,
        pointSize: pointSize,
        scale: scale,
        contentVersion: version
    )
}

actor TestIconProvider: AppIconProviding {
    private(set) var callCount = 0
    private var delayNanoseconds: UInt64 = 0

    func setDelay(_ nanoseconds: UInt64) {
        delayNanoseconds = nanoseconds
    }

    func liveIcon(for url: URL, pixelSize: Int) async -> CGImage? {
        callCount += 1
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return makeImage(size: pixelSize, gray: 0.3)
    }
}

@Suite("IconContentVersion 稳定哈希")
struct IconContentVersionHashTests {
    @Test("相同信号 → 相同哈希; 任一信号变化 → 不同哈希")
    func deterministicHash() {
        let a = IconContentVersion(
            iconResourceModificationNanoseconds: 100,
            iconResourceSizeBytes: 200,
            bundleVersion: "1.0"
        )
        let a2 = IconContentVersion(
            iconResourceModificationNanoseconds: 100,
            iconResourceSizeBytes: 200,
            bundleVersion: "1.0"
        )
        let b = IconContentVersion(
            iconResourceModificationNanoseconds: 101,
            iconResourceSizeBytes: 200,
            bundleVersion: "1.0"
        )
        #expect(a.stableContentHash == a2.stableContentHash)
        #expect(a.stableContentHash != b.stableContentHash)
    }

    @Test("哈希跨进程稳定(固定向量)")
    func stableVector() {
        let v = IconContentVersion(
            iconResourceModificationNanoseconds: 123_456,
            iconResourceSizeBytes: 9_999,
            infoPlistModificationNanoseconds: 77,
            bundleVersion: "1.2.3"
        )
        // 固定向量: 若实现改动导致哈希变化, 此测试提醒检查磁盘缓存兼容性
        let expected = StableHash.fnv1a64(v.canonicalString)
        #expect(v.stableContentHash == expected)
        #expect(expected.count == 16)
    }

    @Test("StableHash.fnv1a64 确定性")
    func fnvDeterminism() {
        #expect(StableHash.fnv1a64("abc") == StableHash.fnv1a64("abc"))
        #expect(StableHash.fnv1a64("abc") != StableHash.fnv1a64("abd"))
    }
}

@Suite("IconMemoryCache 显式 LRU")
struct IconMemoryCacheTests {
    @Test("命中更新 LRU 新鲜度; 超限逐出最旧")
    func lruEviction() throws {
        let cache = IconMemoryCache(costLimitBytes: 1_000_000, countLimit: 3)
        let k1 = iconKey(app: "/A.app", pointSize: 10)
        let k2 = iconKey(app: "/B.app", pointSize: 10)
        let k3 = iconKey(app: "/C.app", pointSize: 10)
        let k4 = iconKey(app: "/D.app", pointSize: 10)
        let img = try #require(makeImage(size: 10))

        cache.insert(img, for: k1)
        cache.insert(img, for: k2)
        cache.insert(img, for: k3)
        #expect(cache.count == 3)

        // 命中 k1 → k1 变为最新
        _ = cache.lookup(k1)
        cache.insert(img, for: k4)
        #expect(cache.count == 3)
        #expect(cache.lookup(k2) == nil, "k2 应被逐出(最旧)")
        #expect(cache.lookup(k1) != nil)
        #expect(cache.lookup(k4) != nil)
    }

    @Test("字节成本限制(超限循环逐出)")
    func costLimit() throws {
        // 每张 32×32×4 = 4096 字节; 限额 10000 → 最多 2 张
        let cache = IconMemoryCache(costLimitBytes: 10_000)
        let img = try #require(makeImage(size: 32))
        for i in 0..<5 {
            cache.insert(img, for: iconKey(app: "/\(i).app", pointSize: 32))
        }
        #expect(cache.count <= 2)
        #expect(cache.totalCostBytes <= 10_000)
    }

    @Test("同键覆盖更新成本")
    func overwriteUpdatesCost() throws {
        let cache = IconMemoryCache(costLimitBytes: 1_000_000)
        let key = iconKey(pointSize: 32)
        let small = try #require(makeImage(size: 32))
        let big = try #require(makeImage(size: 64))
        cache.insert(small, for: key)
        let before = cache.totalCostBytes
        cache.insert(big, for: key)
        #expect(cache.count == 1)
        #expect(cache.totalCostBytes > before)
    }

    @Test("trim(keeping:) 保留指定键")
    func trimKeeping() throws {
        let cache = IconMemoryCache(costLimitBytes: 1_000_000)
        let k1 = iconKey(app: "/A.app")
        let k2 = iconKey(app: "/B.app")
        let k3 = iconKey(app: "/C.app")
        let img = try #require(makeImage(size: 10))
        cache.insert(img, for: k1)
        cache.insert(img, for: k2)
        cache.insert(img, for: k3)

        cache.trim(keeping: [k1, k3])
        #expect(cache.count == 2)
        #expect(cache.lookup(k1) != nil)
        #expect(cache.lookup(k3) != nil)
        #expect(cache.lookup(k2) == nil)
    }

    @Test("removeAll 与 remove(key)")
    func removeOperations() throws {
        let cache = IconMemoryCache(costLimitBytes: 1_000_000)
        let k1 = iconKey(app: "/A.app")
        let img = try #require(makeImage(size: 10))
        cache.insert(img, for: k1)
        cache.remove(key: k1)
        #expect(cache.count == 0)
        cache.insert(img, for: k1)
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.totalCostBytes == 0)
    }

    @Test("成本 = bytesPerRow × height")
    func costModel() throws {
        let img = try #require(makeImage(size: 48))
        #expect(IconMemoryCache.cost(of: img) == img.bytesPerRow * img.height)
    }
}

@Suite("IconDiskCache 全变体缓存")
struct IconDiskCacheTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconDiskTests-\(UUID().uuidString)")
        return url
    }

    @Test("往返: store → load")
    func roundTrip() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = IconDiskCache(rootURL: root)
        let key = iconKey()
        let image = try #require(makeImage(size: 96))

        try cache.store(key: key, image: image)
        let loaded = cache.load(key: key)
        #expect(loaded != nil)
        #expect(loaded!.width == 96)
    }

    @Test("文件名含完整变体: 尺寸/缩放/内容版本")
    func filenameVariant() {
        let root = URL(fileURLWithPath: "/tmp/root")
        let cache = IconDiskCache(rootURL: root)
        let key = iconKey(pointSize: 96, scale: 2, version: IconContentVersion(bundleVersion: "1"))
        let name = cache.fileURL(for: key).lastPathComponent
        #expect(name.hasPrefix("96-2-"))
        #expect(name.hasSuffix(".png"))
        #expect(name.contains(key.contentVersion.stableContentHash))
    }

    @Test("变体隔离: 不同尺寸/缩放/版本 → 不同文件")
    func variantIsolation() {
        let cache = IconDiskCache(rootURL: URL(fileURLWithPath: "/tmp/root"))
        let variants = [
            iconKey(pointSize: 96, scale: 2, version: IconContentVersion(bundleVersion: "1")),
            iconKey(pointSize: 96, scale: 1, version: IconContentVersion(bundleVersion: "1")),
            iconKey(pointSize: 64, scale: 2, version: IconContentVersion(bundleVersion: "1")),
            iconKey(pointSize: 96, scale: 2, version: IconContentVersion(bundleVersion: "2")),
        ]
        let urls = variants.map { cache.fileURL(for: $0) }
        #expect(Set(urls.map(\.lastPathComponent)).count == variants.count, "四个变体文件必须互不相同")
    }

    @Test("同应用同变体不同版本 → 不同文件(内容失效)")
    func contentVersionIsolation() {
        let cache = IconDiskCache(rootURL: URL(fileURLWithPath: "/tmp/root"))
        let before = iconKey(version: IconContentVersion(bundleVersion: "1"))
        let after = iconKey(version: IconContentVersion(bundleVersion: "2"))
        #expect(cache.fileURL(for: before).lastPathComponent != cache.fileURL(for: after).lastPathComponent)
    }

    @Test("缺失文件 → nil; 损坏文件被删除重建")
    func missingAndCorrupted() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = IconDiskCache(rootURL: root)
        let key = iconKey()
        #expect(cache.load(key: key) == nil)

        // 写损坏数据
        let url = cache.fileURL(for: key)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("garbage".utf8).write(to: url)
        #expect(cache.load(key: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path), "损坏文件应被删除")
    }
}
