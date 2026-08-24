import CoreGraphics
import Foundation

/// 文件夹缩略图几何: 圆角玻璃容器 + ≤9 子图标 3×3 网格的唯一几何真值(P0-04)。
///
/// 取代散落在 `FolderThumbnailView.updateLayout`(AppCellView.swift) 与
/// `PageVisualRenderer.drawFolderThumbnail` 各自维护的 padding/gap/iconSide/
/// radius/childRadius/childFrame 硬编码 —— 两处公式逐位相同, 仅 y 原点约定
/// 不同(AppKit 非翻转视图 top-down vs CGContext bottom-up), 提取后由调用方
/// 按自身坐标系翻转, 消除漂移风险。
///
/// 公式(与两处既有实现逐位一致, 提取不改值):
/// - `padding` = max(5, side * 0.11)
/// - `gap`     = max(2, side * 0.025)
/// - `iconSide` = max(1, (side - padding*2 - gap*2) / 3)
/// - `radius`   = min(18, max(10, side * 0.2))
/// - `childRadius` = min(5, max(2, iconSide * 0.16))
///
/// 坐标系约定: `childFrame(index:)` 返回**左上原点(top-down)**坐标(与 AppKit
/// 非翻转视图一致, row 0 = 顶行, 行主序)。bottom-up 消费者(CGContext 光栅化)
/// 取 `y = side - frame.maxY` 翻转。
///
/// 纯计算结构: 不依赖 AppKit, 可在不启动启动器的情况下完整测试。
public struct FolderThumbnailMetrics: Sendable, Equatable {
    /// 子图标网格上限(3×3; 与 FolderThumbnailView.maxIconCount /
    /// resolveIcons prefix(9) 一致)。
    public static let maxIconCount = 9

    /// 缩略图边长(pt; 正方形, side = min(宽, 高))。
    public let side: CGFloat

    /// 容器内边距(pt)。
    public let padding: CGFloat

    /// 子图标间距(pt)。
    public let gap: CGFloat

    /// 子图标边长(pt)。
    public let iconSide: CGFloat

    /// 容器圆角(pt)。
    public let radius: CGFloat

    /// 子图标圆角(pt)。
    public let childRadius: CGFloat

    public init(side: CGFloat) {
        self.side = side
        self.padding = max(5, side * 0.11)
        self.gap = max(2, side * 0.025)
        self.iconSide = max(1, (side - padding * 2 - gap * 2) / 3)
        self.radius = min(18, max(10, side * 0.2))
        self.childRadius = min(5, max(2, iconSide * 0.16))
    }

    /// 子图标数钳制到 [0, maxIconCount](与 FolderThumbnailView.configure 的
    /// `min(max(0, iconCount), maxIconCount)` 一致)。
    public static func clampedIconCount(_ count: Int) -> Int {
        min(max(0, count), maxIconCount)
    }

    /// 第 `index` 个子图标 frame(左上原点, 行主序: row = index/3, col = index%3)。
    /// `index` 超出 [0, maxIconCount) 时返回零 frame(调用方应先经
    /// `clampedIconCount` 钳制)。
    public func childFrame(index: Int) -> CGRect {
        guard (0..<Self.maxIconCount).contains(index) else { return .zero }
        let row = index / 3
        let column = index % 3
        return CGRect(
            x: padding + CGFloat(column) * (iconSide + gap),
            y: padding + CGFloat(row) * (iconSide + gap),
            width: iconSide,
            height: iconSide
        )
    }
}
