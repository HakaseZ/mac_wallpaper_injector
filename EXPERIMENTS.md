# 实验记录 (EXPERIMENTS.md)

> 追踪注入测试实验。原则见 agent.md「实验原则」。
> 每次实验:记录基线 → 执行 → 验证 → **恢复至基线** → commit 本文档。
> 只保留当前实验内容;历史由 git commit 追踪。结论累积见 `EXPERIMENT_CONCLUSIONS.md`。

---

## 实验 008:攻破 aerials 白名单防火墙(设计)

### 背景

007 已验证完整注入闭环(顶替 fallback 资产 + 破宿主缓存 + 面板点击 → 前台下载 → aerials 原生播放)。但注入受**白名单防火墙**限制:面板模型只认 fallback 的 164 个资产 id,新增资产/分类被过滤。用户决策:**保持注入方案,攻破白名单防火墙**。

### 防火墙机制(已实证)

```
SettingsProvider 遍历 fallback 164 资产 id(白名单)
  → 从 override 查每个 id 的覆盖属性(名字/URL/缩略图)
  → 按 fallback 分类分组 → 模型
新增 id 资产 / 新增分类条目 / 修改资产分类 → 全部被忽略或破坏覆盖
```

- 结构(分类/组)= override 控制(纯注入测试:7 组 → 1 组)
- 资产 id = fallback 白名单(新增 d4fc948a/E0685AC0 不显示,顶替显示)
- 宿主缓存跨重启持久(删缓存 + 重启 agent 强制重查)

### 攻破方向(候选,按优先级)

**A. 定位白名单数据源(最优先)**
- SettingsProvider 构建模型时读什么?fallback 是扩展 bundle 的 entries.json(SIP 保护),但**运行时加载路径**可能可被影响(环境变量/默认值/override 扩展字段?)
- 方法:fs_usage 或 dtruss 观察扩展构建模型时打开的文件;检查二进制中 fallbackAssetsURL 的构造

**B. 检查 override 的 fallback 加载影响**
- AerialManifestLocalPathOverride 已确认影响 asset loader;是否也影响 SettingsProvider 的"白名单来源"?纯注入测试显示结构变化(override 分类生效),说明 SettingsProvider 读 override —— 那白名单从哪来?是 fallback 还是 override 与 fallback 的交集?
- 决定性测试:override = fallback 复制 + 删除几个资产 + 新增几个 → 模型 = 删除的消失 + 新增的过滤?(验证"override 结构 + fallback id 白名单")

**C. 用户 entries.json 角色(排除确认)**
- ~/Library/.../manifest/entries.json 已验证不进面板模型;但扩展日志有 "Loading downloaded manifest" —— 确认它是否参与 SettingsProvider

**D. id 匹配细节**
- 大小写/格式变体(fallback 用大写 UUID,注入用大写;试小写/其他格式是否绕过精确匹配)

**E. 动态分析**
- 若 A 无果:dtruss 断点 SettingsProvider 构建函数,看白名单集合来源

### 成功标准

注入**全新 id 资产**(非顶替)出现在面板模型 = 白名单攻破;或确认防火墙不可破(记录硬边界)。

### 基线

| 项 | 状态 |
|---|---|
| 日期 | 2026-08-30;git @ 30c74e5 |
| 壁纸 | image choice |
| videos/ | 8 个系统 mov |
| override | 已清 |
| 8181 | 已停 |
