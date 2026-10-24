# P0 新方案冲突文档清单

日期：2026-10-24。依据：docs/REDESIGN-PLAN-2026-10-23.md §0、§20 P0（「新方案冲突文档清单」交付项）。本文列出 AGENTS/HANDOFF/DEVPLAN/CHANGES 及代码注释中**与本轮方案冲突或已过时**的表述、发生位置、新方案口径、处置阶段。原则（§7 用户要求）：施工阶段同步更新与新行为冲突的说明，**保留历史背景，不篡改旧验收记录**。

## 1. 行为冲突（新方案推翻现有口径，需在对应阶段同步改文档）

| # | 冲突点 | 现有表述（位置） | 新方案口径 | 处置 |
|---|---|---|---|---|
| C1 | 页面术语：配置/分组/路由 → 节点/订阅/分流 | AGENTS.md「主菜单口径」抽屉固定 7 项（配置/分组/路由/…）；DEVPLAN.md:30/220/333/336 大量「配置页/非配置页」表述；CHANGES.md 7 处 | §3.1/REQ-01：七个一级入口为节点、订阅、分流、设置、日志、工具、关于 | P3（W11）改导航时同步 AGENTS.md「主菜单口径」与 DEVPLAN 新章节；旧验收记录保留 |
| C2 | 首页测速入口 | DEVPLAN.md:188「首页移除测速入口，订阅管理保留测速能力」 | §3.3/§4.1：节点页顶栏常驻「检测可用性」+ 更多菜单「添加节点/导入、排序筛选、批量管理、连接列表」 | P3；DEVPLAN:188 保留为历史，新章节注明取代 |
| C3 | 测速回退语义 | AGENTS.md「URL Test…失败自动回退 TCPing」；代码 LatencyTester.ets:349-362 fallback 整批回退 TCPing | §6.4/REQ-10：坏节点分批隔离，不整批退化 TCPing；仅整轮内核不可用时显式提供其他方式 | P2；同步 AGENTS.md 该条 |
| C4 | HTTP 判据默认值 | CHANGES.md:1547「默认不判 HTTP 状态码（expectStatus='any'）」；代码 LatencyTester.ets:346 | §6.1/REQ-04：**新装默认 2xx**；旧装保留 any 并明确显示、可切换 | P2 + 迁移逻辑（已装用户保留 any，首次进入检测设置说明差异） |
| C5 | 测速结果模型 | 代码 Profile.status/ping/error/latencyTestedAt 三件套（AGENTS.md「结果模型与安卓 ProxyEntity 一致」） | §6.2/REQ-08：独立 ProbeResult（runId/configHash/method/target/path/时间），旧字段作兼容投影 | P2；AGENTS.md 结果模型条目改写 |
| C6 | 测速菜单入口 | AGENTS.md「顶栏 ⋮ 菜单两个入口「TCPing」/「URL Test」」 | §3.3：主入口「检测可用性」，方式选择 HTTP/TCPing 为参数选择而非两个菜单 | P3；与 C2 一并改 |
| C7 | 组播拒绝语义 | CHANGES.md:1050（Android 字面 AND 生成）；功能审计「现有测试注释明确把它作为 Android 字面行为保留」 | §7.4：修正为「源或目的属于指定范围即拒绝」明确逻辑结构，用真实内核匹配验证，**升级说明告知** | P4（W13）；同步测试注释与升级说明 |
| C8 | 规则集下载失败策略 | 旧 DEVPLAN「失败跳过不影响启动」（功能审计 §2 已证实不符）；现行代码 remote 定义直接输出 | §7.5/REQ-19：已验证缓存 + 首次失败阻止新配置应用 | P1（W08）；旧 DEVPLAN 声明注记过时 |
| C9 | 分应用空名单 | 现行代码 include 空名单=全部应用按路由规则处理（VpnExtAbility.ets:514-525，审计 §2 P1-1） | §8.2/REQ-13：include 空列表**阻止连接/应用** | P1（W07）；升级说明告知 |
| C10 | 按包名指定出站 | 现行路由页有 packages 输入（新规则 packagesEnabled=false，界面无开关） | §8.5/REQ-14：编辑器移除该控件，历史 packages 规则归「需处理的旧规则」保留原文 | P4（W14） |
| C11 | 备份 schema v4 | Backup.ets schema=4（导入接受 1—4） | §14.4：schema=5，继续读 1—4，拒绝未来未知版本 | P1（W04） |
| C12 | 规则集状态显示 | RouteRulesPage.updateRemoteRuleSet 用编辑时间冒充更新时间（审计 §2 P2） | §7.5：lastAttemptAt/lastSuccessfulDownloadAt/validatedAt 分离 | P1/P4 |
| C13 | selector 热切换缺失 | 审计 §2 P2「当前首页 onNodeTap() 总是全量重启，没有消费 ClashApi.selectProxy()」 | §9.2/REQ-15：selector 热切换 PUT+GET 确认 | P4（W15） |
| C14 | 订阅更新语义 | 现行 304/覆盖处理；无源快照/覆盖分离 | §11.3/§11.4/REQ-17：三层模型（源快照/UserOverride/EffectiveProfile），更新事务 | P5（W17） |

