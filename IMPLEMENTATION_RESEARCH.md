# livid-community (LiveWallpaperEnabler) 实现研究报告

> 研究日期:2026-08-30。基于 `a223079`(dev 分支)。目的:复刻一个类似的 macOS 动态壁纸应用。

## 一句话原理

**把任意视频转码成"结构上等于苹果 Aerial"的 HEVC MOV,然后直接改写系统壁纸目录(`~/Library/Application Support/com.apple.wallpaper/`),让 macOS 的壁纸引擎把它当原生动态壁纸播放。**

没有悬浮窗、没有私有框架。全靠两件事:①文件头伪造(atom 注入)②系统文件直写。风险自负,README 也承认是教育用途。

## 总体架构

```
┌───────────────────────────── LiveWallpaperEnabler.app ─────────────────────────────┐
│                                                                                     │
│  SwiftUI App (5 tab: Prepare→Edit→Render→Library→Catalog)                           │
│    │  import(本地/YouTube) → 转码 → 裁剪 → 渲染队列 → 入库 → 注册+应用                  │
│    │                                                                                │
│    ├── FFmpegBridge (Swift) ──► WebMSupportCpp/FFmpegWrapper.cpp (C++)              │
│    │       静态链接 libav* + libx265 —— 进程内转码,不调 ffmpeg 二进制                   │
│    │                                                                                │
│    ├── QtParser (纯 Swift) —— MOV atom 解析/重写                                     │
│    │       AtomPatcher + WallpaperInjector + QtAtomGenerator + QtNALUnitParser      │
│    │                                                                                │
│    └── NSXPCConnection ──► Contents/XPCServices/com.mitocondria.LiveWallpaperHelper.xpc
│              │                 (bundled XPC service,非特权守护进程)                   │
│              │                 ├─ PythonTask → 打包的 CPython 3.13 + yt-dlp           │
│              │                 └─ LocalAssetServer (Hummingbird, 127.0.0.1:50505)   │
│                                                                                     │
└───────────────┬─────────────────────────────────────────────────────────────────────┘
                │ 改写 Apple 的壁纸目录
                ▼
~/Library/Application Support/com.apple.wallpaper/
  ├─ aerials/manifest/entries.json      ← 注入新 asset(URL 指向 localhost:50505)
  ├─ aerials/videos/<UUID>.mov          ← 打补丁后的视频副本
  ├─ aerials/thumbnails/<UUID>.png
  ├─ Store/Index.plist                  ← 应用壁纸时改写 Desktop/Idle/Linked 节点
  └─ aerials/manifest/TVIdleScreenStrings.bundle ← 本地化(.loctable/.strings)
```

**关键技巧**:manifest 里 asset 的 `url-4K-SDR-240FPS` 写的是 `http://localhost:50505/video/<UUID>.mov`(`AerialService.swift:872`)。系统壁纸引擎通过 HTTP 拉视频,而 LocalAssetServer **每次请求时实时跑 atom 补丁**(`LocalAssetServer.swift:66-68`)再返回字节。所以磁盘上存的是原始转码文件,补丁在服务时完成——这也解释了为什么 patcher 必须快。

## 核心模块 1:转码管线(黄金公式)

入口 `applyGoldenFormula`(`VideoConverterService.swift:275`)→ C++ `FFmpegWrapper::exportToMovExt`(`FFmpegWrapper.cpp:353-376`)。

**编码参数**(`FFmpegWrapper.cpp:336-344,363-367`):

```cpp
encoder     = "libx265"
preset      = "medium"
crf         = "18"
x265-params = "keyint=60:min-keyint=60:scenecut=0:bframes=4:b-adapt=2:b-pyramid=1:temporal-layers=3"
timescale   = 240000        // 关键!文件时间基是 240fps
tenBit      = true          // YUV420P10LE + AV_PROFILE_HEVC_MAIN_10
```

**颜色处理**(`FFmpegWrapper.cpp:517-531,651-686`):

