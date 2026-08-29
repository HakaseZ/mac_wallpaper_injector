# 实验记录 (EXPERIMENTS.md)

> 追踪注入测试实验。原则见 agent.md「实验原则」。
> 每次实验:记录基线 → 执行 → 验证 → **恢复至基线** → commit 本文档。
> 只保留当前实验内容;历史由 git commit 追踪。

---

## 实验 001:无补丁 MOV 注入(阶段 1)

### 目的

验证"转码规格全达标但**未经 atom patcher 处理**"(无 tapt/sgpd/csgm/cslg)的 MOV 是否被系统壁纸引擎接受并播放。结果决定下一步:写 MOV patcher(阶段 2)或可直接注入。

### 实验开始前的基线(即上一次实验恢复后的状态,首次实验 = 系统初始状态)

| 项 | 状态 |
|---|---|
| 日期 | 2026-08-30 |
| 系统 | macOS 27.0 (26A5421a),git dev @ f8df7ad |
| 壁纸 | 静态 image choice(Index.plist `AllSpacesAndDisplays` + `SystemDefault`,Provider=`com.apple.wallpaper.choice.image`) |
| entries.json | 含自定义 asset `E0685AC0-67EB-449F-935D-2C9B95149026`("MWI Test4",`url-4K-SDR-240FPS` → `http://127.0.0.1:8181/mwi_test4.mov`,category `dynamic-aerials`) |
| 8181 服务 | `python3 -m http.server 8181 --directory test_videos/`(PID 13590),mov/png 端点 200 |
| aerials/videos/ | 8 个系统自带 mov(未改动) |
| 注入物 | `mwi_test4.mov`(4K/30s,规格全达标 ✅,未打补丁)、`mwi_test4.png`(640×360) |
| 测试文件状态 | 见 `test_videos/TEST_FILES.md` |

### 实验步骤

1. 备份 `Index.plist`、`entries.json`(带时间戳副本,记录路径)
2. 注入:复刻 livid `setWallpaper` — `AllSpacesAndDisplays` + `SystemDefault` 的 Desktop/Idle 容器:
   - `Type` = `individual`
   - `Choices[0]` = { `Provider`: `com.apple.wallpaper.choice.aerials`, `Configuration`: 二进制 plist `["assetID": E0685AC0-67EB-449F-935D-2C9B95149026]`, `Files`: [] }
   - 删除 `EncodedOptionValues`,`Shuffle` = `$null`
3. 重启 agent:`launchctl stop com.apple.wallpaper.agent` + `pkill -f WallpaperAgent|WallpaperAerialsExtension` + `launchctl start com.apple.wallpaper.agent`
4. 验证:8181 服务日志是否出现 `mwi_test4.mov` 拉流;壁纸实际变化(截图);Index.plist 是否被系统回写
5. 恢复基线 + commit

### 结果

(待执行)

### 恢复至基线

- 恢复操作:恢复备份的 Index.plist / entries.json + 重启 agent
- 完成:待执行
- 差异说明:待执行
