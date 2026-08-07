/// 图标内容版本: 基于真实稳定内容信号的指纹。
///
/// 要求: 未变化的应用内容 → 不变的内容版本。
/// 禁止使用 reconcile 次数 / 进程代数 / 扫描代数。
///
/// 信号在 LaunchPlatform 层采集(AppIconProvider),LaunchCore 只建模与比较。
public struct IconContentVersion: Codable, Sendable, Hashable {
    /// 图标资源文件修改时间(高精度纳秒),示例: 文件 mtime 自 epoch 的纳秒
    public let iconResourceModificationNanoseconds: UInt64?

    /// 图标资源文件大小(字节)
    public let iconResourceSizeBytes: UInt64?

    /// Info.plist 修改时间(高精度纳秒)
    public let infoPlistModificationNanoseconds: UInt64?

    /// CFBundleVersion(如需要)
    public let bundleVersion: String?

    public init(
        iconResourceModificationNanoseconds: UInt64? = nil,
        iconResourceSizeBytes: UInt64? = nil,
        infoPlistModificationNanoseconds: UInt64? = nil,
        bundleVersion: String? = nil
    ) {
        self.iconResourceModificationNanoseconds = iconResourceModificationNanoseconds
        self.iconResourceSizeBytes = iconResourceSizeBytes
        self.infoPlistModificationNanoseconds = infoPlistModificationNanoseconds
        self.bundleVersion = bundleVersion
    }

    /// 无任何信号的空版本(用于占位,不代表真实内容)。
    public static let empty = IconContentVersion()

    /// 是否至少包含一个信号。
    public var hasSignals: Bool {
        iconResourceModificationNanoseconds != nil
            || iconResourceSizeBytes != nil
            || infoPlistModificationNanoseconds != nil
            || bundleVersion != nil
    }

    /// 规范文本表示(确定性,用于磁盘缓存文件名等)。
    /// 长度前缀编码消除歧义: 缺失字段与字段值本身不会碰撞。
    public var canonicalString: String {
        [
            Self.encode(iconResourceModificationNanoseconds?.description),
            Self.encode(iconResourceSizeBytes?.description),
            Self.encode(infoPlistModificationNanoseconds?.description),
            Self.encode(bundleVersion),
        ].joined(separator: "|")
    }

    private static func encode(_ value: String?) -> String {
        guard let value else { return "0:" }
        return "\(value.count):\(value)"
    }

    /// 稳定内容哈希(FNV-1a 64bit 十六进制)。
    /// 相同信号 → 相同哈希;不同信号 → 不同哈希;跨进程稳定。
    public var stableContentHash: String {
        StableHash.fnv1a64(canonicalString)
    }
}

/// 稳定确定性哈希工具(FNV-1a 64bit)。
public enum StableHash {
    public static func fnv1a64(_ text: String) -> String {
        var digest: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in text.utf8 {
            digest = (digest ^ UInt64(byte)) &* prime
        }
        return String(format: "%016llx", digest)
    }
}

/// 图标缓存身份: AppID + 点尺寸 + 缩放 + 内容版本。
///
/// 以下必须互不相同:
/// - 96pt @1x / 96pt @2x / 64pt @2x
/// - 同一应用同一尺寸同一缩放,图标更新前后
public struct IconKey: Codable, Sendable, Hashable {
    public let appID: AppID
    public let pointSize: Int
    public let scale: Int
    public let contentVersion: IconContentVersion

    public init(
        appID: AppID,
        pointSize: Int,
        scale: Int,
        contentVersion: IconContentVersion
    ) {
        self.appID = appID
        self.pointSize = pointSize
        self.scale = scale
        self.contentVersion = contentVersion
    }

    /// 像素尺寸(pointSize × scale)。
    public var pixelSize: Int {
        pointSize * scale
    }
}
