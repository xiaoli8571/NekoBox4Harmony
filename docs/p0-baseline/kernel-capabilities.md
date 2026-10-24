# P0 内核能力清单与 K1/K2 技术验证

日期：2026-10-24。依据：docs/REDESIGN-PLAN-2026-10-23.md §16（运行协议与内核能力）、§25.2（施工前检查）。分析对象：`core/libsingbox14/main.go`（262 行）、`entry/src/main/cpp/napi_init.cpp`（552 行）、`core/sing-box-1.14/box.go`。本文记录**当前实际能力**与 **K1/K2 是否必须实施**的结论，行号以当前工作区为准。

## 1. 当前 .so 导出清单（源码级核验）

`core/libsingbox14/main.go` 共 9 个导出：

| 导出 | 签名 | 用途 | 版本约定 |
|---|---|---|---|
| `CGoSetTunFd` | `(fd C.int)` | 注入 TUN fd | 既有契约，不动 |
| `CGoStartSingBox` | `(configPath)` | 启动 VPN 主实例 | 既有契约，不动 |
| `CGoStopSingBox` | `()` | 停止 VPN 主实例 | 既有契约，不动 |
| `CGoSingBoxVersion` | `()` | 版本字符串 `1.14.0-ohos-inproc` | 既有契约，不动 |
| `CGoTestStartSingBox` | `(configPath)` | 测速会话 legacy | legacy 保留 |
| `CGoTestStartSingBoxV2` | `(configPath, bindIfname)` | 测速会话 + 绑网卡 | V2 |
| `CGoTestProxySingBox` | `(tag, url, timeoutMs)` | 探测 legacy（只 HEAD、不看状态码） | legacy 保留 |
| `CGoTestProxySingBoxV2` | `(tag, url, timeoutMs, expectStatus)` | 探测 + 2xx 判定 | V2 |
| `CGoTestStopSingBox` | `()` | 停止测速会话 | — |

NAPI 侧 `testStartNative(configPath, bindIfname, cb)` / `testProxyNative(tag, url, timeoutMs, expectStatus, cb)` 统一签名，内部按 `g_testV2` dlsym 分派（`napi_init.cpp:313-436`）。

> **2026-10-24 更新（W05/K1 已落地）**：已新增 2 个无副作用校验导出并通过主机测试与构建核验——
> `CGoCheckConfigV1(configPath)`、`CGoValidateSRSFileV1(path)`（main.go 尾部），
> NAPI 侧 `checkConfigNative`/`validateSrsNative`（dlsym 缺失回退 `"unsupported"`），
> ArkTS 包装 `CoreManager.checkConfig()/validateSrs()`。build 脚本 exports.map 白名单 +2 行。
> 新 .so sha256 `fa0b67c4…`（11 导出 = 旧 9 + 新 2），HAP 已重打包且包内 .so 哈希一致。
> 源码级守卫测试 `tests/hostprobe/k1_validate_test.go` 锁死「不 box.New/不 Start/不碰环境变量/不写文件」。

## 2. K1（配置与 SRS 验证能力）——结论：**新增两个无副作用导出，两层校验**

### 2.1 box.New 不是无副作用的（P0 核对结论，对应 §16.3）

`box.New`（box.go:113 起）在**不调用 Start() 的前提下**就会产生副作用：

1. **规则集下载/初始化**：`router.Initialize(routeOptions.Rules, routeOptions.RuleSet)` 在 New 期间执行——remote 规则集首下失败会上抛（功能审计已复现 `initial rule-set: ... unexpected status: 503`）。校验一个引用远端规则集的配置会触发真实网络下载。
2. **日志文件**：`log.New` 按 `log.output` 创建/写日志文件。
3. **缓存文件需求**：`needCacheFile` 分支（cache_file enabled 时）。
4. **环境变量**：包装层 `startTestBox` 会 Set/Unset `SING_BOX_BIND_IFNAME` / `SING_BOX_TUN_FD`（main.go:159-166）——新校验导出**绝不能**沿用这套，否则会污染 UI 进程内正在进行的测速会话环境。

