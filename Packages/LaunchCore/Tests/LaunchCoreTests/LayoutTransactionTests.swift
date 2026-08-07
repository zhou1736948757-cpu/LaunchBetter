import Foundation
import Testing
@testable import LaunchCore

@Suite("LayoutTransaction 拖拽事务")
struct LayoutTransactionTests {
    // 页面容量 4×3=12
    private let capacity = 12

    private func makeDisplay(
        pages: [[LayoutItem]] = [],
        folders: [FolderID: FolderRecord] = [:],
        missingApps: [AppID: MissingAppState] = [:]
    ) -> DisplayModel {
        return DisplayModel(
            catalog: catalog(apps(16).map(\.rawValue)),
            layout: layout(pages: pages, folders: folders, missingApps: missingApps),
            config: config(columns: 4, rows: 3)
        )
    }

    private func pageOfApps(_ ids: [AppID]) -> [LayoutItem] {
        ids.map(LayoutItem.app)
    }

    // MARK: - Preview

    @Test("同页预览: gap 位置与被挤动项数")
    func samePagePreview() {
        let ids = apps(12)
        let display = makeDisplay(pages: [pageOfApps(ids)])
        let preview = LayoutTransaction.preview(
            display: display,
            source: .app(ids[2]),
            destination: LayoutTransaction.Destination(page: 0, slot: 5)
        )
        let p = try! #require(preview)
        #expect(p.sourceIndex == 2)
        #expect(p.gapIndex == 5)
        #expect(p.displacedCount == 3)
        #expect(p.slots.count == 11)
    }

    @Test("跨页预览: gap 进入目标页")
    func crossPagePreview() {
        let ids = apps(16)
        let display = makeDisplay(pages: [pageOfApps(Array(ids[0..<12])), pageOfApps(Array(ids[12..<16]))])
        let preview = LayoutTransaction.preview(
            display: display,
            source: .app(ids[0]),
            destination: LayoutTransaction.Destination(page: 1, slot: 0)
        )
        let p = try! #require(preview)
        #expect(p.sourceIndex == 0)
        #expect(p.gapIndex == 12)
        #expect(p.displacedCount == 12)
    }

    @Test("目标槽位越界时 gap 收尾(确定性 clamp)")
    func previewClamp() {
        let ids = apps(4)
        let display = makeDisplay(pages: [pageOfApps(ids)])
        let preview = LayoutTransaction.preview(
            display: display,
            source: .app(ids[0]),
            destination: LayoutTransaction.Destination(page: 5, slot: 99)
        )
        let p = try! #require(preview)
        #expect(p.gapIndex == 3)
    }

    @Test("源项不在显示中(隐藏/缺失)→ nil")
    func hiddenSourceNil() {
        let ids = apps(3)
        var cfg = config(columns: 4, rows: 3)
        cfg.hiddenAppIDs = [ids[1]]
        let display = DisplayModel(
            catalog: catalog(ids.map(\.rawValue)),
            layout: layout(pages: [pageOfApps(ids)]),
            config: cfg
        )
        let preview = LayoutTransaction.preview(
            display: display,
            source: .app(ids[1]),
            destination: LayoutTransaction.Destination(page: 0, slot: 0)
        )
        #expect(preview == nil)
    }

    // MARK: - Drop

    @Test("同页 drop: 确定性最终顺序")
    func samePageDrop() {
        let ids = apps(12)
        let display = makeDisplay(pages: [pageOfApps(ids)])
        let result = LayoutTransaction.drop(
            display: display,
            source: .app(ids[2]),
            destination: LayoutTransaction.Destination(page: 0, slot: 5)
        )
        let r = try! #require(result)
        let expected = [ids[0], ids[1], ids[3], ids[4], ids[5], ids[2], ids[6], ids[7], ids[8], ids[9], ids[10], ids[11]]
        #expect(r.display.pages == [expected.map(DisplayModel.DisplayItem.app)])
        #expect(r.changedPages == [0])
        #expect(r.mutation == .reorder(item: .app(ids[2]), toDisplayIndex: 5))
    }

    @Test("跨页 drop: 移动到目标页并重新分块")
    func crossPageDrop() {
        let ids = apps(16)
        let display = makeDisplay(pages: [
            pageOfApps(Array(ids[0..<12])),
            pageOfApps(Array(ids[12..<16])),
        ])
        let result = LayoutTransaction.drop(
            display: display,
            source: .app(ids[0]),
            destination: LayoutTransaction.Destination(page: 1, slot: 0)
        )
        let r = try! #require(result)
        #expect(r.display.pages[0] == Array(ids[1...12]).map(DisplayModel.DisplayItem.app))
        #expect(r.display.pages[1] == [ids[0], ids[13], ids[14], ids[15]].map(DisplayModel.DisplayItem.app))
        #expect(r.changedPages == [0, 1])
    }

    @Test("drop 到原位置: 无变化, changedPages 为空")
    func noOpDrop() {
        let ids = apps(12)
        let display = makeDisplay(pages: [pageOfApps(ids)])
        let result = LayoutTransaction.drop(
            display: display,
            source: .app(ids[2]),
            destination: LayoutTransaction.Destination(page: 0, slot: 2)
        )
        let r = try! #require(result)
        #expect(r.display == display)
        #expect(r.changedPages.isEmpty)
    }

    @Test("确定性: 相同输入多次调用结果相等")
    func deterministicDrop() {
        let ids = apps(16)
        let display = makeDisplay(pages: [
            pageOfApps(Array(ids[0..<12])),
            pageOfApps(Array(ids[12..<16])),
        ])
        let a = LayoutTransaction.drop(
            display: display,
            source: .app(ids[5]),
            destination: LayoutTransaction.Destination(page: 1, slot: 2)
        )
        let b = LayoutTransaction.drop(
            display: display,
            source: .app(ids[5]),
            destination: LayoutTransaction.Destination(page: 1, slot: 2)
        )
        #expect(a == b)
    }

