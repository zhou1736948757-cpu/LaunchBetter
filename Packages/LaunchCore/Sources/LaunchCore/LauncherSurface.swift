/// Stage E1: 启动器语义 surface 契约(纯逻辑映射值对象, 不接 UI / LayoutStore)。
///
/// 物理索引(physical index)是跨所有 surface 的唯一连续索引:
/// ```text
/// physical 0      = App Library(恒为 0)
/// physical n + 1  = Layout 第 n 页(普通布局页, 0-based)
/// ```
/// 本类型不提供 LayoutSnapshot/LayoutStore sentinel, 不做持久化编码。
public enum LauncherSurface: Equatable, Sendable {
    /// App Library: 物理索引恒为 0。
    case appLibrary
    /// 普通布局页(0-based layout page index)。
    case layoutPage(Int)
}

/// 语义 surface ↔ 物理索引映射表。
/// `layoutPageCount` 在 init 时规范化为至少 1。
public struct LauncherSurfaceIndex: Equatable, Sendable {
    /// 普通布局页数量(规范化后 ≥ 1)。
    public let layoutPageCount: Int

    public init(layoutPageCount: Int) {
        self.layoutPageCount = max(layoutPageCount, 1)
    }

    /// surface 总数 = Layout 页数 + App Library(≥ 2)。
    public var physicalSurfaceCount: Int { layoutPageCount + 1 }

    /// surface → physical index;越界 page 确定性 clamp 到 [0, layoutPageCount - 1]。
    public func physicalIndex(for surface: LauncherSurface) -> Int {
        switch surface {
        case .appLibrary:
            return 0
        case .layoutPage(let page):
            return min(max(page, 0), layoutPageCount - 1) + 1
        }
    }

    /// physical index → surface;边界确定性 clamp 到 [0, physicalSurfaceCount - 1]。
    /// physical 0 反向为 `.appLibrary`。
    public func surface(forPhysicalIndex index: Int) -> LauncherSurface {
        let clamped = min(max(index, 0), physicalSurfaceCount - 1)
        guard clamped > 0 else { return .appLibrary }
        return .layoutPage(clamped - 1)
    }

    /// physical index → 普通布局页 index(0-based)。
    /// physical 0 与越界索引返回 nil(guard 查询, 非总映射)。
    public func layoutPageIndex(forPhysicalIndex index: Int) -> Int? {
        guard index >= 1, index <= layoutPageCount else { return nil }
        return index - 1
    }
}
