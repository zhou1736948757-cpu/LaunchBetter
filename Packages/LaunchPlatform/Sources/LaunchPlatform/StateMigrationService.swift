import Foundation
import LaunchCore

/// 状态迁移服务(基础框架)。
///
/// 规则(主提示 §45): 当前只有 schemaVersion = 1 的状态,不提前过度构建。
/// 完整流程(未来): 读状态 → 检查版本 → 备份旧状态 → 确定性迁移链 →
/// 验证 → 原子写入;失败时保留旧文件、不销毁用户数据。
///
/// 迁移步骤作用于编码后的 Data: 每个步骤解码旧版本数据、产出新版本编码,
/// 因此步骤可跨越类型边界(V1 → V2)。链按版本逐级推进。
public struct StateMigrationService: Sendable {
    public enum MigrationError: Error, Equatable {
        /// 状态版本高于目标版本(不允许降级)
        case versionNewerThanSupported(Int)
        /// 没有从该版本的迁移步骤
        case noMigrationPath(from: Int)
    }

    /// 确定性迁移链: 从 currentVersion 逐级迁移数据到 toVersion。
    /// `steps` 键为起始版本,值为迁移函数;缺失路径抛错。
    public static func migrateData(
        _ data: Data,
        currentVersion: Int,
        toVersion: Int,
        steps: [Int: @Sendable (Data) throws -> Data]
    ) throws -> Data {
        var current = data
        var version = currentVersion
        guard version <= toVersion else {
            throw MigrationError.versionNewerThanSupported(version)
        }
        while version < toVersion {
            guard let step = steps[version] else {
                throw MigrationError.noMigrationPath(from: version)
            }
            current = try step(current)
            version += 1
        }
        return current
    }
}
