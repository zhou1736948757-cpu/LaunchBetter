import Foundation
import Testing
@testable import LaunchCore

// MARK: - 确定性伪随机(SplitMix64)

/// SplitMix64: 无 Foundation 随机源, 同 seed 同序列(供 fixture 可复现)。
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextInt(bound: Int) -> Int {
        Int(next() % UInt64(max(1, bound)))
    }
}

// MARK: - 合成 fixture

/// 确定性合成测试数据: N apps → Catalog + Layout + Config。
///
/// 结构(与规模成比例):
/// - 文件夹: `appCount / 50` 个(每文件夹 2 个可见子项, 来自专用 app 段)
/// - 隐藏应用: `appCount / 50` 个(页面槽位应用中的确定性取样)
/// - 缺失应用(墓碑): `appCount / 50` 个(在页面槽位, 但不在 catalog, 标记 missingApps)
/// - 每页容量 20(5 列 × 4 行)
///
/// 同 seed → 完全相同的结构;不同 seed → 不同结构(PRNG 采样位置)。
struct StressFixture {
    let appCount: Int
    let capacity: Int
    let catalog: CatalogSnapshot
    let layout: LayoutSnapshot
    let config: AppConfiguration
    /// 页面槽位应用(布局顺序, 含缺失; 不含文件夹子项)。
    let pageSlotIDs: [AppID]
    let hiddenApps: [AppID]
    let missingApps: [AppID]
    let folderIDs: [FolderID]
    let folderPositions: Set<Int>
    let folderChildren: [FolderID: [AppID]]
}

enum StressFixtures {
    static func id(_ index: Int) -> AppID {
        appID("/Applications/StressApp\(String(format: "%03d", index)).app")
    }

    static func digits(of appID: AppID) -> String {
        let last = appID.rawValue.split(separator: "/").last ?? ""
        let stem = last.hasSuffix(".app") ? last.dropLast(4) : last
        return String(stem.reversed().prefix { $0.isNumber }.reversed())
    }

    static func displayName(_ appID: AppID) -> String {
        "Stress App \(digits(of: appID))"
    }

    static func bundleID(_ appID: AppID) -> String {
        "com.stress.app\(digits(of: appID))"
    }

    static func localizedName(_ appID: AppID) -> String {
        "压力应用 \(digits(of: appID))"
    }

    static func aliasName(_ appID: AppID) -> String {
        "别名 \(digits(of: appID))"
    }

