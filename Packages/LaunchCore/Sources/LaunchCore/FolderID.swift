/// 文件夹身份。
///
/// 与 AppID 相同的不变量纪律:
/// - 不做文件系统访问
/// - 禁止 `ExpressibleByStringLiteral`
/// - 纯文本规范化入口 `init?(_:)`,已规范化值入口 `init(normalized:)`
public struct FolderID: Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ raw: String) {
        let normalized = IdentifierNormalization.normalize(raw)
        guard !normalized.isEmpty else { return nil }
        self.rawValue = normalized
    }

    public init(normalized rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = FolderID(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "FolderID 规范化后为空: \(raw)"
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
