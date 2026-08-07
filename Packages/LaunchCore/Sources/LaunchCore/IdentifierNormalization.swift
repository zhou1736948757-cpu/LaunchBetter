/// 纯确定性字符串规范化(无文件系统访问)。
///
/// 这是 AppID/FolderID 规范化第一层(LaunchCore 层):
/// 只做纯文本变换,绝不触碰文件系统。
/// 文件系统级收敛(大小写/symlink//private 路径)属于 LaunchPlatform 的
/// PathCanonicalizer 职责,其结果通过 `init(normalized:)` 进入。
internal enum IdentifierNormalization {
    /// 规范化规则:
    /// 1. 去除首尾空白(含换行)
    /// 2. 去除尾部斜杠(根路径 "/" 例外,保留)
    static func normalize(_ input: String) -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = value
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}
