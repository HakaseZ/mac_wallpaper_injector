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
    /// 全局转码门:并发注入时转码排队(总 CPU 限速 ≈ 单转码限速,不随并发数线性叠加)
    private static let transcodeGate = DispatchSemaphore(value: 1)
    private var httpServer: HTTPServer?

    // MARK: list / status

    func list() -> [InjectedAsset] {
        AerialManifest.list().0
    }

    func choice() -> [String: String] {
        AerialManifest.list().1
    }

    func status() -> StatusInfo {
        // 无 STATE:从系统 choice 读当前资产
        let (_, choice) = AerialManifest.list()
        let aid = choice["assetID"] ?? ""
        var name = ""
        if !aid.isEmpty {
            name = AerialManifest.assetName(id: aid) ?? ""
        }
        let logOut = runLogShow(lastSeconds: 90)
        let downloaded = !aid.isEmpty && FileManager.default.fileExists(
            atPath: Paths.videosDir.appendingPathComponent("\(aid).mov").path)
        let startReading = logOut.contains("startReading callback: success")
        let looping = logOut.components(separatedBy: "startReading callback: success").count - 1 >= 2
        let snapshot = logOut.contains("Snapshot succeeded")
        return StatusInfo(assetID: aid,
                          name: name,
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
        // 确保壁纸面板打开(ax_select 需要 System Settings 进程)
        if !systemSettingsRunning() {
            openWallpaperPanel()
            sleep(6)
        }
        let clicked = AXSelection.clickAsset(named: name)
        guard clicked else {
            throw ServiceError.msg("asset '\(name)' not found in panel (check entries.json + refresh)")
        }
        return "selecting '\(name)' in wallpaper panel... CLICKED\n"
    }

    private func systemSettingsRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "pgrep -x 'System Settings'"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !out.isEmpty
    }

    // MARK: prepare

    // MARK: delete(删除注入资产)

    @discardableResult
    func delete(id: String) throws -> String {
        var log = ""
        let fm = FileManager.default
        // entries 移除资产
        var d = JSONFile.loadDict(Paths.entries)
        var assets = d["assets"] as? [[String: Any]] ?? []
        guard let idx = assets.firstIndex(where: { ($0["id"] as? String) == id }) else {
            throw ServiceError.msg("asset \(id.prefix(8)) not found in entries.json")
        }
        let asset = assets.remove(at: idx)
        let name = (asset["localizedNameKey"] as? String) ?? id.prefix(8).description
        d["assets"] = assets
        // 空分类清理(新分类无其他资产 → 移除)
        let catIDs = (asset["categories"] as? [String]) ?? []
        var cats = d["categories"] as? [[String: Any]] ?? []
        for cid in catIDs {
            let stillUsed = assets.contains { ((($0["categories"] as? [String]) ?? []).contains(cid)) }
            if !stillUsed {
                cats.removeAll { ($0["id"] as? String) == cid }
                log += "移除空分类 \(cid.prefix(8))\n"
            }
        }
        d["categories"] = cats
        try JSONFile.saveDict(d, to: Paths.entries)
        log += "entries.json: asset \(name) removed\n"
        // 删视频/缩略图
        for dir in [Paths.videosDir, Paths.thumbnailsDir] {
            for ext in ["mov", "png"] {
                let f = dir.appendingPathComponent("\(id).\(ext)")
                if fm.fileExists(atPath: f.path) {
                    try? fm.removeItem(at: f)
                    log += "removed \(f.lastPathComponent)\n"
                }
            }
        }
        // choice 指向它 → 恢复系统默认壁纸(非用户本地文件)
        let (_, choice) = AerialManifest.list()
        if choice["assetID"] == id {
            try setSystemDefaultWallpaper()
            log += "choice 恢复系统默认壁纸\n"
        }
        killAgent()
        return log + "deleted \(name)\(id.prefix(8))\n"
    }

    // MARK: prepare(异步,带进度)

    struct PreparedFiles {
        let assetID: String
        let video: URL
        let thumb: URL
    }

    enum PrepareEvent {
        case stage(String)     // 阶段文本(转码/补丁/注入)
        case progress(Double)  // 0-1
        case log(String)
        case done(String)      // 完成(含日志)
        case error(String)
    }

    /// 后台完整注入流程。
    /// 转码/补丁/预置在 detached 并行执行(各自限速,互不阻塞);entries 写入走 actor 串行(避免并发覆盖丢资产)
    func prepareStream(videoURL: URL, name: String, thumbnailURL: URL?, newCategory: String?) -> AsyncStream<PrepareEvent> {
        AsyncStream { continuation in
            Task {
                do {
                    let files = try await Task.detached(priority: .utility) {
                        try WallpaperService.prepareFiles(
                            videoURL: videoURL, thumbnailURL: thumbnailURL,
                            stage: { continuation.yield(.stage($0)) },
                            progress: { continuation.yield(.progress($0)) })
                    }.value
                    // 注入(actor 串行:并发 prepareStream 依次写 entries,不互相覆盖)
                    let log = try await self.injectPrepared(files: files, name: name, newCategory: newCategory)
                    continuation.yield(.done(log))
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                }
                continuation.finish()
            }
        }
    }

    /// entries 注入(actor 隔离 → 串行执行)
    private func injectPrepared(files: PreparedFiles, name: String, newCategory: String?) throws -> String {
        try AerialManifest.inject(assetID: files.assetID, name: name, newCategory: newCategory)
    }

    /// 同步版本(测试/内部用)
    @discardableResult
    func prepare(videoURL: URL, name: String, thumbnailURL: URL?, newCategory: String?) throws -> String {
        let files = try WallpaperService.prepareFiles(
            videoURL: videoURL, thumbnailURL: thumbnailURL, stage: { _ in }, progress: { _ in })
        return try injectPrepared(files: files, name: name, newCategory: newCategory)
    }

    /// 非隔离核心:转码(限速+进度)→ 补丁 → 预置 videos/thumbnails(不写 entries,并发安全)
    private static func prepareFiles(videoURL: URL, thumbnailURL: URL?,
                                     stage: @escaping @Sendable (String) -> Void,
                                     progress: @escaping @Sendable (Double) -> Void) throws -> PreparedFiles {
        let assetID = UUID().uuidString.uppercased()
        let fm = FileManager.default

        // 0. 编码检测:仅当 hvc1(经典 QuickTime,样本表齐备)且容器级合规才跳过转码;
        //    合规 = 10bit yuv420p10le + timescale 240000 + 整数帧率(规格硬条件)。
        //    其余全部转码 — hev1(tag 不合规)、avc1/VP9/AV1、非 QuickTime 容器、fMP4,
        //    以及 hvc1 但不合规(8bit/全范围/错误 timescale,如 yuvj420p@15360 → 引擎拒播)
        var video = videoURL
        let probe = (try? probeVideo(input: video)) ?? VideoProbe(
            hasVideo: true, fps: nil, isHDR: false, needsEvenScale: false, duration: 0, isCompliantHEVC: false)
        if let codec = MOVPatcher.codecOf(video), codec == "hvc1", probe.hasVideo, probe.isCompliantHEVC {
            stage("视频已是合规 HEVC(10bit/240000/整数帧率),跳过转码")
        } else {
            stage("转码 HEVC 中(后台限速,避免发热)...")
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_mwi.mov")
            transcodeGate.wait()  // 排队:同时最多一个转码 → 总 CPU 限速
            defer { transcodeGate.signal() }
            try runFFmpegTranscode(input: video, probe: probe, output: tmp, progress: progress)
            video = tmp
        }

        // 1. 打补丁(未打则输出 _patched.mov)
        stage("打补丁(mov atom)...")
        if !video.lastPathComponent.contains("_patched") {
            let patched = video.deletingLastPathComponent()
                .appendingPathComponent(video.deletingPathExtension().lastPathComponent + "_patched.mov")
            try MOVPatcher.patch(inputURL: video, outputURL: patched)
            video = patched
        }

        // 2. 预置视频 + 缩略图到 aerials 目录(file:// 下载源;不经网络/代理)
        try fm.createDirectory(at: Paths.videosDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: Paths.thumbnailsDir, withIntermediateDirectories: true)
        let destVideo = Paths.videosDir.appendingPathComponent("\(assetID).mov")
        try? fm.removeItem(at: destVideo)
        try fm.copyItem(at: video, to: destVideo)

        var thumbURL: URL
        if let thumb = thumbnailURL {
            thumbURL = thumb
        } else {
            let cand = video.deletingPathExtension().appendingPathExtension("png")
            if fm.fileExists(atPath: cand.path) {
                thumbURL = cand
            } else {
                do {
                    thumbURL = try ThumbnailExtractor.extractFrame(from: video)
                } catch {
                    // AVFoundation 打不开(异常/边缘 hvc1)→ ffmpeg 抽帧兜底
                    thumbURL = try Self.ffmpegFrameGrab(video)
                }
            }
        }
        let destThumb = Paths.thumbnailsDir.appendingPathComponent("\(assetID).png")
        try? fm.removeItem(at: destThumb)
        try fm.copyItem(at: thumbURL, to: destThumb)
        return PreparedFiles(assetID: assetID, video: video, thumb: destThumb)
    }

    /// 调 ffmpeg 转码为 aerials 合规 HEVC 10bit(非隔离,detached 可调用)。
    /// 全种类输入兼容:帧率整数归一、HDR(PQ/HLG)→BT.709 SDR tonemap、奇数分辨率偶数化、
    /// BT.709 色标签走 setparams(filter 链;ffmpeg 9 输出级 -color_* 选项不可靠,文档实测)。
    /// 性能限制:单线程 + nice 20 → CPU ~10%,风扇安静
    /// 进度:ffmpeg -progress pipe:1 输出 out_time_us,经 progress 回调(0-1,分母取 ffprobe 时长)
    private static func runFFmpegTranscode(input: URL, probe: VideoProbe, output: URL,
                                           progress: @escaping @Sendable (Double) -> Void) throws {
        guard let ffmpeg = Self.ffmpegPath() else {
            throw ServiceError.msg("ffmpeg 未安装(需转码 HEVC);brew install ffmpeg")
        }
        guard probe.hasVideo else {
            throw ServiceError.msg("未检测到视频轨: \(input.lastPathComponent)")
        }
        // filter 链:帧率整数归一(29.97→30)→ HDR tonemap → 奇数分辨率偶数化 → 10bit → BT.709 标签
        var vf: [String] = []
        if let fps = probe.fps { vf.append("fps=fps=\(fps)") }
        if probe.isHDR { vf.append("tonemap=hable") }
        if probe.needsEvenScale { vf.append("scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=lanczos") }
        vf.append("format=yuv420p10le,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709")
        let threads = 1
        let args = ["-y", "-i", input.path,
                    "-vf", vf.joined(separator: ","),
                    "-c:v", "libx265", "-preset", "medium", "-crf", "18",
                    "-x265-params",
                    "keyint=60:min-keyint=60:scenecut=0:bframes=4:b-adapt=2:b-pyramid=1:temporal-layers=3",
                    "-tag:v", "hvc1",
                    "-video_track_timescale", "240000", "-an",
                    "-movflags", "+faststart",
                    "-threads", "\(threads)",
                    "-progress", "pipe:1",
                    output.path]
        // nice 20 降低优先级,不抢前台
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        proc.arguments = ["-n", "20", ffmpeg] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()

        // 异步读进度输出(out_time_us)
        let fh = outPipe.fileHandleForReading
        var acc = Data()
        let d = probe.duration > 0 ? probe.duration : 1
        fh.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            acc.append(chunk)
            // 逐行解析
            var lines = String(decoding: acc, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > 1 {
                acc = Data((lines.removeLast() ?? "").utf8)
            }
            for line in lines {
                let kv = line.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "out_time_us", let us = Double(kv[1]), d > 0 {
                    progress(min(max(us / (d * 1_000_000), 0), 1))
                }
            }
        }
        proc.waitUntilExit()
        fh.readabilityHandler = nil
        guard proc.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ServiceError.msg("ffmpeg 转码失败(exit \(proc.terminationStatus)): \(err.split(separator: "\n").suffix(3).joined(separator: "\n"))")
        }
    }
    private static func ffmpegPath() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// ffmpeg 抽帧兜底(AVFoundation 打不开的输入)
    private static func ffmpegFrameGrab(_ video: URL) throws -> URL {
        guard let ffmpeg = Self.ffmpegPath() else {
            throw ServiceError.msg("缩略图生成失败(AVFoundation 不可读,且 ffmpeg 未安装)")
        }
        let out = Paths.httpDir.appendingPathComponent(video.deletingPathExtension().lastPathComponent + ".png")
        try FileManager.default.createDirectory(at: Paths.httpDir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = ["-y", "-i", video.path, "-frames:v", "1", "-vf", "scale=640:-2", out.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw ServiceError.msg("缩略图生成失败(ffmpeg exit \(proc.terminationStatus))")
        }
        return out
    }

    // MARK: ffprobe 探测(任意容器)

    private struct VideoProbe {
        let hasVideo: Bool
        let fps: Int?          // 需归一化的整数帧率(29.97→30);CFR 已为整数则 nil
        let isHDR: Bool        // PQ(smpte2084)/HLG(arib-std-b67)
        let needsEvenScale: Bool  // yuv420p10le 要求宽高均为偶数
        let duration: Double
        let isCompliantHEVC: Bool  // hvc1 + yuv420p10le + 1/240000 + 整数帧率 → 可直接打补丁
    }

    /// ffprobe 探测视频轨:帧率(CFR/VFR)、色彩传输、分辨率奇偶、时长、容器级合规。任意容器均可读。
    /// ffmpeg/ffprobe 缺失时降级为不探测(保持旧行为),仅 ffmpeg 安装异常时抛错。
    private static func probeVideo(input: URL) throws -> VideoProbe {
        guard let ffmpeg = Self.ffmpegPath() else {
            return VideoProbe(hasVideo: true, fps: nil, isHDR: false, needsEvenScale: false, duration: 0, isCompliantHEVC: false)
        }
        let ffprobe = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent()
            .appendingPathComponent("ffprobe").path
        guard FileManager.default.isExecutableFile(atPath: ffprobe) else {
            return VideoProbe(hasVideo: true, fps: nil, isHDR: false, needsEvenScale: false, duration: 0, isCompliantHEVC: false)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffprobe)
        proc.arguments = ["-v", "error", "-select_streams", "v:0",
                          "-show_entries", "stream=r_frame_rate,avg_frame_rate,color_transfer,width,height,pix_fmt,time_base,codec_tag_string:format=duration",
                          "-of", "json", input.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let streams = obj["streams"] as? [[String: Any]], let s = streams.first else {
            return VideoProbe(hasVideo: false, fps: nil, isHDR: false, needsEvenScale: false, duration: 0, isCompliantHEVC: false)
        }
        func frac(_ v: Any?) -> Double? {
            guard let str = v as? String else { return nil }
            let parts = str.split(separator: "/")
            guard parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0 else { return nil }
            return n / d
        }
        let r = frac(s["r_frame_rate"])
        let a = frac(s["avg_frame_rate"])
        var fps: Int?
        var cfrInteger = false
        if let r, let a, abs(r - a) < 0.001 {
            // CFR:非整数才归一(29.97→30,23.976→24);25/30/60 等整数不动
            if abs(r - r.rounded()) > 0.001 { fps = Int(r.rounded()) } else { cfrInteger = true }
        } else if let a {
            // VFR → 按平均帧率 CFR 化(补丁器依赖 stts 单 baseDuration)
            fps = max(1, Int(a.rounded()))
        }
        let transfer = (s["color_transfer"] as? String) ?? ""
        let isHDR = transfer == "smpte2084" || transfer == "arib-std-b67"
        let w = (s["width"] as? Int) ?? 0
        let h = (s["height"] as? Int) ?? 0
        let needsEvenScale = (w > 0 && w % 2 == 1) || (h > 0 && h % 2 == 1)
        let durStr = (obj["format"] as? [String: Any])?["duration"] as? String
        let duration = durStr.flatMap(Double.init) ?? 0
        let tag = (s["codec_tag_string"] as? String) ?? ""
        let pixFmt = (s["pix_fmt"] as? String) ?? ""
        let timeBase = (s["time_base"] as? String) ?? ""
        let isCompliantHEVC = tag == "hvc1" && pixFmt == "yuv420p10le" && timeBase == "1/240000" && cfrInteger
        return VideoProbe(hasVideo: true, fps: fps, isHDR: isHDR, needsEvenScale: needsEvenScale, duration: duration, isCompliantHEVC: isCompliantHEVC)
    }

    private func startHTTPServer(port: UInt16) throws {
        if let s = httpServer, s.isRunning { return }
        let s = HTTPServer(port: port, directory: Paths.httpDir)
        try s.start()
        httpServer = s
    }

    /// 恢复出厂默认动态壁纸(亮/暗切换):系统 Desktop Pictures 的 Valley 动态壁纸
    private func setSystemDefaultWallpaper() throws {
        var idx = PList.loadDict(Paths.index)
        let urlDict: [String: Any] = ["relative": "file:///System/Library/Desktop%20Pictures/Valley.madesktop"]
        let cfg: [String: Any] = ["type": "imageFile", "url": urlDict]
        var choice: [String: Any] = [:]
        choice["Provider"] = "com.apple.wallpaper.choice.image"
        choice["Configuration"] = try PropertyListSerialization.data(fromPropertyList: cfg, format: .xml, options: 0)
        // 结构:AllSpacesAndDisplays.Linked.Content.Choices(macOS 27 实际结构)
        if var all = idx["AllSpacesAndDisplays"] as? [String: Any],
           var linked = all["Linked"] as? [String: Any],
           var content = linked["Content"] as? [String: Any] {
            content["Choices"] = [choice]
            linked["Content"] = content
            all["Linked"] = linked
            idx["AllSpacesAndDisplays"] = all
            try PList.saveDict(idx, to: Paths.index)
        } else if var all = idx["AllSpacesAndDisplays"] as? [String: Any],
                  var desktop = all["Desktop"] as? [String: Any],
                  var content = desktop["Content"] as? [String: Any] {
            // 兼容旧结构
            content["Choices"] = [choice]
            desktop["Content"] = content
            all["Desktop"] = desktop
            idx["AllSpacesAndDisplays"] = all
            try PList.saveDict(idx, to: Paths.index)
        }
    }

    private func ensureHTTPServer() throws {
        if let s = httpServer, s.isRunning { return }
        try startHTTPServer(port: UInt16(Paths.defaultPort))
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
        // 恢复系统默认壁纸(不再引用用户本地图片)
        try setSystemDefaultWallpaper()
        log += "Index.plist -> 系统默认壁纸\n"
        // 注入资产视频 + 缩略图(从 entries 收集,无 STATE 依赖)
        let (injected, _) = AerialManifest.list()
        for a in injected {
            for dir in [Paths.videosDir, Paths.thumbnailsDir] {
                let f = dir.appendingPathComponent("\(a.id).mov")
                let p = dir.appendingPathComponent("\(a.id).png")
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
