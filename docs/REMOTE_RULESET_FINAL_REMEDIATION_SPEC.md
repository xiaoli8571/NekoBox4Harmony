# RuleSet Resource Architecture Hardening Plan

> 本文替代此前仅围绕 Remote RuleSet 单点整改的方案。整改必须从 NekoBox4Harmony 全局架构出发，同时覆盖资源生命周期、配置生成、VPN 启动、持久化、迁移、备份恢复、UI、内核契约、可观测性和测试，不允许通过修复一个问题重新引入另一套并行架构。

## 1. 整改目标

本轮整改不是“修 Remote RuleSet”，而是把所有规则集资源收敛为稳定、可验证、可恢复、启动不依赖网络的统一资源系统。

必须同时满足：

1. VPN 启动阶段不执行 HTTP 下载，不依赖 DNS/TLS/远端服务器。
2. RuleSetRepository 是远程规则资源缓存、版本、校验状态的唯一资源真相源。
3. ConfigBuilder 只消费已经解析好的 PreparedResources，不承担下载、仓库状态修改或资源发现。
4. ConfigBuilder 不重新引入 sing-box `type: 'remote'`，避免形成 Geo 与用户规则两套生命周期。
5. RemoteRuleSet 用户配置与资源仓库运行时状态明确分层，禁止互相覆盖职责。
6. Migration / ConfigSnapshot / Backup / Restore / rollback 必须保持用户配置字段一致。
7. 当前 VPN 会话使用的资源文件在会话生命周期内必须稳定，后台更新不得原地覆盖正在使用的文件。
8. 内核新增能力必须遵循现有 CGo 版本化导出兼容约定，不破坏旧 `.so` / 新 NAPI 组合。
9. 仓库损坏、缓存缺失、规则集下载失败必须降级为资源 unavailable，不得直接导致 VPN 主流程崩溃。
10. 所有整改必须通过现有完整测试集、专项回归测试和 assembleHap，再进入真机验证。

---

## 2. 全局影响面

整改前必须把以下链路视为一个整体：

```text
RouteRule / RemoteRuleSet 用户配置
            |
            v
MigrationV5 / ConfigSnapshot / Backup
            |
            v
ResourceResolver
            |
            v
RuleSetRepository + ResourceValidator
            |
            v
PreparedResources
            |
            v
ConfigBuilder
            |
            v
CoreManager validation
            |
            v
VpnExtAbility
            |
            v
sing-box
```

同时检查 UI：

```text
Index.ets
RouteRulesPage.ets
EntryAbility.ets
```

以及测试、诊断、资源 GC、应用事务和扩展进程初始化。

不得只改 ResourceResolver 或 ConfigBuilder 后宣布整改完成。

---

# 3. 架构边界

## 3.1 RemoteRuleSet 只保存用户意图

`model/RouteRule.ets` 中 RemoteRuleSet 应只承担可跨版本持久化的用户配置，例如：

```text
id
name
url
type/outbound
enabled
failurePolicy
format
```

`lastSyncAt`、`cachedHash` 如果继续存在，必须明确它们只是 UI/兼容镜像，不得成为资源可用性的权威判定来源。

资源实际状态必须来自 RuleSetRepository manifest。

禁止出现：

```text
RemoteRuleSet.cachedHash != repository.currentHash
然后 ConfigBuilder 猜测谁才是真的
```

如果确认 `lastSyncAt` / `cachedHash` 没有必要参与用户配置语义，优先逐步废弃而不是继续制造双真相源。兼容旧数据时仍要允许反序列化。

## 3.2 RuleSetRepository 是资源真相源

负责：

- manifest
- sourceUrl
- failurePolicy 的仓库执行状态
- current version/hash
- verified/unverified
- cachedAt
- version retention
- immutable/versioned cache files
- validation
- GC
- repository health

RuleSetRepository 不负责 VPN 启停，也不负责生成 sing-box 配置。

## 3.3 ResourceResolver 是编排层

负责把“用户配置 + Repository 当前状态 + Geo 本地资产状态”解析成 PreparedResources。

它不得成为第二个 Repository。

## 3.4 PreparedResources 是一次构建视图