## 2. 文档过时（非行为冲突，顺手修正）

| # | 位置 | 问题 |
|---|---|---|
| S1 | AGENTS.md 版本段 | 写「自 2.2.0 起版本号已统一 = 2200000/2.2.0」，实际 AppScope/app.json5 已是 2200001/2.2.1 |
| S2 | Index.ets:1129 注释 | 「旧的 150/400 三档阈值已按 1:1 要求删除」与同文件 1008-1011 行实际保留 <150/<400 分档矛盾（AGENTS.md 2026-10-23 已确认按用户反馈改回分档）；P3 UI 时清理 |
| S3 | DashboardPage.ets | 死文件（全仓无引用）；AGENTS.md 已定「Dashboard(yacd) 不做」；P3 导航改造时随 W01 移除类处理 |
| S4 | HANDOFF.md | 仍以「G 阶段 → 1.6.0」为题、角色分工为旧服务器流程；不影响行为，P7 发布前统一改写指向 REDESIGN-PLAN |

## 3. 一致项（核对后无冲突，防止重复劳动）

- **保活口径**：AGENTS.md 2026-10-23 定稿（保留 `backgroundModes:["dataTransfer"]`、不申请 TASK_KEEPING/KEEP_BACKGROUND_RUNNING_SYSTEM、长时任务仅真实传输期）与方案 §17.3 完全一致。已核对 module.json5:33 `backgroundModes:["dataTransfer"]` 在位、READ_PASTEBOARD 已声明（module.json5:65）。
- **权限政策**：READ_PASTEBOARD 保留口径（AGENTS.md 2026-10-23 AGC 退回教训）与方案 §17.4 一致；改权限需跑 tests/permission-policy.cjs。
- **签名/版本约束**：build-profile.json5 无签名入库、签名材料不入源码——与方案 §17.6 一致。
- **冻结内核约定**：改 core/ 必须重编 .so + 重新 assembleHap——与方案 §17.8 一致。
- **150/400 延迟分档**：方案 §13.1「继续保留」与 AGENTS.md 2026-10-23 改回分档、实际代码一致（仅 S2 注释过时）。
- **Web 仪表板不做**：AGENTS.md「Dashboard(yacd) 不做」与方案 §0.2「不新增独立 Web 仪表板」一致。

## 4. 处置约定

1. 每个阶段完成时，同步本文档所列冲突点的对应文档（AGENTS.md「当前状态」段、DEVPLAN.md 新章节、CHANGES.md 追加记录），旧记录原文保留。
2. 行为变更（C3/C4/C6/C7/C9/C10）必须进入 §24.2-9 的升级说明清单。
3. 本清单随实施推进更新状态；完成一条标记 ✅ 并注明 commit。
