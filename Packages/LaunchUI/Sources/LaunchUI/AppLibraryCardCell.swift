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

/// App Library 卡片单元格: 轻玻璃卡 + 标题 + 2×2 象限内容。
///
/// 象限构成(普通分类/Recently Added): 左上/右上/左下 = 大图标 0/1/2,
/// 右下 = mini 2×2 簇; Suggestions 卡为 2×2 四个大图标。标题 top-left 对齐,
/// 卡片内不放 app 文本标签(无障碍保留全名)。
///
/// 图标异步到达; 复用与新配置会取消旧请求并递增 generation, 迟到结果必须
/// 仍代表同一 AppID 且 generation 未过期才能应用(防串图)。
///
/// 点击路由: 大图标 → `.launch(AppID)`; mini 区 / 标题 → `.openDetail`。
/// mouseDown 有轻微即时 press feedback(Reduce Motion 下跳过)。
@MainActor
final class AppLibraryCardCell: NSCollectionViewItem {
    enum Action: Equatable {
        case launch(AppID)
        case openDetail
    }

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AppLibraryCardCell")

    static let maxPrimaryIcons = 4
    static let maxMiniIcons = 4
    private static let pressClickThreshold: CGFloat = 6
    private static let cardPadding: CGFloat = 14
    private static let cardTitleHeight: CGFloat = 18
    private static let titleGap: CGFloat = 12
    private static let quadrantGap: CGFloat = 12
    private static let miniGap: CGFloat = 8
    /// 重分类悬停高亮幅度(克制; 计时经 MotionTokens.pressFeedback)。
    private static let reclassificationHoverScale: CGFloat = 1.02
    private static let reclassificationHoverBorderWidth: CGFloat = 1.5

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

    /// 右键分类菜单入口(PA2; 由 controller 在配置时设置)。
    /// 参数: 命中的 AppID + 窗口坐标点(供 menu popUp)。
    var onCategoryMenu: ((AppID, NSPoint) -> Void)?

    /// 当前配置的 card 身份(测试 seam)。
    private(set) var cardID: AppLibraryCardID?

    /// 点击热区(根视图坐标; 供路由与测试)。
    private(set) var primaryFrames: [CGRect] = []
    private(set) var miniFrame: CGRect = .zero
    private(set) var titleFrame: CGRect = .zero
    /// mini 2×2 簇内各 mini 图标 frame(根视图坐标, 测试 seam)。
    private(set) var miniIconFrames: [CGRect] = []

    /// 已成功应用的 provider 图标(AppID → CGImage, 测试 seam)。
    private(set) var appliedImages: [AppID: CGImage] = [:]

    /// 主区大图标身份(顺序与 `primaryFrames` 一一对应; 重分类源命中/测试 seam)。
    var primaryAppIDs: [AppID] { representedPrimaryAppIDs }

    /// 当前是否处于重分类悬停高亮(测试 seam)。
    private(set) var reclassificationHoverActive = false

    override func loadView() {
        let root = LibraryCardRootView()
        root.wantsLayer = true
        root.onMouseDown = { [weak self] point in
            self?.beginPress(at: point)
        }
        root.onMouseUp = { [weak self] point in
            self?.endPressAndDispatch(at: point)
        }
        root.onRightMouseDown = { [weak self] point in
            self?.handleRightClick(at: point)
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
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityRole(.button)
        cardView.addSubview(titleLabel)

        miniContainer.wantsLayer = true
        miniContainer.isHidden = true
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
            LibraryBlankTraceLog.record(
                "card click point=\(LibraryBlankTraceLog.fmt(point)) "
                    + "cardHit=primary[\(index)] action=launch"
            )
            onAction?(.launch(representedPrimaryAppIDs[index]))
        } else if miniFrame.contains(point) || titleFrame.contains(point) {
            LibraryBlankTraceLog.record(
                "card click point=\(LibraryBlankTraceLog.fmt(point)) "
                    + "cardHit=\(miniFrame.contains(point) ? "mini" : "title") action=openDetail"
            )
            onAction?(.openDetail)
        } else {
            // V1: 卡内空白(图标/mini/标题之外的 padding/间隙)→ 打开分类 detail,
            // 与卡片交互对象语义一致(不触发空白隐藏)。
            LibraryBlankTraceLog.record(
                "card click point=\(LibraryBlankTraceLog.fmt(point)) "
                    + "cardHit=cardWhitespace action=openDetail"
            )
            onAction?(.openDetail)
        }
    }

    /// 右键分发(PA2): 只命中卡片大图标; mini 簇/标题无右键入口。
    /// 回调携带窗口坐标点(供 controller menu popUp)。
    func handleRightClick(at point: NSPoint) {
        guard let index = primaryFrames.firstIndex(where: { $0.contains(point) }),
              representedPrimaryAppIDs.indices.contains(index) else { return }
        let appID = representedPrimaryAppIDs[index]
        let windowPoint = view.convert(point, to: nil)
        onCategoryMenu?(appID, windowPoint)
    }

    /// 测试 seam: 已应用的 provider 图标(AppID → image)。
    func appliedIconImage(for appID: AppID) -> CGImage? {
        appliedImages[appID]
    }

    /// 重分类源视觉: 主区图标当前显示的图像(已应用 provider 图标或内存占位)。
    /// 复用已渲染内容, 零磁盘 / 零 Info.plist / 零新图标请求。
    func sourceVisualImage(at index: Int) -> NSImage? {
        guard primaryImageViews.indices.contains(index) else { return nil }
        return primaryImageViews[index].image
    }

