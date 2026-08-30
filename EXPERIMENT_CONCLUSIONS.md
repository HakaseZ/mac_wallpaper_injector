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

---

## 实验 002:替换本地资产验证无补丁 MOV

- **日期**:2026-08-30
- **提交**:(随本次 commit)
- **结论**:四项核心发现 —— ①agent 的 choice 解析读**用户级 entries.json**(非扩展 fallback manifest,两组件读两个 manifest);②agent 运行中忽略 Index.plist 变化,重启时解析失败则回写覆盖;③扩展**校验本地资产与 manifest url**,替换文件触发重新下载(直接替换不可行);④**无补丁 MOV 播放失败**(`VideoSampleReadingErrors Code=4`)—— **atom 补丁是硬前提**。
- **根因**:
  - ①:agent(choice 解析)与扩展(资产调度/播放)各自读不同 manifest;注入的 asset 必须存在于用户 entries.json 才能被 agent 接受(001 的 E0685AC0 被接受即因此)
  - ③:扩展将本地 videos/ 文件与 manifest url 关联校验,检测到内容变化(URL changed)即重新下载原视频
  - ④:无 tapt/sgpd/csgm/cslg 的 MOV 被 CoreMedia 播放器直接拒绝(VideoSampleReadingErrors Code=4),与文件规格(编码/位深/时间基等)无关
- **证据**:
  - 拒绝:35693AEA 不在用户 entries.json 时,agent 15:22:17 `Performing scheduled store write` 回写 image
  - 接受:加入后 agent `Create new wallpaper in runtime: aerials` + makeWallpaper + Acquire Wallpaper
  - 检测替换:扩展 `Re-downloading 1 selected video(s) whose URL changed` + `Starting download of`
  - 播放失败:`VideoPlayerLayer failed to acquire next sample ... VideoSampleReadingErrors Code=4`
- **影响**:
  - 阶段 2(MOV patcher)升为**最高优先**:补丁是系统接受注入物的硬前提
  - 注入路径修正为三段:打补丁文件 → 自定义 manifest 或规避 URL-changed 检测 → 用户 entries.json 注册 asset
  - 直接替换本地文件方案否决
- **基线恢复**:✅ 视频 208MB 原文件、entries.json 1 asset、Index.plist image choice、agent 重启
- **下一步**(实验 003 方向):
  1. 移植 livid QtParser 写 MOV patcher(tapt/sgpd/csgm/cslg)
  2. 研究 `AerialManifestLocalPathOverride` / `AerialManifestURLOverride` / `AerialManifestForceLocal`(UserDefaults suite,候选 `com.apple.wallpaper.aerial`)加载自定义 manifest
  3. 完整注入路径:打补丁文件 + 自定义 manifest + 用户 entries.json

---

## 实验 003:打补丁 MOV 系统播放验证

- **日期**:2026-08-30
- **提交**:197f221(阶段 A/B),随本次 commit(阶段 C)
- **结论**:**打补丁 MOV 被系统壁纸引擎成功播放** —— atom 补丁(tapt/sgpd/csgm/cslg)是系统接受注入物的硬前提,实证闭环(无补丁 Code=4 vs 补丁后 `Rendering with success` + `first video frame enqueued`)。
- **根因/机制**:
  - `AerialManifestLocalPathOverride`(UserDefaults suite `com.apple.wallpaper.aerial`)生效,可让扩展加载自定义 manifest —— 这是 macOS 27 的**合法注入入口**(取代失效的用户 entries.json 注入点)
  - manifest 要求:asset 字段须完整(缺 variant/videoGravity 解码失败);categories 不能引用不存在的 asset id;路径须在扩展沙盒可读处(`~/Library/Application Support/com.apple.wallpaper/` 下)
  - 视频下载被调度器节流(`time budget`);**预置本地 videos/<id>.mov 可绕过**(新资产无下载状态,不触发实验 002 的 URL-changed 检测)
- **证据**:
  - override 日志:`AerialManifestLocalPathOverride is set; using ...` + `Did update manifest`
  - 播放:`AVSampleBufferVideoRenderer Change status from Unknown to Rendering with success` + `Received first video frame enqueued` + `setReadyForDisplay to YES`
  - 无 `VideoSampleReadingErrors`(对比实验 002 Code=4)
- **影响**:
  - **完整注入路径成立(三段)**:①打补丁文件(scripts/mov_patcher.py)②override manifest(url 指向我们的文件)+ 本地视频 ③用户 entries.json 注册 asset(agent choice 解析)
  - 阶段 2(patcher)✅ 完成;阶段 3(系统集成)机制已验证,可工程化
- **基线恢复**:✅ 视频/缩略图/manifest/defaults/Index.plist/agent 全部清理
- **待解决**(实验 004 方向):
  1. 6s 短视频播放后 renderer 销毁 —— 长视频(mwi_test4 30s/4K)循环与持续播放行为
  2. 视频下载节流 —— 正式注入时如何避免依赖预置文件(或确认预置即终态)
  3. mwi_test4(4K/30s)打补丁 + 系统播放验证(当前仅验证了 640×360/6s)

---

## 实验 003 补充:管理层面(系统设置壁纸面板)验证

- **日期**:2026-08-30
- **结论**:**系统设置壁纸面板可显示并管理注入的壁纸** —— 管理层面不依赖改 Index.plist,用户可在系统设置中直接预览/选择/应用。
- **机制**:系统设置壁纸面板通过扩展 catalog 加载壁纸列表;override manifest(`AerialManifestLocalPathOverride`)生效时,面板可见我们的 asset(与播放路径共用同一 catalog)。
- **证据**:面板打开后 agent `assetManager Merging two groups` + 8181 收到 `GET /mwi_test4.png`(面板拉取 MWI Test4 缩略图)。
- **影响**:注入方案收敛为单一配置点 —— override manifest 常驻即同时提供"播放数据源"和"系统设置管理入口";用户可直接在系统设置里选择注入壁纸。
---