    /// 生成合成 fixture。`appCount` 必须 ≥ 60。
    static func make(appCount: Int, seed: UInt64 = 42) -> StressFixture {
        precondition(appCount >= 60)
        let capacity = 20
        let folderCount = max(2, appCount / 50)
        let missingCount = max(1, appCount / 50)
        let folderChildCount = 2 * folderCount
        let visiblePageCount = appCount - folderChildCount - missingCount
        precondition(visiblePageCount > 0)

        let allIDs = (0..<appCount).map { id($0) }
        let visiblePageIDs = Array(allIDs[0..<visiblePageCount])
        let missingIDs = Array(allIDs[visiblePageCount..<(visiblePageCount + missingCount)])
        let childIDs = Array(allIDs[(visiblePageCount + missingCount)..<appCount])
        let pageSlotIDs = visiblePageIDs + missingIDs

        var rng = SplitMix64(seed: seed)

        // 隐藏样本: 从可见页面应用取 missingCount 个不同索引。
        var hiddenIndices = Set<Int>()
        while hiddenIndices.count < missingCount {
            hiddenIndices.insert(rng.nextInt(bound: visiblePageCount))
        }
        let hiddenApps = hiddenIndices.sorted().map { visiblePageIDs[$0] }

        // 文件夹槽位: 从总槽位取 folderCount 个不同索引。
        let totalSlots = pageSlotIDs.count + folderCount
        var positionSet = Set<Int>()
        while positionSet.count < folderCount {
            positionSet.insert(rng.nextInt(bound: totalSlots))
        }
        let folderIDs = (0..<folderCount).map { folderID("Folder\(String(format: "%02d", $0))") }

        // 扁平槽位(确定性: 文件夹按升序位置插入, 其余填应用)。
        var slots: [LayoutItem] = []
        var appCursor = 0
        var folderCursor = 0
        for slot in 0..<totalSlots {
            if positionSet.contains(slot) {
                slots.append(.folder(folderIDs[folderCursor]))
                folderCursor += 1
            } else {
                slots.append(.app(pageSlotIDs[appCursor]))
                appCursor += 1
            }
        }

        var pages: [[LayoutItem]] = []
        for start in stride(from: 0, to: slots.count, by: capacity) {
            pages.append(Array(slots[start..<min(start + capacity, slots.count)]))
        }

        var folders: [FolderID: FolderRecord] = [:]
        var folderChildren: [FolderID: [AppID]] = [:]
        for (j, fid) in folderIDs.enumerated() {
            let children = [childIDs[2 * j], childIDs[2 * j + 1]]
            folders[fid] = FolderRecord(id: fid, name: "Folder \(j)", children: children)
            folderChildren[fid] = children
        }

        let missingMap = Dictionary(
            uniqueKeysWithValues: missingIDs.map {
                ($0, MissingAppState(missingSince: Date(timeIntervalSince1970: 1_700_000_000)))
            }
        )

        let catalogApps = allIDs
            .filter { !missingIDs.contains($0) }
            .map { appID in
                AppRecord(
                    id: appID,
                    url: URL(fileURLWithPath: appID.rawValue),
                    bundleIdentifier: bundleID(appID),
                    displayName: displayName(appID),
                    infoPlistModificationDate: nil,
                    iconContentVersion: .empty,
                    localizedNames: ["zh-Hans": localizedName(appID), "en": displayName(appID)]
                )
            }

        var cfg = config(columns: 5, rows: 4)
        cfg.hiddenAppIDs = hiddenApps

        return StressFixture(
            appCount: appCount,
            capacity: capacity,
            catalog: CatalogSnapshot(apps: catalogApps),
            layout: LayoutSnapshot(pages: pages, folders: folders, missingApps: missingMap),
            config: cfg,
            pageSlotIDs: pageSlotIDs,
            hiddenApps: hiddenApps,
            missingApps: missingIDs,
            folderIDs: folderIDs,
            folderPositions: positionSet,
            folderChildren: folderChildren
        )
    }
}

// MARK: - 独立期望推导(不走 DisplayModel 实现)

@Suite("合成压力测试(100/250/500 apps)")
struct StressTests {
    /// 独立推导显示扁平序: 从 fixture 结构事实重建, 不经 DisplayModel。
    private func expectedFlatSlots(_ f: StressFixture) -> [DisplayModel.DisplayItem] {
        let hidden = Set(f.hiddenApps)
        let missing = Set(f.missingApps)
        var appCursor = 0
        var folderCursor = 0
        var out: [DisplayModel.DisplayItem] = []
        for slot in 0..<(f.pageSlotIDs.count + f.folderIDs.count) {
            if f.folderPositions.contains(slot) {
                out.append(.folder(f.folderIDs[folderCursor]))
                folderCursor += 1
            } else {
                let id = f.pageSlotIDs[appCursor]
                appCursor += 1
                if !hidden.contains(id) && !missing.contains(id) {
                    out.append(.app(id))
                }
            }
        }
        return out
    }

    private func expectedVisibleFolderPayloads(_ f: StressFixture) -> [FolderID: [AppID]] {
        let hidden = Set(f.hiddenApps)
        let missing = Set(f.missingApps)
        var out: [FolderID: [AppID]] = [:]
        for (fid, children) in f.folderChildren {
            let visible = children.filter { !hidden.contains($0) && !missing.contains($0) }
            if !visible.isEmpty {
                out[fid] = visible
            }
        }
        return out
    }

    private func appIDs(_ slots: [DisplayModel.DisplayItem]) -> [AppID] {
        slots.compactMap { item in
            if case .app(let id) = item { return id }
            return nil
        }
    }

    private func folderIDs(_ slots: [DisplayModel.DisplayItem]) -> [FolderID] {
        slots.compactMap { item in
            if case .folder(let id) = item { return id }
            return nil
        }
    }

    private func assertUniqueApps(_ display: DisplayModel) {
        var seen = Set<AppID>()
        for slot in display.flatSlots {
            if case .app(let id) = slot {
                #expect(seen.insert(id).inserted)
            }
        }
    }

    private static func changedPages(
        _ old: [[DisplayModel.DisplayItem]],
        _ new: [[DisplayModel.DisplayItem]]
    ) -> Set<Int> {
        var changed = Set<Int>()
        let count = max(old.count, new.count)
        for index in 0..<count {
            let oldPage = index < old.count ? old[index] : []
            let newPage = index < new.count ? new[index] : []
            if oldPage != newPage {
                changed.insert(index)
            }
        }
        return changed
    }

