import CoreGraphics
import Foundation

/// Internal gesture follow curve. Kept in LaunchUI because it is an input
/// implementation detail, not part of LaunchCore's public API.
enum PagingFollowCurve: Sendable, Equatable {
    case linear(sensitivity: CGFloat)
    case normalizedDamped(strength: CGFloat)

    func apply(rawDisplacement: CGFloat, pageWidth: CGFloat) -> CGFloat {
        switch self {
        case .linear(let sensitivity):
            return rawDisplacement * sensitivity
        case .normalizedDamped(let strength):
            let normalized = abs(rawDisplacement) / max(1, pageWidth)
            return rawDisplacement / (1 + strength * normalized)
        }
    }
}
