# 注入视频要求说明(INJECTION_REQUIREMENTS)

> 基于 livid-community(`a223079`)的实现研究。用于 mac_wallpaper_injector 项目的注入规格定义。

## 结论

**livid 的做法是先转码再注入,所以对"用户输入视频"零要求。** 条件约束的是**注入物(转码产物)**。若绕过转码直接注入现成 HEVC 文件,它必须满足以下规格(全部来自 golden formula 输出)。

## 硬性条件(注入物规格)

| 维度 | 要求 | 参考出处 |
|---|---|---|
| 容器 | MOV(QuickTime),FFmpeg mov muxer | `FFmpegWrapper.cpp` 输出路径 |
| 编码 | HEVC,codec tag 必须是 **`hvc1`**(不是 `hev1`) | `FFmpegWrapper.cpp:574` |
| 位深 | **10-bit** `yuv420p10le`,`AV_PROFILE_HEVC_MAIN_10`(SDR 8bit 也会扩到 10) | `:517-525` |
| GOP | **固定** `keyint=60:min-keyint=60:scenecut=0` | `:336-337` |
| 时间分层 | `bframes=4:b-pyramid=1:temporal-layers=3` → 每帧带 temporal_id 0/1/2 | `:337` |
| 时间基 | **timescale = 240000**(240fps 时间基) | `:340` |
| 色彩 | 强制 BT.709 标签(primaries/trc/colorspace)+ MPEG range;HDR 输入先 `tonemap=hable` 到 BT.709 SDR | `:528-531, 658-660` |
| 帧率 | **整数**。29.97→30、23.976→24、59.94→60 自动归一化;仅当 fps 偏离整数 >0.001 且 <0.1 时触发 | `:641-648` |

## 核心机制(为什么是这组数字)

`timescale=240000` + `keyint=60` = **每个 GOP 恰好 1 秒**(60帧 @ 240fps 时间基)。HEVC 3 层时间分层在每个 GOP 内产生 temporal_id 0/1/2 的固定模式——patcher 的 NAL 分析读出来、nibble 打包进 `csgm`,Apple 的壁纸引擎靠它做分段时间播放/慢动作。参数不匹配,csgm 数据就和实际流不符,系统可能只显示静态帧或直接不认。

## patcher 运行时依赖(硬失败条件)

注入时 `WallpaperInjector.patch` 逐级查找,缺任一直接抛 `atomNotFound`(`WallpaperInjector.swift:10-52`):

```
moov → trak → mdia → minf → stbl
stsz(样本大小)、stsc(样本到 chunk)、stco 或 co64(chunk 偏移)、stts(时间戳)
tkhd(读 track 宽高生成 tapt)、hdlr、vmhd
```

可选:`ctts`(有才生成 `cslg`)、`elst`(有才置 media_time=0)、`sgpd`(无则 tscl 按 stts 默认值生成)。

## 明确不需要的

- **分辨率**:任意(`targetHeight=0`,tapt 直接取 tkhd 尺寸)
- **音频**:patcher 完全不碰音轨
- **HDR**:会被 tone-map 成 BT.709 SDR
- **用户输入格式**:mp4/webm/avi 都行——app 会先按上面规格转码

## 附录:用本机 ffmpeg 命令行生成注入文件(2026-08-30 实测验证)

本机:ffmpeg 9.0.1 (Homebrew) + libx265。任意输入视频 → 满足上述全部规格的 MOV:

```bash
ffmpeg -i input.mp4 \
  -vf "fps=fps=30,format=yuv420p10le,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709" \
  -c:v libx265 -preset medium -crf 18 \
  -x265-params "keyint=60:min-keyint=60:scenecut=0:bframes=4:b-adapt=2:b-pyramid=1:temporal-layers=3" \
  -tag:v hvc1 -video_track_timescale 240000 -an \
  output.mov
```

### 实测验证矩阵(6s testsrc2 合成源,640x360@29.97)

| 规格 | 要求 | 实测 |
|---|---|---|
| codec tag | hvc1 | ✅ `codec_tag_string=hvc1` |
| profile/位深 | Main 10 / 10-bit | ✅ `yuv420p10le` |
| timescale | 240000 | ✅ `time_base=1/240000` |
| 帧率 | 整数(29.97→30) | ✅ `r_frame_rate=30/1` |
| GOP | 固定 60 | ✅ 关键帧 @ 1/61/121 |
| 色彩 | BT.709 全套 | ✅ primaries/transfer/space=bt709, range=tv |
| 时间分层 | 3 层 | ✅ NAL temporal id {0,1,2},模式 0,0,1,2,2 |

### 注意点(实测踩坑)

1. **色标签必须用 `setparams` 放在 filter 链里**:ffmpeg 9 从 filter 输出帧属性取色标签。命令行 `-color_primaries bt709 -color_trc bt709` 写了不生效(仅 `-colorspace` 生效),`setparams` 全量写入。
2. **本机 Homebrew ffmpeg 未编译 zscale(libzimg)**:SDR 路径用 `format=yuv420p10le` 做 8→10bit 扩展,等价于参考实现的 zscale error_diffusion(略去抖动)。HDR 输入降级用 `tonemap=hable`(无 zscale 线性转换,质量略差);要完整 HDR 路径需另装带 libzimg 的 ffmpeg。
3. `-video_track_timescale 240000` 是 mov muxer 选项,必须位于输出文件前。
4. 音频:用 `-an` 丢弃;如要保留音轨,移除 `-an` 并加 `-c:a aac`。