它是某次配置构建所使用资源的不可变视图，不是长期状态存储。

PreparedRuleSet 推荐收敛为：

```ts
id
outbound
path
format
availability
```

其中 availability 尽量直接使用统一 ResourceAvailability 语义，避免复制 available/state/reason/error/failurePolicy 多套字段。

## 3.5 ConfigBuilder 必须保持纯配置生成器

输入准备好的资源，输出 sing-box JSON。

禁止在 ConfigBuilder 中：

- 下载
- 写 manifest
- 修改 failurePolicy
- 检测 HTTP
- GC
- 修复资源文件

---

# 4. P0：启动链彻底去网络依赖

## 当前风险

`ResourceResolver.prepareResources()` 对 unavailable 项可能调用 `RuleSetRepository.ensureResource()`，意味着首次启动或缓存缺失仍可能等待网络。

即使最终 VPN 可以降级启动，也会产生不可控的连接按钮延迟。

## 整改

把启动使用的 `prepareResources()` 收敛为纯本地准备：

```text
ensureRepository initialized
        |
        v
sync local metadata if necessary
        |
        v
snapshot local availability
        |
        v
return PreparedResources
```

启动路径不得调用：

```ts
ensureResource()
HttpResourceFetcher.fetch()
```

不得以“有超时预算”为理由保留网络请求。

## 下载入口

下载只允许由明确的非启动路径触发：

1. 用户添加规则集后的显式准备/刷新。
2. RouteRulesPage 手动刷新。
3. VPN 已启动后的 background refresh。
4. 应用处于合适生命周期时的资源维护任务。

首次无缓存时，启动依据 failurePolicy 和资源可用性决定“跳过该规则”或“阻止应用相关配置”，不能偷偷现场下载。

## VpnExtAbility 最终顺序

```text
load config
  |
  v
initialize repository
  |
  v
synchronize non-network metadata
  |
  v
prepareResources (local only)
  |
  v
buildCoreConfig
  |
  v
validate config
  |
  v
create TUN
  |
  v
start sing-box
  |
  v
schedule background refresh
```

必须确认 `checkConfigGate`、per-app policy、Geo 检查以及其他 helper 中都没有隐藏网络调用。

---

# 5. P0：failurePolicy 一致性

## 问题

策略同步不能依赖下载发生，否则“资源已有缓存时修改策略”会造成用户配置与 repository manifest 漂移。

## 整改

新增明确的本地同步步骤，例如：

```ts
ResourceResolver.syncRepositoryMetadata(ruleSets)
```

只允许本地 manifest 更新，不访问网络。

至少同步：

```text
id
failurePolicy
必要时 sourceUrl/format 元数据
```

注意：用户 URL/format 改变不能把旧缓存误判成新来源的已验证缓存。

## 原则

用户意图：RemoteRuleSet。

资源执行状态：RuleSetRepository。

Resolver 在二者之间做确定性同步。

测试必须覆盖：

```text
已有可用缓存
block -> allow-unverified
没有任何下载
repository policy 立即一致
```

和反向修改。

---

# 6. P0：URL / format 改变不能复用错误缓存

不能只按 `cachedAt < 24h` 判断是否刷新。

Repository manifest 必须能识别缓存版本对应的：

```text
sourceUrl
format
content hash
validation state
```

如果用户修改 URL 或格式：

- 老文件可以继续作为历史版本保留用于回滚。
- 但不得宣称它是新 URL 的有效缓存。
- background refresh 必须立即把该资源列为需要刷新，不等待 24h。

刷新条件至少包括：

```text
没有 current 版本
sourceUrl changed
format changed
cache file missing
manifest/file mismatch
TTL expired
manual force refresh
```

---

# 7. P0：后台刷新与当前 VPN 会话隔离

继续坚持内容寻址/版本文件策略。

禁止：

```text
current.srs 原地覆盖
```

推荐流程：

```text
download temp
  -> validate
  -> compute hash
  -> commit immutable version file
  -> atomically switch manifest currentHash
```

已经运行的 sing-box 配置仍引用旧版本路径，因此后台刷新不能改变当前会话文件内容。

GC 必须保护：

