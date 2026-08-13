import Foundation

/// 页面视觉缓存: 有界 working set(≤ 3: previous/current/next)。
///
/// - LRU 驱逐: 超过上限时移除最近最久未使用的条目。
/// - 精确失效: 按 key 查找/插入; 键变化 = 隐式失效(新键自然 miss)。
/// - 内存记账: totalBytes / visualCount / rasterScale 分布。
/// - purge: hide、内存压力、backing scale / geometry / 结构变更时调用。
@MainActor
final class PageVisualCache {
    /// working set 上限: previous/current/next。
    static let maxVisualCount = 3

    private var storage: [PageVisualKey: PageVisual] = [:]
    /// LRU 访问序(末尾 = 最近使用)。
    private var accessOrder: [PageVisualKey] = []

    private(set) var totalBytes = 0
    private(set) var hitCount = 0
    private(set) var missCount = 0

    /// 当前条目数(≤ maxVisualCount)。
    var visualCount: Int { storage.count }

    /// 当前光栅 scale 分布(逐出后清空; 仅记录有效条目)。
    private(set) var rasterScales: Set<Int> = []

    var isEmpty: Bool { storage.isEmpty }

    /// 读视觉; 命中提升 LRU 序。
    func visual(for key: PageVisualKey) -> PageVisual? {
        guard let visual = storage[key] else {
            missCount += 1
            return nil
        }
        hitCount += 1
        touch(key)
        return visual
    }

    /// 只读检查(不提升 LRU 序; 驱逐决策用)。
    func contains(_ key: PageVisualKey) -> Bool {
        storage[key] != nil
    }

    /// 插入视觉; 超过上限逐出最久未使用条目。
    @discardableResult
    func insert(_ visual: PageVisual) -> PageVisual? {
        let key = visual.key
        if let previous = storage[key] {
            totalBytes -= previous.bytes
            storage.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
        }
        storage[key] = visual
        totalBytes += visual.bytes
        accessOrder.append(key)
        let scale = Int(visual.rasterScale.rounded())
        rasterScales.insert(scale)

        var evicted: PageVisual?
        while storage.count > Self.maxVisualCount, let oldest = accessOrder.first {
            evicted = remove(key: oldest)
        }
        return evicted
    }

    /// 精确移除指定 key(幂等)。
    @discardableResult
    func remove(key: PageVisualKey) -> PageVisual? {
        guard let visual = storage.removeValue(forKey: key) else { return nil }
        totalBytes -= visual.bytes
        accessOrder.removeAll { $0 == key }
        refreshRasterScales()
        return visual
    }

    /// 清空(purge: hide / 内存压力 / scale / 结构变更)。
    func removeAll() {
        storage.removeAll()
        accessOrder.removeAll()
        totalBytes = 0
        rasterScales.removeAll()
    }

    /// 当前 LRU 序(诊断/测试)。
    var keysForDiag: [PageVisualKey] { accessOrder }

