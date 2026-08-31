#!/usr/bin/env python3
"""MWI 注入工具 — 任意视频 → macOS Aerial 原生壁纸(白名单攻破版,实验 008)。

链路(全部已验证):
  打补丁(可选转码) → entries.json 注入(字段克隆) → 破宿主缓存+重启 → 面板点击 → 前台下载 → aerials 原生播放

子命令:
  prepare  <video> [--name N] [--thumbnail P] [--category UUID] [--id UUID]
           [--transcode] [--port 8181] [--no-patch] [--http-dir DIR]
  refresh                    删宿主缓存 + 重启 agent + 打开壁纸面板
  select   [--name N]        AX 定位资产按钮并合成点击(默认用 prepare 的名字)
  status                     检查播放日志(startReading/snapshot/selected)
  restore                    恢复基线(entries.json/Index.plist/停 http/重启)

示例:
  python3 scripts/inject.py prepare ~/videos/clip.mov --name "My Clip" --transcode
  python3 scripts/inject.py refresh
  python3 scripts/inject.py select
  python3 scripts/inject.py status
  python3 scripts/inject.py restore
"""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parent.parent
FALLBACK = Path(
    "/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex"
    "/Contents/Resources/entries.json"
)
ENTRIES = Path.home() / "Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json"
INDEX = Path.home() / "Library/Application Support/com.apple.wallpaper/Store/Index.plist"
CACHE_DIR = Path(
    "/var/folders/pc/8127vy3j6wsgyhvmr8pcjc680000gn/C/com.apple.wallpaper.agent/"
    "com.apple.wallpaper.view-model-cache"
)
BACKUP_DIR = ROOT / "backup/inject"
STATE = Path("/tmp/mwi_inject_state.json")
HTTP_DIR = Path("/tmp/mwi_http")


TEMPLATE_ASSET_ID = "6511D2B5-E185-4886-9505-B4004E920D27"  # Landscape/Golden Gate,字段齐全


def log(msg: str) -> None:
    print(f"[inject] {msg}", flush=True)


def load_plist(p: Path):
    with open(p, "rb") as f:
        return plistlib.load(f)


def save_plist(p: Path, d) -> None:
    with open(p, "wb") as f:
        plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)


def load_json(p: Path):
    with open(p) as f:
        return json.load(f)


def save_json(p: Path, d) -> None:
    with open(p, "w") as f:
        json.dump(d, f, indent=1)


def asset_template() -> dict:
    """从 fallback 取字段齐全的资产做模板(克隆字段,白名单攻破关键)。"""
    d = load_json(FALLBACK)
    for a in d["assets"]:
        if a["id"] == TEMPLATE_ASSET_ID:
            return dict(a)
    sys.exit(f"template asset {TEMPLATE_ASSET_ID} not in fallback")


def run(cmd: list, check=True) -> subprocess.CompletedProcess:
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        print(r.stderr[-2000:])
        sys.exit(f"command failed: {' '.join(cmd[:4])}...")
    return r

def _frac(v) -> Optional[float]:
    """'30000/1001' → 29.97;解析失败返回 None"""
    if not isinstance(v, str):
        return None
    parts = v.split("/")
    if len(parts) != 2:
        return None
    try:
        n, d = float(parts[0]), float(parts[1])
    except ValueError:
        return None
    return n / d if d > 0 else None


def probe_video(p: Path) -> dict:
    """ffprobe 探测视频轨:帧率/色彩传输/分辨率奇偶/时长。任意容器。"""
    r = run(["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries",
             "stream=r_frame_rate,avg_frame_rate,color_transfer,width,height:format=duration",
             "-of", "json", str(p)], check=False)
    if r.returncode != 0 or not r.stdout.strip():
        return {}
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return {}


