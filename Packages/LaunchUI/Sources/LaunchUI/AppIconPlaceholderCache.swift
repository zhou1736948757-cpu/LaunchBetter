import AppKit

/// 占位图共享缓存(M2): 卡片 / 设置隐藏行 / detail 行共用同一份渲染结果。
///
/// 每个 cell configure 都主线程 CGContext+CTLine 重画占位图, 同一
/// (appID, name, pointSize, scale) 在滚动/复用期间会反复出现。这里按完整
/// 键缓存 NSImage, hit 时直接复用, 零重画。
///
/// 键必须包含 appID.rawValue 与 name: 自定义名 / 语言变化会刷新占位首字母,
/// 缺 name 会导致改名后仍显示旧字母; pointSize 与 scale 参与像素尺寸与字号。
/// NSCache 的 countLimit 防止不同 app 的组合无限增长。
///
/// 仅主线程访问(AppKit 视图层); 内存压力下 NSCache 自动逐出, 下次 miss
/// 会重新渲染, 行为与无缓存时一致。
@MainActor
final class AppIconPlaceholderCache {
    private let cache: NSCache<NSString, NSImage>

    init(countLimit: Int = 256) {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = countLimit
        self.cache = cache
    }

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: NSImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}