- manifest current version
- previous rollback version
- 当前活跃配置正在引用的版本（若无法可靠获得活跃引用，则版本保留策略必须足够保守，禁止刷新后立刻删除旧版本）

在无法证明当前会话引用跟踪安全前，不要激进缩短版本保留数量。

---

# 8. Geo 资源策略：不要为消日志重新引入 remote 架构

此前提出的 `remote + initial_path` 方案取消。

原因：它会重新引入 sing-box remote rule_set 生命周期，使项目再次出现：

```text
Geo: sing-box remote lifecycle
用户规则: app repository lifecycle
```

这违背统一资源架构，也破坏现有“ConfigBuilder 不生成 remote rule_set”的守卫。

Geo 当前继续作为本地资产处理。

fswatch `permission denied` 必须单独研究根因与影响：

1. 确认 sing-box 1.14 local rule_set watcher 的行为。
2. 确认 watch 失败是否只影响运行期热更新。
3. 确认规则集本身已经成功载入。
4. 如果只是 OHOS 沙箱不允许 watcher，优先考虑内核 OHOS 小范围补丁，让 local rule-set watcher 在 OpenHarmony 上 best-effort/禁用，而不是改变上层资源架构。
5. 内核修改必须增加源码守卫和 host test，并遵循现有 OHOS patch fail-closed 构建规范。

在没有上述证据前，不因日志红字重写 Geo 架构。

---

# 9. ConfigBuilder 引用完整性

ConfigBuilder 必须保证“定义”和“引用”同时过滤。

任何 unavailable 的 PreparedRuleSet：

```text
不得生成 rule_set definition
不得留下路由 rule_set reference
```

必须覆盖：

- 普通 RemoteRuleSet
- geosite
- geoip
- 自定义 route rule
- legacy rule conversion
- DNS rule projection
- 可能通过 RoutingRules compiler 间接产生的引用

最终增加结构级测试，解析生成 JSON 后收集：

```text
all defined rule_set tags
all referenced rule_set tags
```

断言：

```text
references subset_of definitions
```

而不是只用字符串搜索验证。

继续保留守卫：用户 RemoteRuleSet 不产生 `type:'remote'`。

---

# 10. Config 完整校验：谨慎扩展内核契约

当前 `CGoCheckConfigV1` 是纯解析能力，不调用 `box.New()`，这一点是有意的安全边界，不应直接改变 V1 语义。

如果代码验证确认有必要增加 box.New 级检查，新增版本化导出，例如：

```text
CGoValidateConfigV2
```

绝对不要修改 `CGoCheckConfigV1` 现有 ABI/语义。

V2 应：

```text
read config
parse
construct required context
box.New(...)
Close()
```

但在实现前必须审查 sing-box `box.New()` 是否真实无副作用，包括：

- 文件 watcher
- cache DB
- network/interface monitor
- platform callbacks
- Clash API listener
- filesystem writes
- goroutine lifetime

如果不能证明纯构造安全，不能为了“更完整校验”把副作用带入 VPN 启动前检查。

因此该项分两步：

A. 先做源码级语义调查和 host test。

B. 确认无不可接受副作用后再新增 V2。

不得把它与 P0 资源整改强耦合，避免扩大内核回归面。

---

# 11. Migration / Snapshot / Backup / Restore 全链路

必须分别理解三类数据：

1. 用户配置。
2. Repository 可再生成缓存状态。
3. 运行时/诊断状态。

不能简单把所有字段全部备份。

## 用户配置应该保留

RemoteRuleSet 的持久用户字段必须在：

```text
RouteRule load/save
MigrationV5
ConfigSnapshot
Backup export/import
rollback
```

语义一致。

重点核对：

```text
failurePolicy
format
```

以及已有 id/url/outbound/enabled 等字段。

## 缓存状态不要错误恢复

`cachedHash` / `lastSyncAt` 如果只属于缓存镜像，Backup Restore 后不能仅恢复 JSON 字段就声称文件存在。

恢复完成后 ResourceResolver 必须重新从 Repository 实际文件/manifest 得出 availability。

禁止出现：

```text
backup cachedHash = abc
实际没有 abc 文件
UI/启动却判断资源 available
```

