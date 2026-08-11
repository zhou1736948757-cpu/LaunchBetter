import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Folder title inline rename integration")
@MainActor
struct FolderTitleEditIntegrationTests {
    private func makeEvent(
        _ type: NSEvent.EventType,
        in window: NSWindow,
        at pointInWindow: NSPoint
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1, pressure: 0
        )!
    }

    private func sendMouse(
        _ type: NSEvent.EventType,
        in window: NSWindow,
        at pointInWindow: NSPoint
    ) {
        window.sendEvent(makeEvent(type, in: window, at: pointInWindow))
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private func findTitleView(in view: NSView) -> FolderTitleView? {
        if let title = view as? FolderTitleView { return title }
        for sub in view.subviews {
            if let found = findTitleView(in: sub) { return found }
        }
        return nil
    }

    private func findEditor(in view: NSView, matching string: String) -> NSTextField? {
        if let field = view as? NSTextField,
           !(field is FolderTitleLabel),
           field.stringValue == string {
            return field
        }
        for sub in view.subviews {
            if let found = findEditor(in: sub, matching: string) { return found }
        }
        return nil
    }

    @Test("long-press in a real window focuses the editor and keeps full name width")
    func longPressFocusesEditorAtFullWidth() throws {
        let store = TitleEditTestStore()
        let folderVC = FolderViewController(store: store, iconProvider: nil, folderID: store.folderID)

        let window = NSWindow(
            contentRect: NSRect(x: 137, y: 163, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = folderVC.view
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        let title = try #require(findTitleView(in: folderVC.view))
        let expectedName = store.folderName
        #expect(title.text == expectedName)

        let pointInWindow = title.convert(
            NSPoint(x: title.bounds.midX, y: title.bounds.midY),
            to: window.contentView
        )
        let hitView = try #require(window.contentView?.hitTest(pointInWindow))
        #expect(hitView === title, "标题内部 label 不应吞掉窗口命中")

        // 通过 NSWindow.sendEvent 走真实的 window -> contentView -> hitTest 分发链。
        sendMouse(.leftMouseDown, in: window, at: pointInWindow)
        pump(0.45)  // 超过 0.3 秒阈值 → 进入编辑
        pump(0.4)   // 延迟聚焦 async 执行

        let state = folderVC.diagnosticTitleEditState()
        #expect(state.contains("editing=true"))
        let editor = try #require(findEditor(in: folderVC.view, matching: expectedName))
        let editorFont = try #require(editor.font)
        let measuredTextWidth = FolderTitleEditingMetrics.renderedTextWidth(
            expectedName,
            font: editorFont
        )
        let card = try #require(title.superview)
        let availableEditorWidth = FolderTitleEditingMetrics.availableEditorWidth(
            cardWidth: card.bounds.width
        )
        let initialEditorWidth = editor.frame.width

        #expect(editor.stringValue == expectedName)
        #expect(
            editor.frame.width >= measuredTextWidth + 8,
            "编辑框没有为实际文字保留水平余量: \(editor.frame) textWidth=\(measuredTextWidth)"
        )
        #expect(
            editor.frame.width <= availableEditorWidth + 0.5,
            "编辑框超过卡片可用宽度: \(editor.frame) available=\(availableEditorWidth)"
        )

        let expandedName = expectedName + " X"
        editor.stringValue = expandedName
        folderVC.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: editor)
        )

        #expect(editor.stringValue == expandedName)
        #expect(
            editor.frame.width > initialEditorWidth,
            "编辑框未随输入内容扩展: before=\(initialEditorWidth) after=\(editor.frame.width)"
        )
        #expect(
            editor.frame.width <= availableEditorWidth + 0.5,
            "编辑中编辑框超过卡片可用宽度: \(editor.frame) available=\(availableEditorWidth)"
        )

        sendMouse(.leftMouseUp, in: window, at: pointInWindow)
    }

    @Test("rendered width policy handles near-limit input paste deletion and IME")
    func renderedWidthPolicy() throws {
        let font = NSFont.boldSystemFont(ofSize: 24)
        let cardWidth = FolderPanelMetrics.cardSize.width
        let maximumTextWidth = FolderTitleEditingMetrics.maximumTextWidth(cardWidth: cardWidth)

        var nearLimit = ""
        while true {
            let candidate = nearLimit + "W"
            guard FolderTitleEditingMetrics.renderedTextWidth(candidate, font: font) <= maximumTextWidth else {
                break
            }
            nearLimit = candidate
        }
        #expect(!nearLimit.isEmpty)
        #expect(
            FolderTitleEditingMetrics.allowsChange(
                currentText: "",
                affectedRange: NSRange(location: 0, length: 0),
                replacementString: nearLimit,
                font: font,
                cardWidth: cardWidth,
                hasMarkedText: false
            )
        )

        let insertionRange = NSRange(location: (nearLimit as NSString).length, length: 0)
        let overWideInput = nearLimit + "W"
        #expect(
            FolderTitleEditingMetrics.renderedTextWidth(overWideInput, font: font)
                > maximumTextWidth
        )
        #expect(
            !FolderTitleEditingMetrics.allowsChange(
                currentText: nearLimit,
                affectedRange: insertionRange,
                replacementString: "W",
                font: font,
                cardWidth: cardWidth,
                hasMarkedText: false
            )
        )

        let grapheme = "👩‍💻"
        let overWidePaste = String(repeating: grapheme, count: 20)
        let pasteProposed = try #require(
            FolderTitleEditingMetrics.proposedString(
                currentText: "Base",
                affectedRange: NSRange(location: 0, length: ("Base" as NSString).length),
                replacementString: overWidePaste
            )
        )
        #expect(pasteProposed == overWidePaste)
        #expect(pasteProposed.count == 20)
        #expect(
            !FolderTitleEditingMetrics.allowsChange(
                currentText: "Base",
                affectedRange: NSRange(location: 0, length: ("Base" as NSString).length),
                replacementString: overWidePaste,
                font: font,
                cardWidth: cardWidth,
                hasMarkedText: false
            )
        )

        let overWideText = String(repeating: "W", count: 20)
        let deleteRange = NSRange(
            location: (overWideText as NSString).length - 1,
            length: 1
        )
        #expect(
            FolderTitleEditingMetrics.allowsChange(
                currentText: overWideText,
                affectedRange: deleteRange,
                replacementString: "",
                font: font,
                cardWidth: cardWidth,
                hasMarkedText: false
            )
        )
        #expect(
            FolderTitleEditingMetrics.allowsChange(
                currentText: overWideText,
                affectedRange: NSRange(location: 0, length: 2),
                replacementString: "W",
                font: font,
                cardWidth: cardWidth,
                hasMarkedText: false
            )
        )

        #expect(
            FolderTitleEditingMetrics.allowsChange(
                currentText: "Base",
                affectedRange: NSRange(location: 0, length: 0),
                replacementString: overWidePaste,
                font: font,
                cardWidth: cardWidth,
                hasMarkedText: true
            )
        )
    }

    @Test("over-wide IME commit restores the real field editor string and selection")
    func overWideIMECommitRestoresFieldEditorState() throws {
        let store = TitleEditTestStore()
        let folderVC = FolderViewController(store: store, iconProvider: nil, folderID: store.folderID)
        let window = NSWindow(
            contentRect: NSRect(x: 137, y: 163, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = folderVC.view
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        folderVC.startTitleEditingForDiagnostic()
        pump(0.2)

        let editor = try #require(findEditor(in: folderVC.view, matching: store.folderName))
        #expect(window.makeFirstResponder(editor))
        pump(0.1)
        let fieldEditor = try #require(editor.currentEditor() as? NSTextView)
        let lastValidString = store.folderName
        let lastValidSelection = NSRange(location: 2, length: 3)
        fieldEditor.setSelectedRange(lastValidSelection)
        folderVC.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: editor)
        )

        let markedText = String(repeating: "👩‍💻", count: 20)
        fieldEditor.setMarkedText(
            markedText,
            selectedRange: NSRange(location: (markedText as NSString).length, length: 0),
            replacementRange: NSRange(
                location: 0,
                length: (lastValidString as NSString).length
            )
        )
        #expect(fieldEditor.hasMarkedText())
        #expect(fieldEditor.string == markedText)

        fieldEditor.unmarkText()
        editor.stringValue = fieldEditor.string
        #expect(!fieldEditor.hasMarkedText())
        folderVC.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: editor)
        )

        #expect(editor.stringValue == lastValidString)
        #expect(fieldEditor.string == lastValidString)
        #expect(fieldEditor.selectedRange == lastValidSelection)
        #expect(
            NSMaxRange(fieldEditor.selectedRange)
                <= (lastValidString as NSString).length
        )
    }
}

