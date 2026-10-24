# P2 设计：检测可用性系统（ProbeResult / Coordinator / Runner / Store）

日期：2026-10-24。依据：`docs/REDESIGN-PLAN-2026-10-23.md` §6（检测）、§16.4（K2）、§20.1（W09/W10）。状态：模型与协调器已落地（14 项测试），运行器/存储/视图模型并行交付中。

## 1. 分层

```
UI(P3)                     model/ProbeFilters（筛选/排序/历史/分组/显示 token）
                             ↑ 纯函数
core/ProbeRunner  ────────── 编排：前提检查→冻结快照→分批隔离→并发探测→结果归一→持久化
   │   ├── CoreManager（K2: testStartV3/testProxyV3/testStopV3/testSessionInfoV3/testCaps）
   │   ├── core/ProbeCoordinator（纯状态机：runId/generation 守卫、二分隔离、预算、取消、摘要）
   │   └── core/ProbeStore（独立持久化：原子写、读回、unsaved 如实标记）
   ↓
model/ProbeResult（结果模型 + profileConfigHash + 复合键 + 兼容投影 + 新鲜度）
```

## 2. 结果模型要点（§6.2）

- 身份键：`profileId|profileConfigHash|methodActual|target|expectedStatus|path`。`profileConfigHash` 排除 `name/groupId/favorite/pinned/latencyMs/latencyTestedAt`——仅改名称/收藏不使 hash 失效；传输字段任何变化产生新 hash。
- `methodRequested` 与 `methodActual` 永不合并；HTTP 回退 TCP 时 `methodActual='tcping'` + `degradedReason='http_fallback_tcping'` 永久可见。
- `latencyMs`：0 合法；-1 = 未测。成功但延迟无效 → `state=failed`、`errorCode='invalid_latency'`。
- `path`：`directBound`（绑定物理网卡）/`currentTunnel`（经当前 VPN）/`unboundUnknown`（不确定）/`legacyUnknown`（旧结果）——未知路径不假装直出。
- 旧 `status/ping/error` 保留为兼容投影；旧结果迁移 `method=unknown`、`path=legacyUnknown`，不参与"当前可用"过滤。

## 3. 协调器语义（§6.4/§6.5）

| 场景 | 行为 |
|---|---|
| 重复 begin | 拒绝（同一时刻只允许一轮） |
| 目标快照 | `begin` 时冻结副本；运行中搜索/切页/订阅更新不影响 |
| 迟到回调 | `runId` 不匹配 → 拒绝；节点已终结 → 拒绝覆盖 |
| 批量启动失败 | `onBatchStartFailed` → 二分（`split`）；长度=1 → `isolated`（坏节点，带原因/依赖链）；预算耗尽（2N−1）→ `exhausted`，如实报未完成 |
| 环境级失败 | `onEnvironmentFailure` 只记一次；未开始节点标 `notApplicable`（不是坏节点），并提供"改用 TCPing"选项 |
| 取消 | 停止取新目标；未执行节点 `cancelled` + `participated=no`（保留其持久化旧结果）；in-flight 允许完成 |
| 写盘失败 | `markUnsaved` → 结果 `state=unsaved`、`persistedAt=0`，不假装已保存 |
| 前提检查 | `precheckEnv(capsOk, dirWritable, urlValid, methodSupported)` → 机器可读原因 |

## 4. K2 会话协议（§6.5/§16.4，与 k1 并行实现）

| 导出 | 语义 |
|---|---|
| `CGoTestStartSingBoxV3(sessionId, configPath, bindIfname)` | 会话隔离启动；同 id 重复→错误；有其他活动会话→错误（串行）；启动期间被 stop→立即关闭并返回 cancelled |
| `CGoTestProxySingBoxV3(sessionId, tag, url, timeoutMs, expectStatus)` | 仅在该会话内探测；未知会话→`session <id> not found`；返回延迟数字或 `err:` |
| `CGoTestStopSingBoxV3(sessionId)` | 返回 "" 前必须已关闭实例（"stop 完成并确认"）；未知会话幂等；写墓碑供迟到 start 识别 |
| `CGoTestSessionInfoV3(sessionId)` | JSON 状态（starting/active/stopping/closed + tombstone），诊断与 stop 确认 |
| `CGoTestActiveSessionsV3()` | 活动会话（≤1） |

NAPI：`testStartNativeV3/testProxyNativeV3/testStopNativeV3/testSessionInfoNativeV3/testActiveSessionsNative`；缺符号回退 `unsupported`（不得当成功）。`testCapsNative` → `"v3"|"v2"|"legacy"`。

旧 ABI 安全证明：V2/legacy 无 sessionId，串行调度 + 代次守卫兜底；`testCaps()` 如实记录能力，legacy 下不启用"已验证资源/会话隔离"相关流程（§16.3）。

## 5. 失败与降级矩阵

| 情形 | 结果状态 | 用户可见 |
|---|---|---|
| 单节点握手/HTTP 失败 | `failed` + `errorDetail` 原文 | "失败（可查看原文）" |
| 批量启动失败（坏节点/坏前置） | 二分隔离；坏节点 `failed`+`batch_start_failed`+依赖链 | 各根节点显示相同依赖错误 |
| 桥接/内核不支持 | 整轮 `notApplicable` + `envError` | "改用 TCPing 检测支持的节点" |
| 取消 | 未执行 `cancelled`/参与=否 | 取消不是失败 |
| 写盘失败 | `unsaved` | "结果未保存" |
| 超时 | `failed` + 超时原文 | 仅该节点受影响 |

## 6. 待接线（P3/P4）

1. `pages/Index.ets`（或 P3 新首页）消费 `ProbeFilters` + `ProbeStore.latestAll`；检测进度入口全局化。
2. `LatencyTester.urlTestProfiles` 保持旧签名（Index 不改即可获得新行为）。
3. 自动组探测与运行实例检测（P4 W15/W19）：`source` 区分 manual/autoGroup/runInstance，判据/路径不同分别显示。
4. 设备验收（P6）：真实 UDP/TCP 探测、跨页取消、断电后已保存部分恢复。