    /// 重分类悬停高亮(仅"有效目标分类卡"): MotionTokens 约束的轻微 scale +
    /// border 强调; 离开立即恢复(临界阻尼, 无大弹跳/常亮)。Reduce Motion 下
    /// 状态即时应用(高亮本身是状态, 不是瞬态动效)。
    func setReclassificationHoverHighlighted(_ active: Bool) {
        guard reclassificationHoverActive != active, isViewLoaded else { return }
        reclassificationHoverActive = active
        let transform = active
            ? CATransform3DMakeScale(
                Self.reclassificationHoverScale,
                Self.reclassificationHoverScale,
                1
            )
            : CATransform3DIdentity
        let duration = reducedMotion ? 0 : MotionTokens.pressFeedback.response
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = !reducedMotion
            view.layer?.transform = transform
            if let cardLayer = cardView.layer {
                cardLayer.borderWidth = active ? Self.reclassificationHoverBorderWidth : 0
                cardLayer.borderColor = active
                    ? NSColor.white.withAlphaComponent(0.5).cgColor
                    : nil
            }
        }
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

    /// 图标区 2×2 象限的单象限尺寸(与 `layoutContent` 共用同一几何)。
    private var quadrantSize: CGSize {
        let w = view.bounds.width
        let h = view.bounds.height
        guard w > 0, h > 0 else { return .zero }
        let padding = Self.cardPadding
        let contentW = max(0, w - padding * 2)
        let contentH = max(
            0,
            (h - padding - Self.cardTitleHeight - Self.titleGap) - padding
        )
        return CGSize(
            width: max(0, (contentW - Self.quadrantGap) / 2),
            height: max(0, (contentH - Self.quadrantGap) / 2)
        )
    }

    private var primaryIconSize: CGFloat {
        let q = quadrantSize
        return min(76, max(40, min(q.width, q.height) * 0.70))
    }

    private var miniIconSize: CGFloat {
        let q = quadrantSize
        return min(32, max(18, (min(q.width, q.height) - Self.miniGap) / 2))
    }

    private func layoutContent() {
        let bounds = cardView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let padding = Self.cardPadding
        let titleHeight = Self.cardTitleHeight
        let gap = Self.titleGap
        let iconGap = Self.quadrantGap

        titleFrame = CGRect(
            x: padding,
            y: bounds.height - padding - titleHeight,
            width: max(0, bounds.width - padding * 2),
            height: titleHeight
        )
        titleLabel.frame = titleFrame

        let contentW = max(0, bounds.width - padding * 2)
        let contentAreaTop = bounds.height - padding - titleHeight - gap
        let contentAreaBottom = padding
        let contentH = max(0, contentAreaTop - contentAreaBottom)
        let colW = max(0, (contentW - iconGap) / 2)
        let rowH = max(0, (contentH - iconGap) / 2)
        let topRowY = contentAreaBottom + max(0, (contentH - 2 * rowH - iconGap) / 2)
        let bottomRowY = topRowY + rowH + iconGap
        let leftX = padding
        let rightX = padding + colW + iconGap
        let quadrants = [
            CGRect(x: leftX, y: topRowY, width: colW, height: rowH),
            CGRect(x: rightX, y: topRowY, width: colW, height: rowH),
            CGRect(x: leftX, y: bottomRowY, width: colW, height: rowH),
            CGRect(x: rightX, y: bottomRowY, width: colW, height: rowH),
        ]

        let iconSize = primaryIconSize
        let count = representedPrimaryAppIDs.count
        primaryFrames = quadrants.prefix(count).map { q in
            CGRect(
                x: q.midX - iconSize / 2,
                y: q.midY - iconSize / 2,
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
            let quadrant = quadrants[3]
            let miniSize = miniIconSize
            let clusterSize = miniSize * 2 + Self.miniGap
            let clusterX = quadrant.midX - clusterSize / 2
            let clusterY = quadrant.midY - clusterSize / 2
            miniFrame = quadrant
            miniContainer.isHidden = false
            miniContainer.frame = quadrant
            miniIconFrames = []
            for (index, imageView) in miniImageViews.enumerated() {
                let row = index / 2
                let column = index % 2
                imageView.frame = CGRect(
                    x: clusterX + CGFloat(column) * (miniSize + Self.miniGap),
                    y: clusterY + CGFloat(row) * (miniSize + Self.miniGap),
                    width: miniSize,
                    height: miniSize
                )
                imageView.isHidden = index >= miniCount
                if index < miniCount {
                    miniIconFrames.append(imageView.frame)
                }
            }
        } else {
            miniFrame = .zero
            miniIconFrames = []
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
        miniIconFrames = []
        titleFrame = .zero
        if isViewLoaded {
            reclassificationHoverActive = false
            titleLabel.stringValue = ""
            for imageView in primaryImageViews {
                imageView.image = nil
            }
            for imageView in miniImageViews {
                imageView.image = nil
            }
            view.layer?.transform = CATransform3DIdentity
            cardView.layer?.borderWidth = 0
            cardView.layer?.borderColor = nil
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
/// 右键(rightMouseDown)单独转发给 cell(分类菜单入口)。
@MainActor
private final class LibraryCardRootView: NSView {
    var onMouseDown: ((NSPoint) -> Void)?
    var onMouseUp: ((NSPoint) -> Void)?
    var onRightMouseDown: ((NSPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onMouseDown?(point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onMouseUp?(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onRightMouseDown?(point)
    }
}
