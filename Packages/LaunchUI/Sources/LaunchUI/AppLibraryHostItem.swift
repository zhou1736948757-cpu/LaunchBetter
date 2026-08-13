import AppKit
import LaunchCore

/// App Library 物理 section 0 的宿主单元。
///
/// 承载独立的 `AppLibraryViewController`(自身 NSCollectionView / 垂直滚动语义),
/// 不产生 AppCell / Drag identity: 不进入 `cachedDisplayItems`、`flatIndex` 与
/// DragController 的 hit-test 面。
///
/// 注入边界:
/// - model 从 `store as? any AppLibraryDataProviding` 获取(缺省 → 无 host)
/// - displayName / launch 委托给 `LauncherStoring`
/// - 图标复用宿主 `IconImageProviding`
///
/// Session 生命周期: 首次 attach 时 `beginSession` 固定冻结 model;host cell 被
/// 普通 item 复用 / Launcher hide / 离开 Library surface 时 `endSession` 释放冻结;
/// 再次 attach 用最新 model 重新固定。model 绝不写入 Layout。
@MainActor
final class AppLibraryHostItem {
    private let store: any LauncherStoring
    private let iconProvider: (any IconImageProviding)?
    private var libraryController: AppLibraryViewController?
    /// 当前是否处于冻结 session(attach 中)。
    private var sessionActive = false
    /// 缓存宿主窗口 chrome 保留带(controller 创建前先设置 / 创建后都能应用)。
    private var cachedContentInsets: (top: CGFloat, bottom: CGFloat)?

    /// Category detail 打开/关闭状态转发(宿主 → Grid → Window)。
    var onDetailChange: ((Bool) -> Void)?

    /// Library 水平滚动路由(宿主 Grid 注入, Stage E9b): 复用外层
    /// PagingInteractionController, 不创建第二套 settle/display-link。
    var onAppLibraryHorizontalScroll: ((NSEvent) -> Bool)?

    init(store: any LauncherStoring, iconProvider: (any IconImageProviding)?) {
        self.store = store
        self.iconProvider = iconProvider
    }

    /// 按需创建并返回 Library 控制器。store 未实现 `AppLibraryDataProviding`
    /// 时为 nil(此时外层不启用 leading surface)。
    ///
    /// 重复调用复用实例: 冻结 session 中保持原 model;已 endSession 的实例
    /// 用最新 model 重新固定 session。
    func makeController() -> AppLibraryViewController? {
        guard let provider = store as? any AppLibraryDataProviding else { return nil }
        if let existing = libraryController {
            if !sessionActive {
                existing.beginSession(model: provider.appLibraryModel())
                sessionActive = true
            }
            return existing
        }
        let model = provider.appLibraryModel()
        let controller = AppLibraryViewController(
            model: model,
            displayName: { [weak store] appID in
                store?.displayName(for: appID) ?? appID.rawValue
            },
            iconProvider: iconProvider,
            onLaunch: { [weak store] appID in
                store?.launch(appID)
            }
        )
        if let cached = cachedContentInsets {
            controller.setContentInsets(top: cached.top, bottom: cached.bottom)
        }
        controller.onDetailChange = { [weak self] open in
            self?.onDetailChange?(open)
        }
        controller.onHorizontalScroll = onAppLibraryHorizontalScroll
        controller.beginSession(model: model)
        sessionActive = true
        libraryController = controller
        return controller
    }

    /// 更新并缓存顶部/底部保留带(幂等): controller 已创建时立即应用,
    /// 未创建时缓存, 待 `makeController` 创建后应用。
    func setContentInsets(top: CGFloat, bottom: CGFloat) {
        let t = max(0, top)
        let b = max(0, bottom)
        if let cached = cachedContentInsets, cached.top == t, cached.bottom == b {
            return
        }
        cachedContentInsets = (t, b)
        libraryController?.setContentInsets(top: t, bottom: b)
    }

    /// 释放冻结 session(host cell 复用 / Launcher hide / 离开 Library surface)。
    /// 幂等; 之后 `makeController` 会以最新 model 重新固定。
    func endSession() {
        guard sessionActive else { return }
        sessionActive = false
        libraryController?.endSession()
    }

    /// 关闭当前 Library detail(幂等)。Settings 打开 / Launcher 隐藏 / 离开
    /// Library surface 时由 Grid 调用。
    func closeDetail() {
        libraryController?.dismissDetailIfPresent()
    }

    /// 诊断: 已创建的 Library 控制器(host 尚未挂载时为 nil)。
    var libraryControllerForDiag: AppLibraryViewController? { libraryController }
}

/// App Library host 的单元格: 只承载 `AppLibraryViewController.view`, 不参与
/// AppCell / Drag identity。
@MainActor
final class AppLibraryHostCell: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AppLibraryHostCell")

    /// 显式提供稳定的空容器: NSCollectionViewItem 默认 view 可能为 nil,
    /// 未配置 host(store 无 provider / 复用前)时访问 view 仍安全。
    override func loadView() {
        view = NSView()
    }
}
