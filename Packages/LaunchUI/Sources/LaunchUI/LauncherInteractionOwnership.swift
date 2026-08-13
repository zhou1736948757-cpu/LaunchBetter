import AppKit

/// 当前拥有 Launcher 输入的面。
///
/// 规则: 只有当前面可以响应用户输入。Settings 激活时底层 Grid 不得开始/更新/结束
/// App 拖拽、三指拖拽、翻页、启动、右键菜单、空白点击隐藏或建夹。
/// Stage E9a: `.appLibrary` / `.appLibraryCategory` 是 App Library 前景面的
/// 唯一 input owner(Library 自身点击/滚动由其自有视图处理, 不经过 root Grid gate)。
public enum LauncherInteractionSurface: Equatable, Sendable {
    /// 普通 Launcher 网格(分页页面对应 `.layoutPage`, 或搜索模式)。
    case launcher
    /// App Library 物理 section 0(分页仍可用, root drag/三指/建夹/普通 Grid 输入阻断)。
    case appLibrary
    /// App Library 分类 detail 打开中(outer paging / Library scroll / root drag /
    /// 三指 / 普通 Grid 输入全部阻断; detail 负责 Escape/outside/click 完整序列)。
    case appLibraryCategory
    case folder
    case settings
}

/// Settings 激活时覆盖在 Launcher 内容之上的输入屏蔽层。
///
/// 它位于 Launcher 窗口(而非 Settings child window), 因此 Settings 窗口始终在它之上。
/// 消费完整的鼠标序列: mouseDown / mouseDragged / mouseUp / scrollWheel / 右键,
/// 保证同一物理手势的后续事件不会落到底层 Grid(否则会误触发 App 拖拽/启动/翻页)。
///
/// 点击 Launcher 空白只关闭 Settings(经 onMouseDown 回调), 不移除本层;
/// 本层在 mouseUp 消费完成后才安全移除, 避免 mouseUp 透传到 Grid。
final class SettingsInteractionShield: NSView {
    /// mouseDown: 触发 Settings 关闭(不结束所有权)。
    var onShieldMouseDown: (() -> Void)?

    /// mouseUp: 完整序列已消费, 现在可安全结束 Settings 所有权。
    var onShieldMouseUp: (() -> Void)?

    /// 正在消费一次点击序列(mouseDown 已发生, mouseUp 未到)。
    private(set) var isConsumingClick = false

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        isConsumingClick = true
        if CommandLine.arguments.contains("--inputtrace") {
            print("INPUTTRACE shield mouseDown")
        }
        onShieldMouseDown?()
    }

    override func mouseDragged(with event: NSEvent) {
        // 消费, 不透传。
        if CommandLine.arguments.contains("--inputtrace") {
            print("INPUTTRACE shield mouseDragged")
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasConsuming = isConsumingClick
        isConsumingClick = false
        if CommandLine.arguments.contains("--inputtrace") {
            print("INPUTTRACE shield mouseUp")
        }
        if wasConsuming {
            onShieldMouseUp?()
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        isConsumingClick = true
        onShieldMouseDown?()
    }

    override func otherMouseDragged(with event: NSEvent) {}

    override func otherMouseUp(with event: NSEvent) {
        let wasConsuming = isConsumingClick
        isConsumingClick = false
        if wasConsuming {
            onShieldMouseUp?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        isConsumingClick = true
        onShieldMouseDown?()
    }

    override func rightMouseDragged(with event: NSEvent) {}

    override func rightMouseUp(with event: NSEvent) {
        let wasConsuming = isConsumingClick
        isConsumingClick = false
        if wasConsuming {
            onShieldMouseUp?()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // 消费, 不透传(翻页)。
    }
}
