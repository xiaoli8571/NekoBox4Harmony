# P1 设计：运行状态协议与 ApplyCoordinator（§16.1 / §12.3 / REQ-04/05/18）

日期：2026-10-24。状态：设计冻结，实施分两步（P1 骨架 → P3/P4 全量接线）。依据：docs/REDESIGN-PLAN-2026-10-23.md §16.1、§12.3、§4.2、§4.3。

## 1. 现状盘点（基于当前工作区）

| 层 | 现状 | 证据 |
|---|---|---|
| IPC 通道 | CommonEvent，bundleName 限定；事件 VPN_LOG/VPN_STATUS/VPN_TRAFFIC/VPN_LATENCY/VPN_APP_FOREGROUND | `core/VpnIpc.ets:9-14` |
| 状态载荷 | `{status, running, profileId}` 字符串 JSON；无版本/会话/序列号 | `VpnIpc.ets:31-48` |
| UI 侧状态 | AppStorage 键 `vpnStatus/vpnRunning/vpnRunningProfileId`；`VpnService.generation` 守卫 + 60s 数据面证据看门狗 + 120s 启动超时 | `core/VpnService.ets:38-142` |
| 扩展侧 | `tryStart()` 串行重启；`publishVpnStatus('connected:<name>', true, runId)` | `vpnext/VpnExtAbility.ets:378-434, 628` |
| 订阅方过滤 | `subscribeVpnEvents` 有 subscriptionGeneration 防重订阅，但**不校验事件所属会话/代次** | `VpnIpc.ets:103-153` |

差距（对应 REQ-04/05/18 与 §4.2 两套状态独立）：
1. 事件无法关联「哪一次连接请求/哪个 configRevision」→ 迟到事件可能覆盖新会话状态（STATE-03）；
2. 扩展不上报实际生效的 revision/名单摘要 → UI 只能凭 `connected:` 前缀猜「已生效」；
3. 无「查询状态」命令 → UI 进程重建后无法主动拉取运行事实（§16.1 快照重播）；
4. saved/applied revision 未分离（§12.3）。

## 2. 事件信封（VpnIpc 扩展，向后兼容）

所有 VPN_STATUS/VPN_APPLIED 事件 payload 增加信封字段（旧字段原样保留，旧订阅方不受影响）：

```
protocolVersion: number   // 1
sessionId: string         // 扩展每次 startVpnExtensionAbility 会话；扩展进程内生成 UUID
generation: number        // UI 侧请求代次(与 VpnService.generation 对齐,随命令下发)
sequence: number          // 扩展进程内单调递增,每个事件 +1
operationId: string       // 触发本次状态变化的命令 ID(connect/apply/stop/query)
appliedRevision: number   // 扩展实际加载的配置 revision(0=未知/未加载)
configHash: string        // 该 revision 的 content checksum(与 ConfigRepository 一致)
emittedAt: number         // 扩展侧时间戳(仅展示/诊断,不用于排序)
```

规则：
- **排序用 sequence**，时间戳不可替代（§16.1）；
- UI 丢弃 `generation !== 当前请求代次` 或 `sessionId !== 当前会话` 的迟到事件并记诊断；
- 序列断层（sequence 跳跃）→ UI 发 `query` 命令请求全量快照；
- UI 重建后先 `query` 拿全量运行快照，再订阅增量，重叠事件按 (sessionId, sequence) 去重。

## 3. 命令通道（UI → 扩展）

新增事件 `VPN_CMD`（`com.nekobox.app.jynxen.VPN_CMD`），payload 携带信封 + 命令体：

| 命令 | 参数 | 扩展行为 | 回执 |
|---|---|---|---|
| `connect` | operationId, generation, revision, profileId | 加载指定 revision 快照编译配置并启动；同 operationId 重试直接返回已有结果（不重复起隧道） | VPN_STATUS(connecting→connected/failed, appliedRevision) |
| `apply` | operationId, revision, changedScopes[] | 校验 revision 与当前运行差异；需要重连则一次串行重连；可热切换（selector）走 Clash API | VPN_APPLIED(operationId, appliedRevision, effectivePerAppSummary) |
| `stop` | operationId, sessionId | 停止指定会话；sessionId 不匹配时返回说明不误停新会话 | VPN_STATUS(disconnected) |
| `query` | operationId | 回报全量运行快照：_sessionId/generation/appliedRevision/configHash/running/mode/effectivePerApp_ | VPN_STATUS(snapshot) |
| `queryApplyStatus` | operationId | 返回应用事务当前状态（用于 UI 被杀重开后查询，§12.3-8） | VPN_APPLIED(状态回执) |

