import Foundation
import Testing

@Suite("Drag frame invalidation seams")
struct DragFrameIsolationTests {
    @Test("frame paths use session invalidation without reading Store revision")
    func framePathsAreStoreFree() throws {
        let source = try Self.controllerSource()
        let processTick = try Self.section(
            source,
            from: "private func processTick",
            to: "private func processFolderExitTick"
        )
        let folderExitTick = try Self.section(
            source,
            from: "private func processFolderExitTick",
            to: "private func setOverlayVisual"
        )

        #expect(processTick.contains("if sessionInvalidated"))
        #expect(!processTick.contains("store.displayRevision"))
        #expect(folderExitTick.contains("if sessionInvalidated"))
        #expect(!folderExitTick.contains("store.displayRevision"))
    }

    @Test("discrete revision gates and teardown reset remain in place")
    func discreteLifecycleSeamsRemain() throws {
        let source = try Self.controllerSource()
        let rootBegin = try Self.section(
            source,
            from: "func beginDrag(",
            to: "/// 文件夹子项越过卡片后启动的专用 session"
        )
        let folderBegin = try Self.section(
            source,
            from: "func beginFolderExitDrag(\n        app: AppID,\n        from folder: FolderID,\n        representation:",
            to: "/// 诊断: 手动驱动一帧"
        )
        let invalidation = try Self.section(
            source,
            from: "func invalidateActiveSessionForDisplayChange",
            to: "/// 诊断: overlay 是否仍挂在网格层上"
        )
        let endDrag = try Self.section(
            source,
            from: "func endDrag(",
            to: "private func awaitRootDropResult"
        )
        let teardown = try Self.section(
            source,
            from: "private func teardown",
            to: "private func source(from"
        )

        #expect(rootBegin.contains("sessionInvalidated = false"))
        #expect(folderBegin.contains("sessionInvalidated = false"))
        #expect(invalidation.contains("guard state == .dragging"))
        #expect(invalidation.contains("sessionInvalidated = true"))
        #expect(endDrag.contains("guard store.displayRevision == dragStartRevision"))
        #expect(endDrag.contains("if store.displayRevision != dragStartRevision"))
        #expect(teardown.contains("DragOverlayLayer.clearPendingSourceVisualCenter()"))
        #expect(teardown.contains("sessionInvalidated = false"))
    }

    private static func controllerSource() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LaunchUI/DragController.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func section(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> String {
        guard let start = source.range(of: startMarker),
              let end = source.range(
                  of: endMarker,
                  range: start.upperBound..<source.endIndex
              ) else {
            throw SourceTestError.missingSection(startMarker, endMarker)
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

private enum SourceTestError: Error {
    case missingSection(String, String)
}
