# MWI (mac_wallpaper_injector)

macOS 动态壁纸注入器 — 研究 livid-community 实现后的复刻项目。

## 目标

把任意视频转码为 HEVC 10-bit MOV(带 HEVC 时间分层),通过 QuickTime atom 修补使其被 macOS 识别为原生 Aerial 动态壁纸,并注册进系统壁纸目录(`~/Library/Application Support/com.apple.wallpaper/`)。

## 路线

1. 转码器:HEVC Main10 + `temporal-layers=3:keyint=60` + timescale 240000 + `hvc1` tag
2. MOV patcher:parse → copy-or-rebuild → 注入 `tapt/sgpd/csgm/cslg` → stco 重排
3. 系统集成:entries.json + videos/ + thumbnails/ + Index.plist + 重启 wallpaper agent
4. UI:import + 注册按钮

详见 `IMPLEMENTATION_RESEARCH.md`(livid-community 仓库)。
