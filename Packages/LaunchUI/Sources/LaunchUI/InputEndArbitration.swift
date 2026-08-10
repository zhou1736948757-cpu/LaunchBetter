/// 纯输入结束仲裁: 三指 raw ended 可能早于系统左键释放, 但最终 mouseUp
/// 仍可结束三指 session。除这个明确的 handoff 外, 跨输入源结束一律拒绝。
enum InputEndArbitration {
    enum Source: Equatable {
        case mouse
        case threeFinger
    }

    enum Decision: Equatable {
        case end
        case handoffToMouse
        case reject
    }

    static func decide(
        sessionOwner: Source?,
        endingSource: Source,
        leftMouseButtonPressed: Bool
    ) -> Decision {
        guard let sessionOwner else { return .reject }

        // 文件夹/主网格的真实 mouseUp 是三指 session 的最终释放信号。
        if sessionOwner == .threeFinger, endingSource == .mouse {
            return .end
        }

        // 其他跨输入源事件不能取消当前 session。
        guard sessionOwner == endingSource else { return .reject }

        // 系统三指 ended 可能先到; 左键仍按下时等待同一 mouse session 的 mouseUp。
        if endingSource == .threeFinger, leftMouseButtonPressed {
            return .handoffToMouse
        }
        return .end
    }
}
