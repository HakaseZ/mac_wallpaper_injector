// code-review-marker
import Foundation
import AVFoundation

// MARK: - 路径配置(可注入,沙箱测试用 `Paths.current` 覆盖)

/// 壁纸注入相关路径集合。测试将 `Paths.current` 指向临时沙箱,不触碰真实系统状态。
struct AerialPaths {
    let fallbackEntries: URL   // 系统只读 fallback manifest(原厂资产模板)
    let entries: URL           // 用户可写 manifest(注入资产写入处)
    let index: URL             // 系统壁纸设置 Index.plist
    let videosDir: URL         // 注入视频预置目录
    let thumbnailsDir: URL     // 注入缩略图预置目录
    let httpDir: URL           // 本地静态服务目录(抽帧/旧下载源)
    let cacheDir: URL          // 系统壁纸扩展 view-model 缓存(清缓存强制重建)
    let backupDir: URL         // entries 注入前备份(用户可写目录,不依赖构建机路径)

    static let system = AerialPaths(
        fallbackEntries: URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex/Contents/Resources/entries.json"),
        entries: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json"),
        index: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist"),
        videosDir: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos"),
        thumbnailsDir: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/thumbnails"),
        httpDir: URL(fileURLWithPath: "/tmp/mwi_http"),
        cacheDir: {
            // 系统进程缓存位于 per-user /var/folders/<hash>/C/;与临时目录同 hash 根(不可硬编码)
            let tmp = FileManager.default.temporaryDirectory   // /var/folders/<xx>/<hash>/T/
            let userRoot = tmp.deletingLastPathComponent().deletingLastPathComponent()
            return userRoot.appendingPathComponent("C/com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache")
        }(),
        backupDir: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/mwi-backup")
    )
}

enum Paths {
    static var current: AerialPaths = .system
    static var fallbackEntries: URL { current.fallbackEntries }
    static var entries: URL { current.entries }
    static var index: URL { current.index }
    static var videosDir: URL { current.videosDir }
    static var thumbnailsDir: URL { current.thumbnailsDir }
    static var httpDir: URL { current.httpDir }
    static var cacheDir: URL { current.cacheDir }
    static var backupDir: URL { current.backupDir }

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
