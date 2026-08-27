import AppKit
import Testing
@testable import LaunchUI

@Suite("Wallpaper rendering")
struct WallpaperProviderTests {
    @Test("blur preserves color and alpha at every edge and corner")
    func blurPreservesEdgesAndCorners() throws {
        let width = 64
        let height = 48
        let expected = RGBA(red: 181, green: 73, blue: 29, alpha: 255)
        let source = try makeSolidImage(width: width, height: height, color: expected)
        let rendered = try #require(
            WallpaperProvider.render(
                source,
                targetSize: CGSize(width: width, height: height),
                scale: 1,
                blurRadius: 8
            )
        )
        let pixels = try rgbaPixels(of: rendered)
        let boundaryPoints = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: width - 1, y: 0),
            CGPoint(x: 0, y: height - 1),
            CGPoint(x: width - 1, y: height - 1),
            CGPoint(x: width / 2, y: 0),
            CGPoint(x: width / 2, y: height - 1),
            CGPoint(x: 0, y: height / 2),
            CGPoint(x: width - 1, y: height / 2),
        ]

        for point in boundaryPoints {
            let actual = pixels[Int(point.y) * width + Int(point.x)]
            #expect(actual.alpha >= 250, "point=\(point) alpha=\(actual.alpha)")
            #expect(abs(Int(actual.red) - Int(expected.red)) <= 4, "point=\(point) red=\(actual.red)")
            #expect(abs(Int(actual.green) - Int(expected.green)) <= 4, "point=\(point) green=\(actual.green)")
            #expect(abs(Int(actual.blue) - Int(expected.blue)) <= 4, "point=\(point) blue=\(actual.blue)")
        }
    }

    @Test("disk cache filename carries the rendering algorithm version")
    func diskCacheFilenameIsVersioned() {
        let request = WallpaperProvider.RenderRequest(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScale: 2,
            blurRadius: 30
        )

        let sourceIdentity = WallpaperProvider.SourceIdentity(
            normalizedPath: "/Library/Desktop Pictures/Test.heic",
            modificationTimeBits: 123,
            fileSize: 456,
            fileResourceIdentifier: "file-1"
        )

        #expect(WallpaperProvider.diskCacheAlgorithmVersion == 3)
        #expect(
            WallpaperProvider.diskCacheFileName(
                for: request,
                sourceIdentity: sourceIdentity
            ).hasPrefix("v3-720x450-b30.0-src")
        )

        let oneXRequest = WallpaperProvider.RenderRequest(
            screenFrame: request.screenFrame,
            backingScale: 1,
            blurRadius: request.blurRadius
        )
        #expect(
            WallpaperProvider.diskCacheFileName(
                for: oneXRequest,
                sourceIdentity: sourceIdentity
            ).hasPrefix("v3-360x225-b30.0-src")
        )
    }

    @Test("disk cache separates different wallpaper source URLs")
    func diskCacheSeparatesSourceURLs() {
        let request = renderRequest()
        let first = WallpaperProvider.SourceIdentity(
            normalizedPath: "/Library/Desktop Pictures/First.heic",
            modificationTimeBits: 123,
            fileSize: 456,
            fileResourceIdentifier: "file-1"
        )
        let second = WallpaperProvider.SourceIdentity(
            normalizedPath: "/Library/Desktop Pictures/Second.heic",
            modificationTimeBits: 123,
            fileSize: 456,
            fileResourceIdentifier: "file-1"
        )

        #expect(cacheName(for: request, sourceIdentity: first) != cacheName(
            for: request,
            sourceIdentity: second
        ))
    }

    @Test("disk cache separates metadata changes at the same wallpaper path")
    func diskCacheSeparatesSamePathMetadataChanges() {
        let request = renderRequest()
        let original = WallpaperProvider.SourceIdentity(
            normalizedPath: "/Library/Desktop Pictures/Changing.heic",
            modificationTimeBits: 123,
            fileSize: 456,
            fileResourceIdentifier: "file-1"
        )
        let modified = WallpaperProvider.SourceIdentity(
            normalizedPath: original.normalizedPath,
            modificationTimeBits: 124,
            fileSize: original.fileSize,
            fileResourceIdentifier: original.fileResourceIdentifier
        )
        let replaced = WallpaperProvider.SourceIdentity(
            normalizedPath: original.normalizedPath,
            modificationTimeBits: original.modificationTimeBits,
            fileSize: original.fileSize,
            fileResourceIdentifier: "file-2"
        )

        let originalName = cacheName(for: request, sourceIdentity: original)
        #expect(originalName != cacheName(for: request, sourceIdentity: modified))
        #expect(originalName != cacheName(for: request, sourceIdentity: replaced))
    }

    @Test("memory cache identity ignores screenFrame origin when render params match")
    func cacheKeyIgnoresOrigin() {
        let base = WallpaperProvider.RenderRequest(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScale: 2,
            blurRadius: 30
        )
        let moved = WallpaperProvider.RenderRequest(
            screenFrame: CGRect(x: 120, y: -80, width: 1440, height: 900),
            backingScale: 2,
            blurRadius: 30
        )
        #expect(
            WallpaperProvider.normalizedRequest(for: base)
                == WallpaperProvider.normalizedRequest(for: moved)
        )
    }

    @Test("memory cache identity distinguishes render-affecting parameters")
    func cacheKeyDistinguishesRenderParams() {
        let base = WallpaperProvider.RenderRequest(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScale: 2,
            blurRadius: 30
        )
        let differentBlur = WallpaperProvider.RenderRequest(
            screenFrame: base.screenFrame,
            backingScale: base.backingScale,
            blurRadius: 40
        )
        let differentScale = WallpaperProvider.RenderRequest(
            screenFrame: base.screenFrame,
            backingScale: 1,
            blurRadius: base.blurRadius
        )
        let differentSize = WallpaperProvider.RenderRequest(
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            backingScale: base.backingScale,
            blurRadius: base.blurRadius
        )
        let baseKey = WallpaperProvider.normalizedRequest(for: base)
        #expect(baseKey != WallpaperProvider.normalizedRequest(for: differentBlur))
        #expect(baseKey != WallpaperProvider.normalizedRequest(for: differentScale))
        #expect(baseKey != WallpaperProvider.normalizedRequest(for: differentSize))
    }

    @Test("source selection picks the screen matching the request frame size")
    func sourceSelectionMatchesRequestSize() {
        let request = WallpaperProvider.RenderRequest(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScale: 2,
            blurRadius: 30
        )
        let frames = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 1440, height: 900),
        ]
        #expect(WallpaperProvider.targetScreenIndex(for: request, availableFrames: frames) == 1)
    }

    @Test("source selection is deterministic and safe with no screens")
    func sourceSelectionDeterministicFallback() {
        let request = WallpaperProvider.RenderRequest(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScale: 2,
            blurRadius: 30
        )
        // 单屏: 唯一候选
        let single = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        #expect(WallpaperProvider.targetScreenIndex(for: request, availableFrames: single) == 0)
        // 无屏幕: 安全回退
        #expect(WallpaperProvider.targetScreenIndex(for: request, availableFrames: []) == nil)
        // 平局(同尺寸): 确定性取靠前者
        let tie = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: 0, width: 1440, height: 900),
        ]
        #expect(WallpaperProvider.targetScreenIndex(for: request, availableFrames: tie) == 0)
    }

    private func renderRequest() -> WallpaperProvider.RenderRequest {
        WallpaperProvider.RenderRequest(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            backingScale: 2,
            blurRadius: 30
        )
    }

    // MARK: - T-026: 磁盘持久化移出 display-ready path(serial writer)

    @Test("disk writer persists a decodable PNG after flush")
    func diskWriterPersistsDecodablePNG() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = WallpaperDiskWriter()
        let url = dir.appendingPathComponent("Wallpaper").appendingPathComponent("test.png")
        let image = try makeSolidImage(
            width: 32, height: 32, color: RGBA(red: 10, green: 20, blue: 30, alpha: 255)
        )

        writer.enqueue(image: image, to: url)
        writer.flush()

        #expect(FileManager.default.fileExists(atPath: url.path))
        let decoded = try #require(Self.loadPNG(url: url))
        #expect(decoded.width == 32)
        #expect(decoded.height == 32)
        let pixels = try rgbaPixels(of: decoded)
        #expect(pixels.allSatisfy {
            $0.red == 10 && $0.green == 20 && $0.blue == 30 && $0.alpha == 255
        })
    }

    @Test("disk writer deduplicates repeated enqueues of the same URL (idempotent)")
    func diskWriterDeduplicatesSameURL() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = WallpaperDiskWriter()
        let url = dir.appendingPathComponent("Wallpaper").appendingPathComponent("test.png")
        let first = try makeSolidImage(
            width: 16, height: 16, color: RGBA(red: 1, green: 2, blue: 3, alpha: 255)
        )
        let second = try makeSolidImage(
            width: 16, height: 16, color: RGBA(red: 200, green: 201, blue: 202, alpha: 255)
        )

        // 同 URL 二次入队(多次 cold render 场景): 只写首次内容
        writer.enqueue(image: first, to: url)
        writer.enqueue(image: second, to: url)
        writer.flush()

        let decoded = try #require(Self.loadPNG(url: url))
        let pixels = try rgbaPixels(of: decoded)
        #expect(pixels.allSatisfy { $0.red == 1 && $0.green == 2 && $0.blue == 3 })
    }

    @Test("enqueue returns before the write completes (write lives on the serial queue)")
    func enqueueDoesNotBlockOnWrite() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "test.wallpaper-writer.suspended")
        queue.suspend()
        let writer = WallpaperDiskWriter(queue: queue)
        let url = dir.appendingPathComponent("Wallpaper").appendingPathComponent("test.png")
        let image = try makeSolidImage(
            width: 16, height: 16, color: RGBA(red: 5, green: 6, blue: 7, alpha: 255)
        )

        writer.enqueue(image: image, to: url)
        // 队列挂起: enqueue 已返回, 但写盘尚未执行 → 磁盘 IO 不在入队/返回路径
        #expect(!FileManager.default.fileExists(atPath: url.path))

        queue.resume()
        writer.flush()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("disk write failure is recorded, not thrown, and does not poison later writes")
    func diskWriteFailureIsRecordedNotThrown() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = WallpaperDiskWriter()
        let image = try makeSolidImage(
            width: 16, height: 16, color: RGBA(red: 1, green: 1, blue: 1, alpha: 255)
        )

        // 父路径是普通文件: createDirectory 必然失败(确定性失败注入)
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let badURL = blocker.appendingPathComponent("Wallpaper").appendingPathComponent("bad.png")

        writer.enqueue(image: image, to: badURL) // 不抛出
        writer.flush() // 不抛出
        #expect(!FileManager.default.fileExists(atPath: badURL.path))

        // 失败不污染后续写(失败未记入 written, 可重试)
        let goodURL = dir.appendingPathComponent("Wallpaper").appendingPathComponent("good.png")
        writer.enqueue(image: image, to: goodURL)
        writer.flush()
        #expect(FileManager.default.fileExists(atPath: goodURL.path))
    }

    @Test("cold render returns before disk write and persists asynchronously")
    func coldRenderReturnsBeforeDiskWrite() throws {
        // 环境依赖: 需要真实壁纸源; 无壁纸源时验证安全回退(不伪造持久化通过)
        guard let source = firstWallpaperSourceURL() else {
            let provider = WallpaperProvider(
                cachesURL: URL(fileURLWithPath: NSTemporaryDirectory())
            )
            #expect(provider.blurredWallpaper(for: renderRequest()) == nil)
            return
        }
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "test.wallpaper-provider.suspended")
        queue.suspend()
        let writer = WallpaperDiskWriter(queue: queue)
        let provider = WallpaperProvider(cachesURL: dir, diskWriter: writer)
        let request = renderRequest()

        let rendered = try #require(provider.blurredWallpaper(for: request))
        // 返回时: 内存缓存已就绪, 磁盘尚未写(队列挂起 → 写盘不在返回路径)
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("Wallpaper").path
        ))

        // 第二次 cold render(内存缓存命中): 返回同一图像, 不重复入队写盘
        let again = provider.blurredWallpaper(for: request)
        #expect(again === rendered)

        queue.resume()
        writer.flush()
        // 异步写完成: 磁盘文件存在且可解码, 尺寸与渲染结果一致
        let diskURL = dir.appendingPathComponent("Wallpaper", isDirectory: true)
            .appendingPathComponent(WallpaperProvider.diskCacheFileName(
                for: request,
                sourceIdentity: WallpaperProvider.sourceIdentity(for: source)
            ))
        #expect(FileManager.default.fileExists(atPath: diskURL.path))
        let decoded = try #require(Self.loadPNG(url: diskURL))
        #expect(decoded.width == rendered.width)
        #expect(decoded.height == rendered.height)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("T026-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func firstWallpaperSourceURL() -> URL? {
        // 与 WallpaperProvider.wallpaperSourceURL(for:) 同构: 尺寸最近屏优先, 兜底任意有壁纸屏
        let screens = NSScreen.screens
        let request = renderRequest()
        if let index = WallpaperProvider.targetScreenIndex(
            for: request,
            availableFrames: screens.map(\.frame)
        ), screens.indices.contains(index),
           let url = NSWorkspace.shared.desktopImageURL(for: screens[index]) {
            return url
        }
        for screen in screens {
            if let url = NSWorkspace.shared.desktopImageURL(for: screen) {
                return url
            }
        }
        return nil
    }

    private static func loadPNG(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func cacheName(
        for request: WallpaperProvider.RenderRequest,
        sourceIdentity: WallpaperProvider.SourceIdentity
    ) -> String {
        WallpaperProvider.diskCacheFileName(
            for: request,
            sourceIdentity: sourceIdentity
        )
    }

    private struct RGBA {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    private func makeSolidImage(width: Int, height: Int, color: RGBA) throws -> CGImage {
        let pixel = [color.red, color.green, color.blue, color.alpha]
        let data = Data(Array(repeating: pixel, count: width * height).flatMap { $0 })
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
    }

    private func rgbaPixels(of image: CGImage) throws -> [RGBA] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let didDraw = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(didDraw)

        return stride(from: 0, to: bytes.count, by: 4).map {
            RGBA(red: bytes[$0], green: bytes[$0 + 1], blue: bytes[$0 + 2], alpha: bytes[$0 + 3])
        }
    }
}
