import AppKit
import ServiceManagement

/// 登录项(开机自动启动)应用能力(MainActor)。
///
/// 由 Settings 与启动路径共用; 实现方把配置的 `launchAtLogin` 翻译为真正的
/// 注册/注销调用。测试注入 fake 断言 register/unregister 行为。
@MainActor
public protocol LoginItemApplying: AnyObject {
    /// 当前是否已注册为登录项。
    var isRegistered: Bool { get }

    /// 应用目标状态。返回是否与目标一致(允许调用方非致命处理)。
    @discardableResult
    func apply(_ enabled: Bool) -> Bool
}

/// 基于 `SMAppService.mainApp` 的登录项控制器(macOS 13+; 本工程 target 14.0)。
///
/// 仅在不带参数的非 /Applications 路径运行时注册会失败(SMAppService 要求主程序
/// 位于 /Applications 才能注册为登录项), 此时失败不崩溃, 只打印诊断状态。
@MainActor
public final class SMAppServiceLoginItemController: LoginItemApplying {
    public init() {}

    public var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    public func apply(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
            }
            print("LOGIN_ITEM apply=\(enabled) status=\(service.status)")
            return service.status == .enabled
        } catch {
            print("LOGIN_ITEM apply failed enabled=\(enabled): \(error) status=\(service.status)")
            return service.status == .enabled
        }
    }
}
