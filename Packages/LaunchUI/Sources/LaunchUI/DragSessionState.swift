import LaunchCore

/// folder-exit session 的纯状态机。结果回执到达前保持 awaitingResult，
/// 重复回执或取消后的迟到回执都不会再次完成 session。
enum FolderExitDragPhase: Equatable {
    case idle
    case active
    case awaitingResult
}

struct FolderExitDragLifecycle: Equatable {
    private(set) var phase: FolderExitDragPhase = .idle
    private(set) var result: Bool?

    var isActive: Bool { phase != .idle }
    var isAwaitingResult: Bool { phase == .awaitingResult }

    @discardableResult
    mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .active
        result = nil
        return true
    }

    @discardableResult
    mutating func awaitResult() -> Bool {
        guard phase == .active else { return false }
        phase = .awaitingResult
        return true
    }

    @discardableResult
    mutating func resolve(_ result: Bool) -> Bool {
        guard phase == .awaitingResult else { return false }
        phase = .idle
        self.result = result
        return true
    }

    mutating func cancel() {
        phase = .idle
        result = nil
    }
}

/// 把已经由主网格算出的 page/slot 转成 store 使用的显示索引。
/// 该 helper 不重新计算指针目的地, 只负责 folder-exit mouseUp 的索引归一化。
struct FolderExitDragPlacement {
    static func displayIndex(
        for destination: LayoutTransaction.Destination,
        pageCapacity: Int,
        pageCount: Int
    ) -> Int {
        guard pageCapacity > 0 else { return 0 }
        let lastPage = max(0, pageCount - 1)
        let page = min(max(0, destination.page), lastPage)
        let slot = min(max(0, destination.slot), pageCapacity - 1)
        return page * pageCapacity + slot
    }
}
