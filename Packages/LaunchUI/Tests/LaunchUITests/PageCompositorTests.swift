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

    /// 两页布局(方向感知): 页 0 文档 x = 30, 页 1 文档 x = 640+30 = 670。
    private func makeTwoPlacements(
        pageWidth: CGFloat = 640,
        gridOriginX: CGFloat = 30,
        gridOriginY: CGFloat = 200
    ) -> [PageCompositor.Placement] {
        [0, 1].map { page in
            PageCompositor.Placement(
                page: page,
                baseFrame: CGRect(
                    x: CGFloat(page) * pageWidth + gridOriginX,
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

    @Test("production coverage query is independent of diagnostics")
    func coverageQuery() {
        let compositor = PageCompositor()
        let host = CALayer()
        let live = CALayer()
        compositor.activate(
            placements: makeTwoPlacements(), pageWidth: 640, startOffset: 0,
            hostLayer: host, liveLayer: live
        )
        #expect(compositor.covers(pages: [0, 1]))
        #expect(!compositor.covers(pages: [0, 2]))
        #expect(compositor.eventsForDiag.isEmpty)
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
        compositor.diagnosticsEnabled = true
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
        compositor.diagnosticsEnabled = true
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

    @Test("eventsForDiag 有界: 超过 64 条丢弃最旧, last 仍正确(M3)")
    func diagnosticEventsAreBounded() {
        let compositor = PageCompositor()
        compositor.diagnosticsEnabled = true
        let host = CALayer()
        let live = CALayer()
        compositor.activate(
            placements: makePlacements(), pageWidth: 640, startOffset: 640,
            hostLayer: host, liveLayer: live
        )
        for offset in 1...100 {
            compositor.applyOffset(640 + CGFloat(offset))
        }
        // 1 条 activated + 100 条 applied = 101 条, 裁剪后恒为 64。
        #expect(compositor.eventsForDiag.count == 64)
        #expect(compositor.eventsForDiag.last == .applied(offset: 740))
        // 最旧事件已被丢弃(首条不再是 activated, 而是被保留下来的 applied)。
        if case .applied? = compositor.eventsForDiag.first {
            #expect(Bool(true))
        } else {
            #expect(Bool(false), "最旧事件应已被裁剪")
        }
    }

    // MARK: - T-001: 两页方向感知合成

    @Test("两页: 两个 placement 可正常激活, 层序稳定")
    func twoPlacementsActivate() {
        let compositor = PageCompositor()
        let host = CALayer()
        let live = CALayer()
        var clipWrites: [CGFloat] = []
        compositor.onSyncClip = { clipWrites.append($0) }

        let placements = makeTwoPlacements()
        compositor.activate(
            placements: placements, pageWidth: 640, startOffset: 0,
            hostLayer: host, liveLayer: live
        )

        #expect(compositor.isActive)
        #expect(live.opacity == 0)
        #expect(host.sublayers?.count == 2)
        #expect(compositor.layerFramesForDiag == placements.map(\.baseFrame), "激活帧 == baseFrame(零跳变)")
        #expect(compositor.pageIndicesForDiag == [0, 1])
        #expect(clipWrites.isEmpty, "激活不得写 clip")
    }

    @Test("两页: 层 offset 数学正确(层 x = baseX - drift)")
    func twoPlacementsOffsetMath() {
        let compositor = PageCompositor()
        let host = CALayer()
        let live = CALayer()
        var clipWrites: [CGFloat] = []
        compositor.onSyncClip = { clipWrites.append($0) }

        let placements = makeTwoPlacements()
        compositor.activate(
            placements: placements, pageWidth: 640, startOffset: 0,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(320)

        let drift: CGFloat = 320
        let expected = placements.map { CGRect(
            x: $0.baseFrame.minX - drift, y: $0.baseFrame.minY,
            width: $0.baseFrame.width, height: $0.baseFrame.height
        ) }
        #expect(compositor.layerFramesForDiag == expected)
        #expect(compositor.currentOffset == 320)
        #expect(clipWrites.isEmpty)
    }

    @Test("两页: finish → 真实 clip 精确同步 → reveal → 无残留层")
    func twoPlacementsFinishSyncsClip() {
        let compositor = PageCompositor()
        compositor.diagnosticsEnabled = true
        let host = CALayer()
        let live = CALayer()
        var clipWrites: [CGFloat] = []
        compositor.onSyncClip = { clipWrites.append($0) }

        compositor.activate(
            placements: makeTwoPlacements(), pageWidth: 640, startOffset: 0,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(600)
        compositor.applyOffset(640)
        compositor.finishSettle()

        #expect(clipWrites == [640], "clip 精确同步到收敛偏移(单次写)")
        #expect(live.opacity == 1)
        #expect(!compositor.isActive)
        #expect(host.sublayers?.isEmpty ?? true, "无残留层")
        #expect(compositor.eventsForDiag.last == .finishedSettle(offset: 640))
    }

    @Test("两页: abort → 捕获当前 offset 同步 clip → reveal → 无残留层")
    func twoPlacementsAbortNoResidual() {
        let compositor = PageCompositor()
        compositor.diagnosticsEnabled = true
        let host = CALayer()
        let live = CALayer()
        var clipWrites: [CGFloat] = []
        compositor.onSyncClip = { clipWrites.append($0) }

        compositor.activate(
            placements: makeTwoPlacements(), pageWidth: 640, startOffset: 0,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(412.5)
        compositor.abort()

        #expect(clipWrites == [412.5])
        #expect(live.opacity == 1)
        #expect(!compositor.isActive)
        #expect(host.sublayers?.isEmpty ?? true)
        #expect(compositor.eventsForDiag.last == .aborted(offset: 412.5))
    }

    @Test("两页: shutdown 幂等(激活态收尾; 未激活 no-op)")
    func twoPlacementsShutdownIdempotent() {
        let compositor = PageCompositor()
        let host = CALayer()
        let live = CALayer()
        var clipWrites: [CGFloat] = []
        compositor.onSyncClip = { clipWrites.append($0) }

        compositor.shutdown()
        #expect(!compositor.isActive)

        compositor.activate(
            placements: makeTwoPlacements(), pageWidth: 640, startOffset: 0,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(300)
        compositor.shutdown()
        compositor.shutdown()

        #expect(clipWrites == [300])
        #expect(live.opacity == 1)
        #expect(!compositor.isActive)
        #expect(host.sublayers?.isEmpty ?? true)
        #expect(compositor.layerFramesForDiag.isEmpty)
    }

    @Test("两页: 快速方向反转无抖动(层连续移动, 无 clip 写, 无重建)")
    func twoPlacementsQuickReversalNoJitter() {
        let compositor = PageCompositor()
        compositor.metrics.enabled = true
        let host = CALayer()
        let live = CALayer()
        var clipWrites: [CGFloat] = []
        compositor.onSyncClip = { clipWrites.append($0) }

        let placements = makeTwoPlacements()
        compositor.activate(
            placements: placements, pageWidth: 640, startOffset: 0,
            hostLayer: host, liveLayer: live
        )
        // 前移 → 反向 → 再前移: 层连续移动, 不重建、不写 clip。
        compositor.applyOffset(200)
        compositor.applyOffset(400)
        compositor.applyOffset(300)
        compositor.applyOffset(500)
        compositor.applyOffset(640)

        #expect(compositor.isActive, "方向反转不拆 compositor")
        #expect(host.sublayers?.count == 2, "层不重建")
        #expect(clipWrites.isEmpty, "合成期间不写 clip")
        #expect(compositor.metrics.reversalCount >= 1, "方向翻转应计数")
        #expect(compositor.currentOffset == 640)
    }

    // MARK: - T-002: 默认诊断关闭 + 显式开启

    @Test("默认 diagnostics 关闭: 不记录任何 applied 事件")
    func defaultDiagnosticsOffRecordsNothing() {
        let compositor = PageCompositor()
        let host = CALayer()
        let live = CALayer()
        compositor.activate(
            placements: makePlacements(), pageWidth: 640, startOffset: 640,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(700)
        compositor.applyOffset(800)
        compositor.finishSettle()

        #expect(compositor.eventsForDiag.isEmpty, "默认产品路径不记录诊断事件")
    }

    @Test("显式开启 diagnostics: 有界记录生效(activated + applied)")
    func explicitDiagnosticsRecordsBounded() {
        let compositor = PageCompositor()
        compositor.diagnosticsEnabled = true
        let host = CALayer()
        let live = CALayer()
        compositor.activate(
            placements: makePlacements(), pageWidth: 640, startOffset: 640,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(700)
        compositor.applyOffset(800)

        #expect(compositor.eventsForDiag.first == .activated(offset: 640))
        #expect(compositor.eventsForDiag.last == .applied(offset: 800))
        #expect(compositor.eventsForDiag.count == 3, "activated + 2 applied")
    }

    @Test("metrics 默认关闭: 不计算 frame apply, 计数为 0")
    func metricsDefaultOff() {
        let compositor = PageCompositor()
        let host = CALayer()
        let live = CALayer()
        compositor.activate(
            placements: makePlacements(), pageWidth: 640, startOffset: 640,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(700)
        compositor.applyOffset(800)

        #expect(!compositor.metrics.enabled)
        #expect(compositor.metrics.compositorFrames == 0, "默认 metrics 关闭不计数")
        #expect(compositor.metrics.frameApplyTotalUs == 0)
    }

    @Test("metrics 显式开启: frame apply 正确计数")
    func metricsExplicitEnabledCounts() {
        let compositor = PageCompositor()
        compositor.metrics.enabled = true
        let host = CALayer()
        let live = CALayer()
        compositor.activate(
            placements: makePlacements(), pageWidth: 640, startOffset: 640,
            hostLayer: host, liveLayer: live
        )
        compositor.applyOffset(700)
        compositor.applyOffset(800)
        compositor.applyOffset(900)

        #expect(compositor.metrics.compositorFrames == 3)
        #expect(compositor.metrics.frameApplyTotalUs > 0)
        #expect(compositor.metrics.frameApplyMaxUs > 0)
    }
}
