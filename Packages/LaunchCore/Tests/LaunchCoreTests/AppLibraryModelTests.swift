import Foundation
import Testing
@testable import LaunchCore

private let e3Now = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("AppLibrary model")
struct AppLibraryModelTests {
    private func makeRecord(
        _ path: String,
        name: String,
        category: String? = nil,
        bundle: String? = nil,
        localized: [String: String] = [:]
    ) throws -> AppRecord {
        let id = try #require(AppID(path))
        return AppRecord(
            id: id,
            url: URL(fileURLWithPath: path),
            bundleIdentifier: bundle,
            displayName: name,
            infoPlistModificationDate: nil,
            iconContentVersion: .empty,
            localizedNames: localized,
            categoryIdentifier: category
        )
    }

    private func build(
        catalog: CatalogSnapshot,
        hidden: Set<AppID> = [],
        customNames: [AppID: String] = [:],
        metadata: AppLibraryMetadataSnapshot? = nil,
        overrides: [AppID: AppLibraryCategory] = [:],
        fallback: [AppID] = [],
        now: Date = e3Now
    ) -> AppLibraryModel {
        AppLibraryModelBuilder.build(AppLibraryModelBuilder.Inputs(
            catalog: catalog,
            hiddenAppIDs: hidden,
            customDisplayNames: customNames,
            language: .english,
            systemPreferredLanguages: ["en"],
            metadata: metadata,
            categoryOverrides: overrides,
            page1FallbackAppIDs: fallback,
            now: now
        ))
    }

    private func card(
        with id: AppLibraryCardID,
        in model: AppLibraryModel
    ) -> AppLibraryCard? {
        model.cards.first { $0.id == id }
    }

    // MARK: - 分类

    @Test("已知分类映射; nil/空/未知 → Other; graphics/photo → Creativity; 大小写归一")
    func classification() {
        #expect(AppLibraryCategoryClassifier.classify("public.app-category.productivity") == .productivity)
        #expect(AppLibraryCategoryClassifier.classify("public.app-category.social-networking") == .social)
        #expect(AppLibraryCategoryClassifier.classify("public.app-category.developer-tools") == .developer)
        #expect(AppLibraryCategoryClassifier.classify("public.app-category.entertainment") == .entertainment)
        #expect(AppLibraryCategoryClassifier.classify("public.app-category.games") == .games)
        #expect(AppLibraryCategoryClassifier.classify("public.app-category.graphics-design") == .creativity)
        #expect(AppLibraryCategoryClassifier.classify("public.app-category.photo-video") == .creativity)
        #expect(AppLibraryCategoryClassifier.classify("public.app-category.utilities") == .utilities)
        #expect(AppLibraryCategoryClassifier.classify("public.app-category.education") == .education)
        #expect(AppLibraryCategoryClassifier.classify("public.app-category.business") == .business)
        #expect(AppLibraryCategoryClassifier.classify("public.app-category.finance") == .finance)

        #expect(AppLibraryCategoryClassifier.classify(nil) == .other)
        #expect(AppLibraryCategoryClassifier.classify("") == .other)
        #expect(AppLibraryCategoryClassifier.classify("   ") == .other)
        #expect(AppLibraryCategoryClassifier.classify("public.app-category.music") == .other)
        #expect(AppLibraryCategoryClassifier.classify("totally.unknown") == .other)

        #expect(AppLibraryCategoryClassifier.classify("Public.App-Category.Games") == .games)
        #expect(AppLibraryCategoryClassifier.classify("  PUBLIC.APP-CATEGORY.UTILITIES ") == .utilities)
    }

    // MARK: - PA2 手动分类覆盖

    /// QQ 合成记录: bundle=com.tencent.qq + 自报 developer-tools。
    private func makeQQRecord() throws -> AppRecord {
        try makeRecord(
            "/Applications/QQ.app",
            name: "QQ",
            category: "public.app-category.developer-tools",
            bundle: "com.tencent.qq"
        )
    }

    /// WeChat 对照记录: bundle=com.tencent.xinWeChat + 正常自报 social。
    private func makeWeChatRecord() throws -> AppRecord {
        try makeRecord(
            "/Applications/WeChat.app",
            name: "WeChat",
            category: "public.app-category.social-networking",
            bundle: "com.tencent.xinWeChat"
        )
    }

