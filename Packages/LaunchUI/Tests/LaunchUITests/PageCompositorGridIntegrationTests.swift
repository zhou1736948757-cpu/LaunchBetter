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

    /// 驱动 display frame 直到 paging idle(弹簧按真实时间收敛)。
    private func driveUntilIdle(_ grid: GridViewController, maxFrames: Int = 900) async -> Bool {
        var frames = 0
        while grid.pagingProbePhase() != "idle", frames < maxFrames {
            _ = grid.pagingProbeDisplayFrame()
            frames += 1
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return grid.pagingProbePhase() == "idle"
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

    private func makeGrid(_ store: CompositorIntegrationStore) -> GridViewController {
        let grid = GridViewController(
            store: store, iconProvider: CompositorIntegrationIconProvider()
        )
        grid.pageVisualCompositorEnabled = true
        // 测试替身 3 项/页(稀疏); 密度门放宽以专注合成语义本身。
        // 密度门独立于合成语义, 由 densityGate 测试单独覆盖。
        grid.pageVisualMinItemsPerPage = 1
        return grid
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

        // 页 0: 无 previous 邻页 → 不可合成(Library 边界语义)。
        #expect(!grid.pageCompositorEligibleForDiag, "页 0 边界不可合成")

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

    @Test("eligibility: leading surface — layout page 0 邻 Library 恒不可合成")
    func eligibilityLibraryBoundary() async throws {
        let store = CompositorLeadingStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        // leading 启用: 物理 1 = layout page 0, 其 previous = Library。
        #expect(grid.currentSurfaceValue == .layoutPage(0))
        await grid.waitForPageVisualPrepareForDiag()
        #expect(!grid.pageCompositorEligibleForDiag, "Library↔Page1 边界不支持合成(用 live)")

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

        await driveUntilIdle(grid)
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
        #expect(grid.pageCompositorLayerFramesForDiag.count == 3)
        #expect(grid.pageCompositorPageIndicesForDiag == [0, 1, 2])

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
            try? await Task.sleep(nanoseconds: 6_000_000)
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

    @Test("打断: settle 中新手势不拆 compositor, 从 compositor.currentOffset 继续")
    func interruptionKeepsCompositorDuringSettle() async throws {
        let store = CompositorIntegrationStore()
        let grid = makeGrid(store)
        let window = makeWindow(for: grid)
        defer { window.orderOut(nil); window.contentView = nil }

        grid.refresh()
        grid.goToPage(1, animated: false)
        let pageWidth = grid.geometry.pageWidth
        await waitPrepared(grid)

        // 第一次手势 → settling(compositor 已激活)。
        grid.pagingProbeGesture(deltaXs: [-200, -200])
        #expect(grid.pagingProbePhase() == "settling")
        #expect(grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorCurrentOffsetForDiag == pageWidth, "零跳变激活")

        // 同一 runloop turn 内立即打断(display link 无法插帧 → 确定性)。
        grid.pagingProbeGesture(deltaXs: [-100, 100])
        #expect(grid.pageCompositorActiveForDiag, "打断不拆 compositor")
        #expect(
            grid.pageCompositorCurrentOffsetForDiag == pageWidth,
            "从被打断位置继续(baseOffset == 被打断偏移)"
        )
        // 零净位移 → PA4 resume-settle: 重启被打断的目标(page 2), 确定性收敛。
        #expect(grid.pagingProbePhase() == "settling")

        let settled = await driveUntilIdle(grid)
        #expect(settled)
        #expect(!grid.pageCompositorActiveForDiag)
        #expect(grid.pageCompositorLayerFramesForDiag.isEmpty)
        #expect(grid.pageCompositorLiveOpacityForDiag == 1)
        #expect(grid.clipOffsetXForDiag == pageWidth * 2, "resume-settle 收敛到原目标页")
        #expect(grid.currentPageValue == 2)
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
