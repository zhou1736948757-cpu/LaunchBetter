import Darwin
import Foundation
import LaunchCore

/// 路径规范化第二层: 文件系统级收敛。
///
/// LaunchCore 的 AppID 规范化只做纯文本变换;本类型处理:
/// - 真实文件系统大小写
/// - symlink 收敛(realpath 语义)
/// - /private/var vs /var、/tmp 变体
/// - ".." 等相对组件标准化
///
/// 路径不存在时: realpath 失败 → 回退纯文本规范化表示(与 LaunchCore 结果一致)。
public enum PathCanonicalizer {
    /// 把任意 URL 收敛为规范化应用路径,并构造 AppID。
    public static func canonicalAppID(from rawURL: URL) -> AppID {
        AppID(normalized: canonicalPath(from: rawURL))
    }

    /// 返回规范化路径字符串。
    public static func canonicalPath(from rawURL: URL) -> String {
        let path = rawURL.standardizedFileURL.path
        // 注意: URL/NSString 的 resolvingSymlinksInPath 在此 SDK 不解析 /var → /private/var,
        // 必须用 realpath(可靠解析; 不存在的路径返回 nil → 回退)。
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if let resolved = realpath(path, &buffer) {
            return String(cString: resolved)
        }
        return path
    }
}
