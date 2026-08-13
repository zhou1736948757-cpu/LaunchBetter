import Foundation

/// App Library 分类(固定优先级,枚举声明顺序即 category card 顺序,Other 恒最后)。
///
/// 纯值类型;不持有 AppKit / 文件系统引用。
public enum AppLibraryCategory: String, Codable, Hashable, Sendable, CaseIterable {
    case productivity
    case social
    case developer
    case entertainment
    case games
    case creativity
    case utilities
    case education
    case business
    case finance
    case other
}

/// 从原始 `LSApplicationCategoryType` 做确定性分类映射。
///
/// 归一规则: trim 空白 + 小写后查固定映射表;nil / 空 / 未知一律进入 `.other`。
/// 无随机数、无网络、无 ML;同一输入恒得同一输出。
public enum AppLibraryCategoryClassifier {
    public static func classify(_ categoryIdentifier: String?) -> AppLibraryCategory {
        guard let raw = categoryIdentifier else { return .other }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return .other }
        return mapping[key] ?? .other
    }

    /// bundle-ID 校正表(极小, 证据充分的语义错误才允许加入)。
    ///
    /// QQ 自报 `developer-tools` 语义错误(实为即时通讯);分类器
    /// `developer-tools → .developer` 正确, 是自报数据错误 → 按 bundle 校正到 `.social`。
    /// 只允许此最小表;禁止名字启发式、无网络/AI。
    public static let bundleCategoryCorrections: [String: AppLibraryCategory] = [
        "com.tencent.qq": .social,
    ]

    /// 原始 `LSApplicationCategoryType` → 归一分类(小写规范键)。
    static let mapping: [String: AppLibraryCategory] = [
        "public.app-category.productivity": .productivity,
        "public.app-category.social-networking": .social,
        "public.app-category.developer-tools": .developer,
        "public.app-category.entertainment": .entertainment,
        "public.app-category.games": .games,
        "public.app-category.graphics-design": .creativity,
        "public.app-category.photo-video": .creativity,
        "public.app-category.utilities": .utilities,
        "public.app-category.education": .education,
        "public.app-category.business": .business,
        "public.app-category.finance": .finance,
    ]
}

/// 单应用使用记录(usage 元数据,persistence 层采集)。
public struct AppLibraryUsageRecord: Codable, Equatable, Sendable {
    /// 启动次数(归一化 ≥ 0)。
    public let launchCount: Int

    /// 最近一次启动时间;从未启动过则为 nil。
    public let lastLaunchedAt: Date?

    public init(launchCount: Int, lastLaunchedAt: Date?) {
        self.launchCount = max(0, launchCount)
        self.lastLaunchedAt = lastLaunchedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchCount = max(0, try container.decodeIfPresent(Int.self, forKey: .launchCount) ?? 0)
        lastLaunchedAt = try container.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case launchCount
        case lastLaunchedAt
    }
}

/// App Library 元数据快照(usage / firstSeen / bootstrap marker / category overrides)。
///
/// 独立于 Layout;属于持久化用户数据,必须带 schemaVersion。
/// 迁移约定: 缺字段按默认值解码,不抛错、不销毁旧数据。
///
/// schema v2(PA2): 新增 `categoryOverrides`(手动分类覆盖)。旧文件缺该字段 →
/// `decodeIfPresent ?? [:]`,不抛错、不销毁 usage/firstSeen。
public struct AppLibraryMetadataSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int

    /// AppID → 使用记录。
    public let usage: [AppID: AppLibraryUsageRecord]

    /// AppID → 首次发现时间(真实新增信号)。
    public let firstSeen: [AppID: Date]

    /// bootstrap 完成标记。
    /// bootstrap 前收集的 firstSeen 是基线,不能作为"新增";
    /// 仅 bootstrap 完成后新出现/更新的 firstSeen 才算 Recently Added 候选。
    public let isBootstrapped: Bool

    /// AppID → 手动分类覆盖(用户显式指定;覆盖优先于 bundle 校正与分类器)。
    /// 覆盖不进入 LayoutStore、不改 AppRecord.categoryIdentifier。
    public let categoryOverrides: [AppID: AppLibraryCategory]

    public init(
        usage: [AppID: AppLibraryUsageRecord] = [:],
        firstSeen: [AppID: Date] = [:],
        isBootstrapped: Bool = false,
        categoryOverrides: [AppID: AppLibraryCategory] = [:]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.usage = usage
        self.firstSeen = firstSeen
        self.isBootstrapped = isBootstrapped
        self.categoryOverrides = categoryOverrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        usage = try container.decodeIfPresent([AppID: AppLibraryUsageRecord].self, forKey: .usage) ?? [:]
        firstSeen = try container.decodeIfPresent([AppID: Date].self, forKey: .firstSeen) ?? [:]
        isBootstrapped = try container.decodeIfPresent(Bool.self, forKey: .isBootstrapped) ?? false
        categoryOverrides = try container.decodeIfPresent(
            [AppID: AppLibraryCategory].self, forKey: .categoryOverrides
        ) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case usage
        case firstSeen
        case isBootstrapped
        case categoryOverrides
    }
}

