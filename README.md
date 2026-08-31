# MWI 壁纸管理(Mac Wallpaper Injector)

将任意视频注入为 macOS Aerial 动态壁纸的原生管理面板。纯 Swift(AppKit)实现,不依赖 Python 脚本。

## 功能

- **添加壁纸**:选择本地视频,自动转码为 Aerial 合规格式(HEVC 10bit)、补丁 mov 结构、生成 16:10 缩略图,注入独立分类
- **分类管理**:同名分类复用,支持新建分类;注入资产完全独立(不混入系统 Landscape 资产)
- **删除**:移除资产条目、视频、缩略图与空分类;被删资产若正被使用,自动回归系统默认动态壁纸
- **重命名**:右键分类名或壁纸名,可重新编辑名称,改名自动同步到系统壁纸设置;注入资产在系统壁纸面板中直接选择生效
- **日志导出**:日志不在界面显示,通过菜单 **日志 → 导出日志…** 导出为文件
- **并发注入**:多个视频同时注入互不阻塞;转码全局排队,CPU 总占用 ≈ 单转码(~10%),不发热
- **实时进度**:卡片右上角环形进度圈 + 右下百分比,支持多任务并行显示

## 工作原理

注入的资产写入系统壁纸扩展的 `entries.json`,视频与缩略图预置到扩展本地目录,`url` 指向本地文件(`file://`),播放不依赖网络与系统代理;扩展重启后自动恢复播放。

## 环境要求

- macOS 14.0+
- Xcode Command Line Tools(swiftc)
- ffmpeg(候选路径:`/opt/homebrew/bin/ffmpeg`、`/usr/local/bin/ffmpeg`、`/usr/bin/ffmpeg`)

## 构建

```bash
cd panel
./build.sh
```

产出 `panel/build/MWIPanel.app`(已 ad-hoc 签名,打开前需在 系统设置 → 隐私与安全性 允许)。

## 使用

1. 打开 MWIPanel.app,点击 **添加壁纸** 选择视频文件
2. 注入完成后资产卡片出现在网格(分类分组)
3. 在系统壁纸面板中选择注入资产即可生效;**删除选中** 移除资产
4. 右键分类名或壁纸名可重命名;菜单 **日志 → 导出日志…** 可导出操作日志

注入资产列表从系统壁纸扩展的 entries 实时读取,面板操作后点击 **刷新** 同步。

## 测试

```bash
cd panel
./tests.sh
```

## 概念参考

本项目的核心方案(atom 补丁结构、转码规格、系统壁纸目录注入思路)源于以下开源项目的研究;实现均为本项目独立完成,并针对 macOS 27 重新攻破了注入链路(白名单字段克隆、前台通道、独立分类):

- **[livid-community](https://github.com/aground5/livid-community)**(LiveWallpaperEnabler,MIT):MOV atom 补丁(tapt/sgpd/csgm/cslg)与转码 golden formula 规格的原始研究来源。其注入路径在 macOS 27 上已失效,本项目的 mov patcher 为独立 Swift 实现。
- **[phosphene](https://github.com/kageroumado/phosphene)**(MIT):自建壁纸扩展路线的调研参考;本项目最终未采用该路线,改为注入 aerials 扩展(行为与原生动壁纸一致)。

[AGPL-3.0](LICENSE):**copyleft,衍生项目必须开源** —— 衍生作品(含改造成网络服务的情形)须以 AGPL-3.0 或兼容协议发布源码。两个概念参考项目均为 MIT(MIT 代码可并入 AGPL 项目,兼容)。
