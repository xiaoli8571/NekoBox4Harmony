# P6 适配与回归 — 阶段报告（W21 完成）

日期：2026-10-24。依据：`docs/REDESIGN-PLAN-2026-10-23.md` §13（视觉/布局/无障碍）、§24.2-6（资源一致性）。状态：**W21 已交付，主机全绿**。真机项全部「待验」（本机 `hdc list targets` 为空）。未 commit。

## 1. 交付清单

| 工作包 | 交付 | 测试 |
|---|---|---|
| W21 i18n 收口（P4 硬缺口） | 设置页 `SETTING_LABELS` **16→54 条全量映射**（= SettingsSchema registry 全部 SettingDef）+ `SECTION_LABELS` 9 分区；`sectionLabelOf/applyClassLabel/displayValue(开/关)`、待应用条（应用/稍后/放弃/查看/清除/搜索占位）、放弃草稿与恢复默认对话框全部资源化；`SettingsSchema.summaryText→pending_changes token`、`impactLines→impactParts(kind+count)` 结构化 | `tests/i18n-keys.cjs`（**收紧为 54/54+9/9 强制对齐**，缺映射必红）、`tests/settings-schema.cjs`（19/20 组改指 token，意图保留） |
| W21 订阅族 i18n | `model/SubscriptionList.ets` **token 化**：行文本（lastUpdated/autoUpdate/traffic/expiry）与状态、空态、批量摘要、逐订阅结果、导入识别全部改产 token+param（模型不再产用户语言）；`SubscriptionPage` 全文案 $r 映射 + 反馈条改**结构化 props**（`batchOutcomes/batchSummaryModel/batchVisible`，Index 传模型、页面渲染文案）；删除/清空确认对话框带参资源 | `tests/subscription-list.cjs`（17 组断言改指 token，边界语义原样） |
| W21 连接页 i18n | `ConnectionView.buildRouteEvidence` **空值不再注入「未提供」**（保留空串，页面用 `connection_not_provided` 兜底，不伪造语义不变）；`ConnectionsPage` 筛选 chips/搜索占位/开始时间/证据卡（标题+8 个行标签+关闭/断开）全部资源化（AlertDialog message 经 `getStringSync` 现取标签） | `tests/connection-view.cjs`（空值断言改指空串+摘要行跳空） |
| W21 日志/订阅详情 i18n | `LogPage` 导出对话框（标题/说明/导出脱敏/导出原文）资源化；`LogView.redactPreview` 改结构化（`text/totalLines/truncated`，尾注 `log_redact_preview_tail %1$d` 由页面拼）；`SubDetailPage` 墓碑区（标题/保留说明/转为手动/成功 toast）资源化 | `tests/log-view.cjs`（preview 结构断言） |
| ~~W21 响应式双栏（§13.2）~~ **已撤回（2026-10-24 真机用户反馈）** | 曾交付 `model/ResponsiveLayout.ets` + Index ≥840vp 列表+详情双栏（改名草稿存 `PaneState` 断点不丢）；**真机装上后用户明确不要侧边节点详情栏** → 双栏、单列详情视图、模型与 `tests/responsive-layout.cjs` 全部移除，节点信息回归列表行 + 编辑二级页；`p6-ui-static` 第 5 组改为"无侧栏"回归守卫（防回潮） | `tests/p6-ui-static.cjs` 组 5（反向断言）+ 真机 layout 取证 |
| W21 热区/无障碍/等宽（§13.1/§13.3） | `GlowIconButton` 暴露 `a11yText/a11yReason`（string 重载经 `getStringSync` 现取）；顶栏动作读屏名称（`nav_action_*`）+ **禁用原因读出**（`nav_reason_*`，来自 Navigation 契约的 disabledReason）；检测进度槽资源化；节点页 ⋮「连接列表」资源键（§3.3 遗留 TODO 清零）；订阅行 28 高按钮 `responseRegion` 扩 44×44（视觉不变）；墓碑「转为手动」26 高同款；延迟/速率/流量等宽（节点行延迟、连接页行速率与汇总、订阅行流量 `fontFamily('monospace')`） | `tests/p6-ui-static.cjs`（6 组静态防漂移） |
| 真机反馈轮（2026-10-24） | ① **撤节点页侧边详情栏**（见上）；② **状态卡去掉「连接/重试」主按钮**（启动/断开统一走大电源键；检查连接/详情保留并等分），死代码 `primaryActionText/primaryActionColor/onStatusPrimaryAction/cancelSessionAction` 一并删除 | `tests/p6-ui-static.cjs` 组 5；真机重装后 uitest layout 取证（无侧栏痕迹、无「连接」按钮） |
| W21 undefined 守卫 | 连接视图 `str()` 归一化（"undefined"/"null"→空串）保持并纳入静态守卫；订阅行文本全部 token+param，无模板串拼对象字段 | connection-view + p6-ui-static |