    @Test("拖文件夹为整体: 子项身份保持")
    func folderDraggedAsUnit() {
        let ids = apps(4)
        let f = folderID("F")
        let display = makeDisplay(
            pages: [[.app(ids[0]), .folder(f), .app(ids[1])]],
            folders: [f: FolderRecord(id: f, name: "F", children: [ids[2], ids[3]])]
        )
        let result = LayoutTransaction.drop(
            display: display,
            source: .folder(f),
            destination: LayoutTransaction.Destination(page: 0, slot: 0)
        )
        let r = try! #require(result)
        #expect(r.display.pages[0] == [
            .folder(f, visibleChildren: [ids[2], ids[3]]),
            .app(ids[0]),
            .app(ids[1]),
        ])
    }

    // MARK: - Folder membership

    @Test("拖入文件夹: 应用离开页面槽, 进入 children, 无重复")
    func moveIntoFolder() {
        let ids = apps(4)
        let f = folderID("F")
        let display = makeDisplay(
            pages: [[.app(ids[0]), .folder(f), .app(ids[2])]],
            folders: [f: FolderRecord(id: f, name: "F", children: [ids[1]])]
        )
        let result = LayoutTransaction.moveIntoFolder(
            display: display, app: ids[2], folder: f, at: 0
        )
        let r = try! #require(result)
        #expect(r.display.pages[0] == [
            .app(ids[0]),
            .folder(f, visibleChildren: [ids[2], ids[1]]),
        ])
        #expect(r.mutation == .addToFolder(app: ids[2], folder: f, at: 0))
        // 无重复: 显示槽位中 ids[2] 只出现在文件夹子项
        #expect(r.display.flatSlots.compactMap { item -> AppID? in
            switch item {
            case .app(let id): return id
            case .folder: return nil
            }
        }.filter { $0 == ids[2] }.isEmpty)
    }

    @Test("拖入文件夹: at 越界 clamp 到末尾")
    func moveIntoFolderClamp() {
        let ids = apps(3)
        let f = folderID("F")
        let display = makeDisplay(
            pages: [[.app(ids[0]), .folder(f)]],
            folders: [f: FolderRecord(id: f, name: "F", children: [ids[1]])]
        )
        let result = LayoutTransaction.moveIntoFolder(
            display: display, app: ids[0], folder: f, at: 99
        )
        let r = try! #require(result)
        #expect(r.display.folderVisibleChildren(f) == [ids[1], ids[0]])
        #expect(r.mutation == .addToFolder(app: ids[0], folder: f, at: 1))
    }

    @Test("已在文件夹内的应用不能再次拖入 → nil")
    func moveIntoFolderAlreadyInside() {
        let ids = apps(2)
        let f = folderID("F")
        let display = makeDisplay(
            pages: [[.folder(f)]],
            folders: [f: FolderRecord(id: f, name: "F", children: [ids[0], ids[1]])]
        )
        let result = LayoutTransaction.moveIntoFolder(
            display: display, app: ids[0], folder: f, at: 0
        )
        #expect(result == nil)
    }

    @Test("拖出文件夹: 应用插入页面, 文件夹保留")
    func moveOutOfFolder() {
        let ids = apps(3)
        let f = folderID("F")
        let display = makeDisplay(
            pages: [[.app(ids[0]), .folder(f)]],
            folders: [f: FolderRecord(id: f, name: "F", children: [ids[1], ids[2]])]
        )
        let result = LayoutTransaction.moveOutOfFolder(
            display: display, app: ids[2], from: f, to: LayoutTransaction.Destination(page: 0, slot: 0)
        )
        let r = try! #require(result)
        #expect(r.display.pages[0] == [
            .app(ids[2]),
            .app(ids[0]),
            .folder(f, visibleChildren: [ids[1]]),
        ])
        #expect(r.mutation == .moveOutOfFolder(app: ids[2], from: f, toDisplayIndex: 0))
    }

    @Test("拖出最后一个可见子项: 文件夹从显示隐藏")
    func moveOutLastChildHidesFolder() {
        let ids = apps(2)
        let f = folderID("F")
        let display = makeDisplay(
            pages: [[.app(ids[0]), .folder(f)]],
            folders: [f: FolderRecord(id: f, name: "F", children: [ids[1]])]
        )
        let result = LayoutTransaction.moveOutOfFolder(
            display: display, app: ids[1], from: f, to: LayoutTransaction.Destination(page: 1, slot: 0)
        )
        let r = try! #require(result)
        #expect(r.display.folderVisibleChildren(f) == nil)
        #expect(r.display.pages[0] == [.app(ids[0]), .app(ids[1])])
    }

    @Test("未知文件夹或非成员应用 → nil")
    func moveOutUnknown() {
        let ids = apps(2)
        let f = folderID("F")
        let ghost = folderID("Ghost")
        let display = makeDisplay(
            pages: [[.folder(f)]],
            folders: [f: FolderRecord(id: f, name: "F", children: [ids[0]])]
        )
        #expect(LayoutTransaction.moveOutOfFolder(
            display: display, app: ids[1], from: f,
            to: LayoutTransaction.Destination(page: 0, slot: 0)
        ) == nil)
        #expect(LayoutTransaction.moveOutOfFolder(
            display: display, app: ids[0], from: ghost,
            to: LayoutTransaction.Destination(page: 0, slot: 0)
        ) == nil)
    }
}
