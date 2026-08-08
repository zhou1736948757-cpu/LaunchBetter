import Foundation
import Testing
@testable import LaunchCore

@Suite("LayoutEditor 布局变更应用")
struct LayoutEditorTests {
    private let capacity = 12

    private func makeDisplay(
        layout: LayoutSnapshot,
        hidden: [AppID] = []
    ) -> DisplayModel {
        var cfg = config(columns: 4, rows: 3)
        cfg.hiddenAppIDs = hidden
        return DisplayModel(
            catalog: catalog(apps(16).map(\.rawValue)),
            layout: layout,
            config: cfg
        )
    }

    @Test("reorder: 同页移动, 隐藏应用保持原位")
    func reorderWithHiddenStays() throws {
        let ids = apps(5)
        let hidden = ids[2]
        let layout = layout(pages: [ids.map(LayoutItem.app)])
        let display = makeDisplay(layout: layout, hidden: [hidden])
        // 显示: [0,1,3,4]; 把 0 移到显示索引 3
        let mutation = LayoutTransaction.LayoutMutation.reorder(
            item: .app(ids[0]), toDisplayIndex: 3
        )
        let result = try #require(LayoutEditor.apply(mutation, to: layout, display: display))
        // 契约: toDisplayIndex 是移除源项后的 gap 位置。gap@3(剩余 [1,3,4] 的末尾)
        // → 布局: [1,2,3,4,0] — 隐藏的 2 保持原布局位置; 0 落在显示槽 3
        #expect(result.pages[0] == [.app(ids[1]), .app(ids[2]), .app(ids[3]), .app(ids[4]), .app(ids[0])])
        // 新显示空间: [1,3,4,0] — 0 位于显示槽 3
        let newDisplay = DisplayModel(
            catalog: catalog(apps(5).map(\.rawValue)),
            layout: result,
            config: { var c = config(columns: 4, rows: 3); c.hiddenAppIDs = [ids[2]]; return c }()
        )
        #expect(newDisplay.flatSlots == [.app(ids[1]), .app(ids[3]), .app(ids[4]), .app(ids[0])])
    }

    @Test("reorder: 目标越界追加末尾")
    func reorderBeyondEnd() throws {
        let ids = apps(4)
        let layout = layout(pages: [ids.map(LayoutItem.app)])
        let display = makeDisplay(layout: layout)
        let mutation = LayoutTransaction.LayoutMutation.reorder(
            item: .app(ids[0]), toDisplayIndex: 99
        )
        let result = try #require(LayoutEditor.apply(mutation, to: layout, display: display))
        #expect(result.pages[0] == [.app(ids[1]), .app(ids[2]), .app(ids[3]), .app(ids[0])])
    }

    @Test("reorder: 跨页后按容量重分块")
    func reorderChunksPages() throws {
        let ids = apps(16)
        let layout = layout(pages: [
            Array(ids[0..<12]).map(LayoutItem.app),
            Array(ids[12..<16]).map(LayoutItem.app),
        ])
        let display = makeDisplay(layout: layout)
        // 把页1首个移到页2开头(显示索引 12)
        let mutation = LayoutTransaction.LayoutMutation.reorder(
            item: .app(ids[0]), toDisplayIndex: 12
        )
        let result = try #require(LayoutEditor.apply(mutation, to: layout, display: display))
        #expect(result.pages.count == 2)
        // 契约: gap@剩余列表索引12 = 第 12 个剩余项(13)之前 → 0 落在 12 与 13 之间
        #expect(result.pages[0] == Array(ids[1...12]).map { LayoutItem.app($0) })
        #expect(result.pages[1] == [ids[0], ids[13], ids[14], ids[15]].map { LayoutItem.app($0) })
    }

