import Foundation
import LaunchCore

/// App→App 建夹的纯候选决策，不依赖时钟、网格或 AppKit。
enum CreateFolderHoverDecision: Equatable {
    case none
    case waiting(AppID)
    case active(AppID)

    static let activationDwell: TimeInterval = 0.3

    static func resolve(
        sourceApp: AppID,
        pointedApp: AppID?,
        candidate: AppID?,
        elapsed: TimeInterval
    ) -> Self {
        guard let target = pointedApp, target != sourceApp else { return .none }
        guard candidate == target, elapsed >= activationDwell else {
            return .waiting(target)
        }
        return .active(target)
    }
}
