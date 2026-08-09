import Foundation

/// 持久化重试 capped backoff 调度值计算(v0.2.3 §A1)。
///
/// 纯调度值计算, 不含 sleep/Timer: 返回下一次应等待的毫秒数, 由调用方决定何时 sleep。
/// 默认序列 [250, 1000, 4000, 15000, 30000]; 到达序列尾后停留在 cap(30s)。
/// 替换固定 250ms 无限重试(持久失败: 磁盘满/权限/损坏保护写阻塞时造成持续 wakeup)。
public struct RetryBackoff: Sendable, Equatable {
    /// 默认延迟序列(ms): 250ms → 1s → 4s → 15s → 30s(cap)。
    public static let defaultDelays: [Int] = [250, 1000, 4000, 15000, 30000]

    /// 延迟序列(ms)。
    public let delays: [Int]

    /// 当前游标: 下一次将返回 `delays[currentIndex]`。
    public private(set) var currentIndex: Int

    /// - Parameter delays: 延迟序列(ms); 为空时回退到默认序列(防御)。
    public init(delays: [Int] = RetryBackoff.defaultDelays) {
        self.delays = delays.isEmpty ? RetryBackoff.defaultDelays : delays
        self.currentIndex = 0
    }

    /// 返回下一次应等待的延迟(ms)并将游标推进到下一档(cap 后保持)。
    ///
    /// 调用方每次失败重试时调用一次; 成功 commit 或新的文件系统活动时应调用 `reset()`。
    public mutating func nextDelayMilliseconds() -> Int {
        let value = delays[currentIndex]
        if currentIndex < delays.count - 1 {
            currentIndex += 1
        }
        return value
    }

    /// 回到序列首值(成功 commit 或新的文件系统活动时调用)。
    public mutating func reset() {
        currentIndex = 0
    }
}
