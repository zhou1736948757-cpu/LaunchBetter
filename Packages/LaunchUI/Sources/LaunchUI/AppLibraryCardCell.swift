import AppKit
import CoreText
import LaunchCore

/// App Library 卡片的稳定占位图标(色块 + 首字母, 同一 AppID 恒同色同字母)。
/// 与主网格/设置行的占位风格一致, 供卡片与 detail 行共用。
@MainActor
enum AppLibraryIconPlaceholder {
    static func image(appID: AppID, name: String, pointSize: Int, scale: Int) -> NSImage {
        let pixels = pointSize * max(1, scale)
        guard pixels > 0,
              let context = CGContext(
                data: nil,
                width: pixels,
                height: pixels,
                bitsPerComponent: 8,
                bytesPerRow: pixels * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return NSImage(size: NSSize(width: pointSize, height: pointSize))
        }
        let hue = CGFloat(stableColorIndex(for: appID)) / 12
        context.setFillColor(NSColor(hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))

        let letter = String(name.prefix(1)).uppercased()
        let fontSize = CGFloat(pointSize) * 0.55 * CGFloat(max(1, scale))
        let attributed = NSAttributedString(
            string: letter,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(
            x: (CGFloat(pixels) - bounds.width) / 2 - bounds.minX,
            y: (CGFloat(pixels) - bounds.height) / 2 - bounds.minY
        )
        CTLineDraw(line, context)
        guard let cgImage = context.makeImage() else {
            return NSImage(size: NSSize(width: pointSize, height: pointSize))
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: pointSize, height: pointSize))
    }

    static func stableColorIndex(for appID: AppID) -> Int {
        var hash: UInt64 = 5381
        for byte in appID.rawValue.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Int(hash % 12)
    }
}

/// App Library 卡片单元格: 轻玻璃卡 + 标题 + 最多 3 个大图标 + 最多 4 个
/// mini 图标。
///
/// 图标异步到达; 复用与新配置会取消旧请求并递增 generation, 迟到结果必须
/// 仍代表同一 AppID 且 generation 未过期才能应用(防串图)。
///
/// 点击路由: 大图标 → `.launch(AppID)`; 标题/mini 区 → `.openDetail`。
/// mouseDown 有轻微即时 press feedback(Reduce Motion 下跳过)。
@MainActor
final class AppLibraryCardCell: NSCollectionViewItem {
    enum Action: Equatable {
        case launch(AppID)
        case openDetail
    }

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AppLibraryCardCell")

    static let maxPrimaryIcons = 3
    static let maxMiniIcons = 4
    private static let pressClickThreshold: CGFloat = 6

    private let cardView = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var primaryImageViews: [NSImageView] = []
    private var miniImageViews: [NSImageView] = []
    private let miniContainer = NSView()

    private var representedCardID: AppLibraryCardID?
    private var representedPrimaryAppIDs: [AppID] = []
    private var representedPrimaryNames: [String] = []
    private var representedMiniAppIDs: [AppID] = []
    private var representedMiniNames: [String] = []
    private var iconProvider: (any IconImageProviding)?
    private var requestGeneration: UInt64 = 0
    private var iconTasks: [Task<Void, Never>] = []
    private var backingScale = 2
    private var reducedMotion = false

    private var pressStartPoint: NSPoint?

    /// 点击路由(由 controller 在配置时设置)。
    var onAction: ((Action) -> Void)?

    /// 当前配置的 card 身份(测试 seam)。
    private(set) var cardID: AppLibraryCardID?

    /// 点击热区(根视图坐标; 供路由与测试)。
    private(set) var primaryFrames: [CGRect] = []
    private(set) var miniFrame: CGRect = .zero
    private(set) var titleFrame: CGRect = .zero

    /// 已成功应用的 provider 图标(AppID → CGImage, 测试 seam)。
    private(set) var appliedImages: [AppID: CGImage] = [:]

