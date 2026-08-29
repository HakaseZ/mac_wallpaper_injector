# 实验结论总表 (EXPERIMENT_CONCLUSIONS.md)

> 每个实验的结论**永久追加,不删除、不覆盖**,由 git 全量追踪。
> 与 `EXPERIMENTS.md`(只保留当前实验记录)互补:本文件是结论的累积档案。
> 新结论追加到文件末尾,格式遵循「实验 001」模板。

---

## 实验 001:无补丁 MOV 注入

- **日期**:2026-08-30
- **提交**:ffbc4ec(实验记录),269fcaf(框架)
- **结论**:**注入路径在 macOS 27 上失效** —— 无补丁 MOV 是否被接受的问题未走到验证点,系统根本不请求它。
- **根因**:livid 的注入依赖用户级 `aerials/manifest/entries.json`(Sonoma 行为)。macOS 27 的 WallpaperAerialsExtension 改用系统 **fallback manifest**(扩展内嵌/网络源,不在扩展 bundle `Resources/` 或用户容器中),asset url 为 `file://aerials/videos/<UUID>.mov`,资产调度器满足于本地已有视频,不拉取新资产。
- **证据**:
  - agent 解析了注入的 choice(`provider=com.apple.wallpaper.choice.aerials`)并启动扩展 ✅
  - 扩展日志 `Loading fallback manifest` + `FigAssetCreateWithURL: file://…/videos/4207734D-….mov` + `Not downloading additional assets because there are enough`
  - 8181 HTTP 服务零请求;视频队列 0 帧入队
- **影响**:
  - 阶段 3(系统集成)注册机制需重写:注入点从用户 entries.json 移走
  - fallback asset 被 CoreMedia 直接以 `file://` 读取 → atom 补丁(阶段 2)可能更关键:播放器直接吃文件,无 HTTP 层容错
- **基线恢复**:✅ Index.plist 恢复 image choice、agent 重启、entries.json 未改动、8181 功能等价
- **下一步**(实验 002 方向):
  1. 定位 fallback manifest 真实来源(扩展二进制 strings / 抓包 / WallpaperAgent.app bundle)
  2. 理解 macOS 27 资产注册机制(替换本地 videos/ 文件?改写 manifest?)
  3. 验证无补丁 mov 直接替换 fallback asset 本地文件后能否播放(回答原始问题)
