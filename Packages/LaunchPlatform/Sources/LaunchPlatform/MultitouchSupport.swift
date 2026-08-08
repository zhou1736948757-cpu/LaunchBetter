import CoreGraphics
import Darwin
import Foundation

/// MultitouchSupport 私有框架窄包装(§91)。
///
/// - 只允许在本类型出现 C 指针/私有 API
/// - dlopen + dlsym, 优雅不可用(返回 nil, 不崩溃)
/// - 输入监控(TCC)未授权时回调不会到达 → 由上层检测并提示
/// MTTouch 私有结构(与私有框架布局对齐, legacy 验证)。
struct MTTouch {
    var frame: Int64 = 0
    var timestamp: Double = 0
    var identifier: Int32 = 0
    var state: Int32 = 0
    var fingerId: Int32 = 0
    var pathIndex: Int32 = 0
    var pathIndexRaw: Int32 = 0
    var normalized: CGPoint = .zero
    var total: CGPoint = .zero
    var pressure: Double = 0
    var radius: Double = 0
    var angle1: Double = 0
    var angle2: Double = 0
    var majorAxis: Double = 0
    var minorAxis: Double = 0
    var mm: CGPoint = .zero
}

/// 全局回调盒 + 非捕获 C 回调。
/// MTContactCallback 签名无 context 参数(注册时的 context 不会传回回调),
/// 故用全局单盒承载用户闭包(应用内单一引擎实例)。
private final class ContactCallbackBox {
    let closure: @Sendable ([ContactSample]) -> Void
    init(_ closure: @escaping @Sendable ([ContactSample]) -> Void) {
        self.closure = closure
    }
}

private nonisolated(unsafe) var contactCallbackBox: ContactCallbackBox?

/// 非捕获 C 回调(文件级: Swift 6 在类方法内定义带指针绑定的 @convention(c) 闭包会崩溃)
private let contactCallback: MultitouchSupport.MTContactCallback = { _, touches, numTouches, _, _ in
    guard let box = contactCallbackBox, let touches, numTouches > 0 else { return }
    let touchPointer = touches.assumingMemoryBound(to: MTTouch.self)
    var samples: [ContactSample] = []
    for index in 0..<Int(numTouches) {
        let touch = touchPointer[index]
        // state: 1 = 接触表面(legacy 验证)
        samples.append(
            ContactSample(normalized: touch.normalized, isOnSurface: touch.state == 1)
        )
    }
    guard !samples.isEmpty else { return }
    box.closure(samples)
}

final class MultitouchSupport: @unchecked Sendable {
    // MARK: - 私有 API 声明

    private typealias MTDeviceRef = UnsafeMutableRawPointer
    // Swift 6: 自定义 struct 不可直接出现在 @convention(c) 签名,
    // 用原始指针 + assumingMemoryBound 读取 MTTouch 布局
    typealias MTContactCallback = @convention(c) (
        Int32, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Void

    private typealias MTDeviceCreateListFn = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<Int32>?
    ) -> Void
    private typealias MTRegisterContactFrameCallbackFn = @convention(c) (
        MTDeviceRef, MTContactCallback, UnsafeMutableRawPointer?
    ) -> Void
    private typealias MTUnregisterContactFrameCallbackFn = @convention(c) (
        MTDeviceRef, MTContactCallback, UnsafeMutableRawPointer?
    ) -> Void
    private typealias MTDeviceStartFn = @convention(c) (MTDeviceRef) -> Void
    private typealias MTDeviceStopFn = @convention(c) (MTDeviceRef) -> Void

    private let handle: UnsafeMutableRawPointer
    private let deviceCreateList: MTDeviceCreateListFn
    private let registerCallback: MTRegisterContactFrameCallbackFn
    private let unregisterCallback: MTUnregisterContactFrameCallbackFn
    private let deviceStart: MTDeviceStartFn
    private let deviceStop: MTDeviceStopFn

    init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY
        ) else {
            return nil
        }
        guard
            let createList = dlsym(handle, "MTDeviceCreateList").map({
                unsafeBitCast($0, to: MTDeviceCreateListFn.self)
            }),
            let register = dlsym(handle, "MTRegisterContactFrameCallback").map({
                unsafeBitCast($0, to: MTRegisterContactFrameCallbackFn.self)
            }),
            let unregister = dlsym(handle, "MTUnregisterContactFrameCallback").map({
                unsafeBitCast($0, to: MTUnregisterContactFrameCallbackFn.self)
            }),
            let start = dlsym(handle, "MTDeviceStart").map({
                unsafeBitCast($0, to: MTDeviceStartFn.self)
            }),
            let stop = dlsym(handle, "MTDeviceStop").map({
                unsafeBitCast($0, to: MTDeviceStopFn.self)
            })
        else {
            dlclose(handle)
            return nil
        }
        self.handle = handle
        self.deviceCreateList = createList
        self.registerCallback = register
        self.unregisterCallback = unregister
        self.deviceStart = start
        self.deviceStop = stop
    }

    deinit {
        dlclose(handle)
    }

    /// 枚举设备并注册回调(回调在系统线程到达, 非主线程)。
    /// 返回注册设备数;0 = 无设备或回调未注册。
    @discardableResult
    func startDevices(callback: @escaping @Sendable ([ContactSample]) -> Void) -> Int {
        var count: Int32 = 0
        var listStorage: UnsafeMutablePointer<UnsafeMutableRawPointer?>? = nil
        withUnsafeMutablePointer(to: &listStorage) { listPointer in
            deviceCreateList(UnsafeMutableRawPointer(listPointer), &count)
        }
        guard let list = listStorage, count > 0 else { return 0 }

        // 回调包装: C 回调 → Swift 闭包(锁/队列保护)
        contactCallbackBox = ContactCallbackBox(callback)
        var registered = 0
        for index in 0..<Int(count) {
            guard let device = list[index] else { continue }
            registerCallback(device, contactCallback, nil)
            deviceStart(device)
            registered += 1
        }
        return registered
    }

    /// 停止并注销全部设备回调。
    func stopDevices() {
        // 设备列表重新枚举停止(保持与注册对称)
        var count: Int32 = 0
        var listStorage: UnsafeMutablePointer<UnsafeMutableRawPointer?>? = nil
        withUnsafeMutablePointer(to: &listStorage) { listPointer in
            deviceCreateList(UnsafeMutableRawPointer(listPointer), &count)
        }
        guard let list = listStorage else { return }
        for index in 0..<Int(count) {
            guard let device = list[index] else { continue }
            deviceStop(device)
        }
    }

}
