#!/usr/bin/env python3
"""MOV atom patcher — 移植 livid QtParser(WallpaperInjector / QtAtomGenerator / QtNALUnitParser)。

为满足注入规格的 HEVC MOV 注入 Apple Aerial 所需的补丁 atom:
  tapt(clef/prof/enof) + sgpd(tscl/tsas) + csgm(tscl/tsas) + cslg(有 ctts 时)
就地修改 tkhd/vmhd/elst,stbl 子 atom 重排,输出 ftyp|wide|mdat|moov,stco 偏移 +delta。

用法: python3 scripts/mov_patcher.py <input.mov> <output.mov>
"""
import struct
import sys
from pathlib import Path

CONTAINERS = {
    b"moov", b"trak", b"mdia", b"minf", b"stbl", b"edts", b"udta",
    b"dinf", b"mvex", b"tapt", b"clip", b"dref", b"stsd", b"gmhd",
}
# stbl 强制子顺序(livid WallpaperInjector.swift:216)
STBL_ORDER = [b"stsd", b"sgpd", b"csgm", b"stts", b"ctts", b"cslg",
              b"stss", b"sdtp", b"stsc", b"stsz", b"stco", b"co64"]


class Atom:
    __slots__ = ("type", "offset", "size", "header_len", "children")

    def __init__(self, typ: bytes, offset: int, size: int, header_len: int):
        self.type = typ
        self.offset = offset
        self.size = size
        self.header_len = header_len
        self.children: list[Atom] = []

    @property
    def end(self) -> int:
        return self.offset + self.size

    def find(self, typ: bytes) -> "Atom | None":
        for c in self.children:
            if c.type == typ:
                return c
        return None

    def findall(self, typ: bytes) -> list["Atom"]:
        return [c for c in self.children if c.type == typ]


def parse(data: bytes, start: int, end: int) -> list[Atom]:
    atoms = []
    pos = start
    while pos + 8 <= end:
        size, typ = struct.unpack(">I4s", data[pos:pos + 8])
        header = 8
        if size == 1:
            size = struct.unpack(">Q", data[pos + 8:pos + 16])[0]
            header = 16
        elif size == 0:
            size = end - pos
        if size < header or pos + size > end:
            break
        a = Atom(typ, pos, size, header)
        if typ in CONTAINERS and size > header:
            a.children = parse(data, pos + header, pos + size)
        atoms.append(a)
        pos += size
    return atoms


def u32(data: bytes, off: int) -> int:
    return struct.unpack(">I", data[off:off + 4])[0]


# ---------- NAL 分析(移植 QtNALUnitParser.extractTemporalIDs) ----------

def extract_temporal_ids(data: bytes, stsz_sizes: list[int],
                         chunk_offsets: list[int],
                         stsc_entries: list[tuple[int, int]]) -> list[int]:
    """stsc 展开 chunk→sample,逐 sample 跳读 6 字节,temporal_id = b5 & 0x07 - 1。"""
    counts: list[int] = []
    for i, (first_chunk, samples_per_chunk) in enumerate(stsc_entries):
        end = stsc_entries[i + 1][0] if i + 1 < len(stsc_entries) else len(chunk_offsets) + 1
        counts.extend([samples_per_chunk] * max(0, end - first_chunk))
    counts = counts[:len(chunk_offsets)]

    tids: list[int] = []
    si = 0
    for i, co in enumerate(chunk_offsets):
        if i >= len(counts):
            break
        pos = co
        for _ in range(counts[i]):
            if si >= len(stsz_sizes):
                break
            sz = stsz_sizes[si]
            if pos + 6 <= len(data):
                tid_plus1 = data[pos + 5] & 0x07
                tids.append(tid_plus1 - 1 if tid_plus1 > 0 else -1)
            else:
                tids.append(-1)
            pos += sz
            si += 1
    return tids


def generate_csgm_payload(temporal_ids: list[int]) -> bytes:
    """模式检测 + nibble 打包(移植 generateCsgmPayload)。"""
    if not temporal_ids:
        return b""
    base = [i for i, t in enumerate(temporal_ids) if t == 0]
    pattern: list[int] = []
    if len(base) >= 2:
        interval = base[1] - base[0]
        if interval > 0 and base[0] + interval <= len(temporal_ids):
            cand = temporal_ids[base[0]:base[0] + interval]
            limit = min(len(temporal_ids), base[0] + interval * 5)
            consistent = True
            for i in range(base[0], limit, interval):
                chunk = temporal_ids[i:i + interval]
                if chunk != cand[:len(chunk)]:
                    consistent = False
                    break
            pattern = cand if consistent else temporal_ids
    if not pattern:
        pattern = temporal_ids

    out = bytearray()
    for i in range(0, len(pattern), 2):
        n1 = min(pattern[i] + 1, 15)
        n2 = min(pattern[i + 1] + 1, 15) if i + 1 < len(pattern) else 0
        out.append((n1 << 4) | n2)
    return bytes(out)


