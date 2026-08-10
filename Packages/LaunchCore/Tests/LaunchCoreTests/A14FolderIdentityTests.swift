import Foundation
import XCTest
@testable import LaunchCore

/// A14: DisplayItem 稳定身份 — folder 身份 = FolderID, children 是独立 payload。
/// 子项变化不得改变 folder 的 Diffable 身份(无 delete/insert、无 flicker)。
final class A14FolderIdentityTests: XCTestCase {
    private func folderID(_ s: String) -> FolderID { FolderID(normalized: s) }

    func testFolderIdentityIndependentOfChildren() {
        let f = folderID("F")
        let a = AppID(normalized: "/a")
        let b = AppID(normalized: "/b")
        let c = AppID(normalized: "/c")

        let d1 = DisplayModel(
            pages: [[.folder(f)]], pageCapacity: 10,
            folderChildrenPayload: [f: [a, b]]
        )
        let d2 = DisplayModel(
            pages: [[.folder(f)]], pageCapacity: 10,
            folderChildrenPayload: [f: [a, b, c]]
        )

        // 同一 FolderID → 同一 item(identity 相同)
        XCTAssertEqual(d1.flatSlots[0], d2.flatSlots[0])
        XCTAssertEqual(d1.flatSlots[0].hashValue, d2.flatSlots[0].hashValue)
        // payload 不同 → 仅刷新 payload, 身份不变
        XCTAssertNotEqual(d1.folderChildrenPayload, d2.folderChildrenPayload)
        XCTAssertEqual(d1.folderVisibleChildren(f), [a, b])
        XCTAssertEqual(d2.folderVisibleChildren(f), [a, b, c])
    }

    func testDifferentFoldersDifferentIdentity() {
        let f1 = folderID("F1")
        let f2 = folderID("F2")
        let d = DisplayModel(
            pages: [[.folder(f1), .folder(f2)]], pageCapacity: 10
        )
        XCTAssertNotEqual(d.flatSlots[0], d.flatSlots[1])
    }

    func testAppVsFolderDistinctIdentity() {
        let f = folderID("F")
        let a = AppID(normalized: "/a")
        let d = DisplayModel(pages: [[.app(a), .folder(f)]], pageCapacity: 10)
        XCTAssertNotEqual(d.flatSlots[0], d.flatSlots[1])
    }

    func testPayloadPreservedAcrossTransactionFinalize() {
        // moveIntoFolder 后 folder 身份不变, payload 更新(经 LayoutTransaction.finalize)
        let f = folderID("F")
        let a = AppID(normalized: "/a")
        let b = AppID(normalized: "/b")
        let c = AppID(normalized: "/c")
        let display = DisplayModel(
            pages: [[.app(a), .app(b), .folder(f)]], pageCapacity: 10,
            folderChildrenPayload: [f: [c]]
        )
        let result = LayoutTransaction.moveIntoFolder(
            display: display, app: a, folder: f, at: 0
        )
        XCTAssertNotNil(result)
        let after = result!.display
        let before = display.flatSlots.compactMap { item -> FolderID? in
            if case .folder(let fid) = item { return fid }; return nil
        }
        let afterIDs = after.flatSlots.compactMap { item -> FolderID? in
            if case .folder(let fid) = item { return fid }; return nil
        }
        // 身份稳定
        XCTAssertEqual(before, afterIDs)
        // payload 包含新子项
        let visible: [AppID] = after.folderVisibleChildren(f) ?? []
        XCTAssertEqual(visible, [a, c])
    }
}
