# P4 设计：配置应用事务（草稿→应用→运行确认）

日期：2026-10-24。依据 `docs/REDESIGN-PLAN-2026-10-23.md` §12.2（全局待应用条）、§12.3（应用事务状态机）、§16.1（版本化 IPC）、§18（配置应用失败/恢复）。状态：扩展侧已实现（本文件），UI 侧接线进行中。

## 1. 三段 revision

| revision | 含义 | 存储 |
|---|---|---|
| 保存 revision | 最后一次成功提交的快照（`ConfigRepository.getActiveRevision()`） | manifest + 快照文件 |
| 请求 revision | 本次应用事务的目标快照 | `VpnCommand.revision` |
| 运行 revision | 扩展实际加载并确认启动的 revision | 回执 `VpnEnvelope.appliedRevision` |

三者不一致是合法中间态：UI 只能以回执中的运行 revision 作为"已生效"依据。

## 2. 消息与字段（当前实现）

- UI → 扩展：`VpnCommand{cmd:'apply'|'queryApplyStatus', operationId, generation, revision, sessionId}`
- 扩展 → UI：`VPN_EVENT_APPLIED{ok, perAppSummary, error, env{operationId, sessionId, generation, appliedRevision}}`
- UI 侧 `EntryAbility.subscribeApplyResults()` 写入 AppStorage：`vpnApplyOk / vpnApplyError / vpnApplyPerApp / vpnApplyOperationId / vpnAppliedRevision / vpnApplySessionId`。

## 3. 扩展侧流程（`VpnExtAbility.handleApplyCommand`）

1. **幂等**：`operationId == appliedOperationId` → 重播成功回执；`== applyingOperationId` → 忽略重复投递（不发起第二次重连）。
2. **revision 合法性**：`revision <= 0` → `invalid_revision`（不重启）。
3. **只读快照校验**：读 `filesDir/config/config-snapshot-<rev>.json`，`parseSnapshot` 复核 schema/revision/**checksum**；不存在/损坏/版本不支持/校验失败 → `snapshot_unavailable`。
   - 扩展进程**不初始化 ConfigRepository**：写者只在 UI 进程，避免两进程同时 recover/GC 裁决孤儿文件。
4. **本地设置一致性**：`refreshStore` + `loadSettings` 逐键与快照 `content.settings` 比较（JSON 值比较，键名大小写敏感）；不一致 → `settings_out_of_sync:<key>`，**不重启**（否则重启加载的仍是旧设置，等于假生效）。
5. **一次串行重启**：`publishStatus('switching')` → `forceRestartRequested = true` → `tryStart()`（复用既有防重入/代次守卫/看门狗）。
6. **回执**：成功 → `ok=true, appliedRevision=revision, perAppSummary=当前名单摘要`；失败 → `ok=false, appliedRevision=0, error='apply_failed'`。迟到/不匹配的确认由 UI 丢弃。
7. **查询**：`queryApplyStatus` 返回当前 `started` 状态 + `lastAppliedRevision`（UI 重启后避免重复投递）。

## 4. 错误码

| 码 | 含义 | UI 应对 |
|---|---|---|
| `invalid_revision` | 目标 revision 非法 | 报错，检查 ApplyCoordinator 的 savedRevision |
| `snapshot_unavailable` | 快照缺失/校验失败 | 提示"配置保存异常"，可重试保存 |
| `settings_out_of_sync:<key>` | 本地设置未写入快照 | 先保存设置再应用（一次重试） |
| `settings_unreadable` | 设置读取失败 | 报错，重试 |
| `apply_failed` | 重启失败 | 显示真实原因，保留待应用，不无限重试 |
| `not_running` | 查询时未连接 | 提示离线保存/下次连接生效 |

## 5. UI 侧约定（进行中）

- 草稿 = 当前设置对象；已应用 = 活动快照 `content.settings`；差异由 `model/SettingsSchema.diffSettings` 计算。
- 应用流程：`ConfigRepository.commit(...)` → `ApplyCoordinator.markSaved(revision)` → 运行中发 `apply` 命令 → 以 `vpnApplyOperationId + vpnAppliedRevision` 匹配后 `acceptAck`；60s 无匹配回执 → `onFailure`（有界恢复一次），横幅回到待应用并显示真实原因。
- 放弃草稿：恢复为已应用值并 `discardDraft()`。
- 未连接时应用：只提交快照 + 标记"下次连接生效"（不假装已生效）。

## 6. 已知边界

- 重启并非无中断原子交换：新连接失败可能已断开旧连接，UI 必须如实显示（§12.3 末段）。
- 快照 checksum 为空的历史/手写文件不会被判为损坏（`parseSnapshot` 仅在声明 checksum 时校验）；正常的写入路径始终声明 checksum。
- `configHash` 暂不参与校验（空串），K2 会话信息接入后可绑定实际加载文件的哈希。
- 真机项：切换中返回/杀进程恢复、扩展被系统回收后查询状态、失败后旧连接是否可用（P6）。
