/// 纯索引规划：gapIndex 是“移除源项后”的插入位置，源 cell 永不参与位移。
struct DragPreviewPlan {
    struct Move: Equatable {
        let itemIndex: Int
        let targetIndex: Int
    }

    static func moves(sourceIndex: Int, gapIndex: Int) -> [Move] {
        guard sourceIndex != gapIndex else { return [] }
        if sourceIndex < gapIndex {
            return (sourceIndex + 1...gapIndex).map { Move(itemIndex: $0, targetIndex: $0 - 1) }
        }
        return (gapIndex..<sourceIndex).map { Move(itemIndex: $0, targetIndex: $0 + 1) }
    }
}
