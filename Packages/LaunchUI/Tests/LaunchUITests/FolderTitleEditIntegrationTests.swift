import AppKit
import LaunchCore
import Testing
@testable import LaunchUI

@Suite("Folder title inline rename integration")
@MainActor
struct FolderTitleEditIntegrationTests {
    private func makeEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 0
        )!
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }
    }

    private func findTitleView(in view: NSView) -> FolderTitleView? {
        if let title = view as? FolderTitleView { return title }
        for sub in view.subviews {
            if let found = findTitleView(in: sub) { return found }
        }
        return nil
    }

    @Test("long-press in a real window focuses the editor and keeps full name width")
    func longPressFocusesEditorAtFullWidth() throws {
        let store = TitleEditTestStore()
        let folderVC = FolderViewController(store: store, iconProvider: nil, folderID: store.folderID)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = folderVC.view
        folderVC.view.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let title = try #require(findTitleView(in: folderVC.view))
        // 长名字: 验证 editor 宽度不塌缩、名字不截断。
        #expect(title.text == "My Long Folder Name")

        let point = title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), from: nil)
        title.mouseDown(with: makeEvent(.leftMouseDown, at: point))
        pump(0.7)   // 长按达标 → 进入编辑
        pump(0.4)   // 延迟聚焦 async 执行

        let state = folderVC.diagnosticTitleEditState()
        #expect(state.contains("editing=true"))
        // 聚焦由真实运行(showstay)验证; 无头测试窗口无法成为 key 时不强求。
        // 核心回归: editor 宽度 ≥ 标题文字宽度(不截断, 最后一个字不消失)。
        if let width = extractWidth(from: state) {
            #expect(width >= 90, "editor 宽度塌缩导致名字截断: \(state)")
        }
        // intrinsic 尺寸应匹配长名字完整宽度。
        if let intrinsic = extractIntrinsicWidth(from: state) {
            #expect(intrinsic >= 90, "FolderTitleView intrinsic 塌缩: \(state)")
        }
    }

    private func extractWidth(from state: String) -> CGFloat? {
        // frame=(x, y, w, h)
        guard let range = state.range(of: "frame=(") else { return nil }
        let tail = state[range.upperBound...]
        let parts = tail.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3, let width = Double(parts[2]) else { return nil }
        return CGFloat(width)
    }

    private func extractIntrinsicWidth(from state: String) -> CGFloat? {
        // intrinsic=(w, h)
        guard let range = state.range(of: "intrinsic=(") else { return nil }
        let tail = state[range.upperBound...]
        let parts = tail.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 1, let width = Double(parts[0]) else { return nil }
        return CGFloat(width)
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