/// App Library 中的单个 app(纯值: 身份 + 已解析显示名 + 分类)。
public struct AppLibraryApp: Codable, Hashable, Sendable {
    public let id: AppID

    /// 已解析显示名(custom > 当前语言 localized > AppRecord.displayName)。
    public let displayName: String

    public let category: AppLibraryCategory

    public init(id: AppID, displayName: String, category: AppLibraryCategory) {
        self.id = id
        self.displayName = displayName
        self.category = category
    }
}

/// App Library card 稳定身份。
///
/// 身份只描述"是哪张卡",绝不包含当前 app 数组 —— app 变化不得改变 card 身份。
public enum AppLibraryCardID: Hashable, Sendable {
    case suggestions
    case recentlyAdded
    case category(AppLibraryCategory)
}

/// App Library 中的一张卡(纯值,只保存 AppID)。
///
/// 容量约定由 Builder 保证:
/// - Suggestions 卡 primary 最多 `AppLibraryTuning.suggestionsCardLimit`(4,产品约束)
/// - 其它卡 primary 最多 `AppLibraryTuning.categoryPrimaryLimit`(3)
/// - mini 区最多 `AppLibraryTuning.miniLimit`(4)
/// - `detailAppIDs` 为该卡的完整 app 列表(全量 payload)
public struct AppLibraryCard: Equatable, Sendable {
    public let id: AppLibraryCardID

    /// 主要区 apps(直接启动)。
    public let primaryAppIDs: [AppID]

    /// mini 区 apps。
    public let miniAppIDs: [AppID]

    /// 全量 app 列表(该卡完整 payload)。
    public let detailAppIDs: [AppID]

    public init(
        id: AppLibraryCardID,
        primaryAppIDs: [AppID],
        miniAppIDs: [AppID],
        detailAppIDs: [AppID]
    ) {
        self.id = id
        self.primaryAppIDs = primaryAppIDs
        self.miniAppIDs = miniAppIDs
        self.detailAppIDs = detailAppIDs
    }
}

/// App Library 读模型(从 Catalog / hidden / custom names / metadata 派生)。
///
/// 只保存值和 IDs,不持有 UI 对象;`categoryDetail` 是全量分类 payload
/// (partition: 每个可见 app 恰好属于一个分类,含合并进 Other 的)。
public struct AppLibraryModel: Equatable, Sendable {
    /// 有序 cards: [Suggestions?, RecentlyAdded?, 固定优先级的分类卡...]。
    public let cards: [AppLibraryCard]

    /// 分类 → 该分类全量 app ID 列表(rank 顺序)。
    public let categoryDetail: [AppLibraryCategory: [AppID]]

    public init(
        cards: [AppLibraryCard],
        categoryDetail: [AppLibraryCategory: [AppID]]
    ) {
        self.cards = cards
        self.categoryDetail = categoryDetail
    }
}

/// App Library 构建常量(集中定义,可测试)。
public enum AppLibraryTuning {
    /// Suggestions 卡最多直接启动 App 数。
    public static let suggestionsCardLimit = 4