- 无条件强制 BT.709 标签(`color_primaries/trc/colorspace = BT709`),MPEG range
- HDR 输入 → `zscale=transfer=linear:npl=100,tonemap=hable,zscale=transfer=bt709:primaries=bt709:matrix=bt709,format=yuv420p10le`
- SDR 8bit→10bit → `zscale=p=bt709:t=bt709:m=bt709:range=limited:d=error_diffusion,format=...`
- 帧率偏差 >0.1 时插 `fps=fps=N` 归一化(`:646-649`)
- `codec_tag = 'hvc1'`(`:574`)
- **发现的冗余**:libplacebo 链接了但从没进 filter graph;5 种"策略"(HDR/P3/色度)在 C++ 层全部塌缩成"tonemap 开/关 + 永远 10bit";`WebMSupport.swift` 是空壳;测试是空 stub

**为什么是 `temporal-layers=3` + `keyint=60` + `timescale=240000`**:每个 GOP = 60 帧 = 240fps 时间基下的 1 秒,HEVC 时间分层让每帧带 temporal_id(0/1/2)。这正是 Aerial 慢动作/分段时间播放的数据基础。

## 核心模块 2:MOV 原子修补(QtParser)——最硬核的部分

**解析策略:copy-or-rebuild**(`QtAtomPatcher.swift:86-115`):没改过的 atom 直接拷贝原始字节;改过的才用对应 serializer 重建,size 一律重算为 `8 + body`。

**就地修改**(`WallpaperInjector.swift:123-146`):

| atom | 改动 | 意义 |
|---|---|---|
| `tkhd` | flags = 15 | 启用 track 所有标志位 |
| `vmhd` | graphics_mode=64, opcolor=[32768,32768,32768] | QuickTime 视频显示模式 |
| `hdlr` | `"url "` → `"alis"` | 数据引用改别名 |
| `elst` | entries[0].media_time = 0 | 编辑列表归零,循环起点对齐 |

**新增生成 atom**(`QtAtomGenerator.swift`):

- **`tapt`**(tkhd 之后):`clef/prof/enof` 三个 16.16 定点宽高,声明 clean/production/encoded aperture
- **`sgpd` tscl**:version=1, 5 条 entry 每条 20 字节 `[u32 0][u32 baseDuration][u32 1][u32 0][u32 128]` — 时间层描述
- **`sgpd` tsas**:1 条 entry 4 字节 `[u32 0]` — action state
- **`csgm` tscl + tsas**:6 个自定义 u32 `[0,4,2,1,1,16]` + `[u32 sampleCount-1]` + nibble 打包的 temporal id 序列
- **`cslg`**:从 ctts 推导 composition 偏移

**stbl 子 atom 强制重排**(`WallpaperInjector.swift:216`):

```
stsd, sgpd, csgm, stts, ctts, cslg, stss, sdtp, stsc, stsz, stco, co64
```

**NAL 分析**(`QtNALUnitParser.swift:12-101`):用 stsc 展开 chunk→sample 映射,每个 sample 跳读到 chunk 偏移,读 **6 字节**(4 字节长度前缀 + 2 字节 HEVC NAL 头),`temporal_id = byte[5] & 0x07`。然后 `generateCsgmPayload` 检测 0-id 的重复间隔(模式压缩),按 nibble 打包:`(id0+1)<<4 | (id1+1)`。

**文件重组**(`QtAtomPatcher.swift:533-596`):输出布局强制为

```
ftyp | wide(8B 占位) | mdat | moov
```

插入 wide 使 mdat 内容偏移 +8 → **DFS 所有 stco chunk offsets 全部加 delta**(`patchStco`)。这是唯一需要全表重写的部分。

## 核心模块 3:系统目录注入

**注册**(`AerialService.swift:819-922`):
1. 视频副本 → `aerials/videos/<UUID>.mov`;缩略图 → `aerials/thumbnails/<UUID>.png`
2. `entries.json` 新增 `AerialAsset`(schema 见 `Core/Models/AerialModels.swift`:`AerialManifest{version, localizationVersion, initialAssetCount, categories[], assets[]}`,asset 关键字段 `url-4K-SDR-240FPS`、`previewImage`、`categories`、`shotID`)
3. 更新 `TVIdleScreenStrings.bundle` 的 `.loctable` + `.strings`(en/ko)
4. `launchctl stop/start com.apple.wallpaper.agent` 强制重载(`:728-750`)

**应用壁纸**(`setWallpaper`, `:465-598`):读 `Store/Index.plist`,沿 `["Spaces", UUID, "Displays", UUID]` 或 `AllSpacesAndDisplays` 路径,**递归注入** `Type="individual"` + Content/Choices 里的 assetID,写回,重启 agent。没有 AppleScript。外加私有 CGS/SkyLight API(`CGSCopyManagedDisplaySpaces` 等 `@_silgen_name` 声明)枚举/切换 Space、做切换动画。

