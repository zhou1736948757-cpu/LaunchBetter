import CoreGraphics
import Foundation
import Testing
@testable import LaunchUI

@Suite("PageVisualCache: bounded working set", .serialized)
@MainActor
struct PageVisualCacheTests {
    private let geometry = PageVisualGeometrySignature(
        columns: 2, rows: 1, cellSize: 60, iconSize: 32,
        horizontalSpacing: 20, verticalSpacing: 20,
        pageWidth: 200, pageHeight: 120, topInset: 0, bottomInset: 0
    )

    private func key(
        page: Int = 1,
        revision: UInt64 = 7,
        geometry: PageVisualGeometrySignature? = nil,
        scale: Int = 2,
        language: UInt64 = 1,
        iconEpoch: UInt64 = 0
    ) -> PageVisualKey {
        PageVisualKey(
            pageIndex: page,
            displayRevision: revision,
            geometry: geometry ?? self.geometry,
            backingScale: scale,
            languageRevision: language,
            iconEpoch: iconEpoch
        )
    }

    /// 指定像素尺寸的图像(字节数 = w×h×4, 与 PageVisual.bytes 语义一致)。
    private func visual(for key: PageVisualKey, pixelSize: Int = 16) -> PageVisual {
        let context = CGContext(
            data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = context.makeImage()!
        return PageVisual(
            key: key, image: image,
            logicalBounds: CGRect(x: 0, y: 0, width: 100, height: 60),
            rasterScale: CGFloat(key.backingScale)
        )
    }

    @Test("cap 3: 插入第 4 张逐出最久未使用")
    func capThreeEvictsLRU() {
        let cache = PageVisualCache()
        let k0 = key(page: 0)
        let k1 = key(page: 1)
        let k2 = key(page: 2)
        let k3 = key(page: 3)
        cache.insert(visual(for: k0))
        cache.insert(visual(for: k1))
        cache.insert(visual(for: k2))
        #expect(cache.visualCount == 3)

        // 触碰 k0(提升 LRU)→ 插入 k3 应逐出 k1(最久未使用)。
        #expect(cache.visual(for: k0) != nil)
        cache.insert(visual(for: k3))
        #expect(cache.visualCount == 3)
        #expect(cache.contains(k0))
        #expect(cache.contains(k2))
        #expect(cache.contains(k3))
        #expect(!cache.contains(k1), "LRU 逐出应移除最久未使用条目")
    }

    @Test("键失效: revision/geometry/scale/language/iconEpoch 任一变化 = miss")
    func keyComponentInvalidation() {
        let cache = PageVisualCache()
        let base = key()
        cache.insert(visual(for: base))
        #expect(cache.visual(for: base) != nil)

        #expect(cache.visual(for: key(revision: 8)) == nil)
        #expect(cache.visual(for: key(scale: 1)) == nil)
        #expect(cache.visual(for: key(language: 2)) == nil)
        #expect(cache.visual(for: key(iconEpoch: 1)) == nil)

        var otherGeometry = geometry
        otherGeometry = PageVisualGeometrySignature(
            columns: 3, rows: 1, cellSize: 60, iconSize: 32,
            horizontalSpacing: 20, verticalSpacing: 20,
            pageWidth: 200, pageHeight: 120, topInset: 0, bottomInset: 0
        )
        #expect(cache.visual(for: key(geometry: otherGeometry)) == nil)
        #expect(cache.visual(for: key(page: 2)) == nil)
    }

    @Test("字节记账: totalBytes 随插入/逐出/清除一致")
    func byteAccounting() {
        let cache = PageVisualCache()
        let k0 = key(page: 0)
        let k1 = key(page: 1)
        let k2 = key(page: 2)
        // 8×8=256B, 16×16=1024B, 4×4=64B。
        let v0 = visual(for: k0, pixelSize: 8)
        let v1 = visual(for: k1, pixelSize: 16)
        let v2 = visual(for: k2, pixelSize: 4)

        cache.insert(v0)
        cache.insert(v1)
        cache.insert(v2)
        #expect(cache.totalBytes == 256 + 1024 + 64)

        // 同键重插: 先扣旧字节再加新字节(16×16 → 20×20=1600B)。
        cache.insert(visual(for: k1, pixelSize: 20))
        #expect(cache.totalBytes == 256 + 1600 + 64)

        // 插入第 4 张逐出最旧的(v0): 256 字节被移除。
        cache.insert(visual(for: key(page: 3), pixelSize: 10))
        #expect(cache.totalBytes == 1600 + 64 + 400)

        cache.removeAll()
        #expect(cache.totalBytes == 0)
        #expect(cache.visualCount == 0)
        #expect(cache.isEmpty)
    }

    @Test("purge/remove 幂等")
    func purgeIdempotent() {
        let cache = PageVisualCache()
        cache.insert(visual(for: key(page: 0)))
        cache.insert(visual(for: key(page: 1)))
        cache.removeAll()
        cache.removeAll()
        #expect(cache.isEmpty)
        #expect(cache.remove(key: key(page: 0)) == nil)
        #expect(cache.totalBytes == 0)
    }

    @Test("working set 边界: 页 0 无 previous → 恒不齐备")
    func workingSetBoundaryNeverReady() {
        let cache = PageVisualCache()
        cache.insert(visual(for: key(page: 0)))
        cache.insert(visual(for: key(page: 1)))
        #expect(
            cache.isWorkingSetReady(
                centerPage: 0, pageCount: 3, displayRevision: 7, geometry: geometry,
                backingScale: 2, languageRevision: 1, iconEpoch: 0
            ) == false,
            "页 0 的 previous 不存在, 不得合成"
        )
    }