def transcode_args(video: Path) -> list:
    """全种类输入兼容的合规 HEVC 转码参数(与 panel 的 WallpaperService 一致):
    帧率整数归一(29.97→30) / HDR(PQ/HLG) tonemap 到 BT.709 SDR /
    奇数分辨率偶数化(yuv420p10le 要求) / BT.709 色标签走 setparams(ffmpeg 9 输出级 -color_* 不可靠)。"""
    probe = probe_video(video)
    stream = (probe.get("streams") or [{}])[0]
    r, a = _frac(stream.get("r_frame_rate")), _frac(stream.get("avg_frame_rate"))
    vf = []
    if r is not None and a is not None and abs(r - a) < 0.001:
        # CFR:非整数才归一(29.97→30);25/30/60 等整数不动
        if abs(r - round(r)) > 0.001:
            vf.append(f"fps=fps={round(r):g}")
    elif a is not None:
        # VFR → 按平均帧率 CFR 化(补丁器依赖 stts 单 baseDuration)
        vf.append(f"fps=fps={max(1, round(a)):g}")
    transfer = stream.get("color_transfer") or ""
    if transfer in ("smpte2084", "arib-std-b67"):
        vf.append("tonemap=hable")
    w, h = stream.get("width") or 0, stream.get("height") or 0
    if (w and w % 2 == 1) or (h and h % 2 == 1):
        vf.append("scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=lanczos")
    vf.append("format=yuv420p10le,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709")
    return ["-vf", ",".join(vf),
            "-c:v", "libx265", "-preset", "medium", "-crf", "18",
            "-x265-params",
            "keyint=60:min-keyint=60:scenecut=0:bframes=4:b-adapt=2:b-pyramid=1:temporal-layers=3",
            "-tag:v", "hvc1",
            "-video_track_timescale", "240000", "-an",
            "-movflags", "+faststart"]


def cmd_prepare(args) -> None:
    video = Path(args.video).resolve()
    if not video.exists():
        sys.exit(f"video not found: {video}")

    name = args.name or video.stem
    asset_id = args.id or str(uuid.uuid4()).upper()
    port = args.port
    new_cat_id = None
    if args.new_category:
        fb = load_json(FALLBACK)
        landscape = next(c for c in fb["categories"] if c["id"] == "A33A55D9-EDEA-4596-A850-6C10B54FBBB5")
        new_cat = dict(landscape)
        new_cat["id"] = str(uuid.uuid4()).upper()
        new_cat["localizedNameKey"] = args.new_category
        # 全新子分类(克隆 Golden Gate 结构)→ 分类完全独立,资产只归本分类
        sg = next(s for s in landscape["subcategories"] if s["id"] == "67512508-D33E-4CBC-8A9E-BE55CEE35C4C")
        new_sg = dict(sg)
        new_sg["id"] = str(uuid.uuid4()).upper()
        new_sg["localizedNameKey"] = f"{args.new_category} 子分类"
        new_sg["preferredOrder"] = 99
        new_cat["subcategories"] = [new_sg]
        new_cat_id = new_cat["id"]
        new_sg_id = new_sg["id"]
        log(f"new category: {args.new_category} = {new_cat_id}(独立,全新子分类 {new_sg_id})")
        cat = new_cat_id

    # 1. 可选转码(合规 HEVC 10bit/240000/temporal-layers=3)
    if args.transcode:
        out = video.with_name(f"{video.stem}_mwi.mov")
        log(f"transcoding -> {out}")
        run(["ffmpeg", "-y", "-i", str(video), *transcode_args(video), str(out)])
        video = out
        if not args.thumbnail:
            thumb = video.with_suffix(".png")
            run(["ffmpeg", "-y", "-i", str(video), "-frames:v", "1", str(thumb)])
            args.thumbnail = str(thumb)

    # 2. 打补丁(若未打)
    if not args.no_patch:
        if "_patched" not in video.name:
            patched = video.with_name(f"{video.stem}_patched.mov")
            log(f"patching -> {patched}")
            run(["python3", str(ROOT / "scripts/mov_patcher.py"), str(video), str(patched)])
            video = patched
        else:
            log(f"already patched: {video.name}")

    # 3. 缩略图(缺省抽帧)
    thumb = Path(args.thumbnail) if args.thumbnail else None
    if thumb is None:
        thumb = video.with_suffix(".png")
        if not thumb.exists():
            run(["ffmpeg", "-y", "-i", str(video), "-frames:v", "1", str(thumb)])
    if not thumb.exists():
        sys.exit("no thumbnail available (pass --thumbnail or --transcode)")

    # 4. http 服务目录
    HTTP_DIR.mkdir(parents=True, exist_ok=True)
    video_name = video.name
    thumb_name = thumb.name
    shutil.copy2(video, HTTP_DIR / video_name)
    shutil.copy2(thumb, HTTP_DIR / thumb_name)

    # 5. 生成资产条目(字段克隆)
    asset = asset_template()
    asset["id"] = asset_id
    asset["localizedNameKey"] = name
    asset["accessibilityLabel"] = name
    asset["previewImage"] = f"http://127.0.0.1:{port}/{thumb_name}"
    asset["categories"] = [cat]
    if new_cat_id:
        asset["subcategories"] = [new_sg_id]  # 全新子分类 → 资产只在新分类
    asset["url"] = f"http://127.0.0.1:{port}/{video_name}"  # 覆盖模板 sylvan URL → 下载本地视频
    asset["url-4K-SDR-240FPS"] = f"http://127.0.0.1:{port}/{video_name}"  # 扩展实际下载源(优先 url-4K,008 验证)

    # 6a. 备份原 entries.json(prepare 时)
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    if ENTRIES.exists() and not (BACKUP_DIR / "entries.json").exists():
        shutil.copy2(ENTRIES, BACKUP_DIR / "entries.json")
        log("entries.json backed up")

    # 6c. 注入用户 entries.json(=downloaded manifest;完整 fallback 结构 + 新资产)
    d = load_json(FALLBACK)
    d["assets"] = [a for a in d["assets"] if a["id"] != asset_id]
    d["assets"].append(asset)
    if new_cat_id:
        # 新分类条目(克隆 Landscape,7 字段必需)
        d["categories"] = [c for c in d["categories"] if c["id"] != new_cat_id]
        d["categories"].append(new_cat)
    save_json(ENTRIES, d)
    log(f"entries.json: {len(d['assets'])} assets (injected {name} = {asset_id})")

    # 7. 状态文件(select/status/restore 用)
    save_json(STATE, {
        "name": name, "asset_id": asset_id, "video": video_name,
        "thumb": thumb_name, "port": port,
    })
    # 8. 起本地 http 服务(视频+缩略图源)
    _start_http(port)
    log("done. next: inject.py refresh")