    override func loadView() {
        let root = LibraryCardRootView()
        root.wantsLayer = true
        root.onMouseDown = { [weak self] point in
            self?.beginPress(at: point)
        }
        root.onMouseUp = { [weak self] point in
            self?.endPressAndDispatch(at: point)
        }

        cardView.material = .hudWindow
        cardView.blendingMode = .withinWindow
        cardView.state = .active
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 14
        cardView.layer?.masksToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(cardView)
        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            cardView.topAnchor.constraint(equalTo: root.topAnchor),
            cardView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityRole(.button)
        cardView.addSubview(titleLabel)

        miniContainer.wantsLayer = true
        miniContainer.isHidden = true
        miniContainer.layer?.cornerRadius = 8
        miniContainer.layer?.masksToBounds = true
        miniContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        miniContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.30).cgColor
        miniContainer.layer?.borderWidth = 1
        miniContainer.setAccessibilityRole(.button)
        cardView.addSubview(miniContainer)

        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutContent()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        reset()
    }

    /// 配置卡片。会取消上一身份的全部图标请求并清空旧图标。
    func configure(
        cardID: AppLibraryCardID,
        title: String,
        primary: [(appID: AppID, name: String)],
        mini: [(appID: AppID, name: String)],
        provider: (any IconImageProviding)?,
        backingScale: Int,
        reducedMotion: Bool
    ) {
        reset()
        representedCardID = cardID
        self.cardID = cardID
        self.iconProvider = provider
        self.backingScale = max(1, backingScale)
        self.reducedMotion = reducedMotion

        titleLabel.stringValue = title
        titleLabel.setAccessibilityLabel(title)
        titleLabel.setAccessibilityHelp(L10n.t(.categoryDetailHelp))
        cardView.setAccessibilityLabel(title)
        cardView.setAccessibilityHelp(L10n.t(.libraryCardsHelp))

        let primaryPairs = Array(primary.prefix(Self.maxPrimaryIcons))
        let miniPairs = Array(mini.prefix(Self.maxMiniIcons))
        representedPrimaryAppIDs = primaryPairs.map(\.appID)
        representedPrimaryNames = primaryPairs.map(\.name)
        representedMiniAppIDs = miniPairs.map(\.appID)
        representedMiniNames = miniPairs.map(\.name)
        configureIconViews(count: primaryPairs.count, miniCount: miniPairs.count)

        for (index, pair) in primaryPairs.enumerated() {
            let imageView = primaryImageViews[index]
            imageView.setAccessibilityLabel(pair.name)
            imageView.setAccessibilityHelp(L10n.format(.launchApp, pair.name))
            showPlaceholder(in: imageView, appID: pair.appID, name: pair.name, pointSize: primaryPointSize)
        }
        for (index, pair) in miniPairs.enumerated() {
            let imageView = miniImageViews[index]
            imageView.setAccessibilityLabel(pair.name)
            imageView.setAccessibilityHelp(L10n.format(.launchApp, pair.name))
            showPlaceholder(in: imageView, appID: pair.appID, name: pair.name, pointSize: miniPointSize)
        }
        miniContainer.setAccessibilityLabel(L10n.t(.viewMoreApps))
        miniContainer.setAccessibilityHelp(L10n.t(.categoryDetailHelp))
        applyAccessibilityShell()

        guard let provider else { return }
        let expectedGeneration = requestGeneration
        let primarySize = primaryPointSize
        let miniSize = miniPointSize
        let scale = self.backingScale
        for (index, pair) in primaryPairs.enumerated() {
            let appID = pair.appID
            iconTasks.append(Task { [weak self] in
                guard !Task.isCancelled else { return }
                let image = await provider.icon(for: appID, pointSize: primarySize, scale: scale)
                guard !Task.isCancelled,
                      let self,
                      self.representedCardID == cardID,
                      self.requestGeneration == expectedGeneration,
                      self.representedPrimaryAppIDs.indices.contains(index),
                      self.representedPrimaryAppIDs[index] == appID else { return }
                self.applyIcon(image, to: self.primaryImageViews[index], appID: appID, pointSize: primarySize)
            })
        }
        for (index, pair) in miniPairs.enumerated() {
            let appID = pair.appID
            iconTasks.append(Task { [weak self] in
                guard !Task.isCancelled else { return }
                let image = await provider.icon(for: appID, pointSize: miniSize, scale: scale)
                guard !Task.isCancelled,
                      let self,
                      self.representedCardID == cardID,
                      self.requestGeneration == expectedGeneration,
                      self.representedMiniAppIDs.indices.contains(index),
                      self.representedMiniAppIDs[index] == appID else { return }
                self.applyIcon(image, to: self.miniImageViews[index], appID: appID, pointSize: miniSize)
            })
        }
    }

    /// 在根视图坐标中分发一次点击(鼠标/测试共用)。
    func handleClick(at point: NSPoint) {
        guard representedCardID != nil else { return }
        if let index = primaryFrames.firstIndex(where: { $0.contains(point) }),
           representedPrimaryAppIDs.indices.contains(index) {
            onAction?(.launch(representedPrimaryAppIDs[index]))
        } else if miniFrame.contains(point) || titleFrame.contains(point) {
            onAction?(.openDetail)
        }
    }

    /// 测试 seam: 已应用的 provider 图标(AppID → image)。
    func appliedIconImage(for appID: AppID) -> CGImage? {
        appliedImages[appID]
    }

    // MARK: - 按压反馈

    private func beginPress(at point: NSPoint) {
        pressStartPoint = point
        guard !reducedMotion else { return }
        animateTransform(CATransform3DMakeScale(MotionTokens.titlePressScale, MotionTokens.titlePressScale, 1))
    }

    private func endPressAndDispatch(at point: NSPoint) {
        let shouldClick: Bool
        if let start = pressStartPoint {
            let dx = point.x - start.x
            let dy = point.y - start.y
            shouldClick = (dx * dx + dy * dy) <= (Self.pressClickThreshold * Self.pressClickThreshold)
        } else {
            shouldClick = true
        }
        pressStartPoint = nil
        guard !reducedMotion else {
            if shouldClick { handleClick(at: point) }
            return
        }
        animateTransform(CATransform3DIdentity)
        if shouldClick { handleClick(at: point) }
    }

    private func animateTransform(_ transform: CATransform3D) {
        guard let layer = view.layer else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MotionTokens.pressFeedback.response
            context.allowsImplicitAnimation = true
            layer.transform = transform
        }
    }

    // MARK: - 内容布局

    private var primaryPointSize: Int {
        Int(primaryIconSize.rounded())
    }

    private var miniPointSize: Int {
        Int(miniIconSize.rounded())
    }

    private var primaryIconSize: CGFloat {
        min(76, max(40, view.bounds.width * 0.20))
    }

    private var miniIconSize: CGFloat {
        min(32, max(18, primaryIconSize * 0.42))
    }

    private func layoutContent() {
        let bounds = cardView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let padding: CGFloat = 14
        let titleHeight: CGFloat = 18
        let gap: CGFloat = 12
        let iconGap: CGFloat = 12

        titleFrame = CGRect(
            x: padding,
            y: bounds.height - padding - titleHeight,
            width: max(0, bounds.width - padding * 2),
            height: titleHeight
        )
        titleLabel.frame = titleFrame

        let iconSize = primaryIconSize
        let iconsY = bounds.height - padding - titleHeight - gap - iconSize
        let count = representedPrimaryAppIDs.count
        let totalWidth = CGFloat(count) * iconSize + CGFloat(max(0, count - 1)) * iconGap
        let startX = max(0, (bounds.width - totalWidth) / 2)
        primaryFrames = (0..<count).map { index in
            CGRect(
                x: startX + CGFloat(index) * (iconSize + iconGap),
                y: iconsY,
                width: iconSize,
                height: iconSize
            )
        }
        for (index, imageView) in primaryImageViews.enumerated() {
            if primaryFrames.indices.contains(index) {
                imageView.frame = primaryFrames[index]
                imageView.isHidden = false
            } else {
                imageView.isHidden = true
            }
        }

        let miniCount = representedMiniAppIDs.count
        if miniCount > 0 {
            let miniSize = miniIconSize
            let miniGap: CGFloat = 8
            let miniPadding: CGFloat = 10
            let miniTotal = CGFloat(miniCount) * miniSize + CGFloat(miniCount - 1) * miniGap
                + miniPadding * 2
            miniFrame = CGRect(
                x: max(0, (bounds.width - miniTotal) / 2),
                y: padding,
                width: miniTotal,
                height: miniSize + miniPadding * 2
            )
            miniContainer.isHidden = false
            miniContainer.frame = miniFrame
            for (index, imageView) in miniImageViews.enumerated() {
                let x = miniPadding + CGFloat(index) * (miniSize + miniGap)
                imageView.frame = CGRect(x: x, y: miniPadding, width: miniSize, height: miniSize)
                imageView.isHidden = index >= miniCount
            }
        } else {
            miniFrame = .zero
            miniContainer.isHidden = true
        }
    }

    private func configureIconViews(count: Int, miniCount: Int) {
        while primaryImageViews.count < count {
            let imageView = makeIconImageView()
            primaryImageViews.append(imageView)
            cardView.addSubview(imageView)
        }
        while miniImageViews.count < miniCount {
            let imageView = makeIconImageView()
            miniImageViews.append(imageView)
            miniContainer.addSubview(imageView)
        }
    }

    private func makeIconImageView() -> NSImageView {
        let imageView = NSImageView()
        imageView.wantsLayer = true
        imageView.imageScaling = .scaleProportionallyDown
        imageView.layer?.contentsGravity = .resizeAspect
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.setAccessibilityRole(.button)
        return imageView
    }

    private func showPlaceholder(in imageView: NSImageView, appID: AppID, name: String, pointSize: Int) {
        imageView.image = AppLibraryIconPlaceholder.image(
            appID: appID,
            name: name,
            pointSize: pointSize,
            scale: backingScale
        )
    }

    private func applyIcon(_ image: CGImage?, to imageView: NSImageView, appID: AppID, pointSize: Int) {
        if let image {
            imageView.image = NSImage(cgImage: image, size: NSSize(width: pointSize, height: pointSize))
            appliedImages[appID] = image
        } else if let name = nameFor(appID: appID) {
            showPlaceholder(in: imageView, appID: appID, name: name, pointSize: pointSize)
        }
    }

    private func nameFor(appID: AppID) -> String? {
        if let index = representedPrimaryAppIDs.firstIndex(of: appID) {
            return representedPrimaryNames.indices.contains(index) ? representedPrimaryNames[index] : nil
        }
        if let index = representedMiniAppIDs.firstIndex(of: appID) {
            return representedMiniNames.indices.contains(index) ? representedMiniNames[index] : nil
        }
        return nil
    }

    // MARK: - 复用

    private func reset() {
        for task in iconTasks {
            task.cancel()
        }
        iconTasks.removeAll(keepingCapacity: true)
        requestGeneration &+= 1
        representedCardID = nil
        cardID = nil
        representedPrimaryAppIDs = []
        representedPrimaryNames = []
        representedMiniAppIDs = []
        representedMiniNames = []
        appliedImages = [:]
        pressStartPoint = nil
        primaryFrames = []
        miniFrame = .zero
        titleFrame = .zero
        if isViewLoaded {
            titleLabel.stringValue = ""
            for imageView in primaryImageViews {
                imageView.image = nil
            }
            for imageView in miniImageViews {
                imageView.image = nil
            }
            view.layer?.transform = CATransform3DIdentity
        }
    }

    private func applyAccessibilityShell() {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(L10n.t(.appLibrary))
        view.setAccessibilityHelp(L10n.t(.libraryCardsHelp))
        view.setAccessibilityChildren([
            titleLabel,
            miniContainer,
        ] + primaryImageViews + miniImageViews)
    }
}

/// 卡片根视图: 捕获 mouseDown/mouseUp 序列, 转发给 cell(路由与按压反馈)。
@MainActor
private final class LibraryCardRootView: NSView {
    var onMouseDown: ((NSPoint) -> Void)?
    var onMouseUp: ((NSPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onMouseDown?(point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onMouseUp?(point)
    }
}
