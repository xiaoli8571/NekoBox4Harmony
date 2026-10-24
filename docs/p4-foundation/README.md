# P4 分流与设置应用 — 阶段报告（W13/W16 已完成，W14/W15 进行中）

日期：2026-10-24。依据：`docs/REDESIGN-PLAN-2026-10-23.md` §8（分应用）、§9（策略组）、§11（订阅/覆盖）、§12（设置与配置应用）、§20.1（W13–W16）。状态：**W13 规则模型与 W16 设置应用事务已交付并全绿；W14（分流四子页 UI）与 W15（策略组管理/热切换）未开始**。未 commit。

## 1. 交付清单

| 工作包 | 交付 | 测试 |
|---|---|---|
| W13 规则类型化 | `model/RoutingRules.ets`（1649 行）：类型化规则、旧多字段 AND 行无损保留（`legacyRow`）、稳定 ID、校验（空载荷/CIDR/端口/正则/重复/规则集引用）、重叠检测、编译 manifest（排除禁用与 unsupported、按序、fnv1a32 哈希）、`toKernelItems` 与 `buildCustomRule` 16 字段同口径、DNS 投影校验、旧包名规则处理选项 | `tests/routing-rules.cjs` 21 组 |
| W16 设置 Schema | `model/SettingsSchema.ets`：54 项 registry（= `AppSettings` 全字段，防漂移测试直接读源码比对）、9 分区、三档生效分类（31 reconnect / 11 nextTask / 12 immediate，含 lead 裁决 3 项改即时效）、`diffSettings`/`summaryText`/`impactLines`/`searchSettings`/`sectionDefaults`/`defaultsForAll` | `tests/settings-schema.cjs` 25 组 |
| W16 设置页 | `pages/SettingsPage.ets`：待应用条（差异计数 + 影响）、变更列表 sheet（旧值→新值 + 分类徽标）、应用/稍后/放弃、5 个分区「恢复默认」（只写草稿）、设置搜索面板、模式切换走同一事务 | 构建 |
| W16 应用事务 | `core/VpnExtAbility.handleApplyCommand`（扩展侧）：幂等、快照只读校验（schema/revision/checksum）、本地设置一致性校验、单次串行重启、回执 `ok/appliedRevision/error`；`queryApplyStatus` 查询；`VpnIpc.publishVpnApplied(+error)` / `VpnApplyResult` / `subscribeVpnApplied`；`EntryAbility` 写入 AppStorage 六键 | 构建 |
| W16 全局横幅 | `pages/Index.ets`：节点/分流页顶部待应用横幅（应用/稍后、applying 进度）、`ConfigRepository.commit(mutation)` → `markSaved` → 运行中发 `apply` 命令 → `@Watch` 匹配 operationId 后 `acceptAck`；未运行标记"下次连接生效"；模式切换 300ms 去抖合并；60s 无回执如实失败 | 构建 |
| 订阅页 ⋮（P3 收尾） | 排序（名称/最近）、更新选中、自动更新设置入口、删除选中（二次确认）、更新全部/导入/查看失败订阅 | 构建 + 29 套件 |

## 2. 关键设计决定

1. **配置应用三段 revision**（保存/请求/运行）：UI 只以回执中的运行 revision 为"已生效"依据；扩展不初始化 ConfigRepository（写者只在 UI 进程），避免两进程同时裁决孤儿文件。
2. **`settings_out_of_sync:<key>`**：快照 settings 与本地 Preferences 不一致时拒绝重启（否则重启加载旧设置 = 假生效）。错误码见 `docs/p4-design/apply-transaction.md`。
3. **旧规则不放宽**（§8.5 红线）：类型化只覆盖主条件，旧行其余条件存 `legacyRow` 并在编译/内核投影时合并，避免"删掉条件后匹配范围变大"。
4. **DNS 投影只报可证明的问题**：`dns_loop_risk` 仅针对"directDns 自身是域名"的自举回环（有 ConfigBuilder 行号佐证）；"直连规则命中服务器域名"经核实不构成回环，**未虚构告警**。
5. **applyClass 事实裁决**：`autoConnect`/`networkChangeResetConnections`/`wakeResetConnections` 改即时效（事件发生时 `loadSettings()` 现读或纯 UI）；`speedIntervalMs`/`profileTrafficStatistics` 保持 reconnect（扩展在 startVpn/teardown 用启动时缓存的 settings）。

## 3. 验证证据

- release `assembleHap` **BUILD SUCCESSFUL**（33 tasks），HAP **14,745,865 B**，包内 `.so` `9b05c0bf…`（16 导出）。
- Node **31 套件全 PASS**（新增 `routing-rules` 21 组、`settings-schema` 25 组）；Go hostprobe 全 PASS。
- 构建修复记录：`SettingsSchema` 用了 ArkTS 禁止的 `Object.prototype.hasOwnProperty.call`（arkts-no-func-apply-call / no-prototype-assignment）→ 改 `Object.keys().indexOf`。

## 4. 降级与待办（如实）