## 实验 004:常驻注入 + 4K 长视频端到端验证

- **日期**:2026-08-30
- **结论**:**4K 视频稳定播放未达成**;注入路径在 1MB 上曾播放成功但不稳定;扩展存在不可见内部状态,决定自定义资产是否"就绪"。
- **根因/机制**:
  - 4K patcher 完全适配(52MB/4K/898 帧/stco/csgm layers=3),文件本身系统可解码(ffprobe 898 帧)
  - 预置文件必须匹配扩展记录的下载状态(大小/内容);新 asset 无记录 → 等待下载(被 time budget 节流)→ 不播放
  - manifest url 变更 → URL-changed 检测 → 重新下载(节流)失败
  - 状态伪造尝试(文件系统 per-asset 状态、权限 600、mtime 同步、清空 defaults 域)全部无效 —— 判定链在扩展内部(内存/私有逻辑),`fileExistsAtPath:` 与 `LastAerialDownloadDate` 是可见线索但非充分条件
  - **1MB 播放成功(15:44、16:02)为不稳定事件**:同配置多次重启后扩展回退 Golden Gate(agent 默认),无法稳定复现
- **证据**:
  - 4K 预置(52MB)→ 0 帧无 FigAssetCreateWithURL;1MB 预置(E0685AC0 已记录)→ 曾播放成功
  - 新 asset(A1B2C3D4)Selected + png 下载后停住,视频永不读取
  - 状态重置后扩展 `Failed to download full length default aerial` + Golden Gate
- **影响**:
  - **注入路径的可靠性存疑**:播放成功依赖扩展内部状态(可能与 003 的下载记录/时序有关),正式工具需解决"资产就绪"的稳定触发
  - 管理层面(系统设置面板)✅ 独立于播放,仍可行
  - 4K 支持需要扩展的下载状态机制配合(让扩展完成真实下载,或逆向其判定)
- **基线恢复**:✅ 全部清理(image choice、8 videos、1 asset、defaults 恢复)
- **下一步**(实验 005 方向,需不同方法):
  1. 逆向扩展"资产就绪"判定(内存/私有存储,可能需要 dtruss/断点/更长日志窗口)
  2. 尝试让扩展完成一次**真实下载**(解除 time budget 节流:等待、前台触发、或系统设置面板中选择)
  3. 若 4K 不可行,评估注入路径在生产环境的可靠性边界(1MB 短片的稳定触发条件)

---

## 实验 004 补充:URL-changed 机制定位 + time budget 耗尽

- **日期**:2026-08-30
- **结论**:**URL-changed 的判定载体是文件 xattr `SourceURL`**(扩展下载时写入,比较 manifest url);但多次下载尝试后 **time budget 耗尽**,扩展不再发起虚拟下载(无 `Starting download of`),稳定回退 Golden Gate —— 003/004 的成功是预算窗口内事件。
- **证据**:
  - 系统视频 xattr 含 `SourceURL`(sylvan url)、`LastETag`、`com.apple.quarantine`(WallpaperAerialsExtension)
  - 实验 002 替换文件(无 xattr)触发 `Re-downloading URL changed` = SourceURL 不匹配
  - 伪造 SourceURL xattr / 清空 asset categories / 伪造 LastAerialDownloadDate / choice 变化触发 → 全部无效(预算已耗尽)
- **影响**:
  - 预置文件注入的可靠性由 time budget 窗口决定,非配置可控
  - 真实下载路径(让扩展完成下载)是绕过预算的候选,但需前台触发或预算恢复
- **基线恢复**:✅
- **下一步**:
  1. 等待预算恢复(数小时/重启/重新登录)后复测
  2. 构建 livid 完整 app(macOS 26+ 声明)实测其全功能流程是否绕过节流
  3. 或接受"预置注入有时效窗口"的现实,文档化为已知限制
---

## 实验 004.5:截流窗口(time budget)存在性验证

- **日期**:2026-08-30
- **提交**:(随本次 commit)
- **结论**:**截流窗口真实存在且重启/手动下载后仍生效** —— 扩展日志直接出现 `Not allowing background aerial downloads due to time budget`,从推断升级为实证;用户手动下载成功是**前台触发路径**(`retrieveIsChoiceDownloaded` + `download` 消息),不受后台预算限制,与注入的后台 acquire 路径不同。
- **机制**:
  - 后台下载节流:扩展 `asset-loader` 明确拒绝后台 aerial 下载(`Not allowing background aerial downloads due to time budget`),重启 agent/系统未重置该状态
  - 前台下载放行:用户在系统设置手动下载走前台消息路径,成功发起真实下载(17:53 `Downloading first asset`,拉到 68MB 后因网络 -1005 中断,与预算无关)
  - 预置文件分支:`Not downloading additional assets because there are enough` —— 本地已有视频时扩展判定"资产足够",不再发起资产就绪检查,预置文件无法被"全新"资产识别(004 结论修正:预置只避免下载,不建立就绪状态)