    // MARK: - DisplayModel 派生

    @Test("DisplayModel 派生: 页数/容量/扁平序/过滤", arguments: [100, 250, 500])
    func displayModelDerivation(appCount: Int) {
        let f = StressFixtures.make(appCount: appCount)
        let display = DisplayModel(catalog: f.catalog, layout: f.layout, config: f.config)
        let expected = expectedFlatSlots(f)

        #expect(display.pageCapacity == f.capacity)
        #expect(!display.pages.isEmpty)
        #expect(display.pages.allSatisfy { !$0.isEmpty })
        #expect(display.pages.allSatisfy { $0.count <= f.capacity })

        let expectedPageCount = (expected.count + f.capacity - 1) / f.capacity
        #expect(display.pages.count == expectedPageCount)

        // 扁平序与独立推导一致。
        #expect(display.flatSlots == expected)

        // 身份唯一。
        assertUniqueApps(display)

        // 隐藏 / 缺失被过滤。
        for id in f.hiddenApps {
            #expect(!display.flatSlots.contains(.app(id)))
        }
        for id in f.missingApps {
            #expect(!display.flatSlots.contains(.app(id)))
        }

        // 文件夹 payload 与独立推导一致。
        #expect(display.folderChildrenPayload == expectedVisibleFolderPayloads(f))

        // visibleAppIDs == 扁平中的 app 顺序。
        #expect(display.visibleAppIDs == appIDs(expected))

        // 文件夹身份集 == 布局中的文件夹集。
        #expect(Set(folderIDs(display.flatSlots)) == Set(f.folderIDs))
    }

    // MARK: - SearchIndex

    @Test("SearchIndex: 全量索引与查询规模正确性", arguments: [100, 250, 500])
    func searchIndexScale(appCount: Int) {
        let f = StressFixtures.make(appCount: appCount)
        var index = SearchIndex()
        for record in f.catalog.apps {
            index.index(
                record.id,
                displayName: record.displayName,
                bundleIdentifier: record.bundleIdentifier,
                customName: StressFixtures.aliasName(record.id)
            )
        }
        #expect(index.count == f.catalog.apps.count)

        // 空查询 → 全部按 rawValue 排序(%03d 保证字典序 == 索引序)。
        let all = index.query("")
        #expect(all == f.catalog.apps.map(\.id))

        // 通用词命中全部。
        #expect(index.query("stress") == f.catalog.apps.map(\.id))
        #expect(index.query("别名") == f.catalog.apps.map(\.id))

        // 精确命中单条(displayName/bundleID 不含 "app000" 之外的命中)。
        #expect(index.query("app000") == [StressFixtures.id(0)])

        // 部分命中: 独立过滤 + 严格升序 + 无重复。
        let expected = f.catalog.apps.filter { record in
            record.displayName.lowercased().contains("9")
                || (record.bundleIdentifier?.lowercased().contains("9") ?? false)
        }.map(\.id)
        let partial = index.query("9")
        #expect(partial == expected)
        #expect(partial == partial.sorted { $0.rawValue < $1.rawValue })
        #expect(Set(partial).count == partial.count)
    }

