import AppKit
import CoreGraphics
import Foundation
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("PageCompositor grid integration", .serialized)
@MainActor
struct PageCompositorGridIntegrationTests {
    // MARK: - 测试基础设施

    private func makeApp(_ page: Int, _ index: Int) -> AppID {
        AppID("/Applications/CompA\(page)\(index).app")!
    }

    private func makeWindow(for controller: GridViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    /// 合成带 phase 的 precise 滚动事件。
    ///
    /// 注意: CGEvent field 99(kCGScrollWheelEventPhase)使用 kCGScrollPhase
    /// 编码(began=1, changed=2, ended=4, cancelled=8), 与 NSEvent.Phase
    /// rawValue 不同; CGEvent→NSEvent 转换后仍是 kCGScrollPhase 语义。
    /// 这里直接按 kCGScrollPhase 编码写入字段, 避免依赖 rawValue。
    private func makeScroll(dx: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase = []) -> NSEvent? {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let cg = CGEvent(
                  scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                  wheel1: 0, wheel2: Int32(dx), wheel3: 0
              ) else { return nil }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        let phaseField: Int64
        switch phase {
        case .began: phaseField = 1
        case .changed: phaseField = 2
        case .ended: phaseField = 4
        case .cancelled: phaseField = 8
        default: phaseField = 0
        }
        cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: phaseField)
        cg.setIntegerValueField(CGEventField(rawValue: 123)!, value: Int64(momentum.rawValue))
        return NSEvent(cgEvent: cg)
    }

    /// 驱动 display frame 直到 paging idle using the test-only fixed-frame clock.
    private func driveUntilIdle(_ grid: GridViewController, maxFrames: Int = 900) async -> Bool {
        var frames = 0
        while grid.pagingProbePhase() != "idle", frames < maxFrames {
            _ = grid.pagingProbeDisplayFrame()
            frames += 1
        }
        return grid.pagingProbePhase() == "idle"
    }

    /// Read the Grid-owned paging controller through its existing internal test
    /// seam without adding a production forwarding API.
    private func pagingControllerForDiag(_ grid: GridViewController) -> PagingInteractionController {
        guard let paging = Mirror(reflecting: grid).children
            .first(where: { $0.label == "paging" })?.value as? PagingInteractionController
        else {
            fatalError("GridViewController paging diagnostic seam unavailable")
        }
        return paging
    }

    /// 等待 working set 三页齐备(重试版)。
    ///
    /// 并行 suite 会瞬时翻转全局 `L10n.currentLanguage`; 准备期间的实时语言
    /// 复验(FX-F FIX-2)会按规范丢弃该轮视觉(产品语义正确, 下一轮自动重建)。
    /// 本助手在语言翻转恢复后重试 prepare, 直到缓存 3 页齐备, 让断言聚焦
    /// 最终语义而非单轮时序。注意: 断言"复验失败中间态"的用例不得使用。
    private func waitPrepared(_ grid: GridViewController, maxAttempts: Int = 8) async {
        for _ in 0..<maxAttempts {
            await grid.waitForPageVisualPrepareForDiag()
            if grid.pageVisualCacheCountForDiag == 3 { return }
        }
    }

    /// 等待 working set 至少 `count` 页齐备(首页/末页两页方向感知用)。
    private func waitPrepared(_ grid: GridViewController, count: Int, maxAttempts: Int = 8) async {
        for _ in 0..<maxAttempts {
            await grid.waitForPageVisualPrepareForDiag()
            if grid.pageVisualCacheCountForDiag >= count { return }
        }
    }

    private func makeGrid(_ store: CompositorIntegrationStore) -> GridViewController {
        let grid = GridViewController(
            store: store, iconProvider: CompositorIntegrationIconProvider()
        )
        grid.pageVisualCompositorEnabled = true
        // 测试替身 3 项/页(稀疏); 密度门放宽以专注合成语义本身。
        // 密度门独立于合成语义, 由 densityGate 测试单独覆盖。
        grid.pageVisualMinItemsPerPage = 1
        grid.enableDeterministicPagingProbeClock()
        return grid
    }

    private func makeDiagnosticPlacement(page: Int) -> PageCompositor.Placement {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let key = PageVisualKey(
            pageIndex: page, displayRevision: 1,
            geometry: PageVisualGeometrySignature(
                columns: 1, rows: 1, cellSize: 40, iconSize: 24,
                horizontalSpacing: 8, verticalSpacing: 8,
                pageWidth: 640, pageHeight: 480, topInset: 0, bottomInset: 0
            ),
            backingScale: 2, languageRevision: 0, iconEpoch: 0
        )
        let visual = PageVisual(
            key: key, image: context.makeImage()!,
            logicalBounds: CGRect(x: 20, y: 100, width: 40, height: 40),
            rasterScale: 2
        )
        return PageCompositor.Placement(
            page: page,
            baseFrame: CGRect(x: CGFloat(page) * 640 + 20, y: 100, width: 40, height: 40),
            visual: visual
        )
    }

    // MARK: - 密度门

    @Test("eligibility: 密度门 — 稀疏页(< 默认阈值 20)不可合成; 放宽阈值后合成")
    func densityGate() async throws {
        let store = CompositorIntegrationStore()
        let grid = GridViewController(
            store: store, iconProvider: CompositorIntegrationIconProvider()
        )
        grid.pageVisualCompositorEnabled = true
        // 默认阈值 20: 3 项/页的稀疏页即使视觉齐备也不得合成。
        #expect(grid.pageVisualMinItemsPerPage == 20, "默认密度阈值 20")
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        await waitPrepared(grid)
        #expect(grid.pageVisualCacheCountForDiag == 3, "视觉仍按 working set 准备")
        #expect(!grid.pageCompositorEligibleForDiag, "稀疏页(< 阈值)不可合成")

        grid.pageVisualMinItemsPerPage = 1
        #expect(grid.pageCompositorEligibleForDiag, "放宽密度门后合成")
    }

    // MARK: - eligibility

    @Test("eligibility: 普通页 true; 页 0 边界 / 搜索 / 挂起(folder/settings)/ 拖拽 false")
    func eligibilityMatrix() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        #expect(!grid.isSearchMode)

        // 页 0: 视觉未准备 → 不可合成(方向感知下页 0 可向 next 合成, 见 T-001 测试)。
        #expect(!grid.pageCompositorEligibleForDiag, "页 0 视觉未准备 → 不可合成")

        grid.goToPage(1, animated: false)
        #expect(grid.currentPageValue == 1)
        await waitPrepared(grid)
        #expect(grid.pageCompositorEligibleForDiag, "中间普通页 + 视觉齐备 → 可合成")

        // 挂起(Folder/Settings 共用 suspendPagingForSurface)→ 不可合成。
        grid.suspendPagingForSurface()
        #expect(!grid.pageCompositorEligibleForDiag)
        grid.resumePagingForSurface()
        #expect(grid.pageCompositorEligibleForDiag)

        // 拖拽中 → 不可合成。
        let drag = DragController(grid: grid, store: store)
        grid.dragController = drag
        let firstItem = grid.allItems().first!
        let anchor = grid.frame(atFlatIndex: 0)
        let point = grid.collectionViewRef.convert(
            NSPoint(x: anchor.midX, y: anchor.midY), to: nil
        )
        drag.beginDrag(item: firstItem, at: point)
        #expect(drag.isDragging)
        #expect(!grid.pageCompositorEligibleForDiag, "拖拽中不可合成")
        drag.cancelDrag()
        grid.dragController = nil
        #expect(grid.pageCompositorEligibleForDiag)

        // 搜索 → 不可合成 + purge 缓存。
        store.searchResultsValue = [.app(makeApp(0, 0))]
        store.revision &+= 1
        grid.refresh()
        #expect(grid.isSearchMode)
        #expect(!grid.pageCompositorEligibleForDiag)
        #expect(grid.pageVisualCacheCountForDiag == 0, "进入搜索 purge 视觉缓存")

