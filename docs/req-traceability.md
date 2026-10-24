# 需求追踪矩阵（REQ-01 — REQ-24）

依据 `docs/REDESIGN-PLAN-2026-10-23.md` §2（需求表）、§24.2-1（每条需求要有实现 + 证据）、§24.3。状态口径：**✅ 已实现且有主机证据** / **⚠️ 部分实现**（缺口写在备注） / **⏳ 未开始**；所有**真机项一律「待验」**，不计入 ✅。最后更新：2026-10-24（P6 完成：i18n 收口/双栏/热区/无障碍/等宽；P7 文档轮进行中）。

| REQ | 需求 | 计划阶段 | 状态 | 实现位置 | 证据 | 备注 / 缺口 |
|---|---|---|---|---|---|---|
| REQ-01 | 页面术语统一（配置→节点、分组→订阅、路由→分流） | P3 | ✅ | `core/Navigation.ets`、`resources/*/element/string.json`（`nav_*` 仅改值） | `tests/navigation.cjs`；P3 报告 | 键名未改，配置/备份兼容 |
| REQ-02 | 七页职责清晰、跨页路由与返回语义稳定 | P3 | ✅ 主机 / 待验 真机 | `Navigation.resolveBack`、`Index.onBackPress`、`NavMemory` | `tests/navigation.cjs`（11 组） | 真机返回栈与恢复待设备 |
| REQ-03 | 页面专属顶栏、图标有名称、无全局空转按钮 | P3/P6 | ✅ 主机 / 待验 真机 | `Navigation.topBarActions/ActionState`、`Index.visibleActions/isActionWired`、`GlowIconButton.a11yText/a11yReason` | `tests/navigation.cjs`、`tests/p6-ui-static.cjs` 组 2；P6 报告 | 图标读屏名称+禁用原因(nav_reason_*)已接(P6/W21)；读屏实测待真机 |
| REQ-04 | 紧凑连接状态卡、错误重试与原因入口 | P3 | ✅ 主机 / 待验 真机 | `model/HomeView.statusCardView`、`Index.statusCard/onStatusPrimaryAction` | `tests/home-view.cjs`（23 组） | 视觉与触达待真机 |
| REQ-05 | 浏览选择 / 连接目标 / 实际出站严格区分 | P2/P3/P4 | ⚠️ | `HomeView`（会话×连通性、选中/连接目标）、`ProbeResult.computeProfileConfigHash` | `tests/home-view.cjs`、`tests/probe-result.cjs` | **实际出站**依赖策略组热切换（W15 进行中） |
| REQ-06 | 节点行层次、实际使用标记、可见更多入口 | P3 | ✅ 主机 | `HomeView.nodeRowView/NodeRowContext` | `tests/home-view.cjs` | 实际使用标记在组切换落地后接入 |
| REQ-07 | 搜索、收藏、排序、筛选、批量操作范围明确 | P3 | ✅ 主机 | `HomeView.filterNodes/sortNodes`、`NavMemory.filters`、`Index.nodeToolbar` | `tests/home-view.cjs`、`tests/navigation.cjs` | 批量检测/删除范围已在 ⋮ 菜单声明 |
| REQ-08 | HTTP/TCP 测试区分、来源与时间持久化 | P2 | ✅ | `model/ProbeResult.ets`、`core/ProbeRunner.ets`、`core/ProbeStore.ets` | `tests/probe-result.cjs`、`probe-runner.cjs`、`probe-store.cjs`、`latency-parity.cjs` | — |
| REQ-09 | 进度、成功失败计数、取消、仅看可用、重测失败 | P2/P3 | ✅ 主机 | `ProbeCoordinator.summary`、`ProbeFilters.summarize/shouldShowRetest`、`Index` 检测进度 | `tests/probe-coordinator.cjs`、`probe-filters.cjs` | — |
| REQ-10 | 坏节点隔离、绑定回退可见、不静默假绿 | P2 | ✅ 主机 | `ProbeCoordinator.onBatchStartFailed`（split/isolated/exhausted）、`ProbeRunner` 逐节点降级 | `tests/probe-coordinator.cjs`、`probe-runner.cjs`、`parity-latency.cjs` | 真机探测结论待设备 |
| REQ-11 | 分流摘要列表 + 独立基础/高级编辑 | P4 | ✅ 主机 / 待验 真机 | `model/RoutingRules.ets`、`model/RuleEditor.ets`、`pages/RouteRulesPage.ets`、`pages/RuleEditPage.ets` | `tests/routing-rules.cjs`、`rule-editor.cjs`、`route-rules-ui.cjs` | 编译顺序编号/来源标注/条件计数已落；真机交互待验 |
| REQ-12 | 真实连接展示目标、规则、策略组、最终节点 | P5 | ✅ 主机 / 待验 真机 | `model/ConnectionView.ets`、`pages/ConnectionsPage.ets` | `tests/connection-view.cjs`（4 组）；P5 报告 | rulePayload 不伪造、规则名链接按方案留 K3；真机证据卡待验 |
| REQ-13 | 分应用三模式、有效数量、待应用状态、空名单门控 | P1/P4/P6 | ✅ 主机 / 待验 真机 | `model/PerApp.ets`、`model/PerAppPolicy.ets`、`VpnExtAbility`（启动前同一纯函数）、**分流页 PerAppManager（2026-10-24 自设置页整体迁入,保存即走应用事务）** | `tests/per-app-policy.cjs`（8 组）、`tests/functional-audit.cjs`；真机装机 | UI 缺口已关闭;真机 include/exclude 实测待验 |
| REQ-14 | 不支持包名指定出站入口收口与旧数据保护 | P1/P4 | ✅ 主机 | `RoutingRules`（`unsupportedOnPlatform`、`legacyRow`、`legacyHandlingOptions`） | `tests/routing-rules.cjs`、`tests/migration-v5.cjs` | 旧规则区三动作 + 编辑器移除控件已落（convert 不自动推导）；真机待验 |
| REQ-15 | 策略组手动/自动管理、真实选中项、热切换 | P4 | ⚠️ | `core/ClashApi.ets`、`model/PolicyGroups.ets`、ConfigBuilder 多组稳定 tag 下发、分流页策略组 tab | `tests/clash-api.cjs`、`policy-groups.cjs`、`outbound-graph.cjs` | 切换 UI 目前仅覆盖运行图 `proxy` 组；urltest 组如实不给切换；真机热切换待验 |
| REQ-16 | 订阅卡节点数、流量/到期、成功时间与更新结果 | P5 | ✅ 主机 / 待验 真机 | `model/SubscriptionList.ets`、`pages/SubscriptionPage.ets`、`pages/SubDetailPage.ets` | `tests/subscription-list.cjs`（17+W18 组）；P5 报告 | 逐订阅更新结果/失败原因（tx 落 lastError）/危险操作分离/清空节点/墓碑转手动已落；真机待验 |
| REQ-17 | 更新事务、缓存、差异、用户覆盖与冲突处理 | P1/P5 | ✅ 主机 / 待验 真机 | `model/SubscriptionLayers.ets`、`core/SubscriptionRepository.ets`、`core/SubscriptionSourceStore.ets` | `tests/subscription-layers.cjs`（12 组）、`tests/subscription-repository.cjs`（8 组）；P5 报告 | 三层模型+两级身份合并+墓碑/复活+304 只推进时间+基线漂移重算；覆盖层唯一写入口=commit（防漂移断言）；真机待验 |
| REQ-18 | 设置即时/下次/重连分类，统一待应用机制 | P4 | ✅ 主机 / 待验 真机 | `model/SettingsSchema.ets`、设置页待应用条、`ApplyCoordinator`、扩展 `handleApplyCommand` | `tests/settings-schema.cjs`（25 组）；`docs/p4-design/apply-transaction.md` | 真机切换中恢复/杀进程待验 |
| REQ-19 | 规则集真实下载状态、已验证缓存、首次失败策略 | P1/P4 | ✅ 主机 / 待验 真机 | `core/RuleSetRepository.ets`、K1 `CGoValidateSRSFileV1`、分流页规则集子页（真实时间戳,未验证不标） | `tests/ruleset-repository.cjs`（17 组）、`tests/route-rules-ui.cjs`、`tests/hostprobe/k1_validate_test.go`；P4 报告 §6 | 真机下载/断网首连待验 |
| REQ-20 | 日志/流量清除真实生效、诊断错误可读 | P5 | ✅ 主机 / 待验 真机 | `model/LogView.ets`、`model/TrafficBaseline.ets`、`core/Diagnostics.ets`、`pages/LogPage.ets`、`pages/ToolsPage.ets`、`Index` 轮询、`VpnExtAbility` 通知基准 | `tests/log-view.cjs`（4 组）、`tests/diagnostics.cjs`（3 组）；P5 报告 | 清除记偏移+身份（跨页面重建不重现）/导出默认脱敏可预览/流量基准修复轮询写回/诊断包不含密钥与 URL；通知基准会话级同步为已知降级；真机待验 |
| REQ-21 | 深浅色、间距字体、模糊、数字对齐统一 | P3/P6 | ✅ 主机 / 待验 真机 | `UiSpec` + 资源 835 键（base/en 对称）、延迟/速率/流量等宽、底栏半透明+backdropBlur 保持 | `tests/p6-ui-static.cjs` 组 1/4、`tests/i18n-keys.cjs`；P6 报告 | 浅/深色视觉与字体档位实测待真机 |
| REQ-22 | 手机/平板、字体缩放、可访问标签与输入焦点 | P6 | ⚠️ | 44×44 热区、顶栏 a11y 名称/禁用原因已落（P6）；**断点双栏 2026-10-24 真机用户反馈撤回**（不要侧边节点详情栏），节点页保持单列,宽屏形态需用户再确认 | `tests/p6-ui-static.cjs` 组 2/3/5 + 真机装机取证 | 字体 100%/130%/最大档、读屏/键盘走查待真机;双栏撤回后本条回退为部分实现 |
| REQ-23 | 空态、引导、错误恢复、危险操作保护 | P3/P5 | ⚠️ | `HomeView.emptyStateFor`、订阅页空态/二次确认、`connectGate` | `tests/home-view.cjs` | 两处空态分支（`import_done`/`auth_denied`）当前不可达，待改节点页横幅 |
| REQ-24 | 迁移、兼容备份、回滚、性能及全链路真机证据 | P0/P6/P7 | ⚠️ 主机 ✅ / 真机 待验 | `model/MigrationV5.ets`、`ConfigRepository`、`SnapshotStore` | `tests/migration-v5.cjs`、`config-repository.cjs`、`docs/p0-baseline` | **无 HDC 设备**：迁移落盘、TUN、分应用真实流量、DNS 泄漏、保活、性能全待验 |

## 统计（主机证据口径，不含真机）

- ✅ 已实现且有主机证据：REQ-01、02、03、04、06、07、08、09、10、11、12、13、14、16、17、18、19、20、21（20 条;REQ-13 随分应用迁入分流页关闭;真机项一律另注「待验」）
- ⚠️ 部分实现：REQ-05、15、22、23、24（4 条;REQ-22 因真机用户反馈撤回双栏回退）
- ⏳ 未开始：（0 条）

## 维护规则

1. 只有"代码 + 主机测试/构建证据"同时存在才可标 ✅；真机项单独注明"待验"，不得并入 ✅。
2. 新增测试必须登记到上表"证据"列（防漂移测试同样算证据：`settings-schema` 读源码比对、`routing-rules` 与 `buildCustomRule` 字段对照）。
3. 需求状态变化时同步 `DEVPLAN.md` 状态行与本表，两者不得互相矛盾。