    private func effectiveCategory(of appID: AppID, in model: AppLibraryModel) -> AppLibraryCategory? {
        for (category, ids) in model.categoryDetail where ids.contains(appID) {
            return category
        }
        return nil
    }

    @Test("bundle 校正: QQ(自报 developer-tools)无覆盖时经 com.tencent.qq → social")
    func bundleCorrectionQQ() throws {
        let qq = try makeQQRecord()
        let wechat = try makeWeChatRecord()
        let model = build(catalog: CatalogSnapshot(apps: [qq, wechat]))

        #expect(AppLibraryCategoryClassifier.classify("public.app-category.developer-tools") == .developer)
        #expect(AppLibraryCategoryClassifier.bundleCategoryCorrections["com.tencent.qq"] == .social)
        let socialCard = try #require(card(with: .category(.social), in: model))
        // QQ 经校正进入 social(不进入 developer); stable tie: "QQ" < "WeChat"
        #expect(socialCard.detailAppIDs == [qq.id, wechat.id])
        #expect(card(with: .category(.developer), in: model) == nil)
        #expect(effectiveCategory(of: qq.id, in: model) == .social)
        // 记录本身未被改写
        #expect(qq.categoryIdentifier == "public.app-category.developer-tools")
        #expect(qq.bundleIdentifier == "com.tencent.qq")
    }

    @Test("覆盖优先: 手动覆盖 > bundle 校正 > 分类器; 移除覆盖恢复自动")
    func overridePriorityAndClear() throws {
        let qq = try makeQQRecord()
        let wechat = try makeWeChatRecord()
        let catalog = CatalogSnapshot(apps: [qq, wechat])

        let overridden = build(catalog: catalog, overrides: [qq.id: .games])
        #expect(effectiveCategory(of: qq.id, in: overridden) == .games)

        let overriddenOther = build(catalog: catalog, overrides: [qq.id: .other])
        #expect(effectiveCategory(of: qq.id, in: overriddenOther) == .other)

        // 移除覆盖(空表)→ 恢复 bundle 校正 → social(与 WeChat 同卡)
        let cleared = build(catalog: catalog, overrides: [:])
        #expect(effectiveCategory(of: qq.id, in: cleared) == .social)
        let socialCard = try #require(card(with: .category(.social), in: cleared))
        #expect(socialCard.detailAppIDs == [qq.id, wechat.id])
    }

    @Test("覆盖到稀疏分类: < 2 个 app 且含手动覆盖 → 保留为独立卡, 不并入 Other")
    func manualOverrideKeepsSparseCategoryCard() throws {
        let utilities = try makeRecord(
            "/Applications/OnlyUtils.app",
            name: "Only Utils",
            category: "public.app-category.developer-tools"
        )
        let games = try makeRecord(
            "/Applications/LonelyGame.app",
            name: "Lonely Game",
            category: "public.app-category.games"
        )
        let catalog = CatalogSnapshot(apps: [utilities, games])

        // 无覆盖: 两个单 app 分类都并入 Other
        let without = build(catalog: catalog)
        #expect(card(with: .category(.utilities), in: without) == nil)
        #expect(card(with: .category(.games), in: without) == nil)
        #expect(card(with: .category(.other), in: without) != nil)

        // 覆盖到 utilities → utilities 保留为独立卡
        let with = build(catalog: catalog, overrides: [utilities.id: .utilities])
        let utilitiesCard = try #require(card(with: .category(.utilities), in: with))
        #expect(utilitiesCard.detailAppIDs == [utilities.id])
        // games(无覆盖, 稀疏)仍并入 Other
        let other = try #require(card(with: .category(.other), in: with))
        #expect(other.detailAppIDs == [games.id])
        // 分区完整性: 每个可见 app 恰好一个分类
        let covered = Set(with.categoryDetail.values.flatMap { $0 })
        #expect(covered == [utilities.id, games.id])
    }

    @Test("覆盖进 Other: 保持可见(Other 恒不参与合并)")
    func manualOverrideToOtherVisible() throws {
        let qq = try makeQQRecord()
        let model = build(catalog: CatalogSnapshot(apps: [qq]), overrides: [qq.id: .other])

        let other = try #require(card(with: .category(.other), in: model))
        #expect(other.detailAppIDs == [qq.id])
    }

