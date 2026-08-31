# Changelog

本项目的所有显著变更记录于此,格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/),版本遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Fixed

- e2e 增加干净基线保护:检测到已有注入资产(用户壁纸)立即中止,防止 restore 误删

## [1.0.0] - 2026-08-31

首次正式发布:把任意视频注入为 macOS Aerial 动态壁纸的原生管理面板。

### Added

- 原生 Swift(AppKit)管理面板 MWIPanel:添加壁纸 / 删除 / 重命名 / 刷新 / 日志导出
- 任意视频自动转码为 Aerial 合规 HEVC 10bit(帧率归一、HDR→SDR tonemap、奇数分辨率偶数化)
- MOV atom 补丁(tapt/sgpd/csgm/cslg),兼容多轨视频与任意容器格式
- 注入资产独立分类(克隆模板 + 全新子分类,不混入系统 Landscape 资产)
- 并发注入,转码全局限速(CPU 占用 ≈ 单转码,不发热)
- 下载源全面 file:// 本地预置(不依赖网络与系统代理)
- 重命名自动同步系统壁纸设置(清缓存 + 重启 agent)
- 删除/恢复后回归系统默认动态壁纸
- AGPL-3.0 许可证(含概念参考项目 MIT 归属说明)

### Fixed

- 移除机器专属绝对路径(系统缓存目录改为运行时推导)
- 注入备份改到用户可写目录,不再依赖构建机路径(修复其他机器上注入失败)
- 缩略图 16:10 等比居中裁剪渲染(无变形无黑边)
- MOVPatcher 多轨视频补丁后 AVFoundation 不可读
- 视频转换全格式兼容(覆盖所有容器/编码/规格)

### Security

- 清除仓库历史中的本地绝对路径、用户名与实验备份(脱敏)

### Tests

- 沙箱单元/集成测试 114 断言(MOVPatcher / manifest / 转码链路 / HTTP 服务 / 缩略图),不触碰真实系统壁纸状态
- 系统级 e2e 18 断言(注入/选择/播放/持久性/删除/恢复),门控运行(`./tests.sh e2e`)

[1.0.0]: https://github.com/HakaseZ/mac_wallpaper_injector/releases/tag/v1.0.0
