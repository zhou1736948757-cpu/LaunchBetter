import CoreGraphics
import LaunchCore

/// Library 滚轮轴仲裁状态(idle / undecided / vertical / horizontal)。
///
/// 语义与 `PagingAxisLock` 一致(idle → undecided → 锁定), 并补 vertical 分支:
/// undecided 期间按累计位移判定主导轴; 一旦锁定, 直到手势结束不再退出,
/// 后续另一轴的 burst 不能抢回 owner。
enum AppLibraryAxisState: Sendable, Equatable {
    case idle
    case undecided
    case vertical
    case horizontal
}

/// 当前路由决定: 事件交给哪一方处理。
enum AppLibraryAxisRoute: Sendable, Equatable {
    case undecided
    case vertical
    case horizontal
}

/// App Library 垂直/水平滚轮轴仲裁器(纯逻辑, Stage E9b)。
///
/// - 复用 `PagingTuning.axisActivationThreshold` / `horizontalDominance` 的
///   阈值与主导轴语义(与 `PagingAxisLock` 同源, 但支持 vertical 锁定)。
/// - diagonal / 低于阈值保持 undecided, 不产生 route 抖动。
/// - 明显 horizontal 一旦锁定, 后续 vertical burst 不能抢回 owner(反之亦然)。
/// - ended/cancelled/reset 回 idle, 下一手势可重新选择轴。
struct AppLibraryAxisArbiter: Sendable, Equatable {
    private(set) var state: AppLibraryAxisState = .idle
    private(set) var accumulatedX: CGFloat = 0
    private(set) var accumulatedY: CGFloat = 0

    var route: AppLibraryAxisRoute {
        switch state {
        case .idle, .undecided:
            return .undecided
        case .vertical:
            return .vertical
        case .horizontal:
            return .horizontal
        }
    }

    /// 手势开始: 回 undecided, 清累计。
    mutating func begin() {
        state = .undecided
        accumulatedX = 0
        accumulatedY = 0
    }

    /// 输入一个增量(pt, 含系统滚动方向语义)。
    /// - Returns: 当前路由(未锁定 = undecided)。
    mutating func accumulate(deltaX: CGFloat, deltaY: CGFloat) -> AppLibraryAxisRoute {
        switch state {
        case .idle:
            return .undecided
        case .undecided:
            accumulatedX += deltaX
            accumulatedY += deltaY
            let totalX = abs(accumulatedX)
            let totalY = abs(accumulatedY)
            if totalY > PagingTuning.axisActivationThreshold,
               totalY > totalX * PagingTuning.horizontalDominance {
                state = .vertical
            } else if totalX > PagingTuning.axisActivationThreshold,
                      totalX > totalY * PagingTuning.horizontalDominance {
                state = .horizontal
            }
            return route
        case .vertical:
            return .vertical
        case .horizontal:
            return .horizontal
        }
    }

    /// 手势结束/取消: 回 idle。下一手势可重新选择轴。
    mutating func end() {
        state = .idle
        accumulatedX = 0
        accumulatedY = 0
    }

    /// 显式重置(等价 end)。
    mutating func reset() {
        end()
    }
}