**备份**:`entries.json.bak`(`:787`),删除走 `deleteCustomAsset/deleteCustomCategory`(按 `http://localhost` 前缀识别自定义 asset,`AerialCategory_` 前缀识别自定义分类)。

## 核心模块 4:XPC Helper + YouTube

**不是特权守护进程**。全仓库零 `SMAppService/SMJobBless/launchd`——是 **sandbox 关闭的 bundled XPC service**(`CFBundlePackageType=XPC!`,嵌入 `Contents/XPCServices/`,Mach 名 = bundle ID `com.mitocondria.LiveWallpaperHelper`)。Helper 启动时顺便 `killall WallpaperAgent WallpaperAerialsExtension`。

**XPC 协议**(`LiveWallpaperHelperProtocol.swift:16-27`,逐字):

```swift
func fetchMetadata(url: URL, withReply: (String?, Error?) -> Void)
func downloadVideo(taskID:url:formatID:outputDirectoryURL:observer:withReply:)
func cancelDownload(taskID:withReply:)
func checkHealth(withReply:)
```

**yt-dlp**:打包的 `cpython-3.13.9-macos-aarch64-none`(python-build-standalone 发行版,永不下载,`BinaryManager` 纯定位器)+ `yt_dlp_bridge.py` CLI,stdout 按行发 JSON 事件(`metadata/progress/result`)。下载格式选择 `bestvideo[height<=N]`,`isHDR`(dynamic_range 含 hdr/pqi)、`isVP9`、`isNativelyPlayable`(H264/HEVC)启发式排序,选最高分辨率→最高码率。下载后非原生格式(webm/vp9 等)用 FFmpeg remux/转码。

## 核心模块 5:App 流程

5 个 tab 的 NavigationSplitView,`@Observable MainViewModel` 驱动,状态不是 enum 而是散布在各 @Observable 单例(importState/jobs/ThumbnailManager/WallpaperStore):

导入 → Prepare(分析+预览转换)→ Edit(AVPlayer + `FilmstripTimeline` 帧级裁剪,fps 吸附手柄)→ Render(串行队列 `RenderQueueService`,FFmpeg 转码)→ Library(`WallpaperStore` 持久化到 App Group UserDefaults `wallpaper_library_v2` + UUID.mov)→ Catalog(注册 + 应用)。

## 风险与坑(照抄前须知)

1. **OS 版本耦合**:依赖 `com.apple.wallpaper` 目录结构和 agent 行为,系统更新可能破坏(Sonoma 起 loctable 替代 strings 就得兼容两套)
2. **每次 HTTP 请求实时打补丁**:性能敏感,大文件慢;请求失败=壁纸灰屏
3. **直接改系统文件**:需要备份/健康检查(它有,`checkHealth`),且杀进程重启 agent 有副作用
4. **代码质量参差**:大量 `TODO`、stub、打印日志;`WallpaperService.swift` 是空壳,逻辑全在 `AerialService`(1123 行单体)
5. **atom 修补是黑魔法**:Apple 没文档,`csgm/sgpd/tapt` 布局是逆向的;但好处是纯 Swift 可移植

## 如果你想做一个:最小可行路径

| 阶段 | 工作量 | 内容 |
|---|---|---|
| 1. 转码器 | 中 | FFmpeg 静态链接或调二进制:HEVC Main10 + `temporal-layers=3:keyint=60` + timescale 240000 + `hvc1` |
| 2. MOV patcher | 高(核心) | 移植 QtParser 模式:parse→copy-or-rebuild→注入 tapt/sgpd/csgm/cslg→stco 重排(约 600 行可精简) |
| 3. 系统集成 | 中 | 只写 entries.json + videos/ + thumbnails/ + Index.plist + 重启 agent |
| 4. UI | 低~中 | 一个 import + 注册按钮即可起步 |

最低可行 demo(不做裁剪/不做 YouTube/不做 XPC/不做 UI):**转码 + patch + entries.json 注入 + 手动重启 agent ≈ 几百行 Swift**。前置条件:macOS 26 测试机 + Xcode + 一个 HEVC 10bit 文件验证。
