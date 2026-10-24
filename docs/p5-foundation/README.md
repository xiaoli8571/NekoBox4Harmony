# P5 订阅与诊断 — 阶段报告（W17–W20 完成）

日期：2026-10-24。依据：`docs/REDESIGN-PLAN-2026-10-23.md` §10（连接/日志/诊断）、§11（订阅三层模型/更新事务）。状态：**W17/W18/W19/W20 已交付，主机全绿**。真机项全部「待验」（本机 `hdc list targets` 为空）。未 commit。

## 1. 交付清单

| 工作包 | 交付 | 测试 |
|---|---|---|
| W17 三层模型 | `model/SubscriptionLayers.ets`：`SubscriptionSourceSnapshot`（原始层，不可变）/`UserOverride`（别名/收藏/排序/展示分组/传输字段覆盖+墓碑）/`EffectiveProfile`（有效视图）；身份键=订阅URL+传输特征指纹（**显示名不参与**）；两级合并（身份优先→名称锚点次级匹配，歧义记冲突不猜） | `tests/subscription-layers.cjs` 12 组 |
| W17 源快照存储 | `core/SubscriptionSourceStore.ets`：`filesDir/config/subscription-sources/<urlKey>/snapshot-<fetchedAt>.json`，每订阅留当前+上一份（GC）；**刻意不放 ConfigSnapshot**（配置快照只留 3 个 revision，原始层会随 GC 丢历史，违背「永不覆盖」） | 随 repository 套件 |
| W17 更新事务 | `core/SubscriptionRepository.ets`：runUpdate = 锁外获取→锁外解析+准备（UA 回退/改名/强制解析/去重）→ 串行提交段（重读当前态→身份合并→Preferences 兼容写→原始层文件→`ConfigRepository.commit` 段提交）；**基线 revision 漂移→按当前内容重算合并**（日志留痕）；**304 只推进成功检查时间**（节点/覆盖/原始层/快照其他段全不动，响应头新校验器沿用）；失败写 `lastError/lastAttemptAt`（failCount 仍归调用方 markSub*，不双计）；`Subscriptions.updateSubscription` 保留原签名做委托，全部既有调用点不变 | `tests/subscription-repository.cjs` 8 组 |
| W17 覆盖层写入口 | 覆盖层唯一持久化位置 = `ConfigSnapshot.content.userOverrides`，写入只经 `ConfigRepository.commit`（防漂移断言守着：无 `writePrefString('user_overrides'…)`) | subscription-repository 组 6 |
| W18 订阅 UI | `SubscriptionPage`：更多菜单加「清空节点」（二次确认，`SubscriptionRepository.clearSubscriptionNodes`，订阅记录保留）；批量反馈条加「查看节点/检测可用性」快捷动作（切节点页/全量测速，不强制连接）；`Index.updateAllSubscriptions` 逐订阅结果行（`PerSubOutcome`/`batchOutcomeText`，一个失败不覆盖其他）；删除订阅清理原始层+覆盖层（`purgeSubscriptionArtifacts`）；`SubDetailPage` 墓碑区（远端已移除 N 节点 + 「转为手动节点」= `convertTombstoneToManual`：原始层还原传输字段、覆盖随迁、墓碑移除、找不到原始记录拒绝） | subscription-layers 组 9/12、subscription-repository 组 7/8、subscription-list W18 组 |
| W19 连接列表 | `model/ConnectionView.ets` + `ConnectionsPage` 重写：目标（域名>IP>未提供）、网络、上下行、**开始时间**、内核规则表达式原文、代理链（chains 逆序）；搜索+分类筛选（仅实际采集到的 direct/proxy/reject）；行点击弹「为什么走这条线路」证据卡：目标→规则原文→**rulePayload 未提供就显示「未提供」，不伪造**→策略组链→最终节点+运行 revision（vpnAppliedRevision）+采集时间；本地规则名链接恒空（内核 rule 文本与编译 manifest 的唯一对应当前无法证明 → 按方案展示原文，K3 扩展） | `tests/connection-view.cjs` 4 组 |
| W20 日志清除 | `model/LogView.ets`：清除标记=偏移+文件身份；`tailStartOffset`：路径同且 size≥偏移→从标记偏移继续（**旧日志不重现、新日志仍可见**）；轮转/截断（size 回退）或换路径→按新文件从 0；mtime 不参与判定（append 每秒改 mtime，掺入会把追加误判成新文件——主机测试曾抓出此缺陷）。`LogPage`：清除按钮记录标记（Preferences `log_clear_marker`），页面重建后恢复 | `tests/log-view.cjs` 组 1/2 |
| W20 导出脱敏 | `redactLogText`：URL 凭据（user:pass@→user:****@）、敏感查询参数（token/key/secret/password/uuid…值打码保留首尾）、分享链接 base64 载荷（vmess://…→`<redacted:n>`）、password 字段值打码；普通行与时间戳/等级不动。`LogPage` 导出改为两键对话框：预览（前 12 行）+「导出脱敏」（默认主按钮）/「导出原文」（红色次要，用户显式选择） | log-view 组 3 |
| W20 流量基准 | `model/TrafficBaseline.ets`：重置=记录基准偏移（含会话 epoch，Preferences `traffic_display_baseline`）；`displayTotals`=当前−基准；内核重启（计数器小于基准）→基准作废显示原值不出负数。`Index` 轮询走 `displayTotals`（**修复「清除流量统计被 1s 轮询写回」已知问题**）；`VpnExtAbility` 通知在会话启动读同一基准 | log-view 组 4 |
| W20 诊断包 | `core/Diagnostics.ets`：固定键序 JSON（schema/appVersion/versionCode/kernelVersion/kernelCapability/sdkApiLevel/saved+runningRevision/applyState/errorCategory/订阅与节点**计数**/probeParams/probeSummary/logTail）；logTail 全量脱敏+尾部 80 行；**不含节点密钥与订阅 URL**；`diagnosticsLooksSafe` 自检（缺键或未脱敏凭据→false）。`ToolsPage`「生成诊断包」→ 预览 → 复制（不自动上传） | `tests/diagnostics.cjs` 3 组 |

