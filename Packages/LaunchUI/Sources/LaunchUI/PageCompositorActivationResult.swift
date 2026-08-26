import Foundation

/// 页面合成器激活结果(纯值类型; 遥测观察用, 不参与激活判断)。
///
/// 区分最关键的失败原因, 供 `--pagingfeeltelemetry` 摘要输出。
/// 默认产品路径不聚合/不记录; 仅遥测开启时由观察者记录。
enum PageCompositorActivationResult: Equatable, Sendable {
    case activated
    case disabled
    case alreadyActive
    case activeCoverageReuse
    case interruptionFallbackLive
    case search
    case appLibrary
    case dragActive
    case sparsePage
    case offsetNotAtBoundary
    case targetIsLibrary
    case targetOutOfBounds
    case currentVisualMissing
    case targetVisualMissing
    case invalidGeometry
}
