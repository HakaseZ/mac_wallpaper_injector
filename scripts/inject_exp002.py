#!/usr/bin/env python3
"""实验 002:向 Index.plist 注入 aerials choice,assetID = 替换的本地系统资产。

用法:python3 scripts/inject_exp002.py [--restore]
  --restore: 从 backup/exp002/Index.plist.baseline 恢复基线
"""
import datetime
import plistlib
import shutil
import sys
from pathlib import Path

INDEX = Path.home() / "Library/Application Support/com.apple.wallpaper/Store/Index.plist"
BACKUP = Path(__file__).resolve().parent.parent / "backup/exp002/Index.plist.baseline"
ASSET_ID = "35693AEA-F8C4-4A80-B77D-C94B20A68956"
CONTAINERS = ["Desktop", "Idle", "Linked"]


def load(path: Path) -> dict:
    with open(path, "rb") as f:
        return plistlib.load(f)


def save(path: Path, plist: dict) -> None:
    with open(path, "wb") as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)


def inject(node: dict, config: bytes) -> None:
    node["Type"] = "individual"
    content = node.get("Content")
    if content is None:
        content = {}
        node["Content"] = content
    choices = content.get("Choices") or [{}]
    if not choices:
        choices = [{}]
    choices[0]["Provider"] = "com.apple.wallpaper.choice.aerials"
    choices[0]["Configuration"] = config
    choices[0]["Files"] = []
    content["Choices"] = choices
    content["Shuffle"] = "$null"
    content.pop("EncodedOptionValues", None)


def main() -> None:
    if "--restore" in sys.argv:
        if BACKUP.exists():
            shutil.copy2(BACKUP, INDEX)
            print(f"restored: {BACKUP} -> {INDEX}")
        else:
            print(f"no baseline backup at {BACKUP}")
        return

    if not BACKUP.exists():
        shutil.copy2(INDEX, BACKUP)
        print(f"baseline captured: {INDEX} -> {BACKUP}")

    plist = load(INDEX)
    config = plistlib.dumps({"assetID": ASSET_ID}, fmt=plistlib.FMT_BINARY)
    now = datetime.datetime.now()

    for target in ["AllSpacesAndDisplays", "SystemDefault"]:
        if target not in plist:
            print(f"skip missing target: {target}")
            continue
        for container in CONTAINERS:
            if container in plist[target]:
                inject(plist[target][container], config)
                plist[target][container]["LastSet"] = now
                print(f"injected: {target}.{container}")

    save(INDEX, plist)
    print(f"saved: {INDEX} (assetID={ASSET_ID})")


if __name__ == "__main__":
    main()
