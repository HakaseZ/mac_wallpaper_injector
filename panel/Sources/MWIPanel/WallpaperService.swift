import Foundation
import Network
import AVFoundation
import AppKit

// MARK: - 本地 HTTP 静态服务(NWListener,127.0.0.1:port,目录 /tmp/mwi_http)

final class HTTPServer {
    private var listener: NWListener?
    private let directory: URL
    private let port: UInt16

    init(port: UInt16, directory: URL) {
        self.port = port
        self.directory = directory
    }

    var isRunning: Bool { listener != nil }

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else {
                conn.cancel(); return
            }
            // 只处理第一个请求行 GET /path
            let head = req.components(separatedBy: "\r\n").first ?? ""
            let parts = head.components(separatedBy: " ")
            guard parts.count >= 2, parts[0] == "GET" else {
                self.respond(conn, status: 400, body: Data("Bad Request".utf8))
                return
            }
            var path = parts[1]
            if path.hasPrefix("/") { path.removeFirst() }
            // 去查询串
            if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
            let percentDecoded = path.removingPercentEncoding ?? path
            let file = self.directory.appendingPathComponent(percentDecoded)
            // 防目录穿越
            let resolved = file.standardizedFileURL.path
            let base = self.directory.standardizedFileURL.path
            guard resolved.hasPrefix(base), FileManager.default.fileExists(atPath: resolved),
                  let body = try? Data(contentsOf: URL(fileURLWithPath: resolved)) else {
                self.respond(conn, status: 404, body: Data("Not Found".utf8))
                return
            }
            self.respond(conn, status: 200, body: body, contentType: "video/quicktime")
        }
    }

    private func respond(_ conn: NWConnection, status: Int, body: Data, contentType: String = "application/octet-stream") {
        let statusText = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request")
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - 壁纸服务(原生实现 inject.py 功能)

actor WallpaperService {
    static let shared = WallpaperService()
    private var httpServer: HTTPServer?

    // MARK: list / status

    func list() -> [InjectedAsset] {
        AerialManifest.list().0
    }

    func choice() -> [String: String] {
        AerialManifest.list().1
    }

    func status() -> StatusInfo {
        let st = JSONFile.loadDict(Paths.state)
        let aid = (st["asset_id"] as? String) ?? ""
        let logOut = runLogShow(lastSeconds: 90)
        let downloaded = !aid.isEmpty && FileManager.default.fileExists(
            atPath: Paths.videosDir.appendingPathComponent("\(aid).mov").path)
        let startReading = logOut.contains("startReading callback: success")
        let looping = logOut.components(separatedBy: "startReading callback: success").count - 1 >= 2
        let snapshot = logOut.contains("Snapshot succeeded")
        return StatusInfo(assetID: aid,
                          name: (st["name"] as? String) ?? "",
                          downloaded: downloaded,
                          startReading: startReading,
                          looping: looping,
                          snapshot: snapshot,
                          playing: downloaded && (snapshot || looping))
    }

    private func runLogShow(lastSeconds: Int) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = ["show", "--last", "\(lastSeconds)s", "--style", "compact",
                          "--predicate", "process == \"WallpaperAerialsExtension\""]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try? proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: refresh

    @discardableResult
    func refresh() throws -> String {
        var log = ""
        let fm = FileManager.default
        for name in ["extension-com.apple.wallpaper.extension.aerials-desktop",
                     "extension-com.apple.wallpaper.extension.aerials-screenSaver"] {
            let p = Paths.cacheDir.appendingPathComponent(name)
            if fm.fileExists(atPath: p.path) {
                try? fm.removeItem(at: p)
                log += "cache cleared: \(name)\n"
            }
        }
        killAgent()
        sleep(5)
        openWallpaperPanel()
        log += "agent restarted, wallpaper panel opened\n"
        return log
    }

    private func killAgent() {
        for name in ["WallpaperAgent", "WallpaperAerialsExtension"] {
            runBinary("/usr/bin/killall", args: [name])
        }
    }

    private func openWallpaperPanel() {
        runBinary("/usr/bin/open", args: ["x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"])
    }

    private func runBinary(_ path: String, args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        try? proc.run()
        proc.waitUntilExit()
    }

    // MARK: select

    @discardableResult
    func select(id: String) throws -> String {
        guard let name = AerialManifest.assetName(id: id) else {
            throw ServiceError.msg("asset \(id.prefix(8)) not found in entries.json")
        }
        let clicked = AXSelection.clickAsset(named: name)
        guard clicked else {
            throw ServiceError.msg("asset '\(name)' not found in panel (check entries.json + refresh)")
        }
        return "selecting '\(name)' in wallpaper panel... CLICKED\n"
    }

    // MARK: prepare

    @discardableResult
    func prepare(videoURL: URL, name: String, thumbnailURL: URL?, newCategory: String?) throws -> String {
        let port = Paths.defaultPort
        let assetID = UUID().uuidString.uppercased()
        let fm = FileManager.default

        // 1. 打补丁(未打则输出 _patched.mov)
        var video = videoURL
        if !video.lastPathComponent.contains("_patched") {
            let patched = video.deletingLastPathComponent()
                .appendingPathComponent(video.deletingPathExtension().lastPathComponent + "_patched.mov")
            try MOVPatcher.patch(inputURL: video, outputURL: patched)
            video = patched
        }

        // 2. 缩略图(缺省 AVFoundation 抽帧)
        var thumb = thumbnailURL
        if thumb == nil {
            let cand = video.deletingPathExtension().appendingPathExtension("png")
            if fm.fileExists(atPath: cand.path) {
                thumb = cand
            } else {
                thumb = try ThumbnailExtractor.extractFrame(from: video)
            }
        }
        guard let thumb else { throw ServiceError.msg("no thumbnail available") }

        // 3. 复制到 http 目录
        try fm.createDirectory(at: Paths.httpDir, withIntermediateDirectories: true)
        let videoName = video.lastPathComponent
        let thumbName = thumb.lastPathComponent
        try? fm.removeItem(at: Paths.httpDir.appendingPathComponent(videoName))
        try? fm.removeItem(at: Paths.httpDir.appendingPathComponent(thumbName))
        try fm.copyItem(at: video, to: Paths.httpDir.appendingPathComponent(videoName))
        try fm.copyItem(at: thumb, to: Paths.httpDir.appendingPathComponent(thumbName))

        // 4. entries 注入
        let log = try AerialManifest.inject(videoName: videoName, thumbName: thumbName, port: port,
                                            name: name, assetID: assetID, newCategory: newCategory)

        // 5. http 服务
        try startHTTPServer(port: UInt16(port))
        return log + "http server on :\(port)\n"
    }

    private func startHTTPServer(port: UInt16) throws {
        if let s = httpServer, s.isRunning { return }
        let s = HTTPServer(port: port, directory: Paths.httpDir)
        try s.start()
        httpServer = s
    }

    // MARK: restore

    @discardableResult
    func restore() throws -> String {
        var log = ""
        let fm = FileManager.default
        // entries 恢复(backup/inject 或 exp009 baseline)
        let backup = Paths.exp009Baseline.deletingLastPathComponent().appendingPathComponent("inject/entries.json")
        let baseline = Paths.exp009Baseline.appendingPathComponent("entries.json.baseline")
        func replace(_ src: URL, _ dst: URL) throws {
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
        if fm.fileExists(atPath: backup.path) {
            try replace(backup, Paths.entries)
            log += "entries.json restored\n"
        } else if fm.fileExists(atPath: baseline.path) {
            try replace(baseline, Paths.entries)
            log += "entries.json restored (exp009 baseline)\n"
        }
        // Index 恢复(exp009 baseline = 用户壁纸 image)
        let idxBase = Paths.exp009Baseline.appendingPathComponent("Index.plist.baseline")
        if fm.fileExists(atPath: idxBase.path) {
            try replace(idxBase, Paths.index)
            log += "Index.plist restored (用户壁纸)\n"
        }
        // 注入资产视频 + 缩略图
        let st = JSONFile.loadDict(Paths.state)
        if let aid = st["asset_id"] as? String, !aid.isEmpty {
            for dir in [Paths.videosDir, Paths.thumbnailsDir] {
                let f = dir.appendingPathComponent("\(aid).mov")
                let p = dir.appendingPathComponent("\(aid).png")
                if fm.fileExists(atPath: f.path) { try? fm.removeItem(at: f); log += "removed \(f.lastPathComponent)\n" }
                if fm.fileExists(atPath: p.path) { try? fm.removeItem(at: p); log += "removed \(p.lastPathComponent)\n" }
            }
        }
        // http 服务停止
        httpServer?.stop()
        httpServer = nil
        log += "http server stopped\n"
        killAgent()
        sleep(5)
        try? fm.removeItem(at: Paths.state)
        log += "baseline restored\n"
        return log
    }
}

// MARK: - 缩略图抽帧(AVFoundation)

enum ThumbnailExtractor {
    static func extractFrame(from videoURL: URL) throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        let cg = try gen.copyCGImage(at: time, actualTime: nil)
        let out = Paths.httpDir.appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent + ".png")
        try FileManager.default.createDirectory(at: Paths.httpDir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ServiceError.msg("thumbnail encode failed")
        }
        try data.write(to: out)
        return out
    }
}