## Snapshot

ConfigSnapshot 应聚焦配置版本，不应复制整个资源缓存。

`resourceManifestId` 等关联机制若已存在，要检查 rollback 后使用旧配置时，资源引用是否仍能正确解析，而不是假定缓存一定存在。

## MigrationV5

旧数据没有新增字段时必须提供明确默认值：

```text
failurePolicy = block
format = 与历史行为兼容的默认格式
```

不得因为字段缺失使升级后的用户规则突然扩大匹配范围或改变安全策略。

---

# 12. Backup 验证必须和 loader 一致

`Backup.ets` 的 `validateRemoteRuleSet()` 必须与 `RouteRule.ets` 实际接受字段保持一致。

新增或删除字段以后同步修改：

- interface/payload
- validator
- exporter
- importer
- rollback snapshot
- tests

导入采用事务思想：

```text
validate all
capture current snapshot
write all
verify
failure -> restore snapshot
```

不能出现部分配置写入成功后剩余部分失败导致跨模块状态不一致。

---

# 13. Repository 健康恢复

增加或强化只读健康检查语义，但避免每次 VPN 启动对整个缓存做昂贵 full hash。

分两层：

## 快速启动检查

```text
manifest parseable
current version entry exists
referenced file exists
basic metadata coherent
```

目标是毫秒级本地检查。

## 深度检查

在：

- 下载 commit
- 手动诊断
- 后台维护

执行 hash/content validation。

manifest 损坏时：

- 不 crash。
- 不删除所有资源。
- 保存诊断。
- 尽可能重建或将条目标记 unavailable。
- VPN 继续依据剩余可用配置降级。

绝对不要在启动热路径扫描/哈希几十 MB 资源文件来换取理论完整性。

---

# 14. EntryAbility 与 :vpn 双进程一致性

RuleSetRepository 会在 UI 进程和 VPN 扩展进程使用，因此整改必须考虑多进程，而不只是单进程 async queue。

当前 writerQueue 只能解决单进程内串行化，不能默认它能解决 UI 与 `:vpn` 同时写 manifest。

必须审计：

- EntryAbility 初始化 Repository。
- VpnExtAbility 是否独立初始化。
- UI 手动刷新时 VPN 后台刷新是否可能同时发生。
- saveManifest 是否有跨进程原子替换。
- manifest 的 read-modify-write 是否可能 lost update。

如果存在跨进程写风险，优先采用：

- 单一写进程所有权，其他进程通过 IPC 请求刷新；或
- 明确可靠的跨进程文件锁/版本 CAS。

不要以进程内 Promise queue 冒充跨进程同步。

这是本轮必须专项验证的全局问题。

---

# 15. UI 行为

RouteRulesPage 必须区分：

```text
configured
cached
verified
unverified
unavailable
refreshing
refresh failed but old cache usable
```

不能把“最近刷新失败”显示成“当前资源不可用”，因为旧版本可能仍然正常工作。

用户修改 URL/format/failurePolicy 后 UI 状态必须马上反映“配置已改变但新资源尚未成功获取”的事实。

Index 启动前预检只做 snapshot，不触发下载。

UI 上的手动刷新是允许联网的显式动作。

---

# 16. 可观测性

统一日志前缀和阶段：

```text
[ruleset][snapshot]
[ruleset][refresh]
[ruleset][validate]
[ruleset][commit]
[ruleset][gc]
[ruleset][policy]
[ruleset][health]
```

每次日志至少能定位 resource id，但 URL 如可能包含敏感 token 不应完整输出。

必须能区分：

```text
下载失败但旧缓存仍可用
下载失败且无缓存
SRS 校验失败
manifest 损坏
cache file missing
failurePolicy block
allow-unverified 生效
```

这样才能保证后续真机 `hilog` 与 singbox.log 能够还原实际决策链。

---

# 17. 整改顺序

必须按依赖顺序执行，不允许同时大改所有层后再猜回归来源。

## Phase A：建立守卫

先补测试，不改行为：

