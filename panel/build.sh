#!/bin/bash
# MWI 管理面板构建(CLT 无 SwiftUIMacros 插件,用 swiftc 直编替代 SwiftPM)
set -e
cd "$(dirname "$0")"
DIR="$(pwd)"
mkdir -p build/MWIPanel.app/Contents/MacOS

# 绝对路径编译:保证 #filePath 为绝对路径(相对路径会让面板把工程根误解析为 /)
xcrun swiftc -parse-as-library -O \
  "$DIR/Sources/MWIPanel/Models.swift" "$DIR/Sources/MWIPanel/MOVPatcher.swift" \
  "$DIR/Sources/MWIPanel/AerialManifest.swift" "$DIR/Sources/MWIPanel/AXSelection.swift" \
  "$DIR/Sources/MWIPanel/WallpaperService.swift" "$DIR/Sources/MWIPanel/main.swift" "$DIR/Sources/MWIPanel/MainViewController.swift" \
  -o "$DIR/build/MWIPanel.app/Contents/MacOS/MWIPanel" \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics \
  -framework AVFoundation -framework UniformTypeIdentifiers -framework Network

cat > build/MWIPanel.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>MWIPanel</string>
	<key>CFBundleIdentifier</key>
	<string>local.mwi.panel</string>
	<key>CFBundleName</key>
	<string>MWI 壁纸管理</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>MWI 需要控制系统设置壁纸面板以选择注入资产</string>
	<key>NSDesktopFolderUsageDescription</key>
	<string>MWI 需要访问桌面以选择壁纸视频文件</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>MWI 需要访问文稿以选择壁纸视频文件</string>
	<key>NSDownloadsFolderUsageDescription</key>
	<string>MWI 需要访问下载以选择壁纸视频文件</string>
	<key>NSRemovableVolumesUsageDescription</key>
	<string>MWI 需要访问移动存储上的壁纸视频文件</string>
</dict>
</plist>
PLIST
printf 'APPL????' > build/MWIPanel.app/Contents/PkgInfo

# ad-hoc 签名:稳定 TCC 授权标识(重构建不丢权限)
codesign --force --deep -s - build/MWIPanel.app 2>/dev/null

echo "built: build/MWIPanel.app"