    private func touch(_ key: PageVisualKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func refreshRasterScales() {
        var scales: Set<Int> = []
        for visual in storage.values {
            scales.insert(Int(visual.rasterScale.rounded()))
        }
        rasterScales = scales
    }

    // MARK: - working set 查询

    /// 以 centerPage 为中心的 working set 键(previous/current/next)。
    /// 只包含**真实存在**的相邻页: 页 0 没有 previous、末页没有 next →
    /// 键数不足 3 时 `isWorkingSetReady` 恒 false(边界页不得合成)。
    func workingSetKeys(
        centerPage: Int,
        pageCount: Int,
        displayRevision: UInt64,
        geometry: PageVisualGeometrySignature,
        backingScale: Int,
        languageRevision: UInt64,
        iconEpoch: UInt64
    ) -> [PageVisualKey] {
        var pages: [Int] = []
        if centerPage - 1 >= 0 { pages.append(centerPage - 1) }
        pages.append(centerPage)
        if centerPage + 1 < pageCount { pages.append(centerPage + 1) }
        return pages.map { page in
            PageVisualKey(
                pageIndex: page,
                displayRevision: displayRevision,
                geometry: geometry,
                backingScale: backingScale,
                languageRevision: languageRevision,
                iconEpoch: iconEpoch
            )
        }
    }

    /// working set 全部就绪(激活条件: 相邻页视觉齐备, 且两侧邻居都存在)。
    /// iconEpoch 不作为就绪条件: 迟到图标只触发重建, 不阻止用既有视觉激活。
    func isWorkingSetReady(
        centerPage: Int,
        pageCount: Int,
        displayRevision: UInt64,
        geometry: PageVisualGeometrySignature,
        backingScale: Int,
        languageRevision: UInt64,
        iconEpoch: UInt64
    ) -> Bool {
        let keys = workingSetKeys(
            centerPage: centerPage,
            pageCount: pageCount,
            displayRevision: displayRevision,
            geometry: geometry,
            backingScale: backingScale,
            languageRevision: languageRevision,
            iconEpoch: iconEpoch
        )
        guard keys.count == 3 else { return false }
        return keys.allSatisfy { storage[$0] != nil }
    }

    /// working set 视觉(顺序 = 页序; 缺失项不返回)。
    func workingSetVisuals(
        centerPage: Int,
        pageCount: Int,
        displayRevision: UInt64,
        geometry: PageVisualGeometrySignature,
        backingScale: Int,
        languageRevision: UInt64,
        iconEpoch: UInt64
    ) -> [(page: Int, visual: PageVisual)] {
        let keys = workingSetKeys(
            centerPage: centerPage,
            pageCount: pageCount,
            displayRevision: displayRevision,
            geometry: geometry,
            backingScale: backingScale,
            languageRevision: languageRevision,
            iconEpoch: iconEpoch
        )
        return keys.compactMap { key in
            guard let visual = storage[key] else { return nil }
            return (key.pageIndex, visual)
        }
    }

    /// working set 就绪(忽略 iconEpoch: 任何代数下已构建的视觉都算就绪)。
    func isWorkingSetReadyIgnoringIconEpoch(
        centerPage: Int,
        pageCount: Int,
        displayRevision: UInt64,
        geometry: PageVisualGeometrySignature,
        backingScale: Int,
        languageRevision: UInt64
    ) -> Bool {
        let pages = neighborPages(centerPage: centerPage, pageCount: pageCount)
        guard pages.count == 3 else { return false }
        return pages.allSatisfy { page in
            storedVisual(
                page: page,
                displayRevision: displayRevision,
                geometry: geometry,
                backingScale: backingScale,
                languageRevision: languageRevision
            ) != nil
        }
    }

    /// working set 视觉(忽略 iconEpoch; 缺失项不返回)。
    func workingSetVisualsIgnoringIconEpoch(
        centerPage: Int,
        pageCount: Int,
        displayRevision: UInt64,
        geometry: PageVisualGeometrySignature,
        backingScale: Int,
        languageRevision: UInt64
    ) -> [(page: Int, visual: PageVisual)] {
        neighborPages(centerPage: centerPage, pageCount: pageCount).compactMap { page in
            guard let visual = storedVisual(
                page: page,
                displayRevision: displayRevision,
                geometry: geometry,
                backingScale: backingScale,
                languageRevision: languageRevision
            ) else { return nil }
            return (page, visual)
        }
    }

    private func neighborPages(centerPage: Int, pageCount: Int) -> [Int] {
        var pages: [Int] = []
        if centerPage - 1 >= 0 { pages.append(centerPage - 1) }
        pages.append(centerPage)
        if centerPage + 1 < pageCount { pages.append(centerPage + 1) }
        return pages
    }

    /// 任意代数下匹配数据/几何/scale/语言的已存储视觉。
    private func storedVisual(
        page: Int,
        displayRevision: UInt64,
        geometry: PageVisualGeometrySignature,
        backingScale: Int,
        languageRevision: UInt64
    ) -> PageVisual? {
        for (key, visual) in storage
        where key.pageIndex == page
            && key.displayRevision == displayRevision
            && key.geometry == geometry
            && key.backingScale == backingScale
            && key.languageRevision == languageRevision {
            return visual
        }
        return nil
    }
}