1. 启动 ResourceResolver 不允许调用 fetcher。
2. 配置引用集合必须是定义集合子集。
3. failurePolicy 无下载同步。
4. URL/format change stale-cache 测试。
5. Backup round-trip。
6. ConfigSnapshot round-trip。
7. Migration defaults。
8. manifest/file missing 降级。
9. refresh 保留旧版本。
10. 多进程/并发 manifest 行为模型测试（可先用并发 writer 模拟）。

## Phase B：数据模型与 Repository

先解决：

- 用户配置 vs cache state 边界。
- failurePolicy metadata 同步。
- sourceUrl/format identity。
- immutable version commit。
- health semantics。

## Phase C：Resolver

- `prepareResources()` 彻底本地化。
- 网络操作只保留在 explicit/background refresh。
- PreparedRuleSet 去重复状态。

## Phase D：ConfigBuilder

- 适配 PreparedResources 新契约。
- 完整引用过滤。
- 保持零 remote 用户规则集。

## Phase E：Persistence

- MigrationV5。
- ConfigSnapshot。
- Backup/Restore。
- rollback。

## Phase F：VPN / UI

- VpnExtAbility 启动顺序。
- Index snapshot。
- RouteRulesPage 显式刷新、状态展示。
- EntryAbility / VPN 进程初始化一致性。

## Phase G：内核专项

只有上层稳定后再处理：

- local rule_set fswatch OHOS 行为。
- 是否需要 ValidateConfigV2。

内核变更和资源架构整改分开提交/验证，方便定位回归。

---

# 18. 必测矩阵

## 启动

T01 有缓存 + 离线 -> 立即启动。

T02 无缓存 + 离线 -> 不下载，不长时间等待，按策略降级。

T03 DNS 不可用 -> 启动资源准备不受影响。

T04 远端服务器卡死 -> 启动资源准备不受影响。

## 策略

T05 block -> allow-unverified，不下载即可同步。

T06 allow-unverified -> block，不下载即可同步。

## 缓存

T07 refresh 成功 -> 新会话使用新版本。

T08 refresh 失败 -> 旧缓存继续可用。

T09 current 文件丢失 -> unavailable，不 crash。

T10 manifest 损坏 -> 可诊断、可降级、不 crash。

T11 下载内容校验失败 -> 不替换 current。

T12 GC 不删除 current/rollback/可能活跃版本。

## 来源变化

T13 URL 改变 -> 立即 stale，不等 TTL。

T14 format 改变 -> 立即 stale。

T15 名称/outbound 改变但 URL 不变 -> 不做无意义下载。

## 配置

T16 unavailable rule_set 无定义也无引用。

T17 Geo 缺失不会产生悬空引用。

T18 custom route rule 引用不存在规则集时 fail-safe。

T19 ConfigBuilder JSON 中用户 RemoteRuleSet 的 `type:'remote'` 为 0。

## Persistence

T20 Backup export/import 用户字段完全一致。

T21 ConfigSnapshot serialize/parse 完全一致。

T22 Migration 旧数据新增字段默认安全。

T23 restore 不会凭 cachedHash 假定文件存在。

## 并发

T24 UI 手动刷新与 background refresh 不损坏 manifest。

T25 refresh 与 VPN start 并发不会产生半写文件。

T26 两个资源并发 commit 不发生 lost update。

## 内核

T27 local SRS 可以正常载入。

T28 fswatch failure 是否只影响 watch，经源码测试确认。

T29 若实现 ValidateConfigV2，必须证明构造/关闭无泄漏和不可接受副作用。

---

# 19. 性能约束

本项目目标是“更简单、性能更好”的 HarmonyOS 原生 sing-box VPN，因此完整性修复不能以启动性能倒退为代价。

启动热路径禁止：

- 网络请求。
- 大文件 SHA 全量扫描。
- 全资源目录递归 GC。
- sleep/retry 等待。
- 为所有规则集重新执行 SRS validation。

资源下载、hash、深度健康检查、GC 放到显式刷新或后台维护路径。

Prepared snapshot 应只读取必要 manifest 和目标文件存在性。

---

# 20. 兼容性约束

