import AppKit
import QuartzCore

/// 帧协调器(§87/§88): 每帧从样本缓冲读取最新手势,驱动 CALayer 变换。
///
/// 绑定到启动器视图的 display link,刷新率跟随所在显示器(不硬编码 120Hz)。
/// 逐帧状态只存在于本协调器与 layer 呈现状态,绝不进入 LauncherStore(§60)。
@MainActor
final class FrameCoordinator {
    private weak var view: NSView?
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkTarget?
    private let buffer: GestureSampleBuffer
    private let session: UUID
    /// 每帧回调(拖拽中每帧触发, 内部按需消费样本)。
    var onFrame: (() -> Void)?

    init(view: NSView, buffer: GestureSampleBuffer, session: UUID) {
        self.view = view
        self.buffer = buffer
        self.session = session
    }

    /// 读取当前会话最新样本(无则 nil)。
    func readLatestSample() -> CGPoint? {
        buffer.read(session: session)
    }

    func start() {
        guard displayLink == nil, let view else { return }
        let target = DisplayLinkTarget(owner: self)
        let link = view.displayLink(
            target: target,
            selector: #selector(DisplayLinkTarget.tick(_:))
        )
        // macOS 14+ NSView.displayLink 返回可能为 paused; 显式启动
        link.isPaused = false
        link.add(to: .main, forMode: .common)
        displayLinkTarget = target
        displayLink = link
    }

    func stop() {
        stopDisplayLink()
    }

    /// 显式生命周期收尾；可安全重复调用。
    func shutdown() {
        stopDisplayLink()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
    }

    var isRunning: Bool { displayLink != nil }

    private func displayTick() {
        onFrame?()
    }

    @MainActor
    final class DisplayLinkTarget: NSObject {
        weak var owner: FrameCoordinator?

        init(owner: FrameCoordinator?) {
            self.owner = owner
        }

        @objc func tick(_ link: CADisplayLink) {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.displayTick()
        }

        /// 确定性测试 seam：owner 已释放时，下一帧必须 invalidate。
        @discardableResult
        func tickForTesting(invalidate: () -> Void) -> Bool {
            guard owner == nil else { return false }
            invalidate()
            return true
        }
    }
}