    /// 分类卡 primary 区最多 App 数。
    public static let categoryPrimaryLimit = 3

    /// 分类卡 mini 区最多 App 数。
    public static let miniLimit = 4

    /// 少于该数量的普通分类合并到 Other(避免稀疏卡)。
    public static let categoryCardMinimumAppCount = 2

    /// Recently Added 默认窗口天数。
    public static let recentlyAddedWindowDays = 30

    /// SuggestionRanker "recent" 桶天数(最近使用 > 旧使用,仅 Suggestions 卡)。
    public static let recentUsageWindowDays = 30

    public static let secondsPerDay: TimeInterval = 86_400

    public static var recentlyAddedWindow: TimeInterval {
        TimeInterval(recentlyAddedWindowDays) * secondsPerDay
    }

    public static var recentUsageWindow: TimeInterval {
        TimeInterval(recentUsageWindowDays) * secondsPerDay
    }
}

/// App Library 模型构建器(纯逻辑,memory-only)。
///
/// 不修改 LayoutSnapshot、不做 IO、不产生 UI 对象;输入相同 → 输出恒等。
public struct AppLibraryModelBuilder: Sendable {
    /// 构建输入。
    public struct Inputs: Sendable {
        public let catalog: CatalogSnapshot
        public let hiddenAppIDs: Set<AppID>
        public let customDisplayNames: [AppID: String]
        public let language: AppLanguage
        public let systemPreferredLanguages: [String]
        public let metadata: AppLibraryMetadataSnapshot?
        /// 手动分类覆盖(用户显式指定;优先级最高, 覆盖 bundle 校正与分类器)。
        public let categoryOverrides: [AppID: AppLibraryCategory]
        /// 布局第 1 页可见 app IDs(cold start Suggestions fallback,调用方从 DisplayModel 派生)。
        public let page1FallbackAppIDs: [AppID]
        public let now: Date

        public init(
            catalog: CatalogSnapshot,
            hiddenAppIDs: Set<AppID> = [],
            customDisplayNames: [AppID: String] = [:],
            language: AppLanguage = .system,
            systemPreferredLanguages: [String] = [],
            metadata: AppLibraryMetadataSnapshot? = nil,
            categoryOverrides: [AppID: AppLibraryCategory] = [:],
            page1FallbackAppIDs: [AppID] = [],
            now: Date = Date()
        ) {
            self.catalog = catalog
            self.hiddenAppIDs = hiddenAppIDs
            self.customDisplayNames = customDisplayNames
            self.language = language
            self.systemPreferredLanguages = systemPreferredLanguages
            self.metadata = metadata
            self.categoryOverrides = categoryOverrides
            self.page1FallbackAppIDs = page1FallbackAppIDs
            self.now = now
        }
    }

    /// 解析显示名: custom name > 当前语言 localized name > AppRecord.displayName。
    /// 空 custom name 视为未提供(回退)。
    public static func displayName(
        for record: AppRecord,
        customName: String?,
        language: AppLanguage,
        systemPreferredLanguages: [String]
    ) -> String {
        if let custom = customName, !custom.isEmpty {
            return custom
        }
        if let localized = record.localizedDisplayName(
            language: language,
            systemPreferredLanguages: systemPreferredLanguages
        ), !localized.isEmpty {
            return localized
        }
        return record.displayName
    }

