# P3 导航与节点首页交付报告（2026-10-24）

依据：`docs/REDESIGN-PLAN-2026-10-23.md` §3（信息架构与导航）、§4（节点首页与连接状态）、§20.1（W11/W12）。状态：**开发项完成、构建与主机测试全绿；真机项与少量降级项如实列出**。未 commit。

## 1. 交付清单

| 工作包 | 交付 | 测试 |
|---|---|---|
| W11 导航契约 | `core/Navigation.ets`：7 页定义与顺序、旧下标映射（0..6→节点/订阅/分流/…）、返回语义（抽屉→父页→节点页→系统）、顶栏动作与禁用原因、按页浏览记忆、跨页上下文参数 | `tests/navigation.cjs` 11 组 |
| W11 壳层 | `pages/Index.ets`：抽屉 7 项按契约渲染（显示名 节点/订阅/分流）、`sectionTitle` 契约化、返回键走 `resolveBack`、`switchTab` 统一记忆存取、`NavMemory` 同步（分组/排序/收藏/仅看可用）、删除无引用 `pages/DashboardPage.ets` | 构建 |
| W11 顶栏 | `titleActionCluster` 按 `topBarActions()` 按页渲染；节点=搜索/检测/⋮（检测中变 LoadingProgress + 取消）、订阅=添加/更新全部、分流/设置/日志=搜索（+分流添加）、工具/关于无占位；未接线 token 过滤并记日志，不放死按钮；禁用原因 toast；「连接列表」移入节点页 ⋮ 并给无障碍文案 | 构建 |
| W12 首页模型 | `model/HomeView.ets`（追加）：会话/连通性双状态、状态卡、节点行（延迟分档/方式/新鲜度/三态）、筛选排序、空态、连接动作原因 | `tests/home-view.cjs` 23 组（含既有 7 组回归） |
| W12 首页接线 | `Index.ets`：`ProbeStore.latestAll()`→`ProbeResult` 逐字段投影、live+stored 合并（300ms 节流）、状态卡（5 档主按钮）、节点行模型渲染（延迟分档颜色/方式徽标/历史标注/三态描边优先级/失败看内核原文）、工具条（收藏/仅看可用/排序）、空态、连接前置校验 | 构建 + 29 套件 |
| W12 订阅页 | `pages/SubscriptionPage.ets` + `model/SubscriptionList.ets`（行模型/批量摘要/排序筛选/空态）、tab 1 接线（更新单个/全部、失败原文、删除二次确认、详情自跳） | `tests/subscription-list.cjs` 17 组 |
| 配置校验闸 | 所有连接入口经 `connectTo()` → `buildCoreConfig` + `CoreManager.checkConfig`（K1 纯解析）；`err:` 弹内核原文 + 「去修复」入口（订阅节点→订阅页 / 手建→编辑页），不进重连循环；`unsupported` 跳过并记降级日志 | 构建 |

## 2. 退出条件核对（§20.1 P3）

| 退出条件 | 证据 | 结论 |
|---|---|---|
| 七页导航可用、页名符合 §3.1 | 抽屉 7 项顺序/显示名断言（navigation.cjs）；`sectionTitle` 由契约给出 | ✅ 主机 |
| 顶栏动作按页、不可用给原因 | `topBarActions` 断言；Index 渲染 + toast；未接线 token 记日志不渲染 | ✅ 主机（部分页无搜索/⋮，见降级） |
| 返回语义 | `resolveBack` 矩阵断言 + Index `onBackPress` 接入 | ✅ 主机；真机返回键待验 |
| 浏览记忆 | NavMemory 断言 + Index 切页存取；恢复时清运行态绑定项 | ✅ 主机 |
| 状态卡两套状态独立 | 组合矩阵断言（connected+failed 合法、unknown 不冒充 connected、switching 不显示"正在使用"） | ✅ 主机 |
| 节点行信息与显示口径 | 行模型断言（0ms/失败/未测/检测中、149/150/399/400/401 边界、方式/新鲜度/三态） | ✅ 主机；视觉待真机 |
| 搜索/收藏/排序 | `filterNodes`/`sortNodes` 断言 + Index 工具条接线（页面不再自算排序） | ✅ 主机 |
| 空态与连接交互 | 空态断言 + Index 接线；连接前 `connectActionEnabled` + 配置校验闸 | ✅ 主机（部分空态分支不可达，见下） |
| 设备：返回栈/折叠/恢复 | 无 HDC 设备 | ⏳ 待验 |

## 3. 行为变化

1. **抽屉页名变更**：配置→节点、分组→订阅、路由→分流（资源 `nav_config/nav_groups/nav_route` 的显示值；内部 `activeTab` 与存储字段不变）。
2. **展示组管理并入节点页**；`pages/GroupPage.ets` 不再挂在 tab 1（文件保留供后续分组子页使用）。
3. **连接前配置校验**：配置无效时阻止连接并给出修复入口（此前会启动内核后失败）。
4. **连接列表入口**从顶栏图标移入节点页 ⋮（文字项，带无障碍名称）。
5. **节点行延迟/方式/新鲜度口径**改为 ProbeResult 驱动；旧 `status/ping` 仍用于兼容展示。
6. **自动连接也走配置校验**（失败会弹框并停在未连接态，不再静默重试）。

## 4. 验证证据

- `assembleHap` release **BUILD SUCCESSFUL**（末次 2.9s，33 tasks），HAP 14,668,481 B，包内 `libsingbox.so` sha256 `9b05c0bf…`（16 导出）。
- Node **29 套件全 PASS**（新增 navigation/subscription-list，扩充 home-view；含 latency-parity、functional-audit、parity-config 等既有套件）。
- Go hostprobe 全 PASS（未改动内核）。

## 5. 降级与待办（如实）

| 项 | 现状 | 计划 |
|---|---|---|
| 空态 `import_done`/`auth_denied` 分支 | 数据源已接，但空态只在无节点时渲染 ⇒ 两分支不可达 | P4 改为节点页顶部横幅（有节点也可显示） |
| `skippedTypes` 类型明细 | 解析器只回数量/名称，页面传空数组 | P5 订阅导入结果模型补类型明细 |
| 订阅页 ⋮ 三项（排序/自动更新开关/删除选中） | 需 `SubscriptionPage` 暴露 `sortMode/onSort/onSelect` | P4 加 props 后接线 |
| 分流/设置页搜索槽、日志导出槽 | 页面未实现搜索/导出在页内 | P4（分流）/ 保留页内实现（日志） |
| 状态卡折叠/展开 | 仅紧凑单卡，`collapsedSummary` 未用 | P4 与设置项「折叠连接卡」一起做 |
| 配置校验写 `filesDir/core/config.json` | 与扩展进程共用路径；仅在未连接时调用，但仍是共享文件 | P4 改独立 `config-check.json` 或内存校验入口 |
| 分组条节点数/最低延迟 | 仍读旧投影，不受"收藏/仅看可用"影响 | P4 统一 |
| 旧延迟/错误辅助函数 | 节点行改模型后成死代码，保留避免动 parity 断言 | P4 清理 |
| 新页面 i18n | 中文兜底常量（资源键已列清单） | P6 适配阶段统一资源化 |
| 真机：返回栈、折叠记忆、恢复确认、视觉 | 无设备 | P6 |