- **证据**:
  - override 正常:`AerialManifestLocalPathOverride is set; using ...` + `Did update manifest` + agent `Create new wallpaper in runtime: aerials`
  - 节流拒绝:`Not allowing background aerial downloads due to time budget`(重启后新扩展进程仍报)
  - 资产分支:`Not downloading additional assets because there are enough` + 8181 零请求
  - 回退:renderer 渲染 Golden Gate.mov(`Image cache lookup - url: .../Golden%20Gate.mov` + `Rendering with success`),非注入资产
  - 前台下载对比:17:53 `Begin asset download` + `Downloading first asset '00BA71CD...'` + `Starting download of` + 18:11 网络失败 -1005(期望 445MB 实收 68MB)
- **影响**:
  - 注入路径的后台下载依赖 time budget,重启不是恢复手段;`AerialManifestForceLocal` 等 override 组合未测试(预算耗尽前窗口内有效)
  - 管理层面(系统设置面板)依然独立可行(003 补充)
  - 4K/预置注入要稳定,需走前台触发路径或逆向资产就绪判定
- **基线恢复**:✅ image choice(exp001 干净基线)、8 videos、entries 1 asset、defaults override 删除、8181 停止;exp004 脏备份(内含 aerials choice)已用 exp001 覆盖修复
- **下一步**(实验 005 方向):
  1. 测试 `AerialManifestForceLocal` / `AerialManifestURLOverride` 组合是否绕过 time budget
  2. 逆向"资产就绪"判定链(内存状态/dtruss)
  3. 构建 livid 完整 app 实测其全功能流程
---

## 实验 004.5 补充:代理网络根因 + 前台下载完成实证

- **日期**:2026-08-30
- **提交**:521bcab(随 005 设计 commit)
- **结论**:**用户手动下载失败根因 = FlClash 系统代理拖垮 sylvan 下载;关闭代理后前台下载完整成功(445399708 字节,与期望精确一致),资产获得完整就绪状态并稳定播放** —— 004 部分"失败"混入代理网络因素,需重新分层。
- **根因/机制**:
  - FlClash 规则 `DOMAIN-KEYWORD,apple` → Apple 组(US 代理)→ sylvan.apple.com 下载走代理
  - 扩展下载连接日志:`nw_flow_connected [127.0.0.1:7890 ... uses wifi, proxy]` —— 全程走系统代理(HTTP/HTTPS/SOCKS 全指向 7890)
  - 速度量化:同文件直连 **2.6MB/s** vs 代理 **46KB/s**(差 56 倍);445MB 代理下需 ~2.6 小时,17 分钟连接中断(-1005),实收 68MB
  - manifest 更新 404 两次也出自代理响应
- **证据**:
  - 关闭 FlClash(系统代理 HTTP/HTTPS/SOCKS 全 disabled)后:自动重试下载 18:18 发起 → 突飞猛进 → **18:22 完整落盘**
  - `videos/00BA71CD-2C54-415A-A68A-8358E677D750.mov` = 445399708 字节,全套 xattr:`SourceURL`(sylvan 官方 url)+ `LastETag` + `com.apple.quarantine`(WallpaperAerialsExtension)
  - 下载完成后 Index.plist Desktop 自动切到该 aerials asset,agent `Wallpaper updated in runtime` + `Rendering with success` + 3840×2160 帧 enqueued/displayed —— **就绪资产稳定播放**
- **影响**:
  - **004 结论重新分层**:time budget 节流真实存在(004.5 已直接证实),但 004 观察到的"下载失败/回退 Golden Gate"可能混入代理网络失败;003/004 窗口内成功与窗口外失败,网络因素不可忽略
  - **资产就绪的钥匙实证**:前台下载路径不受节流,网络正常即可真实完成下载 → 扩展建立完整"已下载"状态(文件 + xattr)—— 这正是预置注入缺失的"就绪"前提
  - 修复方案落地:`~/Projects/clash-rules/apple-direct.yaml`(sylvan.apple.com 等 Apple 域名直连规则)
- **基线恢复**:✅ image choice、8 videos(00BA71CD 已删)、entries 1 asset、defaults override 已删
- **下一步**(实验 005 方向,已设计):
  1. 让扩展**前台下载我们的打补丁文件**(override manifest url → 8181 patched)→ 资产同时获得"就绪"+"打补丁内容",无需替换、不触发 URL-changed
  2. 阶段 A 对照(后台注入仍被节流)→ 阶段 B 前台触发(程序化优先)→ 阶段 C 播放/重启稳定验证

---

## 实验 005:后台注入穷举确认不可用 + override 覆盖 fallback 有效(部分)

- **日期**:2026-08-30
- **提交**:(随本次 commit)
- **结论**:**后台注入路径在所有 override 组合下均被 time budget 拦截,彻底确认不可用;但发现 override manifest 覆盖 fallback 资产有效 —— 扩展接受覆盖资产并下载其缩略图(不受节流),视频下载通道受节流**。
- **机制**:
  - `there are enough` 分支:fallback manifest 本地视频已足时,扩展跳过资产就绪检查,不识别任何 override/预置资产
  - 缩略图 vs 视频下载分通道:缩略图下载不受 time budget(`Completing download successfully`),视频下载受(`Not allowing background aerial downloads due to time budget`)
  - 003 的"就绪"状态(下载记录)不可复现:E0685AC0 同配置不再生效,证明就绪依赖时序性下载记录
