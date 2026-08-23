import Foundation
import Testing
@testable import LaunchCore

@Suite("SearchIndex")
struct SearchIndexTests {
    private var safariID: AppID { AppID("/Applications/Safari.app")! }
    private var notesID: AppID { AppID("/Applications/Notes.app")! }
    private var xcodeID: AppID { AppID("/Applications/Xcode.app")! }

    private func makeIndex() -> SearchIndex {
        var index = SearchIndex()
        index.index(
            safariID,
            displayName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            customName: nil
        )
        index.index(
            notesID,
            displayName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            customName: "我的笔记"
        )
        index.index(
            xcodeID,
            displayName: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            customName: nil
        )
        return index
    }

    @Test("空查询返回全部(排序)")
    func emptyQueryReturnsAllSorted() {
        let index = makeIndex()
        #expect(index.query("") == [notesID, safariID, xcodeID])
        #expect(index.query("   ") == [notesID, safariID, xcodeID])
    }

    @Test("displayName 大小写不敏感包含匹配")
    func displayNameMatch() {
        let index = makeIndex()
        #expect(index.query("saf") == [safariID])
        #expect(index.query("SAF") == [safariID])
        #expect(index.query("xcode") == [xcodeID])
    }

    @Test("bundleIdentifier 匹配")
    func bundleIdentifierMatch() {
        let index = makeIndex()
        #expect(index.query("com.apple.safari") == [safariID])
        #expect(index.query("dt.Xcode") == [xcodeID])
    }

    @Test("customName 匹配")
    func customNameMatch() {
        let index = makeIndex()
        #expect(index.query("笔记") == [notesID])
    }

    @Test("无匹配返回空")
    func noMatch() {
        let index = makeIndex()
        #expect(index.query("nonexistent") == [])
    }

    @Test("变音符不敏感: 无变音查询命中带变音名称")
    func diacriticInsensitiveMatch() {
        let cafeID = AppID("/Applications/Cafe.app")!
        var index = SearchIndex()
        index.index(
            cafeID,
            displayName: "Café",
            bundleIdentifier: nil,
            customName: nil
        )
        #expect(index.query("cafe") == [cafeID])
        #expect(index.query("CAFÉ") == [cafeID])
    }

    @Test("大小写 + 变音符组合")
    func caseAndDiacriticCombined() {
        let resumeID = AppID("/Applications/Resume.app")!
        var index = SearchIndex()
        index.index(
            resumeID,
            displayName: "Résumé Assistant",
            bundleIdentifier: "com.example.Resume",
            customName: nil
        )
        #expect(index.query("resume") == [resumeID])
        #expect(index.query("RÉSUMÉ") == [resumeID])
        #expect(index.query("résumé assistant") == [resumeID])
        // 变音符敏感差一字符: 省略一个重音但仍折叠命中
        #expect(index.query("resume a") == [resumeID])
    }

    @Test("remove 后不再命中")
    func removeApp() {
        var index = makeIndex()
        index.remove(safariID)
        #expect(index.query("safari") == [])
        #expect(index.query("") == [notesID, xcodeID])
    }

    @Test("removeAll 清空")
    func removeAll() {
        var index = makeIndex()
        index.removeAll()
        #expect(index.count == 0)
        #expect(index.query("") == [])
        #expect(index.query("safari") == [])
    }

    @Test("结果确定性: 多命中按 AppID 排序")
    func deterministicOrder() {
        let index = makeIndex()
        #expect(index.query("e") == [notesID, safariID, xcodeID])
    }
}
