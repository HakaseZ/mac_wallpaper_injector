# 核心实现说明 (CORE_IMPLEMENTATION)

> 本项目研究结论的最终版技术说明。逐实验过程见 git 历史的实验记录;本文只描述已验证的核心机制与最终方案。

## 一句话原理

把任意视频转码为**结构上等于苹果 Aerial** 的 HEVC MOV(补 tapt/sgpd/csgm/cslg 原子),预置到系统壁纸扩展的本地目录,通过可写的用户 manifest(`entries.json`)注册为**全新独立资产 + 独立分类**,再用辅助功能模拟点击系统壁纸面板走**前台通道**触发,让 macOS 壁纸引擎把它当原生动态壁纸播放。

无悬浮窗、无私有框架、无 root。播放由 aerials 扩展原生完成,行为与系统壁纸一致(循环/锁屏渐入/多显示器)。

## 注入链路(端到端,全部实测)

```
源视频
  → 转码(HEVC 10bit,规格见下)
  → mov 补丁(tapt/sgpd/csgm/cslg,AVFoundation 可读的前提)
  → 抽帧生成 16:10 缩略图
  → 预置 videos/<assetID>.mov + thumbnails/<assetID>.png(本地 file:// 源)
  → 写用户 entries.json:全新资产(字段克隆)+ 独立分类
  → 破宿主设置缓存 + 重启 WallpaperAgent
  → 打开系统设置壁纸面板,AX 定位资产,合成点击
  → 扩展走前台通道下载 → 落盘 → choice 写入 → aerials 原生播放
```

## 关键机制(实证结论)

### 1. 白名单防火墙 = 字段完整性,不是 id 白名单

系统设置壁纸面板的模型(SettingsProvider)遍历 manifest 资产时,过滤**字段不完整**的资产;`subcategories=[]`、shotID 不匹配等都会导致资产被丢弃。**全新 id 只要完整克隆 fallback 资产的结构字段**(subcategories 引用合法子分类、shotID、includeInShuffle、preferredOrder、showInTopLevel、pointsOfInterest 等),仅 id / URL / 名字不同,即可进入面板模型并完成下载播放。无需顶替官方资产。

### 2. 可写注入点:用户 entries.json

`~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json` 是扩展的 "downloaded manifest"(日志 `Loading downloaded manifest`)。SettingsProvider 与播放器都读它,**结构完整时改名/删除/新增全部生效**,纯新资产清单会被拒并回落 fallback。这是 macOS 27 上的合法注入入口。

### 3. 宿主设置缓存跨重启持久

面板模型缓存位于 `/var/folders/.../C/com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache/extension-com.apple.wallpaper.extension.aerials-desktop`,跨重启持久。**删缓存 + `killall WallpaperAgent`** 强制重查,否则注入资产不出现。

### 4. 前台 vs 后台通道(注入成败的分水岭)

系统不"识别"用户操作,而是**信任 System Settings 面板进程的消息通道**:

- **后台通道**(改 Index.plist / 文件变更):扩展只收 `selectedChoicesDidChange` + `acquire` → 命中 **`there are enough` 省流量设计**(本地已有视频时不再自动下载附加视频)→ 注入资产无本地对应文件,回退 Golden Gate。
- **前台通道**(面板点击):面板进程持 XPC 凭证发 `downloadAsset(withID:)` → `Begin asset download → Downloading first asset → Completing successfully → Completed downloading representative asset` → 不受 "there are enough" 拦截,真实下载落盘,建立完整就绪状态。

伪造 XPC 通道不可行(签名系统进程);**合成点击面板 = 唯一可靠触发方式**。

### 5. 实际下载源字段:url-4K-SDR-240FPS(不是 url)

扩展下载资产时读 `url-4K-SDR-240FPS` 字段。仅改 `url` 会让扩展去下载 sylvan 官方视频(4K/300s,数百 MB);改 `url-4K-SDR-240FPS` 才指向注入源。删除该字段 → 下载失败(DownloadError 0);`url` 单独存在不被使用。

### 6. 下载源收敛为本地 file://(避开网络与代理)

