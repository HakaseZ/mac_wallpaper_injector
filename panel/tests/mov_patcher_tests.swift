// code-review-marker
import Foundation
import AVFoundation

// MARK: - MOVPatcher 测试

func movPatcherTests(_ r: TestRunner) throws {
    // 原子辅助:构造完整 size 的原子(不足部分补零)
    func atom(_ type: String, _ size: UInt32) -> Data {
        var d = MOVPatcher.be32(size) + type.data(using: .ascii)!
        d.append(Data(repeating: 0, count: Int(size) - 8))
        return d
    }

    // --- parse:扁平原子 ---
    var data = atom("ftyp", 16)
    data += atom("mdat", 32)
    let roots = MOVPatcher.parse(data, 0, data.count)
    r.equal("parse 根原子数", roots.count, 2)
    r.equal("parse 类型", roots.first?.type ?? "", "ftyp")
    r.equal("parse size", roots.first?.size ?? 0, 16)
    r.equal("parse offset", roots.first?.offset ?? -1, 0)

    // --- parse:嵌套容器(trak 必须位于 moov 内部,size 字段一致)---
    let trakAtom = atom("trak", 24)
    let nested = MOVPatcher.be32(UInt32(8 + trakAtom.count)) + "moov".data(using: .ascii)! + trakAtom
    let nroots = MOVPatcher.parse(nested, 0, nested.count)
    r.equal("parse 容器子节点", nroots.first?.children.count ?? 0, 1)
    r.equal("parse 子节点类型", nroots.first?.find("trak")?.type ?? "", "trak")

    // --- parse:64-bit size ---
    var big = Data()
    big += MOVPatcher.be32(1) + "mdat".data(using: .ascii)! + MOVPatcher.be32(0) + MOVPatcher.be32(48)
    big += Data(repeating: 0, count: 32)
    let broots = MOVPatcher.parse(big, 0, big.count)
    r.equal("parse 64 位 size", broots.first?.size ?? 0, 48)
    r.equal("parse 64 位 header", broots.first?.headerLen ?? 0, 16)

    // --- parse:截断/垃圾数据不崩溃 ---
    r.equal("parse 垃圾数据", MOVPatcher.parse(Data("garbage".utf8), 0, 7).count, 0)
    var trunc = atom("moov", 100)  // 声明 100,实际只提供 40
    trunc += atom("trak", 24)
    let troots = MOVPatcher.parse(Data(trunc.prefix(40)), 0, 40)
    r.equal("parse 越界截断", troots.count, 0)

    // --- u32/be32 往返 ---
    let v: UInt32 = 0xDEADBEEF
    r.equal("be32 字节序", MOVPatcher.u32(MOVPatcher.be32(v), 0), v)

    // --- buildTapt ---
    let tapt = MOVPatcher.buildTapt(w32: 1920, h32: 1080)
    r.equal("tapt size 字段", MOVPatcher.u32(tapt, 0), UInt32(tapt.count))
    r.equal("tapt type", String(data: tapt.subdata(in: 4..<8), encoding: .ascii) ?? "", "tapt")
    let taptAtoms = MOVPatcher.parse(tapt, 0, tapt.count)
    r.equal("tapt 子原子数", taptAtoms.first?.children.count ?? 0, 3)
    // clef 布局:[size][tag][reserved][w][h] → w 在原子头 +12,+16
    if let clef = taptAtoms.first?.find("clef") {
        r.equal("tapt clef 宽", MOVPatcher.u32(tapt, clef.offset + 12), 1920)
        r.equal("tapt clef 高", MOVPatcher.u32(tapt, clef.offset + 16), 1080)
    } else {
        r.check("tapt clef 存在", false)
    }

    // --- buildSgpdTscl:5 个 tscl payload,version/flag 0x01000000 ---
    let tscl = MOVPatcher.buildSgpdTscl(baseDuration: 2400)
    r.equal("sgpd size 字段", MOVPatcher.u32(tscl, 0), UInt32(tscl.count))
    r.equal("sgpd type", String(data: tscl.subdata(in: 4..<8), encoding: .ascii) ?? "", "sgpd")
    r.equal("sgpd version+flags", MOVPatcher.u32(tscl, 8), 0x01000000)
    r.equal("sgpd entry type tscl", String(data: tscl.subdata(in: 12..<16), encoding: .ascii) ?? "", "tscl")
    r.equal("sgpd entry count", MOVPatcher.u32(tscl, 20), 5)

    // --- buildCsgm:gtype/版本/sampleCount-1/layers ---
    let csgm = MOVPatcher.buildCsgm(gtype: "tscl", payload: Data([0x12, 0x30]), sampleCount: 10, layers: 2)
    r.equal("csgm type", String(data: csgm.subdata(in: 4..<8), encoding: .ascii) ?? "", "csgm")
    r.equal("csgm gtype", String(data: csgm.subdata(in: 12..<16), encoding: .ascii) ?? "", "tscl")
    r.equal("csgm layers 字段", MOVPatcher.u32(csgm, 24), 2)
    r.equal("csgm sampleCount-1", MOVPatcher.u32(csgm, 40), 9)

    // --- buildCslg:maxOffset ---
    let cslg = MOVPatcher.buildCslg(maxOffset: 9000)
    r.equal("cslg type", String(data: cslg.subdata(in: 4..<8), encoding: .ascii) ?? "", "cslg")
    r.equal("cslg maxOffset 字段", MOVPatcher.u32(cslg, 20), 9000)

    // --- generateCsgmPayload ---
    r.equal("csgm payload 空", MOVPatcher.generateCsgmPayload([]).count, 0)
    // [0,0,0,0] → base 全 0,interval 1,pattern [0] → nibble 0x10
    r.equal("csgm payload 全零", MOVPatcher.generateCsgmPayload([0, 0, 0, 0]).map { $0 }, [0x10])
    // [0,1,0,1] → pattern [0,1] → 0x12
    r.equal("csgm payload 周期", MOVPatcher.generateCsgmPayload([0, 1, 0, 1]).map { $0 }, [0x12])
    // [0,1,2,0,1,2] → pattern [0,1,2] → 0x12 0x30
    r.equal("csgm payload 三周期", MOVPatcher.generateCsgmPayload([0, 1, 2, 0, 1, 2]).map { $0 }, [0x12, 0x30])

    // --- extractTemporalIDs:合成 mdat(样本第 6 字节低 3 位 = tid+1)---
    func sample(_ tidPlus1: UInt8) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 6)
        b[5] = tidPlus1
        return b
    }
    var mdat = Data()
    mdat += sample(1) + sample(2) + sample(1)  // tids: 0,1,0
    let tids = MOVPatcher.extractTemporalIDs(mdat, stszSizes: [6, 6, 6],
                                             chunkOffsets: [0], stscEntries: [(1, 3)])
    r.equal("temporalIDs 提取", tids, [0, 1, 0])
    // 越界样本 → -1
    let short = MOVPatcher.extractTemporalIDs(Data([0x00]), stszSizes: [6], chunkOffsets: [0], stscEntries: [(1, 1)])
    r.equal("temporalIDs 越界", short, [-1])

    // --- codecOf:垃圾/无 moov → nil ---
    r.check("codecOf 垃圾数据 nil", MOVPatcher.codecOf(writeTmp(Data("nonsense".utf8))) == nil)

    // --- patch:缺 ftyp/mdat/moov → 抛错 ---
    let bad = writeTmp(atom("ftyp", 16))
    r.throwsError("patch 缺 mdat 抛错") {
        try MOVPatcher.patch(inputURL: bad, outputURL: tmpURL())
    }

    // --- 集成:真实小视频补丁(fixture,ffmpeg 缺失则跳过)---
    let fixture = tmpURL()
    guard try makeVideo(at: fixture, codec: "h264", size: "320x180", fps: 25, seconds: 2) else {
        r.skip("补丁集成(真实视频)", "ffmpeg 缺失")
        return
    }
    r.equal("fixture codecOf h264=avc1", MOVPatcher.codecOf(fixture) ?? "", "avc1")
    let patched = tmpURL()
    if r.noThrow("patch 执行", { try MOVPatcher.patch(inputURL: fixture, outputURL: patched) }) != nil {
        let out = try Data(contentsOf: patched)
        let pr = MOVPatcher.parse(out, 0, out.count)
        let types = pr.map { $0.type }
        r.equal("补丁输出根原子顺序", types, ["ftyp", "wide", "mdat", "moov"])
        if let moov = pr.first(where: { $0.type == "moov" }),
           let stbl = moov.find("trak")?.find("mdia")?.find("minf")?.find("stbl") {
            let childTypes = stbl.children.map { $0.type }
            // h264 非 HEVC:不插 sgpd/csgm(专用 HEVC 时间分层);仅插 cslg(ctts 存在时)
            r.check("h264 不插 sgpd", !childTypes.contains("sgpd"), "children=\(childTypes)")
            r.check("h264 插 cslg", childTypes.contains("cslg"), "children=\(childTypes)")
            r.check("cslg 紧邻 stco 前",
                    (childTypes.firstIndex(of: "cslg") ?? 0) + 1 == (childTypes.firstIndex(of: "stco") ?? 0),
                    "children=\(childTypes)")
            // stco 偏移必须落在 mdat 内容区内
            if let stco = stbl.find("stco") {
                let mdat = pr.first(where: { $0.type == "mdat" })!
                let count = Int(MOVPatcher.u32(out, stco.offset + 12))
                var allInRange = true
                var first = 0
                for i in 0..<count {
                    let off = Int(MOVPatcher.u32(out, stco.offset + 16 + 4 * i))
                    if i == 0 { first = off }
                    if off < mdat.offset + 8 || off >= mdat.end { allInRange = false }
                }
                r.check("stco 偏移落在 mdat 内", allInRange, "first=\(first), mdat=\(mdat.offset + 8)...\(mdat.end)")
            } else {
                r.check("stbl 含 stco", false)
            }
        } else {
            r.check("moov/stbl 可解析", false)
        }
        // AVFoundation 可读(打不开 bug 回归)
        let asset = AVURLAsset(url: patched)
        r.check("补丁后 AVFoundation 可读", !asset.tracks(withMediaType: .video).isEmpty)
    }

    // --- codecOf fMP4 → nil(碎片化容器)---
    let fmp4 = tmpURL()
    if try makeVideo(at: fmp4, codec: "h264", extra: ["-movflags", "+frag_keyframe+empty_moov"]) {
        r.check("codecOf fMP4 nil", MOVPatcher.codecOf(fmp4) == nil)
    } else {
        r.skip("codecOf fMP4", "ffmpeg 缺失")
    }
}

// MARK: - 辅助

private func writeTmp(_ d: Data) -> URL {
    let u = tmpURL()
    try? d.write(to: u)
    return u
}

private func tmpURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("mwi-test-\(UUID().uuidString).mov")
}
