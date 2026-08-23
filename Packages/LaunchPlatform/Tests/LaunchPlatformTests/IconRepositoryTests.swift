import CoreGraphics
import Foundation
import Testing
import LaunchCore
@testable import LaunchPlatform

@Suite("IconRepository 管道")
struct IconRepositoryTests {
    private func makeRepository(
        provider: TestIconProvider,
        root: URL,
        writer: (any IconDiskWriting)? = nil
    ) -> IconRepository {
        IconRepository(
            memoryCache: IconMemoryCache(costLimitBytes: 50_000_000),
            diskCache: IconDiskCache(rootURL: root),
            provider: provider,
            diskWriter: writer
        )
    }

    private func tempRoot() throws -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("IconRepoTests-\(UUID().uuidString)")
    }

    @Test("首次请求: 实时提取并缓存")
    func firstRequestResolves() async throws {
        let provider = TestIconProvider()
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = makeRepository(provider: provider, root: root)
        let key = iconKey()

        let image = await repo.image(for: key)
        #expect(image != nil)
        #expect(await provider.callCount == 1)
        #expect(await repo.memoryHits == 0)
        #expect(await repo.liveResolves == 1)
        #expect(await repo.diskWrites == 1)
    }

    @Test("内存命中: 第二次请求不走 provider")
    func memoryHit() async throws {
        let provider = TestIconProvider()
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = makeRepository(provider: provider, root: root)
        let key = iconKey()

        _ = await repo.image(for: key)
        _ = await repo.image(for: key)
        #expect(await provider.callCount == 1)
        #expect(await repo.memoryHits == 1)
    }

    @Test("A5 live 路径不二次光栅化: 返回 provider 同一对象")
    func livePathNoRedecode() async throws {
        let provider = TestIconProvider()
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = makeRepository(provider: provider, root: root)
        let key = iconKey()

        let image = await repo.image(for: key)
        let provided = await provider.lastImage
        #expect(image != nil)
        #expect(provided != nil)
        #expect(image === provided, "live 显示就绪位图应直接返回, 不二次光栅化")
    }

    @Test("A5 1x/2x 像素尺寸与请求一致")
    func livePathPixelSizeMatches() async throws {
        let provider = TestIconProvider()
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = makeRepository(provider: provider, root: root)

        let scale1 = iconKey(pointSize: 48, scale: 1)
        let scale2 = iconKey(pointSize: 48, scale: 2)
        let img1 = await repo.image(for: scale1)
        let img2 = await repo.image(for: scale2)
        #expect(img1?.width == 48)
        #expect(img1?.height == 48)
        #expect(img2?.width == 96)
        #expect(img2?.height == 96)
    }

    @Test("A6 resolve 不等磁盘写: 慢写器下首显不劣化, 返回时写未完成")
    func resolveDoesNotWaitForDiskWrite() async throws {
        let provider = TestIconProvider()
        let writer = SlowIconDiskWriter(storeDelay: 400_000_000) // 400ms 慢写
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = makeRepository(provider: provider, root: root, writer: writer)
        let key = iconKey()

        let start = Date()
        let image = await repo.image(for: key)
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        #expect(image != nil)
        #expect(elapsedMs < 300, "resolve 不应等待 400ms 慢磁盘写(实际 \(elapsedMs)ms)")
        #expect(await writer.storeCount == 0, "resolve 返回时磁盘写仍未完成")
        #expect(await writer.enqueueCount == 1, "resolve 已提交写请求")

        await repo.waitForPendingDiskWrites()
        #expect(await writer.storeCount == 1, "写最终异步完成")
    }

    @Test("A6 磁盘写失败不阻断 resolve 返回图像")
    func resolveSurvivesDiskWriteFailure() async throws {
        let provider = TestIconProvider()
        // 父路径被文件占据 → 磁盘写必然失败(可再生缓存, 仅记录)
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let badRoot = blocker.appendingPathComponent("Icons")
        let writer = DiskCacheWriter(rootURL: badRoot)
        let repo = makeRepository(provider: provider, root: badRoot, writer: writer)

        let key = iconKey()
        let image = await repo.image(for: key)
        #expect(image != nil, "写失败仍应返回图像")
        await repo.waitForPendingDiskWrites() // 不抛错
    }

    @Test("in-flight 去重: 并发请求只调一次 provider")
    func inFlightDedup() async throws {
        let provider = TestIconProvider()
        await provider.setDelay(100_000_000) // 100ms,保证并发重叠
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = makeRepository(provider: provider, root: root)
        let key = iconKey()

        async let first: CGImage? = repo.image(for: key)
        async let second: CGImage? = repo.image(for: key)
        let a = await first
        let b = await second
        #expect(a != nil)
        #expect(b != nil)
        #expect(await provider.callCount == 1, "并发请求应共享 in-flight 任务")
    }

    @Test("磁盘命中: 内存清空后不调 provider")
    func diskHit() async throws {
        let provider = TestIconProvider()
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = makeRepository(provider: provider, root: root)
        let key = iconKey()

        _ = await repo.image(for: key)
        await repo.waitForPendingDiskWrites() // A6: 等异步写完成, 模拟"重启时已落盘"
        // 模拟冷启动: 新 repository(同一磁盘缓存)
        let repo2 = makeRepository(provider: provider, root: root)
        let image = await repo2.image(for: key)
        #expect(image != nil)
        #expect(await provider.callCount == 1, "磁盘命中不应实时提取")
        #expect(await repo2.diskHits == 1)
    }

    @Test("变体隔离: 不同尺寸独立解析")
    func variantIsolation() async throws {
        let provider = TestIconProvider()
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = makeRepository(provider: provider, root: root)

        let small = iconKey(pointSize: 48, scale: 2)
        let big = iconKey(pointSize: 96, scale: 2)
        _ = await repo.image(for: small)
        _ = await repo.image(for: big)
        #expect(await provider.callCount == 2)

        let smallImage = await repo.image(for: small)
        #expect(smallImage?.width == 96)
    }

    @Test("内容版本失效: 新版本触发重新提取")
    func contentVersionInvalidation() async throws {
        let provider = TestIconProvider()
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = makeRepository(provider: provider, root: root)

        let v1 = iconKey(version: IconContentVersion(bundleVersion: "1"))
        let v2 = iconKey(version: IconContentVersion(bundleVersion: "2"))
        _ = await repo.image(for: v1)
        _ = await repo.image(for: v2)
        #expect(await provider.callCount == 2)
        _ = await repo.image(for: v1)
        #expect(await provider.callCount == 2, "v1 已在缓存")
    }

    @Test("消费者取消不杀死共享任务(§81): 取消者返回 nil, 未取消者获得结果")
    func consumerCancellation() async throws {
        let provider = TestIconProvider()
        await provider.setDelay(200_000_000)
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = makeRepository(provider: provider, root: root)
        let key = iconKey()

        let consumer1 = Task { await repo.image(for: key) }
        let consumer2 = Task { await repo.image(for: key) }
        consumer1.cancel()
        let result2 = await consumer2.value
        #expect(result2 != nil, "未取消的消费者应获得结果")
        let result1 = await consumer1.value
        #expect(result1 == nil, "已取消消费者应返回 nil(不应用结果)")
        #expect(await provider.callCount == 1, "共享任务只执行一次,不被消费者取消杀死")
        #expect(await repo.liveResolves == 1)
    }

    @Test("invalidate 后 in-flight 旧任务不发布结果 (M2 陈旧防护)")
    func invalidateBlocksStaleResult() async throws {
        let provider = TestIconProvider()
        await provider.setDelay(200_000_000)
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = makeRepository(provider: provider, root: root)
        let key = iconKey()

        let consumer = Task { await repo.image(for: key) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await repo.invalidate(appID: key.appID)
        let result = await consumer.value
        #expect(result == nil, "invalidate 后旧代际任务不得发布结果")

        // 新请求(同键,代际已升)仍可正常解析
        let fresh = await repo.image(for: key)
        #expect(fresh != nil)
        #expect(await provider.callCount == 2)
    }

    @Test("shutdown 幂等, 清除内存后仍可从磁盘恢复")
    func shutdownIsIdempotent() async throws {
        let provider = TestIconProvider()
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = makeRepository(provider: provider, root: root)
        let key = iconKey()

        _ = await repo.image(for: key)
        await repo.shutdown()
        await repo.shutdown()

        let restored = await repo.image(for: key)
        #expect(restored != nil, "shutdown 后磁盘缓存仍可恢复")
        #expect(await provider.callCount == 1, "恢复走磁盘,不实时提取")
    }

    @Test("F5 shutdown 等待后台 prune 完成(预置旧文件被清理)")
    func shutdownWaitsForPrune() async throws {
        let provider = TestIconProvider()
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 在 repository 构造之前预置 60 天前的旧缓存文件:
        // 保证 prune 无论何时运行都会看到它, 断言不依赖启动竞态。
        let sub = root.appendingPathComponent("hash123", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let old = sub.appendingPathComponent("96-2-old.png")
        try Data("old".utf8).write(to: old)
        let oldDate = Date().addingTimeInterval(-60 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: old.path)

        let repo = makeRepository(provider: provider, root: root)
        await repo.shutdown()

        #expect(!FileManager.default.fileExists(atPath: old.path), "shutdown 返回前 prune 必须已完成并删除旧文件")
    }

    @Test("内存压力: trim keeping 保留可见页, critical 全清")
    func memoryPressure() async throws {
        let provider = TestIconProvider()
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = makeRepository(provider: provider, root: root)

        let k1 = iconKey(app: "/A.app")
        let k2 = iconKey(app: "/B.app")
        _ = await repo.image(for: k1)
        _ = await repo.image(for: k2)
        await repo.waitForPendingDiskWrites() // 等异步写完成, 逐出后可回读磁盘

        await repo.trimMemory(keeping: [k1], level: .hidden)
        #expect(await repo.image(for: k1) != nil, "保留键应仍在内存")
        #expect(await provider.callCount == 2, "k2 被逐出后应从磁盘/实时再取(磁盘有,不计 live)")

        await repo.trimMemory(keeping: [], level: .critical)
        #expect(await repo.image(for: k1) != nil, "critical 清内存后仍可从磁盘恢复")
        #expect(await repo.diskHits >= 1)
    }

    @Test("invalidate 清除指定应用的内存条目")
    func invalidateApp() async throws {
        let provider = TestIconProvider()
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = makeRepository(provider: provider, root: root)

        let keyA = iconKey(app: "/A.app")
        let keyB = iconKey(app: "/B.app")
        _ = await repo.image(for: keyA)
        _ = await repo.image(for: keyB)
        await repo.waitForPendingDiskWrites() // 等异步写完成, 失效后可回读磁盘
        await repo.invalidate(appID: AppID("/A.app")!)

        let fromDisk = await repo.image(for: keyA)
        #expect(fromDisk != nil)
        #expect(await provider.callCount == 2, "A 被失效后走磁盘(不实时提取)")
        #expect(await repo.image(for: keyB) != nil)
        #expect(await provider.callCount == 2, "B 仍内存命中")
    }
}

@Suite("IconContentVersionFactory 信号")
struct IconContentVersionFactoryTests {
    @Test("CFBundleIconFile 定位: mtime/大小/版本信号齐全")
    func iconFileSignals() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appURL = dir.appendingPathComponent("App.app")
        let resources = appURL.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(count: 1024).write(to: resources.appendingPathComponent("App.icns"))

        let version = IconContentVersionFactory.make(
            appURL: appURL,
            infoPlist: ["CFBundleIconFile": "App", "CFBundleVersion": "1.0"],
            infoPlistDate: Date(timeIntervalSince1970: 100)
        )
        #expect(version.iconResourceSizeBytes == 1024)
        #expect(version.iconResourceModificationNanoseconds != nil)
        #expect(version.bundleVersion == "1.0")
        #expect(version.infoPlistModificationNanoseconds != nil)
    }

    @Test("Assets.car 作为第二信号源")
    func assetsCarSignals() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appURL = dir.appendingPathComponent("App.app")
        let resources = appURL.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(count: 2048).write(to: resources.appendingPathComponent("Assets.car"))

        let version = IconContentVersionFactory.make(
            appURL: appURL,
            infoPlist: ["CFBundleVersion": "2.0"],
            infoPlistDate: nil
        )
        #expect(version.iconResourceSizeBytes == 2048)
        #expect(version.iconResourceModificationNanoseconds != nil)
        #expect(version.bundleVersion == "2.0")
    }

    @Test("无图标资源: 回退 Info.plist + 版本")
    func fallbackSignals() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appURL = dir.appendingPathComponent("App.app")
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )
        let version = IconContentVersionFactory.make(
            appURL: appURL,
            infoPlist: ["CFBundleVersion": "3.0"],
            infoPlistDate: Date(timeIntervalSince1970: 500)
        )
        #expect(version.iconResourceModificationNanoseconds == nil)
        #expect(version.iconResourceSizeBytes == nil)
        #expect(version.infoPlistModificationNanoseconds == UInt64(500 * 1_000_000_000))
        #expect(version.bundleVersion == "3.0")
    }

    @Test("内容未变 → 版本不变; 图标文件变更 → 版本变化")
    func stabilityAndChange() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appURL = dir.appendingPathComponent("App.app")
        let resources = appURL.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let iconURL = resources.appendingPathComponent("App.icns")
        try Data(count: 100).write(to: iconURL)
        let plist: [String: Any] = ["CFBundleIconFile": "App", "CFBundleVersion": "1.0"]

        let v1 = IconContentVersionFactory.make(
            appURL: appURL, infoPlist: plist, infoPlistDate: nil
        )
        let v1Again = IconContentVersionFactory.make(
            appURL: appURL, infoPlist: plist, infoPlistDate: nil
        )
        #expect(v1 == v1Again)

        // 等 mtime 粒度变化: 显式改内容并设置 mtime
        try Data(count: 200).write(to: iconURL)
        let stamp = Date().addingTimeInterval(2)
        try FileManager.default.setAttributes(
            [.modificationDate: stamp], ofItemAtPath: iconURL.path
        )
        let v2 = IconContentVersionFactory.make(
            appURL: appURL, infoPlist: plist, infoPlistDate: nil
        )
        #expect(v1 != v2)
    }
}
