import Foundation

/// 事件路径折叠(§71): 把 .app 内部事件折叠到 .app 根, 目录级变化标记 scope 脏。
/// 纯逻辑, 可确定性测试。
public enum AppRootFolding {
    public enum Result: Equatable, Sendable {
        /// 目录本身或其非 .app 子项变化 → 该 scope 目录脏(需枚举该 scope)
        case scopeDirty(String)
        /// .app 内部变化 → 折叠到 .app 根(仅需重扫该应用)
        case appRoot(String)
        /// 不在任何监控 scope 内 → 忽略
        case ignored
    }

    /// 折叠规则:
    /// 1. 事件路径 == scope → scopeDirty
    /// 2. 事件路径包含 .app 组件 → appRoot(取最长匹配 scope 内的首个 .app 组件)
    /// 3. 事件路径是 scope 内非 .app 子项 → scopeDirty
    /// 4. 不在任何 scope → ignored
    public static func fold(_ eventPath: String, scopes: [String]) -> Result {
        guard let scope = scopes
            .filter({ eventPath == $0 || eventPath.hasPrefix($0 + "/") })
            .max(by: { $0.count < $1.count }) else {
            return .ignored
        }
        if eventPath == scope {
            return .scopeDirty(scope)
        }
        let relative = String(eventPath.dropFirst(scope.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        if let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) {
            let appRoot = scope + "/" + components[0...appIndex].joined(separator: "/")
            return .appRoot(appRoot)
        }
        return .scopeDirty(scope)
    }
}
