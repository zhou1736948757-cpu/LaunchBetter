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

    // MARK: - T-017: 合成层方向(镜像 bug 回归)

    /// 纯色 CGImage 工厂(与 PageVisualRendererTests.solidImage 同构)。
    private func solidImage(r: CGFloat, g: CGFloat, b: CGFloat, alpha: CGFloat = 1, size: Int = 8) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: r, green: g, blue: b, alpha: alpha)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    /// 1x 页面视觉(复用 PageVisualRendererTests.makeRequest 模式):
    /// 2 列 1 行, gridOrigin=(30,30), gridSize=(140,60)。
    /// item0 = 真实红色图标(页面视觉左上); item1 = 占位(色块 + 首字母)。
    /// 页面视觉顶部 = 图标区, 底部 = 标签区(与 y-down 落位断言方向一致)。
    private func makeOrientationVisual() -> PageVisual {
        let request = PageVisualRenderRequest(
            key: PageVisualKey(
                pageIndex: 0, displayRevision: 1,
                geometry: PageVisualGeometrySignature(
                    columns: 2, rows: 1, cellSize: 60, iconSize: 32,
                    horizontalSpacing: 20, verticalSpacing: 20,
                    pageWidth: 200, pageHeight: 120, topInset: 0, bottomInset: 0
                ),
                backingScale: 1, languageRevision: 0, iconEpoch: 0
            ),
            gridOrigin: CGPoint(x: 30, y: 30),
            gridSize: CGSize(width: 140, height: 60),
            columns: 2, rows: 1, cellSize: 60, iconSize: 32,
            horizontalSpacing: 20, verticalSpacing: 20,
            scale: 1,
            cells: [
                .app(
                    slot: 0, colorRGBA: (1, 0, 0, 1), letter: "A",
                    label: "Alpha", icon: solidImage(r: 1, g: 0, b: 0)
                ),
                .app(
                    slot: 1, colorRGBA: (0.2, 0.2, 0.2, 1), letter: "B",
                    label: "Beta", icon: nil
                ),
            ]
        )
        return PageVisualRenderer.rasterize(request)!
    }

    /// 渲染 layer 到像素缓冲(buffer row 0 = 输出顶部行)。
    ///
    /// 注意: 必须**直接渲染 compositor 子层**而非 host 层树 —— 探针证实
    /// `hostLayer.render(in:)` 的软件渲染路径不应用子层 `isGeometryFlipped`
    /// (host+sub 渲染在 flipped=true/false 下输出相同), 只有直接渲染该层
    /// 才复现镜像机制(与 T-016 calayer-flip-experiment.swift 同法)。
    private func renderPixels(_ layer: CALayer, width: Int, height: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        layer.render(in: context)
        return buffer
    }

    /// (x, y) 为输出像素坐标(y = 0 为输出顶部行)。
    private func outputPixel(_ buffer: [UInt8], width: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let index = (y * width + x) * 4
        return (Int(buffer[index]), Int(buffer[index + 1]), Int(buffer[index + 2]), Int(buffer[index + 3]))
    }

    /// T-017: 合成层方向 — 走真实 activate 路径 + render(in:) 像素断言。
    ///
    /// 非 flipped host(y-up) + live 层 + rasterize 产物(1x):
    /// 输出顶部区域 == 页面视觉顶部(item0 红色图标), 输出底部区域 ==
    /// 页面视觉底部(标签白字, 无红色图标)。修复前(isGeometryFlipped=true)
    /// 该测试必须失败(红蓝颠倒)。
    @Test("T-017: 合成层方向 — 非 flipped host 渲染无镜像(输出顶部 == 页面视觉顶部)")
    func compositorLayerRendersUpright() {
        // 真实 rasterize 产物(1x): 页面视觉顶部 = item0 红色图标, 底部 = 标签。
        let visual = makeOrientationVisual()
        #expect(visual.image.width == 140 && visual.image.height == 60)

        // 非 flipped host + live 层(与生产一致: host = view.layer, y-up)。
        let host = CALayer()
        host.frame = CGRect(x: 0, y: 0, width: 140, height: 60)
        let live = CALayer()
        live.frame = host.bounds

        let placement = PageCompositor.Placement(
            page: 0,
            baseFrame: CGRect(x: 0, y: 0, width: 140, height: 60),
            visual: visual
        )
        let compositor = PageCompositor()
        compositor.activate(
            placements: [placement], pageWidth: 640, startOffset: 0,
            hostLayer: host, liveLayer: live
        )

        // 激活路径真实生效: live 隐藏 + 层 frame == baseFrame(位置不变)。
        #expect(live.opacity == 0, "激活即隐藏 live 前景")
        #expect(compositor.layerFramesForDiag == [placement.baseFrame], "层 frame == baseFrame(位置不变)")
        #expect(host.sublayers?.count == 1)

        // 直接渲染 compositor 子层(见 renderPixels 注释: host 层树渲染不应用
        // 子层 isGeometryFlipped), 读输出像素(buffer row 0 = 输出顶部)。
        let compositorLayer = host.sublayers?.first
        #expect(compositorLayer != nil, "activate 已创建合成层")
        let pixels = renderPixels(compositorLayer!, width: 140, height: 60)

        // 无镜像: 输出顶部区域 == 页面视觉顶部(item0 红色图标)。
        // 图标中心: 页面 y-down (30,16) → 非 flipped 层输出行 15。
        let icon = outputPixel(pixels, width: 140, x: 30, y: 15)
        #expect(icon.r > 200 && icon.g < 60 && icon.b < 60 && icon.a == 255, "输出顶部应为红色图标(无镜像)")

        // 输出底部区域 == 页面视觉底部(标签白字; 无红色图标)。
        // 只扫 cell0 标签区(x 2..58, 行 39..52): item0 用真实图标(无首字母),
        // 该区域唯一白字来源就是标签本身 —— 镜像时此处是红色图标, 必失败。
        var labelFound = false
        for y in 39..<54 {
            for x in 2..<59 where !labelFound {
                let p = outputPixel(pixels, width: 140, x: x, y: y)
                if p.r > 150, p.g > 150, p.b > 150 { labelFound = true }
            }
        }
        #expect(labelFound, "输出底部应含标签白字(无镜像)")
        var redInBottom = false
        for y in 39..<54 {
            for x in 0..<140 where !redInBottom {
                let p = outputPixel(pixels, width: 140, x: x, y: y)
                if p.r > 200, p.g < 60, p.b < 60 { redInBottom = true }
            }
        }
        #expect(!redInBottom, "输出底部不得出现红色图标(无镜像)")
    }
}
