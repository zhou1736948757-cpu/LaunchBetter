import AppKit
import LaunchCore

/// 设置"隐藏应用"表格行: 最左侧真实 app 图标, 右侧名称。
///
/// 图标经 `IconImageProviding` 异步到达。复用与新配置会取消旧请求并递增
/// generation; 迟到结果只有在仍代表同一 AppID 且 generation 未过期时才允许
/// 应用, 防止把另一 app 的图标显示到已复用的 cell 上。
///
/// provider 为 nil、返回 nil、未知或已卸载 AppID 时显示按 AppID 稳定的占位
/// (色块 + 首字母), 不串用其他 app 的视觉。
@MainActor
final class SettingsHiddenRowCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SettingsHiddenRowCell")

    /// 图标视图(占位与真实图标共用)。
    let iconView: NSImageView

    /// 名称标签。
    let nameLabel: NSTextField

    /// 图标 + 名称的水平容器(icon 恒在 name 左侧)。
    let contentStack: NSStackView

    private static let iconSize: CGFloat = 32
    private var representedAppID: AppID?
    private var requestGeneration: UInt64 = 0
    private var iconTask: Task<Void, Never>?
    private var requestedPointSize = 32

    /// 最近一次成功应用的 provider 图标(nil = 仍为占位)。
    /// 测试 seam: 用于区分真实图标与 fallback, 以及校验迟到结果被拒绝。
    private(set) var appliedCGImage: CGImage?

    override init(frame frameRect: NSRect) {
        iconView = NSImageView()
        iconView.wantsLayer = true
        iconView.imageScaling = .scaleProportionallyDown
        iconView.layer?.contentsGravity = .resizeAspect
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel = NSTextField(labelWithString: "")
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        contentStack = NSStackView(views: [iconView, nameLabel])
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        imageView = iconView
        textField = nameLabel
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -4
            ),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 配置一行。会取消上一 identity 的请求并清空旧图标, 确保复用不串内容。
    func configure(
        appID: AppID,
        name: String,
        provider: (any IconImageProviding)?,
        pointSize: Int,
        scale: Int
    ) {
        prepareForReuse()
        representedAppID = appID
        nameLabel.stringValue = name
        requestedPointSize = pointSize
        showPlaceholder(appID: appID, name: name, pointSize: pointSize, scale: scale)
        guard let provider else { return }
        startIconRequest(
            appID: appID,
            provider: provider,
            pointSize: pointSize,
            scale: scale
        )
    }

    /// 等待当前图标请求收敛(测试 seam; provider 为 nil 时立即返回)。
    func waitForIcon() async {
        await iconTask?.value
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconTask?.cancel()
        iconTask = nil
        requestGeneration &+= 1
        representedAppID = nil
        appliedCGImage = nil
        iconView.image = nil
        nameLabel.stringValue = ""
    }

    private func startIconRequest(
        appID: AppID,
        provider: any IconImageProviding,
        pointSize: Int,
        scale: Int
    ) {
        let expectedGeneration = requestGeneration
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let image = await provider.icon(for: appID, pointSize: pointSize, scale: scale)
            guard !Task.isCancelled,
                  let self,
                  self.representedAppID == appID,
                  self.requestGeneration == expectedGeneration else { return }
            self.applyIcon(image)
        }
        iconTask = task
    }

    private func applyIcon(_ image: CGImage?) {
        guard let image else { return }
        appliedCGImage = image
        iconView.image = NSImage(
            cgImage: image,
            size: NSSize(width: requestedPointSize, height: requestedPointSize)
        )
    }

    /// 稳定占位(M2): 与卡片/detail 行共用 `AppLibraryIconPlaceholder.image`,
    /// 经共享缓存复用渲染结果; 像素计算语义与旧的私有实现一致
    /// (pixels = pointSize × scale, 色板/字号/布局照旧)。
    private func showPlaceholder(appID: AppID, name: String, pointSize: Int, scale: Int) {
        iconView.image = AppLibraryIconPlaceholder.image(
            appID: appID,
            name: name,
            pointSize: pointSize,
            scale: scale
        )
    }
}
