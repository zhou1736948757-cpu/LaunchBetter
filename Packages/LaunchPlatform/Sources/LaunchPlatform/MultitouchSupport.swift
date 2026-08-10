import CoreGraphics
import Darwin
import Foundation

// MARK: - 私有框架数据结构(与 legacy 验证可用布局完全对齐)

/// 触控板上的点(归一化或绝对坐标)
struct MTPoint {
    var x: Float
    var y: Float
}

struct MTReadout {
    var position: MTPoint
    var velocity: MTPoint
}

/// 单个手指的原始触控数据(与 MultitouchSupport.framework 的 MTTouch 结构对齐,
/// 布局经 legacy LaunchHistory 在本机验证可用)
struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32        // 0 = 未触摸, 非0 = 活跃
    var fingerID: Int32
    var handID: Int32
    var normalized: MTReadout   // 归一化坐标 (0.0–1.0)
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTReadout     // 绝对(像素)坐标
    var zero2: (Int32, Int32)
    var density: Float
}

// MARK: - 私有函数类型(C 调用约定, 与 legacy 一致)

private typealias MTDeviceRef = UnsafeMutableRawPointer

private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterContactFrameCallbackFn = @convention(c) (MTDeviceRef, MTContactCallbackFn) -> Void
private typealias MTUnregisterContactFrameCallbackFn = @convention(c) (MTDeviceRef, MTContactCallbackFn) -> Void
private typealias MTDeviceStartFn = @convention(c) (MTDeviceRef, Int32) -> Void
private typealias MTDeviceStopFn = @convention(c) (MTDeviceRef, Int32) -> Void

/// 接触帧回调签名: (device, touches指针, 数量, 时间戳, 帧号) -> Int32
private typealias MTContactCallbackFn =
    @convention(c) (MTDeviceRef, UnsafeMutableRawPointer, Int32, Double, Int32) -> Int32

// MARK: - 全局回调盒 + 非捕获 C 回调

/// 全局盒锁(C5 M1): 同步 C 回调线程(读)与 start/stop(写)对 contactCallbackBox 的访问。
private let contactCallbackLock = NSLock()

/// 全局单盒承载用户闭包(回调签名无 context 参数, 应用内单一引擎实例)。
private final class ContactCallbackBox {
    let closure: @Sendable ([ContactSample], Double) -> Void
    init(_ closure: @escaping @Sendable ([ContactSample], Double) -> Void) {
        self.closure = closure
    }
}

private nonisolated(unsafe) var contactCallbackBox: ContactCallbackBox?
/// box 的 owner token: 只有 owner 匹配的 stopDevices 才清空(防旧 wrapper 清新 box, Luna M1-1)。
private nonisolated(unsafe) var contactCallbackOwner: UInt64 = 0

/// 非捕获 C 回调(文件级: Swift 6 在类方法内定义带指针绑定的 @convention(c) 闭包会崩溃)
private let contactCallback: MTContactCallbackFn = { _, touches, count, timestamp, _ in
    guard count > 0 else { return 0 }
    // 锁内取盒快照, 锁外调用闭包(不持锁进入用户代码, 避免锁序死锁)。
    contactCallbackLock.lock()
    let box = contactCallbackBox
    contactCallbackLock.unlock()
    guard let box else { return 0 }
    let typed = touches.assumingMemoryBound(to: MTTouch.self)
    let buffer = UnsafeBufferPointer(start: typed, count: Int(count))
    var samples: [ContactSample] = []
    samples.reserveCapacity(buffer.count)
    for touch in buffer {
        // state != 0 = 活跃(与 legacy 一致)
        samples.append(
            ContactSample(
                normalized: CGPoint(
                    x: Double(touch.normalized.position.x),
                    y: Double(touch.normalized.position.y)
                ),
                isOnSurface: touch.state != 0
            )
        )
    }
    box.closure(samples, timestamp)
    return 0
}

// MARK: - 窄 C 包装

/// MultitouchSupport 私有框架窄包装(§91)。
/// 函数签名与 legacy 本机验证可用实现逐行对齐; dlopen 优雅不可用。
final class MultitouchSupport: @unchecked Sendable {
    /// 启动结果诊断。
    enum StartResult {
        case ok(devices: Int)
        case dlopenFailed
        case noDevices
    }

    private let handle: UnsafeMutableRawPointer
    private let deviceCreateList: MTDeviceCreateListFn
    private let registerCallback: MTRegisterContactFrameCallbackFn
    private let unregisterCallback: MTUnregisterContactFrameCallbackFn
    private let deviceStart: MTDeviceStartFn
    private let deviceStop: MTDeviceStopFn

    /// 持有设备列表生命周期(legacy 必需)。
    private var deviceList: CFArray?

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
    @discardableResult
    func startDevices(
        callback: @escaping @Sendable ([ContactSample], Double) -> Void,
        owner: UInt64
    ) -> StartResult {
        guard let listRef = deviceCreateList() else { return .noDevices }
        let list = listRef.takeUnretainedValue()
        deviceList = list  // 持有 CFArray 生命周期

        contactCallbackLock.lock()
        contactCallbackBox = ContactCallbackBox(callback)
        contactCallbackOwner = owner
        contactCallbackLock.unlock()
        let count = CFArrayGetCount(list)
        var registered = 0
        for index in 0..<count {
            let value = CFArrayGetValueAtIndex(list, index)
            let device = unsafeBitCast(value, to: MTDeviceRef.self)
            registerCallback(device, contactCallback)
            deviceStart(device, 0)
            registered += 1
        }
        return .ok(devices: registered)
    }

    /// 停止并注销全部设备回调。仅当 owner 匹配时清空全局 box(防旧 wrapper 清新 owner 的 box)。
    func stopDevices(owner: UInt64) {
        if let list = deviceList {
            let count = CFArrayGetCount(list)
            for index in 0..<count {
                let value = CFArrayGetValueAtIndex(list, index)
                let device = unsafeBitCast(value, to: MTDeviceRef.self)
                deviceStop(device, 0)
                unregisterCallback(device, contactCallback)
            }
            deviceList = nil
        }
        contactCallbackLock.lock()
        if contactCallbackOwner == owner {
            contactCallbackBox = nil
        }
        contactCallbackLock.unlock()
    }
}
