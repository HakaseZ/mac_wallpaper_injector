#!/bin/bash
# MWI 面板自动化测试:编译并运行全链路断言
# 用法: ./tests.sh
set -e
cd "$(dirname "$0")"
DIR="$(pwd)"

echo "== 编译测试 =="
xcrun swiftc -parse-as-library -O \
  "$DIR/Sources/MWIPanel/Models.swift" "$DIR/Sources/MWIPanel/MOVPatcher.swift" \
  "$DIR/Sources/MWIPanel/AerialManifest.swift" "$DIR/Sources/MWIPanel/AXSelection.swift" \
  "$DIR/Sources/MWIPanel/WallpaperService.swift" \
  "$DIR/tests/run_tests.swift" -o "$DIR/build/run_tests" \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics \
  -framework AVFoundation -framework UniformTypeIdentifiers -framework Network

echo "== 运行(会注入/选择/播放/删除/恢复,结束后自动回基线)=="
"$DIR/build/run_tests"
