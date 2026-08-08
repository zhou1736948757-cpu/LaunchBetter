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
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    var isRunning: Bool { displayLink != nil }

    @objc private func tick(_ link: CADisplayLink) {
        onFrame?()
    }
}
