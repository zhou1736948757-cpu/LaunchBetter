import Foundation
import Testing
@testable import LaunchCore

@Suite("AppID 纯规范化与编码")
struct AppIDTests {
    @Test("首尾空白被裁剪")
    func trimsWhitespace() {
        #expect(AppID("  /Applications/Safari.app  ")?.rawValue == "/Applications/Safari.app")
        #expect(AppID("\n/Applications/Safari.app\n")?.rawValue == "/Applications/Safari.app")
    }

    @Test("尾部斜杠被移除")
    func removesTrailingSlash() {
        #expect(AppID("/Applications/Safari.app/")?.rawValue == "/Applications/Safari.app")
        #expect(AppID("/Applications/Safari.app///")?.rawValue == "/Applications/Safari.app")
    }

    @Test("根路径保留单个斜杠")
    func preservesRootSlash() {
        #expect(AppID("/")?.rawValue == "/")
        #expect(AppID("///")?.rawValue == "/")
    }

    @Test("空与纯空白返回 nil")
    func emptyIsNil() {
        #expect(AppID("") == nil)
        #expect(AppID("   ") == nil)
        #expect(AppID("\n\t") == nil)
        #expect(AppID("///") != nil)
    }

    @Test("等式与哈希一致性")
    func equalityAndHash() {
        let a = AppID("/Applications/Safari.app")
        let b = AppID("/Applications/Safari.app/")
        #expect(a == b)
        #expect(a?.hashValue == b?.hashValue)
        #expect(a != AppID("/Applications/Notes.app"))
    }

    @Test("Codable 往返")
    func codableRoundTrip() throws {
        let id = try #require(AppID("/Applications/Safari.app"))
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(AppID.self, from: data)
        #expect(decoded == id)
        #expect(decoded.rawValue == "/Applications/Safari.app")
    }

    @Test("解码时规范化: 尾部斜杠被规范化")
    func decodeNormalizes() throws {
        let data = try JSONEncoder().encode("/Applications/Safari.app/")
        let decoded = try JSONDecoder().decode(AppID.self, from: data)
        #expect(decoded.rawValue == "/Applications/Safari.app")
    }

    @Test("解码空白字符串抛错")
    func decodeEmptyThrows() {
        #expect(throws: DecodingError.self) {
            let data = try JSONEncoder().encode("   ")
            _ = try JSONDecoder().decode(AppID.self, from: data)
        }
    }

    @Test("normalized 直构保留给定值")
    func normalizedInit() {
        let id = AppID(normalized: "/Applications/Safari.app")
        #expect(id.rawValue == "/Applications/Safari.app")
    }
}

@Suite("FolderID 规范化与编码")
struct FolderIDTests {
    @Test("空白与尾斜杠规范化")
    func normalization() {
        #expect(FolderID("  Folder A/ ")?.rawValue == "Folder A")
        #expect(FolderID("Folder A")?.rawValue == "Folder A")
        #expect(FolderID("") == nil)
    }

    @Test("Codable 往返")
    func codableRoundTrip() throws {
        let id = try #require(FolderID("Tools"))
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(FolderID.self, from: data)
        #expect(decoded == id)
    }
}
