# Remote RuleSet 全局架构重构方案

## 背景

当前项目已经存在完整的 RuleSetRepository 子系统：

- 下载
- 校验
- 缓存
- 版本管理
- failurePolicy
- 回滚
- 可用性判定

但 VPN 启动链路仍直接向 sing-box 下发 remote rule_set。

结果是：

```text
RemoteRuleSet
    ↓
ConfigBuilder
    ↓
sing-box remote rule_set
    ↓
启动时联网下载
```

而不是：

```text
RemoteRuleSet
    ↓
RuleSetRepository
    ↓
本地缓存
    ↓
ConfigBuilder(local rule_set)
    ↓
启动
```

因此形成两套资源管理体系并存的问题。

---

# 当前架构问题

## P1 首次下载失败导致 VPN 启动失败

场景：

- GitHub 不可达
- DNS 异常
- TLS 失败
- URL 配错

当前配置仍会生成：

```json
{
  "type": "remote",
  "url": "https://xxx"
}
```

VPN 启动时由内核即时下载。

结果：

```text
规则集失败
    ↓
内核启动失败
    ↓
VPN 整体失败
```

---

## P1 RuleSetRepository 未真正生效

当前已实现：

- getAvailability()
- cachedFilePath()
- ensureResource()
- failurePolicy

但 VPN 主链路未使用。

属于半迁移状态。

---

## P1 资源生命周期不统一

项目当前存在三套机制：

### Geo Assets

remote + initial_path

### Remote RuleSet

sing-box remote

### RuleSetRepository

本地仓库模式

三套行为不一致。

---

# 目标架构

统一资源生命周期。

```text
                ResourceResolver
                       │
       ┌───────────────┼───────────────┐
       │               │               │
       ▼               ▼               ▼
   GeoSite         GeoIP         RemoteRuleSet
       │               │               │
       └───────────────┼───────────────┘
                       ▼
              RuleSetRepository
                       ▼
                 local file
                       ▼
                ConfigBuilder
                       ▼
                 sing-box
```

原则：

启动阶段永远只使用本地文件。

启动阶段不得依赖网络。

---

# 第一阶段

## 扩展 RemoteRuleSet 模型

新增字段：

```ts
failurePolicy
format
lastSyncAt
cachedHash
```

建议：

```ts
failurePolicy:
  block
  allow-unverified
```

默认：

```ts
block
```

---

## 增加 ResourceResolver

新增：

```text
entry/src/main/ets/core/ResourceResolver.ets
```

职责：

统一管理：

- geosite
- geoip
- remote ruleset

接口：

```ts
prepareResources()
```

返回：

```ts
PreparedRuleSet[]
```

结构：

```ts
{
  tag,
  path,
  available,
  verified,
  fromCache
}
```

---

# 第二阶段

## VPN 启动前资源预处理

在 VpnExtAbility 中新增阶段：

```text
load settings
    ↓
prepareResources
    ↓
build config
    ↓
checkConfig
    ↓
startCore
```

替换当前：

```text
loadRemoteRuleSets
    ↓
buildCoreConfig
    ↓
startCore
```

---

## 下载策略

对于每个启用规则集：

```ts
RuleSetRepository.ensureResource()
```

结果：

### 已验证缓存

直接使用。

### 更新失败但缓存存在

继续使用缓存。

### 首次失败无缓存

标记 unavailable。

不允许进入配置生成。

---

# 第三阶段

## ConfigBuilder 禁止 remote rule_set

删除：

```json
{
  "type":"remote"
}
```

生成：

```json
{
  "type":"local",
  "path":"..."
}
```

规则：

```text
ConfigBuilder 不负责下载
ConfigBuilder 不负责联网
ConfigBuilder 只消费已准备资源
```

---

## 本地规则集定义

统一生成：

```json
{
  "tag":"remote_xxx",
  "type":"local",
  "format":"binary",
  "path":"cached.srs"
}
```

路由引用保持不变：

```json
{
  "rule_set":["remote_xxx"]
}
```

---

# 第四阶段

## 启动前配置校验

生成配置后：

```ts
CoreManager.checkConfig()
```

必须执行。

流程：

```text
build config
    ↓
checkConfig
    ↓
通过
    ↓
startCore
```

失败：

```text
不创建TUN
不启动VPN
直接向用户报告
```

---

# 第五阶段

## 后台刷新机制

VPN 启动后异步更新。

```text
VPN 已运行
    ↓
后台刷新规则集
    ↓
校验
    ↓
更新缓存
```

失败：

```text
保持旧缓存
```

不得影响当前会话。

---

# 第六阶段

## Geo Assets 统一接入 Repository

长期目标：

GeoSite
GeoIP
RemoteRuleSet

全部通过：

```ts
RuleSetRepository
```

管理。

最终删除：

```text
buildGeoRuleSet(remote + initial_path)
```

统一改成：

```text
local rule_set
```

---

# 验收标准

## A1

首次安装。

断网。

VPN 仍可启动。

---

## A2

规则集下载失败。

已有缓存。

VPN 仍可启动。

---

## A3

规则集 URL 错误。

VPN 仍可启动。

日志明确提示。

---

## A4

ConfigBuilder 输出中：

```json
"type":"remote"
```

数量必须为：

```text
0
```

---

## A5

启动阶段：