        // 退出搜索恢复。
        store.searchResultsValue = nil
        store.revision &+= 1
        grid.refresh()
        #expect(!grid.isSearchMode)
        #expect(grid.currentPageValue == 1)
    }

    @Test("eligibility: leading surface — layout page 0 可向 next 合成; previous → Library 降级")
    func eligibilityLibraryBoundary() async throws {
        let store = CompositorLeadingStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        // leading 启用: 物理 1 = layout page 0, 其 previous = Library。
        #expect(grid.currentSurfaceValue == .layoutPage(0))
        await waitPrepared(grid, count: 2)
        #expect(grid.pageCompositorEligibleForDiag, "layout page 0 可向 next(page 1)合成")

        grid.goToPage(1, animated: false)
        await waitPrepared(grid)
        #expect(grid.pageCompositorEligibleForDiag, "layout page 1 两侧都是普通页 → 可合成")
    }

    // MARK: - offset 语义

    @Test("offset 语义: 未激活 = clip; 激活 = compositor.currentOffset")
    func offsetSemantics() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        #expect(grid.readPagingOffset() == 0, "未激活 = clip offset")

        grid.goToPage(1, animated: false)
        let pageWidth = grid.geometry.pageWidth
        #expect(grid.readPagingOffset() == pageWidth, "未激活 = clip offset(跳页后)")

        await waitPrepared(grid)
        grid.pagingProbeGesture(deltaXs: [-100, -150])
        #expect(grid.pagingProbePhase() == "settling")
        #expect(grid.pageCompositorActiveForDiag)
        #expect(
            grid.readPagingOffset() == grid.pageCompositorCurrentOffsetForDiag,
            "激活 → 单一偏移源 = compositor.currentOffset"
        )

        _ = await driveUntilIdle(grid)
        #expect(grid.readPagingOffset() == grid.clipOffsetXForDiag, "收口后 = clip")
        #expect(!grid.pageCompositorActiveForDiag)
    }

    // MARK: - settle 激活 / 完成

    @Test("settle 激活零跳变 + 完成同步真实 clip 再 reveal: Page1 → Page2")
    func settleActivationAndCompletion() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        let pageWidth = grid.geometry.pageWidth
        #expect(grid.clipOffsetXForDiag == pageWidth)

        await waitPrepared(grid)
        #expect(grid.pageCompositorEligibleForDiag)

        // 手势左滑 → 目标 Page2。
        grid.pagingProbeGesture(deltaXs: [-180, -240, -120])

        // 激活断言(settle 进行中, compositor 保持):
        #expect(grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorLiveOpacityForDiag == 0, "live 前景隐藏")
        #expect(grid.clipOffsetXForDiag == pageWidth, "compositor 期间真实 clip 不动")
        #expect(
            grid.pageCompositorCurrentOffsetForDiag == pageWidth,
            "激活帧偏移 == clip 偏移(零跳变)"
        )
        #expect(grid.pageCompositorLayerFramesForDiag.count == 2)
        #expect(grid.pageCompositorPageIndicesForDiag == [1, 2], "方向感知两页 [current, target]")

        // settle 收敛 → clip 同步到精确目标 → reveal → 释放。
        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(!grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorLiveOpacityForDiag == 1, "settle 完成后 reveal live")
        #expect(grid.clipOffsetXForDiag == pageWidth * 2, "clip 精确同步到目标页")
        #expect(grid.pageCompositorLayerFramesForDiag.isEmpty, "无残留层")
        #expect(grid.currentPageValue == 2)
        #expect(grid.pageVisualCacheCountForDiag <= 3)
        // 空窗修复(v0.5.1): 揭露时刻强制同步布局已执行, 目标页 cell 在
        // 合成表面移除前就绪(快速甩页后不再出现只有壁纸的空白页)。
        #expect(
            grid.pageCompositorSyncLayoutCountForDiag >= 1,
            "揭露前强制同步布局已执行"
        )
        #expect(
            grid.visibleItemsCountForDiag > 0,
            "揭露时目标页 cell 已物化"
        )
        // 平滑落地(v0.5.2): settling 帧内真实 clip 遮盖下渐进跟进已发生。
        #expect(
            grid.pageVisualRealClipAdvanceCountForDiag > 0,
            "settle 期间真实 clip 渐进跟进已执行"
        )
    }

    @Test("平滑落地: settling 帧内真实 clip 遮盖下向目标渐进推进")
    func realClipAdvancesIncrementallyDuringSettle() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        let pageWidth = grid.geometry.pageWidth
        await waitPrepared(grid)

        grid.pagingProbeGesture(deltaXs: [-180, -240])
        #expect(grid.pagingProbePhase() == "settling")

        // 驱动少量 settle 帧(带真实间隔, 时间驱动弹簧才能推进): 真实 clip
        // 应在遮盖下向弹簧当前位置渐进推进, 但仍落后于合成器偏移(渐进,
        // 未一步到位)。注意合成器 currentOffset 在 settle 过程中从起点向
        // 目标收敛, 这里对比的是"活值"。
        for _ in 0..<10 {
            _ = grid.pagingProbeDisplayFrame()
        }
        let midClip = grid.clipOffsetXForDiag
        let midCompositorOffset = grid.readPagingOffset()
        #expect(
            midClip > pageWidth,
            "clip 已从起点推进(mid=\(midClip))"
        )
        #expect(
            midClip < midCompositorOffset,
            "clip 落后于合成器偏移(遮盖下渐进)"
        )

        // 收敛: 跟进至目标附近, 最终同步精确落点(一页手势 = 起点+pageWidth)。
        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(!grid.pageCompositorActiveForDiag)
        #expect(grid.clipOffsetXForDiag == pageWidth * 2, "最终精确同步到目标页")
        #expect(grid.visibleItemsCountForDiag > 0)
    }

    @Test("T-010 A: active settle → uncovered same-direction Page3 live fallback")
    func interruptionFallsBackWhenCoverageMissing() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        let pageWidth = grid.geometry.pageWidth
        await waitPrepared(grid)

        // Real Page 1 → Page 2 compositor settle, then leave it mid-flight.
        grid.pagingProbeGesture(deltaXs: [-180, -240, -120])
        #expect(grid.pagingProbePhase() == "settling")
        #expect(grid.pageCompositorActiveForDiag)
        for _ in 0..<20 { _ = grid.pagingProbeDisplayFrame() }
        let abortOffset = grid.pageCompositorCurrentOffsetForDiag
        #expect(abortOffset > pageWidth && abortOffset < pageWidth * 2)
        let cacheCountBeforeInterruption = grid.pageVisualCacheCountForDiag

        // A second, genuinely same-direction gesture targets Page 3. The active
        // [Page1, Page2] cover does not include Page 3, so abort must be
        // immediate and continue live from the compositor's exact offset.
        grid.pagingProbeGesture(deltaXs: [-180, -240, -120])
        #expect(!grid.pageCompositorActiveForDiag, "Page 3 未覆盖时立即降级 live")
        #expect(grid.pageCompositorLiveOpacityForDiag == 1)
        #expect(abs(grid.clipOffsetXForDiag - abortOffset) < 0.001, "live 从 abort offset 连续")
        #expect(grid.visibleItemsCountForDiag > 0, "降级后 live content 非空")
        #expect(
            grid.pageVisualCacheCountForDiag == cacheCountBeforeInterruption,
            "打断不应同步等待或重建 PageVisual/cache"
        )
        #expect(grid.pagingProbePhase() == "settling")

        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(grid.currentPageValue == 3, "真实第二次手势必须落到 Page 3")
        #expect(grid.clipOffsetXForDiag == pageWidth * 3, "Page 3 clip 精确对齐")
        #expect(!grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorLayerFramesForDiag.isEmpty)
        #expect(grid.pageCompositorLiveOpacityForDiag == 1)
        #expect(grid.visibleItemsCountForDiag > 0, "Page 3 live content 非空")
    }

    // MARK: - 反向

    @Test("Page2 → 过半 → 反向 → 回 Page2: 方向翻转不拆 compositor, 收口零残留")
    func halfwayReverseBackToPage2() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(2, animated: false)
        let pageWidth = grid.geometry.pageWidth
        await waitPrepared(grid)

        // 事件级手势: 前移过半 → 反向 → 归零(位移净 0 → finishWithoutSettle)。
        grid.pagingProbeFeed(makeScroll(dx: -80, phase: .began)!)
        _ = grid.pagingProbeDisplayFrame()
        grid.pagingProbeFeed(makeScroll(dx: -160, phase: .changed)!)
        _ = grid.pagingProbeDisplayFrame()
        grid.pagingProbeFeed(makeScroll(dx: -160, phase: .changed)!)
        _ = grid.pagingProbeDisplayFrame()
        #expect(grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorCurrentOffsetForDiag > pageWidth * 2.4, "已过半(>40% 额外)")
        #expect(grid.clipOffsetXForDiag == pageWidth * 2, "compositor 期间 clip 不动")

        grid.pagingProbeFeed(makeScroll(dx: +120, phase: .changed)!)
        _ = grid.pagingProbeDisplayFrame()
        grid.pagingProbeFeed(makeScroll(dx: +220, phase: .changed)!)
        _ = grid.pagingProbeDisplayFrame()
        grid.pagingProbeFeed(makeScroll(dx: 0, phase: .ended)!)
        #expect(grid.pagingProbePhase() == "settling", "净位移 -60(低于 90pt 阈值)→ settle 弹回 Page2")

        let settled = await driveUntilIdle(grid)
        #expect(settled)
        // 收口: clip 同步回 Page2, live reveal, 层移除。
        #expect(!grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorLiveOpacityForDiag == 1)
        #expect(grid.clipOffsetXForDiag == pageWidth * 2, "反向 → settle 回 Page2, clip 精确同步")
        #expect(grid.pageCompositorLayerFramesForDiag.isEmpty)
        #expect(grid.currentPageValue == 2)
    }

    @Test("T-010 B: covered reverse reuses active compositor layers")
    func coveredReverseReusesActiveCompositor() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        let pageWidth = grid.geometry.pageWidth
        await waitPrepared(grid)
        grid.pageCompositor.diagnosticsEnabled = true

        grid.pagingProbeGesture(deltaXs: [-180, -240, -120])
        // Let the real Page 1 → Page 2 settle pass the midpoint, but interrupt
        // before completion.  At this point the active presentation is still
        // exactly the [Page 1, Page 2] pair and the rounded offset resolves the
        // reverse gesture to Page 1 (not Page 0).
        for _ in 0..<24 { _ = grid.pagingProbeDisplayFrame() }
        #expect(grid.pageCompositorActiveForDiag)
        let activePagesBeforeReverse = grid.pageCompositorPageIndicesForDiag
        let offsetBeforeReverse = grid.pageCompositorCurrentOffsetForDiag
        let layersBeforeReverse = grid.pageCompositor.layerObjectIdentifiersForDiag
        let eventsBeforeReverse = grid.pageCompositorEventsForDiag
        let abortsBeforeReverse = grid.pageCompositor.metrics.abortCount
        let teardownCount: ([PageCompositor.Event]) -> Int = { events in
            events.reduce(into: 0) { count, event in
                switch event {
                case .finishedSettle, .aborted, .shutdown:
                    count += 1
                case .activated, .applied:
                    break
                }
            }
        }
        let teardownsBeforeReverse = teardownCount(eventsBeforeReverse)
        #expect(activePagesBeforeReverse == [1, 2], "Page 1 → Page 2 active coverage")
        #expect(offsetBeforeReverse > pageWidth * 1.5 && offsetBeforeReverse < pageWidth * 2)
        #expect(layersBeforeReverse.count == activePagesBeforeReverse.count)
        #expect(grid.pageCompositorLiveOpacityForDiag == 0, "reverse 前 live 必须隐藏")

        // This is a real second gesture while the first settle is mid-flight.
        // Its base offset is in Page 2's half, so PagingTargetResolver selects
        // Page 1; Page 1 is explicitly proven to remain in active coverage.
        let offsetAtReverseStart = grid.pageCompositorCurrentOffsetForDiag
        grid.pagingProbeGesture(deltaXs: [180, 240, 120])
        #expect(grid.pageCompositorCurrentOffsetForDiag == offsetAtReverseStart, "reverse begins continuously")
        #expect(grid.pageCompositorActiveForDiag, "covered reverse 不得 abort")
        #expect(grid.pageCompositorPageIndicesForDiag == activePagesBeforeReverse)
        #expect(activePagesBeforeReverse.contains(1), "reverse target Page 1 必须在 active placements")
        _ = grid.pagingProbeDisplayFrame()
        #expect(grid.pageCompositorActiveForDiag, "covered reverse 不得 teardown")
        #expect(grid.pageCompositor.layerObjectIdentifiersForDiag == layersBeforeReverse)
        #expect(grid.pageCompositorLiveOpacityForDiag == 0, "covered reverse 不提前揭露 live")
        #expect(grid.pageCompositorCurrentOffsetForDiag < offsetBeforeReverse)
        let eventsAfterReverse = grid.pageCompositorEventsForDiag
        #expect(grid.pageCompositor.metrics.abortCount == abortsBeforeReverse, "covered reverse 不得 abort")
        #expect(teardownCount(eventsAfterReverse) == teardownsBeforeReverse, "covered reverse 不得 teardown")
        #expect(eventsAfterReverse.count > eventsBeforeReverse.count, "reverse 必须产生真实 compositor tracking")

        // Read the controller's existing internal test seam directly and assert
        // the resolver's target before any settle frame can finish.
        let resolvedReverseTarget = pagingControllerForDiag(grid).settleTargetPageForTest
        #expect(resolvedReverseTarget == 1, "covered reverse resolved target = Page 1")
        #expect(activePagesBeforeReverse.contains(resolvedReverseTarget ?? -1), "resolved target remains in active placements")

        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(grid.currentPageValue == 1, "covered reverse final target = Page 1")
        #expect(grid.clipOffsetXForDiag == pageWidth, "Page 1 clip 精确对齐")
        #expect(!grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorLayerFramesForDiag.isEmpty)
        #expect(grid.pageCompositorLiveOpacityForDiag == 1)
        #expect(grid.visibleItemsCountForDiag > 0)

        // Final cleanup must be exactly one normal settle, with no abort or
        // shutdown added by the covered reverse path.
        let finalEvents = grid.pageCompositorEventsForDiag
        func eventCount(_ events: [PageCompositor.Event], matching kind: (PageCompositor.Event) -> Bool) -> Int {
            events.dropFirst(eventsBeforeReverse.count).reduce(into: 0) { count, event in
                if kind(event) { count += 1 }
            }
        }
        #expect(eventCount(finalEvents) { if case .finishedSettle = $0 { return true }; return false } == 1)
        #expect(eventCount(finalEvents) { if case .aborted = $0 { return true }; return false } == 0)
        #expect(eventCount(finalEvents) { if case .shutdown = $0 { return true }; return false } == 0)
    }

    @Test("反向后继续: 方向翻转计数; settle 收敛到目标页")
    func reversalThenForwardSettles() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(2, animated: false)
        let pageWidth = grid.geometry.pageWidth
        await waitPrepared(grid)
        grid.pageCompositor.metrics.enabled = true

        // 前移 → 反向 → 继续前移(净 -420 → settle Page3)。
        grid.pagingProbeFeed(makeScroll(dx: -100, phase: .began)!)
        _ = grid.pagingProbeDisplayFrame()
        grid.pagingProbeFeed(makeScroll(dx: -200, phase: .changed)!)
        _ = grid.pagingProbeDisplayFrame()
        grid.pagingProbeFeed(makeScroll(dx: -120, phase: .changed)!)
        _ = grid.pagingProbeDisplayFrame()
        grid.pagingProbeFeed(makeScroll(dx: +90, phase: .changed)!)
        _ = grid.pagingProbeDisplayFrame()
        grid.pagingProbeFeed(makeScroll(dx: -90, phase: .changed)!)
        _ = grid.pagingProbeDisplayFrame()
        grid.pagingProbeFeed(makeScroll(dx: 0, phase: .ended)!)

        #expect(grid.pageCompositorActiveForDiag, "反向期间 compositor 保持")
        #expect(grid.pageCompositor.metrics.reversalCount >= 1)
        #expect(grid.pagingProbePhase() == "settling")

        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(!grid.pageCompositorActiveForDiag)
        #expect(grid.clipOffsetXForDiag == pageWidth * 3, "反向后续行 → 收敛到 Page3")
        #expect(grid.currentPageValue == 3)
    }

    // MARK: - 中止

    @Test("中止同步: 中途 shutdown → clip 同步到 visual offset → reveal → 回 live")
    func abortSyncMidGesture() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        let pageWidth = grid.geometry.pageWidth
        await waitPrepared(grid)

        // tracking 中(compositor active, offset 已移动)。
        grid.pagingProbeFeed(makeScroll(dx: -80, phase: .began)!)
        _ = grid.pagingProbeDisplayFrame()
        grid.pagingProbeFeed(makeScroll(dx: -140, phase: .changed)!)
        _ = grid.pagingProbeDisplayFrame()
        #expect(grid.pageCompositorActiveForDiag)
        let visualOffset = grid.pageCompositorCurrentOffsetForDiag
        #expect(visualOffset > pageWidth)
        #expect(grid.clipOffsetXForDiag == pageWidth)

        // 结构变更(settings/搜索等)→ 中止: clip 同步到当前 visual offset。
        grid.shutdownPageCompositor()
        #expect(!grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorLiveOpacityForDiag == 1)
        #expect(grid.clipOffsetXForDiag == visualOffset, "中止捕获偏移同步真实 clip")
        #expect(grid.pageCompositorLayerFramesForDiag.isEmpty)

        // 后续 live 继续: clip 随跟踪移动。
        grid.pagingProbeFeed(makeScroll(dx: -100, phase: .changed)!)
        _ = grid.pagingProbeDisplayFrame()
        #expect(grid.clipOffsetXForDiag > visualOffset, "回 live 后 clip 正常移动")
        #expect(!grid.pageCompositorActiveForDiag)

        grid.pagingProbeFeed(makeScroll(dx: 0, phase: .ended)!)
        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(!grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorLayerFramesForDiag.isEmpty)
        #expect(grid.pageCompositorLiveOpacityForDiag == 1)
    }

    @Test("数据刷新: active compositor 在替换 page model 前收口")
    func dataRefreshShutsDownPageCompositor() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        let pageWidth = grid.geometry.pageWidth
        await waitPrepared(grid)

        grid.pagingProbeGesture(deltaXs: [-80, -140])
        #expect(grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorLiveOpacityForDiag == 0)

        // Simulate an external catalog revision while the user is swiping.
        store.revision &+= 1
        grid.refresh()

        #expect(!grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorLiveOpacityForDiag == 1)
        #expect(grid.pageCompositorLayerFramesForDiag.isEmpty)
        #expect(
            grid.clipOffsetXForDiag == CGFloat(grid.currentPageValue) * pageWidth,
            "refresh leaves the live clip aligned to the current page"
        )
    }

    // MARK: - 500 轮压力

    @Test("500 轮: 无泄漏 / 无残留层 / 无中间态; 缓存 ≤ 3")
    func stress500Rounds() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        let pageWidth = grid.geometry.pageWidth

        for round in 0..<500 {
            let targetPage = round % 2 == 0 ? 1 : 2
            grid.goToPage(targetPage, animated: false)
            await waitPrepared(grid)
            #expect(grid.pageCompositorEligibleForDiag)

            // 事件级手势(交替方向) + 中间帧: 激活 → 移动 → 反向 → 净 0 收口。
            let direction: CGFloat = round % 2 == 0 ? -1 : 1
            grid.pagingProbeFeed(makeScroll(dx: -60 * direction, phase: .began)!)
            _ = grid.pagingProbeDisplayFrame()
            grid.pagingProbeFeed(makeScroll(dx: -150 * direction, phase: .changed)!)
            _ = grid.pagingProbeDisplayFrame()
            grid.pagingProbeFeed(makeScroll(dx: +60 * direction, phase: .changed)!)
            _ = grid.pagingProbeDisplayFrame()
            grid.pagingProbeFeed(makeScroll(dx: +150 * direction, phase: .changed)!)
            _ = grid.pagingProbeDisplayFrame()
            grid.pagingProbeFeed(makeScroll(dx: 0, phase: .ended)!)

            // 不变式: 每轮结束无残留、无中间态、真实 clip == 起始页。
            #expect(grid.pagingProbePhase() == "idle", "第 \(round) 轮: 必须回 idle")
            #expect(!grid.pageCompositorActiveForDiag, "第 \(round) 轮: compositor 已释放")
            #expect(grid.pageCompositorLayerFramesForDiag.isEmpty, "第 \(round) 轮: 无残留层")
            #expect(grid.pageCompositorLiveOpacityForDiag == 1, "第 \(round) 轮: live 已 reveal")
            // 净位移 0 → 收口把 clip 同步到最后应用的 compositor offset
            // (与 live 分页行为一致: 零位移不触发 settle)。
            let residual: CGFloat = 1.3 * 150 * direction
            #expect(
                grid.clipOffsetXForDiag == CGFloat(targetPage) * pageWidth + residual,
                "第 \(round) 轮: clip 同步到最后应用的 compositor offset"
            )
            #expect(grid.pageVisualCacheCountForDiag <= 3, "第 \(round) 轮: 缓存有界")
            #expect(grid.currentPageValue == targetPage, "第 \(round) 轮: 语义页一致")
        }
    }

    // MARK: - 每页独立 iconEpoch

    @Test("每页独立 epoch: prepare 后缓存 3 页, 各页 key.iconEpoch 互不相同")
    func perPageIconEpochKeysIndependent() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        await waitPrepared(grid)

        // 3 页均已 prepare 且驻留缓存(LRU 上限 3)。
        let keys = grid.pageVisualKeysForDiag
        #expect(keys.count == 3, "prepare 后缓存 3 页")
        #expect(keys.map(\.pageIndex).sorted() == [0, 1, 2])

        // 每页图标集合不同(页内 3 个唯一 app)→ 各页独立 epoch。
        // 若退回"整体单一 epoch", 三页键会共享同一 iconEpoch。
        let epochs = Set(keys.map(\.iconEpoch))
        #expect(epochs.count == 3, "各页 key.iconEpoch 独立(相邻页集合不同)")
    }

    // MARK: - prepare 快照复验(FX-F FIX-2)

    @Test("快照复验: 解析期间 displayRevision 变化 → 该页视觉不插入; 稳定轮重建成功")
    func snapshotRecheckDropsStaleVisualsOnce() async throws {
        let store = SnapshotRecheckStore()
        let folderChildIDs = Set(store.folderChildrenPayload.values.flatMap { $0 })
        let provider = SnapshotBumpIconProvider(store: store, childIDs: folderChildIDs)
        let grid = GridViewController(store: store, iconProvider: provider)
        grid.pageVisualCompositorEnabled = true
        grid.pageVisualMinItemsPerPage = 1
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)

        // 第 1 轮: 页 0/1(普通 app)在提升前已解析并入缓存; 页 2 是文件夹页,
        // 其子项图标请求只可能来自 resolveIcons(单元格只配置可见页 1,
        // prewarm 跳过 folder 项)—— 解析瞬间 revision 被提升 → 该页插入前
        // 复验(store.displayRevision == capturedRevision)失败 → 视觉丢弃。
        // 注意: 这里**不能**用 waitPrepared(它重试到 3 页齐备, 会吞掉
        // 本用例要断言的"复验失败不插入"中间态)。
        await grid.waitForPageVisualPrepareForDiag()
        #expect(provider.didBump, "文件夹子项图标请求只来自 resolveIcons")
        #expect(
            grid.pageVisualCacheCountForDiag == 2,
            "复验失败的页(2)不插入, 其余两页已按起点快照键插入"
        )
        #expect(grid.pageVisualKeysForDiag.map(\.pageIndex).sorted() == [0, 1])
        #expect(!grid.pageCompositorEligibleForDiag, "缺页 → working set 不齐备")

        // 第 2 轮(revision 已稳定, 不再提升): 旧键 revision 不匹配 → 全部
        // 重新构建并插入, working set 齐备。
        grid.refresh()
        await waitPrepared(grid)
        #expect(grid.pageVisualCacheCountForDiag == 3)
        #expect(grid.pageVisualKeysForDiag.map(\.pageIndex).sorted() == [0, 1, 2])
        #expect(grid.pageCompositorEligibleForDiag)
    }

    // MARK: - live 降级空白页回归(v0.5.x 类 bug)

    @Test("live 降级(不可合成)快速甩页 settle 后强制物化目标页 cell")
    func liveFallbackSettleMaterializesTargetCells() async throws {
        let store = CompositorIntegrationStore()
        let grid = GridViewController(
            store: store, iconProvider: CompositorIntegrationIconProvider()
        )
        // 保持默认密度门(20 项/页)而测试页仅 3 项 → compositor 永不激活,
        // 分页走 live clip 路径。这正是用户复现“滑几次后只有壁纸背景”的路径。
        grid.pageVisualCompositorEnabled = true
        grid.enableDeterministicPagingProbeClock()
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        #expect(!grid.pageCompositorEligibleForDiag, "稀疏页不可合成(live 路径)")

        grid.pagingProbeGesture(deltaXs: [-180, -240, -120])
        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(grid.currentPageValue == 2)
        #expect(
            grid.liveSettleLayoutSyncCountForDiag >= 1,
            "live settle 收尾执行强制同步布局"
        )
        #expect(
            grid.visibleItemsCountForDiag > 0,
            "落地时目标页 cell 已物化(不是空白壁纸)"
        )
    }

    // MARK: - T-001: 方向感知两页合成

    @Test("T-001: 首页 idle → prepare [0,1]")
    func firstPagePreparesTwoPages() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        #expect(grid.currentPageValue == 0)
        await waitPrepared(grid, count: 2)
        #expect(grid.pageVisualCacheCountForDiag == 2, "首页 prepare [0,1]")
        #expect(grid.pageVisualKeysForDiag.map(\.pageIndex).sorted() == [0, 1])
        #expect(grid.pageCompositorEligibleForDiag, "首页可向 next 合成")
    }

    @Test("T-011: 单次真实手势事件顺序: direction → compositor → first offset")
    func unifiedPagingEventSequence() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        await waitPrepared(grid, count: 2)
        #expect(grid.pageCompositorEligibleForDiag)
        grid.applyPagingDiagnosticsConfiguration(
            PagingDiagnosticsConfiguration(arguments: ["--pagecompositor"])
        )

        // Record the callbacks and first routed offset write from one real
        // GridViewController → PagingInteractionController gesture.
        grid.beginPagingEventSequenceForDiag()
        grid.pagingProbeGesture(deltaXs: [-180, -240, -120])
        _ = grid.pagingProbeDisplayFrame()

        let sequence = grid.pagingEventSequenceForDiag
        #expect(
            sequence == ["directionCallback", "compositorDecision", "firstOffsetWrite"],
            "one gesture must emit exactly the semantic markers"
        )
        let direction = sequence.firstIndex(of: "directionCallback")
        let decision = sequence.firstIndex(of: "compositorDecision")
        let firstWrite = sequence.firstIndex(of: "firstOffsetWrite")
        #expect(direction != nil && decision != nil && firstWrite != nil)
        if let direction, let decision, let firstWrite {
            #expect(direction < decision, "direction callback precedes compositor decision")
            #expect(decision < firstWrite, "compositor decision precedes first offset write")
        }
        #expect(grid.pageCompositorActiveForDiag, "the real gesture activated the compositor")
        #expect(
            grid.pageCompositorEventsForDiag.contains { event in
                if case .activated = event { return true }
                return false
            },
            "compositor diagnostics record the activation decision"
        )
    }

    @Test("T-001: 首页 → 次页: 激活两页 compositor")
    func firstPageToSecondActivatesTwoPageCompositor() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        await waitPrepared(grid, count: 2)
        #expect(grid.pageCompositorEligibleForDiag)

        // 首页左滑 → 次页。
        grid.pagingProbeGesture(deltaXs: [-180, -240, -120])
        #expect(grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorPageIndicesForDiag == [0, 1], "两页合成 [0,1]")
        #expect(grid.pageCompositorLayerFramesForDiag.count == 2)
        #expect(grid.pageCompositorLiveOpacityForDiag == 0, "live 前景隐藏")

        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(!grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorLiveOpacityForDiag == 1)
        #expect(grid.pageCompositorLayerFramesForDiag.isEmpty, "无残留层")
        #expect(grid.clipOffsetXForDiag == grid.geometry.pageWidth, "clip 同步到次页")
        #expect(grid.currentPageValue == 1)
    }

    @Test("T-001: 首页 → App Library(leading): live 降级")
    func firstPageToLibraryFallsBack() async throws {
        let store = CompositorLeadingStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        #expect(grid.currentSurfaceValue == .layoutPage(0))
        await waitPrepared(grid, count: 2)

        // 首页右滑(previous)→ App Library → live 降级, 不激活 compositor。
        grid.pagingProbeGesture(deltaXs: [180, 240, 120])
        #expect(!grid.pageCompositorActiveForDiag, "previous → Library 不合成")
        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(grid.currentSurfaceValue == .appLibrary, "落到 Library")
    }

    @Test("T-001: 末页 → 上一页: 激活两页 compositor")
    func lastPageToPreviousActivatesTwoPageCompositor() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(3, animated: false)
        #expect(grid.currentPageValue == 3)
        await waitPrepared(grid, count: 2)
        #expect(grid.pageVisualKeysForDiag.map(\.pageIndex).sorted() == [2, 3], "末页 prepare [2,3]")
        #expect(grid.pageCompositorEligibleForDiag)

        // 末页右滑(previous)→ 上一页。
        grid.pagingProbeGesture(deltaXs: [180, 240, 120])
        #expect(grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorPageIndicesForDiag == [3, 2], "两页合成 [current, target]")

        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(!grid.pageCompositorActiveForDiag)
        #expect(grid.clipOffsetXForDiag == grid.geometry.pageWidth * 2, "clip 同步到上一页")
        #expect(grid.currentPageValue == 2)
    }

    @Test("T-001: 末页 → 越界(next): 稳定 live 降级")
    func lastPageToOutOfBoundsFallsBack() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(3, animated: false)
        await waitPrepared(grid, count: 2)

        // 末页左滑(next)→ 越界 → live 降级, 不激活 compositor。
        grid.pagingProbeGesture(deltaXs: [-180, -240, -120])
        #expect(!grid.pageCompositorActiveForDiag, "next 越界不合成")
        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(grid.currentPageValue == 3, "停在末页")
    }

    @Test("T-010 C: App Library boundary interruption falls back live without invalid visuals")
    func appLibraryBoundaryInterruptionUsesLiveFallback() async throws {
        // App Library boundary: the active paging settle is live by design
        // because the compositor excludes the leading surface. Interrupt it
        // again at the same boundary and prove no visual for a negative page.
        let store = CompositorLeadingStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        let cacheKeysBefore = grid.pageVisualKeysForDiag
        grid.pagingProbeGesture(deltaXs: [180, 240, 120])
        #expect(grid.pagingProbePhase() == "settling")
        #expect(!grid.pageCompositorActiveForDiag)
        for _ in 0..<10 { _ = grid.pagingProbeDisplayFrame() }
        grid.pagingProbeGesture(deltaXs: [180, 240, 120])
        #expect(!grid.pageCompositorActiveForDiag, "App Library target must use live fallback")
        #expect(
            grid.pageCompositorLiveOpacityForDiag == nil || grid.pageCompositorLiveOpacityForDiag == 1,
            "Library live path must not hide live content"
        )
        #expect(grid.visibleItemsCountForDiag > 0, "Library live fallback content nonempty")
        #expect(grid.pageVisualKeysForDiag == cacheKeysBefore, "boundary fallback must not build missing visual")

        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(grid.currentSurfaceValue == .appLibrary)
        #expect(grid.currentPageValue == 0)
        #expect(grid.clipOffsetXForDiag == 0)
        #expect(grid.pageCompositorLayerFramesForDiag.isEmpty)
        #expect(grid.visibleItemsCountForDiag > 0)
        #expect(grid.pageVisualKeysForDiag.allSatisfy { $0.pageIndex >= 0 && $0.pageIndex < 4 })
    }

    // MARK: - T-013 A: 末页真实 active-settle interruption

    /// T-013 A: 真实 Page 2 → Page 3 compositor settle 中途向 Page 4 越界方向
    /// 第二次手势 → 立即 live fallback → 最终精确落 Page 3。
    ///
    /// 修复原 `boundaryInterruptionsUseLiveFallback` 末页部分证据缺口(从 Page 3
    /// 启动、clamp 回 Page 3、velocity 可能为 0、首个 deterministic frame 即完成
    /// settle): 本测试从 Page 2 启动真实手势、推进到确定性的 mid-settle 区间
    /// (2.1w, 2.95w)、在 compositor 仍 active 时发起第二次真实 next 手势。
    @Test("T-013 A: 末页 Page2→Page3 active settle 中途向 Page4 越界中断 → live fallback → Page3")
    func lastPageActiveSettleInterruptionUsesLiveFallback() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(2, animated: false)
        let pageWidth = grid.geometry.pageWidth
        #expect(grid.currentPageValue == 2, "A1: 起点必须为 Page 2")
        await waitPrepared(grid, count: 2)
        // A1: Page 2/3 visual 已准备, cache 只含合法页, 不存在 Page 4 key。
        #expect(
            grid.pageVisualKeysForDiag.map(\.pageIndex).sorted() == [1, 2, 3],
            "A1: Page 2 working set [1,2,3] 已准备"
        )
        #expect(
            grid.pageVisualKeysForDiag.allSatisfy { $0.pageIndex >= 0 && $0.pageIndex < 4 },
            "A1: cache 只含合法页"
        )
        #expect(
            !grid.pageVisualKeysForDiag.contains { $0.pageIndex == 4 },
            "A1: 不存在 Page 4 key"
        )

        // 遥测/诊断开启(测试专用; 产品默认路径零开销, 行为不变)。
        grid.applyPagingDiagnosticsConfiguration(
            PagingDiagnosticsConfiguration(arguments: ["--pagecompositor", "--pagingfeeltelemetry"])
        )
        var summaries: [String] = []
        grid.pageCompositorActivationTelemetry.onSummary = { summaries.append($0) }

        // A2: 真实 Page 2 → Page 3 next 手势(非零位移), 激活 compositor。
        grid.pagingProbeGesture(deltaXs: [-180, -240, -120])
        #expect(grid.pagingProbePhase() == "settling", "A2: 手势结束立即 settling")
        #expect(grid.pageCompositorActiveForDiag, "A2: compositor active")
        #expect(grid.pageCompositorPageIndicesForDiag == [2, 3], "A2: active pages == [2, 3]")
        #expect(grid.pageCompositorCurrentOffsetForDiag == pageWidth * 2, "A2: 零跳变激活")
        #expect(grid.pageCompositorLiveOpacityForDiag == 0, "A2: live 被 compositor 遮盖")
        #expect(pagingControllerForDiag(grid).settleTargetPageForTest == 3, "A2: settle target == Page 3")
        #expect(
            !grid.pageVisualKeysForDiag.contains { $0.pageIndex == 4 },
            "A2: 无 Page 4 visual"
        )

        // A3: 确定性推进到 mid-settle(上限 1...60 帧): offset ∈ (2w+0.1w, 3w-0.05w)。
        var midSettleFrame = 0
        var midOffset: CGFloat = -1
        for frame in 1...60 {
            _ = grid.pagingProbeDisplayFrame()
            let offset = grid.pageCompositorCurrentOffsetForDiag
            if grid.pagingProbePhase() == "settling",
               grid.pageCompositorActiveForDiag,
               offset > pageWidth * 2 + pageWidth * 0.1,
               offset < pageWidth * 3 - pageWidth * 0.05 {
                midSettleFrame = frame
                midOffset = offset
                break
            }
        }
        #expect(midSettleFrame > 0, "A3: mid-settle 未达即 idle ⇒ 前置状态失败, 不能把 idle 后的手势当 interruption")
        #expect(grid.pagingProbePhase() == "settling", "A3: 第二次手势前 phase == settling")
        #expect(grid.pageCompositorActiveForDiag, "A3: 第二次手势前 compositor active")
        #expect(midOffset > pageWidth * 2 + pageWidth * 0.1, "A3: offset 下界余量 0.1w")
        #expect(midOffset < pageWidth * 3 - pageWidth * 0.05, "A3: offset 上界余量 0.05w")
        #expect(grid.pageCompositorPageIndicesForDiag == [2, 3], "A3: active pages 保持 [2, 3]")

        // A3 快照(中断前): compositor offset / clip / layer 身份 / 事件计数 / cache / live。
        let compositorOffsetBeforeInterruption = grid.pageCompositorCurrentOffsetForDiag
        let clipOffsetBeforeInterruption = grid.clipOffsetXForDiag
        let activeLayerIdentifiersBefore = grid.pageCompositor.layerObjectIdentifiersForDiag
        let eventsBefore = grid.pageCompositorEventsForDiag
        func countEvent(_ events: [PageCompositor.Event], kind: (PageCompositor.Event) -> Bool) -> Int {
            events.reduce(into: 0) { count, event in
                if kind(event) { count += 1 }
            }
        }
        let abortsBefore = countEvent(eventsBefore) { if case .aborted = $0 { return true }; return false }
        let finishesBefore = countEvent(eventsBefore) { if case .finishedSettle = $0 { return true }; return false }
        let shutdownsBefore = countEvent(eventsBefore) { if case .shutdown = $0 { return true }; return false }
        let cacheKeysBefore = grid.pageVisualKeysForDiag
        let cacheVisualCountBefore = grid.pageVisualCacheCountForDiag
        let visibleItemsBefore = grid.visibleItemsCountForDiag
        #expect(!activeLayerIdentifiersBefore.isEmpty, "A3: 中断前存在 active layers")
        #expect(visibleItemsBefore > 0, "A3: live content 非空")
        #expect(
            clipOffsetBeforeInterruption <= compositorOffsetBeforeInterruption,
            "A3: 中断前 clip 在 compositor offset 之后(被遮盖推进)"
        )

        // A4: 第二次真实 next 手势, 语义指向 Page 4(越界)。净位移非零,
        // 不以 Page 2 结束; controller 侧最终 settle target 经 clamp 回到 Page 3。
        grid.pagingProbeGesture(deltaXs: [-180, -240, -120])
        #expect(
            pagingControllerForDiag(grid).settleTargetPageForTest == 3,
            "A4: controller 最终 settle target clamp 回 Page 3"
        )

        // A5: 中断瞬间 —— live fallback 立即生效。
        #expect(!grid.pageCompositorActiveForDiag, "A5: 越界目标 → compositor 立即退出")
        #expect(grid.pageCompositorLayerFramesForDiag.isEmpty, "A5: layer 已安全退出")
        #expect(grid.pageCompositorLiveOpacityForDiag == 1, "A5: live 已 reveal")
        #expect(
            abs(grid.clipOffsetXForDiag - compositorOffsetBeforeInterruption) < 0.001,
            "A5: clip 与 abort 前 compositor offset 连续"
        )
        #expect(grid.visibleItemsCountForDiag > 0, "A5: live content 非空")
        #expect(grid.pageVisualCacheCountForDiag == cacheVisualCountBefore, "A5: cache visual count 不增")
        #expect(
            grid.pageVisualKeysForDiag.map(\.pageIndex).sorted() == cacheKeysBefore.map(\.pageIndex).sorted(),
            "A5: cache key 集合不增"
        )
        #expect(
            !grid.pageVisualKeysForDiag.contains { $0.pageIndex == 4 },
            "A5: 无 pageIndex == 4"
        )
        #expect(
            grid.pageVisualKeysForDiag.allSatisfy { $0.pageIndex >= 0 && $0.pageIndex < 4 },
            "A5: 所有 page key 合法"
        )
        let eventsAfterAbort = grid.pageCompositorEventsForDiag
        #expect(
            countEvent(eventsAfterAbort) { if case .aborted = $0 { return true }; return false } == abortsBefore + 1,
            "A5: abort event 恰好增加一次"
        )
        #expect(
            countEvent(eventsAfterAbort) { if case .finishedSettle = $0 { return true }; return false } == finishesBefore,
            "A5: finishedSettle 不得冒充 interruption abort"
        )
        #expect(
            countEvent(eventsAfterAbort) { if case .shutdown = $0 { return true }; return false } == shutdownsBefore,
            "A5: shutdown 不得冒充 interruption abort"
        )
        #expect(grid.pagingProbePhase() == "settling", "A5: 第二次手势后仍 settling(live settle)")

        // A6: 最终落点 —— 真实 settle 收敛到 Page 3。
        let settled = await driveUntilIdle(grid)
        #expect(settled, "A6: 最终 settle 必须收敛")
        #expect(grid.currentPageValue == 3, "A6: 最终 Page 3")
        #expect(grid.clipOffsetXForDiag == pageWidth * 3, "A6: clip 精确对齐 3w")
        #expect(grid.pagingProbePhase() == "idle", "A6: phase == idle")
        #expect(!grid.pageCompositorActiveForDiag, "A6: compositor inactive")
        #expect(grid.pageCompositorLayerFramesForDiag.isEmpty, "A6: compositor layers 空")
        #expect(grid.pageCompositorLiveOpacityForDiag == 1, "A6: 无残留隐藏 live layer")
        #expect(grid.visibleItemsCountForDiag > 0, "A6: live content 非空")
        #expect(
            !grid.pageVisualKeysForDiag.contains { $0.pageIndex == 4 },
            "A6: 无 Page 4 visual/cache key"
        )
        #expect(
            grid.pageVisualKeysForDiag.allSatisfy { $0.pageIndex >= 0 && $0.pageIndex < 4 },
            "A6: 无非法 page key"
        )
        #expect(!pagingControllerForDiag(grid).isDisplayLinkActive, "A6: 无残留 active animator/display link")
        let finalEvents = grid.pageCompositorEventsForDiag
        #expect(
            countEvent(finalEvents) { if case .aborted = $0 { return true }; return false } == abortsBefore + 1,
            "A6: 无额外 abort"
        )
        #expect(
            countEvent(finalEvents) { if case .finishedSettle = $0 { return true }; return false } == finishesBefore,
            "A6: 最终 settle 为 live settle(无新 compositor finishedSettle), 只发生预期 interruption teardown"
        )
        #expect(
            countEvent(finalEvents) { if case .shutdown = $0 { return true }; return false } == shutdownsBefore,
            "A6: 无额外 shutdown"
        )

        // A5: 遥测断言 activation result == .interruptionFallbackLive(对应 fallback result)。
        for _ in 0..<200 where summaries.count < 2 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(summaries.count == 2, "两个 telemetry session 各交付一次")
        #expect(summaries[0].contains("completionReason=interrupted"), "第一 session 被第二次手势 interrupted")
        #expect(summaries[1].contains("activationResult=interruptionFallbackLive"), "A5: 中断为 live fallback 决策")
        #expect(summaries[1].contains("completionReason=settled"), "最终 settle settled")
    }

    @Test("T-001: 中间页 → 仍用三页缓存")
    func middlePageUsesThreePageCache() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        await waitPrepared(grid)
        #expect(grid.pageVisualCacheCountForDiag == 3, "中间页 prepare [0,1,2]")
        #expect(grid.pageVisualKeysForDiag.map(\.pageIndex).sorted() == [0, 1, 2])
    }

    @Test("T-001: live settle 中途 clip 不在页边界 → 不激活新 compositor")
    func liveSettleMidFlightDoesNotActivateNewCompositor() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        let pageWidth = grid.geometry.pageWidth
        await waitPrepared(grid)

        // 第一次手势激活 compositor, settle 进行中。
        grid.pagingProbeGesture(deltaXs: [-200, -200])
        #expect(grid.pageCompositorActiveForDiag)

        // 驱动若干 settle 帧, 让合成器偏移离开页边界(向目标页收敛)。
        for _ in 0..<10 {
            _ = grid.pagingProbeDisplayFrame()
        }
        let midCompositor = grid.pageCompositorCurrentOffsetForDiag
        #expect(midCompositor > pageWidth && midCompositor < pageWidth * 2, "合成器偏移已离开页边界")

        // 直接 shutdown(不经 refresh, 避免 applyDisplayModel 的 jumpTo 复位 clip):
        // clip 同步到当前 visual offset(页中间), compositor 关闭, settle 仍在途。
        grid.shutdownPageCompositor()
        #expect(!grid.pageCompositorActiveForDiag)
        let midClip = grid.clipOffsetXForDiag
        #expect(midClip > pageWidth && midClip < pageWidth * 2, "clip 停在页中间")

        // 新手势: 方向回调触发, 但 clip 不在页边界 → 不激活新 compositor(live 降级)。
        grid.pagingProbeGesture(deltaXs: [-100, -100])
        #expect(!grid.pageCompositorActiveForDiag, "clip 不在页边界 → 不激活新 compositor")

        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(!grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorLayerFramesForDiag.isEmpty)
    }

    // MARK: - T-005: 非零 gridOrigin 下合成层坐标(P0)

    /// 断言两矩形坐标在容差内一致(验证真实坐标, 而非仅层数/页码)。
    private func assertRect(
        _ actual: CGRect, _ expected: CGRect, tolerance: CGFloat = 0.5
    ) {
        #expect(
            abs(actual.minX - expected.minX) <= tolerance,
            "minX \(actual.minX) vs 期望 \(expected.minX)"
        )
        #expect(
            abs(actual.minY - expected.minY) <= tolerance,
            "minY \(actual.minY) vs 期望 \(expected.minY)"
        )
        #expect(
            abs(actual.width - expected.width) <= tolerance,
            "width \(actual.width) vs 期望 \(expected.width)"
        )
        #expect(
            abs(actual.height - expected.height) <= tolerance,
            "height \(actual.height) vs 期望 \(expected.height)"
        )
    }

    /// 对一个激活的两页合成, 验证每层 frame 坐标对齐真实网格内容区
    /// (Cell 所在 document rect), 覆盖 页0→页1 / 中间页 / 末页。
    private func assertLayerFramesAlignWithRealGridContent(
        _ grid: GridViewController, leadingDocumentOffset: CGFloat = 0,
        tolerance: CGFloat = 0.5
    ) {
        let g = grid.geometry
        #expect(g.gridOrigin != .zero, "前置: gridOrigin 必须非零才能证明补上 gridOrigin")

        let frames = grid.pageCompositorLayerFramesForDiag
        let pages = grid.pageCompositorPageIndicesForDiag
        #expect(frames.count == pages.count, "层与页索引一一对齐")
        #expect(frames.count == 2, "两页合成")

        for (index, page) in pages.enumerated() {
            let actual = frames[index]

            // 独立期望: 渲染像素覆盖的 document rect = 网格内容区
            // (leadingDocumentOffset + pageIndex*pageWidth + gridOrigin,
            //  size = logicalBounds.size = gridSize)。
            let logicalBounds = CGRect(
                origin: .zero,
                size: CGSize(width: g.gridWidth, height: g.gridHeight)
            )
            let docRect = CGRect(
                x: leadingDocumentOffset
                    + CGFloat(page) * g.pageWidth
                    + g.gridOrigin.x
                    + logicalBounds.minX,
                y: g.gridOrigin.y + logicalBounds.minY,
                width: logicalBounds.width,
                height: logicalBounds.height
            )
            let expected = grid.collectionViewRef.convert(docRect, to: grid.view)
            assertRect(actual, expected, tolerance: tolerance)
        }
    }

    @Test("T-005: 非零 gridOrigin — 页0→页1 / 中间页 / 末页 层坐标对齐真实网格")
    func compositorLayerFramesAlignWithRealGridContentAcrossPages() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        let g = grid.geometry
        #expect(g.gridOrigin != .zero, "测试窗口几何产生非零 gridOrigin")
        #expect(!(store is any AppLibraryDataProviding), "非 leading: leadingDocumentOffset == 0")

        // 覆盖任务要求的三个场景: 起始页 / 中间页 / 末页。
        let scenarios: [(current: Int, target: Int)] = [
            (0, 1),   // Page 0 → Page 1(起始页, 两页 working set)
            (1, 2),   // 中间页
            (2, 3),   // 中间 → 末页
        ]

        for scenario in scenarios {
            grid.goToPage(scenario.current, animated: false)
            if scenario.current == 0 {
                await waitPrepared(grid, count: 2)
            } else {
                await waitPrepared(grid)
            }
            #expect(grid.pageCompositorEligibleForDiag)

            // 前向翻页 → 左滑(负 dx)。
            grid.pagingProbeGesture(deltaXs: [-180, -240, -120])
            #expect(grid.pageCompositorActiveForDiag, "\(scenario.current)→\(scenario.target) 已激活")
            #expect(
                grid.pageCompositorPageIndicesForDiag == [scenario.current, scenario.target],
                "方向感知两页 [current, target]"
            )

            assertLayerFramesAlignWithRealGridContent(grid)

            let settled = await driveUntilIdle(grid)
            #expect(settled)
            #expect(!grid.pageCompositorActiveForDiag, "settle 收口释放")
            #expect(grid.pageCompositorLayerFramesForDiag.isEmpty)
        }
    }

    @Test("T-005: leading surface — document offset 只加一次")
    func compositorLayerFramesIncludeLeadingDocumentOffsetOnce() async throws {
        let store = CompositorLeadingStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        await waitPrepared(grid, count: 2)
        #expect(grid.pageCompositorEligibleForDiag)

        grid.pagingProbeGesture(deltaXs: [-180, -240, -120])
        #expect(grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorPageIndicesForDiag == [0, 1])
        assertLayerFramesAlignWithRealGridContent(
            grid, leadingDocumentOffset: grid.geometry.pageWidth
        )

        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(!grid.pageCompositorActiveForDiag)
    }

    @Test("flag combinations produce only their enabled diagnostic behavior")
    func pagingDiagnosticFlagsAreIndependent() async {
        let cases: [([String], Bool, Bool)] = [
            (["--pagecompositor"], true, false),
            (["--pagingfeeltelemetry"], false, true),
            (["--pagecompositor", "--pagingfeeltelemetry"], true, true),
        ]

        for (arguments, compositorEnabled, feelTelemetryEnabled) in cases {
            let grid = GridViewController(store: CompositorIntegrationStore(), iconProvider: nil)
            grid.applyPagingDiagnosticsConfiguration(
                PagingDiagnosticsConfiguration(arguments: arguments)
            )

            // Drive the real compositor object, rather than inspecting its switches.
            let host = CALayer()
            let live = CALayer()
            grid.pageCompositor.activate(
                placements: [makeDiagnosticPlacement(page: 0), makeDiagnosticPlacement(page: 1)],
                pageWidth: 640,
                startOffset: 0,
                hostLayer: host,
                liveLayer: live
            )
            grid.pageCompositor.applyOffset(160)

            if compositorEnabled {
                #expect(grid.pageCompositor.metrics.compositorFrames == 1)
                #expect(grid.pageCompositor.eventsForDiag.contains(.activated(offset: 0)))
                #expect(grid.pageCompositor.eventsForDiag.contains(.applied(offset: 160)))
            } else {
                #expect(grid.pageCompositor.metrics.compositorFrames == 0)
                #expect(grid.pageCompositor.eventsForDiag.isEmpty)
            }

            let telemetry = grid.pageCompositorActivationTelemetry
            if feelTelemetryEnabled {
                // Two callbacks form one real display-link interval, then a real
                // activation result is flushed through the async formatter.
                telemetry.recordDisplayLinkInterval()
                telemetry.recordDisplayLinkInterval()
                #expect(telemetry.displayLinkIntervalCountForDiag == 1)
                let summary = await withCheckedContinuation { continuation in
                    telemetry.onSummary = { continuation.resume(returning: $0) }
                    telemetry.beginGesture(startPage: 0, direction: .next)
                    telemetry.recordActivationResult(.activated)
                    _ = telemetry.flushGesture()
                }
                #expect(summary.contains("activationResult=activated"))
                #expect(summary.contains("gestureIndex=0"))
            } else {
                telemetry.beginGesture(startPage: 0, direction: .next)
                #expect(telemetry.flushGesture() == nil)
                #expect(telemetry.displayLinkIntervalCountForDiag == 0)
            }
        }
    }

    @Test("probe counter reset keeps interrupted and replacement sessions isolated")
    func probeCounterResetKeepsSessionsIsolated() async throws {
        let grid = makeGrid(CompositorIntegrationStore())
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }
        grid.applyPagingDiagnosticsConfiguration(
            PagingDiagnosticsConfiguration(arguments: ["--pagingfeeltelemetry"])
        )

        grid.refresh()
        grid.goToPage(1, animated: false)
        await waitPrepared(grid)

        var summaries: [String] = []
        grid.pageCompositorActivationTelemetry.onSummary = { summaries.append($0) }

        // Leave the first probe settle active with observable frame/write work.
        grid.pagingProbeGesture(deltaXs: [-180, -240, -120])
        for _ in 0..<12 { _ = grid.pagingProbeDisplayFrame() }
        #expect(grid.pagingProbePhase() == "settling")

        // Starting a second probe resets diagnostic fields while the first
        // telemetry session is still open. Both sessions must retain their own
        // baseline diff rather than observing a reset counter.
        grid.pagingProbeGesture(deltaXs: [180, 240, 120])
        _ = grid.pagingProbeDisplayFrame()
        grid.pagingProbeShutdown()
        for _ in 0..<200 where summaries.count < 2 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(summaries.count == 2)
        let counts = summaries.map { summary -> (frames: Int, writes: Int) in
            func value(named name: String) -> Int {
                let prefix = name + "="
                let field = summary.split(separator: " ").first { $0.hasPrefix(prefix) } ?? ""
                return Int(field.dropFirst(prefix.count)) ?? -1
            }
            return (value(named: "displayFrameCount"), value(named: "scrollWriteCount"))
        }
        #expect(counts.allSatisfy { $0.frames >= 0 && $0.writes >= 0 })
        #expect(counts[0].frames > counts[1].frames, "replacement must not inherit old probe frames")
        #expect(counts[0].writes > counts[1].writes, "replacement must not inherit old scroll writes")
        #expect(summaries[0].contains("completionReason=interrupted"))
        #expect(summaries[1].contains("completionReason=cancelled"))
    }

    @Test("active horizontal tracking teardown flushes cancelled telemetry")
    func activeTrackingTeardownReportsCancelled() async throws {
        let actions: [(String, (GridViewController) -> Void)] = [
            ("shutdown", { $0.pagingProbeShutdown() }),
            ("disable", { $0.pagingProbeDisable() }),
            ("jump", { $0.pagingProbeJumpTo(page: 1) }),
            ("cancelled NSEvent", { grid in
                grid.pagingProbeFeed(makeScroll(dx: 0, phase: .cancelled)!)
            }),
        ]

        for (label, action) in actions {
            let grid = makeGrid(CompositorIntegrationStore())
            let window = makeWindow(for: grid)
            defer { window.orderOut(nil); window.contentView = nil }
            grid.applyPagingDiagnosticsConfiguration(
                PagingDiagnosticsConfiguration(arguments: ["--pagingfeeltelemetry"])
            )

            grid.refresh()
            grid.goToPage(1, animated: false)
            await waitPrepared(grid)

            // Feed real precise NSEvents and leave the controller in tracking.
            grid.pagingProbeFeed(makeScroll(dx: -80, phase: .began)!)
            grid.pagingProbeFeed(makeScroll(dx: -160, phase: .changed)!)
            #expect(grid.pagingProbePhase() == "tracking", "\(label) starts from active tracking")

            let telemetry = grid.pageCompositorActivationTelemetry
            #expect(telemetry.enabled, "\(label) telemetry must be enabled")
            #expect(telemetry.gestureInProgressForDiag, "\(label) must have an active telemetry session")
            var summaries: [String] = []
            telemetry.onSummary = { value in summaries.append(value) }
            action(grid)
            for _ in 0..<200 where summaries.isEmpty {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(10))
            }
            let summary = summaries.first

            #expect(summary?.contains("completionReason=cancelled") == true, "\(label) must cancel telemetry")
            #expect(summary?.contains("settleDurationMs=nil") == true, "\(label) must not reuse settle duration")
            #expect(summaries.count == 1, "\(label) must flush telemetry once")
        }
    }

    // MARK: - T-013 B: telemetry 生命周期集成

    /// T-013 B1: startSettle replacement 的 Grid 端到端 telemetry session 隔离。
    ///
    /// 第一个真实手势的 telemetry session 在 settling 中被第二次真实手势(现有
    /// 合法产品入口)替换: 旧 session 必须 completionReason == interrupted、duration
    /// 为当前 session 的实际 elapsed(非 stale 值)、frame/write 计数只含自身工作、
    /// 只交付一次; 新 session 必须独立 baseline、不继承旧 session 计数、最终按真实
    /// 结果 settled、只交付一次; 交付顺序按 session 顺序。
    @Test("T-013 B1: startSettle replacement keeps telemetry sessions isolated end-to-end")
    func startSettleReplacementKeepsTelemetrySessionsIsolated() async throws {
        let grid = makeGrid(CompositorIntegrationStore())
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }
        grid.applyPagingDiagnosticsConfiguration(
            PagingDiagnosticsConfiguration(arguments: ["--pagecompositor", "--pagingfeeltelemetry"])
        )

        grid.refresh()
        grid.goToPage(1, animated: false)
        let pageWidth = grid.geometry.pageWidth
        await waitPrepared(grid)

        var summaries: [String] = []
        grid.pageCompositorActivationTelemetry.onSummary = { summaries.append($0) }

        // 第一 telemetry session: 真实手势 → Page 2 settle, compositor active。
        grid.pagingProbeGesture(deltaXs: [-180, -240, -120])
        #expect(grid.pagingProbePhase() == "settling")
        #expect(grid.pageCompositorActiveForDiag)

        // 确定性推进 24 帧(120Hz → elapsed 200ms)到可观察 mid-settle。
        for _ in 0..<24 { _ = grid.pagingProbeDisplayFrame() }
        let midOffset = grid.pageCompositorCurrentOffsetForDiag
        #expect(midOffset > pageWidth && midOffset < pageWidth * 2, "settle 已推进到中途")
        #expect(grid.pagingProbePhase() == "settling", "replacement 前仍在 settling")

        // 经现有合法入口(第二次真实手势)在 settling 中替换 settle target。
        grid.pagingProbeGesture(deltaXs: [-180, -240, -120])
        #expect(
            pagingControllerForDiag(grid).settleTargetPageForTest == 3,
            "replacement settle target == Page 3(经 clamp)"
        )
        #expect(grid.pagingProbePhase() == "settling", "replacement 后继续 settling")

        // 驱动 replacement settle 到 idle, 记录帧数。
        var framesAfterReplacement = 0
        while grid.pagingProbePhase() != "idle", framesAfterReplacement < 600 {
            _ = grid.pagingProbeDisplayFrame()
            framesAfterReplacement += 1
        }
        #expect(grid.pagingProbePhase() == "idle", "replacement settle 必须收敛")
        #expect(framesAfterReplacement > 0)

        // 等待两个 summary 交付。
        for _ in 0..<300 where summaries.count < 2 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(summaries.count == 2, "每个 session 只交付一次")

        func value(named name: String, in summary: String) -> Int {
            let prefix = name + "="
            let field = summary.split(separator: " ").first { $0.hasPrefix(prefix) } ?? ""
            return Int(field.dropFirst(prefix.count)) ?? -1
        }
        func duration(named name: String, in summary: String) -> Double {
            let prefix = name + "="
            let field = summary.split(separator: " ").first { $0.hasPrefix(prefix) } ?? ""
            return Double(field.dropFirst(prefix.count)) ?? -1
        }

        // 旧 session: interrupted、duration == 当前 session elapsed(24 帧 × 1/120 = 200ms,
        // 非 stale 旧值)、frame/write 只含自己 24 帧工作、不含新 session 工作。
        #expect(summaries[0].contains("gestureIndex=0"), "FIFO: 先交付 session 0")
        #expect(summaries[0].contains("completionReason=interrupted"), "旧 session 必须 interrupted")
        let oldDuration = duration(named: "settleDurationMs", in: summaries[0])
        #expect(abs(oldDuration - 200.0) < 1.0, "旧 session duration == 当前 elapsed(非旧值), 实际 \(oldDuration)")
        #expect(value(named: "displayFrameCount", in: summaries[0]) == 24, "旧 session frame 只含自身 24 帧")
        #expect(value(named: "scrollWriteCount", in: summaries[0]) == 24, "旧 session write 只含自身 24 帧")

        // 新 session: 独立 baseline、不继承旧 session 计数、最终 settled、只交付一次。
        #expect(summaries[1].contains("gestureIndex=1"), "FIFO: 后交付 session 1")
        #expect(summaries[1].contains("completionReason=settled"), "新 session 最终 settled")
        #expect(
            summaries[1].contains("activationResult=interruptionFallbackLive"),
            "replacement 手势走真实 live fallback 决策"
        )
        #expect(
            value(named: "displayFrameCount", in: summaries[1]) == framesAfterReplacement,
            "新 session 计数不含旧 session 工作(独立 baseline)"
        )
        let newWrites = value(named: "scrollWriteCount", in: summaries[1])
        #expect(newWrites >= 0 && newWrites <= framesAfterReplacement, "新 session write 非负且不超帧数")
        let newDuration = duration(named: "settleDurationMs", in: summaries[1])
        #expect(newDuration > 0, "新 session 有真实 settle duration")

        // 等待额外时间确认无第三次/重复交付。
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(summaries.count == 2, "无重复/额外 summary")
    }

    /// T-013 B2: settling 状态收到真实 precise NSEvent.phase == .cancelled 时,
    /// telemetry 只 flush 一次 cancelled summary(settleDurationMs 显式 nil, 无 stale
    /// 值), animator/display link 停止、compositor/live 正确收口、clip offset 连续,
    /// 后续 onPhaseIdle 不重复 flush。
    @Test("T-013 B2: settling 状态 cancelled NSEvent 只 flush 一次 cancelled summary")
    func settlingCancelledEventFlushesOnce() async throws {
        let grid = makeGrid(CompositorIntegrationStore())
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }
        grid.applyPagingDiagnosticsConfiguration(
            PagingDiagnosticsConfiguration(arguments: ["--pagecompositor", "--pagingfeeltelemetry"])
        )

        grid.refresh()
        grid.goToPage(1, animated: false)
        let pageWidth = grid.geometry.pageWidth
        await waitPrepared(grid)

        var summaries: [String] = []
        grid.pageCompositorActivationTelemetry.onSummary = { summaries.append($0) }

        // 真实 horizontal 手势 → 进入 settle(compositor active)。
        grid.pagingProbeFeed(makeScroll(dx: -80, phase: .began)!)
        grid.pagingProbeFeed(makeScroll(dx: -160, phase: .changed)!)
        _ = grid.pagingProbeDisplayFrame()
        grid.pagingProbeFeed(makeScroll(dx: -160, phase: .changed)!)
        _ = grid.pagingProbeDisplayFrame()
        grid.pagingProbeFeed(makeScroll(dx: 0, phase: .ended)!)
        #expect(grid.pagingProbePhase() == "settling", "手势结束后必须 settling")
        #expect(grid.pageCompositorActiveForDiag, "settle 期间 compositor active")

        // 推进到 mid-settle。
        for _ in 0..<10 { _ = grid.pagingProbeDisplayFrame() }
        #expect(grid.pagingProbePhase() == "settling", "cancel 前仍在 settling")
        let compositorOffsetAtCancel = grid.pageCompositorCurrentOffsetForDiag
        #expect(
            compositorOffsetAtCancel > pageWidth && compositorOffsetAtCancel < pageWidth * 2,
            "mid-settle 前置状态"
        )

        // 真实 precise NSEvent.phase == .cancelled。
        grid.pagingProbeFeed(makeScroll(dx: 0, phase: .cancelled)!)

        // 断言: cancelled、nil duration、summary exactly once、animator/phase/compositor/live 收口。
        #expect(grid.pagingProbePhase() == "idle", "cancel 后 phase idle")
        #expect(!pagingControllerForDiag(grid).isDisplayLinkActive, "cancel 后 display link/animator 停止")
        #expect(pagingControllerForDiag(grid).settleTargetPageForTest == nil, "cancel 清除 settle 目标")
        #expect(!grid.pageCompositorActiveForDiag, "compositor 正确收口")
        #expect(grid.pageCompositorLayerFramesForDiag.isEmpty, "compositor layers 清空")
        #expect(grid.pageCompositorLiveOpacityForDiag == 1, "live 已 reveal")
        #expect(
            abs(grid.clipOffsetXForDiag - compositorOffsetAtCancel) < 0.001,
            "clip offset 与 cancel 时 compositor offset 连续"
        )
        #expect(grid.visibleItemsCountForDiag > 0, "live content 非空")

        for _ in 0..<300 where summaries.isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(summaries.count == 1, "summary exactly once")
        #expect(summaries[0].contains("completionReason=cancelled"), "cancel 语义 completionReason == cancelled")
        #expect(summaries[0].contains("settleDurationMs=nil"), "cancelled 无 stale duration")

        // 后续 onPhaseIdle 不重复 flush: 零位移手势结束(无方向回调)仍会走 onPhaseIdle。
        grid.pagingProbeFeed(makeScroll(dx: 0, phase: .began)!)
        grid.pagingProbeFeed(makeScroll(dx: 0, phase: .ended)!)
        _ = grid.pagingProbeDisplayFrame()
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(summaries.count == 1, "后续 onPhaseIdle 不重复 flush")
    }
}

