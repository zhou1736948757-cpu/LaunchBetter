/// 应用身份 = 规范化应用路径。
///
/// 不可协商决策:
/// - 禁止用生成的 UUID 替代路径身份
/// - 禁止 `ExpressibleByStringLiteral`,防止未规范化路径绕过不变量
///
/// 两层规范化:
/// - LaunchCore(`init?(_:)`): 纯确定性文本变换
/// - LaunchPlatform(PathCanonicalizer → `init(normalized:)`):
///   文件系统级收敛(实际大小写/symlink//private 收敛);路径不存在时回退纯文本结果
public struct AppID: Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    /// 从原始输入创建,执行纯文本规范化。
    /// 规范化结果为空时返回 nil。
    public init?(_ raw: String) {
        let normalized = IdentifierNormalization.normalize(raw)
        guard !normalized.isEmpty else { return nil }
        self.rawValue = normalized
    }

    /// 直接构造规范化的身份。
    /// 只允许传入已完成规范化的值(例如 PathCanonicalizer 输出)。
    /// 调用方必须保证值已规范化,否则绕过 AppID 不变量。
    public init(normalized rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = AppID(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AppID 规范化后为空: \(raw)"
            )
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}