    @Test("schema v2: categoryOverrides 编码往返一致 + schemaVersion=2")
    func metadataV2OverrideRoundTrip() throws {
        let qq = try #require(AppID("/Applications/QQ.app"))
        let metadata = AppLibraryMetadataSnapshot(
            usage: [qq: AppLibraryUsageRecord(launchCount: 2, lastLaunchedAt: e3Now)],
            firstSeen: [qq: e3Now],
            isBootstrapped: true,
            categoryOverrides: [qq: .social]
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(AppLibraryMetadataSnapshot.self, from: data)

        #expect(decoded == metadata)
        #expect(decoded.schemaVersion == 2)
        #expect(decoded.categoryOverrides == [qq: .social])
    }

    @Test("旧 schema(无 categoryOverrides)迁移 → [], usage/firstSeen 保留")
    func legacySchemaMigratesToEmptyOverrides() throws {
        let qq = try #require(AppID("/Applications/QQ.app"))
        // 自定义 key 字典在 JSON 中是交替数组形式(与既有持久化格式一致);
        // Date 按 JSONDecoder 默认策略解码为 timeIntervalSinceReferenceDate。
        let legacy = """
        {"schemaVersion": 1, "usage": ["\(qq.rawValue)", {"launchCount": 3}], "firstSeen": ["\(qq.rawValue)", \(e3Now.timeIntervalSinceReferenceDate)], "isBootstrapped": true}
        """
        let migrated = try JSONDecoder().decode(
            AppLibraryMetadataSnapshot.self,
            from: Data(legacy.utf8)
        )
        #expect(migrated.categoryOverrides.isEmpty)
        #expect(migrated.usage[qq] == AppLibraryUsageRecord(launchCount: 3, lastLaunchedAt: nil))
        #expect(migrated.isBootstrapped)
        #expect(migrated.firstSeen[qq] == e3Now)
        #expect(migrated.schemaVersion == 1)
    }

    @Test("覆盖只影响展示分类: 同一输入 + 不同覆盖 → 仅分类位置不同, 记录不变")
    func overrideDoesNotMutateRecord() throws {
        let qq = try makeQQRecord()
        let catalog = CatalogSnapshot(apps: [qq])
        _ = build(catalog: catalog, overrides: [qq.id: .finance])
        #expect(qq.categoryIdentifier == "public.app-category.developer-tools")
        #expect(catalog.apps.first?.id == qq.id)
        #expect(catalog.apps.first?.categoryIdentifier == "public.app-category.developer-tools")
    }

    // MARK: - 过滤与来源等价

    @Test("hidden 与不在 catalog 的 app 不进入任何 card/detail")
    func hiddenAndMissingFiltering() throws {
        let visible = try makeRecord("/Applications/Visible.app", name: "Visible", category: "public.app-category.productivity")
        let hidden = try makeRecord("/Applications/Hidden.app", name: "Hidden", category: "public.app-category.games")
        let ghost = try makeRecord("/Applications/Ghost.app", name: "Ghost", category: "public.app-category.education")
        let catalog = CatalogSnapshot(apps: [visible, hidden])

        let model = build(
            catalog: catalog,
            hidden: [hidden.id],
            fallback: [ghost.id, hidden.id, visible.id]
        )

        let allDetail = model.cards.flatMap(\.detailAppIDs)
        #expect(allDetail.contains(visible.id))
        #expect(!allDetail.contains(hidden.id))
        #expect(!allDetail.contains(ghost.id))

        let found = card(with: .suggestions, in: model)
        let suggestions = try #require(found)
        #expect(suggestions.primaryAppIDs.contains(visible.id))
        #expect(!suggestions.primaryAppIDs.contains(hidden.id))
        #expect(!suggestions.primaryAppIDs.contains(ghost.id))
    }

    @Test("自定义来源 record 与普通 record 等价(分类/排名无来源分支)")
    func customSourceRecordEquivalent() throws {
        let normal = try makeRecord("/Applications/Normal.app", name: "Normal", category: "public.app-category.productivity")
        let custom = try makeRecord("/Users/me/Tools/Custom.app", name: "Custom", category: "public.app-category.productivity")
        let catalog = CatalogSnapshot(apps: [custom, normal])

        let model = build(catalog: catalog)

        let found = card(with: .category(.productivity), in: model)
        let appCard = try #require(found)
        // 无 usage → 稳定 tie-break: displayName "Custom" < "Normal"
        #expect(appCard.detailAppIDs == [custom.id, normal.id])
        #expect(appCard.primaryAppIDs == [custom.id, normal.id])
    }

    // MARK: - 名称优先级

    @Test("custom name > 当前语言 localized name > displayName")
    func namePriority() throws {
        let record = try makeRecord(
            "/Applications/A.app",
            name: "Fallback",
            category: "public.app-category.productivity",
            localized: ["zh-Hans": "中文名", "en": "English Name"]
        )
        let resolve: (String?, AppLanguage, [String]) -> String = { custom, language, system in
            AppLibraryModelBuilder.displayName(
                for: record,
                customName: custom,
                language: language,
                systemPreferredLanguages: system
            )
        }

        #expect(resolve(nil, .english, ["en"]) == "English Name")
        #expect(resolve(nil, .simplifiedChinese, ["zh-Hans"]) == "中文名")
        #expect(resolve(nil, .system, ["zh-Hans"]) == "中文名")
        #expect(resolve(nil, .system, ["zh-Hant"]) == "Fallback")
        #expect(resolve("我的名字", .english, ["en"]) == "我的名字")
        #expect(resolve("", .english, ["en"]) == "English Name")
    }

    @Test("模型内 custom name 参与稳定排名")
    func customNameAffectsOrdering() throws {
        let a = try makeRecord("/Applications/A.app", name: "A", category: "public.app-category.productivity")
        let b = try makeRecord("/Applications/B.app", name: "B", category: "public.app-category.productivity")
        let catalog = CatalogSnapshot(apps: [a, b])

        let model = build(catalog: catalog, customNames: [b.id: "0Custom"])

        let found = card(with: .category(.productivity), in: model)
        let appCard = try #require(found)
        #expect(appCard.detailAppIDs == [b.id, a.id])
    }

    // MARK: - 合并与顺序

    @Test("单 app 普通分类并入 Other; Other 非空才生成; 固定 category 顺序; 稳定 card id")
    func compactionAndOrdering() throws {
        let p1 = try makeRecord("/Applications/P1.app", name: "P1", category: "public.app-category.productivity")
        let p2 = try makeRecord("/Applications/P2.app", name: "P2", category: "public.app-category.productivity")
        let g1 = try makeRecord("/Applications/G1.app", name: "G1", category: "public.app-category.games")
        let u1 = try makeRecord("/Applications/U1.app", name: "U1", category: "public.app-category.utilities")
        let catalog = CatalogSnapshot(apps: [p1, p2, g1, u1])

        let first = build(catalog: catalog)
        let second = build(catalog: catalog)

        #expect(first == second)
        let ids = first.cards.map(\.id)
        #expect(ids == [.suggestions, .category(.productivity), .category(.other)])

        let other = try #require(card(with: .category(.other), in: first))
        #expect(other.detailAppIDs == [g1.id, u1.id])
        #expect(other.primaryAppIDs == [g1.id, u1.id])

        #expect(first.categoryDetail[.productivity] == [p1.id, p2.id])
        #expect(first.categoryDetail[.other] == [g1.id, u1.id])
        #expect(first.categoryDetail[.games] == nil)
        #expect(first.categoryDetail[.utilities] == nil)
    }

    // MARK: - Ranking

    @Test("最近高频 > 旧高频; 最近低频(decay) > 旧高频; 同桶内 count 决定")
    func rankingRecencyAndDecay() throws {
        let a = try makeRecord("/Applications/A.app", name: "A", category: "public.app-category.productivity")
        let b = try makeRecord("/Applications/B.app", name: "B", category: "public.app-category.productivity")
        let c = try makeRecord("/Applications/C.app", name: "C", category: "public.app-category.productivity")
        let catalog = CatalogSnapshot(apps: [a, b, c])
        let metadata = AppLibraryMetadataSnapshot(usage: [
            a.id: AppLibraryUsageRecord(launchCount: 5, lastLaunchedAt: e3Now.addingTimeInterval(-2 * 86_400)),
            b.id: AppLibraryUsageRecord(launchCount: 5, lastLaunchedAt: e3Now.addingTimeInterval(-60 * 86_400)),
            c.id: AppLibraryUsageRecord(launchCount: 3, lastLaunchedAt: e3Now.addingTimeInterval(-86_400)),
        ])

        let model = build(catalog: catalog, metadata: metadata)

        let found = card(with: .category(.productivity), in: model)
        let appCard = try #require(found)
        // a(近,5) > c(近,3) > b(旧,5): recency 桶优先,桶内 count 降序,decay 使 c > b
        #expect(appCard.detailAppIDs == [a.id, c.id, b.id])
    }

    @Test("frequent > never-used")
    func rankingFrequentOverNeverUsed() throws {
        let used = try makeRecord("/Applications/Used.app", name: "Used", category: "public.app-category.productivity")
        let never = try makeRecord("/Applications/Never.app", name: "Never", category: "public.app-category.productivity")
        let catalog = CatalogSnapshot(apps: [used, never])
        let metadata = AppLibraryMetadataSnapshot(usage: [
            used.id: AppLibraryUsageRecord(launchCount: 1, lastLaunchedAt: e3Now.addingTimeInterval(-10 * 86_400)),
        ])

        let model = build(catalog: catalog, metadata: metadata)

        let found = card(with: .category(.productivity), in: model)
        let appCard = try #require(found)
        #expect(appCard.detailAppIDs == [used.id, never.id])
        // primary 容量 3 ≥ 2,两 app 都进入 primary(used 在前)
        #expect(appCard.primaryAppIDs == [used.id, never.id])
    }

    @Test("tie 确定: 相同 usage 按 displayName, 再按 AppID")
    func rankingTieDeterministic() throws {
        let alpha = try makeRecord("/Applications/Alpha.app", name: "Alpha", category: "public.app-category.productivity")
        let beta = try makeRecord("/Applications/Beta.app", name: "Beta", category: "public.app-category.productivity")
        let sameX = try makeRecord("/Applications/X.app", name: "Same", category: "public.app-category.productivity")
        let sameY = try makeRecord("/Applications/Y.app", name: "Same", category: "public.app-category.productivity")
        let catalog = CatalogSnapshot(apps: [beta, alpha, sameY, sameX])
        let metadata = AppLibraryMetadataSnapshot(usage: [
            alpha.id: AppLibraryUsageRecord(launchCount: 3, lastLaunchedAt: e3Now.addingTimeInterval(-5 * 86_400)),
            beta.id: AppLibraryUsageRecord(launchCount: 3, lastLaunchedAt: e3Now.addingTimeInterval(-5 * 86_400)),
            sameX.id: AppLibraryUsageRecord(launchCount: 2, lastLaunchedAt: e3Now.addingTimeInterval(-86_400)),
            sameY.id: AppLibraryUsageRecord(launchCount: 2, lastLaunchedAt: e3Now.addingTimeInterval(-86_400)),
        ])

        let model = build(catalog: catalog, metadata: metadata)

        let found = card(with: .category(.productivity), in: model)
        let appCard = try #require(found)
        #expect(appCard.detailAppIDs == [alpha.id, beta.id, sameX.id, sameY.id])
    }

    // MARK: - Suggestions

    @Test("cold start: 无 usage 用 Page 1 fallback, 再 stable order 补齐, 最多 4")
    func coldStartPage1Fallback() throws {
        let apps = try (0..<6).map { index in
            try makeRecord(
                "/Applications/App\(index).app",
                name: "App \(index)",
                category: "public.app-category.productivity"
            )
        }
        let catalog = CatalogSnapshot(apps: apps)
        let fallback = [apps[4].id, apps[5].id, apps[3].id]

        let model = build(catalog: catalog, fallback: fallback)

        let found = card(with: .suggestions, in: model)
        let suggestions = try #require(found)
        // fallback 按给定顺序 + stable order(displayName)补齐
        #expect(suggestions.primaryAppIDs == [apps[4].id, apps[5].id, apps[3].id, apps[0].id])
        #expect(suggestions.primaryAppIDs.count == 4)
    }

    @Test("有 usage 时 Suggestions 按 rank 取前 4, 不再用 fallback")
    func suggestionsUseRankingWhenUsageExists() throws {
        let a = try makeRecord("/Applications/A.app", name: "A", category: "public.app-category.productivity")
        let b = try makeRecord("/Applications/B.app", name: "B", category: "public.app-category.productivity")
        let catalog = CatalogSnapshot(apps: [a, b])
        let metadata = AppLibraryMetadataSnapshot(usage: [
            b.id: AppLibraryUsageRecord(launchCount: 2, lastLaunchedAt: e3Now.addingTimeInterval(-86_400)),
        ])

        let model = build(catalog: catalog, metadata: metadata, fallback: [a.id])

        let found = card(with: .suggestions, in: model)
        let suggestions = try #require(found)
        #expect(suggestions.primaryAppIDs == [b.id, a.id])
    }

    // MARK: - Recently Added

    @Test("recently added 需 bootstrap; 未 bootstrap 即使有 firstSeen 也不生成")
    func recentlyAddedRequiresBootstrap() throws {
        let x = try makeRecord("/Applications/X.app", name: "X", category: "public.app-category.productivity")
        let y = try makeRecord("/Applications/Y.app", name: "Y", category: "public.app-category.productivity")
        let catalog = CatalogSnapshot(apps: [x, y])
        let unbootstrapped = AppLibraryMetadataSnapshot(
            firstSeen: [x.id: e3Now.addingTimeInterval(-5 * 86_400), y.id: e3Now.addingTimeInterval(-3 * 86_400)],
            isBootstrapped: false
        )

        let without = build(catalog: catalog, metadata: unbootstrapped)
        #expect(card(with: .recentlyAdded, in: without) == nil)

        let bootstrapped = AppLibraryMetadataSnapshot(
            firstSeen: [x.id: e3Now.addingTimeInterval(-5 * 86_400), y.id: e3Now.addingTimeInterval(-3 * 86_400)],
            isBootstrapped: true
        )
        let with = build(catalog: catalog, metadata: bootstrapped)
        let recently = try #require(card(with: .recentlyAdded, in: with))
        // 最新 firstSeen 在前
        #expect(recently.detailAppIDs == [y.id, x.id])
        #expect(recently.primaryAppIDs == [y.id, x.id])
        #expect(with.cards[1].id == .recentlyAdded)
    }

    @Test("recently added 30 天窗口: 边界点排除, 窗口内包含, 未来排除")
    func recentlyAddedWindowBoundary() throws {
        let edge = try makeRecord("/Applications/Edge.app", name: "Edge", category: "public.app-category.productivity")
        let inside = try makeRecord("/Applications/Inside.app", name: "Inside", category: "public.app-category.productivity")
        let future = try makeRecord("/Applications/Future.app", name: "Future", category: "public.app-category.productivity")
        let catalog = CatalogSnapshot(apps: [edge, inside, future])
        let cutoff = e3Now.addingTimeInterval(-AppLibraryTuning.recentlyAddedWindow)
        let metadata = AppLibraryMetadataSnapshot(
            firstSeen: [
                edge.id: cutoff,
                inside.id: cutoff.addingTimeInterval(1),
                future.id: e3Now.addingTimeInterval(3600),
            ],
            isBootstrapped: true
        )

        let model = build(catalog: catalog, metadata: metadata)

        let recently = try #require(card(with: .recentlyAdded, in: model))
        #expect(recently.detailAppIDs == [inside.id])
        #expect(AppLibraryTuning.recentlyAddedWindowDays == 30)
    }

    @Test("bootstrap 后窗口内无新增 → 不生成空 Recently Added 卡")
    func recentlyAddedEmptyNotGenerated() throws {
        let old = try makeRecord("/Applications/Old.app", name: "Old", category: "public.app-category.productivity")
        let catalog = CatalogSnapshot(apps: [old])
        let metadata = AppLibraryMetadataSnapshot(
            firstSeen: [old.id: e3Now.addingTimeInterval(-100 * 86_400)],
            isBootstrapped: true
        )

        let model = build(catalog: catalog, metadata: metadata)

        #expect(card(with: .recentlyAdded, in: model) == nil)
        #expect(!model.cards.contains { $0.detailAppIDs.isEmpty })
    }

    // MARK: - 容量与规模

    @Test("卡片容量: Suggestions ≤ 4; category primary ≤ 3 / mini ≤ 4; detail 全量")
    func cardCapacityLimits() throws {
        let apps = try (0..<15).map { index in
            try makeRecord(
                "/Applications/App\(String(format: "%02d", index)).app",
                name: "App \(String(format: "%02d", index))",
                category: "public.app-category.productivity"
            )
        }
        let catalog = CatalogSnapshot(apps: apps)

        let model = build(catalog: catalog)

        let suggestions = try #require(card(with: .suggestions, in: model))
        #expect(suggestions.primaryAppIDs.count == 4)

        let productivity = try #require(card(with: .category(.productivity), in: model))
        #expect(productivity.primaryAppIDs.count == 3)
        #expect(productivity.miniAppIDs.count == 4)
        #expect(productivity.detailAppIDs.count == 15)
        #expect(productivity.detailAppIDs == apps.map(\.id))
        #expect(Set(productivity.primaryAppIDs).isDisjoint(with: Set(productivity.miniAppIDs)))
    }

    @Test("100/250/500 apps 构建: 重复 build 等值, 卡片与 detail 受限")
    func buildScaleAndRepeatEquality() throws {
        let categories = [
            "public.app-category.productivity",
            "public.app-category.games",
            "public.app-category.utilities",
            "public.app-category.finance",
        ]
        for count in [100, 250, 500] {
            var records: [AppRecord] = []
            var usage: [AppID: AppLibraryUsageRecord] = [:]
            var firstSeen: [AppID: Date] = [:]
            for index in 0..<count {
                let record = try makeRecord(
                    String(format: "/Applications/App%03d.app", index),
                    name: String(format: "App %03d", index),
                    category: categories[index % categories.count]
                )
                records.append(record)
                usage[record.id] = AppLibraryUsageRecord(
                    launchCount: index,
                    lastLaunchedAt: e3Now.addingTimeInterval(-Double(index) * 3600)
                )
                if index % 10 == 0 {
                    firstSeen[record.id] = e3Now.addingTimeInterval(-Double(index) * 86_400)
                }
            }
            let catalog = CatalogSnapshot(apps: records)
            let metadata = AppLibraryMetadataSnapshot(usage: usage, firstSeen: firstSeen, isBootstrapped: true)

            let first = build(catalog: catalog, metadata: metadata)
            let second = build(catalog: catalog, metadata: metadata)

            #expect(first == second)
            #expect(first.cards.count <= 12)
            // categoryDetail 是 partition: 每个可见 app 恰好一次
            let covered = Set(first.categoryDetail.values.flatMap { $0 })
            #expect(covered.count == count)
        }
    }

    // MARK: - 值语义

    @Test("metadata snapshot Codable 往返 + schemaVersion + 迁移默认值")
    func metadataCodableRoundTrip() throws {
        let a = try #require(AppID("/Applications/A.app"))
        let metadata = AppLibraryMetadataSnapshot(
            usage: [a: AppLibraryUsageRecord(launchCount: 3, lastLaunchedAt: e3Now)],
            firstSeen: [a: e3Now],
            isBootstrapped: true
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(AppLibraryMetadataSnapshot.self, from: data)

        #expect(decoded == metadata)
        #expect(AppLibraryMetadataSnapshot.currentSchemaVersion == 2)
        #expect(decoded.schemaVersion == AppLibraryMetadataSnapshot.currentSchemaVersion)

        let legacy = """
        {"schemaVersion": 1, "isBootstrapped": true}
        """
        let migrated = try JSONDecoder().decode(
            AppLibraryMetadataSnapshot.self,
            from: Data(legacy.utf8)
        )
        #expect(migrated.usage.isEmpty)
        #expect(migrated.firstSeen.isEmpty)
        #expect(migrated.isBootstrapped)
    }

    @Test("模型跨 Task 边界 Sendable 且值稳定")
    func sendableAcrossTasks() async throws {
        let a = try makeRecord("/Applications/A.app", name: "A", category: "public.app-category.productivity")
        let model = build(catalog: CatalogSnapshot(apps: [a]))

        let ids = await Task.detached {
            model.cards.map(\.id)
        }.value

        #expect(ids == [.suggestions, .category(.other)])
    }
}