资源键：base/en_US 各 **700 → 830**（+135 后随双栏撤回移除 5 个 `nodes_detail_*`；全部对称；`i18n-keys` 断言键集合一致、无重复、无空值/占位残留，且含 122 键占位符中英一致检查）。

## 2. 关键设计决定

1. **模型 token 化而不是页面正则替换**：SubscriptionList/SettingsSchema 的文本函数全部改为产出 `token+param`，页面映射 `$r`（与 P3 HomeView `titleToken` 同惯例）。Node VM 测试断言改指 token，**边界语义逐条保留**（59s/60s、恰好 7 天、时钟回拨、旧字段兜底等断言原样对应）。
2. **AlertDialog/Toast 的带参文案**：message 只收 string，`getStringSync` 不展开 `%n$s/%n$d`（G6 已知限制）——页面统一 `resText/resFormat`（手动替换顺序占位符），与 VpnExtAbility 通知同手法。
3. **反馈条结构化**：Index 不再拼中文长串（旧 `batchOutcomeText`），传 `UpdateBatchSummary + PerSubOutcome[]`，页面逐行映射；失败原文经资源 `%2$s` 原样透出（不吞错误语义不变）。
4. ~~双栏草稿保真~~（随双栏撤回作废；机制曾为：草稿存 `PaneState` 由纯函数迁移，主机可测——真机用户反馈不接受侧栏形态，方案 §13.2 的该条按用户裁决优先于方案撤回）。
5. **accessibilityText 只收 string/Resource 单一类型**（SDK 双重载不接受 `ResourceStr` 联合）：组件内经 `getStringSync` 归一为 string。

## 3. 验证证据（2026-10-24）

- 末次构建（2026-10-24 真机反馈撤回轮后）：release `assembleHap` **BUILD SUCCESSFUL**，HAP **15,004,034 B**，包内 `libs/arm64-v8a/libsingbox.so` sha256 `9b05c0bfccad124f`（**16 导出，冻结内核未动**）。
- **Node 41 套件全 PASS**（`responsive-layout` 随双栏撤回移除；`p6-ui-static` 6 组中第 5 组改为无侧栏回归守卫）。
- **真机（无线 192.168.3.146）已装 2.3.0 并复核**：撤回后 layout 取证确认无侧栏痕迹（编辑/保存改名/返回 均不在屏）、「连接」主按钮不在屏、单列节点列表正常（含延迟/HTTP 方式行）；截图 `dist/device-2.3.0-after-revert.jpeg`。
- `tests/hostprobe` Go 套件 PASS（`ok parityprobe`）。
- 构建修复记录：`accessibilityText/Description` 联合类型实参×4（GlowIconButton/订阅页/连接页改 string 重载）、`Row` 无 `flexWrap`。

## 4. 降级与待办（如实）

| 项 | 现状 | 说明 |
|---|---|---|
| 真机全部待验 | 双栏切换/旋转分屏实时性、字体 100%/130%/最大档、浅深色视觉、44vp 实触、读屏（TalkBack 类）走查、键盘完成排序/选择/取消/应用 | 无 HDC 设备；§22 矩阵在 P7 清单标「待验」 |
| Index 壳层 P3 中文兜底 | `sessionTitleText`（已连接/连接中…）、`connectivityText`、节点页空态等约 200 处 | P3 遗留的**节点首页状态卡**中文兜底；本轮任务范围为"订阅/连接/日志页 P5 文案+设置页 54 条"，未扩到 Index 全量（改动面与回归风险原因，如实记录，遗留下一轮） |
| HomeView 延迟 token 中文 | `latencyToken='检测中'/'失败'` | 同上，P3 范围；数字形态已等宽 |
| Diagnostics '未知' | 诊断 JSON 值保留中文 | 诊断包是开发侧工件（固定键序 JSON），非 UI chrome，`diagnosticsLooksSafe` 自检守着 |
| ~~双栏覆盖面~~ | **双栏整体撤回（用户真机反馈）** | 节点页保持单列;如未来再引入宽屏形态需先过用户确认 |
| 设置搜索 keywords 中文 | `SettingsSchema.keywords` 为中文检索词 | §12.1 设计（中文关键词匹配），非显示文案，`i18n-keys` 守 labelToken→资源键 |

## 5. REQ 映射

- REQ-21（视觉/深浅色/等宽数字统一）：✅ 主机（等宽/资源/规格落地 + p6-ui-static + 构建）；真机视觉待验。
- REQ-22（手机/平板、字体缩放、可访问标签与输入焦点）：⚠️（a11y 名称/禁用原因/热区 ✅ 主机并真机装机；**断点双栏按用户真机反馈撤回**，REQ 按实际形态回退；字体档位/读屏/键盘待真机）。
- REQ-03（图标无障碍名称）：✅ 主机（顶栏动作+禁用原因；p6-ui-static 组 2）。
- REQ-24（性能/全链路真机证据）：仍 ⚠️（无设备，P7 清单逐项标待验）。