约束（§16.1）：关键指令只在本应用 CommonEvent 边界内；不新增可被其他应用随意调用的公共控制入口 —— CommonEvent 发布方校验 bundleName（现有 `CommonEventPublishData.bundleName` 已限定本应用）。

## 4. ApplyCoordinator（配置应用事务状态机，§12.3）

```
draft → validating → saved(待应用) → applying → applied(运行确认) / failed
                     ↘ discarded              ↘ recovered(一次有界回滚) / failed(显示真实状态)
```

- 三个 revision 分别存储：`savedRevision`(ConfigRepository)、`requestedRevision`(本次 apply 参数)、`appliedRevision`(扩展回执)；
- 应用失败且存在上一份已验证快照 → **一次**回滚尝试（`ConfigRepository.rollbackTo(prev)` 内容以新 revision 提交），仍失败则显示真实断开/未知状态，不无限重试（§12.3-7）；
- 仅匹配 `operationId + sessionId + revision` 的回执可结束事务；迟到回执忽略并记录（§12.3-6）；
- UI 被杀不取消已进入扩展的有效事务；重开后 `queryApplyStatus` 查询（§12.3-8）；
- 重连非原子：失败时如实告知可能已断开，不宣称「无中断」（§12.3）。

### 4.1 与 ConfigRepository 的关系

- 保存 = `ConfigRepository.commit()` 推进 savedRevision（磁盘快照）；
- 应用 = 把 savedRevision 交给扩展；**保存成功不推进 applied**（§14.3 指针命名：draftManifest/savedManifest/appliedRevision 区分）；
- 回滚点 = 磁盘上前 2 个 revision（KEEP_REVISIONS=3）。

## 5. 与现状代码的映射与实施步骤

| 步骤 | 内容 | 阶段 |
|---|---|---|
| M1 | `VpnIpc.ets` 加信封类型与 `publishVpnStatusEx(...)`/`publishVpnApplied(...)`/`VPN_CMD` 发布与订阅（旧 API 保留转调） | P1 |
| M2 | `VpnService` 生成 operationId/session 期望值，命令走 VPN_CMD，状态按 generation 过滤 | P1 骨架 |
| M3 | `VpnExtAbility` 维护 sessionId/sequence/appliedRevision；处理 connect/apply/stop/query 命令；回执带信封 | P1 骨架（connect/query），P4 全量（apply 分流/名单/热切换） |
| M4 | `core/ApplyCoordinator.ets`：事务状态机 + 待应用变更计数 + 有界恢复；`PendingChangesPanel` UI | P1 骨架 + P4 UI |
| M5 | 扩展侧「只读 revision」：加载 `filesDir/config/` 指定 revision 快照编译（替代全量 Preferences 读） | P4（与分流/设置应用一起） |
| M6 | 全局待应用条（节点/分流/设置页统一） | P4 |

P1 交付判据：APPLY-01（保存/应用 revision 可区分）、APPLY-03（连续切换合并、迟到确认不覆盖）在主机测试可验证；设备回读确认（语雀/真机）在 P6。

## 6. 已知风险与对策

| 风险 | 对策 |
|---|---|
| CommonEvent 丢事件（真机已见） | 状态显示「状态待确认」+ 主动 query；不以计时器断言断开（§4.3-6） |
| 扩展进程被杀后 sequence 归零 | sessionId 变化即视为新会话；UI 收到新 sessionId 先 query |
| 旧版本客户端/扩展混跑（升级过渡） | protocolVersion 缺失时按旧语义处理，UI 标「状态待确认」；协议升版独立于 config schema |
| 扩展读快照与 UI 写快照并发 | 扩展只读不写；读失败回退旧「Preferences 全量读」路径并如实记录（P4 切换时保留一个版本的兼容读） |