最终方案:视频预置 `aerials/videos/<id>.mov`、缩略图预置 `thumbnails/<id>.png`,`url`/`url-4K`/`previewImage` 全部指向本地文件(百分比编码)。不依赖网络与系统代理(曾实测 Clash 代理把 sylvan 下载拖慢 56 倍并导致 -1005 中断);扩展重启后自动恢复播放,持久性好。

### 7. mov 补丁(硬前提)

- 无 tapt/sgpd/csgm/cslg 的 MOV 被 CoreMedia 直接拒绝(`VideoSampleReadingErrors Code=4`),与编码规格无关。
- **csgm 必须带 Apple 8B 头**(sampleCount-1 后 `(0x0f, 0x0f)`),缺失则 AVFoundation 解析 0 轨道。
- **stbl 保持原始顺序**:仅在 stsd 后插 sgpd/csgm、stco 前插 cslg;重排(把 ctts 移到 stss/sdtp 前)会导致 0 轨道。
- sgpd 内容不影响 aerials 播放(扩展不读,简化实现可保留);csgm payload 从 NAL temporal_id 生成,被接受。

### 8. 独立分类(最终方案)

- 新分类 = 完整克隆 Landscape 模板(7 字段必需:id/localizedDescriptionKey/localizedNameKey/preferredOrder/previewImage/representativeAssetID/subcategories),仅 id/名字不同。
- **全新子分类** = 克隆 Golden Gate 子分类结构,新 id;新分类 subcategories = [该全新子分类]。
- 资产归入:`categories=[新分类 id]` + `subcategories=[全新子分类 id]` → **资产只在新分类,Landscape 完全不含,双归属消除**。
- 模型验证:MWI 独立分类只含注入资产;Landscape 不含注入资产。

### 9. 面板模拟操作(AX)

- 资产按钮 AXDescription = 资产名,AX 树定位 + `AXScrollToVisible` + 合成点击(CGEvent)。
- 壁纸面板资产流**横向滚动,由垂直滚轮事件驱动**:须先点击激活滚动区(AXScrollArea),再合成垂直滚轮。
- 资产下载中 = AXProgressIndicator(拦截点击),完成后恢复 AXButton。
- 首次点击可能落空(滚动动画坐标漂移),重试即成功。

## 转码规格(注入物必须满足)

| 维度 | 规格 |
|---|---|
| 容器 | MOV(QuickTime),FFmpeg mov muxer |
| 编码 | HEVC,codec tag `hvc1` |
| 位深 | 10-bit `yuv420p10le`,main10 |
| GOP | 固定 `keyint=60:min-keyint=60:scenecut=0` |
| 时间分层 | `bframes=4:b-adapt=2:b-pyramid=1:temporal-layers=3` |
| 时间基 | timescale = 240000 |
| 色彩 | 强制 BT.709 标签 + MPEG range;HDR 输入先 tonemap 到 BT.709 SDR |
| 帧率 | 整数(29.97→30、23.976→24、59.94→60 自动归一) |
| 参数 | libx265 medium,crf 18 |

## 播放验证边界(全部实测)

- **循环**:长视频 startReading 间隔 = 完整时长,无 renderer 销毁,持续循环。
- **锁屏**:锁屏后扩展 `Presentation Mode: default -> locked` + `Play Called` + `.rampingUp` 渐入,与 aerials 原生锁屏行为一致;解锁恢复。
- **多显示器**:副屏(Sidecar)与主屏一致显示注入壁纸(choice → agent → 每屏 acquire 统一分配)。
- **快照**:`Snapshot succeeded` 强证据(渲染画面成立)。

## 恢复规范

- restore/删除全部注入资产后,choice 回归**系统出厂默认动态壁纸**(`Provider: default`,亮/暗切换),不引用任何用户本地图片。
- 缩略图污染自愈:删除被污染的 `thumbnails/<id>.png`,扩展自动从 sylvan 重新下载系统真实封面。
- 恢复内容:entries.json 复原、videos 复原、Index.plist choice 复原、override 清除、面板缓存清理。