- **证据**:
  - override 覆盖 4207734D( fallback 资产)→ 扩展 `Starting download of` + 连接 127.0.0.1:8181 + `GET /mwi_test4.png` + `Completing download successfully`(缩略图);视频仍被 time budget 拦
  - 7 组组合(资产 × override × 预置/file://)全部 `there are enough` + time budget + 回退 Golden Gate
  - 面板 UI 自动化受阻:系统设置主内容区 AX 树空白,无法程序化点击
- **影响**:
  - 后台注入作为生产路径否决;前台手动下载(004.5)是唯一建立就绪的途径
  - override 覆盖 fallback 资产 = 面板可见性/缩略图注入的可行通道(管理层面)
  - 下一步:前台手动下载系统资产 → 就绪 → 替换文件保留 xattr / override 覆盖 url,验证播放打补丁内容
- **基线恢复**:✅ image choice、8 videos、entries 1 asset、defaults 无 override、8181 停止、agent 重启
- **下一步**(实验 006 方向):
  1. 用户手动下载系统资产(网络已修复)→ 就绪 → 替换文件保留 xattr → 验证播放
  2. 或 override 覆盖已就绪资产 url → 8181 打补丁文件

---

## 实验 005 补充:对照实验推翻"time budget 是注入失败主因"

- **日期**:2026-08-30
- **结论**:**time budget 不是注入失败的原因;真正机制是 `there are enough` 省流量设计 —— 本地已有视频时扩展不下载新视频,改用本地已有视频顶替选中资产播放**。time budget 机制存在性仍无法证实(二进制仅日志串 + `AerialBackgroundDownloadPolicy` 类名,无存储/计数器)。
- **对照实验**(用户质疑后设计,注入系统真实资产):
  - 4DFE24ED(DYNAMIC 组合,非纯视频):下载资源(0.185s,非视频),无 time budget
  - 6511D2B5(GG_A_DAY 纯视频,结构等同已下载 4207734D):`Selected aerial ids did change: [6511D2B5]` 识别 ✅ → `Not downloading additional assets because there are enough` → **播放本地 videos/4207734D.mov 顶替**
  - 对比:注入资产 A1B2C3D4 同分支,但本地无对应文件 → 回退 Golden Gate
- **机制**:
  - `there are enough` = 本地 videos/ 已有视频时,扩展跳过新视频下载,用本地文件顶替选中资产
  - 系统资产能顶替(本地有文件),注入资产不能(无对应本地文件)
  - time budget 日志在纯视频拦截中不出现 —— 它伴随 `there are enough` 出现但非拦截原因
- **影响**:
  - 注入策略转向"顶替"路径:打补丁文件以正确文件名存在于 videos/ → 扩展选中对应资产时直接播放
  - 之前"下载就绪"是唯一路径的判断错误;003 成功可能就是顶替路径(预置 E0685AC0.mov 被播放)
- **基线恢复**:✅ image choice(exp001)、8 videos(删除测试下载的 11AB4259.mov)、缩略图系统自动恢复

---

## 实验 006:探究 `there are enough` 触发条件

- **日期**:2026-08-30
- **结论**:**`there are enough` 的判定与磁盘文件数、initialAssetCount 均无关 —— 它是 manifest 层面对"初始资产(系统默认动态壁纸)"的静态判断;DYNAMIC 组合资产(有 variant)不受其限制、永远下载,纯视频资产(附加内容)被其拦截**。
- **实验过程与证据**:
  - 用例1(DYNAMIC C6AECFD2 注入):`Selected aerial ids` + `Starting download of` + 下载 731140AB(DYNAMIC_DARK 组配对视频)+ `Rendering with success` —— **无 "enough"**
  - 用例2(本地视频 8→4,注入 6511D2B5):仍 `there are enough`
  - 用例3(本地视频 8→0,注入 6511D2B5):仍 `there are enough`,且扩展仍播放"记忆中的" videos/4207734D.mov(image-cache 引用已移走的文件)—— 证明**已下载清单是扩展内存态(ActiveAerialWallpaperRegistry),非磁盘实时扫描**
  - initialAssetCount=0 override:仍 `there are enough` —— manifest 字段无关
  - 同时观察到 `there are enough` **之后**才出现 `Not allowing background... due to time budget` —— time budget 是第二层检查,再次印证非主因
- **机制推断**:
  - DYNAMIC 4 资产(4DFE24ED 等)= fallback 的初始资产(系统默认 macOS 动态壁纸),扩展对其特殊处理:始终尝试下载(组内配对,如 C6AECFD2↔731140AB)
  - 纯视频资产 = 附加内容,受 "enough" 拦截;判定基准是 fallback manifest 的初始资产状态,非磁盘文件
  - 系统回退壁纸 = `/System/Library/Wallpapers/.default/Golden Gate.mov`
- **影响**:
  - "enough" 是 macOS 27 的**附加内容省流量设计**:默认壁纸(初始资产)就绪后不再自动下载更多 aerials 视频
  - 注入路径含铁门槛:纯视频资产无法通过后台触发下载;"顶替播放"依赖扩展内存中的已下载清单
  - 前台路径(004.5)仍是唯一绕过点
- **基线恢复**:✅ 8 videos、image choice、override 已清、DYNAMIC 污染缩略图已删

---

## 实验 006 补充:显式 vs 后台操作的判定机制 = 消息通道信任(进程级)

- **日期**:2026-08-30
- **结论**:**系统不"识别"用户操作,而是信任 System Settings 面板进程的消息通道** —— 显式操作 = 面板发起的消息流,后台操作 = agent 文件变更检测路径;两者走完全不同的消息序列。
- **证据(消息序列对比)**:
  - 前台(004.5 用户手动):agent 收到 `updateDesktopWallpaperUserSettings` + `registerSettingsObserver` + `ensureViewModelIsUpToDate`;扩展收到 `retrieveIsChoiceDownloaded` + `download` + `provideSettingsViewModels` → 下载成功
  - 后台(006 注入):agent 无面板消息;扩展只收 `selectedChoicesDidChange` + `acquire` → `there are enough` 拦截
- **机制**:
  - 面板进程(System Settings)持有到 agent 和扩展的 XPC 连接;只有用户点击才发 `updateDesktopWallpaperUserSettings`(→agent)和 `downloadAsset(withID:)`(→扩展)
  - 面板 = 用户意图的**进程级凭证**(签名系统进程),非内容标记;沙盒/签名阻止伪造其 XPC 连接
  - 改 Index.plist 只触发 agent 文件监听 → 扩展被动 `selectedChoicesDidChange`,无面板消息 → 纯后台策略(初始资产足够 → 不下载附加)
- **影响**:
  - 注入要伪装"显式"必须经由面板进程的 XPC 通道(不可伪造)
  - 003 成功疑因当时恰好有面板交互(选择/下载 E0685AC0)
  - 后续方向:模拟面板 XPC 消息流(需破解面板↔agent/扩展协议)或接受"用户手动选择"作为唯一触发

---

## 实验 007:面板程序化选择 = 完整注入闭环成立 ✅

- **日期**:2026-08-30
- **结论**:**macOS 27 上任意视频注入 aerials 壁纸的完整自动化路径已打通:override manifest 顶替 fallback 资产 → 破宿主设置缓存 → 面板显示 → 合成点击 → 前台通道下载 → 就绪播放**。"there are enough" 只拦后台通道,面板(前台)选择不受限。
- **注入流程(全自动)**:
  1. 打补丁视频 + 缩略图放本地 http 服务器(或 file://)
  2. override manifest:fallback 完整清单 + **顶替一个本地未下载的 fallback 资产**(改名 localizedNameKey + 改 url 指向我们的视频,id 保持 fallback 原 id)
  3. 删宿主设置模型缓存(`/var/folders/.../C/com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache/extension-com.apple.wallpaper.extension.aerials-desktop`)+ killall WallpaperAgent
  4. 打开面板,AX 定位顶替资产(名字 = 我们的 localizedNameKey),合成点击
  5. 扩展走前台通道:`Begin asset download → Downloading first asset → Completing successfully → Completed downloading representative asset` → 落盘 videos/<assetID>.mov → choice 写入 → VideoPlayer ready
- **关键机制**:
  - 面板模型(SettingsProvider)用 override manifest,**但资产按 fallback id 白名单过滤** —— 新增 id 不可见,顶替已有 id 可见
  - 分类白名单:categories 数组不能新增(新分类被忽略,资产回落原分类)
  - 宿主设置缓存跨重启持久,删缓存+重启 agent 强制重查(phosphene issue #27 同款)
  - 合成点击(CGEvent)+ AX 定位 = 面板程序化驱动(需辅助功能权限)
  - 扩展处理 choice 时从 override 找资产:顶替资产 URL 指向本地源 → 下载即拷贝
- **已验证闭环产物**:videos/6511D2B5-….mov = mwi_test3_patched.mov 精确字节(1005931),choice = aerials + assetID
- **未完成**:渲染帧日志(first video frame/Rendering with success)未捕获(6s 小视频 + 可能时序);4K 长视频端到端播放验证待做
- **基线恢复**:✅ 8 videos、image choice、override 已清、8181 已停

---

## 实验 007 补充:面板模型机制根因(白名单防火墙)与路线决策

- **日期**:2026-08-30(007 成功后继续深挖)
- **背景**:007 成功证明"顶替 + 面板点击"闭环可行;但用户要求探索"不顶替官方资产、新建独立分类"的可行性,及 fallback 结构能否修改 —— 系列测试揭示面板模型的完整机制。
- **面板模型构建机制(SettingsProvider)**:
  1. **结构 = override 控制**:纯注入 override(1 资产 1 分类)→ 模型从 7 组 166 项变为 1 组 1 项(仅硬编码 Shuffle All)。证明 SettingsProvider 读 override,非 fallback 全量。
  2. **资产 id 白名单(防火墙核心)**:override 中 id 不在 fallback 的资产一律被过滤(新增 d4fc948a、E0685AC0 均不显示;顶替 4207734D/6511D2B5 显示)。模型 = fallback 164 id × override 属性覆盖。
  3. **分类白名单**:override categories 新增条目被忽略(不生成新组);资产引用未知分类时回落原分类。
  4. **修改资产 categories 破坏整个覆盖**:顶替资产改分类 → 连改名都失效(回落 fallback 原名),仅 URL/缩略图生效。
  5. **宿主设置模型缓存**(phosphene issue #27 同款):`/var/folders/.../C/com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache/extension-com.apple.wallpaper.extension.aerials-desktop`,跨重启持久;删缓存 + killall WallpaperAgent 强制重查。
- **phosphene 调研结论**:自建扩展(phosphene 模式)与 aerials 在"管道层"(宿主/面板/分配/锁屏)一致,但**播放行为层必须自实现,只能接近原生**(用户亲历 phosphene 行为不一致);且私有框架脆弱(dlopen + Mirror 反射)。**注入路线让 aerials 扩展自己播放 → 行为原生**,是"行为一致"需求的天然优势。
- **决策(用户拍板)**:保持注入方案,攻破 aerials 的白名单防火墙;不走自建扩展路线。
- **白名单防火墙攻破方向(候选,供实验 008)**:
  a. 逆向 SettingsProvider 白名单数据源(运行时读什么:fallback bundle 路径?内存?)
  b. 检查 override 能否影响 fallback 加载路径(AerialManifestLocalPathOverride 只覆盖 asset loader?SettingsProvider 的 fallbackAssetsURL 可否被影响)
  c. 用户 entries.json 是否参与 SettingsProvider(已验证不进模型,确认排除)
  d. 动态分析 SettingsProvider 构建模型的输入(fs_usage/dtruss 观察读文件)
  e. id 匹配细节:大小写/格式变体是否绕过
- **基线恢复**:✅ 8 videos、image choice、override 已清、8181 已停

---

## 实验 008:攻破 aerials 白名单防火墙 ✅(完整注入闭环,无需顶替)

- **日期**:2026-08-30
- **结论**:**全新资产(非 fallback id)可通过"字段克隆"进入面板模型并完成下载播放 —— 白名单防火墙攻破,注入不再需要顶替官方资产。**
- **防火墙真实机制(推翻 007 的"id 白名单"假设)**:
  - 面板模型(SettingsProvider)= 遍历 manifest 资产 + 过滤**字段不完整**的资产,而非"id 必须在 fallback"
  - 新资产失败原因:subcategories=[] / shotID 自定义等字段缺失或不匹配 → 被过滤
  - **攻破条件:新资产完整克隆 fallback 资产的结构字段(subcategories 引用 fallback 子分类 UUID、shotID、includeInShuffle、preferredOrder、showInTopLevel、pointsOfInterest 等),仅 id 和 URL/名字不同**
- **manifest 源(可写!)**:用户 `~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json` = "downloaded manifest",扩展日志 `Loading downloaded manifest` 确认加载;**完整 fallback 结构时被接受(改名/删除/新增生效),纯新资产清单被拒(回落 fallback)** —— 攻破载体 = 用户 entries.json(可写)
- **完整闭环验证(全新资产 d4fc948a)**:
  1. entries.json = fallback 完整清单 + d4fc948a(克隆 6511D2B5 字段,URL=本地 http)
  2. 删宿主缓存 + 重启 agent + 开面板 → 缓存模型含 MWI Clone(d4fc948a, Landscape/Golden Gate 子分类)
  3. AX 滚动定位 + 合成点击 → 前台通道:`Begin asset download 'd4fc948a'` → `Downloading first asset` → `Completing successfully` → `Completed downloading representative asset`
  4. 落盘 videos/d4fc948a-….mov = 1005931 字节(精确匹配源视频)+ choice 写入(aerials + d4fc948a)+ VideoPlayer ready ×2
- **与 007 顶替方案的关系**:007 顶替(借 fallback id)依然可用,但 008 证明**不需要顶替** —— 全新 id + 字段克隆即可。注入形态升级:任意视频 = 全新资产(自己的 id/名字/URL),面板显示自己的名字,播放 aerials 原生
- **关键攻破点**:
  - 用户 entries.json(可写)= SettingsProvider 结构源(downloaded manifest)
  - 新资产必须满足字段结构校验(subcategories 引用合法子分类等)
  - 宿主设置缓存跨重启(删缓存 + killall agent 强制重查)
  - 前台通道(面板点击)下载,不受 "there are enough" 拦
- **基线恢复**:✅ 8 videos、image choice、entries.json 复原(1 资产)、8181 已停

---

## 实验 008 补充:mov_patcher 基础 bug 修复 + 4K 端到端验证 ✅

- **日期**:2026-08-30(008 攻破后继续)
- **背景**:4K 端到端验证发现扩展仅 VideoPlayer ready、解码器空闲 —— 定位到**补丁文件 AVFoundation 不可读(tracks=0)**,且 003 的"播放成功"无法重现(仅 ready,无帧)。
- **根因(mov_patcher.py 两处 bug)**:
  1. **stbl 重排破坏顺序**:原实现按 STBL_ORDER(Apple 顺序)重排,把 ctts 移到 stss/sdtp 前 —— AVFoundation 对 FFmpeg 风格文件(ctts 在后)顺序敏感,重排后 0 轨道。**修复:保持原始顺序,仅在 stsd 后插 sgpd/csgm、stco 前插 cslg**
  2. **csgm 缺 Apple 8B 头**:Apple 原厂 csgm 在 sampleCount-1 后有 2 个 u32(0x0f,0x0f),原实现缺失 → 解析失败。**修复:build_csgm 补 `(sampleCount-1, 15, 15)`**
- **验证**:
  - AVFoundation:小视频/4K 补丁文件 videoTracks=1 + AVAssetReader 可读 sample ✓(修复前 0 轨道)
  - 扩展真实播放(预置 + choice 注入):`startReading callback: success` + `Handling frame during still` + **`Snapshot succeeded. Saving to cache`**(快照需渲染画面,强证据)✓ 小视频 + 4K 均成功
  - 003 的"Rendering with success"未重现,但快照成功 = 渲染成立(日志时机/级别差异)
- **4K 端到端(修复后)**:3840×2160/30s 资产,预置播放成功(startReading success + snapshot ×3)
- **附带澄清**:003 时代补丁文件同样不可读(结构对齐≠可播放),003 播放证据不可靠;修复后为真正可播
- **基线恢复**:✅ 8 videos、image choice、entries.json 复原、8181 已停

---

## 工具固化:inject.py 完整注入工具链 ✅

- **日期**:2026-08-30
- **内容**:`scripts/inject.py`(主工具)+ `scripts/ax_select.swift`(面板 AX 定位点击)
- **子命令**:prepare(转码/打补丁/缩略图/entries.json 注入/起 http)→ refresh(破缓存+重启+开面板)→ select(AX 定位+合成点击)→ status(验证下载/循环播放/快照)→ restore(恢复基线)
- **验证**(完整链路实测):prepare 165 资产注入 → refresh 模型含资产 → select CLICKED → status 全绿(downloaded ✅ startReading ✅ looping ✅ snapshot ✅ → PLAYING ✅)→ restore 基线完整(8 videos/entries 1/image choice/server 停)
- **播放确认**:6s 视频每 6s 循环 StartReading(success 回调重复)= 持续循环播放,强于单次快照证据
- **转码规格**(IMPLEMENTATION_RESEARCH 提炼):libx265 medium crf18,keyint=60/min-keyint=60/scenecut=0/bframes=4/b-adapt=2/b-pyramid=1/temporal-layers=3,pix_fmt yuv420p10le,main10,hvc1,BT.709,timescale 240000
- **基线恢复**:✅ 8 videos、entries.json 复原、image choice、8181 停

---

## 实验 008 补充:sgpd/csgm 内容对 aerials 播放的影响 ✅(无影响)

- **日期**:2026-08-30
- **结论**:**sgpd/csgm 的内容不影响 aerials 扩展播放** —— 扩展二进制不含 tscl/tsas/csgm/sgpd 处理字符串(扩展不读);简化 sgpd([0,dur,1,0,128]×5)与 Apple 对齐 sgpd(递增结构)播放行为完全相同。
- **验证**:
  - 扩展二进制 strings:无 tscl/tsas/csgm/sgpd 引用(时间分层处理在 CoreMedia/VideoToolbox 内部或未用)
  - 简化 sgpd 播放:PLAYING ✅(downloaded/startReading/looping/snapshot)
  - Apple 对齐 sgpd(从系统 4207734D 提取模式:entry=[0x0022fc00+n*0x01000000, 0xf000, 0, 0xb70000, 0]×5)播放:完全相同 ✅
  - 视频 6s 正常循环(节奏正常,无慢动作异常)
- **系统 sgpd tscl 结构**(4207734D):头 24B(size/type/verflags=1/group_type/entry_size=20/entry_count=5),5×20B entry 递增结构
- **与 csgm 的关系**:csgm 8B 头是 AVFoundation 解析的结构必需(缺失→0 轨道,已修复);csgm payload(从 NAL temporal_id 生成)被接受
- **含义**:mov_patcher 的 sgpd 简化实现可保留(无功能影响);csgm 结构必须对齐 Apple(8B 头)
- **基线恢复**:✅ 8 videos、entries 1、image choice、server 停

---

## 实验 008 补充:B 验证 — 长视频循环 + 锁屏壁纸 ✅

- **日期**:2026-08-30
- **长视频持续循环**:4K 30s 资产注入 → 下载(54618788B 精确)→ 播放 → **startReading 间隔 30.9s = 完整循环**,无 renderer 销毁;status 全绿(downloaded/startReading/looping/snapshot)
- **锁屏壁纸**:CGSession 已移除(macOS 27),用 Control+Command+Q 锁屏 → 扩展收到 `Presentation Mode: 'default' -> 'locked'` → **`Play Called` + `Switch to .rampingUp` + startReading success + Media data request** —— 注入资产作为锁屏壁纸播放,带渐入动画(与 aerials 原生锁屏行为一致);解锁恢复 default
- **select 可靠性**:首次点击可能落空(面板滚动动画未完成坐标漂移),重试即成功 —— 工具已能处理(select 可重复执行)
- **多显示器**:环境仅 1 屏,无法验证(记录为待验证,依赖多屏硬件)
- **基线恢复**:✅ 8 videos、entries 1、image choice、server 停

---

## 实验 008 补充:多显示器验证 ✅(用户观察)

- **日期**:2026-08-30
- **场景**:用户接入 iPad(Sidecar 随航)作为副屏;注入壁纸播放期间锁屏
- **观察(用户)**:锁屏时副屏(iPad)行为与主屏一致 —— 均显示注入壁纸
- **结论**:macOS 壁纸系统对多显示器统一分配(choice → agent → 每屏 acquire),注入资产在副屏正常渲染(无黑屏/回退);多显示器核心行为验证完成
- **未测**:per-display 独立选择(副屏选不同壁纸)—— macOS 功能层行为,注入资产遵循系统规则,非工具范围
- **基线**:✅ 8 videos、entries 1、image choice、server 停

---

## 状态快照:研究结论汇总 + 下一步(新建独立分类)

- **日期**:2026-08-30
- **已完成(全部实证)**:
  1. 注入链路闭环:任意视频 → 转码/打补丁 → entries.json 注入(字段克隆,白名单攻破)→ 破缓存 → 面板点击 → 前台下载 → aerials 原生播放 ✅
  2. 播放验证:小视频/4K 循环、锁屏(rampingUp 渐入)、多显示器(Sidecar iPad 锁屏一致)✅
  3. 机制:白名单=字段完整性(12 必需字段可克隆);用户 entries.json=可写 manifest 源;宿主设置缓存可破;sgpd 内容无影响;csgm 8B 头必需;mov_patcher 修复后 AVFoundation 可读 ✅
  4. 工具:inject.py(prepare/refresh/select/status/restore)+ ax_select.swift,端到端验证 ✅
- **当前限制**:**注入资产均使用 Landscape 分类模板**(6511D2B5 字段克隆,categories=A33A55D9),面板显示在 Landscape 分类下
- **下一步(用户要求)**:**新建独立分类** —— 让注入资产显示在自建分类(而非挤占 Landscape);需研究 override categories 白名单的绕过(008 曾测:新增分类条目被忽略,资产回落原分类;待重新攻破)
- **壁纸状态**:✅ 完全恢复系统默认(entries.json 仅 E0685AC0 历史残留、模型=fallback 原始 7 组、注入缩略图已删、image choice、8 videos)

---

## 壁纸完全恢复:封面污染清理(用户指出 Golden Gate 缩略图仍是 test4)

- **日期**:2026-08-30
- **问题**:实验时顶替资产(4207734D/6511D2B5)previewImage 指向 mwi_test4.png,扩展把 test4 下载为 thumbnails/<id>.png,**覆盖了系统资产的真实封面**
- **污染文件**(1167863B = test4):4207734D.png、6511D2B5.png(系统资产封面被覆盖)+ A1B2C3D4.png(003 注入资产)
- **恢复**:删除污染 png → 系统自动重新下载真实封面(4207734D=45KB/6511D2B5=37KB,md5 与 test4 不同)
- **验证**:
  - test4 大小文件:0 残留
  - 系统资产封面:4207734D/6511D2B5 自动恢复 ✓
  - 面板:Golden Gate/Tahoe 显示正常,无注入资产
  - 非资产缩略图(子分类封面,如 67512508/17647EAB)为系统正常文件
- **机制确认**:删除 thumbnails/<id>.png 后,扩展自动从 sylvan 重新拉取系统封面(004.5 已见,本轮复现)
- **基线**:✅ 完全恢复(entries=exp001 一致、模型=fallback、封面=系统、8 videos、image choice)

---

## 基线规范(exp009,刷新):恢复目标 + 缩略图还原要求

- **日期**:2026-08-30(用户澄清)
- **恢复目标(exp009 基线)**:
  - Index.plist:**image choice = 用户图片(脱敏)**(非 default;面板操作曾改为 default,已恢复)
  - entries.json:1 资产(E0685AC0)
  - videos/:8 个系统 mov
  - override:无
  - **缩略图:必须还原** —— 实验会污染 thumbnails/(注入资产 png、test4 覆盖系统封面),基线恢复时必须清理
- **缩略图还原规范**:
  - 删除注入资产缩略图(thumbnails/<注入assetID>.png)
  - 删除被 test4 覆盖的系统资产封面(1167863B 文件:4207734D/6511D2B5)
  - **封面自愈机制**:删 thumbnails/<id>.png → 系统自动从 sylvan 重新下载真实封面(已验证)
  - 子分类缩略图(67512508 等)为系统正常文件,勿删
- **inject.py restore 增强**:需加入缩略图清理(从 STATE 读 asset_id 删 thumbnails/<id>.png)
- **基线位置**:backup/exp009/(Index.plist.baseline = image 用户壁纸 + entries.json.baseline)

---

## 实验 009:新建独立分类(资产归入自建分类)✅ + url-4K 下载源发现

- **日期**:2026-08-30
- **目标**:注入资产显示在自建分类(MWI 独立分类),而非挤占 Landscape
- **结论**:**分类条目完整克隆 Landscape 模板(7 字段必需:id/localizedDescriptionKey/localizedNameKey/preferredOrder/previewImage/representativeAssetID/subcategories)即可被面板接受为新分类**
- **独立分类方案(最终采用):全新子分类**(修正早期"subcategories 必须引用 fallback 子分类 67512508"的结论):
  - 新分类 subcategories = [全新子分类(克隆 67512508 Golden Gate 结构,新 id)] → 分类独立显示
  - 资产 categories=[新分类 id] + subcategories=[全新子分类 id] → **资产只在新分类,Landscape 完全不含(双归属消除)**
  - 模型验证:MWI 独立分类 items=1(只含注入资产),Landscape items=83 含MWI=0,其余分类无 MWI
  - 早期"全新子分类 → groups=0"为误判(当时资产未正确关联新子分类);全新子分类 + 资产关联后完全可用
- **机制要点**:
  - 新分类克隆 Landscape(id/localizedNameKey 改,其余字段保留,representativeAssetID 可保留模板值)
  - 资产归入:categories=[新分类 id] + subcategories=[新分类的全新子分类 id] → 完全独立
  - 面板模型:新分类 groups 出现(items=84 含 MWI 资产),Landscape 同步含
  - 独立分类完整渲染:分类标题 + 资产按钮 + 自带 Shuffle 按钮
- **关键发现:url-4K-SDR-240FPS 是扩展实际下载源**(本次实验最大坑):
  - 008 时"URL=本地 http"改的是 **url-4K-SDR-240FPS** 字段;inject.py 固化时只改了 `url` 字段 → url-4K 残留 sylvan GG_A_DAY URL → **扩展下载 sylvan 442MB(4096×2160/300s,非注入视频)**
  - 症状:落盘 463906777(非源 1MB)、服务器 8181 无 GET、ffprobe 4096×2160/300s
  - 修复:asset["url-4K-SDR-240FPS"] = http://127.0.0.1:8181/<video> → 扩展 GET 8181 200、落盘 1005947(精确源)、startReading success
  - 删除 url-4K 字段 → 下载失败(DownloadError 0);url 字段单独存在不被扩展用于下载
- **面板滚动操作**(合成滚动踩坑):
  - 壁纸面板资产流**横向滚动,由垂直滚轮事件驱动**(触控板手势映射)
  - 合成 CGEvent 滚动须先**点击激活滚动区**(AXScrollArea,鼠标移入 y≈1000)+ wheel1 垂直滚动(每格 -300 生效)
  - 资产下载中 = AXProgressIndicator(desc=资产名,拦截点击),完成后恢复 AXButton
  - ax_select.swift(AX 树定位 + ScrollToVisible + 合成点击)在下载完成后可靠
- **inject.py --new-category 工具**:prepare 支持 `--new-category NAME`(克隆 Landscape 模板→新分类,资产归入 + subcategories=67512508);验证链路 prepare→refresh→select→status→restore 全通
- **恢复规范**:restore 恢复系统默认壁纸(不再引用用户本地图片)(prepare 时备份的 Index 可能含实验残留 choice,agent 重启会保留)
