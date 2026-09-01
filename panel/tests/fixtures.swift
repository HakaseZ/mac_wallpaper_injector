// code-review-marker
import Foundation

// MARK: - 沙箱环境与测试夹具
// 把 Paths.current 指向临时目录 → 全部注入/删除/探测都不触碰真实系统壁纸状态。

/// ffmpeg 候选路径(与 WallpaperService 一致)
func ffmpegBin() -> String? {
    ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

func ffprobeBin() -> String? {
    guard let f = ffmpegBin() else { return nil }
    let p = URL(fileURLWithPath: f).deletingLastPathComponent().appendingPathComponent("ffprobe").path
    return FileManager.default.isExecutableFile(atPath: p) ? p : nil
}

/// 沙箱:全部路径指向临时目录;deinit/teardown 恢复系统路径并清理
final class Sandbox {
    let root: URL
    let paths: AerialPaths
    private let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("mwi-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home")
        paths = AerialPaths(
            fallbackEntries: root.appendingPathComponent("fallback/entries.json"),
            entries: home.appendingPathComponent("aerials/manifest/entries.json"),
            index: home.appendingPathComponent("Index.plist"),
            videosDir: home.appendingPathComponent("aerials/videos"),
            thumbnailsDir: home.appendingPathComponent("aerials/thumbnails"),
            httpDir: root.appendingPathComponent("http"),
            cacheDir: root.appendingPathComponent("cache"),
            backupDir: root.appendingPathComponent("backup")
        )
        for d in [paths.entries.deletingLastPathComponent(), paths.videosDir,
                  paths.thumbnailsDir, paths.httpDir, paths.backupDir,
                  paths.fallbackEntries.deletingLastPathComponent()] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try writeFallback()
        Paths.current = paths
    }

    /// 最小 fallback manifest:与真实系统同构(Landscape 分类 + Golden Gate 模板资产)
    private func writeFallback() throws {
        let goldenGateSub: [String: Any] = [
            "id": Paths.goldenGateSubID, "localizedNameKey": "Golden Gate 子分类", "preferredOrder": 0,
        ]
        let landscape: [String: Any] = [
            "id": Paths.landscapeCatID, "localizedNameKey": "Landscape", "subcategories": [goldenGateSub],
        ]
        let template: [String: Any] = [
            "id": Paths.templateAssetID, "localizedNameKey": "Golden Gate", "accessibilityLabel": "Golden Gate",
            "url": "https://example.com/gg.mov", "url-4K-SDR-240FPS": "https://example.com/gg4k.mov",
            "previewImage": "https://example.com/gg.png",
            "categories": [Paths.landscapeCatID], "subcategories": [Paths.goldenGateSubID],
        ]
        let manifest: [String: Any] = ["categories": [landscape], "assets": [template]]
        try JSONFile.saveDict(manifest, to: paths.fallbackEntries)
    }

    func teardown() {
        Paths.current = .system
        try? fm.removeItem(at: root)
    }

    deinit { teardown() }
}

/// 用 ffmpeg 生成小测试视频(lavfi testsrc2)。ffmpeg 缺失 → false(调用方 skip)。
@discardableResult
func makeVideo(at url: URL, codec: String = "h264", size: String = "320x180",
               fps: Int = 25, seconds: Int = 2, pixFmt: String = "yuv420p",
               extra: [String] = []) throws -> Bool {
    guard let ffmpeg = ffmpegBin() else { return false }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: ffmpeg)
    proc.arguments = ["-y", "-f", "lavfi",
                      "-i", "testsrc2=size=\(size):rate=\(fps):duration=\(seconds)",
                      "-c:v", codec, "-pix_fmt", pixFmt, "-an"] + extra + [url.path]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return false }
    return true
}