    @Test("reorder: 源项不在布局 → nil")
    func reorderInvalid() throws {
        let ids = apps(3)
        let layout = layout(pages: [ids.map(LayoutItem.app)])
        let display = makeDisplay(layout: layout)
        let mutation = LayoutTransaction.LayoutMutation.reorder(
            item: .app(appID("/Applications/Missing.app")), toDisplayIndex: 0
        )
        #expect(LayoutEditor.apply(mutation, to: layout, display: display) == nil)
    }

    @Test("addToFolder: 隐藏子项保持原位")
    func addToFolderKeepsHiddenChildren() throws {
        let ids = apps(6)
        let folderID = folderID("F")
        let hiddenChild = ids[2]
        let layout = layout(
            pages: [[.app(ids[0]), .app(ids[5]), .folder(folderID)]],
            folders: [folderID: FolderRecord(id: folderID, name: "F", children: [hiddenChild, ids[1]])]
        )
        let display = makeDisplay(layout: layout, hidden: [hiddenChild])
        // 显示可见子项: [1]; 把 5 加到可见索引 0 → 隐藏子项 2 之前插入 5
        let mutation = LayoutTransaction.LayoutMutation.addToFolder(app: ids[5], folder: folderID, at: 0)
        let result = try #require(LayoutEditor.apply(mutation, to: layout, display: display))
        #expect(result.folders[folderID]?.children == [hiddenChild, ids[5], ids[1]])
        // 5 已从页面移除
        let pageApps = result.pages[0].compactMap { item -> AppID? in
            if case .app(let id) = item { return id }
            return nil
        }
        #expect(!pageApps.contains(ids[5]))
    }

    @Test("addToFolder: at 越界 clamp 到末尾")
    func addToFolderClamp() throws {
        let ids = apps(3)
        let folderID = folderID("F")
        let layout = layout(
            pages: [[.app(ids[0]), .folder(folderID)]],
            folders: [folderID: FolderRecord(id: folderID, name: "F", children: [ids[1]])]
        )
        let display = makeDisplay(layout: layout)
        let mutation = LayoutTransaction.LayoutMutation.addToFolder(app: ids[0], folder: folderID, at: 99)
        let result = try #require(LayoutEditor.apply(mutation, to: layout, display: display))
        #expect(result.folders[folderID]?.children == [ids[1], ids[0]])
    }

    @Test("addToFolder: 应用已在文件夹内 → nil")
    func addToFolderAlreadyInside() throws {
        let ids = apps(2)
        let folderID = folderID("F")
        let layout = layout(
            pages: [[.folder(folderID)]],
            folders: [folderID: FolderRecord(id: folderID, name: "F", children: [ids[0], ids[1]])]
        )
        let display = makeDisplay(layout: layout)
        let mutation = LayoutTransaction.LayoutMutation.addToFolder(app: ids[0], folder: folderID, at: 0)
        #expect(LayoutEditor.apply(mutation, to: layout, display: display) == nil)
    }

    @Test("moveOutOfFolder: 插入指定显示索引")
    func moveOutOfFolder() throws {
        let ids = apps(4)
        let folderID = folderID("F")
        let layout = layout(
            pages: [[.app(ids[0]), .folder(folderID), .app(ids[3])]],
            folders: [folderID: FolderRecord(id: folderID, name: "F", children: [ids[1], ids[2]])]
        )
        let display = makeDisplay(layout: layout)
        // 显示: [0, F, 3]; 把 2 移到显示索引 0
        let mutation = LayoutTransaction.LayoutMutation.moveOutOfFolder(
            app: ids[2], from: folderID, toDisplayIndex: 0
        )
        let result = try #require(LayoutEditor.apply(mutation, to: layout, display: display))
        #expect(result.folders[folderID]?.children == [ids[1]])
        #expect(result.pages[0] == [.app(ids[2]), .app(ids[0]), .folder(folderID), .app(ids[3])])
    }