因此「拿 box.New 做 check」不可行，按 §16.3 拆两层：

### 2.2 K1 设计（实施于 P1/P2，配合 ConfigCompiler）

| 层 | 实现方式 | 副作用 | 能校验什么 |
|---|---|---|---|
| 结构校验（ArkTS 纯逻辑） | ConfigCompiler 静态检查：引用存在性（outbound/rule_set tag）、空组、递归引用、参数边界 | 无 | 引用缺失、空组、重复 tag、无效参数 |
| 内核 schema 校验（新导出 `CGoCheckConfigV1(configPath)`） | 仅 `json.UnmarshalExtendedContext[option.Options]`（main.go:86 同款调用），**不 box.New、不 Start、不触碰任何环境变量** | 无（纯内存解析） | schema 类型错误——功能审计中 `server_port:"invalid"` 坏节点正是在这一层被拒（CGoStartSingBox 先 parse 后 box.New，parse 错误必上抛），把它抽成独立导出即可在**批量检测前逐节点**静态拦截 |
| SRS 校验（新导出 `CGoValidateSRSFileV1(path)`） | 读本地文件 → `common/srs.Read(reader, recover=false)`（core/sing-box-1.14/common/srs/binary.go:53，纯解析） | 无 | 完整 SRS 内容、版本与规则；比「只认 SR 魔数」强 |
| 运行验证 | 现有 Start 流程 | 有 | 端口/权限/真实网络 |

能力探测：NAPI 侧 dlsym `CGoCheckConfigV1` / `CGoValidateSRSFileV1`，缺失时能力上报 `check:unsupported`，产品侧不得标「已验证」（§16.3 旧库缺能力不启用该流程）。

### 2.3 对 REQ 的影响

- REQ-10（坏节点隔离）：逐节点 `CGoCheckConfigV1` 使 §6.4「静态字段检查」从 JS 猜测升级为真实内核 schema 校验，坏节点在检测开始前即单独报错。
- REQ-19（规则集）：`CGoValidateSRSFileV1` 是「已验证缓存」的判据来源；无该能力时不标已验证。
- 构建：新增导出必须重编 `.so`（`GO126=... bash core/scripts/build-libsingbox-ohos.sh`）+ 重新 assembleHap（§17.8）。

## 3. K2（检测会话取消与迟到回调）——结论：**最小 K2 必须实施**

### 3.1 现状与风险（P0 核对结论，对应 §6.5）

当前测速会话模型（main.go:43-48, 138-183, 240-255；LatencyTester.ets:262-294, 338-414）：

- 包级单例 `testInstance` + `testMu` RWMutex，一次只有一个会话；
- `startTestBox` 遇到已有会话**直接复用**（main.go:141-143 `return C.CString("") // 已有测试会话,直接复用`）；
- 导出**不带 sessionId**，NAPI 回调无法关联轮次；
- JS 侧缓解措施已存在：开测前无条件 pre-stop 一次（LatencyTester.ets:385-391）、start 桥接 30s 兜底超时、`withBridgeTimeout` 全局兜底、`testing` 布尔卫兵（Index.ets:603, 632）。

风险点（对照 §6.5 要求）：

1. **迟到 start 复用**：`startTestBox` 在 native 侧挂死 30s 后 UI 已回退 TCPing 并 testStop；native 迟到完成后 testInstance 又被赋值——违反「迟到创建成功的实例必须立即关闭，不能被下一轮误复用」。当前靠下一轮 pre-stop 自愈，但本轮内复用一个「上轮配置」的实例会造成整组 outbound not found 假红（代码注释已承认该场景：LatencyTester.ets:353-355, 385-388）。
2. **无会话身份**：`proxyTest` 拿到的 `testInstance` 可能是任意轮的实例，UI 无法校验「这轮探测打在这轮实例上」。
3. **stop 语义**：`CGoTestStopSingBox` 无条件清掉当前实例——若一轮探测仍在进行而下一轮 stop 到达，会把仍在进行的探测的实例关掉（promise 挂死风险，靠 withBridgeTimeout 兜底转失败）。

