import Foundation
import Testing
@testable import LaunchCore

@Suite("LayoutReconciler 纯逻辑对账")
struct LayoutReconcilerTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func record(_ path: String) throws -> AppRecord {
        let id = try #require(AppID(path))
        return AppRecord(
            id: id,
            url: URL(fileURLWithPath: path),
            bundleIdentifier: nil,
            displayName: "App",
            infoPlistModificationDate: nil,
            iconContentVersion: .empty
        )
    }

    private func catalog(_ paths: String...) throws -> CatalogSnapshot {
        CatalogSnapshot(apps: try paths.map(record))
    }

    private func layout(
        pages: [[LayoutItem]] = [],
        folders: [FolderID: FolderRecord] = [:],
        missingApps: [AppID: MissingAppState] = [:]
    ) -> LayoutSnapshot {
        LayoutSnapshot(pages: pages, folders: folders, missingApps: missingApps)
    }

    @Test("新应用追加到最后一页末尾(按 AppID 排序)")
    func newAppsAppendToLastPage() throws {
        let catalog = try catalog(
            "/Applications/B.app",
            "/Applications/A.app",
            "/Applications/C.app"
        )
        let existing = try #require(AppID("/Applications/A.app"))
        let layout = layout(pages: [[.app(existing)]])

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages.count == 1)
        #expect(result.pages[0] == [
            .app(existing),
            .app(try #require(AppID("/Applications/B.app"))),
            .app(try #require(AppID("/Applications/C.app"))),
        ])
        #expect(result.missingApps.isEmpty)
    }

    @Test("无页面时创建第一页")
    func createsFirstPageWhenEmpty() throws {
        let catalog = try catalog("/Applications/A.app")
        let result = LayoutReconciler.reconcile(
            catalog: catalog,
            layout: layout(),
            now: now
        )
        #expect(result.pages == [[.app(try #require(AppID("/Applications/A.app")))]])
    }

    @Test("缺失应用: 保留布局引用, 创建墓碑")
    func missingAppCreatesTombstone() throws {
        let present = try #require(AppID("/Applications/Present.app"))
        let gone = try #require(AppID("/Applications/Gone.app"))
        let catalog = try catalog("/Applications/Present.app")
        let layout = layout(pages: [[.app(present), .app(gone)]])

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages[0] == [.app(present), .app(gone)])
        #expect(result.missingApps[gone]?.missingSince == now)
        #expect(result.missingApps[present] == nil)
    }

    @Test("已存在墓碑的应用不会重置 missingSince")
    func existingTombstoneKeepsDate() throws {
        let gone = try #require(AppID("/Applications/Gone.app"))
        let catalog = try catalog("/Applications/Present.app")
        let firstSeen = Date(timeIntervalSince1970: 500)
        let layout = layout(
            pages: [[.app(gone)]],
            missingApps: [gone: MissingAppState(missingSince: firstSeen)]
        )

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.missingApps[gone]?.missingSince == firstSeen)
    }

    @Test("应用回归: 清除墓碑, 位置自动恢复")
    func returnedAppClearsTombstone() throws {
        let app = try #require(AppID("/Applications/Back.app"))
        let catalog = try catalog("/Applications/Back.app")
        let layout = layout(
            pages: [[.app(app)]],
            missingApps: [app: MissingAppState(missingSince: Date(timeIntervalSince1970: 10))]
        )

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages[0] == [.app(app)])
        #expect(result.missingApps.isEmpty)
    }

    @Test("无引用的墓碑: 应用回归时重新加入布局并清除墓碑")
    func orphanTombstoneAppReadded() throws {
        let app = try #require(AppID("/Applications/Back.app"))
        let catalog = try catalog("/Applications/Back.app")
        // 引用已不在布局中,但墓碑残留(手动移除等罕见情况)
        let layout = layout(
            pages: [[]],
            missingApps: [app: MissingAppState(missingSince: Date(timeIntervalSince1970: 10))]
        )

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages[0] == [.app(app)])
        #expect(result.missingApps.isEmpty)
    }

    @Test("宽限期边界: 到期前保留, 到期后移除")
    func gracePeriodBoundary() throws {
        let recent = try #require(AppID("/Applications/Recent.app"))
        let expired = try #require(AppID("/Applications/Expired.app"))
        let present = try #require(AppID("/Applications/Present.app"))
        let catalog = try catalog("/Applications/Present.app")
        let firstSeen = Date(timeIntervalSince1970: 500)
        let layout = layout(
            pages: [[.app(recent), .app(expired)]],
            missingApps: [
                // recent 昨天才缺失;expired 从 firstSeen 起缺失
                recent: MissingAppState(missingSince: now.addingTimeInterval(-86_400)),
                expired: MissingAppState(missingSince: firstSeen),
            ]
        )

        // now = firstSeen + 29 天 + 23 小时(两个墓碑都未到期)
        let beforeExpiry = firstSeen.addingTimeInterval(29 * 86_400 + 23 * 3_600)
        let resultBefore = LayoutReconciler.reconcile(
            catalog: catalog, layout: layout, now: beforeExpiry
        )
        #expect(resultBefore.pages[0].contains(.app(recent)))
        #expect(resultBefore.missingApps[recent] != nil)
        #expect(resultBefore.missingApps[expired] != nil)

        // now = firstSeen + 30 天 + 1 秒(expired 到期, recent 未到期)
        let afterExpiry = firstSeen.addingTimeInterval(30 * 86_400 + 1)
        let resultAfter = LayoutReconciler.reconcile(
            catalog: catalog, layout: layout, now: afterExpiry
        )
        #expect(!resultAfter.pages[0].contains(.app(expired)))
        #expect(resultAfter.missingApps[expired] == nil)
        #expect(resultAfter.pages[0] == [.app(recent), .app(present)])
    }

    @Test("过期应用同时从文件夹子项移除")
    func expiredRemovedFromFolderChildren() throws {
        let gone = try #require(AppID("/Applications/Gone.app"))
        let staying = try #require(AppID("/Applications/Staying.app"))
        let folderID = try #require(FolderID("F"))
        let catalog = try catalog("/Applications/Staying.app")
        let firstSeen = Date(timeIntervalSince1970: 500)
        let layout = layout(
            pages: [[.folder(folderID)]],
            folders: [
                folderID: FolderRecord(id: folderID, name: "F", children: [gone, staying])
            ],
            missingApps: [gone: MissingAppState(missingSince: firstSeen)]
        )

        let result = LayoutReconciler.reconcile(
            catalog: catalog,
            layout: layout,
            now: firstSeen.addingTimeInterval(30 * 86_400 + 1)
        )

        #expect(result.pages == [[.app(staying)]])
        #expect(result.folders[folderID] == nil)
        #expect(result.missingApps.isEmpty)
    }

    @Test("空文件夹确定性解散(含从页面移除)")
    func emptyFolderDissolved() throws {
        let emptyFolder = try #require(FolderID("Empty"))
        let fullFolder = try #require(FolderID("Full"))
        let app = try #require(AppID("/Applications/A.app"))
        let catalog = try catalog("/Applications/A.app")
        let layout = layout(
            pages: [[.folder(emptyFolder), .folder(fullFolder)]],
            folders: [
                emptyFolder: FolderRecord(id: emptyFolder, name: "Empty"),
                fullFolder: FolderRecord(id: fullFolder, name: "Full", children: [app]),
            ]
        )

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.folders[emptyFolder] == nil)
        #expect(result.folders[fullFolder] == nil)
        #expect(result.pages[0] == [.app(app)])
    }

    @Test("孤儿文件夹项(引用不存在的 FolderID)被移除")
    func orphanFolderItemRemoved() throws {
        let orphan = try #require(FolderID("Orphan"))
        let app = try #require(AppID("/Applications/A.app"))
        let catalog = try catalog("/Applications/A.app")
        let layout = layout(pages: [[.app(app), .folder(orphan)]])

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages[0] == [.app(app)])
    }

    @Test("单 child 文件夹解散且应用不会重复追加")
    func singleChildFolderDissolvedWithoutDuplicateAppend() throws {
        let app = try #require(AppID("/Applications/A.app"))
        let folderID = try #require(FolderID("F"))
        let catalog = try catalog("/Applications/A.app")
        let layout = layout(
            pages: [[.folder(folderID)]],
            folders: [folderID: FolderRecord(id: folderID, name: "F", children: [app])]
        )

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages == [[.app(app)]])
        #expect(result.folders[folderID] == nil)
        #expect(result.pages.flatMap { $0 }.filter { $0 == .app(app) }.count == 1)
    }

    @Test("同页多个单 child 文件夹按槽位顺序原子解散")
    func multipleSingleChildFoldersDissolveInPageOrder() throws {
        let first = try #require(AppID("/Applications/First.app"))
        let middle = try #require(AppID("/Applications/Middle.app"))
        let last = try #require(AppID("/Applications/Last.app"))
        let firstFolder = try #require(FolderID("First"))
        let lastFolder = try #require(FolderID("Last"))
        let catalog = try catalog(
            "/Applications/First.app",
            "/Applications/Middle.app",
            "/Applications/Last.app"
        )
        let layout = layout(
            pages: [[.folder(firstFolder), .app(middle), .folder(lastFolder)]],
            folders: [
                firstFolder: FolderRecord(id: firstFolder, name: "First", children: [first]),
                lastFolder: FolderRecord(id: lastFolder, name: "Last", children: [last]),
            ]
        )

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages == [[.app(first), .app(middle), .app(last)]])
        #expect(result.folders.isEmpty)
    }

    @Test("至少两个 child 的文件夹保留")
    func folderWithAtLeastTwoChildrenRemains() throws {
        let first = try #require(AppID("/Applications/First.app"))
        let second = try #require(AppID("/Applications/Second.app"))
        let folderID = try #require(FolderID("Retained"))
        let catalog = try catalog("/Applications/First.app", "/Applications/Second.app")
        let layout = layout(
            pages: [[.folder(folderID)]],
            folders: [folderID: FolderRecord(
                id: folderID, name: "Retained", children: [first, second]
            )]
        )

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages == [[.folder(folderID)]])
        #expect(result.folders[folderID]?.children == [first, second])
    }

    @Test("孤儿与重复文件夹引用不会产生重复应用")
    func orphanAndDuplicateFolderReferencesDoNotDuplicateApps() throws {
        let app = try #require(AppID("/Applications/A.app"))
        let orphan = try #require(FolderID("Orphan"))
        let firstFolder = try #require(FolderID("First"))
        let secondFolder = try #require(FolderID("Second"))
        let catalog = try catalog("/Applications/A.app")
        let layout = layout(
            pages: [[
                .folder(orphan),
                .folder(firstFolder),
                .folder(firstFolder),
                .folder(secondFolder),
                .app(app),
            ]],
            folders: [
                firstFolder: FolderRecord(id: firstFolder, name: "First", children: [app]),
                secondFolder: FolderRecord(id: secondFolder, name: "Second", children: [app]),
            ]
        )

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages == [[.app(app)]])
        #expect(result.folders.isEmpty)
        #expect(result.pages.flatMap { $0 }.filter { $0 == .app(app) }.count == 1)
    }

    @Test("重复根应用只保留持久化遍历中的首次引用")
    func duplicateRootAppsKeepFirstOccurrence() throws {
        let first = try #require(AppID("/Applications/First.app"))
        let second = try #require(AppID("/Applications/Second.app"))
        let catalog = try catalog("/Applications/First.app", "/Applications/Second.app")
        let layout = layout(
            pages: [
                [.app(first), .app(first), .app(second)],
                [.app(first)],
            ]
        )

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages == [[.app(first), .app(second)]])
    }

    @Test("重复文件夹槽位只保留首次有效槽位")
    func duplicateFolderSlotsKeepFirstValidSlot() throws {
        let first = try #require(AppID("/Applications/First.app"))
        let second = try #require(AppID("/Applications/Second.app"))
        let folderID = try #require(FolderID("F"))
        let catalog = try catalog("/Applications/First.app", "/Applications/Second.app")
        let layout = layout(
            pages: [[.folder(folderID), .folder(folderID)]],
            folders: [folderID: FolderRecord(
                id: folderID,
                name: "F",
                children: [first, second]
            )]
        )

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages == [[.folder(folderID)]])
        #expect(result.folders[folderID]?.children == [first, second])
    }

    @Test("文件夹 children 内重复 AppID 只保留首次引用")
    func duplicateFolderChildrenKeepFirstOccurrence() throws {
        let first = try #require(AppID("/Applications/First.app"))
        let second = try #require(AppID("/Applications/Second.app"))
        let folderID = try #require(FolderID("F"))
        let catalog = try catalog("/Applications/First.app", "/Applications/Second.app")
        let layout = layout(
            pages: [[.folder(folderID)]],
            folders: [folderID: FolderRecord(
                id: folderID,
                name: "F",
                children: [first, first, second, second]
            )]
        )

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages == [[.folder(folderID)]])
        #expect(result.folders[folderID]?.children == [first, second])
    }

    @Test("根应用优先于后续文件夹 child,且跨文件夹重复按槽位顺序收敛")
    func crossRootAndFolderReferencesKeepFirstOccurrence() throws {
        let root = try #require(AppID("/Applications/Root.app"))
        let shared = try #require(AppID("/Applications/Shared.app"))
        let firstOnly = try #require(AppID("/Applications/FirstOnly.app"))
        let secondOnly = try #require(AppID("/Applications/SecondOnly.app"))
        let firstFolder = try #require(FolderID("First"))
        let secondFolder = try #require(FolderID("Second"))
        let catalog = try catalog(
            "/Applications/Root.app",
            "/Applications/Shared.app",
            "/Applications/FirstOnly.app",
            "/Applications/SecondOnly.app"
        )
        let layout = layout(
            pages: [[.app(root), .folder(firstFolder), .folder(secondFolder)]],
            folders: [
                firstFolder: FolderRecord(
                    id: firstFolder,
                    name: "First",
                    children: [root, shared, firstOnly]
                ),
                secondFolder: FolderRecord(
                    id: secondFolder,
                    name: "Second",
                    children: [shared, secondOnly]
                ),
            ]
        )

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages == [[.app(root), .folder(firstFolder), .app(secondOnly)]])
        #expect(result.folders[firstFolder]?.children == [shared, firstOnly])
        #expect(result.folders[secondFolder] == nil)
    }

    @Test("孤儿文件夹按 rawValue 排序恢复,单 child 转为应用,空记录丢弃")
    func orphanFoldersAreRestoredDeterministically() throws {
        let root = try #require(AppID("/Applications/Root.app"))
        let shared = try #require(AppID("/Applications/Shared.app"))
        let alphaOnly = try #require(AppID("/Applications/AlphaOnly.app"))
        let single = try #require(AppID("/Applications/Single.app"))
        let zetaOnly = try #require(AppID("/Applications/ZetaOnly.app"))
        let alpha = try #require(FolderID("Alpha"))
        let empty = try #require(FolderID("Empty"))
        let singleFolder = try #require(FolderID("Single"))
        let zeta = try #require(FolderID("Zeta"))
        let catalog = try catalog(
            "/Applications/Root.app",
            "/Applications/Shared.app",
            "/Applications/AlphaOnly.app",
            "/Applications/Single.app",
            "/Applications/ZetaOnly.app"
        )
        let layout = layout(
            pages: [[.app(root)]],
            folders: [
                zeta: FolderRecord(id: zeta, name: "Zeta", children: [shared, zetaOnly]),
                empty: FolderRecord(id: empty, name: "Empty"),
                singleFolder: FolderRecord(id: singleFolder, name: "Single", children: [single]),
                alpha: FolderRecord(id: alpha, name: "Alpha", children: [shared, alphaOnly]),
            ]
        )

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages == [[
            .app(root),
            .folder(alpha),
            .app(single),
            .app(zetaOnly),
        ]])
        #expect(result.folders.count == 1)
        #expect(result.folders[alpha]?.children == [shared, alphaOnly])
        #expect(result.folders[empty] == nil)
        #expect(result.folders[singleFolder] == nil)
        #expect(result.folders[zeta] == nil)
    }

    @Test("归一化幂等且保留未过期墓碑")
    func normalizationIsIdempotentAndPreservesTombstones() throws {
        let first = try #require(AppID("/Applications/First.app"))
        let second = try #require(AppID("/Applications/Second.app"))
        let gone = try #require(AppID("/Applications/Gone.app"))
        let folderID = try #require(FolderID("F"))
        let missingSince = now.addingTimeInterval(-1)
        let catalog = try catalog("/Applications/First.app", "/Applications/Second.app")
        let layout = layout(
            pages: [[.app(first), .app(first), .folder(folderID)]],
            folders: [folderID: FolderRecord(
                id: folderID,
                name: "F",
                children: [first, second]
            )],
            missingApps: [gone: MissingAppState(missingSince: missingSince)]
        )

        let once = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)
        let twice = LayoutReconciler.reconcile(catalog: catalog, layout: once, now: now)

        #expect(once == twice)
        #expect(once.missingApps[gone]?.missingSince == missingSince)
        #expect(!once.referencedAppIDs.contains(gone))
    }

    @Test("隐藏应用与对账无关: 布局引用即保留")
    func hiddenAppsNotReconciled() throws {
        let app = try #require(AppID("/Applications/A.app"))
        let catalog = try catalog("/Applications/A.app")
        let layout = layout(pages: [[.app(app)]])

        let result = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(result.pages[0] == [.app(app)])
    }

    @Test("全量对账确定性: 相同输入相同输出")
    func deterministicReconcile() throws {
        let a = try #require(AppID("/Applications/A.app"))
        let b = try #require(AppID("/Applications/B.app"))
        let gone = try #require(AppID("/Applications/Gone.app"))
        let folderID = try #require(FolderID("F"))
        let catalog = try catalog("/Applications/A.app", "/Applications/B.app")
        let layout = layout(
            pages: [[.app(a), .app(gone), .folder(folderID)]],
            folders: [folderID: FolderRecord(id: folderID, name: "F", children: [b])],
            missingApps: [gone: MissingAppState(missingSince: now)]
        )

        let r1 = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)
        let r2 = LayoutReconciler.reconcile(catalog: catalog, layout: layout, now: now)

        #expect(r1 == r2)
    }
}