// MARK: - 测试替身

@MainActor
private class CompositorIntegrationStore: LauncherStoring {
    var searchResultsValue: [DisplayModel.DisplayItem]?
    var revision: UInt64 = 1

    var onDataChange: (() -> Void)?
    var searchQuery = ""
    let gridColumns = 3
    let gridRows = 2
    let iconSize = 64
    let wallpaperBlurRadius = 30
    let searchBarWidth = 320
    var displayRevision: UInt64 { revision }

    let pages: [[DisplayModel.DisplayItem]]

    init() {
        pages = (0..<4).map { page in
            (0..<3).map { index in
                .app(AppID("/Applications/CompA\(page)\(index).app")!)
            }
        }
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID { UUID() }
    func removeDataObserver(_ token: UUID) {}

    func displayModel() -> DisplayModel {
        DisplayModel(pages: pages, pageCapacity: gridColumns * gridRows)
    }

    func searchResults() -> [DisplayModel.DisplayItem]? { searchResultsValue }
    func displayName(for appID: AppID) -> String { appID.rawValue }
    func folderName(for folderID: FolderID) -> String { folderID.rawValue }
    func launch(_ appID: AppID) {}
    func createFolder(name: String, appIDs: [AppID]) {}
    func renameFolder(_ id: FolderID, to name: String) {}
    func dissolveFolder(_ id: FolderID) {}
    func addToFolder(app: AppID, folder: FolderID) {}
    func moveOutOfFolder(
        app: AppID,
        from folder: FolderID,
        toDisplayIndex: Int,
        completion: @escaping (Bool) -> Void
    ) { completion(false) }
    func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int) {}
    func folderNames() -> [FolderID: String] { [:] }
    func folderChildren(_ id: FolderID) -> [AppID]? { nil }
    func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation) {}
    func setHidden(_ appID: AppID, hidden: Bool) {}
    func setCustomName(_ appID: AppID, name: String?) {}
    func moveToTrash(_ appID: AppID) {}
    func isHidden(_ appID: AppID) -> Bool { false }

}

