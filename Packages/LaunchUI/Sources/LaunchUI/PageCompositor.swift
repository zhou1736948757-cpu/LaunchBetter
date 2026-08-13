import AppKit
import QuartzCore

/// 页面合成器遥测(默认关; `--pagecompositor` 开启)。
///
/// 计数目标: A/B 对比 dense 页 live vs compositor 的帧间隔、构建/应用耗时、
/// 降级与中止次数。记录成本仅一个布尔判断 + 时间差(开启时), 默认零开销路径不变。
@MainActor
final class PageCompositorMetrics {
    var enabled = false

    private(set) var active = false
    private(set) var visualBuildCount = 0
    private(set) var visualBuildTotalMs: Double = 0
    private(set) var visualBuildMaxMs: Double = 0
    private(set) var activeVisualCount = 0
    private(set) var activeVisualBytes = 0
    private(set) var fallbackLiveCount = 0
    private(set) var compositorFrames = 0
    private(set) var frameApplyTotalUs: Double = 0
    private(set) var frameApplyMaxUs: Double = 0
    private(set) var abortCount = 0
    private(set) var reversalCount = 0

    func recordActiveChange(active: Bool) {
        self.active = active
    }

    func recordVisualBuild(durationMs: Double) {
        guard enabled else { return }
        visualBuildCount += 1
        visualBuildTotalMs += durationMs
        visualBuildMaxMs = max(visualBuildMaxMs, durationMs)
    }

    func recordActivation(visualCount: Int, bytes: Int) {
        guard enabled else { return }
        activeVisualCount = visualCount
        activeVisualBytes = bytes
    }

    func recordFallbackLive() {
        guard enabled else { return }
        fallbackLiveCount += 1
    }

    func recordFrameApply(durationUs: Double) {
        guard enabled else { return }
        compositorFrames += 1
        frameApplyTotalUs += durationUs
        frameApplyMaxUs = max(frameApplyMaxUs, durationUs)
    }

    func recordAbort() {
        guard enabled else { return }
        abortCount += 1
    }

    func recordReversal() {
        guard enabled else { return }
        reversalCount += 1
    }

    var visualBuildAvgMs: Double {
        visualBuildCount > 0 ? visualBuildTotalMs / Double(visualBuildCount) : 0
    }

    var frameApplyAvgUs: Double {
        compositorFrames > 0 ? frameApplyTotalUs / Double(compositorFrames) : 0
    }

    func summary(cacheHits: Int, cacheMisses: Int, cacheBytes: Int) -> String {
        "enabled=\(enabled ? 1 : 0) active=\(active ? 1 : 0) "
            + "cacheHits=\(cacheHits) cacheMisses=\(cacheMisses) cacheBytes=\(cacheBytes) "
            + "builds=\(visualBuildCount) buildAvgMs=\(String(format: "%.2f", visualBuildAvgMs)) "
            + "buildMaxMs=\(String(format: "%.2f", visualBuildMaxMs)) "
            + "activeVisuals=\(activeVisualCount) activeBytes=\(activeVisualBytes) "
            + "fallbackLive=\(fallbackLiveCount) frames=\(compositorFrames) "
            + "applyAvgUs=\(String(format: "%.1f", frameApplyAvgUs)) "
            + "applyMaxUs=\(String(format: "%.1f", frameApplyMaxUs)) "
            + "aborts=\(abortCount) reversals=\(reversalCount)"
    }
}

/// 页面合成器: **只做 presentation**。PagingInteractionController 保持唯一运动引擎;
/// 本对象只负责把预渲染 PageVisual 摆到正确位置, 并在 settle 完成/中止时
/// 把真实 NSClipView 同步到精确偏移再 reveal live。
///
/// 每帧路径: 仅 offset 数学 + CALayer frame 写; 禁止 Store/DisplayModel/Diffable/
/// 图标/文件/文本布局/文件夹光栅/autolayout/Task。
///
/// 生命周期:
/// - `activate`: 手势起点(零跳变: 激活帧视觉 == 当前 live 页视觉)。
/// - `applyOffset`: 每帧唯一写入(层 x = pageIndex×pageWidth - offset)。
/// - `finishSettle` / `abort` / `shutdown`: 同步 clip → reveal → 移除层。
@MainActor
final class PageCompositor {
    /// 一页视觉的放置信息(baseFrame 为宿主层坐标, y-up; 水平随 offset 漂移)。
    struct Placement {
        let page: Int
        let baseFrame: CGRect
        let visual: PageVisual
    }

    enum Event: Equatable {
        case activated(offset: CGFloat)
        case applied(offset: CGFloat)
        case finishedSettle(offset: CGFloat)
        case aborted(offset: CGFloat)
        case shutdown(offset: CGFloat)
    }

    /// 真实 clip 写入(settle 完成/中止时一次性同步)。
    var onSyncClip: (CGFloat) -> Void = { _ in }