```text
无网络请求
```

---

# 结论

这是一次资源生命周期统一改造，而不是单点修复。

最终目标：

- 启动与网络解耦
- 启动与下载解耦
- 统一 RuleSetRepository
- 消除 sing-box remote rule_set 依赖
- 所有规则集均采用本地缓存启动
- 下载失败永不直接拖垮 VPN 启动
---

# 落地状态(2026-10-26,已实现并编译通过)

## 已落地(阶段 1~5 + A4)

| 项 | 位置 | 说明 |
| --- | --- | --- |
| RemoteRuleSet 模型扩展 | `model/RouteRule.ets` | 新增 `failurePolicy`('block' 默认 / 'allow-unverified')、`format`('binary'/‘source')、`lastSyncAt`、`cachedHash`,`loadRemoteRuleSets` 兼容旧数据 |
| 纯数据契约 | `core/PreparedResource.ets`(新) | `PreparedRuleSet`/`PreparedResources`,**零 import**,ConfigBuilder 可被 Node 单测直接执行 |
| 资源解析器 | `core/ResourceResolver.ets`(新) | `ensureRepository`(扩展进程自初始化)、`snapshot`(只读不联网)、`prepareResources`(有限预算补缓存、永不抛)、`refreshInBackground`(24h 最小年龄)、`ruleSetTag`(`remote_<sid>`) |
| ConfigBuilder 禁 remote | `core/ConfigBuilder.ets` | `buildGeoRuleSet` 改 `local + binary + path`;**签名改为 `preparedRuleSets: Array<PreparedRuleSet>`**;不可用规则集定义与引用一起跳过(不留悬空引用) |
| 启动前预处理 | `vpnext/VpnExtAbility.ets` | 先 `prepareResources`(withGeo=规则模式,budget=20s)再 `buildCoreConfig`;可用性逐条打日志 |
| 启动前配置校验 | `vpnext/VpnExtAbility.ets` `checkConfigGate` | `CoreManager.checkConfig` 15s 超时;返回 `unsupported` 放行,否则在**建 TUN 之前**抛出 |
| 后台刷新 | `vpnext/VpnExtAbility.ets` | `setRunningProfileId` 之后 `void refreshInBackground(...)`,失败保留旧缓存 |
| UI 预校验同口径 | `pages/Index.ets` | `checkConfigBeforeConnect` 用 `ResourceResolver.snapshot`(allowDownload 隐含 false),不再自己拼 geo 路径 |
| 规则集页 | `pages/RouteRulesPage.ets` | 下载走 `ensureResource(sid,url,format,policy)`、策略切换 `setFailurePolicy`、卡片展示 state/失败策略/缓存路径 |

验收对应:A1(启动不联网)✅ A2(启动不下载)✅ A3(下载失败不阻塞启动)✅
A4(配置内 `type:"remote"` 计数为 0)✅ A5(启动阶段无网络请求)✅
守卫用例:`node tests/ruleset-local-startup.cjs`(25 断言,含"混合三态/全部不可用/geo local/静态调用顺序/会话资源固定")。

## 会话资源稳定(§7,2026-10-26 补强)

| 项 | 位置 | 说明 |
| --- | --- | --- |
| 会话固定 | `core/RuleSetRepository.ets`.`pinSessionFiles/releaseSessionFiles/pinnedSessionFiles` | 登记进入本会话配置的文件,`trimVersions` 与 `collectGarbage` 跳过;`removeVersionFile` 遇固定路径只记日志不删 |
| 启动固定 | `vpnext/VpnExtAbility.ets` 写完 config.json 后 | `ResourceResolver.pinSessionFiles(prepared)`(规则集 + geo 路径),发生在 `checkConfigGate`/`createVpnConnection`/`startCore` 之前 |
| 会话结束解除 | `vpnext/VpnExtAbility.ets.doTeardown` | `ResourceResolver.releaseSessionFiles()`,旧版本留到下一次 GC |
| 用例 | `tests/ruleset-repository.cjs` 第 14 组 | 固定后连续刷新两次(v1→v2→v3):v1 文件必须存活;解除固定后 `collectGarbage()` 清 v1、保留当前版本 |

另:规则集页下载失败时不再伪造 `lastSyncAt`(改用仓库 `cachedAt`),模型里的
`lastSyncAt/cachedHash` 仅是展示镜像,可用性一律以仓库清单为准。

## 已知取舍(必须知情)

- **local rule_set 会触发内核 fswatch**:OHOS 应用存储别名路径不支持 inotify,启动日志会多出
  `route: watch rule-set file: ... permission denied` 的 **ERROR 行**(非致命)。这是
  2026-10-24 曾把 geo 改回 `remote + initial_path` 的原因;本轮按本方案 A4 改回 local,
  以换取"配置零 remote"。若真机确认红字不可接受,回退点只有一处:
  `ConfigBuilder.buildGeoRuleSet()` 恢复 remote + initial_path + 10 年 update_interval。

## 未做(可后续)

- Geo 资产(geosite/geoip)迁入 RuleSetRepository 统一生命周期(阶段 6):目前仍走 `utils/GeoAssets`
  的下载/落盘,只由 `snapshot` 判定就绪后以 local 路径注入配置。
- 规则集页的"后台刷新状态"实时刷新(当前只在重进页面/操作后 refresh)。
