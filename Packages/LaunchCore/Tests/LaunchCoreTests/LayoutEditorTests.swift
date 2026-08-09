import Foundation
import Testing
@testable import LaunchCore

@Suite("LayoutEditor 布局变更应用")
struct LayoutEditorTests {
    private let capacity = 12

    private func makeDisplay(
        layout: LayoutSnapshot,
        hidden: [AppID] = [],
        columns: Int = 4,
        rows: Int = 3
    ) -> DisplayModel {
        var cfg = config(columns: columns, rows: rows)
        cfg.hiddenAppIDs = hidden
        return DisplayModel(
            catalog: catalog(apps(16).map(\.rawValue)),
            layout: layout,
            config: cfg
        )
    }

    private func appOccurrenceCounts(_ layout: LayoutSnapshot) -> [AppID: Int] {
        var counts: [AppID: Int] = [:]
        for page in layout.pages {
            for item in page {
                if case .app(let id) = item {
                    counts[id, default: 0] += 1
                }
            }
        }
        for folder in layout.folders.values {
            for id in folder.children {
                counts[id, default: 0] += 1
            }
        }
        return counts
    }

    private func expectUniqueAppOccurrences(_ layout: LayoutSnapshot) {
        let counts = appOccurrenceCounts(layout)
        #expect(Set(counts.keys) == layout.referencedAppIDs)
        #expect(counts.values.allSatisfy { $0 == 1 })
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

    @Test("reorderInFolder: 按可见 gap 重排")
    func reorderInFolder() throws {
        let ids = apps(5)
        let folderID = folderID("F")
        let layout = layout(
            pages: [[.app(ids[0]), .folder(folderID), .app(ids[4])]],
            folders: [folderID: FolderRecord(
                id: folderID, name: "F", children: [ids[1], ids[2], ids[3]]
            )]
        )
        let display = makeDisplay(layout: layout)
        // 移除 1 后剩余 [2, 3], gap@2 = 末尾 → [2, 3, 1]
        let mutation = LayoutTransaction.LayoutMutation.reorderInFolder(
            app: ids[1], folder: folderID, toIndex: 2
        )
        let result = try #require(LayoutEditor.apply(mutation, to: layout, display: display))
        #expect(result.folders[folderID]?.children == [ids[2], ids[3], ids[1]])
        #expect(result.pages == layout.pages)
    }

    @Test("reorderInFolder: 隐藏子项保持在 children 中")
    func reorderInFolderKeepsHiddenChildren() throws {
        let ids = apps(5)
        let folderID = folderID("F")
        let layout = layout(
            pages: [[.folder(folderID)]],
            folders: [folderID: FolderRecord(
                id: folderID, name: "F", children: [ids[1], ids[2], ids[3]]
            )]
        )
        let display = makeDisplay(layout: layout, hidden: [ids[2]])
        // 可见列表 [1, 3], 将 3 移到可见 gap@0, 隐藏项 2 仍保留。
        let mutation = LayoutTransaction.LayoutMutation.reorderInFolder(
            app: ids[3], folder: folderID, toIndex: 0
        )
        let result = try #require(LayoutEditor.apply(mutation, to: layout, display: display))
        #expect(result.folders[folderID]?.children == [ids[3], ids[1], ids[2]])
    }

    @Test("reorderInFolder: 未知文件夹或不可见应用 → nil")
    func reorderInFolderInvalid() throws {
        let ids = apps(3)
        let f = folderID("F")
        let layout = layout(
            pages: [[.folder(f)]],
            folders: [f: FolderRecord(id: f, name: "F", children: [ids[1]])]
        )
        let display = makeDisplay(layout: layout)
        #expect(LayoutEditor.apply(
            .reorderInFolder(app: ids[0], folder: f, toIndex: 0),
            to: layout,
            display: display
        ) == nil)
        #expect(LayoutEditor.apply(
            .reorderInFolder(app: ids[1], folder: folderID("Ghost"), toIndex: 0),
            to: layout,
            display: display
        ) == nil)
    }

    @Test("moveOutOfFolder: 移出后仍有至少两个 child 时保留文件夹")
    func moveOutOfFolder() throws {
        let ids = apps(5)
        let folderID = folderID("F")
        let layout = layout(
            pages: [[.app(ids[0]), .folder(folderID), .app(ids[4])]],
            folders: [folderID: FolderRecord(
                id: folderID, name: "F", children: [ids[1], ids[2], ids[3]]
            )]
        )
        let display = makeDisplay(layout: layout)
        // 显示: [0, F, 4]; 把 3 移到显示索引 0,剩余 children [1, 2]
        let mutation = LayoutTransaction.LayoutMutation.moveOutOfFolder(
            app: ids[3], from: folderID, toDisplayIndex: 0
        )
        let result = try #require(LayoutEditor.apply(mutation, to: layout, display: display))
        #expect(result.folders[folderID]?.children == [ids[1], ids[2]])
        #expect(result.pages[0] == [.app(ids[3]), .app(ids[0]), .folder(folderID), .app(ids[4])])
    }

    @Test("moveOutOfFolder: 单 child 时在一次 mutation 中解散并覆盖前后附近目标")
    func moveOutDissolvesSingleChildAtNearbyTargets() throws {
        let ids = apps(4)
        let folderID = folderID("F")
        let layout = layout(
            pages: [[.app(ids[0]), .folder(folderID), .app(ids[3])]],
            folders: [folderID: FolderRecord(id: folderID, name: "F", children: [ids[1], ids[2]])]
        )
        let display = makeDisplay(layout: layout)
        let cases: [(target: Int, page: [LayoutItem])] = [
            (0, [.app(ids[2]), .app(ids[0]), .app(ids[1]), .app(ids[3])]),
            (1, [.app(ids[0]), .app(ids[2]), .app(ids[1]), .app(ids[3])]),
            (2, [.app(ids[0]), .app(ids[1]), .app(ids[2]), .app(ids[3])]),
            (3, [.app(ids[0]), .app(ids[1]), .app(ids[3]), .app(ids[2])]),
        ]

        for testCase in cases {
            let mutation = LayoutTransaction.LayoutMutation.moveOutOfFolder(
                app: ids[2], from: folderID, toDisplayIndex: testCase.target
            )
            let result = try #require(LayoutEditor.apply(mutation, to: layout, display: display))
            #expect(result.folders[folderID] == nil)
            #expect(result.pages == [testCase.page])
            #expect(result.referencedAppIDs == layout.referencedAppIDs)
        }
    }

    @Test("moveOutOfFolder: 历史单 child 文件夹移出后原子删除空槽和记录")
    func moveOutRemovesHistoricalEmptyFolder() throws {
        let ids = apps(5)
        let hidden = ids[0]
        let folderID = folderID("HistoricalOneChild")
        let layout = layout(
            pages: [[.app(hidden), .app(ids[1]), .folder(folderID), .app(ids[3])]],
            folders: [folderID: FolderRecord(
                id: folderID, name: "HistoricalOneChild", children: [ids[2]]
            )]
        )
        let display = makeDisplay(layout: layout, hidden: [hidden], columns: 4, rows: 1)
        let cases: [(target: Int, page: [LayoutItem], visible: [AppID])] = [
            (0, [.app(hidden), .app(ids[2]), .app(ids[1]), .app(ids[3])], [ids[2], ids[1], ids[3]]),
            (1, [.app(hidden), .app(ids[1]), .app(ids[2]), .app(ids[3])], [ids[1], ids[2], ids[3]]),
            (2, [.app(hidden), .app(ids[1]), .app(ids[3]), .app(ids[2])], [ids[1], ids[3], ids[2]]),
        ]

        for testCase in cases {
            let result = try #require(LayoutEditor.apply(
                .moveOutOfFolder(app: ids[2], from: folderID, toDisplayIndex: testCase.target),
                to: layout,
                display: display
            ))
            #expect(result.folders[folderID] == nil)
            #expect(result.pages == [testCase.page])
            #expect(makeDisplay(
                layout: result, hidden: [hidden], columns: 4, rows: 1
            ).visibleAppIDs == testCase.visible)
            #expect(result.referencedAppIDs == layout.referencedAppIDs)
            expectUniqueAppOccurrences(result)
        }
    }

    @Test("moveOutOfFolder: 按持久 children 数量解散,隐藏剩余 app 仍回原槽位")
    func moveOutDissolvesUsingPersistentChildrenCount() throws {
        let ids = apps(4)
        let folderID = folderID("F")
        let layout = layout(
            pages: [[.app(ids[0]), .folder(folderID), .app(ids[3])]],
            folders: [folderID: FolderRecord(id: folderID, name: "F", children: [ids[1], ids[2]])]
        )
        let display = makeDisplay(layout: layout, hidden: [ids[1]])
        let mutation = LayoutTransaction.LayoutMutation.moveOutOfFolder(
            app: ids[2], from: folderID, toDisplayIndex: 1
        )

        let result = try #require(LayoutEditor.apply(mutation, to: layout, display: display))
        #expect(result.folders[folderID] == nil)
        #expect(result.pages == [[.app(ids[0]), .app(ids[1]), .app(ids[2]), .app(ids[3])]])
        #expect(result.referencedAppIDs == layout.referencedAppIDs)
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
        #expect(result.layout.referencedAppIDs == layout.referencedAppIDs)
        expectUniqueAppOccurrences(result.layout)
    }

    @Test("createFolder: 空列表/单应用/重复或非可见槽位应用 → nil")
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
        #expect(LayoutEditor.createFolder(
            in: layout, display: display, name: "X",
            appIDs: [ids[0], ids[0]]
        ) == nil)
        // 单应用文件夹会自动解散,新建时拒绝。
        #expect(LayoutEditor.createFolder(
            in: layout, display: display, name: "X", appIDs: [ids[0]]
        ) == nil)

        let hiddenDisplay = makeDisplay(layout: layout, hidden: [ids[0]])
        #expect(LayoutEditor.createFolder(
            in: layout, display: hiddenDisplay, name: "X", appIDs: [ids[0], ids[1]]
        ) == nil)

        let missingLayout = LayoutSnapshot(
            pages: [ids.map(LayoutItem.app)],
            missingApps: [ids[0]: MissingAppState(missingSince: Date(timeIntervalSince1970: 1))]
        )
        #expect(LayoutEditor.createFolder(
            in: missingLayout,
            display: makeDisplay(layout: missingLayout),
            name: "X",
            appIDs: [ids[0], ids[1]]
        ) == nil)
    }

    @Test("createFolder: hidden 应用在目标前/中/后保持持久顺序")
    func createFolderPreservesHiddenAroundGap() throws {
        let ids = apps(7)

        do {
            let layout = layout(pages: [[
                .app(ids[0]), .app(ids[1]), .app(ids[2]), .app(ids[3])
            ]])
            let display = makeDisplay(layout: layout, hidden: [ids[0]])
            let result = try #require(LayoutEditor.createFolder(
                in: layout, display: display, name: "Before", appIDs: [ids[2], ids[3]]
            ))
            #expect(result.layout.pages == [[
                .app(ids[0]), .app(ids[1]), .folder(result.folderID)
            ]])
            #expect(DisplayModel(
                catalog: catalog(apps(16).map(\.rawValue)),
                layout: result.layout,
                config: { var c = config(); c.hiddenAppIDs = [ids[0]]; return c }()
            ).flatSlots == [
                .app(ids[1]), .folder(result.folderID, visibleChildren: [ids[2], ids[3]])
            ])
            expectUniqueAppOccurrences(result.layout)
        }

        do {
            let layout = layout(pages: [[
                .app(ids[1]), .app(ids[0]), .app(ids[2]), .app(ids[3])
            ]])
            let display = makeDisplay(layout: layout, hidden: [ids[0]])
            let result = try #require(LayoutEditor.createFolder(
                in: layout, display: display, name: "Between", appIDs: [ids[2], ids[3]]
            ))
            #expect(result.layout.pages == [[
                .app(ids[1]), .app(ids[0]), .folder(result.folderID)
            ]])
            #expect(DisplayModel(
                catalog: catalog(apps(16).map(\.rawValue)),
                layout: result.layout,
                config: { var c = config(); c.hiddenAppIDs = [ids[0]]; return c }()
            ).flatSlots == [
                .app(ids[1]), .folder(result.folderID, visibleChildren: [ids[2], ids[3]])
            ])
            expectUniqueAppOccurrences(result.layout)
        }

        do {
            let layout = layout(pages: [[
                .app(ids[1]), .app(ids[2]), .app(ids[0]), .app(ids[3])
            ]])
            let display = makeDisplay(layout: layout, hidden: [ids[0]])
            let result = try #require(LayoutEditor.createFolder(
                in: layout, display: display, name: "After", appIDs: [ids[1], ids[2]]
            ))
            #expect(result.layout.pages == [[
                .app(ids[0]), .folder(result.folderID), .app(ids[3])
            ]])
            #expect(DisplayModel(
                catalog: catalog(apps(16).map(\.rawValue)),
                layout: result.layout,
                config: { var c = config(); c.hiddenAppIDs = [ids[0]]; return c }()
            ).flatSlots == [
                .folder(result.folderID, visibleChildren: [ids[1], ids[2]]), .app(ids[3])
            ])
            expectUniqueAppOccurrences(result.layout)
        }
    }

    @Test("createFolder: missing 应用在目标前/中保持持久顺序")
    func createFolderPreservesMissingAroundGap() throws {
        let ids = apps(7)
        let missing = ids[0]
        let state = MissingAppState(missingSince: Date(timeIntervalSince1970: 1234))

        do {
            let layout = layout(
                pages: [[.app(missing), .app(ids[1]), .app(ids[2]), .app(ids[3])]],
                missingApps: [missing: state]
            )
            let display = makeDisplay(layout: layout)
            let result = try #require(LayoutEditor.createFolder(
                in: layout, display: display, name: "Before", appIDs: [ids[2], ids[3]]
            ))
            #expect(result.layout.pages == [[
                .app(missing), .app(ids[1]), .folder(result.folderID)
            ]])
            #expect(DisplayModel(
                catalog: catalog(apps(16).map(\.rawValue)),
                layout: result.layout,
                config: config()
            ).flatSlots == [
                .app(ids[1]), .folder(result.folderID, visibleChildren: [ids[2], ids[3]])
            ])
            #expect(result.layout.missingApps[missing] == state)
            expectUniqueAppOccurrences(result.layout)
        }

        do {
            let layout = layout(
                pages: [[.app(ids[1]), .app(missing), .app(ids[2]), .app(ids[3])]],
                missingApps: [missing: state]
            )
            let display = makeDisplay(layout: layout)
            let result = try #require(LayoutEditor.createFolder(
                in: layout, display: display, name: "Between", appIDs: [ids[2], ids[3]]
            ))
            #expect(result.layout.pages == [[
                .app(ids[1]), .app(missing), .folder(result.folderID)
            ]])
            #expect(DisplayModel(
                catalog: catalog(apps(16).map(\.rawValue)),
                layout: result.layout,
                config: config()
            ).flatSlots == [
                .app(ids[1]), .folder(result.folderID, visibleChildren: [ids[2], ids[3]])
            ])
            #expect(result.layout.missingApps[missing] == state)
            expectUniqueAppOccurrences(result.layout)
        }
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
        #expect(result.referencedAppIDs == layout.referencedAppIDs)
        expectUniqueAppOccurrences(result)
    }

    @Test("dissolveFolder: hidden 应用在文件夹前/中/后保持持久顺序")
    func dissolveFolderPreservesHiddenAroundSlot() throws {
        let ids = apps(8)
        let folderID = folderID("HiddenDissolve")

        do {
            let layout = layout(
                pages: [[.app(ids[0]), .app(ids[1]), .folder(folderID), .app(ids[4])]],
                folders: [folderID: FolderRecord(
                    id: folderID, name: "F", children: [ids[2], ids[3]]
                )]
            )
            let display = makeDisplay(layout: layout, hidden: [ids[0]])
            let result = try #require(LayoutEditor.dissolveFolder(
                in: layout, display: display, id: folderID
            ))
            #expect(result.pages == [[
                .app(ids[0]), .app(ids[1]), .app(ids[2]), .app(ids[3]), .app(ids[4])
            ]])
            #expect(DisplayModel(
                catalog: catalog(apps(16).map(\.rawValue)),
                layout: result,
                config: { var c = config(); c.hiddenAppIDs = [ids[0]]; return c }()
            ).flatSlots == [.app(ids[1]), .app(ids[2]), .app(ids[3]), .app(ids[4])])
            expectUniqueAppOccurrences(result)
        }

        do {
            let layout = layout(
                pages: [[.app(ids[1]), .app(ids[0]), .folder(folderID), .app(ids[4])]],
                folders: [folderID: FolderRecord(
                    id: folderID, name: "F", children: [ids[2], ids[3]]
                )]
            )
            let display = makeDisplay(layout: layout, hidden: [ids[0]])
            let result = try #require(LayoutEditor.dissolveFolder(
                in: layout, display: display, id: folderID
            ))
            #expect(result.pages == [[
                .app(ids[1]), .app(ids[0]), .app(ids[2]), .app(ids[3]), .app(ids[4])
            ]])
            expectUniqueAppOccurrences(result)
        }

        do {
            let layout = layout(
                pages: [[.app(ids[1]), .folder(folderID), .app(ids[0]), .app(ids[4])]],
                folders: [folderID: FolderRecord(
                    id: folderID, name: "F", children: [ids[2], ids[3]]
                )]
            )
            let display = makeDisplay(layout: layout, hidden: [ids[0]])
            let result = try #require(LayoutEditor.dissolveFolder(
                in: layout, display: display, id: folderID
            ))
            #expect(result.pages == [[
                .app(ids[1]), .app(ids[0]), .app(ids[2]), .app(ids[3]), .app(ids[4])
            ]])
            expectUniqueAppOccurrences(result)
        }
    }

    @Test("dissolveFolder: missing 应用在文件夹前/中保持持久顺序")
    func dissolveFolderPreservesMissingAroundSlot() throws {
        let ids = apps(8)
        let missing = ids[0]
        let folderID = folderID("MissingDissolve")
        let state = MissingAppState(missingSince: Date(timeIntervalSince1970: 4321))

        do {
            let layout = layout(
                pages: [[.app(missing), .app(ids[1]), .folder(folderID), .app(ids[4])]],
                folders: [folderID: FolderRecord(
                    id: folderID, name: "F", children: [ids[2], ids[3]]
                )],
                missingApps: [missing: state]
            )
            let display = makeDisplay(layout: layout)
            let result = try #require(LayoutEditor.dissolveFolder(
                in: layout, display: display, id: folderID
            ))
            #expect(result.pages == [[
                .app(missing), .app(ids[1]), .app(ids[2]), .app(ids[3]), .app(ids[4])
            ]])
            #expect(result.missingApps[missing] == state)
            expectUniqueAppOccurrences(result)
        }

        do {
            let layout = layout(
                pages: [[.app(ids[1]), .app(missing), .folder(folderID), .app(ids[4])]],
                folders: [folderID: FolderRecord(
                    id: folderID, name: "F", children: [ids[2], ids[3]]
                )],
                missingApps: [missing: state]
            )
            let display = makeDisplay(layout: layout)
            let result = try #require(LayoutEditor.dissolveFolder(
                in: layout, display: display, id: folderID
            ))
            #expect(result.pages == [[
                .app(ids[1]), .app(missing), .app(ids[2]), .app(ids[3]), .app(ids[4])
            ]])
            #expect(result.missingApps[missing] == state)
            expectUniqueAppOccurrences(result)
        }
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

    @Test("create/dissolveFolder: hidden 前缀下跨页按容量确定性重分块")
    func folderOperationsCrossPageWithHiddenPrefix() throws {
        let ids = apps(8)
        let hidden = ids[0]

        let createLayout = layout(pages: [
            [.app(hidden), .app(ids[1])],
            [.app(ids[2]), .app(ids[3])],
            [.app(ids[4]), .app(ids[5])],
        ])
        let createDisplay = makeDisplay(
            layout: createLayout, hidden: [hidden], columns: 2, rows: 1
        )
        let created = try #require(LayoutEditor.createFolder(
            in: createLayout,
            display: createDisplay,
            name: "CrossPage",
            appIDs: [ids[4], ids[5]]
        ))
        #expect(created.layout.pages == [
            [.app(hidden), .app(ids[1])],
            [.app(ids[2]), .app(ids[3])],
            [.folder(created.folderID)],
        ])
        let createdDisplay = makeDisplay(
            layout: created.layout, hidden: [hidden], columns: 2, rows: 1
        )
        #expect(createdDisplay.pages == [
            [.app(ids[1]), .app(ids[2])],
            [.app(ids[3]), .folder(created.folderID, visibleChildren: [ids[4], ids[5]])],
        ])
        #expect(created.layout.referencedAppIDs == createLayout.referencedAppIDs)
        expectUniqueAppOccurrences(created.layout)

        let dissolveFolderID = folderID("CrossPageDissolve")
        let dissolveLayout = layout(
            pages: [
                [.app(hidden), .app(ids[1])],
                [.folder(dissolveFolderID), .app(ids[2])],
                [.app(ids[3]), .app(ids[4])],
            ],
            folders: [dissolveFolderID: FolderRecord(
                id: dissolveFolderID, name: "CrossPage", children: [ids[5], ids[6]]
            )]
        )
        let dissolveDisplay = makeDisplay(
            layout: dissolveLayout, hidden: [hidden], columns: 2, rows: 1
        )
        let dissolved = try #require(LayoutEditor.dissolveFolder(
            in: dissolveLayout, display: dissolveDisplay, id: dissolveFolderID
        ))
        #expect(dissolved.pages == [
            [.app(hidden), .app(ids[1])],
            [.app(ids[5]), .app(ids[6])],
            [.app(ids[2]), .app(ids[3])],
            [.app(ids[4])],
        ])
        let dissolvedDisplay = makeDisplay(
            layout: dissolved, hidden: [hidden], columns: 2, rows: 1
        )
        #expect(dissolvedDisplay.pages == [
            [.app(ids[1]), .app(ids[5])],
            [.app(ids[6]), .app(ids[2])],
            [.app(ids[3]), .app(ids[4])],
        ])
        #expect(dissolved.referencedAppIDs == dissolveLayout.referencedAppIDs)
        expectUniqueAppOccurrences(dissolved)
    }

    @Test("create/dissolveFolder: JSON 重载后保留墓碑, unhide 后顺序恢复")
    func folderOperationsPersistAndUnhide() throws {
        let ids = apps(8)
        let hidden = ids[0]
        let missing = ids[1]
        let missingState = MissingAppState(missingSince: Date(timeIntervalSince1970: 9876))

        let createLayout = layout(
            pages: [[.app(hidden), .app(missing), .app(ids[2]), .app(ids[3]), .app(ids[4])]],
            missingApps: [missing: missingState]
        )
        let createDisplay = makeDisplay(layout: createLayout, hidden: [hidden])
        let created = try #require(LayoutEditor.createFolder(
            in: createLayout,
            display: createDisplay,
            name: "PersistCreate",
            appIDs: [ids[3], ids[4]]
        ))
        #expect(created.layout.pages == [[
            .app(hidden), .app(missing), .app(ids[2]), .folder(created.folderID)
        ]])
        #expect(created.layout.missingApps[missing] == missingState)
        #expect(created.layout.referencedAppIDs == createLayout.referencedAppIDs)
        expectUniqueAppOccurrences(created.layout)

        let createdReloaded = try JSONDecoder().decode(
            LayoutSnapshot.self,
            from: JSONEncoder().encode(created.layout)
        )
        #expect(createdReloaded == created.layout)
        #expect(createdReloaded.schemaVersion == LayoutSnapshot.currentSchemaVersion)
        #expect(createdReloaded.missingApps[missing] == missingState)

        let createdUnhidden = LayoutSnapshot(
            pages: createdReloaded.pages,
            folders: createdReloaded.folders
        )
        let createdUnhiddenDisplay = makeDisplay(layout: createdUnhidden)
        #expect(createdUnhiddenDisplay.flatSlots == [
            .app(hidden), .app(missing), .app(ids[2]),
            .folder(created.folderID, visibleChildren: [ids[3], ids[4]])
        ])

        let dissolveFolderID = folderID("PersistDissolve")
        let dissolveLayout = layout(
            pages: [[.app(hidden), .app(missing), .app(ids[2]), .folder(dissolveFolderID), .app(ids[5])]],
            folders: [dissolveFolderID: FolderRecord(
                id: dissolveFolderID, name: "PersistDissolve", children: [ids[3], ids[4]]
            )],
            missingApps: [missing: missingState]
        )
        let dissolveDisplay = makeDisplay(layout: dissolveLayout, hidden: [hidden])
        let dissolved = try #require(LayoutEditor.dissolveFolder(
            in: dissolveLayout, display: dissolveDisplay, id: dissolveFolderID
        ))
        #expect(dissolved.pages == [[
            .app(hidden), .app(missing), .app(ids[2]), .app(ids[3]), .app(ids[4]), .app(ids[5])
        ]])
        #expect(dissolved.missingApps[missing] == missingState)
        #expect(dissolved.referencedAppIDs == dissolveLayout.referencedAppIDs)
        expectUniqueAppOccurrences(dissolved)

        let dissolvedReloaded = try JSONDecoder().decode(
            LayoutSnapshot.self,
            from: JSONEncoder().encode(dissolved)
        )
        #expect(dissolvedReloaded == dissolved)
        #expect(dissolvedReloaded.schemaVersion == LayoutSnapshot.currentSchemaVersion)
        #expect(dissolvedReloaded.missingApps[missing] == missingState)

        let dissolvedUnhidden = LayoutSnapshot(
            pages: dissolvedReloaded.pages,
            folders: dissolvedReloaded.folders
        )
        #expect(makeDisplay(layout: dissolvedUnhidden).flatSlots == [
            .app(hidden), .app(missing), .app(ids[2]), .app(ids[3]), .app(ids[4]), .app(ids[5])
        ])
    }

    @Test("dissolveFolder: 重复 AppID 引用会使操作无效")
    func dissolveFolderRejectsDuplicateReferences() throws {
        let ids = apps(4)
        let dissolveDuplicateFolderID = folderID("Duplicate")

        let createDuplicateFolderID = folderID("CreateDuplicate")
        let createWithPageAndChildDuplicate = layout(
            pages: [[.app(ids[0]), .app(ids[1]), .folder(createDuplicateFolderID)]],
            folders: [createDuplicateFolderID: FolderRecord(
                id: createDuplicateFolderID,
                name: "CreateDuplicate",
                children: [ids[1], ids[2]]
            )]
        )
        #expect(LayoutEditor.createFolder(
            in: createWithPageAndChildDuplicate,
            display: makeDisplay(layout: createWithPageAndChildDuplicate),
            name: "New",
            appIDs: [ids[0], ids[1]]
        ) == nil)

        let pageAndChildDuplicate = layout(
            pages: [[.app(ids[0]), .folder(dissolveDuplicateFolderID)]],
            folders: [dissolveDuplicateFolderID: FolderRecord(
                id: dissolveDuplicateFolderID, name: "Duplicate", children: [ids[0], ids[1]]
            )]
        )
        #expect(LayoutEditor.dissolveFolder(
            in: pageAndChildDuplicate,
            display: makeDisplay(layout: pageAndChildDuplicate),
            id: dissolveDuplicateFolderID
        ) == nil)

        let childDuplicate = layout(
            pages: [[.folder(dissolveDuplicateFolderID)]],
            folders: [dissolveDuplicateFolderID: FolderRecord(
                id: dissolveDuplicateFolderID, name: "Duplicate", children: [ids[0], ids[0]]
            )]
        )
        #expect(LayoutEditor.dissolveFolder(
            in: childDuplicate,
            display: makeDisplay(layout: childDuplicate),
            id: dissolveDuplicateFolderID
        ) == nil)
    }

    @Test("重复文件夹槽位会使编辑操作无效")
    func mutationRejectsDuplicateFolderSlots() {
        let ids = apps(2)
        let id = folderID("DuplicateSlot")
        let malformed = layout(
            pages: [[.folder(id), .folder(id)]],
            folders: [id: FolderRecord(id: id, name: "F", children: ids)]
        )
        #expect(LayoutEditor.apply(
            .renameFolder(id, newName: "Renamed"),
            to: malformed,
            display: makeDisplay(layout: malformed)
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
