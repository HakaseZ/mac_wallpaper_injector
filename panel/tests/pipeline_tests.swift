// code-review-marker
import AVFoundation

// MARK: - 转码→补丁→预置全链路测试(沙箱;ffmpeg 缺失时跳过)

func pipelineTests(_ r: TestRunner) throws {
    guard ffmpegBin() != nil else {
        r.skip("Pipeline 套件", "ffmpeg 缺失")
        return
    }
    let sandbox = try Sandbox()
    defer { sandbox.teardown() }

    let src = sandbox.root.appendingPathComponent("src.mov")
    guard try makeVideo(at: src, codec: "h264", size: "320x180", fps: 25, seconds: 2) else {
        r.skip("Pipeline 套件", "fixture 生成失败")
        return
    }

    // --- probeVideo:任意容器探测 ---
    let probe = try WallpaperService.probeVideo(input: src)
    r.check("probe hasVideo", probe.hasVideo)
    r.check("probe h264 非合规 HEVC", !probe.isCompliantHEVC)
    r.check("probe 整数帧率不归一", probe.fps == nil, "fps=\(String(describing: probe.fps))")
    r.check("probe 偶数分辨率", !probe.needsEvenScale)
    r.check("probe 非 HDR", !probe.isHDR)
    r.check("probe 时长 ≈2s", abs(probe.duration - 2) < 0.3, "duration=\(probe.duration)")

    // 29.97fps → fps 归一为 30
    let ntsc = sandbox.root.appendingPathComponent("ntsc.mov")
    if try makeVideo(at: ntsc, codec: "h264", size: "320x180", fps: 30000, seconds: 2,
                     extra: ["-r", "30000/1001"]) {
        let p2 = try WallpaperService.probeVideo(input: ntsc)
        r.check("probe 29.97→30 归一", p2.fps == 30, "fps=\(String(describing: p2.fps))")
    } else {
        r.skip("probe 29.97 归一", "fixture 生成失败")
    }

    // --- prepareFiles:全链路(转码→补丁→预置到沙箱)---
    let files = try WallpaperService.prepareFiles(videoURL: src, thumbnailURL: nil,
                                                  stage: { _ in }, progress: { _ in })
    r.check("assetID UUID 大写", files.assetID == files.assetID.uppercased())
    let dest = sandbox.paths.videosDir.appendingPathComponent("\(files.assetID).mov")
    r.check("预置视频存在", FileManager.default.fileExists(atPath: dest.path))
    let destSize = (try? Data(contentsOf: dest))?.count ?? 0
    r.check("预置视频非空", destSize > 1000, "size=\(destSize)")

    // 转码产物合规:ffprobe 验证规格
    let outProbe = try WallpaperService.probeVideo(input: dest)
    r.check("转码产物 isCompliantHEVC", outProbe.isCompliantHEVC,
            "tag/pixfmt/timebase 不符: \(dest.lastPathComponent)")
    r.equal("转码产物 codecOf=hvc1", MOVPatcher.codecOf(dest) ?? "", "hvc1")
    r.check("转码产物偶数分辨率", !outProbe.needsEvenScale)

    // 补丁后结构:stbl 含 sgpd/csgm
    let outData = try Data(contentsOf: dest)
    if let moov = MOVPatcher.parse(outData, 0, outData.count).first(where: { $0.type == "moov" }),
       let stbl = moov.find("trak")?.find("mdia")?.find("minf")?.find("stbl") {
        let types = stbl.children.map { $0.type }
        r.check("转码产物 stbl 含 sgpd", types.contains("sgpd"), "children=\(types)")
        r.check("转码产物 stbl 含 csgm", types.contains("csgm"))
    } else {
        r.check("转码产物 moov/stbl 可解析", false)
    }

    // AVFoundation 可读(播放链路可用性)
    let asset = AVURLAsset(url: dest)
    r.check("转码产物 AVFoundation 可读", !asset.tracks(withMediaType: .video).isEmpty)

    // 缩略图已生成到 thumbnails 目录
    let thumb = sandbox.paths.thumbnailsDir.appendingPathComponent("\(files.assetID).png")
    r.check("缩略图预置存在", FileManager.default.fileExists(atPath: thumb.path))

    // --- prepareFiles 幂等:转码后产物直接打补丁(跳过转码分支)---
    let files2 = try WallpaperService.prepareFiles(videoURL: dest, thumbnailURL: nil,
                                                   stage: { _ in }, progress: { _ in })
    r.check("合规 HEVC 再注入仍成功", !files2.assetID.isEmpty)
    let dest2 = sandbox.paths.videosDir.appendingPathComponent("\(files2.assetID).mov")
    let p3 = try WallpaperService.probeVideo(input: dest2)
    r.check("二次注入产物仍合规", p3.isCompliantHEVC)
}
