import Foundation
import AVFoundation

// MARK: - 路径常量

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let fallbackEntries = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources/entries.json")
    static let entries = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json")
    static let index = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    static let videosDir = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos")
    static let thumbnailsDir = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/thumbnails")
    static let cacheDir = URL(fileURLWithPath: "/var/folders/pc/8127vy3j6wsgyhvmr8pcjc680000gn/C/com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache")
    static let state = URL(fileURLWithPath: "/tmp/mwi_inject_state.json")
    static let httpDir = URL(fileURLWithPath: "/tmp/mwi_http")
    static let exp009Baseline = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Sources/MWIPanel
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // panel
        .deletingLastPathComponent() // 根
        .appendingPathComponent("backup/exp009")

    static let templateAssetID = "6511D2B5-E185-4886-9505-B4004E920D27" // Landscape/Golden Gate 字段齐全
    static let landscapeCatID = "A33A55D9-EDEA-4596-A850-6C10B54FBBB5"
    static let goldenGateSubID = "67512508-D33E-4CBC-8A9E-BE55CEE35C4C"
    static let defaultPort = 8181
}

// MARK: - JSON/plist 工具

enum PList {
    static func loadDict(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else { return [:] }
        return dict
    }

    static func saveDict(_ dict: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }
}

enum JSONFile {
    static func loadDict(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return [:] }
        return dict
    }

    static func saveDict(_ dict: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func loadArray(_ url: URL) -> [[String: Any]] {
        (loadDict(url)["assets"] as? [[String: Any]]) ?? []
    }
}

// MARK: - 数据模型

struct InjectedAsset: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let categories: [String]
    let subcategories: [String]
    let url: String
    let downloaded: Bool
    let thumb: String  // 本地缩略图路径(空 = 无)
}

struct StatusInfo: Codable, Equatable {
    let assetID: String
    let name: String
    let downloaded: Bool
    let startReading: Bool
    let looping: Bool
    let snapshot: Bool
    let playing: Bool
}
