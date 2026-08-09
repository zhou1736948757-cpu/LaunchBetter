import AppKit
import Foundation
import LaunchCore
import LaunchPlatform
import LaunchUI

/// 三指拖动协调器(Stage 2): 把 GestureCaptureEngine 的三指事件桥接到现有 DragController。
///
/// 原则(§9/§20):
/// - 不维护第二套 reorder/preview/folder-drop/cross-page 引擎 —— 全部复用 DragController
/// - 三指输入只负责: 事件转发 + 指针位置 → beginDrag/updateDrag/endDrag/cancelDrag
/// - 位置语义与旧 LaunchHistory 一致: 用 NSEvent.mouseLocation(指针), 非触点中心
/// - 仅面板可见时启用; 隐藏时发送 cancel(不执行 drop)
///
/// 线程模型: 本类非隔离(可被引擎后台闭包直接调用), 状态用 NSLock 保护;
/// 实际触碰窗口/拖拽的调用一律经 DispatchQueue.main + MainActor.assumeIsolated。
///
/// 性能(§20/§21/评审 M4): changed 事件做 latest-value coalescing——
/// 后台只标记"需要一次主线程 drain", 主线程每周期只处理最新样本, 不积压。
final class ThreeFingerDragCoordinator: @unchecked Sendable {
    private weak var windowController: LauncherWindowController?
    private let engine: GestureCaptureEngine

    private let lock = NSLock()
    private var enabled = false
    private var updateQueued = false

    // 诊断计数(§37; 主线程更新, 读为诊断近似值)
    private var beginCount = 0
    private var updateCount = 0
    private var endCount = 0
    private var cancelCount = 0
    private var missedBeginCount = 0

    init(windowController: LauncherWindowController, engine: GestureCaptureEngine) {
        self.windowController = windowController
        self.engine = engine
    }

    /// 订阅引擎三指事件(后台线程到达)。
    func install() {
        engine.onThreeFingerGesture = { [weak self] event in
            self?.receive(event)
        }
    }

    /// 卸载回调。
    func uninstall() {
        engine.onThreeFingerGesture = nil
    }

    /// 面板显示/隐藏时启用/禁用。隐藏时若在拖动 → cancel(不执行 drop, 与旧行为一致)。
    func setEnabled(_ enabled: Bool) {
        lock.lock()
        let wasEnabled = self.enabled
        self.enabled = enabled
        lock.unlock()
        guard wasEnabled, !enabled else { return }
        // 隐藏且可能有活动拖拽 → cancel(主线程)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.windowController?.hasActiveDrag() == true {
                    self.lock.lock()
                    self.cancelCount += 1
                    self.lock.unlock()
                    self.windowController?.threeFingerDragCancel()
                }
            }
        }
    }

    // MARK: - 后台接收(引擎回调线程)

    private func receive(_ event: ThreeFingerGestureEvent) {
        switch event {
        case .changed:
            enqueueChanged()
        case .began, .ended:
            enqueueLifecycle(event)
        }
    }

    /// 后台: 标记需要一次主线程 drain(latest-value coalescing, 评审 M4)。
    private func enqueueChanged() {
        lock.lock()
        guard !updateQueued else {
            lock.unlock()
            return
        }
        updateQueued = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.drainChanged()
            }
        }
    }

    /// 后台: 生命周期事件先进队列, 保证与已排队 changed 有序。
    private func enqueueLifecycle(_ event: ThreeFingerGestureEvent) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 先消费未处理的最近样本, 再执行生命周期动作
                self.drainChanged()
                self.handle(event)
            }
        }
    }

    private func drainChanged() {
        lock.lock()
        updateQueued = false
        lock.unlock()
        lock.lock()
        let isEnabled = enabled
        lock.unlock()
        guard isEnabled, let windowController else { return }
        lock.lock()
        updateCount += 1
        lock.unlock()
        MainActor.assumeIsolated {
            windowController.threeFingerDragUpdate()
        }
    }

    private func handle(_ event: ThreeFingerGestureEvent) {
        lock.lock()
        let isEnabled = enabled
        lock.unlock()
        guard isEnabled, let windowController else { return }
        switch event {
        case .began:
            let began = MainActor.assumeIsolated {
                windowController.threeFingerDragBegin()
            }
            if began {
                lock.lock(); beginCount += 1; lock.unlock()
            } else {
                lock.lock(); missedBeginCount += 1; lock.unlock()
            }
        case .changed:
            break // 已由 drainChanged 处理
        case .ended:
            lock.lock(); endCount += 1; lock.unlock()
            MainActor.assumeIsolated {
                windowController.threeFingerDragEnd()
            }
        }
    }

    func diagnostics() -> String {
        lock.lock()
        defer { lock.unlock() }
        return "begin=\(beginCount) update=\(updateCount) end=\(endCount) cancel=\(cancelCount) missedBegin=\(missedBeginCount) engine[\(engine.threeFingerStats())]"
    }
}
