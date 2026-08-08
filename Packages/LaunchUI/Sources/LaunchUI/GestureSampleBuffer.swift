import Foundation

/// 手势样本缓冲(§89): 只保留最新样本,轻量锁保护,会话隔离(M2)。
///
/// 高频回调(鼠标事件/未来 Multitouch 125-250Hz)只写最新状态,
/// 禁止逐回调跳主线程;CADisplayLink 每帧读取一次。
/// 会话 token: 读取只接受当前拖拽会话的样本,防止上一会话陈旧坐标泄漏。
/// 禁止用 volatile 做线程同步。
final class GestureSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var latestPoint: CGPoint?
    private var latestSession: UUID?
    private var generation: UInt64 = 0

    /// 写入最新样本(覆盖旧值)。
    func write(_ point: CGPoint, session: UUID) {
        lock.lock()
        defer { lock.unlock() }
        latestPoint = point
        latestSession = session
        generation &+= 1
    }

    /// 读取最新样本(消费);会话不匹配返回 nil(陈旧会话样本被丢弃)。
    func read(session: UUID) -> CGPoint? {
        lock.lock()
        defer { lock.unlock() }
        guard latestSession == session, let point = latestPoint else { return nil }
        latestPoint = nil
        latestSession = nil
        return point
    }

    /// 清空(会话结束兜底)。
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        latestPoint = nil
        latestSession = nil
    }

    /// 是否有未消费样本。
    func hasPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return latestPoint != nil
    }
}