    @Test("本地化元数据: 大样本解析确定性", arguments: [100, 250, 500])
    func localizedMetadataScale(appCount: Int) {
        let f = StressFixtures.make(appCount: appCount)
        for record in f.catalog.apps {
            #expect(
                record.localizedDisplayName(language: .simplifiedChinese, systemPreferredLanguages: [])
                    == StressFixtures.localizedName(record.id)
            )
            #expect(
                record.localizedDisplayName(language: .english, systemPreferredLanguages: [])
                    == StressFixtures.displayName(record.id)
            )
            #expect(
                record.localizedDisplayName(
                    language: .system, systemPreferredLanguages: ["zh-Hans-CN"]
                ) == StressFixtures.localizedName(record.id)
            )
        }
    }

    // MARK: - LayoutTransaction

    @Test("跨页 reorder: 大布局确定性结果", arguments: [100, 250, 500])
    func crossPageReorder(appCount: Int) {
        let f = StressFixtures.make(appCount: appCount)
        let display = DisplayModel(catalog: f.catalog, layout: f.layout, config: f.config)
        let lastPage = display.pages.count - 1
        let source = f.pageSlotIDs[0]

        let result = try! #require(
            LayoutTransaction.drop(
                display: display,
                source: .app(source),
                destination: LayoutTransaction.Destination(page: lastPage, slot: 0)
            )
        )

        var expected = display.flatSlots
        let sourceIndex = try! #require(expected.firstIndex(of: .app(source)))
        expected.remove(at: sourceIndex)
        let target = min(max(0, lastPage * display.pageCapacity), expected.count)
        expected.insert(.app(source), at: target)

        #expect(result.display.flatSlots == expected)
        #expect(result.display.pages.count == display.pages.count)
        #expect(result.display.pages.allSatisfy { $0.count <= display.pageCapacity })
        #expect(Set(result.display.flatSlots) == Set(display.flatSlots))
        #expect(result.display.flatSlots.count == display.flatSlots.count)
        assertUniqueApps(result.display)
        #expect(result.changedPages == Self.changedPages(display.pages, result.display.pages))
    }

    @Test("跨页拖动文件夹: 身份保持且子项 payload 不变", arguments: [100, 250, 500])
    func crossPageFolderDrag(appCount: Int) {
        let f = StressFixtures.make(appCount: appCount)
        let display = DisplayModel(catalog: f.catalog, layout: f.layout, config: f.config)
        let folder = f.folderIDs[0]
        let lastPage = display.pages.count - 1

        let result = try! #require(
            LayoutTransaction.drop(
                display: display,
                source: .folder(folder),
                destination: LayoutTransaction.Destination(page: lastPage, slot: 0)
            )
        )

        var expected = display.flatSlots
        let sourceIndex = try! #require(expected.firstIndex(of: .folder(folder)))
        expected.remove(at: sourceIndex)
        let target = min(max(0, lastPage * display.pageCapacity), expected.count)
        expected.insert(.folder(folder), at: target)

        #expect(result.display.flatSlots == expected)
        #expect(result.display.folderVisibleChildren(folder) == display.folderVisibleChildren(folder))
        #expect(Set(folderIDs(result.display.flatSlots)) == Set(folderIDs(display.flatSlots)))
        assertUniqueApps(result.display)
    }

    @Test("moveIntoFolder: 大布局 app 离开槽位进入文件夹", arguments: [100, 250, 500])
    func moveIntoFolderScale(appCount: Int) {
        let f = StressFixtures.make(appCount: appCount)
        let display = DisplayModel(catalog: f.catalog, layout: f.layout, config: f.config)
        let folder = f.folderIDs[0]
        let app = f.pageSlotIDs[0]

        let result = try! #require(
            LayoutTransaction.moveIntoFolder(display: display, app: app, folder: folder, at: 0)
        )

        #expect(!result.display.flatSlots.contains(.app(app)))
        #expect(result.display.flatSlots.contains(.folder(folder)))
        #expect(
            result.display.folderVisibleChildren(folder)
                == [app] + (display.folderVisibleChildren(folder) ?? [])
        )
        assertUniqueApps(result.display)
        #expect(result.display.pages.allSatisfy { $0.count <= display.pageCapacity })
        #expect(result.mutation == .addToFolder(app: app, folder: folder, at: 0))
        #expect(result.changedPages == Self.changedPages(display.pages, result.display.pages))
    }

    @Test("moveOutOfFolder: 大布局子项成为页面槽位", arguments: [100, 250, 500])
    func moveOutOfFolderScale(appCount: Int) {
        let f = StressFixtures.make(appCount: appCount)
        let display = DisplayModel(catalog: f.catalog, layout: f.layout, config: f.config)
        let folder = f.folderIDs[0]
        let children = try! #require(display.folderVisibleChildren(folder))
        let app = try! #require(children.first)
        let lastPage = display.pages.count - 1

        let result = try! #require(
            LayoutTransaction.moveOutOfFolder(
                display: display,
                app: app,
                from: folder,
                to: LayoutTransaction.Destination(page: lastPage, slot: 0)
            )
        )

        #expect(result.display.flatSlots.contains(.app(app)))
        #expect(result.display.folderVisibleChildren(folder) == Array(children.dropFirst()))
        #expect(result.display.flatSlots.contains(.folder(folder)))

        let target = min(max(0, lastPage * display.pageCapacity), display.flatSlots.count)
        var expected = display.flatSlots
        expected.insert(.app(app), at: target)
        #expect(result.display.flatSlots == expected)

        assertUniqueApps(result.display)
        #expect(result.mutation == .moveOutOfFolder(app: app, from: folder, toDisplayIndex: target))
        #expect(result.changedPages == Self.changedPages(display.pages, result.display.pages))
    }

    // MARK: - Snapshot 往返

    @Test("snapshot 构建与编码往返: 大布局不崩溃且等值", arguments: [100, 250, 500])
    func snapshotRoundtrip(appCount: Int) throws {
        let f = StressFixtures.make(appCount: appCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let layoutData = try encoder.encode(f.layout)
        let decodedLayout = try decoder.decode(LayoutSnapshot.self, from: layoutData)
        #expect(decodedLayout == f.layout)
        #expect(decodedLayout.schemaVersion == LayoutSnapshot.currentSchemaVersion)

        let catalogData = try encoder.encode(f.catalog)
        let decodedCatalog = try decoder.decode(CatalogSnapshot.self, from: catalogData)
        #expect(decodedCatalog == f.catalog)
        #expect(decodedCatalog.schemaVersion == CatalogSnapshot.currentSchemaVersion)

        // 引用身份规模正确: 所有 app 恰被布局引用一次(页面 + 文件夹子项)。
        #expect(f.layout.referencedAppIDs.count == appCount)
        #expect(f.layout.flatCount == f.pageSlotIDs.count + f.folderIDs.count)
    }

    // MARK: - 确定性

    @Test("同 seed 同结果; 不同 seed 不同结构", arguments: [100, 250, 500])
    func deterministicSameSeed(appCount: Int) {
        let a = StressFixtures.make(appCount: appCount, seed: 7)
        let b = StressFixtures.make(appCount: appCount, seed: 7)
        #expect(a.layout == b.layout)
        #expect(a.catalog == b.catalog)
        #expect(a.hiddenApps == b.hiddenApps)
        #expect(a.folderPositions == b.folderPositions)

        let displayA = DisplayModel(catalog: a.catalog, layout: a.layout, config: a.config)
        let displayB = DisplayModel(catalog: b.catalog, layout: b.layout, config: b.config)
        #expect(displayA == displayB)

        var indexA = SearchIndex()
        var indexB = SearchIndex()
        for record in a.catalog.apps {
            indexA.index(
                record.id, displayName: record.displayName,
                bundleIdentifier: record.bundleIdentifier, customName: nil
            )
            indexB.index(
                record.id, displayName: record.displayName,
                bundleIdentifier: record.bundleIdentifier, customName: nil
            )
        }
        #expect(indexA.query("stress") == indexB.query("stress"))
        #expect(indexA.query("app0") == indexB.query("app0"))

        let dropA = LayoutTransaction.drop(
            display: displayA,
            source: .app(a.pageSlotIDs[0]),
            destination: LayoutTransaction.Destination(page: displayA.pages.count - 1, slot: 0)
        )
        let dropB = LayoutTransaction.drop(
            display: displayB,
            source: .app(b.pageSlotIDs[0]),
            destination: LayoutTransaction.Destination(page: displayB.pages.count - 1, slot: 0)
        )
        #expect(dropA == dropB)

        // 不同 seed → 结构不同。
        let c = StressFixtures.make(appCount: appCount, seed: 8)
        let displayC = DisplayModel(catalog: c.catalog, layout: c.layout, config: c.config)
        #expect(displayA != displayC)
    }

    // MARK: - 时间预算(防御性上限, 防二次复杂度回归)

    @Test("压力规模耗时防御性上限(< 5s/规模)", arguments: [100, 250, 500])
    func timeBudget(appCount: Int) {
        let clock = ContinuousClock()
        let start = clock.now

        let f = StressFixtures.make(appCount: appCount)
        let display = DisplayModel(catalog: f.catalog, layout: f.layout, config: f.config)
        var index = SearchIndex()
        for record in f.catalog.apps {
            index.index(
                record.id, displayName: record.displayName,
                bundleIdentifier: record.bundleIdentifier, customName: nil
            )
        }
        _ = index.query("stress")
        _ = index.query("9")
        _ = LayoutTransaction.drop(
            display: display,
            source: .app(f.pageSlotIDs[0]),
            destination: LayoutTransaction.Destination(page: display.pages.count - 1, slot: 0)
        )

        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        #expect(seconds < 5.0)
    }
}
