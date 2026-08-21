import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Settings slider measure probe", .serialized)
@MainActor
struct SettingsSliderMeasureProbe {
    @Test("measure slider runtime frames and grid geometry")
    func measure() throws {
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            let previousLanguage = L10n.currentLanguage
            L10n.configure(language: language)
            defer { L10n.configure(language: previousLanguage) }

            let handler = SettingsHandlerStub2(config: AppConfiguration(language: language))
            let controller = SettingsWindowController(handler: handler)
            let window = try #require(controller.window)
            let contentView = try #require(window.contentView)
            window.layoutIfNeeded()
            contentView.layoutSubtreeIfNeeded()

            let blurSlider = try #require(descendant2(
                of: NSSlider.self,
                identifier: "settings.blur",
                in: contentView
            ))
            let searchSlider = try #require(descendant2(
                of: NSSlider.self,
                identifier: "settings.searchBarSize",
                in: contentView
            ))
            print("PROBE[\(language)] blurSlider frame=\(blurSlider.frame) intrinsic=\(blurSlider.intrinsicContentSize)")
            print("PROBE[\(language)] searchSlider frame=\(searchSlider.frame) intrinsic=\(searchSlider.intrinsicContentSize)")
            let grids = descendantGrids(in: contentView)
            for (i, grid) in grids.enumerated() {
                let cellFrames = (0..<grid.numberOfRows).map { row -> String in
                    let col1 = grid.cell(atColumnIndex: 1, rowIndex: row)
                    guard let content = col1.contentView else { return "?" }
                    let f = content.convert(content.bounds, to: contentView)
                    return "r\(row)=[\(col1.xPlacement.rawValue) \(f.minX)..\(f.maxX) w=\(f.width)]"
                }
                print("PROBE[\(language)] grid[\(i)] rows=\(grid.numberOfRows) frame=\(grid.convert(grid.bounds, to: contentView)) col0=\(grid.column(at: 0).width) col1=\(grid.column(at: 1).width) cells=\(cellFrames)")
            }
        }

        // NSSlider intrinsic width probe in isolation
        let bare = NSSlider(value: 30, minValue: 0, maxValue: 60, target: nil, action: nil)
        print("PROBE bare slider intrinsic=\(bare.intrinsicContentSize) fitting=\(bare.fittingSize)")
        let bareStack = NSStackView(views: [NSTextField(labelWithString: "30"), bare])
        print("PROBE bareStack intrinsic=\(bareStack.intrinsicContentSize) fitting=\(bareStack.fittingSize)")
    }
}

@MainActor
private final class SettingsHandlerStub2: SettingsHandling {
    private(set) var config: AppConfiguration
    let allApps: [(id: AppID, name: String)]

    init(config: AppConfiguration, allApps: [(id: AppID, name: String)] = []) {
        self.config = config
        self.allApps = allApps
    }

    func save(_ config: AppConfiguration) {
        self.config = config
        L10n.configure(language: config.language)
    }
}

private func descendant2<View: NSView>(
    of type: View.Type,
    identifier: String,
    in root: NSView
) -> View? {
    descendantViews(in: root).first { $0.identifier?.rawValue == identifier } as? View
}

private func descendantGrids(in root: NSView) -> [NSGridView] {
    descendantViews(in: root).compactMap { $0 as? NSGridView }
}

private func descendantViews(in root: NSView) -> [NSView] {
    root.subviews.flatMap { view -> [NSView] in
        [view] + descendantViews(in: view)
    }
}
