import AppKit
import LaunchCore
import QuartzCore
import Testing
@testable import LaunchUI

@Suite("L10n", .serialized)
@MainActor
struct L10nTests {
    private static let requiredKeys: [L10n.Key] = [
        .launchApp,
        .folderLabel,
        .folderContentsHelp,
        .renameFolderHelp,
        .permissionTitle,
        .permissionMessage,
        .later,
        .dropIntoFolder,
        .createFolderWith,
    ]

    @Test("new localization keys are complete in all supported languages")
    func newKeysAreComplete() {
        let previous = L10n.currentLanguage
        defer { L10n.configure(language: previous) }

        let expected: [(AppLanguage, [L10n.Key: String])] = [
            (
                .english,
                [
                    .launchApp: "Click to launch %@",
                    .folderLabel: "Folder %@",
                    .folderContentsHelp: "Folder contents and actions",
                    .renameFolderHelp: "Rename folder",
                    .permissionTitle: "Input Monitoring Permission Required",
                    .permissionMessage: "The four-finger pinch gesture requires Input Monitoring permission.\nClick “Open System Settings”, then enable LaunchBetter in Privacy & Security → Input Monitoring and return to the app.",
                    .later: "Later",
                    .dropIntoFolder: "Drop into %@",
                    .createFolderWith: "Create a folder with %@",
                ]
            ),
            (
                .simplifiedChinese,
                [
                    .launchApp: "点击启动 %@",
                    .folderLabel: "文件夹 %@",
                    .folderContentsHelp: "文件夹内容和操作",
                    .renameFolderHelp: "重命名文件夹",
                    .permissionTitle: "需要输入监控权限",
                    .permissionMessage: "四指捏合手势需要“输入监控”权限才能工作。\n请点击“打开系统设置”，在“隐私与安全性” → “输入监控”中启用 LaunchBetter，然后回到应用。",
                    .later: "稍后",
                    .dropIntoFolder: "放入 %@",
                    .createFolderWith: "与 %@ 建立文件夹",
                ]
            ),
            (
                .traditionalChinese,
                [
                    .launchApp: "點擊啟動 %@",
                    .folderLabel: "檔案夾 %@",
                    .folderContentsHelp: "檔案夾內容與操作",
                    .renameFolderHelp: "重新命名檔案夾",
                    .permissionTitle: "需要輸入監控權限",
                    .permissionMessage: "四指捏合手勢需要「輸入監控」權限才能運作。\n請點擊「開啟系統設定」，在「隱私權與安全性」→「輸入監控」中啟用 LaunchBetter，然後返回應用程式。",
                    .later: "稍後",
                    .dropIntoFolder: "放入 %@",
                    .createFolderWith: "與 %@ 建立檔案夾",
                ]
            ),
        ]

        for (language, translations) in expected {
            L10n.configure(language: language)
            #expect(Set(Self.requiredKeys) == Set(translations.keys))
            for key in Self.requiredKeys {
                guard let expectedValue = translations[key] else {
                    #expect(Bool(false), "Missing expected translation for \(key.rawValue)")
                    continue
                }
                #expect(L10n.t(key) == expectedValue)
                #expect(L10n.t(key) != key.rawValue)
            }
        }
    }

    @Test("formatted messages use the selected language")
    func formattedMessagesUseSelectedLanguage() {
        let previous = L10n.currentLanguage
        defer { L10n.configure(language: previous) }

        let expected: [(AppLanguage, String, String, String, String)] = [
            (.english, "Click to launch Safari", "Folder Work", "Drop into Work", "Create a folder with Safari"),
            (.simplifiedChinese, "点击启动 Safari", "文件夹 Work", "放入 Work", "与 Safari 建立文件夹"),
            (.traditionalChinese, "點擊啟動 Safari", "檔案夾 Work", "放入 Work", "與 Safari 建立檔案夾"),
        ]

        for (language, launch, folder, drop, create) in expected {
            L10n.configure(language: language)
            #expect(L10n.format(.launchApp, "Safari") == launch)
            #expect(L10n.format(.folderLabel, "Work") == folder)
            #expect(L10n.format(.dropIntoFolder, "Work") == drop)
            #expect(L10n.format(.createFolderWith, "Safari") == create)
        }
    }

    @Test("drag overlay target labels follow the live language")
    func dragOverlayTargetLabelsFollowLanguage() throws {
        let previous = L10n.currentLanguage
        defer { L10n.configure(language: previous) }

        let store = FolderLocalizationTestStore()
        let overlay = DragOverlayLayer()
        let labelLayer = try #require(
            overlay.layer.sublayers?.compactMap { $0 as? CATextLayer }.first
        )

        L10n.configure(language: .english)
        overlay.showFolderTarget(store.folderID, store: store)
        #expect(labelLayer.string as? String == "Drop into Test Folder")
        overlay.showCreateFolderTarget(name: "Safari")
        #expect(labelLayer.string as? String == "Create a folder with Safari")

        L10n.configure(language: .traditionalChinese)
        overlay.showFolderTarget(store.folderID, store: store)
        #expect(labelLayer.string as? String == "放入 Test Folder")
        overlay.showCreateFolderTarget(name: "Safari")
        #expect(labelLayer.string as? String == "與 Safari 建立檔案夾")

