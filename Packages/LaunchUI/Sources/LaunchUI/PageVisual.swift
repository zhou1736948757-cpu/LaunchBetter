import CoreGraphics
import Foundation
import LaunchCore

/// 页面视觉几何签名: 从 GridGeometry 派生的稳定指纹。
///
/// 渲染像素只依赖 geometry 的布局字段; 任何字段变化(列/行/尺寸/间距/页宽高/
/// 保留区)都会产生新签名 → 缓存键变化 → 旧视觉失效, 无需显式 purge。
struct PageVisualGeometrySignature: Hashable, Sendable {
    let columns: Int
    let rows: Int
    let cellSize: CGFloat
    let iconSize: CGFloat
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let pageWidth: CGFloat
    let pageHeight: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(geometry: GridGeometry) {
        columns = geometry.columns
        rows = geometry.rows
        cellSize = geometry.cellSize
        iconSize = geometry.iconSize
        horizontalSpacing = geometry.horizontalSpacing
        verticalSpacing = geometry.verticalSpacing
        pageWidth = geometry.pageWidth
        pageHeight = geometry.pageHeight
        topInset = geometry.topInset
        bottomInset = geometry.bottomInset
    }

    /// 显式 memberwise(自定义 init 会抑制合成; 测试直接构造)。
    init(
        columns: Int,
        rows: Int,
        cellSize: CGFloat,
        iconSize: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) {
        self.columns = columns
        self.rows = rows
        self.cellSize = cellSize
        self.iconSize = iconSize
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.topInset = topInset
        self.bottomInset = bottomInset
    }
}

/// 页面视觉缓存键: 决定一张 PageVisual 是否仍然有效。
///
/// 由普通 layout page 索引 + 数据/几何/scale/语言代数组成。图标代数由渲染器
/// 在观察到"可用图标集合变化"时递增(迟到图标到达 → 旧视觉自然失效)。
struct PageVisualKey: Hashable, Sendable {
    let pageIndex: Int
    let displayRevision: UInt64
    let geometry: PageVisualGeometrySignature
    let backingScale: Int
    let languageRevision: UInt64
    let iconEpoch: UInt64
}

/// 一张已光栅化的页面网格内容区(非全屏)。
///
/// - `image`: 网格内容区位图(像素尺寸 = logicalBounds × rasterScale)。
/// - `logicalBounds`: 页面局部坐标(y-down)中网格内容区矩形; 合成器按此摆放。
/// - `rasterScale`: 位图 scale(1x/2x 显示器)。
/// - `bytes`: 内存记账(近似位图字节数)。
struct PageVisual: Sendable {
    let key: PageVisualKey
    let image: CGImage
    let logicalBounds: CGRect
    let rasterScale: CGFloat

    /// 近似内存占用: 像素数 × 每像素 4 字节(ARGB)。CGImage 实际解码可能
    /// 另有开销, 此处只做稳定记账信号。
    var bytes: Int {
        let pixels = image.width * image.height
        guard pixels > 0 else { return 0 }
        return pixels * 4
    }
}
