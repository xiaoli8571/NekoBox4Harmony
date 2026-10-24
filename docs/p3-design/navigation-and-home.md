# P3 设计：导航与节点首页

日期：2026-10-24。依据 `docs/REDESIGN-PLAN-2026-10-23.md` §3（信息架构与导航）、§4（节点首页与连接状态）。状态：契约与视图模型已落地并有测试；Index 接线进行中。

## 1. 七页与旧结构映射（内部路由名不变，只改显示名，§3.2）

| 新页面 | 抽屉下标 | 旧结构 | 迁移方式 |
|---|---|---|---|
| 节点 | 0 | 旧「配置」（节点列表+分组条+连接） | 沿用 tab 0，展示分组并入本页（§3.1） |
| 订阅 | 1 | 旧「分组」（展示组管理） | 展示组并入节点页；本 tab 改为订阅来源列表（新 `pages/SubscriptionPage.ets`） |
| 分流 | 2 | 旧「路由」 | 沿用 tab 2，四子页签在 P4 补齐 |
| 设置 | 3 | 旧「设置」 | 不变 |
| 日志 | 4 | 旧「日志」 | 不变 |
| 工具 | 5 | 旧「工具」 | 不变 |
| 关于 | 6 | 旧「关于」 | 不变 |

`core/Navigation.ets::pageByLegacyTab(tab)` 固化该映射，避免改动大量既有 `activeTab` 逻辑；显示名为 `nav_config→节点`、`nav_route→分流`（`nav_groups` 在订阅页接线时改为「订阅」）。

## 2. 顶栏动作（§3.3）

- 动作 token：`search / probe / probeProgress / probeCancel / add / updateAll / export / more`。
- 规则：检测进行中「检测」位置变「进度 + 取消」；不可用动作必须带机器可读原因（`no_profiles / no_subscriptions / probe_unsupported / updating`），UI 显示原因而非静默；工具/关于页无常驻业务动作（不放占位按钮）。
- 实现：`topBarActions(pageId, TopBarContext)` 纯函数，Index 只负责渲染与分派。

## 3. 返回与恢复（§3.4）

`resolveBack(BackContext)`：抽屉打开 → 收抽屉；二级页 → 父页；非节点页 → 节点页；节点页 → 系统返回（退出桌面）。
`NavMemory`：按页隔离搜索文本、滚动位置、选中展示组、订阅选择、分流子页签、排序/收藏/仅看可用；进程恢复调用 `resetRuntimeDependent()`（清运行态绑定项，保留浏览位置），运行态必须重新向扩展确认。

## 4. 首页两套状态（§4.2，`model/HomeView.ets`）

| 模型 | 输入 | 输出 token |
|---|---|---|
| `vpnSessionView` | vpnStatus/running/runningProfileId/name | `disconnected/awaiting_auth/connecting/connected/switching/disconnecting/connect_failed/unknown` |
| `connectivityView` | ProbeResult + now + staleMs | `untested/probing/reachable/failed/stale/restricted` |
| `statusCardView` | 两者 | 主按钮 `connect/disconnect/cancel/retry/unknown` + 固定副动作 `checkConnectivity/connectionDetails` |

关键不变量：两者独立，`connected + failed` 合法；`unknown` 永不冒充 `connected`；`switching` 时节点行不得显示「正在使用」（需要 `runningConfirmed`）。

## 5. 节点行（§4.1/§6.6）

`nodeRowView(profile, result, NodeRowContext)` → 主标题/副标题、`latencyToken`（`86 ms`/`失败`/`—`/`检测中`，0ms 合法）、`latencyBucket`（`<150 fast / 150-399 medium / ≥400 slow`，与既有颜色阈值一致）、`methodToken`（HTTP 2xx / HTTP 有响应 / TCPing / 降级 / 未知）、`freshnessToken` + `ageText`、三态（已选/正在使用/正在确认）、`expandableError`。

## 6. 空态与动作可用性（§4.3/§4.5）

`emptyStateFor(EmptyContext)` 优先级：导入完成 → 首次授权被拒 → 离线 → 无节点；`showConnectButton` 在四类空态均为 false（不显示必然失败的连接按钮）。`connectActionEnabled(profileCount, configValid, applying)`：`no_profile / config_invalid / applying` 三种原因，`config_invalid` 停留当前页给修复入口，不进入重连循环。

## 7. 测试

| 套件 | 组数 | 覆盖 |
|---|---|---|
| `tests/navigation.cjs` | 11 | 页面顺序与显示名、旧下标映射、返回矩阵、顶栏动作与禁用原因、检测中进度/取消、按页记忆、恢复清理、跨页上下文 |
| `tests/home-view.cjs` | 23 | 既有折叠/订阅 7 组回归 + 会话/连通性矩阵、主按钮、行延迟与分档边界（149/150/399/400/401）、方法/新鲜度/时间、三态、筛选（中文/大小写/收藏/仅看可用）、排序、空态、动作原因 |

## 8. 待接线

1. Index 节点页：状态卡 + 行模型 + 工具条（先 `filterNodes` 再 `sortNodes`）+ 空态 + `connectActionEnabled`。
2. Index 订阅页：`pages/SubscriptionPage.ets` + `model/SubscriptionList.ets` 接线（导入/更新/详情/删除确认）。
3. 设备验收（P6）：返回栈真机行为、折叠记忆、恢复后运行态确认。
