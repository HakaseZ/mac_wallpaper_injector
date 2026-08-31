# MWI 壁纸管理(Mac Wallpaper Injector)

把任意视频注入为 macOS Aerial 动态壁纸的原生管理面板。纯 Swift(AppKit)实现,不依赖 Python 脚本。

> **注意**:本工具会修改系统壁纸扩展的 manifest(`~/Library/Application Support/com.apple.wallpaper/`)。使用前请阅读[工作原理](#工作原理)与[卸载/回滚](#卸载--回滚)。

## 功能

- **添加壁纸**:选择本地视频,自动转码为 Aerial 合规格式(HEVC 10bit)、修补 mov 结构、生成 16:10 缩略图,注入独立分类
- **全格式输入**:MOV/MP4/MKV/WebM/AVI 等任意容器/编码;自动帧率归一(29.97→30)、HDR(PQ/HLG)→SDR tonemap、奇数分辨率偶数化
- **分类管理**:同名分类复用,不重复创建;新分类完全独立(克隆模板 + 全新子分类,不混入系统 Landscape 资产)
- **删除**:移除资产条目、视频、缩略图与空分类;被删资产若正被使用,自动回归系统默认动态壁纸
- **重命名**:右键分类名或壁纸名;改名自动同步到系统壁纸设置(清缓存 + 重启 agent)
- **并发注入**:多个视频同时注入互不阻塞;转码全局排队,CPU 总占用 ≈ 单转码(~10%),不发热
- **日志导出**:菜单 **日志 → 导出日志…** 导出操作日志(`~/Library/Logs/mwi_panel.log`)

## 工作原理

注入的资产写入系统壁纸扩展的 `entries.json`;视频与缩略图预置到扩展本地目录,`url` 指向本地文件(`file://`),播放不依赖网络与系统代理。注入前自动备份用户 `entries.json` 到 `~/Library/Application Support/com.apple.wallpaper/mwi-backup/`,扩展重启后自动恢复播放。

## 环境要求

- macOS 14.0+(在 macOS 27 上验证)
- Xcode Command Line Tools(swiftc)
- ffmpeg(候选路径:`/opt/homebrew/bin/ffmpeg`、`/usr/local/bin/ffmpeg`、`/usr/bin/ffmpeg`)— 转码与规格探测需要;若视频已是合规 HEVC 则直接打补丁,无需转码

## 构建

```bash
cd panel
./build.sh
```

产出 `panel/build/MWIPanel.app`(ad-hoc 签名;首次打开需在 系统设置 → 隐私与安全性 允许)。

## 使用

1. 打开 MWIPanel.app,点击 **添加壁纸** 选择视频文件(可拖入)
2. 注入完成后资产卡片出现在网格(按分类分组)
3. 在系统壁纸面板中选择注入资产即可生效;**删除选中** 移除资产
4. 右键分类名或壁纸名可重命名;菜单 **日志 → 导出日志…** 导出操作日志

注入资产列表从系统壁纸扩展的 entries 实时读取,面板操作后点击 **刷新** 同步。

## 卸载 / 回滚

面板内:删除全部注入资产后,壁纸自动回归系统默认动态壁纸。

手动清理(彻底移除):

1. 删除注入资产:面板 **删除选中**,或手动从 `aerials/manifest/entries.json` 移除 `url` 为 `file://` 的资产条目及其空分类
2. 删除预置文件:`~/Library/Application Support/com.apple.wallpaper/aerials/videos/<ID>.mov` 与 `aerials/thumbnails/<ID>.png`
3. 恢复注入前 manifest(可选):从 `~/Library/Application Support/com.apple.wallpaper/mwi-backup/entries.json` 拷回
4. 删除应用:移除 `MWIPanel.app` 即可(无守护进程、无自启项、无残留)

## 测试

```bash
cd panel
./tests.sh        # 沙箱单元/集成测试(不触碰系统壁纸状态,可随时运行)
./tests.sh e2e    # 系统级全链路测试(注入/选择/播放/删除/恢复;需辅助功能权限,会改真实系统壁纸状态)
./tests.sh all    # 两者
```

测试分层:

- **单元**:MOV atom 补丁(解析/构建/时序分层提取/偏移重排)、manifest 注入/复用/重命名/删除/空分类清理
- **集成**:转码→补丁→预置全链路(ffprobe 验证合规规格 + AVFoundation 可读)、ffprobe 探测、HTTP 静态服务、16:10 缩略图裁切
- **e2e**:对真实系统壁纸做端到端断言(基线/注入/播放/持久性/删除/恢复),结束后自动回基线

沙箱测试通过 `Paths.current` 将全部路径注入临时目录,不触碰真实系统壁纸。

## 项目结构

```
panel/Sources/MWIPanel/  应用源码(Models / MOVPatcher / AerialManifest / WallpaperService / MainViewController / AXSelection)
panel/tests/             测试(harness + 套件 + e2e)
CORE_IMPLEMENTATION.md   核心实现技术文档(最终版)
research/                研究阶段归档(实验结论、实现研究、注入规格、Python 原型脚本)
```

## 已知限制

- 注入链路依赖系统壁纸扩展的 manifest 结构(白名单字段克隆),**未来 macOS 版本更新可能失效**;失效请提交 issue
- 应用为 ad-hoc 签名、未公证,分发需用户手动允许(系统设置 → 隐私与安全性)
- 重命名/刷新依赖清空系统壁纸扩展的 view-model 缓存并重启 WallpaperAgent,首次操作可能略有延迟

## 许可证与参考

[AGPL-3.0](LICENSE):**copyleft,衍生项目必须开源**(含改造成网络服务的情形)。

核心方案(atom 补丁结构、转码规格、系统壁纸目录注入思路)源于以下 MIT 项目的公开研究;实现均为本项目独立完成,并针对 macOS 27 重新攻破了注入链路(白名单字段克隆、前台通道、独立分类):

- **[livid-community](https://github.com/aground5/livid-community)**(LiveWallpaperEnabler,MIT):MOV atom 补丁(tapt/sgpd/csgm/cslg)与转码 golden formula 规格的原始研究来源。其注入路径在 macOS 27 上已失效,本项目的 mov patcher 为独立 Swift 实现
- **[phosphene](https://github.com/kageroumado/phosphene)**(MIT):自建壁纸扩展路线的调研参考;本项目最终未采用该路线,改为注入 aerials 扩展(行为与原生动壁纸一致)