@MainActor
private final class CompositorLeadingStore: CompositorIntegrationStore, AppLibraryDataProviding {
    func appLibraryModel() -> AppLibraryModel {
        AppLibraryModel(cards: [], categoryDetail: [:])
    }
}

@MainActor
private final class CompositorIntegrationIconProvider: IconImageProviding {
    func icon(for appID: AppID, pointSize: Int, scale: Int) async -> CGImage? {
        let context = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let hue = CGFloat(abs(appID.rawValue.hashValue) % 12) / 12
        context.setFillColor(
            NSColor(hue: hue, saturation: 0.6, brightness: 0.7, alpha: 1).cgColor
        )
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return context.makeImage()
    }

    func trimMemoryForHidden() {}
}

/// FX-F FIX-2 seam: 页 2 是文件夹页; 其子项图标请求**只可能来自 resolveIcons**
/// (单元格只配置可见页, prewarm 跳过 folder 项)—— provider 首次为子项取
/// 图标时提升 store.displayRevision, 精确模拟"解析期间数据变化"。
@MainActor
private final class SnapshotRecheckStore: LauncherStoring {
    var revision: UInt64 = 1

    var onDataChange: (() -> Void)?
    var searchQuery = ""
    let gridColumns = 3
    let gridRows = 2
    let iconSize = 64
    let wallpaperBlurRadius = 30
    let searchBarWidth = 320
    var displayRevision: UInt64 { revision }