# ---------- 补丁 atom 生成(移植 QtAtomGenerator) ----------

def dim_atom(tag: bytes, w32: int, h32: int) -> bytes:
    return struct.pack(">I4sIII", 20, tag, 0, w32, h32)


def build_tapt(w32: int, h32: int) -> bytes:
    body = dim_atom(b"clef", w32, h32) + dim_atom(b"prof", w32, h32) + dim_atom(b"enof", w32, h32)
    return struct.pack(">I4s", 8 + len(body), b"tapt") + body


def build_sgpd_tscl(base_duration: int) -> bytes:
    payload = struct.pack(">IIIII", 0, base_duration, 1, 0, 128)
    body = struct.pack(">I4sI", 0x01000000, b"tscl", 20) + struct.pack(">I", 5) + payload * 5
    return struct.pack(">I4s", 8 + len(body), b"sgpd") + body


def build_sgpd_tsas() -> bytes:
    body = struct.pack(">I4sII", 0x01000000, b"tsas", 4, 1) + struct.pack(">I", 0)
    return struct.pack(">I4s", 8 + len(body), b"sgpd") + body


def build_csgm(gtype: bytes, payload: bytes, sample_count: int, layers: int) -> bytes:
    """layers = 时间分层数;Apple 原厂 csgm 第 3 字段即分层数(4207734D 为 3)。"""
    body = struct.pack(">I4s", 0, gtype)
    for v in (0, 4, layers, 1, 1, 16):
        body += struct.pack(">I", v)
    body += struct.pack(">I", max(0, sample_count - 1)) + payload
    return struct.pack(">I4s", 8 + len(body), b"csgm") + body


def build_cslg(max_offset: int) -> bytes:
    body = struct.pack(">I", 0)
    for v in (0, 0, max_offset, 0, 0):
        body += struct.pack(">I", v)
    return struct.pack(">I4s", 8 + len(body), b"cslg") + body


# ---------- 主流程 ----------

