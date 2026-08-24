import CoreGraphics
import Foundation
import Testing
@testable import LaunchCore

/// FolderThumbnailMetrics 纯逻辑测试(P0-04): 不启动真实 Launcher。
///
/// 期望值独立于实现手工计算(与 t2 审计数值及 PageVisualRendererTests
/// 硬编码结果 side=120 → padding=13.2/gap=3/iconSide≈29.2 交叉核对),
/// 作为两处 UI 消费者(FolderThumbnailView.updateLayout /
/// PageVisualRenderer.drawFolderThumbnail)的公式奇偶门。
@Suite("FolderThumbnailMetrics")
struct FolderThumbnailMetricsTests {
    private func approx(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.001) -> Bool {
        abs(a - b) <= tolerance
    }

    // MARK: - 公式奇偶(代表边长 48/64/80/96, 与 t2 审计数值一致)

    @Test("side=48: padding=5.28 gap=2 iconSide≈11.15 radius=10 childRadius=2")
    func side48() {
        let m = FolderThumbnailMetrics(side: 48)
        #expect(approx(m.padding, 5.28))
        #expect(approx(m.gap, 2))
        #expect(approx(m.iconSide, 11.1467))
        #expect(approx(m.radius, 10))
        #expect(approx(m.childRadius, 2))
    }

    @Test("side=64: padding=7.04 gap=2 iconSide≈15.31 radius=12.8 childRadius≈2.45")
    func side64() {
        let m = FolderThumbnailMetrics(side: 64)
        #expect(approx(m.padding, 7.04))
        #expect(approx(m.gap, 2))
        #expect(approx(m.iconSide, 15.3067))
        #expect(approx(m.radius, 12.8))
        #expect(approx(m.childRadius, 2.4491))
    }

    @Test("side=80: padding=8.8 gap=2 iconSide≈19.47 radius=16 childRadius≈3.11")
    func side80() {
        let m = FolderThumbnailMetrics(side: 80)
        #expect(approx(m.padding, 8.8))
        #expect(approx(m.gap, 2))
        #expect(approx(m.iconSide, 19.4667))
        #expect(approx(m.radius, 16))
        #expect(approx(m.childRadius, 3.1147))
    }

    @Test("side=96: padding=10.56 gap=2.4 iconSide=23.36 radius=18 childRadius≈3.74")
    func side96() {
        let m = FolderThumbnailMetrics(side: 96)
        #expect(approx(m.padding, 10.56))
        #expect(approx(m.gap, 2.4))
        #expect(approx(m.iconSide, 23.36))
        #expect(approx(m.radius, 18))
        #expect(approx(m.childRadius, 3.7376))
    }

    @Test("side=120: 与 PageVisualRendererTests 硬编码奇偶(padding=13.2 gap=3 iconSide=29.2)")
    func side120RendererParity() {
        let m = FolderThumbnailMetrics(side: 120)
        #expect(approx(m.padding, 13.2))
        #expect(approx(m.gap, 3))
        #expect(approx(m.iconSide, 29.2))
        #expect(approx(m.radius, 18))
        #expect(approx(m.childRadius, 4.672))
        // child0 中心 ≈ (27.8, 27.8) —— 与渲染器测试注释一致。
        let child0 = m.childFrame(index: 0)
        #expect(approx(child0.midX, 27.8))
        #expect(approx(child0.midY, 27.8))
    }

    // MARK: - 钳制边界

    @Test("小边长: padding/gap/iconSide/radius/childRadius 全部触底钳制")
    func smallSideClamps() {
        for side: CGFloat in [0, 10] {
            let m = FolderThumbnailMetrics(side: side)
            #expect(m.padding == 5)
            #expect(m.gap == 2)
            #expect(m.iconSide == 1)
            #expect(m.radius == 10)
            #expect(m.childRadius == 2)
        }
    }

    @Test("大边长: radius 封顶 18, childRadius 封顶 5")
    func largeSideCaps() {
        let m200 = FolderThumbnailMetrics(side: 200)
        #expect(approx(m200.padding, 22))
        #expect(approx(m200.gap, 5))
        #expect(approx(m200.iconSide, 48.6667))
        #expect(m200.radius == 18)
        #expect(m200.childRadius == 5)

        let m1000 = FolderThumbnailMetrics(side: 1000)
        #expect(approx(m1000.padding, 110))
        #expect(approx(m1000.gap, 25))
        #expect(approx(m1000.iconSide, 243.3333))
        #expect(m1000.radius == 18)
        #expect(m1000.childRadius == 5)
    }

