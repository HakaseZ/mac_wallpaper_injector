import Foundation

// MARK: - MOV atom patcher (移植 scripts/mov_patcher.py)

enum MOVPatcher {
    static let containers: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "edts", "udta",
        "dinf", "mvex", "tapt", "clip", "dref", "stsd", "gmhd",
    ]
    static let stblOrder: [String] = ["stsd", "sgpd", "csgm", "stts", "ctts", "cslg",
                                      "stss", "sdtp", "stsc", "stsz", "stco", "co64"]

    struct Atom {
        let type: String
        let offset: Int
        let size: Int
        let headerLen: Int
        let children: [Atom]
        var end: Int { offset + size }

        func find(_ t: String) -> Atom? {
            children.first { $0.type == t }
        }
    }

    static func u32(_ d: Data, _ off: Int) -> UInt32 {
        d.subdata(in: off..<(off + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    }

    static func parse(_ data: Data, _ start: Int, _ end: Int) -> [Atom] {
        var atoms: [Atom] = []
        var pos = start
        while pos + 8 <= end {
            let size32 = u32(data, pos)
            let typeData = data.subdata(in: (pos + 4)..<(pos + 8))
            guard let type = String(data: typeData, encoding: .ascii) else { break }
            var size = Int(size32)
            var header = 8
            if size32 == 1 {
                size = Int(data.subdata(in: (pos + 8)..<(pos + 16)).withUnsafeBytes {
                    $0.loadUnaligned(as: UInt64.self).bigEndian
                })
                header = 16
            } else if size32 == 0 {
                size = end - pos
            }
            if size < header || pos + size > end { break }
            var children: [Atom] = []
            if containers.contains(type) && size > header {
                children = parse(data, pos + header, pos + size)
            }
            atoms.append(Atom(type: type, offset: pos, size: size, headerLen: header, children: children))
            pos += size
        }
        return atoms
    }

    // MARK: NAL 分析

    static func extractTemporalIDs(_ data: Data, stszSizes: [Int], chunkOffsets: [Int],
                                   stscEntries: [(Int, Int)]) -> [Int] {
        var counts: [Int] = []
        for (i, entry) in stscEntries.enumerated() {
            let endChunk = i + 1 < stscEntries.count ? stscEntries[i + 1].0 : chunkOffsets.count + 1
            let n = max(0, endChunk - entry.0)
            counts.append(contentsOf: Array(repeating: entry.1, count: n))
        }
        if counts.count > chunkOffsets.count { counts = Array(counts.prefix(chunkOffsets.count)) }

        var tids: [Int] = []
        var si = 0
        for (i, co) in chunkOffsets.enumerated() {
            if i >= counts.count { break }
            var pos = co
            for _ in 0..<counts[i] {
                if si >= stszSizes.count { break }
                let sz = stszSizes[si]
                if pos + 6 <= data.count {
                    let b5 = data[pos + 5]
                    let tidPlus1 = Int(b5 & 0x07)
                    tids.append(tidPlus1 > 0 ? tidPlus1 - 1 : -1)
                } else {
                    tids.append(-1)
                }
                pos += sz
                si += 1
            }
        }
        return tids
    }

    static func generateCsgmPayload(_ temporalIDs: [Int]) -> Data {
        guard !temporalIDs.isEmpty else { return Data() }
        let base = temporalIDs.enumerated().compactMap { $0.element == 0 ? $0.offset : nil }
        var pattern: [Int] = []
        if base.count >= 2 {
            let interval = base[1] - base[0]
            if interval > 0 && base[0] + interval <= temporalIDs.count {
                let cand = Array(temporalIDs[base[0]..<(base[0] + interval)])
                let limit = min(temporalIDs.count, base[0] + interval * 5)
                var consistent = true
                var i = base[0]
                while i < limit {
                    let chunk = Array(temporalIDs[i..<min(i + interval, temporalIDs.count)])
                    if chunk != Array(cand.prefix(chunk.count)) { consistent = false; break }
                    i += interval
                }
                pattern = consistent ? cand : temporalIDs
            }
        }
        if pattern.isEmpty { pattern = temporalIDs }

        var out = Data()
        var i = 0
        while i < pattern.count {
            let n1 = min(pattern[i] + 1, 15)
            let n2 = i + 1 < pattern.count ? min(pattern[i + 1] + 1, 15) : 0
            out.append(UInt8((n1 << 4) | n2))
            i += 2
        }
        return out
    }

    // MARK: 补丁 atom 生成

    static func be32(_ v: UInt32) -> Data {
        var v = v.bigEndian
        return Data(bytes: &v, count: 4)
    }

    static func dimAtom(_ tag: String, w32: UInt32, h32: UInt32) -> Data {
        var d = be32(20)
        d += tag.data(using: .ascii)!
        d += be32(0) + be32(w32) + be32(h32)
        return d
    }

    static func buildTapt(w32: UInt32, h32: UInt32) -> Data {
        let body = dimAtom("clef", w32: w32, h32: h32)
            + dimAtom("prof", w32: w32, h32: h32)
            + dimAtom("enof", w32: w32, h32: h32)
        return be32(UInt32(8 + body.count)) + "tapt".data(using: .ascii)! + body
    }

    static func buildSgpdTscl(baseDuration: UInt32) -> Data {
        var payload = be32(0) + be32(baseDuration) + be32(1) + be32(0) + be32(128)
        var body = be32(0x01000000) + "tscl".data(using: .ascii)! + be32(20) + be32(5)
        for _ in 0..<5 { body += payload }
        return be32(UInt32(8 + body.count)) + "sgpd".data(using: .ascii)! + body
    }

    static func buildSgpdTsas() -> Data {
        var body = be32(0x01000000) + "tsas".data(using: .ascii)! + be32(4) + be32(1) + be32(0)
        return be32(UInt32(8 + body.count)) + "sgpd".data(using: .ascii)! + body
    }

    static func buildCsgm(gtype: String, payload: Data, sampleCount: Int, layers: Int) -> Data {
        var body = be32(0) + gtype.data(using: .ascii)!
        for v in [UInt32(0), 4, UInt32(layers), 1, 1, 16] { body += be32(v) }
        body += be32(UInt32(max(0, sampleCount - 1))) + be32(15) + be32(15) + payload
        return be32(UInt32(8 + body.count)) + "csgm".data(using: .ascii)! + body
    }

    static func buildCslg(maxOffset: UInt32) -> Data {
        var body = be32(0)
        for v in [UInt32(0), 0, maxOffset, 0, 0] { body += be32(v) }
        return be32(UInt32(8 + body.count)) + "cslg".data(using: .ascii)! + body
    }

    /// 读取视频轨编码 4cc(avc1/hvc1/...),供 prepare 判断是否需要转码
    static func codecOf(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let roots = parse(data, 0, data.count)
        guard let moov = roots.first(where: { $0.type == "moov" }),
              let trak = moov.find("trak"),
              let mdia = trak.find("mdia"),
              let minf = mdia.find("minf"),
              let stbl = minf.find("stbl"),
              let stsd = stbl.find("stsd"), stsd.size >= 20,
              // 经典 QuickTime 样本表齐备、且非碎片化(fMP4 带 mvex,样本在 moof)才算可直接打补丁;
              // fMP4 返回 nil → prepare 走转码
              moov.find("mvex") == nil,
              stbl.find("stsz") != nil, stbl.find("stsc") != nil,
              (stbl.find("stco") ?? stbl.find("co64")) != nil else { return nil }
        return String(data: data.subdata(in: (stsd.offset + 20)..<(stsd.offset + 24)), encoding: .ascii)
    }

    // MARK: 主流程

    struct PatchError: LocalizedError {
        let msg: String
        var errorDescription: String? { msg }
    }

    static func patch(inputURL: URL, outputURL: URL) throws {
        var data = try Data(contentsOf: inputURL)
        let roots = parse(data, 0, data.count)

        guard let ftyp = roots.first(where: { $0.type == "ftyp" }),
              let mdat = roots.first(where: { $0.type == "mdat" }),
              let moov = roots.first(where: { $0.type == "moov" }) else {
            throw PatchError(msg: "missing ftyp/mdat/moov")
        }
        guard let trak = moov.find("trak"),
              let mdia = trak.find("mdia"),
              let minf = mdia.find("minf"),
              let stbl = minf.find("stbl") else {
            throw PatchError(msg: "missing trak/mdia/minf/stbl")
        }
        guard let stsz = stbl.find("stsz"),
              let stsc = stbl.find("stsc"),
              let stco = stbl.find("stco") ?? stbl.find("co64") else {
            throw PatchError(msg: "missing stsz/stsc/stco|co64")
        }
        let chunkAtom = stbl.find("stco") ?? stbl.find("co64")!
        let isCo64 = chunkAtom.type == "co64"

        // stsz
        let sampleSize = u32(data, stsz.offset + 12)
        let sampleCount = Int(u32(data, stsz.offset + 16))
        var stszSizes: [Int] = []
        if sampleSize > 0 {
            stszSizes = Array(repeating: Int(sampleSize), count: sampleCount)
        } else {
            for i in 0..<sampleCount { stszSizes.append(Int(u32(data, stsz.offset + 20 + 4 * i))) }
        }

        // stsc
        let stscCount = Int(u32(data, stsc.offset + 12))
        var stscEntries: [(Int, Int)] = []
        for i in 0..<stscCount {
            let base = stsc.offset + 16 + 12 * i
            stscEntries.append((Int(u32(data, base)), Int(u32(data, base + 4))))
        }

        // stco/co64
        let offCount = Int(u32(data, chunkAtom.offset + 12))
        let elem = isCo64 ? 8 : 4
        var chunkOffsets: [Int] = []
        for i in 0..<offCount {
            if isCo64 {
                let v = data.subdata(in: (chunkAtom.offset + 16 + 8 * i)..<(chunkAtom.offset + 24 + 8 * i))
                    .withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
                chunkOffsets.append(Int(v))
            } else {
                chunkOffsets.append(Int(u32(data, chunkAtom.offset + 16 + 4 * i)))
            }
        }

        // NAL 分析
        var tids = extractTemporalIDs(data, stszSizes: stszSizes, chunkOffsets: chunkOffsets, stscEntries: stscEntries)
        if tids.isEmpty || tids.allSatisfy({ $0 < 0 }) {
            tids = Array(repeating: 0, count: stszSizes.count)
        }

        // tkhd
        var w32: UInt32 = 0, h32: UInt32 = 0
        if let tkhd = trak.find("tkhd") {
            data.replaceSubrange((tkhd.offset + 9)..<(tkhd.offset + 12), with: Data([0x00, 0x00, 0x0f]))
            let version = data[tkhd.offset + 8]
            let wOff = tkhd.offset + (version == 1 ? 100 : 88)
            let hOff = tkhd.offset + (version == 1 ? 104 : 92)
            w32 = u32(data, wOff)
            h32 = u32(data, hOff)
        }

        // vmhd
        if let vmhd = minf.find("vmhd") {
            data.replaceSubrange((vmhd.offset + 12)..<(vmhd.offset + 14), with: be32(64).dropFirst(2))
            var rgb = Data()
            for _ in 0..<3 { rgb += be32(32768).dropFirst(2) }
            data.replaceSubrange((vmhd.offset + 14)..<(vmhd.offset + 20), with: rgb)
        }

        // elst media_time
        if let edts = trak.find("edts"), let elst = edts.find("elst") {
            let ver = data[elst.offset + 8]
            if ver == 1 {
                data.replaceSubrange((elst.offset + 24)..<(elst.offset + 32), with: Data(repeating: 0, count: 8))
            } else {
                data.replaceSubrange((elst.offset + 20)..<(elst.offset + 24), with: Data(repeating: 0, count: 4))
            }
        }

        // stts baseDuration
        var baseDuration: UInt32 = 1000
        if let stts = stbl.find("stts"), u32(data, stts.offset + 12) > 0 {
            baseDuration = u32(data, stts.offset + 20)
        }

        // ctts maxOffset
        var maxOffset: UInt32 = 0
        let ctts = stbl.find("ctts")
        if let ctts {
            let cttsCount = Int(u32(data, ctts.offset + 12))
            let cttsVer = data[ctts.offset + 8]
            for i in 0..<cttsCount {
                let base = ctts.offset + 16 + 8 * i
                var off = u32(data, base + 4)
                if cttsVer == 1 {
                    off = UInt32(bitPattern: Int32(bitPattern: off))
                }
                if off > maxOffset { maxOffset = off }
            }
        }

        // 视频编码(stsd 首个 entry 4cc):csgm/sgpd 为 HEVC 时间分层专用,h264 等跳过
        var isHEVC = false
        if let stsd = stbl.find("stsd"), stsd.size >= 20 {
            let codec = data.subdata(in: (stsd.offset + 20)..<(stsd.offset + 24))
            let codecStr = String(data: codec, encoding: .ascii) ?? ""
            isHEVC = (codecStr == "hvc1" || codecStr == "hev1")
        }

        // 生成补丁 atom
        let tapt = buildTapt(w32: w32, h32: h32)
        let sgpdTscl = buildSgpdTscl(baseDuration: baseDuration)
        let sgpdTsas = buildSgpdTsas()
        let payload = generateCsgmPayload(tids)
        let layers = (tids.filter { $0 >= 0 }.max() ?? 0) + 1
        let csgmTscl = buildCsgm(gtype: "tscl", payload: payload, sampleCount: tids.count, layers: layers)
        let csgmTsas = buildCsgm(gtype: "tsas", payload: payload, sampleCount: tids.count, layers: layers)
        let cslg = ctts != nil ? buildCslg(maxOffset: maxOffset) : nil

        func atomBytes(_ a: Atom) -> Data {
            data.subdata(in: a.offset..<a.end)
        }

        // stbl 重排
        var stblChildren: [String: Data] = [:]
        for a in stbl.children { stblChildren[a.type] = atomBytes(a) }
        var newStbl = Data()
        for a in stbl.children {
            if a.type == "stsd" {
                newStbl += stblChildren["stsd"]!
                if isHEVC {
                    newStbl += sgpdTscl + sgpdTsas + csgmTscl + csgmTsas
                }
            } else if a.type == "stco" && cslg != nil {
                newStbl += cslg! + stblChildren["stco"]!
            } else if let c = stblChildren[a.type] {
                newStbl += c
            }
        }

        // stco/co64 + delta
        func patchOffsets(_ atom: Atom, elemSize: Int) -> Data {
            let count = Int(u32(data, atom.offset + 12))
            var newOffsets = Data()
            for i in 0..<count {
                var v = Int(u32(data, atom.offset + 16 + elemSize * i)) + delta
                if elemSize == 8 {
                    var v64 = UInt64(v).bigEndian
                    newOffsets += Data(bytes: &v64, count: 8)
                } else {
                    newOffsets += be32(UInt32(v))
                }
            }
            return be32(UInt32(16 + elemSize * count)) + atom.type.data(using: .ascii)! + be32(0) + be32(UInt32(count)) + newOffsets
        }

        // delta = 新 mdat 内容偏移 - 原 mdat 内容偏移
        let newMdatContent = ftyp.size + 8 + 8
        let origMdatContent = mdat.offset + 8
        let delta = newMdatContent - origMdatContent

        if let stco = stbl.find("stco") {
            let orig = atomBytes(stco)
            let patched = patchOffsets(stco, elemSize: 4)
            if let range = newStbl.range(of: orig) {
                newStbl.replaceSubrange(range, with: patched)
            }
        }
        if let co64 = stbl.find("co64") {
            let orig = atomBytes(co64)
            let patched = patchOffsets(co64, elemSize: 8)
            if let range = newStbl.range(of: orig) {
                newStbl.replaceSubrange(range, with: patched)
            }
        }

        // rebuild moov:仅补丁目标 stbl(视频轨)用重排后的 newStbl;
        // 其他轨(如音频)的 stbl 原样保留但 stco/co64 必须 +delta(全局 mdat 移位)
        let targetStblOffset = stbl.offset
        func rebuild(_ a: Atom) -> Data {
            if a.type == "stbl" {
                if a.offset == targetStblOffset {
                    return be32(UInt32(8 + newStbl.count)) + "stbl".data(using: .ascii)! + newStbl
                }
                var body = Data()
                for c in a.children {
                    if c.type == "stco" {
                        body += patchOffsets(c, elemSize: 4)
                    } else if c.type == "co64" {
                        body += patchOffsets(c, elemSize: 8)
                    } else {
                        body += atomBytes(c)
                    }
                }
                return be32(UInt32(8 + body.count)) + "stbl".data(using: .ascii)! + body
            }
            if !a.children.isEmpty {
                var body = Data()
                for c in a.children { body += rebuild(c) }
                return be32(UInt32(8 + body.count)) + a.type.data(using: .ascii)! + body
            }
            return atomBytes(a)
        }

        let moovBytes = rebuild(moov)
        var out = atomBytes(ftyp)
        out += be32(8) + "wide".data(using: .ascii)!
        out += atomBytes(mdat)
        out += moovBytes
        try out.write(to: outputURL)
    }
}