## 2. 关键设计决定

1. **身份=订阅URL+传输特征指纹（不含显示名）**：远端改名=同一节点（保 id/收藏/排序/流量），这是对旧「按名合并」的行为变更；身份变了但源名称唯一对应 → 名称锚点次级匹配视为「参数变更」，覆盖迁移、用户传输覆盖记冲突不自动套；同名多对一 → 冲突按加删处理（§11.4 不把覆盖随机套）。
2. **原始层独立于配置快照**：ConfigSnapshot 只保留 3 个 revision，原始层入内会被 GC 掉历史；独立文件每订阅留 2 份，支撑墓碑恢复/转手动。
3. **304 语义收窄**：只推进 lastUpdate/nextUpdateAt/lastAttemptAt/lastError + userinfo/校验器沿用；Preferences 节点、覆盖层、原始层、快照 profiles/userOverrides 段一律不动（主机测试以哨兵数据验证段透传）。
4. **兼容层口径**：Preferences 仍是运行态读源（页面/扩展读它），快照 sections 每次事务从活态刷新后经 commit 收口（与 W16 设置事务同口径）；快照提交失败数据已在 Preferences，日志留痕不伪造 revision，下次事务自愈。
5. **排序语义**：匹配节点保留旧 sortOrder（排序=用户覆盖，§11.4）；远端顺序只给新节点排号（与 Android「内容未变仅顺序变→重排」不同，有意为之）。

## 3. 验证证据

- release `assembleHap` **BUILD SUCCESSFUL**，HAP **14,964,820 B**，包内 `.so` sha256 `9b05c0bfccad124f`（16 导出，冻结内核未被触碰）。
- **Node 40 套件全 PASS**（P4 为 35，新增 subscription-layers 12 组 / subscription-repository 8 组 / connection-view 4 组 / log-view 4 组 / diagnostics 3 组；sub-etag、sub-ua-fallback、sub-parity-subscription 三个防漂移套件已按 W17 迁移后的结构改指新事务文件，断言意图保留未删）。
- `tests/hostprobe` Go 套件 PASS（`ok parityprobe`）。
- 构建修复记录：arkts-limited-throw（rethrow 需包装 Error）、ClashParseResult/SubFetchResult 显式导入（缺导入致推断 any）、advanceSuccessOnly 多传实参、Subscriptions 误删 ensureGroupByName 导入。

## 4. 降级与待办（如实）

| 项 | 现状 | 说明 |
|---|---|---|
| 通知栏基准同步 | 会话启动时读一次 | 扩展进程 Preferences 缓存约束：UI 会话中途重置，通知最迟在下一次会话/apply 后同基准（已知降级） |
| 规则名链接 | 恒空 | 内核 rule 表达式↔本地编译 manifest 的唯一对应无法在不伪造的前提下建立；按方案 §10.2 展示内核原文，K3 可选扩展 |
| 诊断 probe 摘要 | 参数/结果摘要为简化文本 | ProbeStore 逐项结果未接入（计数级即可定位，后续如需再加） |
| 订阅页文案 | 中文兜底常量 | 资源键随 P6 i18n 统一（与 P4 遗留同批） |
| forceResolve+动态 DNS | 身份键含解析后 IP | 服务器 IP 变化会表现为加+删（身份定义使然，与 Android 按名合并的取舍不同，如实记录） |
| 别名编辑 UI | 覆盖模型支持 alias，无专门编辑入口 | 现有节点改名写 Profile.name；显式别名编辑器留 W21/P6 |
| 真机 | 全部待验 | 订阅更新全链路/墓碑转手动/连接证据卡/日志清除标记跨重建/流量基准/通知基准——无设备 |

## 5. REQ 映射

- REQ-12（连接列表+为什么走这条线路）：✅ 主机（connection-view 4 组 + 构建）；真机待验。
- REQ-16（订阅卡/更新结果）：✅ 主机（SubscriptionList 17+W18 组 + 构建）；真机待验。
- REQ-17（更新事务/缓存/覆盖/冲突处理）：✅ 主机（subscription-layers 12 组 + subscription-repository 8 组）；真机待验。
- REQ-20（日志/流量清除、诊断）：✅ 主机（log-view 4 组 + diagnostics 3 组）；真机待验。