    let pages: [[DisplayModel.DisplayItem]]
    let folderChildrenPayload: [FolderID: [AppID]]

    init() {
        let folderID = FolderID(normalized: "/folders/snapshot-recheck")
        pages = [
            (0..<3).map { .app(AppID("/Applications/RecheckA0\($0).app")!) },
            (0..<3).map { .app(AppID("/Applications/RecheckA1\($0).app")!) },
            [.folder(folderID)],
        ]
        folderChildrenPayload = [
            folderID: [
                AppID("/Applications/RecheckChild0.app")!,
                AppID("/Applications/RecheckChild1.app")!,
            ],
        ]
    }

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID { UUID() }
    func removeDataObserver(_ token: UUID) {}

    func displayModel() -> DisplayModel {
        DisplayModel(
            pages: pages,
            pageCapacity: gridColumns * gridRows,
            folderChildrenPayload: folderChildrenPayload
        )
    }

    func searchResults() -> [DisplayModel.DisplayItem]? { nil }
    func displayName(for appID: AppID) -> String { appID.rawValue }
    func folderName(for folderID: FolderID) -> String { folderID.rawValue }
    func launch(_ appID: AppID) {}
    func createFolder(name: String, appIDs: [AppID]) {}
    func renameFolder(_ id: FolderID, to name: String) {}
    func dissolveFolder(_ id: FolderID) {}
    func addToFolder(app: AppID, folder: FolderID) {}
    func moveOutOfFolder(
        app: AppID,
        from folder: FolderID,
        toDisplayIndex: Int,
        completion: @escaping (Bool) -> Void
    ) { completion(false) }
    func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int) {}
    func folderNames() -> [FolderID: String] { [:] }
    func folderChildren(_ id: FolderID) -> [AppID]? { folderChildrenPayload[id] }
    func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation) {}
    func setHidden(_ appID: AppID, hidden: Bool) {}
    func setCustomName(_ appID: AppID, name: String?) {}
    func moveToTrash(_ appID: AppID) {}
    func isHidden(_ appID: AppID) -> Bool { false }
}

@MainActor
private final class SnapshotBumpIconProvider: IconImageProviding {
    private let store: SnapshotRecheckStore
    private let childIDs: Set<AppID>
    private(set) var didBump = false

    init(store: SnapshotRecheckStore, childIDs: Set<AppID>) {
        self.store = store
        self.childIDs = childIDs
    }

    func icon(for appID: AppID, pointSize: Int, scale: Int) async -> CGImage? {
        if !didBump, childIDs.contains(appID) {
            didBump = true
            store.revision &+= 1
        }
        let context = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let hue = CGFloat(abs(appID.rawValue.hashValue) % 12) / 12
        context.setFillColor(
            NSColor(hue: hue, saturation: 0.6, brightness: 0.7, alpha: 1).cgColor
        )
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return context.makeImage()
    }

    func trimMemoryForHidden() {}
}
