import Foundation
import Testing
@testable import LaunchCore

// MARK: - 共享测试工具

func appID(_ path: String) -> AppID {
    AppID(path)!
}

func folderID(_ raw: String) -> FolderID {
    FolderID(raw)!
}

func record(_ path: String) -> AppRecord {
    AppRecord(
        id: appID(path),
        url: URL(fileURLWithPath: path),
        bundleIdentifier: nil,
        displayName: "App",
        infoPlistModificationDate: nil,
        iconContentVersion: .empty
    )
}

func catalog(_ paths: [String]) -> CatalogSnapshot {
    CatalogSnapshot(apps: paths.map(record))
}

func config(columns: Int = 4, rows: Int = 3) -> AppConfiguration {
    AppConfiguration(gridColumns: columns, gridRows: rows)
}

func layout(
    pages: [[LayoutItem]],
    folders: [FolderID: FolderRecord] = [:],
    missingApps: [AppID: MissingAppState] = [:]
) -> LayoutSnapshot {
    LayoutSnapshot(pages: pages, folders: folders, missingApps: missingApps)
}

func apps(_ count: Int, prefix: String = "/Applications/App") -> [AppID] {
    (0..<count).map { appID("\(prefix)\($0).app") }
}

// MARK: - DisplayModel

@Suite("DisplayModel 派生")
struct DisplayModelTests {
    @Test("隐藏应用从页面过滤")
    func hiddenAppsFiltered() {
        let ids = apps(3)
        var cfg = config()
        cfg.hiddenAppIDs = [ids[1]]
        let display = DisplayModel(
            catalog: catalog(ids.map(\.rawValue)),
            layout: layout(pages: [ids.map(LayoutItem.app)]),
            config: cfg
        )
        #expect(display.pages == [[.app(ids[0]), .app(ids[2])]])
        #expect(display.visibleAppIDs == [ids[0], ids[2]])
    }

    @Test("缺失应用(墓碑)从显示过滤")
    func missingAppsFiltered() {
        let ids = apps(3)
        let display = DisplayModel(
            catalog: catalog([ids[0].rawValue, ids[2].rawValue]),
            layout: layout(
                pages: [ids.map(LayoutItem.app)],
                missingApps: [ids[1]: MissingAppState(missingSince: Date())]
            ),
            config: config()
        )
        #expect(display.pages == [[.app(ids[0]), .app(ids[2])]])
    }

    @Test("文件夹显示可见子项, 隐藏应用被过滤")
    func folderChildrenFiltered() {
        let ids = apps(4)
        let f = folderID("F")
        var cfg = config()
        cfg.hiddenAppIDs = [ids[1]]
        let display = DisplayModel(
            catalog: catalog(ids.map(\.rawValue)),
            layout: layout(
                pages: [[.folder(f)]],
                folders: [f: FolderRecord(id: f, name: "F", children: [ids[0], ids[1], ids[2]])]
            ),
            config: cfg
        )
        #expect(display.folderVisibleChildren(f) == [ids[0], ids[2]])
    }

    @Test("无可见子项的文件夹从显示隐藏")
    func emptyFolderHidden() {
        let ids = apps(2)
        let f = folderID("F")
        var cfg = config()
        cfg.hiddenAppIDs = [ids[0]]
        let display = DisplayModel(
            catalog: catalog(ids.map(\.rawValue)),
            layout: layout(
                pages: [[.app(ids[1]), .folder(f)]],
                folders: [f: FolderRecord(id: f, name: "F", children: [ids[0]])]
            ),
            config: cfg
        )
        #expect(display.pages == [[.app(ids[1])]])
        #expect(display.folderVisibleChildren(f) == nil)
    }

    @Test("过滤后为空的页被丢弃; 不存在的文件夹项被跳过")
    func emptyPagesDropped() {
        let ids = apps(2)
        let ghost = folderID("Ghost")
        var cfg = config()
        cfg.hiddenAppIDs = [ids[0], ids[1]]
        let display = DisplayModel(
            catalog: catalog(ids.map(\.rawValue)),
            layout: layout(pages: [[.app(ids[0]), .app(ids[1])], [.folder(ghost)], [.app(ids[0])]]),
            config: cfg
        )
        #expect(display.pages.isEmpty)
        #expect(display.flatSlots.isEmpty)
    }

    @Test("pageCapacity = 列 × 行")
    func pageCapacity() {
        let ids = apps(1)
        let display = DisplayModel(
            catalog: catalog(ids.map(\.rawValue)),
            layout: layout(pages: [ids.map(LayoutItem.app)]),
            config: config(columns: 5, rows: 4)
        )
        #expect(display.pageCapacity == 20)
    }

    @Test("超过容量的布局页按容量重新分块")
    func reChunksOverCapacityPages() {
        let ids = apps(30)
        // 单页塞 30 个,容量 12(4×3)→ 显示为 3 页
        let display = DisplayModel(
            catalog: catalog(ids.map(\.rawValue)),
            layout: layout(pages: [ids.map(LayoutItem.app)]),
            config: config(columns: 4, rows: 3)
        )
        #expect(display.pages.count == 3)
        #expect(display.pages[0].count == 12)
        #expect(display.pages[1].count == 12)
        #expect(display.pages[2].count == 6)
        #expect(display.flatSlots.count == 30)
    }

    @Test("可见应用 ID 顺序即显示顺序")
    func visibleAppIDsOrder() {
        let ids = apps(4)
        let f = folderID("F")
        let display = DisplayModel(
            catalog: catalog(ids.map(\.rawValue)),
            layout: layout(
                pages: [[.app(ids[0]), .folder(f), .app(ids[3])]],
                folders: [f: FolderRecord(id: f, name: "F", children: [ids[1], ids[2]])]
            ),
            config: config()
        )
        // 文件夹内应用不占页面槽位, 不计入 visibleAppIDs
        #expect(display.visibleAppIDs == [ids[0], ids[3]])
    }

    @Test("flatSlots/visibleAppIDs 存储化: 直构 init 与派生 init 语义一致")
    func storedFlatSlotsSemantics() {
        let ids = apps(3)
        let f = folderID("F")
        // 直构 init: flatSlots = pages.flatMap, visibleAppIDs 为显示顺序 app
        let direct = DisplayModel(
            pages: [[.app(ids[0]), .folder(f)], [.app(ids[1]), .app(ids[2])]],
            pageCapacity: 2
        )
        #expect(direct.flatSlots == [
            .app(ids[0]), .folder(f), .app(ids[1]), .app(ids[2]),
        ])
        #expect(direct.visibleAppIDs == [ids[0], ids[1], ids[2]])

        // 派生 init: flatSlots 与 pages flatMap 一致(含过滤)
        var cfg = config()
        cfg.hiddenAppIDs = [ids[1]]
        let derived = DisplayModel(
            catalog: catalog(ids.map(\.rawValue)),
            layout: layout(pages: [ids.map(LayoutItem.app)]),
            config: cfg
        )
        #expect(derived.flatSlots == [.app(ids[0]), .app(ids[2])])
        #expect(derived.flatSlots == derived.pages.flatMap { $0 })
        #expect(derived.visibleAppIDs == [ids[0], ids[2]])
    }
}
