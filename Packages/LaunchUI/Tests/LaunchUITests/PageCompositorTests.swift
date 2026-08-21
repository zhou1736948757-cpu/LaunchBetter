import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import LaunchUI

@Suite("PageCompositor: presentation-only", .serialized)
@MainActor
struct PageCompositorTests {
    private func makeVisual(page: Int, width: CGFloat = 140, height: CGFloat = 60) -> PageVisual {
        let context = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let key = PageVisualKey(
            pageIndex: page, displayRevision: 1,
            geometry: PageVisualGeometrySignature(
                columns: 2, rows: 1, cellSize: 60, iconSize: 32,
                horizontalSpacing: 20, verticalSpacing: 20,
                pageWidth: 640, pageHeight: 480, topInset: 0, bottomInset: 0
            ),
            backingScale: 2, languageRevision: 0, iconEpoch: 0
        )
        return PageVisual(
            key: key, image: context.makeImage()!,
            logicalBounds: CGRect(x: 30, y: 200, width: width, height: height),
            rasterScale: 2
        )
    }

    /// 3 页布局: pageWidth 640, 页 1 网格文档 x = 640+30 = 670。
    private func makePlacements(
        pageWidth: CGFloat = 640,
        gridOriginX: CGFloat = 670,
        gridOriginY: CGFloat = 200
    ) -> [PageCompositor.Placement] {
        (0..<3).map { page in
            PageCompositor.Placement(
                page: page,
                baseFrame: CGRect(
                    x: CGFloat(page) * pageWidth + gridOriginX - pageWidth,
                    y: gridOriginY,
                    width: 140, height: 60
                ),
                visual: makeVisual(page: page)
            )
        }
    }

    @Test("激活零跳变: 层 frame == baseFrame, live 隐藏, clip 不写")
    func activationZeroJump() {
        let compositor = PageCompositor()
        let host = CALayer()
        let live = CALayer()
        var clipWrites: [CGFloat] = []
        compositor.onSyncClip = { clipWrites.append($0) }

        let placements = makePlacements()
        compositor.activate(
            placements: placements, pageWidth: 640, startOffset: 640,
            hostLayer: host, liveLayer: live
        )

        #expect(compositor.isActive)
        #expect(live.opacity == 0, "激活即隐藏 live 前景内容")
        #expect(host.sublayers?.count == 3)
        #expect(compositor.layerFramesForDiag == placements.map(\.baseFrame), "激活帧 == live 位置(零跳变)")
        #expect(compositor.currentOffset == 640)
        #expect(clipWrites.isEmpty, "激活不得写 clip")
        #expect(compositor.pageIndicesForDiag == [0, 1, 2])
    }