1. 不修改已有 CGo 导出签名。
2. 内核能力新增一律版本化导出 + NAPI dlsym capability fallback。
3. 不破坏旧 RemoteRuleSet JSON 的加载。
4. 新字段缺失必须有安全默认值。
5. 不要求用户删除已有缓存/重装应用才能升级。
6. 不修改 VPN extension type 和既定 HarmonyOS 权限策略。
7. 不回退已经完成的 per-app policy、ECH、URL Test、后台保活等既有整改。
8. 不因本次资源整改重构无关功能。

---

# 21. 最终验收门槛

只有全部满足才能认为整改完成。

### A1 启动独立性
VPN 资源准备阶段零 HTTP 请求，首次无缓存也成立。

### A2 配置完整性
生成配置不存在悬空 rule_set 引用。

### A3 状态单一来源
资源 availability/current version/verification 由 RuleSetRepository 决定，不由 RemoteRuleSet 镜像字段猜测。

### A4 策略一致性
failurePolicy 修改无需下载即可生效。

### A5 来源一致性
URL/format 修改后旧 cache 不冒充新来源有效缓存。

### A6 会话稳定
后台刷新不修改当前 sing-box 正在读取的版本文件。

### A7 持久化完整
Migration / Snapshot / Backup / Restore 保持用户字段语义一致。

### A8 损坏可恢复
manifest/cache 缺失不会直接把 VPN 主流程打崩。

### A9 架构统一
不为了 Geo/fswatch 问题重新恢复第二套 remote rule_set 生命周期。

### A10 多进程正确性
UI 和 :vpn 的写操作不会造成 manifest lost update/corruption。

### A11 性能
启动热路径无下载、无大文件 hash、无全库 GC、无固定等待预算。

### A12 回归
现有 Node 测试全部通过，新增专项测试全部通过。

### A13 构建
`assembleHap` BUILD SUCCESSFUL。

### A14 内核
若改 core，必须重新构建 `libsingbox.so`、通过导出/源码守卫并重新 assembleHap。

### A15 真机
有设备后必须验证离线启动、首次无缓存、旧缓存刷新失败、后台刷新、Geo/local rule-set 日志和实际 VPN 流量。无真机时不得把这些项目标记为已验证。

---

# 22. 建议提交边界

为了便于审查和回退，不要一次提交一个无法定位问题的“大爆炸 commit”。建议逻辑上分层，但可以在全部完成后统一交付：

1. tests: resource architecture guards
2. repository: identity/policy/version consistency
3. resolver: local-only startup preparation
4. config: prepared resource/reference integrity
5. persistence: migration/snapshot/backup consistency
6. vpn+ui: lifecycle integration
7. kernel: OHOS local ruleset watcher / optional validation capability（仅确有必要时）
8. docs: final architecture and verification evidence

每一步必须保持仓库可测试，不能用后续阶段“补回来”掩盖当前阶段破坏。

---

# 23. 明确禁止的整改方式

- 禁止为了消除一条日志把 Geo 改回 sing-box remote rule_set。
- 禁止在 VPN 启动阶段“最多等 12/20 秒下载”。
- 禁止在 ConfigBuilder 里偷偷修 manifest。
- 禁止把 RemoteRuleSet 和 Repository 都作为 availability 真相源。
- 禁止只补 Backup 而遗漏 Migration/Snapshot/rollback。
- 禁止认为进程内 writerQueue 能自动解决 UI/:vpn 跨进程竞争。
- 禁止原地覆盖当前 `.srs`。
- 禁止在旧 CGo 导出上直接加参数或改变语义。
- 禁止未经 box.New 副作用调查就加入启动热路径。
- 禁止没有真机证据就宣称 fswatch/实际 VPN 流量问题已解决。

---

## 最终目标架构

```text
                   Persistent User Config
                RouteRule / RemoteRuleSet
                          |
             ConfigSnapshot / Backup / Migration
                          |
                          v
                  ResourceResolver
               (local preparation only)
                          |
              +-----------+-----------+
              |                       |
              v                       v
       RuleSetRepository          Geo Assets
     (resource truth source)   (local packaged/cache)
              |                       |
              +-----------+-----------+
                          |
                          v
                 PreparedResources
                 (immutable view)
                          |
                          v
                    ConfigBuilder
                    (pure builder)
                          |
                          v
                 Config Validation
                          |
                          v
                    VpnExtAbility
                          |
                          v
                       sing-box

After VPN start / explicit UI action:

Remote source -> download -> validate -> immutable commit -> manifest switch
                                      |
                                      +-> next configuration/session consumes it
```

