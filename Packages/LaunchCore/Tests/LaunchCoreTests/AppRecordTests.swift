import Foundation
import Testing
@testable import LaunchCore

@Suite("AppRecord 序列化")
struct AppRecordTests {
    private func makeRecord(
        path: String = "/Applications/Safari.app",
        bundleID: String? = "com.apple.Safari",
        localizedNames: [String: String] = [:]
    ) throws -> AppRecord {
        let id = try #require(AppID(path))
        return AppRecord(
            id: id,
            url: URL(fileURLWithPath: path),
            bundleIdentifier: bundleID,
            displayName: "Safari",
            infoPlistModificationDate: Date(timeIntervalSince1970: 1_000),
            iconContentVersion: IconContentVersion(
                iconResourceModificationNanoseconds: 123,
                iconResourceSizeBytes: 456
            ),
            localizedNames: localizedNames
        )
    }

    @Test("Codable 往返保持全部字段")
    func codableRoundTrip() throws {
        let record = try makeRecord()
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AppRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.id == record.id)
        #expect(decoded.bundleIdentifier == "com.apple.Safari")
        #expect(decoded.iconContentVersion == record.iconContentVersion)
    }

    @Test("bundleIdentifier 可为 nil")
    func optionalBundleID() throws {
        let record = try makeRecord(bundleID: nil)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AppRecord.self, from: data)
        #expect(decoded.bundleIdentifier == nil)
    }

    @Test("Identifiable: id 即身份")
    func identifiable() throws {
        let record = try makeRecord()
        #expect(record.id == AppID("/Applications/Safari.app"))
    }

    @Test("相同内容哈希相等")
    func hashEquality() throws {
        #expect(try makeRecord() == makeRecord())
    }

    @Test("localizedNames Codable 往返保持")
    func localizedNamesRoundTrip() throws {
        let record = try makeRecord(localizedNames: [
            "en": "Safari", "zh-Hans": "浏览器", "zh-Hant": "瀏覽器",
        ])
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AppRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.localizedNames == record.localizedNames)
    }

    @Test("旧版记录(无 localizedNames 字段)解码迁移为空字典")
    func decodesLegacyRecord() throws {
        let legacyJSON = """
        {
          "id": "/Applications/Safari.app",
          "url": "file:///Applications/Safari.app",
          "bundleIdentifier": "com.apple.Safari",
          "displayName": "Safari",
          "infoPlistModificationDate": 1000,
          "iconContentVersion": {
            "iconResourceModificationNanoseconds": 123,
            "iconResourceSizeBytes": 456
          }
        }
        """
        let record = try JSONDecoder().decode(AppRecord.self, from: Data(legacyJSON.utf8))
        #expect(record.localizedNames.isEmpty)
        #expect(record.displayName == "Safari")
        #expect(record.bundleIdentifier == "com.apple.Safari")
    }
}

@Suite("AppRecord 本地化显示名解析")
struct LocalizedDisplayNameTests {
    private func record(_ names: [String: String]) throws -> AppRecord {
        let id = try #require(AppID("/Applications/Safari.app"))
        return AppRecord(
            id: id,
            url: URL(fileURLWithPath: "/Applications/Safari.app"),
            bundleIdentifier: "com.apple.Safari",
            displayName: "Safari",
            infoPlistModificationDate: nil,
            iconContentVersion: .empty,
            localizedNames: names
        )
    }

    @Test("英文偏好取 en")
    func english() throws {
        let r = try record(["en": "Safari", "zh-Hans": "浏览器"])
        #expect(r.localizedDisplayName(language: .english, systemPreferredLanguages: []) == "Safari")
    }

    @Test("简体偏好取 zh-Hans")
    func simplifiedChinese() throws {
        let r = try record(["en": "Safari", "zh-Hans": "浏览器"])
        #expect(
            r.localizedDisplayName(language: .simplifiedChinese, systemPreferredLanguages: [])
                == "浏览器"
        )
    }

    @Test("旧格式 zh_CN 归一到 zh-Hans(系统性: 百度网盘/微信类应用)")
    func legacyUnderscoreLocale() throws {
        let r = try record(["en": "BaiduNetdisk", "zh_CN": "百度网盘"])
        #expect(
            r.localizedDisplayName(language: .simplifiedChinese, systemPreferredLanguages: [])
                == "百度网盘"
        )
        #expect(
            r.localizedDisplayName(language: .system, systemPreferredLanguages: ["zh-Hans-CN"])
                == "百度网盘"
        )
    }

    @Test("旧格式 zh_TW 归一到 zh-Hant")
    func legacyTraditionalLocale() throws {
        let r = try record(["en": "App", "zh_TW": "應用"])
        #expect(
            r.localizedDisplayName(language: .traditionalChinese, systemPreferredLanguages: [])
                == "應用"
        )
    }

    @Test("区域后缀 zh-CN 归一到 zh-Hans")
    func regionSuffixLocale() throws {
        let r = try record(["en": "App", "zh-CN": "应用"])
        #expect(
            r.localizedDisplayName(language: .simplifiedChinese, systemPreferredLanguages: [])
                == "应用"
        )
    }

    @Test("繁体偏好取 zh-Hant")
    func traditionalChinese() throws {
        let r = try record(["en": "Safari", "zh-Hant": "瀏覽器"])
        #expect(
            r.localizedDisplayName(language: .traditionalChinese, systemPreferredLanguages: [])
                == "瀏覽器"
        )
    }

    @Test(".system 按系统首选语言推断")
    func systemPreferred() throws {
        let r = try record(["en": "Safari", "zh-Hans": "浏览器", "zh-Hant": "瀏覽器"])
        #expect(
            r.localizedDisplayName(language: .system, systemPreferredLanguages: ["zh-Hans-CN"])
                == "浏览器"
        )
        #expect(
            r.localizedDisplayName(language: .system, systemPreferredLanguages: ["zh-TW"])
                == "瀏覽器"
        )
        #expect(
            r.localizedDisplayName(language: .system, systemPreferredLanguages: ["en-US"])
                == "Safari"
        )
    }

    @Test("前缀匹配: zh-Hans-CN 命中 zh-Hans 候选, en-GB 命中 en")
    func prefixMatch() throws {
        let r = try record(["zh-Hans-CN": "浏览器", "en-GB": "Safari UK"])
        #expect(
            r.localizedDisplayName(language: .simplifiedChinese, systemPreferredLanguages: [])
                == "浏览器"
        )
        #expect(r.localizedDisplayName(language: .english, systemPreferredLanguages: []) == "Safari UK")
    }

    @Test("无匹配本地化回退 nil")
    func noMatch() throws {
        let r = try record(["fr": "Navigateur"])
        #expect(
            r.localizedDisplayName(language: .simplifiedChinese, systemPreferredLanguages: [])
                == nil
        )
    }

    @Test("无本地化名回退 nil")
    func empty() throws {
        let r = try record([:])
        #expect(
            r.localizedDisplayName(language: .english, systemPreferredLanguages: []) == nil
        )
    }

    @Test("繁体偏好带变体: zh-TW 存储命中 zh-Hant 候选")
    func variantTraditional() throws {
        let r = try record(["zh-TW": "瀏覽器"])
        #expect(
            r.localizedDisplayName(language: .traditionalChinese, systemPreferredLanguages: [])
                == "瀏覽器"
        )
    }
}