    @Test("applyOffset: 层 x = baseX - (offset - start); 不写 clip")
    func applyOffsetMovesLayersOnly() {
        let compositor = PageCompositor()
        let host = CALayer()
        let live = CALayer()
        var clipWrites: [CGFloat] = []
        compositor.onSyncClip = { clipWrites.append($0) }

        let placements = makePlacements()
        compositor.activate(
            placements: placements, pageWidth: 640, startOffset: 640,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(960)

        let drift: CGFloat = 960 - 640
        let expected = placements.map { CGRect(
            x: $0.baseFrame.minX - drift, y: $0.baseFrame.minY,
            width: $0.baseFrame.width, height: $0.baseFrame.height
        ) }
        #expect(compositor.layerFramesForDiag == expected)
        #expect(compositor.currentOffset == 960)
        #expect(clipWrites.isEmpty)
        #expect(host.sublayers?.count == 3, "合成期间层不拆除")
    }

    @Test("settle 完成: 真实 clip 同步到精确目标 → reveal → 移除层(同一事务序)")
    func finishSettleSyncsClipThenReveals() {
        let compositor = PageCompositor()
        let host = CALayer()
        let live = CALayer()
        var clipWrites: [CGFloat] = []
        compositor.onSyncClip = { clipWrites.append($0) }

        compositor.activate(
            placements: makePlacements(), pageWidth: 640, startOffset: 640,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(1270)
        compositor.applyOffset(1280)
        compositor.finishSettle()

        #expect(clipWrites == [1280], "clip 精确同步到收敛偏移(单次写)")
        #expect(live.opacity == 1, "settle 完成后 reveal live")
        #expect(!compositor.isActive)
        #expect(host.sublayers == nil || host.sublayers?.isEmpty == true, "层全部移除")
        #expect(compositor.layerFramesForDiag.isEmpty)
        #expect(compositor.eventsForDiag.last == .finishedSettle(offset: 1280))
    }

    @Test("中止: 捕获当前 visual offset 同步 clip → reveal → 移除(安全回 live)")
    func abortSyncsCurrentOffset() {
        let compositor = PageCompositor()
        let host = CALayer()
        let live = CALayer()
        var clipWrites: [CGFloat] = []
        compositor.onSyncClip = { clipWrites.append($0) }

        compositor.activate(
            placements: makePlacements(), pageWidth: 640, startOffset: 640,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(812.5)
        compositor.abort()

        #expect(clipWrites == [812.5], "中止必须同步到当前 visual offset")
        #expect(live.opacity == 1)
        #expect(!compositor.isActive)
        #expect(host.sublayers?.isEmpty ?? true)
        #expect(compositor.eventsForDiag.last == .aborted(offset: 812.5))
    }

    @Test("打断: 新手势不拆 compositor, 继续从 compositor.currentOffset")
    func interruptionKeepsCompositor() {
        let compositor = PageCompositor()
        let host = CALayer()
        let live = CALayer()
        compositor.activate(
            placements: makePlacements(), pageWidth: 640, startOffset: 640,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(800)

        // 新手势 begin → 再次 activate 必须是 no-op(guard), 不重建不闪烁。
        compositor.activate(
            placements: makePlacements(), pageWidth: 640, startOffset: 800,
            hostLayer: host, liveLayer: live
        )

        #expect(compositor.isActive)
        #expect(host.sublayers?.count == 3)
        #expect(live.opacity == 0)
        #expect(compositor.currentOffset == 800, "继续从 compositor.currentOffset 跟手")

        compositor.applyOffset(900)
        #expect(compositor.currentOffset == 900)
    }

    @Test("反向: 位移方向翻转 → reversalCount 递增")
    func reversalDetection() {
        let compositor = PageCompositor()
        compositor.metrics.enabled = true
        let host = CALayer()
        let live = CALayer()
        compositor.activate(
            placements: makePlacements(), pageWidth: 640, startOffset: 640,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(700)
        compositor.applyOffset(760)
        compositor.applyOffset(730)
        compositor.applyOffset(710)
        #expect(compositor.metrics.reversalCount >= 1, "方向翻转应计数")
        #expect(compositor.metrics.compositorFrames == 4)
    }

    @Test("shutdown 幂等: 激活态同步收尾; 未激活 no-op")
    func shutdownIdempotent() {
        let compositor = PageCompositor()
        let host = CALayer()
        let live = CALayer()
        var clipWrites: [CGFloat] = []
        compositor.onSyncClip = { clipWrites.append($0) }

        compositor.shutdown()
        #expect(!compositor.isActive)

        compositor.activate(
            placements: makePlacements(), pageWidth: 640, startOffset: 640,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(730)
        compositor.shutdown()
        compositor.shutdown()

        #expect(clipWrites == [730])
        #expect(live.opacity == 1)
        #expect(!compositor.isActive)
        #expect(host.sublayers?.isEmpty ?? true)
        #expect(compositor.layerFramesForDiag.isEmpty)
    }

    @Test("末页 rubber band 负位移: 层位置允许越界, 无 clip 写")
    func rubberBandOffsetKeepsLayersOnly() {
        let compositor = PageCompositor()
        let host = CALayer()
        let live = CALayer()
        var clipWrites: [CGFloat] = []
        compositor.onSyncClip = { clipWrites.append($0) }

        compositor.activate(
            placements: makePlacements(), pageWidth: 640, startOffset: 640,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(610)
        let drift: CGFloat = 610 - 640
        #expect(
            compositor.layerFramesForDiag.map(\.minX)
                == makePlacements().map { $0.baseFrame.minX - drift }
        )
        #expect(clipWrites.isEmpty)
    }
}
