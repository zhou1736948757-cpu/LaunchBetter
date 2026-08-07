import Foundation
import LaunchCore

/// 目录对账: 计算旧快照到新发现记录集的增量。
///
/// 增量是默认路径;全量对账只是恢复手段。
/// 输出确定性排序: inserted/updated 按 AppID,removed 按 rawValue。
public enum ReconcileEngine {
    public static func delta(
        from old: CatalogSnapshot,
        to new: [AppRecord]
    ) -> CatalogDelta {
        let newRecords = new.sorted { $0.id.rawValue < $1.id.rawValue }
        let oldByID = Dictionary(uniqueKeysWithValues: old.apps.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: newRecords.map { ($0.id, $0) })

        var inserted: [AppRecord] = []
        var updated: [AppRecord] = []
        var removed: [AppID] = []

        for record in newRecords {
            guard let previous = oldByID[record.id] else {
                inserted.append(record)
                continue
            }
            if previous != record {
                updated.append(record)
            }
        }

        removed = old.apps
            .filter { newByID[$0.id] == nil }
            .map(\.id)
            .sorted { $0.rawValue < $1.rawValue }

        return CatalogDelta(inserted: inserted, updated: updated, removed: removed)
    }
}