        L10n.configure(language: .simplifiedChinese)
        overlay.showFolderTarget(store.folderID, store: store)
        #expect(labelLayer.string as? String == "放入 Test Folder")
        overlay.showCreateFolderTarget(name: "Safari")
        #expect(labelLayer.string as? String == "与 Safari 建立文件夹")
    }

    @Test("language configuration switches immediately")
    func languageConfigurationSwitchesImmediately() {
        let previous = L10n.currentLanguage
        defer { L10n.configure(language: previous) }

        L10n.configure(language: .english)
        #expect(L10n.currentLanguage == .english)
        #expect(L10n.t(.folderContentsHelp) == "Folder contents and actions")

        L10n.configure(language: .traditionalChinese)
        #expect(L10n.currentLanguage == .traditionalChinese)
        #expect(L10n.t(.folderContentsHelp) == "檔案夾內容與操作")

        L10n.configure(language: .simplifiedChinese)
        #expect(L10n.currentLanguage == .simplifiedChinese)
        #expect(L10n.t(.folderContentsHelp) == "文件夹内容和操作")
    }

    @Test("an open folder refreshes localized presentation without rebuilding")
    func openFolderRefreshesLocalizedPresentation() throws {
        let previous = L10n.currentLanguage
        defer { L10n.configure(language: previous) }

        let store = FolderLocalizationTestStore()
        let controller = FolderViewController(
            store: store, iconProvider: nil, folderID: store.folderID
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        window.contentView = controller.view
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let rootID = ObjectIdentifier(controller.view)

        L10n.configure(language: .english)
        store.notifyDataObservers()
        try assertFolderPresentation(
            in: controller.view,
            folderLabel: "Folder Test Folder",
            folderHelp: "Folder contents and actions",
            renameTitle: "Rename…",
            renameHelp: "Rename folder",
            dissolveTitle: "Dissolve Folder",
            dissolveHelp: "Dissolve Folder"
        )

        L10n.configure(language: .traditionalChinese)
        store.notifyDataObservers()
        try assertFolderPresentation(
            in: controller.view,
            folderLabel: "檔案夾 Test Folder",
            folderHelp: "檔案夾內容與操作",
            renameTitle: "重新命名…",
            renameHelp: "重新命名檔案夾",
            dissolveTitle: "解散檔案夾",
            dissolveHelp: "解散檔案夾"
        )

        #expect(ObjectIdentifier(controller.view) == rootID)
    }

    private func assertFolderPresentation(
        in view: NSView,
        folderLabel: String,
        folderHelp: String,
        renameTitle: String,
        renameHelp: String,
        dissolveTitle: String,
        dissolveHelp: String
    ) throws {
        let views = descendants(of: view)
        let card = try #require(views.compactMap { $0 as? NSVisualEffectView }.first)
        #expect(card.accessibilityLabel() == folderLabel)
        #expect(card.accessibilityHelp() == folderHelp)

        let buttons = views.compactMap { $0 as? NSButton }
        let renameButton = try #require(buttons.first { $0.title == renameTitle })
        #expect(renameButton.accessibilityHelp() == renameHelp)
        let dissolveButton = try #require(buttons.first { $0.title == dissolveTitle })
        #expect(dissolveButton.accessibilityHelp() == dissolveHelp)

        let title = try #require(
            views.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Test Folder" }
        )
        #expect(title.accessibilityLabel() == folderLabel)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}

@MainActor
private final class FolderLocalizationTestStore: LauncherStoring {
    let appID = AppID("/Applications/FolderChild.app")!
    let folderID = FolderID("folder://localization-test")!

    var onDataChange: (() -> Void)?
    var searchQuery = ""
    let gridColumns = 7
    let gridRows = 6
    let iconSize = 64
    var wallpaperBlurRadius: Int { 30 }
    var searchBarWidth: Int { 320 }
    let displayRevision: UInt64 = 1

    private var observers: [UUID: () -> Void] = [:]

    @discardableResult
    func addDataObserver(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeDataObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    func notifyDataObservers() {
        for observer in observers.values {
            observer()
        }
    }

    func displayModel() -> DisplayModel {
        DisplayModel(
            pages: [[.folder(folderID)]],
            pageCapacity: gridColumns * gridRows,
            folderChildrenPayload: [folderID: [appID]]
        )
    }

    func searchResults() -> [DisplayModel.DisplayItem]? { nil }
    func displayName(for appID: AppID) -> String {
        appID == self.appID ? "Folder Child" : appID.rawValue
    }
    func folderName(for folderID: FolderID) -> String {
        folderID == self.folderID ? "Test Folder" : folderID.rawValue
    }
    func launch(_ appID: AppID) {}
    func createFolder(name: String, appIDs: [AppID]) {}
    func renameFolder(_ id: FolderID, to name: String) {}
    func dissolveFolder(_ id: FolderID) {}
    func addToFolder(app: AppID, folder: FolderID) {}
    func moveOutOfFolder(
        app: AppID,
        from folder: FolderID,
        toDisplayIndex: Int,
        completion: @escaping (Bool) -> Void
    ) {
        completion(false)
    }
    func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int) {}
    func folderNames() -> [FolderID: String] { [folderID: "Test Folder"] }
    func folderChildren(_ id: FolderID) -> [AppID]? { id == folderID ? [appID] : nil }
    func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation) {}
    func setHidden(_ appID: AppID, hidden: Bool) {}
    func setCustomName(_ appID: AppID, name: String?) {}
    func moveToTrash(_ appID: AppID) {}
    func isHidden(_ appID: AppID) -> Bool { false }
}
