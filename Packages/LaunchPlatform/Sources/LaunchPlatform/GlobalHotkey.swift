import Carbon
import Foundation

/// 全局热键(§115): Carbon RegisterEventHotKey, 生命周期显式。
public final class GlobalHotkey: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handlerInstalled = false
    private let lock = NSLock()

    /// 触发回调(主线程事件循环)。
    public var onTrigger: (@Sendable () -> Void)?

    public init() {}

    deinit {
        stop()
    }

    /// 注册热键。keyCode 为 Carbon 键码;modifiers 位掩码(cmd=256, shift=512, option=2048, control=4096)。
    public func start(keyCode: UInt32, modifiers: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard hotKeyRef == nil else { return true }
        let id = EventHotKeyID(signature: 0x4C42_4852, id: 1) // "LBHR"
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        if !handlerInstalled {
            let userData = Unmanaged.passUnretained(self).toOpaque()
            let err = InstallEventHandler(
                GetApplicationEventTarget(),
                GlobalHotkey.hotKeyHandler,
                1,
                &eventType,
                userData,
                &eventHandlerRef
            )
            guard err == noErr else { return false }
            handlerInstalled = true
        }
        let err = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return err == noErr
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if handlerInstalled, let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
            handlerInstalled = false
        }
    }

    private static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard let userData else { return noErr }
        let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
        hotkey.trigger()
        return noErr
    }

    private func trigger() {
        onTrigger?()
    }
}
