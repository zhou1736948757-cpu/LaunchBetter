import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Rename prompt sheet presentation", .serialized)
@MainActor
struct RenamePromptPresenterTests {
    @Test("app rename is an attached sheet, focuses the field, and applies the async app icon")
    func appRenameSheetAndIcon() async throws {
        let window = makeWindow()
        let provider = RenameIconProvider(image: try makeSolidImage())
        let presenter = RenamePromptPresenter()
        let appID = try #require(AppID("/Applications/Rename Target.app"))
        var completedName: String?

        let presented = presenter.present(
            in: window,
            defaultValue: "Old Name",
            title: "Rename App",
            appID: appID,
            iconProvider: provider,
            iconPointSize: 64
        ) { completedName = $0 }

        let alert = try #require(presenter.activeAlert)
        let field = try #require(presenter.activeTextField)
        #expect(presented)
        #expect(window.attachedSheet === alert.window)
        #expect(alert.window.sheetParent === window)
        #expect(alert.messageText == "Rename App")
        #expect(alert.buttons.map(\.title) == [L10n.t(.ok), L10n.t(.cancel)])
        #expect(field.stringValue == "Old Name")
        #expect(alert.icon?.cgImage(forProposedRect: nil, context: nil, hints: nil) == nil)

        await eventually {
            alert.icon?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width == 2
        }
        await Task.yield()
        #expect(alert.window.firstResponder === field.currentEditor() || window.firstResponder === field)
        #expect(provider.requests.count == 1)
        #expect(provider.requests.first?.0 == appID)
        #expect(provider.requests.first?.1 == 64)

        field.stringValue = "  New Name  "
        window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        await Task.yield()

        #expect(completedName == "New Name")
        #expect(presenter.activeAlert == nil)
        #expect(window.attachedSheet == nil)
    }

    @Test("cancel returns nil and folder rename does not request an app icon")
    func folderCancelKeepsBehavior() async throws {
        let window = makeWindow()
        let provider = RenameIconProvider(image: try makeSolidImage())
        let presenter = RenamePromptPresenter()
        var completionCalled = false
        var completedName: String? = "unexpected"

        #expect(presenter.present(
            in: window,
            defaultValue: "Folder",
            title: "Rename Folder",
            appID: nil,
            iconProvider: provider,
            iconPointSize: 64
        ) { value in
            completionCalled = true
            completedName = value
        })

        let alert = try #require(presenter.activeAlert)
        #expect(window.attachedSheet === alert.window)
        window.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        await Task.yield()

        #expect(completionCalled)
        #expect(completedName == nil)
        #expect(provider.requests.isEmpty)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView()
        return window
    }

    private func makeSolidImage() throws -> CGImage {
        let data = Data(repeating: 0xFF, count: 2 * 2 * 4)
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<50 {
            if condition() { return }
            await Task.yield()
        }
    }
}

@MainActor
private final class RenameIconProvider: IconImageProviding {
    let image: CGImage
    var requests: [(AppID, Int)] = []

    init(image: CGImage) {
        self.image = image
    }

    func icon(for appID: AppID, pointSize: Int, scale: Int) async -> CGImage? {
        requests.append((appID, pointSize))
        await Task.yield()
        return image
    }

    func trimMemoryForHidden() {}
}