    @Test("子图标数钳制到 [0, 9]")
    func iconCountClamp() {
        #expect(FolderThumbnailMetrics.clampedIconCount(-5) == 0)
        #expect(FolderThumbnailMetrics.clampedIconCount(0) == 0)
        #expect(FolderThumbnailMetrics.clampedIconCount(9) == 9)
        #expect(FolderThumbnailMetrics.clampedIconCount(10) == 9)
        #expect(FolderThumbnailMetrics.clampedIconCount(100) == 9)
    }

    // MARK: - 子图标网格

    @Test("childFrame 行主序: row=index/3, col=index%3, 左上原点")
    func childFrameGridPositions() {
        let m = FolderThumbnailMetrics(side: 80)
        let step = m.iconSide + m.gap
        #expect(m.childFrame(index: 0) == CGRect(x: m.padding, y: m.padding, width: m.iconSide, height: m.iconSide))
        #expect(approx(m.childFrame(index: 1).minX, m.padding + step))
        #expect(approx(m.childFrame(index: 2).minX, m.padding + 2 * step))
        #expect(approx(m.childFrame(index: 3).minY, m.padding + step))
        #expect(approx(m.childFrame(index: 8).minX, m.padding + 2 * step))
        #expect(approx(m.childFrame(index: 8).minY, m.padding + 2 * step))
    }

    @Test("childFrame 越界 index 返回零 frame")
    func childFrameOutOfRange() {
        let m = FolderThumbnailMetrics(side: 80)
        #expect(m.childFrame(index: -1) == .zero)
        #expect(m.childFrame(index: 9) == .zero)
        #expect(m.childFrame(index: 100) == .zero)
    }

    @Test("9 个子图标全部落在 padding 内且互不重叠")
    func childGridContainmentAndNoOverlap() {
        let m = FolderThumbnailMetrics(side: 80)
        var frames: [CGRect] = []
        for index in 0..<FolderThumbnailMetrics.maxIconCount {
            let frame = m.childFrame(index: index)
            // 全部落在 padding 内(不越界)。
            #expect(frame.minX >= m.padding - 0.001)
            #expect(frame.minY >= m.padding - 0.001)
            #expect(frame.maxX <= m.side - m.padding + 0.001)
            #expect(frame.maxY <= m.side - m.padding + 0.001)
            frames.append(frame)
        }
        // 末列/末行恰与 padding 齐平(与既有实现一致)。
        for row in 0..<3 {
            #expect(approx(frames[row * 3 + 2].maxX, m.side - m.padding))
        }
        for col in 0..<3 {
            #expect(approx(frames[6 + col].maxY, m.side - m.padding))
        }
        // 相邻 frame 间距 = gap > 0, 无重叠。
        for row in 0..<3 {
            for col in 0..<2 {
                let left = frames[row * 3 + col]
                let right = frames[row * 3 + col + 1]
                #expect(approx(right.minX - left.maxX, m.gap))
            }
        }
        for col in 0..<3 {
            for row in 0..<2 {
                let top = frames[row * 3 + col]
                let bottom = frames[(row + 1) * 3 + col]
                #expect(approx(bottom.minY - top.maxY, m.gap))
            }
        }
    }

    // MARK: - 1x/2x 尺度

    @Test("指标为点单位: 与显示 scale 无关, 像素尺寸 = 点 × scale")
    func pointBasedScaleIndependence() {
        // 类型无 scale 输入: 同一 side 恒得同一指标(1x/2x 显示器共用)。
        let m1 = FolderThumbnailMetrics(side: 80)
        let m2 = FolderThumbnailMetrics(side: 80)
        #expect(m1 == m2)
        // 像素契约: 2x 下子图标像素边长 = iconSide × 2。
        #expect(approx(m1.iconSide * 2, 38.9333))
        #expect(approx(m1.padding * 2, 17.6))
    }
}