def _start_http(port: int) -> None:
    r = subprocess.run(["pgrep", "-f", f"http.server {port}"], capture_output=True, text=True)
    if r.stdout.strip():
        log(f"http server already on :{port}")
        return
    proc = subprocess.Popen(
        ["python3", "-m", "http.server", str(port), "--directory", str(HTTP_DIR)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1)
    import urllib.request
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=3)
        log(f"http server on :{port} (pid {proc.pid})")
    except Exception:
        sys.exit("http server failed to start")


def _kill_agent() -> None:
    subprocess.run(["killall", "WallpaperAgent", "WallpaperAerialsExtension", "System Settings"],
                   capture_output=True)
    time.sleep(3)
    subprocess.run(["killall", "WallpaperAgent"], capture_output=True)


def cmd_refresh(_args) -> None:
    for c in ("extension-com.apple.wallpaper.extension.aerials-desktop",
              "extension-com.apple.wallpaper.extension.aerials-screenSaver"):
        p = CACHE_DIR / c
        if p.exists():
            p.unlink()
            log(f"cache cleared: {c}")
    _kill_agent()
    time.sleep(5)
    subprocess.run(["open", "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"])
    log("agent restarted, wallpaper panel opened")


def cmd_select(args) -> None:
    st = load_json(STATE) if STATE.exists() else {}
    name = args.name or st.get("name")
    if not name and getattr(args, "id", None):
        d = load_json(ENTRIES) if ENTRIES.exists() else {}
        a = next((x for x in d.get("assets", []) if x["id"] == args.id), None)
        name = a.get("localizedNameKey") if a else None
    if not name:
        sys.exit("no asset name (run prepare first or pass --name/--id)")
    log(f"selecting '{name}' in wallpaper panel...")
    r = run(["swift", str(ROOT / "scripts/ax_select.swift"), name], check=False)
    print(r.stdout.strip())
    if "CLICKED" not in r.stdout:
        sys.exit(f"asset '{name}' not found in panel (check entries.json + refresh)")


def cmd_status(args) -> None:
    st = load_json(STATE) if STATE.exists() else {}
    aid = st.get("asset_id", "")
    r = subprocess.run(
        ["log", "show", "--last", "90s", "--style", "compact",
         "--predicate", 'process == "WallpaperAerialsExtension"'],
        capture_output=True, text=True)
    out = r.stdout
    downloaded = aid and (Path.home() / "Library/Application Support/com.apple.wallpaper/aerials/videos" / f"{aid}.mov").exists()
    checks = {
        "downloaded": downloaded,
        "startReading": "startReading callback: success" in out,
        "looping": out.count("startReading callback: success") >= 2,
        "snapshot": "Snapshot succeeded" in out,
    }
    if getattr(args, "json", False):
        import json as _json
        print(_json.dumps({
            "asset_id": aid,
            "name": st.get("name", ""),
            **checks,
            "playing": bool(checks["downloaded"] and (checks["snapshot"] or checks["looping"])),
        }))
        return
    for k, v in checks.items():
        print(f"  {k}: {'✅' if v else '❌'}")
    ok = checks["downloaded"] and (checks["snapshot"] or checks["looping"])
    print("PLAYING ✅" if ok else "NOT PLAYING ❌(check refresh/select)")