### 3.2 最小 K2 设计（实施于 P2，ProbeCoordinator 重构前）

新增 V3 导出（遵循既有 V2 后缀 + dlsym 回退约定，AGENTS.md「今后再给 CGo 导出加参数,一律走 V2 后缀 + dlsym 回退」）：

| 导出 | 签名 | 行为 |
|---|---|---|
| `CGoTestStartSingBoxV3` | `(configPath, bindIfname, sessionId)` | 有活跃会话且 sessionId 不同：关闭旧实例（记录 stale），再启动新实例；同 sessionId 已活跃：返回明确错误（不重复启动） |
| `CGoTestProxySingBoxV3` | `(tag, url, timeoutMs, expectStatus, sessionId)` | 会话不匹配返回 `err:stale session`；探测在会话 cancel context 内执行 |
| `CGoTestStopSingBoxV3` | `(sessionId)` | 仅关闭匹配 sessionId 的实例；不匹配时返回说明（不误关新会话） |

Go 侧维护 `curSessionId string`；迟到 start（stop 之后才完成的 New/Start）在赋值前比对 sessionId，不匹配立即 Close。NAPI 回调携带 sessionId，ArkTS ProbeCoordinator 按 runId/generation 过滤（§6.5「旧回调不能更新新一轮」）。

不实施完整「强制回收」承诺：§16.4 明确 K2 不承诺 Go 或系统永久阻塞时能强制回收——不可恢复时上报 `检测不可用`，VPN 主会话独立运行，不用 dlclose 活跃 Go 运行时恢复。

### 3.3 对 REQ 的影响

- REQ-09/REQ-10：取消、迟到回调、旧实例隔离的正确性基础。
- 测试对应 TEST-08（取消、切页、重测、迟到 start 回调）。

## 4. 运行状态协议现状（§16.1 设计输入）

- 现有 IPC：CommonEvent `VPN_LOG` / `VPN_STATUS`（AGENTS.md 架构速记；`core/VpnIpc.ets` 170 行）。
- 无 protocolVersion/sessionId/generation/sequence 信封——P1 的 ApplyCoordinator 与 RuntimeStore 设计需先读 `core/VpnIpc.ets` 与 `vpnext/VpnExtAbility.ets` 的现有事件载荷再定信封字段（不在本文展开，P1 设计时补）。

## 5. K3（可选结构化规则标识）——P0 结论

§16.5：基础诊断可用内核 `rule` 表达式与 chains 满足 REQ-12。ClashApi 当前连接接口已可读 `rule`（`utils/ClashApi.ets`）。**P0 结论：K3 不需要**，仅当 P5 实现精确跳转编辑时若 manifest 无法唯一对应再评估。本文不展开。

## 6. 待验证遗留（P0 无法在本机完成的）

| 项 | 状态 | 计划 |
|---|---|---|
| .so 实际导出核验（llvm-readelf） | ✅ tester 已核验 9/9；W05 后为 11/11（含 2 个 K1 导出） | 本轮 |
| `CGoCheckConfigV1`/`CGoValidateSRSFileV1` 行为验证 | ✅ 已实现；主机 Go 测试 19 项通过（含 `server_port:"invalid"` 拒绝、真实 geosite-cn.srs 通过、8 种损坏 SRS 拒绝、无副作用源码守卫） | — |
| V3 会话导出的迟到 start 场景复现 | 未实现 | P2 故障注入测试 |
| 真机 K1/K2 行为 | 无 HDC 设备（`hdc list targets` 返回空） | P6/P7 设备验收，当前保持「待验」状态，不得标通过 |