    @Test("working set 齐备: 中间页三张齐备才 true")
    func workingSetReadyOnlyWithThreeNeighbors() {
        let cache = PageVisualCache()
        let center = key(page: 1)
        cache.insert(visual(for: key(page: 0)))
        cache.insert(visual(for: center))
        #expect(
            cache.isWorkingSetReady(
                centerPage: 1, pageCount: 3, displayRevision: 7, geometry: geometry,
                backingScale: 2, languageRevision: 1, iconEpoch: 0
            ) == false,
            "next 缺失 → 不齐备"
        )
        cache.insert(visual(for: key(page: 2)))
        #expect(
            cache.isWorkingSetReady(
                centerPage: 1, pageCount: 3, displayRevision: 7, geometry: geometry,
                backingScale: 2, languageRevision: 1, iconEpoch: 0
            ) == true
        )
        #expect(cache.visual(for: center) != nil)
    }

    @Test("working set 查询返回页序(prev/current/next)")
    func workingSetVisualsOrdered() {
        let cache = PageVisualCache()
        cache.insert(visual(for: key(page: 0)))
        cache.insert(visual(for: key(page: 1)))
        cache.insert(visual(for: key(page: 2)))
        let visuals = cache.workingSetVisuals(
            centerPage: 1, pageCount: 3, displayRevision: 7, geometry: geometry,
            backingScale: 2, languageRevision: 1, iconEpoch: 0
        )
        #expect(visuals.map(\.page) == [0, 1, 2])
        #expect(visuals.map(\.visual.key.pageIndex) == [0, 1, 2])
    }

    @Test("ignoringIconEpoch: 同页多 epoch 时返回最后插入的视觉(即使 epoch 数值更小)")
    func ignoringIconEpochPrefersLatestInsertion() {
        let cache = PageVisualCache()
        // 同一页/数据/几何/scale/语言: 先插入 iconEpoch=100 的视觉,
        // 后插入 iconEpoch=1 的视觉(新视觉可能带着数值更小的 epoch)。
        cache.insert(visual(for: key(page: 0, iconEpoch: 5)))
        cache.insert(visual(for: key(page: 1, iconEpoch: 100)))
        cache.insert(visual(for: key(page: 1, iconEpoch: 1)))
        #expect(cache.visualCount == 3)

        let visuals = cache.workingSetVisualsIgnoringIconEpoch(
            centerPage: 1, pageCount: 3, displayRevision: 7, geometry: geometry,
            backingScale: 2, languageRevision: 1
        )
        #expect(visuals.map(\.page) == [0, 1])
        guard let page1 = visuals.first(where: { $0.page == 1 }) else {
            Issue.record("page 1 视觉缺失")
            return
        }
        #expect(
            page1.visual.key.iconEpoch == 1,
            "同页多 epoch → 必须选最后插入的视觉(单调插入序最大), 而非 epoch 数值更大者"
        )
        #expect(
            cache.isWorkingSetReadyIgnoringIconEpoch(
                centerPage: 1, pageCount: 3, displayRevision: 7,
                geometry: geometry, backingScale: 2, languageRevision: 1
            ) == false,
            "page 2 缺失 → 不齐备(选择逻辑不影响就绪判定)"
        )
    }

    // MARK: - T-001: 显式页集合查询 visuals(for:)

    @Test("visuals(for:): [0,1] 按序返回两页")
    func explicitPages01InOrder() {
        let cache = PageVisualCache()
        cache.insert(visual(for: key(page: 0)))
        cache.insert(visual(for: key(page: 1)))
        let visuals = cache.visuals(
            for: [0, 1], displayRevision: 7, geometry: geometry,
            backingScale: 2, languageRevision: 1
        )
        #expect(visuals.map(\.page) == [0, 1], "返回顺序与请求一致")
        #expect(visuals.map(\.visual.key.pageIndex) == [0, 1])
    }

    @Test("visuals(for:): [1,2] 按序返回两页")
    func explicitPages12InOrder() {
        let cache = PageVisualCache()
        cache.insert(visual(for: key(page: 1)))
        cache.insert(visual(for: key(page: 2)))
        let visuals = cache.visuals(
            for: [1, 2], displayRevision: 7, geometry: geometry,
            backingScale: 2, languageRevision: 1
        )
        #expect(visuals.map(\.page) == [1, 2])
    }

    @Test("visuals(for:): 任一页缺失 → 返回数 < 请求数(可检测不齐备)")
    func explicitPagesDetectIncompleteness() {
        let cache = PageVisualCache()
        cache.insert(visual(for: key(page: 0)))
        // 请求 [0,1], 但 page 1 缺失。
        let visuals = cache.visuals(
            for: [0, 1], displayRevision: 7, geometry: geometry,
            backingScale: 2, languageRevision: 1
        )
        #expect(visuals.count == 1, "缺失项不返回, 调用方以 count 检测不齐备")
        #expect(visuals.map(\.page) == [0])
    }

    @Test("visuals(for:): displayRevision 不匹配 → miss")
    func explicitPagesRevisionMismatch() {
        let cache = PageVisualCache()
        cache.insert(visual(for: key(page: 0, revision: 7)))
        let visuals = cache.visuals(
            for: [0], displayRevision: 8, geometry: geometry,
            backingScale: 2, languageRevision: 1
        )
        #expect(visuals.isEmpty)
    }

    @Test("visuals(for:): geometry 不匹配 → miss")
    func explicitPagesGeometryMismatch() {
        let cache = PageVisualCache()
        cache.insert(visual(for: key(page: 0)))
        let other = PageVisualGeometrySignature(
            columns: 3, rows: 1, cellSize: 60, iconSize: 32,
            horizontalSpacing: 20, verticalSpacing: 20,
            pageWidth: 200, pageHeight: 120, topInset: 0, bottomInset: 0
        )
        let visuals = cache.visuals(
            for: [0], displayRevision: 7, geometry: other,
            backingScale: 2, languageRevision: 1
        )
        #expect(visuals.isEmpty)
    }

    @Test("visuals(for:): backing scale 不匹配 → miss")
    func explicitPagesScaleMismatch() {
        let cache = PageVisualCache()
        cache.insert(visual(for: key(page: 0, scale: 2)))
        let visuals = cache.visuals(
            for: [0], displayRevision: 7, geometry: geometry,
            backingScale: 1, languageRevision: 1
        )
        #expect(visuals.isEmpty)
    }

    @Test("visuals(for:): language revision 不匹配 → miss")
    func explicitPagesLanguageMismatch() {
        let cache = PageVisualCache()
        cache.insert(visual(for: key(page: 0, language: 1)))
        let visuals = cache.visuals(
            for: [0], displayRevision: 7, geometry: geometry,
            backingScale: 2, languageRevision: 2
        )
        #expect(visuals.isEmpty)
    }

    @Test("visuals(for:): 同页多 iconEpoch → 取最后插入者")
    func explicitPagesPrefersLatestInsertion() {
        let cache = PageVisualCache()
        cache.insert(visual(for: key(page: 0, iconEpoch: 100)))
        cache.insert(visual(for: key(page: 0, iconEpoch: 1)))
        let visuals = cache.visuals(
            for: [0], displayRevision: 7, geometry: geometry,
            backingScale: 2, languageRevision: 1
        )
        #expect(visuals.count == 1)
        #expect(visuals[0].visual.key.iconEpoch == 1, "取最后插入者(单调插入序最大)")
    }

    @Test("visuals(for:): 不改变 LRU 序, 缓存上限仍 3")
    func explicitPagesDoesNotTouchLRUAndKeepsCap() {
        let cache = PageVisualCache()
        cache.insert(visual(for: key(page: 0)))
        cache.insert(visual(for: key(page: 1)))
        cache.insert(visual(for: key(page: 2)))
        let orderBefore = cache.keysForDiag
        _ = cache.visuals(
            for: [0, 1], displayRevision: 7, geometry: geometry,
            backingScale: 2, languageRevision: 1
        )
        #expect(cache.keysForDiag == orderBefore, "只读查询不提升 LRU 序")
        #expect(cache.visualCount == 3, "缓存上限仍 3")
    }
}
