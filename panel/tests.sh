#!/bin/bash
# MWI 测试
#   ./tests.sh       — 沙箱单元/集成测试(路径注入临时目录,不触碰系统壁纸状态)
#   ./tests.sh e2e   — 系统级全链路测试(注入/选择/播放/删除/恢复真实系统壁纸;需辅助功能权限)
#   ./tests.sh all   — 两者
set -e
cd "$(dirname "$0")"
DIR="$(pwd)"

COMMON_SRC="$DIR/Sources/MWIPanel/Models.swift $DIR/Sources/MWIPanel/MOVPatcher.swift \
  $DIR/Sources/MWIPanel/AerialManifest.swift $DIR/Sources/MWIPanel/AXSelection.swift \
  $DIR/Sources/MWIPanel/WallpaperService.swift $DIR/Sources/MWIPanel/MainViewController.swift"
FRAMEWORKS="-framework AppKit -framework ApplicationServices -framework CoreGraphics \
  -framework AVFoundation -framework UniformTypeIdentifiers -framework Network"

mkdir -p build

run_sandboxed() {
  echo "== 编译沙箱测试 =="
  xcrun swiftc -parse-as-library -O $COMMON_SRC \
    "$DIR/tests/harness.swift" "$DIR/tests/fixtures.swift" \
    "$DIR/tests/mov_patcher_tests.swift" "$DIR/tests/aerial_manifest_tests.swift" \
    "$DIR/tests/pipeline_tests.swift" "$DIR/tests/http_server_tests.swift" \
    "$DIR/tests/thumbnail_tests.swift" "$DIR/tests/run_tests.swift" \
    -o "$DIR/build/run_tests" $FRAMEWORKS
  echo "== 运行沙箱测试(不触碰系统壁纸状态)=="
  "$DIR/build/run_tests"
}

run_e2e() {
  echo "== 编译系统级 e2e 测试 =="
  xcrun swiftc -parse-as-library -O $COMMON_SRC \
    "$DIR/tests/run_e2e.swift" -o "$DIR/build/run_e2e" $FRAMEWORKS
  echo "⚠  e2e 会修改真实系统壁纸状态(注入/选择/播放/删除/恢复),结束后自动回基线"
  echo "⚠  需辅助功能权限:系统设置 → 隐私与安全性 → 辅助功能 → 允许终端"
  echo "⚠  需测试素材:test_videos/mwi_test3_patched.mov + mwi_test4.png(本地生成,不入库)"
  "$DIR/build/run_e2e"
}

case "${1:-}" in
  e2e) run_e2e ;;
  all) run_sandboxed && run_e2e ;;
  *) run_sandboxed ;;
esac