    public static func build(_ inputs: Inputs) -> AppLibraryModel {
        let visible = inputs.catalog.apps.filter { !inputs.hiddenAppIDs.contains($0.id) }
        // Page1 顺序作为冷启动熟悉度先验的 ranking 输入(只读, 不改 Layout)。
        let page1Order: [AppID: Int] = Dictionary(
            inputs.page1FallbackAppIDs.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let isCategoryHigherRank: (ResolvedApp, ResolvedApp) -> Bool = { lhs, rhs in
            CategoryCommonRanker.less(lhs: lhs, rhs: rhs, inputs: inputs, page1Order: page1Order)
        }
        let isSuggestionHigherRank: (ResolvedApp, ResolvedApp) -> Bool = { lhs, rhs in
            SuggestionRanker.less(lhs: lhs, rhs: rhs, now: inputs.now)
        }

        var grouped: [AppLibraryCategory: [ResolvedApp]] = [:]
        var hasManualOverride: [AppLibraryCategory: Bool] = [:]
        for record in visible {
            let resolved = resolve(record, inputs: inputs)
            grouped[resolved.app.category, default: []].append(resolved)
            if inputs.categoryOverrides[record.id] != nil {
                hasManualOverride[resolved.app.category, default: false] = true
            }
        }
        for category in AppLibraryCategory.allCases {
            grouped[category]?.sort(by: isCategoryHigherRank)
        }

        // 单 app 普通分类合并到 Other(固定规则,与 Other 是否为空无关)。
        // 含手动覆盖 app 的分类必须保留为独立卡,不得因稀疏被合并掉
        // (覆盖进 Other 的 app 保持可见 —— Other 恒不参与合并)。
        for category in AppLibraryCategory.allCases where category != .other {
            guard hasManualOverride[category] != true else { continue }
            guard let group = grouped[category],
                  group.count < AppLibraryTuning.categoryCardMinimumAppCount else { continue }
            grouped[.other, default: []].append(contentsOf: group)
            grouped[category] = nil
        }
        grouped[.other]?.sort(by: isCategoryHigherRank)

        let allRanked = grouped.values.flatMap { $0 }.sorted(by: isSuggestionHigherRank)

        var cards: [AppLibraryCard] = []
        var picked = Set<AppID>()

        // 1. Suggestions: 最多 4 个直接启动 App。
        //    无 usage 数据(cold start)时先用 Page 1 visible fallback,再用 stable order 补齐。
        let hasUsageData = inputs.metadata.map { !$0.usage.isEmpty } ?? false
        var suggestions: [AppID] = []
        if !hasUsageData {
            for id in inputs.page1FallbackAppIDs {
                guard suggestions.count < AppLibraryTuning.suggestionsCardLimit else { break }
                guard !picked.contains(id) else { continue }
                guard inputs.catalog.app(with: id) != nil, !inputs.hiddenAppIDs.contains(id) else { continue }
                suggestions.append(id)
                picked.insert(id)
            }
        }
        for app in allRanked {
            guard suggestions.count < AppLibraryTuning.suggestionsCardLimit else { break }
            guard !picked.contains(app.app.id) else { continue }
            suggestions.append(app.app.id)
            picked.insert(app.app.id)
        }
        if !suggestions.isEmpty {
            cards.append(AppLibraryCard(
                id: .suggestions,
                primaryAppIDs: suggestions,
                miniAppIDs: [],
                detailAppIDs: suggestions
            ))
        }

        // 2. Recently Added: 仅 bootstrap 后且窗口内存在真实 firstSeen 时生成。
        if let recently = recentlyAddedAppIDs(visible: visible, inputs: inputs), !recently.isEmpty {
            cards.append(AppLibraryCard(
                id: .recentlyAdded,
                primaryAppIDs: Array(recently.prefix(AppLibraryTuning.categoryPrimaryLimit)),
                miniAppIDs: Array(
                    recently.dropFirst(AppLibraryTuning.categoryPrimaryLimit)
                        .prefix(AppLibraryTuning.miniLimit)
                ),
                detailAppIDs: recently
            ))
        }

        // 3. 分类卡(固定 category priority;Other 非空才生成,恒最后)。
        var categoryDetail: [AppLibraryCategory: [AppID]] = [:]
        for category in AppLibraryCategory.allCases {
            guard let group = grouped[category], !group.isEmpty else { continue }
            // 合并规则(A11): 普通稀疏分类(无手动覆盖)已被并入 Other;
            // 含手动覆盖的分类必须保留为独立卡(即使 < 2 个 app)。
            if category != .other,
               group.count < AppLibraryTuning.categoryCardMinimumAppCount,
               hasManualOverride[category] != true {
                continue
            }
            let ids = group.map(\.app.id)
            categoryDetail[category] = ids
            cards.append(AppLibraryCard(
                id: .category(category),
                primaryAppIDs: Array(ids.prefix(AppLibraryTuning.categoryPrimaryLimit)),
                miniAppIDs: Array(
                    ids.dropFirst(AppLibraryTuning.categoryPrimaryLimit)
                        .prefix(AppLibraryTuning.miniLimit)
                ),
                detailAppIDs: ids
            ))
        }

        return AppLibraryModel(cards: cards, categoryDetail: categoryDetail)
    }

    // MARK: - Internal

    private struct ResolvedApp: Sendable {
        let app: AppLibraryApp
        let usage: AppLibraryUsageRecord?
    }

    private static func resolve(_ record: AppRecord, inputs: Inputs) -> ResolvedApp {
        ResolvedApp(
            app: AppLibraryApp(
                id: record.id,
                displayName: displayName(
                    for: record,
                    customName: inputs.customDisplayNames[record.id],
                    language: inputs.language,
                    systemPreferredLanguages: inputs.systemPreferredLanguages
                ),
                category: effectiveCategory(for: record, inputs: inputs)
            ),
            usage: inputs.metadata?.usage[record.id]
        )
    }

    /// 生效分类优先级(PA2): 手动覆盖 > bundle 校正 > 分类器。
    /// 覆盖/校正只影响展示分类, 不写 Layout、不改 AppRecord.categoryIdentifier。
    private static func effectiveCategory(for record: AppRecord, inputs: Inputs) -> AppLibraryCategory {
        if let override = inputs.categoryOverrides[record.id] {
            return override
        }
        if let bundleID = record.bundleIdentifier,
           let corrected = AppLibraryCategoryClassifier.bundleCategoryCorrections[bundleID] {
            return corrected
        }
        return AppLibraryCategoryClassifier.classify(record.categoryIdentifier)
    }

    /// 确定性排名: lhs 是否排在 rhs 之前(更高 rank)。
    ///
    /// 分类卡与 Suggestions 卡使用不同 ranker(Suggestions 保留 recency 桶语义;
    /// 分类卡 frequency-first, 永不 recency-over-frequency), 相互独立。
    private enum SuggestionRanker {
        /// Suggestions 卡专用 ranking(保留现有 recency/usage 语义;不污染分类卡)。
        ///
        /// 1. 有 usage > 无 usage
        /// 2. 最近使用桶(recentUsageWindow 内)> 旧桶
        /// 3. launchCount 降序
        /// 4. lastLaunchedAt 降序(nil 最后)
        /// 5. displayName 升序(稳定 tie-break)
        /// 6. AppID rawValue 升序(最终稳定 tie-break)
        static func less(lhs: ResolvedApp, rhs: ResolvedApp, now: Date) -> Bool {
            if lhs.usage != nil && rhs.usage == nil { return true }
            if lhs.usage == nil && rhs.usage != nil { return false }
            guard let lhsUsage = lhs.usage, let rhsUsage = rhs.usage else {
                return stableLess(lhs: lhs, rhs: rhs)
            }
            let lhsRecent = isRecent(lhsUsage, now: now)
            let rhsRecent = isRecent(rhsUsage, now: now)
            if lhsRecent != rhsRecent { return lhsRecent }
            if lhsUsage.launchCount != rhsUsage.launchCount {
                return lhsUsage.launchCount > rhsUsage.launchCount
            }
            if let lhsDate = lhsUsage.lastLaunchedAt,
               let rhsDate = rhsUsage.lastLaunchedAt,
               lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            if lhsUsage.lastLaunchedAt == nil && rhsUsage.lastLaunchedAt != nil { return false }
            if lhsUsage.lastLaunchedAt != nil && rhsUsage.lastLaunchedAt == nil { return true }
            return stableLess(lhs: lhs, rhs: rhs)
        }
    }

    /// 分类卡专用 ranking(frequency-first, 永不 recency-over-frequency)。
    ///
    /// 1. 显式手动覆盖/分配到本分类的 app 置顶(多个手动 app 之间按频率)
    /// 2. launchCount 降序(频率优先; 最近未用不降权)
    /// 3. 冷启动熟悉度先验: 无 usage 的 app 按 Page1 顺序(分类内)
    /// 4. lastLaunchedAt 仅作 tie-break(used 组内; nil 最后)
    /// 5. displayName / AppID 稳定 tie-break
    private enum CategoryCommonRanker {
        static func less(lhs: ResolvedApp, rhs: ResolvedApp, inputs: Inputs, page1Order: [AppID: Int]) -> Bool {
            let lhsManual = inputs.categoryOverrides[lhs.app.id] != nil
            let rhsManual = inputs.categoryOverrides[rhs.app.id] != nil
            if lhsManual != rhsManual { return lhsManual }

            let lhsCount = lhs.usage?.launchCount ?? 0
            let rhsCount = rhs.usage?.launchCount ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }

            if lhsCount > 0 {
                switch (lhs.usage?.lastLaunchedAt, rhs.usage?.lastLaunchedAt) {
                case (nil, nil): return stableLess(lhs: lhs, rhs: rhs)
                case (nil, _?): return false
                case (_?, nil): return true
                case (let lhsDate?, let rhsDate?):
                    if lhsDate != rhsDate { return lhsDate > rhsDate }
                    return stableLess(lhs: lhs, rhs: rhs)
                }
            }

            switch (page1Order[lhs.app.id], page1Order[rhs.app.id]) {
            case (nil, nil): return stableLess(lhs: lhs, rhs: rhs)
            case (nil, _?): return false
            case (_?, nil): return true
            case (let lhsIndex?, let rhsIndex?):
                if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
                return stableLess(lhs: lhs, rhs: rhs)
            }
        }
    }