/// 最小 LauncherStoring 测试存储(文件夹名较长, 验证不截断)。
private final class TitleEditTestStore: LauncherStoring {
    let appID = AppID("/Applications/TitleChild.app")!
    let folderID = FolderID("folder://title-edit")!
    let folderName = "My Long Folder Name"

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

    func displayModel() -> DisplayModel {
        DisplayModel(
            pages: [[.folder(folderID)]],
            pageCapacity: gridColumns * gridRows,
            folderChildrenPayload: [folderID: [appID]]
        )
    }

    func searchResults() -> [DisplayModel.DisplayItem]? { nil }
    func displayName(for appID: AppID) -> String { appID == self.appID ? "Title Child" : appID.rawValue }
    func folderName(for folderID: FolderID) -> String { folderID == self.folderID ? folderName : folderID.rawValue }
    func launch(_ appID: AppID) {}
    func createFolder(name: String, appIDs: [AppID]) {}
    func renameFolder(_ id: FolderID, to name: String) {}
    func dissolveFolder(_ id: FolderID) {}
    func addToFolder(app: AppID, folder: FolderID) {}
    func moveOutOfFolder(
        app: AppID, from folder: FolderID, toDisplayIndex: Int,
        completion: @escaping (Bool) -> Void
    ) { completion(false) }
    func reorderFolderApp(app: AppID, in folder: FolderID, toIndex: Int) {}
    func folderNames() -> [FolderID: String] { [folderID: folderName] }
    func folderChildren(_ id: FolderID) -> [AppID]? { id == folderID ? [appID] : nil }
    func applyDragDrop(_ mutation: LayoutTransaction.LayoutMutation) {}
    func setHidden(_ appID: AppID, hidden: Bool) {}
    func setCustomName(_ appID: AppID, name: String?) {}
    func moveToTrash(_ appID: AppID) {}
    func isHidden(_ appID: AppID) -> Bool { false }
}