    private(set) var isActive = false
    private(set) var currentOffset: CGFloat = 0
    private(set) var pageWidth: CGFloat = 0

    let metrics = PageCompositorMetrics()

    private var startOffset: CGFloat = 0
    private var placements: [Placement] = []
    private var layers: [CALayer] = []
    private weak var hostLayer: CALayer?
    private weak var liveLayer: CALayer?
    private var lastAppliedOffset: CGFloat = 0
    private var lastDirectionSign: CGFloat = 0

    private(set) var eventsForDiag: [Event] = []

    /// 激活(零跳变): 把 visual 摆到与 live 完全一致的位置, 然后隐藏 live 前景。
    /// - 前提: 调用方已确认相邻页视觉齐备、surface/状态允许。
    /// - `startOffset` 必须 == 当前 clip 偏移(调用方读取真实 clip 传入)。
    func activate(
        placements: [Placement],
        pageWidth: CGFloat,
        startOffset: CGFloat,
        hostLayer: CALayer,
        liveLayer: CALayer
    ) {
        guard !isActive, !placements.isEmpty, pageWidth > 0 else { return }
        self.placements = placements
        self.pageWidth = pageWidth
        self.startOffset = startOffset
        self.currentOffset = startOffset
        self.lastAppliedOffset = startOffset
        self.lastDirectionSign = 0
        self.hostLayer = hostLayer
        self.liveLayer = liveLayer

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var newLayers: [CALayer] = []
        for placement in placements {
            let layer = CALayer()
            layer.isGeometryFlipped = true
            layer.contents = placement.visual.image
            layer.contentsScale = placement.visual.rasterScale
            layer.frame = placement.baseFrame
            layer.opacity = 1
            layer.contentsGravity = .resize
            hostLayer.addSublayer(layer)
            newLayers.append(layer)
        }
        layers = newLayers
        liveLayer.opacity = 0
        CATransaction.commit()

        isActive = true
        metrics.recordActiveChange(active: true)
        metrics.recordActivation(
            visualCount: placements.count,
            bytes: placements.reduce(0) { $0 + $1.visual.bytes }
        )
        eventsForDiag.append(.activated(offset: startOffset))
    }

    /// 每帧唯一 offset 写入: 只移动层, 不写 clip。
    func applyOffset(_ offset: CGFloat) {
        guard isActive else { return }
        let start = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let drift = offset - startOffset
        for (index, placement) in placements.enumerated() {
            var frame = placement.baseFrame
            frame.origin.x = placement.baseFrame.minX - drift
            layers[index].frame = frame
        }
        CATransaction.commit()

        let delta = offset - lastAppliedOffset
        if delta != 0 {
            let sign: CGFloat = delta > 0 ? 1 : -1
            if lastDirectionSign != 0, sign != lastDirectionSign {
                metrics.recordReversal()
            }
            lastDirectionSign = sign
        }
        lastAppliedOffset = offset
        currentOffset = offset
        metrics.recordFrameApply(durationUs: (CACurrentMediaTime() - start) * 1_000_000)
        eventsForDiag.append(.applied(offset: offset))
    }

    /// settle 完成: 禁隐式动画下把真实 clip 同步到精确目标 → reveal live →
    /// 移除层。同一 CATransaction 内原子完成, 无闪烁。
    func finishSettle() {
        guard isActive else { return }
        let target = currentOffset
        teardown(syncOffset: target, event: .finishedSettle(offset: target))
    }

    /// 中止(缓存失效/条件不满足): 捕获当前 visual offset → 真实 clip 同步 →
    /// reveal → 移除, 回到 live。
    func abort() {
        guard isActive else { return }
        let offset = currentOffset
        metrics.recordAbort()
        teardown(syncOffset: offset, event: .aborted(offset: offset))
    }

    /// 显式 shutdown(幂等; 可重复调用, 无僵尸 layer)。
    func shutdown() {
        guard isActive else {
            eventsForDiag.append(.shutdown(offset: currentOffset))
            return
        }
        let offset = currentOffset
        metrics.recordAbort()
        teardown(syncOffset: offset, event: .shutdown(offset: offset))
    }

    private func teardown(syncOffset: CGFloat, event: Event) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        onSyncClip(syncOffset)
        liveLayer?.opacity = 1
        CATransaction.commit()
        for layer in layers {
            layer.removeFromSuperlayer()
        }
        layers.removeAll()
        placements.removeAll()
        isActive = false
        metrics.recordActiveChange(active: false)
        eventsForDiag.append(event)
    }

    // MARK: - 诊断

    /// 当前层 frame(宿主坐标; 测试/探针)。
    var layerFramesForDiag: [CGRect] { layers.map(\.frame) }

    /// 当前层页索引(与 placements 对齐)。
    var pageIndicesForDiag: [Int] { placements.map(\.page) }

    /// live 前景层当前 opacity(nil = 未激活)。
    var liveLayerOpacityForDiag: Float? { liveLayer?.opacity }
}