    /// Recently Added 卡专用 ranking(firstSeen 降序; 现逻辑保留)。
    private enum RecentlyAddedRanker {
        static func less(
            lhs: (firstSeen: Date, displayName: String, id: AppID),
            rhs: (firstSeen: Date, displayName: String, id: AppID)
        ) -> Bool {
            if lhs.firstSeen != rhs.firstSeen { return lhs.firstSeen > rhs.firstSeen }
            if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    private static func isRecent(_ usage: AppLibraryUsageRecord, now: Date) -> Bool {
        guard let last = usage.lastLaunchedAt else { return false }
        return last > now.addingTimeInterval(-AppLibraryTuning.recentUsageWindow) && last <= now
    }

    private static func stableLess(lhs: ResolvedApp, rhs: ResolvedApp) -> Bool {
        if lhs.app.displayName != rhs.app.displayName {
            return lhs.app.displayName < rhs.app.displayName
        }
        return lhs.app.id.rawValue < rhs.app.id.rawValue
    }

    /// Recently Added 候选: 仅 bootstrap 且 firstSeen ∈ (now - window, now] 的真实新增。
    /// 首次 baseline(未 bootstrap)不得生成;窗口外/未来 firstSeen 不进入。
    private static func recentlyAddedAppIDs(
        visible: [AppRecord],
        inputs: Inputs
    ) -> [AppID]? {
        guard let metadata = inputs.metadata, metadata.isBootstrapped else { return nil }
        let cutoff = inputs.now.addingTimeInterval(-AppLibraryTuning.recentlyAddedWindow)
        var candidates: [(firstSeen: Date, displayName: String, id: AppID)] = []
        for record in visible {
            guard let firstSeen = metadata.firstSeen[record.id] else { continue }
            guard firstSeen > cutoff && firstSeen <= inputs.now else { continue }
            candidates.append((
                firstSeen,
                displayName(
                    for: record,
                    customName: inputs.customDisplayNames[record.id],
                    language: inputs.language,
                    systemPreferredLanguages: inputs.systemPreferredLanguages
                ),
                record.id
            ))
        }
        guard !candidates.isEmpty else { return [] }
        candidates.sort { RecentlyAddedRanker.less(lhs: $0, rhs: $1) }
        return candidates.map(\.id)
    }
}