def patch(input_path: Path, output_path: Path) -> None:
    data = bytearray(Path(input_path).read_bytes())
    roots = parse(bytes(data), 0, len(data))

    ftyp = next((a for a in roots if a.type == b"ftyp"), None)
    mdat = next((a for a in roots if a.type == b"mdat"), None)
    moov = next((a for a in roots if a.type == b"moov"), None)
    if not (ftyp and mdat and moov):
        sys.exit("missing ftyp/mdat/moov")

    trak = moov.find(b"trak")
    mdia = trak.find(b"mdia") if trak else None
    minf = mdia.find(b"minf") if mdia else None
    stbl = minf.find(b"stbl") if minf else None
    if not stbl:
        sys.exit("missing trak/mdia/minf/stbl")
    stsz = stbl.find(b"stsz")
    stsc = stbl.find(b"stsc")
    stco = stbl.find(b"stco")
    co64 = stbl.find(b"co64")
    chunk_atom = stco or co64
    if not (stsz and stsc and chunk_atom):
        sys.exit("missing stsz/stsc/stco|co64")

    # ---- stsz ----
    sample_size = u32(data, stsz.offset + 12)
    sample_count = u32(data, stsz.offset + 16)
    if sample_size > 0:
        stsz_sizes = [sample_size] * sample_count
    else:
        stsz_sizes = [u32(data, stsz.offset + 20 + 4 * i) for i in range(sample_count)]

    # ---- stsc ----
    stsc_count = u32(data, stsc.offset + 12)
    stsc_entries = []
    for i in range(stsc_count):
        base = stsc.offset + 16 + 12 * i
        stsc_entries.append((u32(data, base), u32(data, base + 4)))

    # ---- stco/co64 ----
    off_count = u32(data, chunk_atom.offset + 12)
    elem = 8 if chunk_atom.type == b"co64" else 4
    chunk_offsets = [u32(data, chunk_atom.offset + 16 + elem * i) for i in range(off_count)]

    # ---- NAL 分析 ----
    tids = extract_temporal_ids(bytes(data), stsz_sizes, chunk_offsets, stsc_entries)
    if not tids or all(t < 0 for t in tids):
        print(f"WARN: no valid temporal ids ({len(tids)} samples); csgm 用全 0 层")
        tids = [0] * len(stsz_sizes)

    # ---- 就地修改(字节级 patch,避免重建非必要 atom) ----
    tkhd = trak.find(b"tkhd")
    if tkhd:
        # flags = 15(track enabled|in movie|in preview|size is aspect)
        data[tkhd.offset + 9:tkhd.offset + 12] = b"\x00\x00\x0f"
        tkhd_version = data[tkhd.offset + 8]
        w_off = tkhd.offset + (100 if tkhd_version == 1 else 88)
        h_off = tkhd.offset + (104 if tkhd_version == 1 else 92)
        w32 = u32(data, w_off)
        h32 = u32(data, h_off)
    else:
        w32 = h32 = 0

    vmhd = minf.find(b"vmhd")
    if vmhd:
        data[vmhd.offset + 12:vmhd.offset + 14] = struct.pack(">H", 64)      # graphics_mode
        data[vmhd.offset + 14:vmhd.offset + 20] = struct.pack(">HHH", 32768, 32768, 32768)

    edts = trak.find(b"edts")
    elst = edts.find(b"elst") if edts else None
    if elst:
        ver = data[elst.offset + 8]
        if ver == 1:
            data[elst.offset + 24:elst.offset + 32] = b"\x00" * 8  # media_time
        else:
            data[elst.offset + 20:elst.offset + 24] = b"\x00" * 4

    # ---- stts baseDuration / ctts maxOffset ----
    base_duration = 1000
    stts = stbl.find(b"stts")
    if stts and u32(data, stts.offset + 12) > 0:
        base_duration = u32(data, stts.offset + 20)

    max_offset = 0
    ctts = stbl.find(b"ctts")
    if ctts:
        ctts_count = u32(data, ctts.offset + 12)
        ctts_ver = data[ctts.offset + 8]
        for i in range(ctts_count):
            base = ctts.offset + 16 + 8 * i
            off = u32(data, base + 4)
            if ctts_ver == 1:
                off = struct.unpack(">i", struct.pack(">I", off))[0]
            if off > max_offset:
                max_offset = off

    # ---- 生成补丁 atom ----
    tapt = build_tapt(w32, h32)
    sgpd_tscl = build_sgpd_tscl(base_duration)
    sgpd_tsas = build_sgpd_tsas()
    payload = generate_csgm_payload(tids)
    layers = max((t for t in tids if t >= 0), default=0) + 1
    csgm_tscl = build_csgm(b"tscl", payload, len(tids), layers)
    csgm_tsas = build_csgm(b"tsas", payload, len(tids), layers)
    cslg = build_cslg(max_offset) if ctts else None

    # ---- stbl 重排(原字节拷贝 + 新 atom 插入) ----
    def atom_bytes(a: Atom) -> bytes:
        return bytes(data[a.offset:a.end])

    stbl_children = {a.type: atom_bytes(a) for a in stbl.children}
    new_stbl = b""
    for t in STBL_ORDER:
        if t == b"sgpd":
            new_stbl += sgpd_tscl + sgpd_tsas
        elif t == b"csgm":
            new_stbl += csgm_tscl + csgm_tsas
        elif t == b"cslg":
            if cslg:
                new_stbl += cslg
        elif t in stbl_children:
            new_stbl += stbl_children[t]

    # ---- 重组输出 ftyp|wide|mdat|moov ----
    ftyp_bytes = atom_bytes(ftyp)
    mdat_bytes = atom_bytes(mdat)
    new_mdat_content = len(ftyp_bytes) + 8 + 8
    orig_mdat_content = mdat.offset + 8
    delta = new_mdat_content - orig_mdat_content
    print(f"shift delta: {delta}")

    # stco/co64 +delta(重建 chunk offset 数组)
    def patch_offsets(atom: Atom, elem_size: int) -> bytes:
        count = u32(data, atom.offset + 12)
        fmt = ">Q" if elem_size == 8 else ">I"
        new_offsets = b"".join(
            struct.pack(fmt, u32(data, atom.offset + 16 + elem_size * i) + delta)
            for i in range(count)
        )
        return struct.pack(">I4sII", 16 + elem_size * count, atom.type, 0, count) + new_offsets

    new_stbl = new_stbl.replace(
        atom_bytes(stco) if stco else b"", patch_offsets(stco, 4) if stco else b"", 1
    ) if stco else new_stbl
    if co64:
        new_stbl = new_stbl.replace(atom_bytes(co64), patch_offsets(co64, 8), 1)

    # 重建 moov 子树(容器重算 size,叶子拷贝)
    def rebuild(a: Atom) -> bytes:
        if a.type == b"stbl":
            return struct.pack(">I4s", 8 + len(new_stbl), b"stbl") + new_stbl
        if a.children:
            body = b"".join(rebuild(c) for c in a.children)
            return struct.pack(">I4s", 8 + len(body), a.type) + body
        return atom_bytes(a)

    moov_bytes = rebuild(moov)
    out = ftyp_bytes + struct.pack(">I4s", 8, b"wide") + mdat_bytes + moov_bytes
    Path(output_path).write_bytes(out)
    print(f"patched: {input_path} -> {output_path} ({len(out)} bytes)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <input.mov> <output.mov>")
    patch(Path(sys.argv[1]), Path(sys.argv[2]))
