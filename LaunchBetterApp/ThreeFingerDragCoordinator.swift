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
/// - 仅面板可见时启用; 隐藏/失焦时发送 cancel(不执行 drop)
///
/// 性能(§20/§21): changed 事件以轻量 DispatchQueue.main.async 注入 DragController
/// (其内部只写 latest-sample buffer, 由既有 FrameCoordinator/display link 消费,
/// 不按 raw-frame 率执行 UI 工作)。
@MainActor
final class ThreeFingerDragCoordinator {
    private weak var windowController: LauncherWindowController?
    private let engine: GestureCaptureEngine
    private var enabled = false

    // 诊断计数(§37)
    private(set) var beginCount = 0
    private(set) var updateCount = 0
    private(set) var endCount = 0
    private(set) var cancelCount = 0
    private(set) var missedBeginCount = 0

    init(windowController: LauncherWindowController, engine: GestureCaptureEngine) {
        self.windowController = windowController
        self.engine = engine
    }

    /// 订阅引擎三指事件(后台线程到达)。
    func install() {
        engine.onThreeFingerGesture = { [weak self] event in
            // 轻量桥接: 事件率低, 且 DragController.updateDrag 只写 latest buffer(微秒级)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.handle(event)
                }
            }
        }
    }

    /// 卸载回调。
    func uninstall() {
        engine.onThreeFingerGesture = nil
    }

    /// 面板显示/隐藏时启用/禁用。隐藏时若在拖动 → cancel(不执行 drop, 与旧行为一致)。
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled, windowController?.hasActiveDrag() == true {
            cancelCount += 1
            windowController?.threeFingerDragCancel()
        }
    }

    private func handle(_ event: ThreeFingerGestureEvent) {
        guard enabled, let windowController else { return }
        switch event {
        case .began:
            if windowController.threeFingerDragBegin() {
                beginCount += 1
            } else {
                missedBeginCount += 1
            }
        case .changed:
            updateCount += 1
            windowController.threeFingerDragUpdate()
        case .ended:
            endCount += 1
            windowController.threeFingerDragEnd()
        }
    }

    func diagnostics() -> String {
        "begin=\(beginCount) update=\(updateCount) end=\(endCount) cancel=\(cancelCount) missedBegin=\(missedBeginCount) engine[\(engine.threeFingerStats())]"
    }
}