def cmd_list(args) -> None:
    """列出注入资产(url 指向本地 127.0.0.1 的 entries 资产)+ 当前 choice"""
    import json as _json
    d = load_json(ENTRIES) if ENTRIES.exists() else {}
    assets = d.get("assets", [])
    cats = {c["id"]: c.get("localizedNameKey", c["id"]) for c in d.get("categories", [])}
    injected = []
    for a in assets:
        url = a.get("url", "") or ""
        url4k = a.get("url-4K-SDR-240FPS", "") or ""
        if "127.0.0.1" in url or "127.0.0.1" in url4k:
            cat_names = [cats.get(c, c[:8]) for c in a.get("categories", [])]
            injected.append({
                "id": a["id"],
                "name": a.get("localizedNameKey", ""),
                "categories": cat_names,
                "subcategories": [s[:8] for s in a.get("subcategories", [])],
                "url": url or url4k,
                "downloaded": (Path.home() / "Library/Application Support/com.apple.wallpaper/aerials/videos" / f"{a['id']}.mov").exists(),
            })
    # 当前 choice
    choice = {}
    try:
        with open(INDEX, "rb") as f:
            idx = plistlib.load(f)
        ch = idx.get("AllSpacesAndDisplays", {}).get("Desktop", {}).get("Content", {}).get("Choices", [{}])[0]
        cfg = ch.get("Configuration", b"")
        choice = plistlib.loads(cfg) if cfg else {}
    except Exception:
        pass
    out = {"injected": injected, "choice": choice}
    if getattr(args, "json", False):
        print(_json.dumps(out))
        return
    if not injected:
        print("(no injected assets)")
    for a in injected:
        mark = "⬇" if a["downloaded"] else "·"
        print(f"  {mark} {a['name']}  [{','.join(a['categories'])}]  {a['id'][:8]}")
    print("choice:", choice)


def cmd_restore(_args) -> None:
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    # entries.json
    bak = BACKUP_DIR / "entries.json"
    if bak.exists():
        shutil.copy2(bak, ENTRIES)
        log("entries.json restored")
    # Index.plist(面板点击改过 choice;prepare 时已备份干净版)
    idx_bak = BACKUP_DIR / "Index.plist"
    if idx_bak.exists():
        shutil.copy2(idx_bak, INDEX)
        log("Index.plist restored")
    # 注入资产的视频 + 缩略图(污染 videos/ + thumbnails/)
    st = load_json(STATE) if STATE.exists() else {}
    aid = st.get("asset_id", "")
    if aid:
        vf = Path.home() / "Library/Application Support/com.apple.wallpaper/aerials/videos" / f"{aid}.mov"
        if vf.exists():
            vf.unlink()
            log(f"downloaded video removed: {vf.name}")
        tf = Path.home() / "Library/Application Support/com.apple.wallpaper/aerials/thumbnails" / f"{aid}.png"
        if tf.exists():
            tf.unlink()
            log(f"thumbnail removed: {tf.name}")
    # http server
    r = subprocess.run(["pgrep", "-f", "http.server"], capture_output=True, text=True)
    for pid in r.stdout.split():
        try:
            subprocess.run(["kill", pid.strip()], capture_output=True)
        except Exception:
            pass
    log("http server stopped")
    _kill_agent()
    time.sleep(5)
    if STATE.exists():
        STATE.unlink()
    log("baseline restored")


def main() -> None:
    ap = argparse.ArgumentParser(description="MWI injector (macOS Aerial wallpaper)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prepare", help="patch + inject into entries.json")
    p.add_argument("video")
    p.add_argument("--name")
    p.add_argument("--thumbnail")
    p.add_argument("--category", help="归入现有分类 UUID(默认 Landscape)")
    p.add_argument("--new-category", help="新建独立分类(克隆 Landscape 模板,资产归入)")
    p.add_argument("--id")
    p.add_argument("--transcode", action="store_true", help="ffmpeg to compliant HEVC 10bit")
    p.add_argument("--port", type=int, default=8181)
    p.add_argument("--no-patch", action="store_true")
    sub.add_parser("refresh", help="clear host cache + restart agent + open panel")
    p_sel = sub.add_parser("select")
    p_sel.add_argument("--name")
    p_sel.add_argument("--id")
    p_status = sub.add_parser("status", help="check playback logs")
    p_status.add_argument("--json", action="store_true")
    p_list = sub.add_parser("list", help="list injected assets")
    p_list.add_argument("--json", action="store_true")
    sub.add_parser("restore", help="restore baseline")
    args = ap.parse_args()
    globals()[f"cmd_{args.cmd}"](args)


if __name__ == "__main__":
    main()