| 项 | 现状 | 计划 |
|---|---|---|
| 36 个 `labelToken` 缺资源键 | 变更列表/搜索回落 token 原文 | P6 i18n 统一补键（含 en_US） |
| 设置搜索 | 结果面板 + 跳分区，非逐字段隐藏 | P6 或 W16 余项 |
| 恢复分区默认 | 仅覆盖 5 个页内分区（外观/路由/DNS/入站/Clash API），且部分为近似映射 | 待设置页分区头按 schema 重排 |
| 壳层横幅不显示数字 | 因 `pendingChanges` 是批次计数，尚未按 diff 计数 | 下一轮接 `diffSettings` 计数（SettingsSchema 已可用） |
| 订阅排序记忆 | 会话内 `@State`，重启回默认 | 待 NavMemory 增字段（P5） |
| 旧「保存」按钮 | 与待应用条并存（仅持久化草稿） | 待 W16 收尾统一 |
| **W14 分流四子页** | 未开始（规则模型已就绪，页面与 ConfigBuilder 接线待做） | 下一轮 |
| **W15 策略组管理/热切换** | 未开始（Clash API 热切换路径需 W15 设计） | 下一轮 |
| 真机 | 应用事务切换中杀进程/返回、扩展回收后查询、失败后旧连接状态 | P6 |

## 5. 下一轮计划

1. **W14**：`RouteRulesPage` 重构为四子页（分应用 / 域名·IP 规则 / 规则集 / 策略组），规则编辑器接 `RoutingRules`（校验/编译/旧包名规则处理），ConfigBuilder 改吃 `compileManifest`。
2. **W15**：策略组管理（类型/成员/前置/落地）、稳定 tag、热切换（Clash API PUT + GET 核对 now）、自动优选参数。
3. W16 收尾：横幅计数、保存按钮合并、分区头按 schema 重排。

---

## 6. 追加交付（2026-10-24 第二批，W14/W15 完成）

| 交付 | 内容 | 测试 |
|---|---|---|
| 规则编辑器模型 | `model/RuleEditor.ets`：RuleForm 往返（旧 AND 行条件不丢，存 legacyRow 旧键位）、12 个校验码逐字段定位、正则原文保留、目标缺失不自动替换、`moveRule`、旧规则三动作（convert 无用户改写一律拒绝）、AND 逻辑预览 | 28 组 |
| Clash API 客户端 | `core/ClashApi.ets`：GET/PUT /proxies（对 sing-box 源码核对：204/400 Must be a Selector/404/401；空 secret 放行），可注入传输 | 14 组 |
| 策略组模型 | `model/PolicyGroups.ets`：稳定 tag（`group-<enc(id)>`）、校验（空组/缺失/环/重复 tag/失效前置）、compileGroups、热切换决策、`verifyNow`（PUT 后 GET 核对 now）、`actualMemberView`（未知即"实际节点未知"） | 20 组 |
| 内核组图 | ConfigBuilder：非选中策略组也按稳定 tag 下发（selector/urltest，参数与选中组同口径），节点按 tag 去重（多组共享成员不重复）；规则可用 `group:<id>` 指向组；空组不下发、引用空组的规则跳过并告警 | outbound-graph 12 组（+3 新） |
| 分流四子页 | `RouteRulesPage` 重写：分应用/域名·IP 规则/规则集/策略组；最终编译顺序编号、来源标注、校验聚合条、旧规则区、规则集真实时间戳（未验证不标）、策略组真实状态与切换流程（selectProxy→GET 核对才打"正在使用"） | route-rules-ui + 构建 |
| 规则编辑器页 | `RuleEditPage.ets`（新建）：校验 error 阻断/warning 放行、高级区恒显条件数、logical/and 预览、目标缺失给替代候选不自动写回、保存只写草稿 | 构建 |
| 本地化 | 44 个设置项/分区资源键（base+en_US 键集合一致）+ `tests/i18n-keys.cjs` 防漂移 | 6 组 |
| 导航 | `NavMemory.hasRoutingTab()`：区分"用户选过的子页签"与旧默认值 | navigation 套件 |

**组播语义修正（§7.4/C7，行为变更）**：旧 `ip_cidr`+`source_ip_cidr` 同规则 AND 几乎永不匹配（组播实际未被拒）→ 改为 logical OR（源**或**目的命中即拒绝），范围不变；`tests/parity-config.cjs` 40 组已按新语义断言，见 `docs/upgrade-notes-2.2.md` §3。

**最终验证**：release assembleHap BUILD SUCCESSFUL（HAP **14,897,920 B**，.so `9b05c0bf…`）；**Node 35 套件全 PASS**；Go hostprobe PASS。

**遗留（转入下阶段）**：策略组切换目前仅覆盖承接流量的 `proxy` 组（多组稳定 tag 切换 UI 待 W15 第二批）；分应用完整名单管理仍留设置页（分流页为摘要+入口）；设置页 `SETTING_LABELS` 静态映射待扩到 54；`runningGroupTags`（运行中分组不可作为出站目标）待壳层下发；AND/OR 逻辑落盘为平铺规则（内核对不同字段本就 AND，`toLogicalExpression` 仅作预览说明，无功能差异，如实记录）。