    @Test("renameFolder")
    func renameFolder() throws {
        let ids = apps(2)
        let folderID = folderID("F")
        let layout = layout(
            pages: [[.folder(folderID)]],
            folders: [folderID: FolderRecord(id: folderID, name: "F", children: [ids[0], ids[1]])]
        )
        let mutation = LayoutTransaction.LayoutMutation.renameFolder(folderID, newName: "开发工具")
        let result = try #require(LayoutEditor.apply(mutation, to: layout, display: makeDisplay(layout: layout)))
        #expect(result.folders[folderID]?.name == "开发工具")
    }

    @Test("createFolder: 合并 ≥2 应用, 文件夹在最早位置")
    func createFolder() throws {
        let ids = apps(5)
        let layout = layout(pages: [ids.map(LayoutItem.app)])
        let display = makeDisplay(layout: layout)
        let result = try #require(LayoutEditor.createFolder(
            in: layout, display: display, name: "工具", appIDs: [ids[1], ids[3]]
        ))
        #expect(result.folderID.rawValue.hasPrefix("F-"))
        let folder = try #require(result.layout.folders[result.folderID])
        #expect(folder.name == "工具")
        #expect(folder.children == [ids[1], ids[3]])
        #expect(result.layout.pages[0] == [
            .app(ids[0]), .folder(result.folderID), .app(ids[2]), .app(ids[4])
        ])
    }

    @Test("createFolder: 空列表或含非槽位应用 → nil")
    func createFolderInvalid() throws {
        let ids = apps(3)
        let layout = layout(pages: [ids.map(LayoutItem.app)])
        let display = makeDisplay(layout: layout)
        #expect(LayoutEditor.createFolder(
            in: layout, display: display, name: "X", appIDs: []
        ) == nil)
        #expect(LayoutEditor.createFolder(
            in: layout, display: display, name: "X",
            appIDs: [ids[0], appID("/Applications/NotInLayout.app")]
        ) == nil)
        // 单应用文件夹允许(UX: 新建后拖入更多)
        #expect(LayoutEditor.createFolder(
            in: layout, display: display, name: "X", appIDs: [ids[0]]
        ) != nil)
    }

    @Test("dissolveFolder: children 插回原显示位置")
    func dissolveFolder() throws {
        let ids = apps(5)
        let folderID = folderID("F")
        let layout = layout(
            pages: [[.app(ids[0]), .folder(folderID), .app(ids[4])]],
            folders: [folderID: FolderRecord(id: folderID, name: "F", children: [ids[1], ids[2], ids[3]])]
        )
        let display = makeDisplay(layout: layout)
        let result = try #require(LayoutEditor.dissolveFolder(
            in: layout, display: display, id: folderID
        ))
        #expect(result.folders[folderID] == nil)
        #expect(result.pages[0] == [
            .app(ids[0]), .app(ids[1]), .app(ids[2]), .app(ids[3]), .app(ids[4])
        ])
    }

    @Test("dissolveFolder: 未知文件夹或不在显示 → nil")
    func dissolveInvalid() throws {
        let ids = apps(2)
        let f = folderID("F")
        let layout = layout(
            pages: [[.app(ids[0]), .folder(f)]],
            folders: [f: FolderRecord(id: f, name: "F", children: [ids[1]])]
        )
        let display = makeDisplay(layout: layout)
        #expect(LayoutEditor.dissolveFolder(
            in: layout, display: display, id: folderID("Ghost")
        ) == nil)
    }

    @Test("全量确定性: 相同输入相同输出")
    func deterministic() throws {
        let ids = apps(16)
        let layout = layout(pages: [
            Array(ids[0..<12]).map(LayoutItem.app),
            Array(ids[12..<16]).map(LayoutItem.app),
        ])
        let display = makeDisplay(layout: layout)
        let mutation = LayoutTransaction.LayoutMutation.reorder(
            item: .app(ids[3]), toDisplayIndex: 14
        )
        let a = LayoutEditor.apply(mutation, to: layout, display: display)
        let b = LayoutEditor.apply(mutation, to: layout, display: display)
        #expect(a == b)
    }
}
