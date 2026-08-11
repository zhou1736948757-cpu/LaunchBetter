import AppKit
import LaunchCore

/// Presents rename prompts as sheets owned by the launcher window.
///
/// `NSAlert` otherwise defaults to the host application's icon. App renames start
/// with an intentionally empty icon and replace it with the cached app icon when
/// the asynchronous provider completes. The request is scoped to the active
/// sheet so a late result cannot update a dismissed or replacement prompt.
@MainActor
final class RenamePromptPresenter {
    private(set) var activeAlert: NSAlert?
    private(set) var activeTextField: NSTextField?
    private var iconTask: Task<Void, Never>?

    @discardableResult
    func present(
        in parentWindow: NSWindow,
        defaultValue: String,
        title: String,
        appID: AppID?,
        iconProvider: (any IconImageProviding)?,
        iconPointSize: Int,
        completion: @escaping (String?) -> Void
    ) -> Bool {
        guard activeAlert == nil, parentWindow.attachedSheet == nil else { return false }

        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: L10n.t(.ok))
        alert.addButton(withTitle: L10n.t(.cancel))

        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field

        // A nil NSAlert icon means "use the host app icon". Use a transparent
        // image instead, so an app rename never flashes LaunchBetter's icon and
        // a folder rename remains deliberately iconless.
        alert.icon = NSImage(size: NSSize(width: 64, height: 64))

        activeAlert = alert
        activeTextField = field

        alert.beginSheetModal(for: parentWindow) { [weak self, weak alert] response in
            guard let self, let alert, self.activeAlert === alert else { return }
            let value = response == .alertFirstButtonReturn
                ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            self.finish()
            completion(value)
        }

        DispatchQueue.main.async { [weak self, weak alert, weak parentWindow] in
            guard let self, let alert, let parentWindow,
                  self.activeAlert === alert,
                  parentWindow.attachedSheet === alert.window else { return }
            parentWindow.makeFirstResponder(field)
        }

        if let appID, let iconProvider {
            let scale = max(1, Int(parentWindow.backingScaleFactor.rounded()))
            iconTask = Task { [weak self, weak alert, weak parentWindow] in
                let image = await iconProvider.icon(
                    for: appID,
                    pointSize: iconPointSize,
                    scale: scale
                )
                guard !Task.isCancelled,
                      let self, let alert, let parentWindow,
                      self.activeAlert === alert,
                      parentWindow.attachedSheet === alert.window else { return }
                if let image {
                    alert.icon = NSImage(
                        cgImage: image,
                        size: NSSize(width: iconPointSize, height: iconPointSize)
                    )
                } else {
                    alert.icon = NSWorkspace.shared.icon(forFile: appID.rawValue)
                }
            }
        } else if let appID {
            // Test hosts and lightweight embedders may omit the cache adapter.
            // NSWorkspace still gives the target bundle's icon without adding a
            // LaunchUI -> LaunchPlatform dependency.
            alert.icon = NSWorkspace.shared.icon(forFile: appID.rawValue)
        }

        return true
    }

    private func finish() {
        iconTask?.cancel()
        iconTask = nil
        activeTextField = nil
        activeAlert = nil
    }
}