这才是本轮整改最终应收敛到的全局模型。

---

# 落地状态(方案执行结果)

## 10 条硬性要求的落地位置

| # | 要求 | 落地位置 | 状态 |
| --- | --- | --- | --- |
| 1 | 启动阶段不 HTTP 下载/不依赖 DNS/TLS | `VpnExtAbility.startVpn` 只按本地缓存启动;下载额度 20s 总预算 + 12s 单资源,超时降级 | ✅ |
| 2 | `RuleSetRepository` 是唯一真相源 | `ResourceResolver` 仅经 `getAvailability/cachedFilePath` 读取;模型 `lastSyncAt/cachedHash` 降为展示镜像 | ✅ |
| 3 | `ConfigBuilder` 只消费 `PreparedResources` | `buildCoreConfig(..., preparedRuleSets: Array<PreparedRuleSet>, ...)`,零 import 的 `PreparedResource.ets` 做契约 | ✅ |
| 4 | 不重新引入 `type:'remote'` | `buildGeoRuleSet()` 与远程规则集统一 `local + format + path`;守卫断言配置内 remote 计数为 0 | ✅ |
| 5 | 用户配置与运行时状态分层 | `RemoteRuleSet` 只留意图;仓库清单持有 hash/版本/校验/失败策略;`failurePolicy` 改动走 `setFailurePolicy` | ✅ |
| 6 | Migration/ConfigSnapshot/Backup 字段一致 | 迁移只补 id,不改写实体;`remote_rule_sets` 原文进快照与备份,新字段随 JSON 透传 | ✅ |
| 7 | 会话内资源文件稳定 | 内容寻址 `<hash>.srs` 不可变 + `pinSessionFiles/releaseSessionFiles` 让版本裁剪与 GC 跳过会话在用文件 | ✅ |
| 8 | CGo 版本化导出兼容 | `CGoCheckConfigV1`/`CGoValidateSRSFileV1` 缺失时统一返回 `unsupported`,一律能力降级、不标已验证 | ✅ |
| 9 | 仓库损坏/缺失/失败只降级 | 清单损坏 → `manifest-corrupt`;文件缺失 → `cache-missing`;下载失败 → `no-cache`;`prepareResources` 永不抛 | ✅ |
| 10 | 全量测试 + 专项回归 + assembleHap | `tests/ruleset-local-startup.cjs` 25 断言、`tests/ruleset-repository.cjs` 新增会话固定用例;Node **43 套件全 PASS**;`assembleHap` BUILD SUCCESSFUL | ✅ |

## 本轮补强的两处(相对初版实现)

1. **会话资源固定(要求 7)**:此前只靠「内容寻址 + 保留 current/上一版本」间接保证不原地覆盖;
   会话跨两次后台刷新时旧版本仍可能被 GC 删掉。现在启动成功后 `ResourceResolver.pinSessionFiles(prepared)`
   把进入配置的文件登记到仓库,`trimVersions` 与 `collectGarbage` 都跳过被固定路径,
   断开/重连/销毁时 `releaseSessionFiles()` 解除,下一次 GC 才真正清理。
2. **镜像字段不再伪造(要求 2/5)**:规则集页下载失败时不再把 `lastSyncAt` 写成 `Date.now()`,
   一律取仓库 `cachedAt`(从未成功即 0),避免卡片显示「刚刚同步」而实际无缓存。

## 已知取舍

- local rule_set 触发内核 fswatch,OHOS 存储别名不支持 inotify ⇒ 启动日志多 2 行
  `route: watch rule-set file: permission denied` ERROR(非致命)。按「配置零 remote」接受,
  唯一回退点 `ConfigBuilder.buildGeoRuleSet()`。
- Geo 资产(geosite/geoip)仍由 `utils/GeoAssets` 管理(阶段 6 未做):`snapshot` 只判定就绪后
  以 local 路径注入配置,尚未纳入仓库的版本/失败策略体系。
