# 鸿蒙版七个抽屉页面：实现事实与代码级可用性判定

> 取证对象：`C:\Worker\NekoBox4Harmony`（只读）。
> 取证方法：逐条打开 `onClick` 指向的方法体，确认「是否落库（Preferences）/ 是否调用系统 API / 是否只 toast / 是否被配置生成器消费」。
> 判定三档：**✅ 完整**（有实现 + 有持久化或系统调用 + 有失败处理）／**⚠️ 有条件**（依赖开关、权限、连接态、内核导出或仅部分生效）／**❌ 死路/仅提示**（方法体里没有动作、或被下游覆盖、或 UI 无入口）。
> 行号均为当前工作区实际行号。仅列事实与证据，不做主观评价。

## 取证基线（行号口径，先读这段）

**审计读取窗口**：2026-10-23 12:41–13:07（读取时的文件指纹）：

| 文件 | 读取时行数 | 完成文档时（13:12） |
|---|---|---|
| `pages/Index.ets` | 2947 | **2950**（13:10:35 被并发修改；md5 `aaee547bccd8…`） |
| `pages/SettingsPage.ets` | 1363 | **1356**（13:11:54 被并发修改；md5 `68cf16d343ea…`） |
| `pages/GroupPage.ets` | 654 | 654（未变，10-23 10:31 之后无改动） |
| `pages/RouteRulesPage.ets` / `LogPage.ets` / `ToolsPage.ets` / `AboutPage.ets` | 718 / 222 / 445 / 189 | 全部未变（10-17 之后无改动） |

**因此**：本文表格里的行号是**审计读取时**的行号。5 个二级页面（分组/路由/日志/工具/关于）的行号与当前工作区完全一致；`Index.ets` 与 `SettingsPage.ets` 在本轮审计期间被其它进程改动过，行号存在漂移（非均匀，−11…+4），复核请以**方法名 / `$r(...)` 键**为准（每行都给了）。

**锚点换算表（审计行号 → 当前工作区行号，`grep -n` 实测）**

| Index.ets 锚点 | 审计 | 当前 | SettingsPage.ets 锚点 | 审计 | 当前 |
|---|---|---|---|---|---|
| `updateCurrentSubscription()` | 839 | 839 | `sectionHeader()` | 406 | 407 |
| `clearTrafficStatistics()` | 879 | 879 | `build()` | 443 | 441 |
| `moveProfile()` | 993 | 993 | `latency_test_mode` 行 | 535 | 534 |
| `runUrlTest()` | 1128 | 1131 | `settings_speed_interval` 行 | 619 | 608 |
| `openProfileShare()` | 1201 | 1204 | `settings_geo_download` 按钮 | 681 | 674 |
| `quickImportClipboard()` | 1528 | 1531 | `settings_geo_update_one` | 722 | 715 |
| `doImport()` | 1546 | 1549 | `haptic_feedback` 行 | 1018 | 1010 |
| `drawerItems()` | 1660 | 1663 | `liquid_glass` 行 | 1026 | 1018 |
| `drawerPanel()` | 1695 | 1699 | `network_change_reset_connections` 行 | 1038 | 1027 |
| `openDrawer()` | 1796 | 1799 | `wake_reset_connections` 行 | 1050 | 1039 |
| `drawerOverlay()` | 1814 | 1818 | `profile_traffic_statistics` 行 | 1062 | 1051 |
| `modeSwitchRow()` | 1845 | 1848 | `clash_api_enabled` 行 | 1082 | 1074 |
| `groupContextMenu()` | 1874 | 1878 | `per_app_add_import` 按钮 | 1163 | 1156 |
| `nodeCard()` | 1892 | 1896 | `PerAppAddDialog` | 1305 | 1299 |
| `searchInputRow()` | 1981 | 1985 | | | |
| `configFragment()` | 2004 | 2008 | | | |
| `groupTabBar()` 的 `bindContextMenu` | 2123 | 2126 | | | |
| `statsBar()` 的 `onClick` | 2186 | 2189 | | | |
| `fabButton()` 的 `onClick` | 2228 | 2231 | | | |
| `titleActionCluster()` | 2350 | 2353 | | | |
| `overflowActions()` | 2415 | 2418 | | | |
| `openOverflowMenu()` | 2446 | 2449 | | | |
| `activeContent()` | 2482 | 2486 | | | |
| `titleBottomBuilder()` | 2531 | 2535 | | | |
| `shellTitleBar()` | 2564 | 2568 | | | |
| `build()` | 2633 | 2636 | | | |

> 这也是一条**协作事实**：审计期间有另一个进程在改 `Index.ets` / `SettingsPage.ets`（13:10、13:11 各一次）。若后续仍有改动，请以方法名重新定位，不要依赖本文件的绝对行号。

**漂移规律（实测，便于插值）**
- `Index.ets`：≤993 行不变；1128–1663 段整体 **+3**；1699–2415 段多为 **+3/+4**（就近取锚点）；2486 之后 **+3~+4**。
- `SettingsPage.ets`：≤500 基本不变；507–930 段 **−1…−7**；960 之后 **−7…−11**（两处删除所致，如 7 个章节头 507/658/847/937/971/1077/1122 → 当前 507/651/840/930/964/1070/1115）。

**并发改动后的关键行为复核（13:22 重读方法体，结论未变）**
- `SettingsPage.save(quiet)` `:229-240`：仍为"落库 → 回调 → toast `saved_reconnect_vpn`"，无自动重连；`applyAppearance` `:200-223` 仍"落库 + setColorMode + 回调"（立即生效）；`switchMode` `:242-263` 仍无 UI 引用（D10 成立）；`persistPerApp` `:272-287` 仍"save(true) + 运行中 switchTo"。
- `Index.runUrlTest` `:1131-1170`：`fetchCurrentProxyDelay` 成功后**只改内存**（`:1144` 注释明示"不落库"），异常时 toast 四分支——D11 成立。
- `Index.deleteProfile` `:1172-1185`：`saveProfiles(this.profiles)` 仍**未 await**。
- `LogPanel`「清空」`:165-169`：仍置 `fileOffset=0`；`tailCoreLog` `:99-135` 在文件被截断（重连）时也归零重读——D3 成立。
- `GroupPage.updateAll` `:149-178`：toast 键为 `sub_update_result`（`:169`），失败仅计数写日志（`:170-172`）。
- `ToolsPage`：`prepareForRestore` `:83-102`（断开 VPN + 15s 轮询）、`exportBackupFile` `:142-166`（忙碌互斥 + `backup_export_cancelled`）、剪贴板四键 `:352-401`（异常 toast 分支齐全）、`runStun` `:194-209`——均与表内描述一致。
- `SettingsPage` 章节头为 7 个（`:507/651/840/930/964/1070/1115`），与表 #2-#8 对应；「保存」按钮 `enabled(this.dirty)`（`:447`）。


## 0. 入口与分区映射（事实基线）

| 事实 | 证据 |
|---|---|
| 抽屉 7 项顺序 = `config/groups/route/settings/logs/tools/about` | `entry/src/main/ets/pages/Index.ets:56` |
| 抽屉文案键：`nav_config`/`nav_groups`/`nav_route`/`settings_title`/`logs`/`nav_tools`/`nav_about` | `Index.ets:57-65` |
| `activeTab` 0..6 = 配置/分组/路由/设置/日志/工具/关于；`TAB_TO_DRAWER_INDEX = [0,1,2,3,4,5,6]`（恒等映射） | `Index.ets:76`、`Index.ets:96` |
| 抽屉点击 → `onDrawerSelect(id)` 只做 `activeTab = 0..6`，无路由、无落库 | `Index.ets:1676-1693` |
| 分区内容切换：0 内联 `configFragment()`；1 `GroupPage`；2 `RouteRulesPanel`；3 `SettingsPage`；4 `LogPanel`；5 `ToolsPage`；6 `AboutPage` | `Index.ets:2482-2528` |
| 「使用文档」入口已从抽屉移除，`DocPage` 路由保留但无任何 `pushUrl` → 不可达 | `Index.ets:54-55`（全仓仅 `pages/DocPage.ets:14` 自身） |
| `DashboardPage`（内嵌 yacd Web 面板）无任何 import / 路由调用 → 不可达 | 全仓仅 `pages/DashboardPage.ets:13`；`utils/WebUiAssets.ets:23` 只被它引用 |
| 系统返回键：抽屉开→收；非首页→回配置页；配置页→`moveAbilityToBackground()` | `Index.ets:194-205` |

## 1. 共享壳层（7 页共有；不在分页计数里重复统计）

页面骨架（`Index.build()`，`Index.ets:2633-2689`）：`Stack` → `HdsNavigation`（HDS 官方标题栏：渐变模糊 + 沉浸光感，`shellTitleBar()` `Index.ets:2564-2610`）→ 内容层 `activeContent()`；底部 `statsBar()`（条件 `isRunning && (activeTab==0 || settings.showBottomBar)`，`Index.ets:2653`）；`fabLayer()`（条件 `activeTab==0 || settings.showBottomBar`，`Index.ets:2677`）；最后兄弟 `drawerOverlay()`（盖住标题栏与状态栏，`Index.ets:2682`）。

### 1.1 顶栏动作簇（`titleActionCluster()`，`Index.ets:2350-2412`；**7 个分区都渲染**）

| # | 项 | 触发方法 | 实际行为 | 判 | 证据 |
|---|---|---|---|---|---|
| 1 | ☰ 抽屉 | `openDrawer()` | `drawerEdge=handSide; drawerOpen=true`，遮罩 + 面板 translate 滑入，无落库 | ✅ | `Index.ets:1796-1799`、`Index.ets:2336-2345` |
| 2 | 搜索图标（首页） | 内联 onTap | `searchVisible=true` + 120ms 后 `requestFocus('nodeSearchInput')`；再点一次走 `closeNodeSearch()` | ✅ | `Index.ets:2352-2372`、`Index.ets:226-230` |
| 3 | 搜索图标（非首页） | 同上 | `searchVisible=true`，但搜索行只在 `activeTab===0` 时渲染（`titleBottomBuilder` 整块被 `if (this.activeTab === 0)` 包住）⇒ 界面上没有任何可见变化；再点一次复位 | ❌ | `Index.ets:2356-2371` + `Index.ets:2540-2552` |
| 4 | ＋ 添加 | 内联 onTap → `addEntryDialog.open()` | 打开 5 入口弹窗（导入订阅/扫码/剪贴板/文件/新建节点），全部有实现（见 2.3） | ✅ | `Index.ets:2373-2380`、`Index.ets:2807-2881`、`Index.ets:1325-1345` |
| 5 | 连接图标（`sys.symbol.link`） | `router.pushUrl('pages/ConnectionsPage')` | 真实路由；该页在无 VPN 时显示"不可用"占位并停止轮询 | ✅ | `Index.ets:2381-2388`、`ConnectionsPage.ets:113-123`、`ConnectionsPage.ets:224` |
| 6 | ⋮ 溢出菜单 | `openOverflowMenu()` | `HdsMenu.open(...)` 弹系统菜单窗口，回调按 `value` 分发 11 个动作 | ✅ | `Index.ets:2389-2409`、`Index.ets:2446-2479` |
| 7 | 抽屉：配置 | `onDrawerSelect('config')` | `activeTab=0` | ✅ | `Index.ets:1678-1679` |
| 8 | 抽屉：分组 | `onDrawerSelect('groups')` | `activeTab=1` | ✅ | `Index.ets:1680-1681` |
| 9 | 抽屉：路由 | `onDrawerSelect('route')` | `activeTab=2` | ✅ | `Index.ets:1682-1683` |
| 10 | 抽屉：设置 | `onDrawerSelect('settings')` | `activeTab=3` | ✅ | `Index.ets:1684-1685` |
| 11 | 抽屉：日志 | `onDrawerSelect('logs')` | `activeTab=4` | ✅ | `Index.ets:1686-1687` |
| 12 | 抽屉：工具 | `onDrawerSelect('tools')` | `activeTab=5` | ✅ | `Index.ets:1688-1689` |
| 13 | 抽屉：关于 | `onDrawerSelect('about')` | `activeTab=6` | ✅ | `Index.ets:1690-1691` |

**跨页事实**：○○⊕⋮ 四个动作属于"配置页语义"却常驻所有分区——＋ 始终打开"添加节点/订阅"弹窗，⋮ 始终打开"更新订阅/清理/测速/排序"菜单，其作用域是 `this.selectedGroupId`（配置页分组条选中项，可能来自上次停留的配置页）。搜索图标是非首页唯一的完全空转项（第 3 行）。

## 2. 配置页（`activeTab===0`，`configFragment()` `Index.ets:2004-2059`）

自上而下：HDS 标题栏（☰ + 标题 + 动作簇）→ `titleBottomBuilder`（搜索行 ↔ 模式行 + 分组条，恒 68vp，`Index.ets:2531-2553`）→ `List`（顶部占位项 `contentTopInset-8` + 节点卡，`Index.ets:2027-2055`）→ 底部 `statsBar` → 右侧/左侧 FAB → 抽屉。空列表时改为居中"无节点"块（`Index.ets:2011-2025`）。

### 2.1 可点项（42 项）

| # | 项（文案键） | 触发方法 | 实际行为 | 判 | 证据 |
|---|---|---|---|---|---|
| 1 | 搜索输入框 `search_nodes` | `scheduleSearchFilter(v)` | 250ms 防抖后写 `nodeSearch`；`visibleProfiles()` 按名称/服务器子串过滤 | ✅ | `Index.ets:1984-1991`、`Index.ets:210-216`、`Index.ets:936-945` |
| 2 | 搜索行「取消」`cancel` | `closeNodeSearch()` | 清防抖定时器 + `nodeSearch=''` + `searchVisible=false` | ✅ | `Index.ets:1992-1996`、`Index.ets:226-230` |
| 3 | 模式「规则」`mode_rule` | `switchOutboundMode('rule')` | `settings.mode` 改写 + `saveSettings()` 落库；运行中 → `VpnService.connect(id, true)` 强制重启 | ✅ | `Index.ets:1865`、`Index.ets:568-580` |
| 4 | 模式「全局」`mode_global` | 同上 | 同上 | ✅ | 同上 |
| 5 | 模式「直连」`mode_direct` | 同上 | 同上 | ✅ | 同上 |
| 6 | 分组 chip 点选 | 内联 onTouch(Up) | 只写 `selectedGroupId`（内存，**不落库**），刷新列表 | ✅ | `Index.ets:2113-2122` |
| 7 | 分组 chip 长按 | `bindContextMenu(groupContextMenu(groupId))` | 弹出 6 项分组菜单 | ✅ | `Index.ets:2123-2129`、`Index.ets:1874-1890` |
| 8 | 分组菜单「TCPing」`connection_test_tcp_ping` | `runTcpTest(groupId)` | `runTestForGroup(g,'tcp')` → `canTCPing` 过滤 → `testProfiles` 并发测；`finally` 里 `saveProfiles` 落库 | ✅ | `Index.ets:1877-1878`、`Index.ets:594-596`、`Index.ets:602-629`、`Index.ets:692-698` |
| 9 | 分组菜单「URL Test」`connection_test_url_test` | `runSpeedTest(groupId)` | 强制走 `urlTestProfiles`（内核 `CGoTest*` 临时实例）；内核起不来则回退 TCPing 并 toast `speed_test_degraded` | ⚠️ | `Index.ets:1879-1880`、`Index.ets:588-590`、`Index.ets:680-687` |
| 10 | 分组菜单「测速本组」`test_current_group` | `runGroupSpeedTest(groupId)` | 方式跟随 `settings.latencyTestMode`（url/tcp），与 ⋮ 两个显式入口语义不同 | ⚠️ | `Index.ets:1881-1882`、`Index.ets:598-600` |
| 11 | 分组菜单「清除测试结果」`clear_test_results` | `clearTestResults(groupId)` | `status!=0` 的节点归零 + `saveProfiles` + `bumpResults` | ✅ | `Index.ets:1883-1884`、`Index.ets:716-734` |
| 12 | 分组菜单「去重」`dedup_action` | `dedupGroup(groupId)` | 键 `server+serverPort+type` 找重复 → 确认框列前 20 名 → 删除 + `saveProfiles` | ✅ | `Index.ets:1885-1886`、`Index.ets:741-781` |
| 13 | 分组菜单「删除不可用」`delete_unavailable` | `deleteUnavailable(groupId)` | `status∉{0,1}` 的节点 → 确认框 → 删除 + `saveProfiles` + toast | ✅ | `Index.ets:1887-1888`、`Index.ets:785-806` |
| 14 | 节点卡点按 | `onNodeTap(p)` | 写 `selectedId` + `selected_profile_id` 落库；未运行时只选中；运行中不同节点 → `VpnService.switchTo()` 热切换（带 `switching` 防重入） | ✅ | `Index.ets:1968`、`Index.ets:545-566` |
| 15 | 节点卡延迟文字 | `showTestError(p)` | 仅 `status===3` 有值：`AlertDialog` 展示内核原文；其它状态直接 return | ⚠️ | `Index.ets:1910-1917`、`Index.ets:1113-1123` |
| 16 | 节点卡长按 | `bindContextMenu(profileContextMenu(p), LongPress)` | 弹 12 项节点菜单（毛玻璃背板） | ✅ | `Index.ets:1969-1976`、`Index.ets:1270-1305` |
| 17 | 菜单「固定/取消固定」`pin`/`unpin` | `togglePinned(p)` | 改 `pinned` + `saveProfiles`；排序时置顶 | ✅ | `Index.ets:1273-1274`、`Index.ets:1011-1015` |
| 18 | 菜单「上移」`move_up` | `moveProfile(p,-1)` | 仅 `profileSortMode==='manual'` 时渲染；重排 `sortOrder` + `saveProfiles` | ⚠️ | `Index.ets:1275-1277`、`Index.ets:993-1009` |
| 19 | 菜单「下移」`move_down` | `moveProfile(p,+1)` | 同上 | ⚠️ | 同上 |
| 20 | 菜单「URL Test」`url_test` | `runUrlTest(p)` | 要求 **运行中且 `vpnRunningProfileId===p.id`**，否则 toast；走 clash API `/proxies/.../delay`，**只改内存不落库**（注释明示对齐安卓 StatsBar）⇒ 下次 `refresh()` 回退 | ⚠️ | `Index.ets:1281-1282`、`Index.ets:1128-1167` |
| 21 | 菜单「复制分享链接」`copy_share_link` | `copyProfileLink(p)` | `exportProfileLink` → 剪贴板 + toast；协议不支持则 toast | ✅ | `Index.ets:1283-1284`、`Index.ets:1223-1231` |
| 22 | 菜单「分享节点」`share_profile` | `openProfileShare(p)` | 生成二维码（`generateBarcode.createBarcode`）+ 文本弹窗；二维码失败降级纯文本 | ✅ | `Index.ets:1285-1286`、`Index.ets:1201-1221` |
| 23 | 菜单「导出发送配置」`export_outbound_config` | `exportProfileConfig(p)` | `buildOutboundJson` → 剪贴板；异常 toast | ✅ | `Index.ets:1287-1288`、`Index.ets:1234-1242` |
| 24 | 菜单「导出到文件」`export_outbound_config_file` | `exportProfileConfigFile(p)` | `DocumentViewPicker.save` + `fs.writeSync`；取消/异常分别 toast | ✅ | `Index.ets:1289-1290`、`Index.ets:1245-1268` |
| 25 | 菜单「编辑节点」`profile_edit_title` | `router.pushUrl('pages/ProfileEdit')` | 真实路由，`AppStorage.editProfileId` 传参 | ✅ | `Index.ets:1291-1295` |
| 26 | 菜单「移动到分组」`move_to_group` | `openMoveToGroup(p)` | 弹窗列"未分组 + 全部分组"，选中后写 `p.groupId` + `saveProfiles` + toast | ✅ | `Index.ets:1296-1297`、`Index.ets:1020-1042` |
| 27 | 菜单「查看订阅」`view_subscription` | `router.pushUrl('pages/SubDetailPage',{url})` | 仅 `p.subUrl.length>0` 时渲染，真实路由 | ⚠️ | `Index.ets:1298-1301` |
| 28 | 菜单「删除」`delete` | `deleteProfile(p)` | 确认框 → 过滤 `profiles` + `saveProfiles(...)`（**未 await**，无失败提示）；未清理 `selectedId` | ✅ | `Index.ets:1302-1303`、`Index.ets:1169-1183` |
| 29 | 空态「导入订阅链接」`import_link_subscription` | `openImportDialog()` | 清空输入 + 读 `recent_subscription_group` 预填 + 打开弹窗 | ✅ | `Index.ets:2017-2021`、`Index.ets:1522-1526` |
| 30 | 底部 `statsBar` 点按 | 内联 onClick → `runUrlTest(selectedProfile())` | 要求"运行中 + 有选中节点"；随后 `runUrlTest` 还要求该节点是当前运行节点，否则 toast `url_test_current_profile_only` | ⚠️ | `Index.ets:2186-2191`、`Index.ets:1128-1137` |
| 31 | FAB 连接/断开 | `toggleVpn()` | 运行中→`VpnService.disconnect`；未运行→取 `selectedProfile()`，为空 toast `select_or_create_profile`，否则 `connectTo`（落 `selected_profile_id` + `VpnService.connect`） | ✅ | `Index.ets:2228`、`Index.ets:531-542`、`Index.ets:509-521` |
| 32 | ⋮「更新当前订阅」`update_current_subscription` | `updateCurrentSubscription()` | 取选中节点 `subUrl` 或 `activeConfigUrl`；空则 toast；`needDirectUpdateConfirm` 命中先确认；`updateSubscription` → `refresh()` → 差异/toast | ⚠️ | `Index.ets:2424`、`Index.ets:2453-2454`、`Index.ets:839-876` |
| 33 | ⋮「清除流量统计」`clear_traffic_statistics` | `clearTrafficStatistics()` | 仅把 `lastUp/lastDown/lastTrafficAt` 与 `AppStorage['vpnTotalUp/Down']` 置 0；**内核 `/connections` 计数无重置接口**，UI 1s 轮询（`Index.ets:424-425`）与扩展进程 `speedIntervalMs` 轮询（`VpnExtAbility.ets:668-670`）随即把真实累计值写回 ⇒ 显示 ≤1s 复原 | ❌ | `Index.ets:2455-2456`、`Index.ets:879-886`、`utils/TrafficStats.ets:14-40` |
| 34 | ⋮「去重」`dedup_action` | `dedupGroup('__all__')` | 作用域被硬编码为全量（与分组菜单传 `groupId` 不一致），注释标注"去重语义由 Lead 统一改" | ✅ | `Index.ets:2466-2468`（`Index.ets:467` 注释） |
| 35 | ⋮「TCPing」`connection_test_tcp_ping` | `runTcpTest(selectedGroupId)` | 同 #8 | ✅ | `Index.ets:2434`、`Index.ets:2457-2458` |
| 36 | ⋮「URL Test」`connection_test_url_test` | `runSpeedTest(selectedGroupId)` | 同 #9 | ⚠️ | `Index.ets:2435`、`Index.ets:2459-2460` |
| 37 | ⋮「取消」`cancel`（测速中替换两测试项） | `cancelSpeedTest()` | 只置 `testCancelled=true`；worker 停止取新节点，**已测结果仍落库**（`finally` 中 `saveProfiles`） | ✅ | `Index.ets:2427-2430`、`Index.ets:702-707`、`Index.ets:694-695` |
| 38 | ⋮「清除测试结果」`clear_test_results` | `clearTestResults(selectedGroupId)` | 同 #11，作用域=当前分组 | ✅ | `Index.ets:2437`、`Index.ets:2463-2465` |
| 39 | ⋮「删除不可用」`delete_unavailable` | `deleteUnavailable(selectedGroupId)` | 同 #13 | ✅ | `Index.ets:2438`、`Index.ets:2469-2470` |
| 40 | ⋮「按手动排序」`sort_manual` | `setSortMode('manual')` | `settings.profileSortMode` + `saveSettings` + 重建列表（带选中勾） | ✅ | `Index.ets:2439`、`Index.ets:808-812` |
| 41 | ⋮「按延迟排序」`sort_latency` | `setSortMode('latency')` | 同上；排序值 = `status===1?ping:MAX` | ✅ | `Index.ets:2440`、`Index.ets:890-916` |
| 42 | ⋮「按名称排序」`sort_name` | `setSortMode('name')` | 同上 | ✅ | `Index.ets:2441` |

### 2.2 失败与边界（配置页）

- 测速并发进行中再点测速：toast `index_test_in_progress`（`Index.ets:602-607`）。
- TCPing 全组无可用协议 / URL Test 组内无节点：分别 toast `connection_test_tcp_ping_unavailable` / `speed_test_group_empty`（`Index.ets:610-617`）。
- 结果刷新用 `resultsRev` 版本号驱动，避免就地改对象导致 ArkUI 复用旧条目（`Index.ets:87-90`、`Index.ets:1044-1052`）。
- 测速结果每 300ms 合并刷 `@State`，防整页重渲染（`Index.ets:631-671`）。
- 导入管道（`doImport`）对空串、订阅安全确认、clash yaml / sing-box json / 分享链接三种解析、无可用节点、异常均有分支与 toast（`Index.ets:1546-1651`）。

### 2.3 「＋」弹窗内的 5 个入口（计入第 1 节 #4 的下钻事实，不重复计数）

| 入口（键） | 方法 | 实际行为 | 判 | 证据 |
|---|---|---|---|---|
| `import_link_subscription` | `openImportDialog()` | 见 #29 | ✅ | `Index.ets:1331-1333` |
| `add_profile_methods_scan_qr_code` | `scanImport()` | `scanBarcode.startScanForResult` 系统扫码 → `doImport`；取消码 1000500002/12900010 静默 | ✅ | `Index.ets:1352-1377` |
| `import_from_clipboard` | `quickImportClipboard()` | 读剪贴板 → 打开导入弹窗并填入；空剪贴板 toast | ✅ | `Index.ets:1528-1536` |
| `action_import_file` | `importFromFile()` | `DocumentViewPicker.select` → 拷到 cache → `.zip` 走 WireGuard 解包分支，其余 `readTextSync` → `doImport` | ✅ | `Index.ets:1384-1421`、`Index.ets:1424-1496` |
| `profile_new_title` | `router.pushUrl('pages/ProfileEdit')` | `editProfileId=''` 新建 | ✅ | `Index.ets:1327-1330` |

## 3. 分组页（`activeTab===1`，`GroupPage.ets` 全文 654 行）

结构：页头只有右侧「更新全部订阅」（`GroupPage.ets:451-461`）→ 新建分组行（输入框 + 按钮，`GroupPage.ets:463-486`）→ `List`：订阅卡（名称/节点数/URL/最后更新/流量/到期，动作行 6 项，`GroupPage.ets:490-524`）→ 手动分组卡（名称/节点数 + 3 动作 + 可展开设置面板，`GroupPage.ets:527-621`）→ 空态文案（`GroupPage.ets:623-630`）。**页面无标题栏、无测速入口、无"移动分组"入口**。

| # | 项（文案键） | 触发方法 | 实际行为 | 判 | 证据 |
|---|---|---|---|---|---|
| 1 | 更新全部订阅 `update_all_subs` | `updateAll()` | 串行遍历全部订阅 `updateSubscription`+`markSubSuccess/Failure`；toast `sub_update_result(added,removed)`；失败数只写日志；结束后 `refresh()`+`onDataChanged()` | ✅ | `GroupPage.ets:454-457`、`GroupPage.ets:149-178` |
| 2 | 新建分组输入框 `new_group_hint` | 内联 onChange | 只写 `newGroupName`（不落库） | ✅ | `GroupPage.ets:464-468` |
| 3 | 添加分组 `add_group` | `createGroup()` | 空名校验 → 新建 `ProfileGroup`（`grp_<ts>_<rand>`）→ `saveGroups` → 清输入 → `refresh()` | ✅ | `GroupPage.ets:469-483`、`GroupPage.ets:291-309` |
| 4 | 订阅卡「更新」`update_action`/`updating` | `updateOne(sub)` | 互斥保护；`needDirectUpdateConfirm` 先确认；`updateSubscription` → `markSubSuccess` → 差异反馈 → `refresh`；异常 `markSubFailure`+toast | ✅ | `GroupPage.ets:420-423`、`GroupPage.ets:110-147` |
| 5 | 订阅卡「分享订阅链接」`share_sub_link` | `shareSubLink(sub)` | 订阅 URL 写剪贴板 + toast | ✅ | `GroupPage.ets:424-427`、`GroupPage.ets:180-183` |
| 6 | 订阅卡「导出全部节点」`export_all_nodes` | `exportAllNodes(sub)` | 该订阅全部节点 `exportProfileLink` 拼接写剪贴板；为空 toast | ✅ | `GroupPage.ets:428-431`、`GroupPage.ets:185-193` |
| 7 | 订阅卡「导出全部节点到文件」`export_all_nodes_file` | `exportAllNodesToFile(sub)` | `DocumentViewPicker.save` + 写 txt；取消/异常 toast | ✅ | `GroupPage.ets:432-435`、`GroupPage.ets:196-223` |
| 8 | 订阅卡「清空分组」`clear_group` | `clearSubProfiles(sub)` | 确认框 → 删该订阅节点 + `saveProfiles` + `refresh`（**不动订阅记录本身**） | ✅ | `GroupPage.ets:436-439`、`GroupPage.ets:254-270` |
| 9 | 订阅卡「删除」`delete` | `deleteSub(sub)` | 确认框 → `removeSub(url)` + 删节点 + `saveProfiles` + `refresh` | ✅ | `GroupPage.ets:440-443`、`GroupPage.ets:272-289` |
| 10 | 手动分组「分组设置」`group_settings` | `openGroupSettings(group)` | 展开/收起设置面板，载入组当前 `isSelector/frontProxy/landingProxy` | ✅ | `GroupPage.ets:539-542`、`GroupPage.ets:348-357` |
| 11 | 手动分组「清空分组」`clear_group` | `clearGroupProfiles(id)` | 确认框 → 删组内节点 + `saveProfiles` | ✅ | `GroupPage.ets:543-546`、`GroupPage.ets:236-252` |
| 12 | 手动分组「删除」`delete` | `deleteGroup(group)` | 确认框 → 组内节点 `groupId=''`（不删节点）→ `saveGroups` | ✅ | `GroupPage.ets:547-550`、`GroupPage.ets:311-333` |
| 13 | 设置「使用选择器」`use_selector` | Toggle → `settingsSelector` → `saveGroupSettings()` | 写 `group.isSelector` + `saveGroups`；被配置生成器消费（生成 `selector` 出站）；仅当**运行节点属于该组**才立即 `switchTo` 重载 | ⚠️ | `GroupPage.ets:561-563`、`GroupPage.ets:360-386`、`ConfigBuilder.ets:850-880` |
| 14 | 设置「前置代理」`front_proxy` | Select → `settingsFront` → 保存 | 写 `group.frontProxy`（节点 id）；`buildProfileGraph` 把它 `unshift` 进链 | ⚠️ | `GroupPage.ets:566-571`、`ConfigBuilder.ets:763-775` |
| 15 | 设置「落地代理」`landing_proxy` | Select → `settingsLanding` → 保存 | 写 `group.landingProxy`；`buildProfileGraph` 把它 `push` 进链 | ⚠️ | `GroupPage.ets:573-579`、`ConfigBuilder.ets:772-774` |
| 16 | 设置「取消」`cancel` | 内联 | `settingsGroupId=''` 收起面板（丢弃未保存改动） | ✅ | `GroupPage.ets:582-595` |
| 17 | 设置「保存」`save` | `saveGroupSettings()` | 三字段写回组 + `saveGroups` + toast `group_settings_saved` + 条件重载 VPN + `refresh` | ✅ | `GroupPage.ets:596-608`、`GroupPage.ets:360-386` |

**分组页缺失项（事实，非判定）**：
- 无测速入口（全文件无 `LatencyTester`/`test`/`speed` 相关调用，`GroupPage.ets` import 列表 `1-15` 行）；测速只在配置页分组 chip 长按与节点长按菜单。
- 无"移动分组"入口（该动作只在配置页节点长按菜单 `Index.ets:1296-1297`）。
- 无"重命名分组"UI：`renameGroup()` 方法存在（`GroupPage.ets:335-346`）但 `renameGroupId/renameDraft` 只在该方法与声明中出现，**无任何组件绑定 → 死代码**。
- 订阅分组不出现在此页：`manualGroups()` 过滤 `!fromSubscription`（`GroupPage.ets:66-68`），订阅产生的分组只在配置页分组条显示。
- `ProfileGroup.autoSelect`（urltest 组）在配置生成器被消费（`ConfigBuilder.ets:850-873`），但本页 UI 只暴露 `isSelector`，用户无法手动开关 `autoSelect`；它只由订阅解析写入（`core/Subscriptions.ets:902-903`）。

## 4. 路由页（`activeTab===2`，`RouteRulesPage.ets` 全文 718 行，导出组件名 `RouteRulesPanel`）

结构：页头「新增」`add` + 「重置」`route_reset`（`RouteRulesPage.ets:388-417`）→ 加载态/错误态（含「重新加载」`reload`）/空态（`RouteRulesPage.ets:419-467`）→ 「远程规则集」卡区块（标题 + `add_remote_rule_set` + 每个规则集一张卡，`RouteRulesPage.ets:469-632`）→ 自定义规则 `List`（每卡：备注 + ↑↓ + 启用 + 多字段匹配区 + 删除，`RouteRulesPage.ets:634-700`）→ 底部顺序提示（`RouteRulesPage.ets:706-707`）。

持久化机制：所有编辑只改内存并 `persist()` 1s 防抖写 `route_rules`（`RouteRulesPage.ets:41-49`）；离开页面时若有挂起定时器立即补写（`RouteRulesPage.ets:61-72`）。

| # | 项（文案键） | 触发方法 | 实际行为 | 判 | 证据 |
|---|---|---|---|---|---|
| 1 | 新增规则 `add` | `addRule()` | push 一个 `new RouteRule()`（默认 `outbound='proxy'`、`enabled=true`）+ 防抖落盘 | ✅ | `RouteRulesPage.ets:393-403`、`:139-144` |
| 2 | 重置 `route_reset` | `resetRules()` | 空则 toast `route_reset_empty`；否则确认框 → 清空两套数组 + **立即** `saveRouteRules`+`saveRemoteRuleSets` + toast | ✅ | `:404-415`、`:164-184` |
| 3 | 重新加载 `reload` | `load()` | 只在 `loadError` 分支渲染；重新读 profiles/rules/remoteSets | ⚠️ | `:431-452` |
| 4 | 新增远程规则集 `add_remote_rule_set` | `addRemoteRuleSet()` | push 空 `RemoteRuleSet`（`type='site'`、`outbound='direct'`、`enabled=true`）+ 防抖落盘 | ✅ | `:475-485`、`:74-81` |
| 5 | 规则集名称 `remote_rule_set_name` | `updateRemoteRuleSet(i,'name',v)` | 只写 `item.name`；配置生成器用 `id` 作 tag、**不读 name** | ⚠️ | `:492-494`、`ConfigBuilder.ets:1162-1163` |
| 6 | 规则集 URL `remote_rule_set_url` | `updateRemoteRuleSet(i,'url',v)` | 写 `item.url`；生成 `route.rule_set` 定义（`type=remote`、`format=binary`、`download_detour=direct`、`update_interval=24h`），URL 为空则整条跳过 | ✅ | `:543-545`、`ConfigBuilder.ets:1158-1169` |
| 7 | 规则集 ↑ | `moveRemoteRuleSet(i,-1)` | 交换数组元素 + 防抖落盘；首项图标置灰但**仍可点**（无边界 return 前无禁用逻辑，`moveRemoteRuleSet` 内部对越界 return） | ✅ | `:498-517`、`:112-123` |
| 8 | 规则集 ↓ | `moveRemoteRuleSet(i,+1)` | 同上 | ✅ | `:518-537` |
| 9 | 规则集启用 `Toggle` | `updateRemoteRuleSet(i,'enabled',v)` | 写 `item.enabled`；生成器只处理 `enabled===true` 的项 | ✅ | `:538-539`、`ConfigBuilder.ets:1159` |
| 10 | 规则集类型「站点」`rule_set_site` | `updateRemoteRuleSet(i,'type','site')` | 只写 `item.type='site'`；生成器**不读 `item.type`**（站点/IP 都写成同一份 `format=binary` 远程集）⇒ 按钮无配置效果，只影响下次载入时的回显 | ⚠️ | `:547-560`、`ConfigBuilder.ets:1162-1169` |
| 11 | 规则集类型「IP」`rule_set_ip` | `updateRemoteRuleSet(i,'type','ip')` | 同上 | ⚠️ | `:561-573` |
| 12 | 规则集出站「直连」`mode_direct` | `updateRemoteRuleSet(i,'outbound','direct')` | 写 `item.outbound`；生成器写进引用规则的 `outbound` | ✅ | `:577-590`、`ConfigBuilder.ets:1171-1174` |
| 13 | 规则集出站「代理」`proxy` | `updateRemoteRuleSet(i,'outbound','proxy')` | 同上 | ✅ | `:591-603` |
| 14 | 规则集「删除」`delete_rule` | `removeRemoteRuleSet(i)` | `splice` + 防抖落盘（**无确认框**） | ✅ | `:619-623`、`:104-109` |
| 15 | 规则集「更新时间」文本 `remote_rule_set_updated` | 只读文本 | 显示 `item.updatedAt`；该字段唯一写入点是用户编辑（`updateRemoteRuleSet` 里 `updatedAt=Date.now()`），全仓无下载/校验代码写入它 ⇒ 语义是"最后编辑时间" | ⚠️ | `:607-612`、`:97` |
| 16 | 规则集「错误」文本 `remote_rule_set_error` | 只读文本 | `lastError` 仅在编辑时被清空（`:98`），**无任何写入点** ⇒ 永远不显示 | ⚠️ | `:613-618`、`:98` |
| 17 | 规则备注 `route_rule_remark` | `updateRule(i,'remark',v)` | 写 `rule.remark` + 防抖落盘（备注不进入内核规则） | ✅ | `:639-641`、`:186-221` |
| 18 | 规则 ↑ | `moveRule(i,-1)` | 交换顺序（顺序即优先级）+ 防抖落盘 | ✅ | `:644-663`、`:126-137` |
| 19 | 规则 ↓ | `moveRule(i,+1)` | 同上 | ✅ | `:664-683` |
| 20 | 规则启用 `Toggle` | `updateRule(i,'enabled',v)` | 写 `rule.enabled`；生成器跳过 `!enabled` | ✅ | `:684-685`、`ConfigBuilder.ets:1111` |
| 21 | 域名 `route_rule_domains` | `updateRule(i,'domains',v)` | 写字段；生成器解析 `full:/domain:/regexp:/keyword:/geosite:` 前缀与裸值后缀 | ✅ | `:233-235`、`ConfigBuilder.ets:462-495` |
| 22 | 目的 IP `route_rule_ip` | `updateRule(i,'ip',v)` | 写字段；`geoip:private`→`ip_is_private`、`geoip:x`→rule_set 引用、其余→`ip_cidr` | ✅ | `:241-243`、`ConfigBuilder.ets:497-519` |
| 23 | 目的端口 `route_rule_port` | `updateRule(i,'port',v)` | 写字段；支持单值与 `1000:2000` 区间（`setRulePorts`） | ✅ | `:247-249`、`ConfigBuilder.ets:521-523`、`:577+` |
| 24 | 源 IP `route_rule_source` | `updateRule(i,'source',v)` | 写 `source` → `source_ip_cidr` | ✅ | `:256-258`、`ConfigBuilder.ets:525-530` |
| 25 | 源端口 `route_rule_source_port` | `updateRule(i,'sourcePort',v)` | 写 `sourcePort` → `source_port` | ✅ | `:262-264`、`ConfigBuilder.ets:531-534` |
| 26 | 网络 `route_rule_network` | Select → `updateRule(i,'network','tcp'/'udp'/'')` | 写字段 → `network` | ✅ | `:271-280`、`ConfigBuilder.ets:535-539` |
| 27 | 协议 `route_rule_protocol` | `updateRule(i,'protocol',v)` | 写字段 → `protocol` 数组（逗号/换行都拆） | ✅ | `:284-286`、`ConfigBuilder.ets:540-546` |
| 28 | 应用包名 `route_rule_packages` | `updateRule(i,'packages',v)` | 写字段，但生成器要求 `packagesEnabled===true` 才写 `process_name`；UI **没有**这个勾选框，新建规则默认 `false` ⇒ 本次会话填了不生效；只有 `loadRouteRules` 在载入时把"包名非空的旧数据"补成 `true`（需重进页面/重启应用） | ⚠️ | `:290-295`、`ConfigBuilder.ets:547-552`、`model/RouteRule.ets:129-130`、`model/RouteRule.ets:24` |
| 29 | 自定义配置 `route_rule_config` | `updateRule(i,'config',v)` | 写字段 → `parseUserJson` 后 `deepMerge` 进规则（非法 JSON 忽略） | ✅ | `:297-302`、`ConfigBuilder.ets:553-558` |
| 30 | 出站「代理」`proxy` | `updateRule(i,'outbound','proxy')` | 写 `outbound` → 规则 `outbound: proxy` | ✅ | `:304-320`、`ConfigBuilder.ets:1124-1126` |
| 31 | 出站「直连」`mode_direct` | `updateRule(i,'outbound','direct')` | 同上，`direct` | ✅ | 同上 |
| 32 | 出站「拒绝」`reject` | `updateRule(i,'outbound','reject')` | 写 `reject`；生成器写 `action: reject` 而非 `outbound` | ✅ | `ConfigBuilder.ets:562-566` |
| 33 | 出站「指定节点」`route_outbound_profile`/`_active` | 内联：切换 `profile:<首个节点id>` 或回 `proxy` | 无节点时 toast `route_no_profiles`；否则写 `profile:<profiles[0].id>`（**默认取第一个节点**） | ✅ | `:322-344` |
| 34 | 指定节点下拉 `route_rule_profile_target` | Select → `updateRule(i,'outbound','profile:<id>')` | 首项「代理」= 取消指定；目标 id 不存在时标签显示 `route_rule_profile_missing` | ✅ | `:347-357`、`:361-383` |
| 35 | 规则「删除」`delete_rule` | `removeRule(i)` | 确认框 `confirm_delete_route_rule` → splice + 防抖落盘 | ✅ | `:691-692`、`:146-161` |

**路由页关键事实（判定依据，非主观）**

1. **无导入/导出**：本页无任何导入/导出按钮或方法；备份/恢复只在工具页（`ToolsPage.ets`），全量备份里包含 `routeRules` 与 `remoteRuleSets`（`core/Backup.ets:206-215`、`:237-251`）。
2. **改动不触发重连**：`persist()` 只写 Preferences（`RouteRulesPage.ets:41-49`），无 `VpnService.switchTo`；对比分组设置保存会条件重载（`GroupPage.ets:372-384`）。规则生效时机 = 下一次连接（扩展进程在启动时读取：`VpnExtAbility.ets:552-574`）。
3. **仅规则模式注入**：`customRules` 循环与远程规则集循环都在 `if (s.mode === 'rule')` 内（`ConfigBuilder.ets:1105-1200`）⇒ 全局/直连模式下规则静默不生效，UI 无提示。
4. **非 cn 的 geosite/geoip 引用会让整次连接失败**：引用了 `geosite:x`/`geoip:x`（x≠cn）或本地库缺失时，生成器 `throw new Error('未支持的规则集引用…')`（`ConfigBuilder.ets:1177-1196`），异常沿 `buildCoreConfig` 抛到扩展进程启动流程。
5. **规则卡 ForEach key 含 `index` 与 `remark`**（`RouteRulesPage.ets:699`）：改备注会改变 key，条目按新 key 重建。
6. 无"手动更新规则集"入口；远程规则集下载由内核按 `update_interval:24h` 自行完成（`ConfigBuilder.ets:1168`），ArkTS 侧没有任何下载/失败回报路径。

## 5. 设置页（`activeTab===3`，`SettingsPage.ets` 全文 1363 行）

结构：页头只有右侧「保存」（`dirty` 才可点，`SettingsPage.ets:443-465`）→ `Scroll` 内 7 个可折叠章节（章节头 `sectionHeader()` `SettingsPage.ets:406-439`）：常规 `settings_general`、路由 `settings_route`、DNS `settings_dns`、入站 `settings_inbound`、外观与交互 `appearance_and_interaction`、Clash API `clash_api_settings`、分应用代理 `per_app_proxy`。加载/加载失败态带「重新加载」（`:466-502`）。

**生效模型（贯穿全页的事实）**：所有开关只写 `this.s`（`@State AppSettings`）与 `markDirty()`；点「保存」→ `saveSettings` 落库 + `onSettingsChanged` 回传 Index（`:229-240`）。**除三处外都不自动重连**，保存后 toast `saved_reconnect_vpn` 明示需重连；三处例外：出站模式（本页无入口，见下）、分应用模式（`:1139-1149` 自动 `VpnService.switchTo`）、分应用条目勾选/增删（`:272-287`）、主题外观（`:200-223` 立刻 `setColorMode` 且立刻落盘）。配置侧消费点全部在 VPN 启动时读取（`VpnExtAbility.ets:552-576`）。

| # | 项（文案键） | 写入字段 | 谁消费（证据） | 判 | UI 证据 |
|---|---|---|---|---|---|
| 1 | 保存 `save` | 整个 `AppSettings` | `Store.saveSettings` → 下次连接由 `VpnExtAbility.loadSettings()` 读取 | ✅ | `:447-462`、`:229-240` |
| 2 | 章节头「常规」 | 无（仅展开态） | — | ✅ | `:507` |
| 3 | 章节头「路由」 | 无 | — | ✅ | `:658` |
| 4 | 章节头「DNS」 | 无 | — | ✅ | `:847` |
| 5 | 章节头「入站」 | 无 | — | ✅ | `:937` |
| 6 | 章节头「外观与交互」 | 无 | — | ✅ | `:971` |
| 7 | 章节头「Clash API」 | 无 | — | ✅ | `:1077` |
| 8 | 章节头「分应用代理」 | 无 | — | ✅ | `:1122` |
| 9 | 自动连接 `settings_auto_connect` | `autoConnect` | `Index.autoConnect()` 启动时 `VpnService.connect`（`Index.ets:373-389`） | ✅ | `:515-519` |
| 10 | 日志级别 `settings_log_level` | `logLevel` | `ConfigBuilder` → `log.level`（`ConfigBuilder.ets:1251`）；非法值回退 info（`Store.ets:199-202`） | ✅ | `:524-531` |
| 11 | 测速方式 `latency_test_mode` | `latencyTestMode` | **只被**配置页分组菜单「测速本组」使用（`Index.ets:598-600`）；⋮ 的两个入口不受它影响 | ⚠️ | `:535-544` |
| 12 | 测速网址 `settings_test_url` | `testUrl` | `LatencyTester`（`LatencyTester.ets:344`）、urltest 出站探测地址（`ConfigBuilder.ets:863`）、clash 单节点测速（`Index.ets:1140`） | ✅ | `:548-556` |
| 13 | 测速并发 `settings_test_concurrent` | `testConcurrent`（钳 1..32） | `testProfiles`/`urlTestProfiles` 调用参数（`Index.ets:674,680`；钳制 `Store.ets:223-225`） | ✅ | `:560-569` |
| 14 | 全局自定义配置 `settings_global_custom_config` | `globalCustomConfig` | `ConfigBuilder` 与根对象浅合并（`ConfigBuilder.ets:1268`） | ✅ | `:573-584` |
| 15 | 始终显示地址 `settings_always_show_address` | `alwaysShowAddress` | 节点卡第二行（`Index.ets:1929-1939`） | ✅ | `:588-592` |
| 16 | 其它分区保留底栏 `show_bottom_bar` | `showBottomBar` | StatsBar 与 FAB 的显示条件（`Index.ets:2653`、`:2677`） | ✅ | `:597-601` |
| 17 | 通知显示分组名 `settings_notification_group` | `notificationGroup` | 扩展进程通知标题前缀（`VpnExtAbility.ets:458-463`、`:776-777`） | ✅ | `:606-610` |
| 18 | 速率刷新间隔 `settings_speed_interval` | `speedIntervalMs` | **只影响常驻通知**轮询（`VpnExtAbility.ets:673-676`，500..10000ms 兜底）；首页速率条固定 1000ms（`Index.ets:428`） | ⚠️ | `:619-625` |
| 19 | 全局放行不安全 TLS `settings_insecure_tls` | `allowInsecureAll` | 出站 TLS 生成（`ConfigBuilder.ets:71`） | ✅ | `:633-637` |
| 20 | 订阅放行不安全 TLS `settings_sub_allow_insecure` | `subAllowInsecure` | 订阅下载（`Index.ets:1576` → `fetchSubscriptionWithInfo`） | ✅ | `:645-649` |
| 21 | 直连域名后缀 `settings_direct_domain_suffix` | `directDomains` | 仅 `mode==='rule'` 生成 `domain_suffix→direct`（`ConfigBuilder.ets:1131-1137`；UI 也只在 rule 显示 `:660`） | ✅ | `:663-668` |
| 22 | 直连 IP 段 `settings_direct_cidr` | `directIpCidrs` | 同上 → `ip_cidr→direct`（`ConfigBuilder.ets:1138-1144`） | ✅ | `:671-676` |
| 23 | 下载 Geo 数据 `settings_geo_download` / `_redownload` / `_downloading` | 无（写文件） | `downloadGeoAssets()` 落 `geosite/geoip` 文件，`geoReady()` 反馈（`utils/GeoAssets.ets:127`、`:77`） | ✅ | `:681-692` |
| 24 | 导入 Geo 数据库 `settings_geo_import` | 无（写文件） | `importGeoAssetFromFile()` 复制用户选择的 .db（`GeoAssets.ets:212`）；用户取消返回 null 不报错 | ✅ | `:697-710` |
| 25 | 单库更新 `settings_geo_update_one` | 无 | `downloadGeoAsset(kind)`（`GeoAssets.ets:177`） | ✅ | `:722-735` |
| 26 | 单库删除 `settings_geo_delete` | 无 | 确认框 → `deleteGeoAsset(kind)`（`GeoAssets.ets:190`） | ✅ | `:736-751`、`:146-166` |
| 27 | TUN MTU `settings_tun_mtu` | `mtu` | `tun.mtu`（`ConfigBuilder.ets:825`）；**载入时被夹到 1280..1500**（`Store.ets:190`），与输入框 placeholder `9000` 不一致 ⇒ 填大值静默变 1500 | ⚠️ | `:762-768` |
| 28 | TUN 栈 `settings_tun_stack` | `stack` | `tun.stack`（`ConfigBuilder.ets:828`）；**选项只有 `'system'` 一项**（`:22`） | ⚠️ | `:773-779` |
| 29 | IPv6 模式 `settings_enable_ipv6` | `ipv6Mode` | `effectiveIpv6Mode()` 决定 tun 地址族（`ConfigBuilder.ets:813-824`）；非法值回退（`Store.ets:208`） | ✅ | `:784-790` |
| 30 | 绕过局域网 `settings_bypass_lan` | `bypassLan` | `ip_is_private→direct`（`ConfigBuilder.ets:1090-1095`） | ✅ | `:798-802` |
| 31 | 嗅探「关闭」`sniff_off` | `sniffMode='off'` | 不生成 sniff 规则（`ConfigBuilder.ets:1056`）；非法值回退 `route`（`Store.ets:203-206`） | ✅ | `:809-825` |
| 32 | 嗅探「路由」`sniff_route` | `sniffMode='route'` | `action:sniff`（`ConfigBuilder.ets:1062`） | ✅ | 同上 |
| 33 | 嗅探「覆写」`sniff_override` | `sniffMode='override'` | `action:sniff` + `override_destination:true`（`ConfigBuilder.ets:1063-1065`，依赖内核补丁 6） | ✅ | 同上 |
| 34 | 解析目标地址 `settings_resolve_destination` | `resolveDestination` | `action:resolve` 规则（`ConfigBuilder.ets:1076-1081`）。**注意**：`model/Profile.ets:189` 的注释"配置暂不消费"已过时 | ✅ | `:835-839` |
| 35 | 远程 DNS `settings_remote_dns` | `remoteDns` | `dns.servers` 生成；旧默认值迁移（`Store.ets:267-270`） | ✅ | `:852-857` |
| 36 | 远程 DNS 策略 `settings_remote_dns_strategy` | `remoteDnsStrategy` | `dns.strategy`（`ConfigBuilder.ets:1048`） | ✅ | `:864-870` |
| 37 | 直连 DNS `settings_direct_dns` | `directDns` | local DNS server 生成 | ✅ | `:875-880` |
| 38 | 直连 DNS 策略 `settings_direct_dns_strategy` | `directDnsStrategy` | `dnsStrategy(direct…)` | ✅ | `:885-891` |
| 39 | 服务器域名策略 `settings_server_dns_strategy` | `serverDnsStrategy` | `route.default_domain_resolver.strategy`（`ConfigBuilder.ets:1223-1226`） | ✅ | `:896-904` |
| 40 | DNS 路由 `settings_dns_routing` | `dnsRouting` | CN 域名走直连 DNS（`ConfigBuilder.ets:938`、`:1033`，需 `mode==='rule'` 且有 geo 库） | ✅ | `:912-916` |
| 41 | FakeDNS `settings_fakedns` | `fakeDns` | fakeip server + 规则（`ConfigBuilder.ets:921`、`:1004`、`:1018`） | ✅ | `:924-928` |
| 42 | 混合端口 `settings_mixed_port` | `mixedPort`（0=关，钳 1024..65535） | `mixed-in` inbound（`ConfigBuilder.ets:832-838`），同时影响包名规则仅对 tun 的 sniff 判定（`:1059-1061`） | ✅ | `:942-948` |
| 43 | 允许局域网访问 `settings_allow_access` | `allowAccess` | mixed `listen` = `0.0.0.0`（`ConfigBuilder.ets:836`） | ✅ | `:956-960` |
| 44 | 外观「跟随系统」`appearance_follow_system` | `appearance='system'` | `applyAppearance()` → `context.setColorMode(NOT_SET)`，**立即落盘**（`:202-209`） | ✅ | `:975-992` |
| 45 | 外观「浅色」`appearance_light` | `appearance='light'` | 同上 `COLOR_MODE_LIGHT` | ✅ | 同上 |
| 46 | 外观「深色」`appearance_dark` | `appearance='dark'` | 同上 `COLOR_MODE_DARK` | ✅ | 同上 |
| 47 | 排序「手动」`sort_manual` | `profileSortMode='manual'` | 节点列表排序 + 长按菜单上下移的显示条件（`Index.ets:898-910`、`:1275`） | ✅ | `:997-1014` |
| 48 | 排序「延迟」`sort_latency` | `profileSortMode='latency'` | 同上 | ✅ | 同上 |
| 49 | 排序「名称」`sort_name` | `profileSortMode='name'` | 同上 | ✅ | 同上 |
| 50 | 触感反馈 `haptic_feedback` | `hapticFeedback` | **全仓无消费方**（`grep vibrator|haptic` 仅命中 `Profile.ets:223`、`SettingsPage.ets:1017-1020`、`Backup.ets:101`）⇒ 开关只落库，无任何振动调用 | ❌ | `:1018-1022` |
| 51 | 液态玻璃 `liquid_glass` | `liquidGlass` | **全仓无消费方**（仅 `Profile.ets:246`、本页、`Backup.ets:101`）⇒ 不影响任何 UI 材质 | ❌ | `:1026-1030` |
| 52 | 网络变化重置连接 `network_change_reset_connections` | `networkChangeResetConnections` | 扩展进程仅当为 true 时重建连接（`VpnExtAbility.ets:181-203`，含 15s 合并窗口 `:195`）；但 `Store.loadSettings` 在首次迁移时**强制写回 false**（`Store.ets:277-285`），且恢复出厂后该标记被清除 ⇒ 迁移会再跑一次 | ⚠️ | `:1038-1042` |
| 53 | 唤醒后重置连接 `wake_reset_connections` | `wakeResetConnections` | 扩展进程前台事件处理（`VpnExtAbility.ets:245-285`），UI 侧发事件（`EntryAbility.ets:331`） | ✅ | `:1050-1054` |
| 54 | 节点流量统计 `profile_traffic_statistics` | `profileTrafficStatistics` | 节点卡显示 rx/tx（`Index.ets:1940-1946`）；会话结束累加落库（`VpnExtAbility.ets:701-719`） | ✅ | `:1062-1066` |
| 55 | Clash API 开关 `clash_api_enabled` | `clashApiEnabled` | `experimental.clash_api` 生成（`ConfigBuilder.ets:1233-1238`）；首页速率/连接页轮询条件（`Index.ets:395`、`ConnectionsPage.ets:115`） | ✅ | `:1082-1086` |
| 56 | Clash API 端口 `clash_api_port` | `clashApiPort`（钳 1024..65535，默认 19290） | `external_controller`（`ConfigBuilder.ets:1235`）；9090→19290 一次性迁移（`Store.ets:279-281`） | ✅ | `:1090-1100` |
| 57 | Clash API 密钥 `clash_api_secret` | `clashApiSecret` | `clash_api.secret`（`ConfigBuilder.ets:1236`）；空值自动生成并落盘（`Store.ets:262-266`） | ✅ | `:1104-1111` |
| 58 | 分应用「关闭」`per_app_off` | `perAppMode='off'` | 扩展进程按模式构造 VpnConfig（`VpnExtAbility.ets:519`、`VpnService.ets:79`）；切换后自动重连（`:1139-1149`） | ✅ | `:1127-1149` |
| 59 | 分应用「排除」`per_app_exclude` | `perAppMode='exclude'` | 同上 | ✅ | 同上 |
| 60 | 分应用「仅代理」`per_app_include` | `perAppMode='include'` | 同上 | ✅ | 同上 |
| 61 | 分应用搜索框 `per_app_search_placeholder` | `appSearch`（仅本地过滤） | `perAppFilteredEntries()` 按名称/包名过滤（`:298-305`） | ✅ | `:1160-1162` |
| 62 | 添加/批量导入 `per_app_add_import` | 打开 `PerAppAddDialog` | 见 #68-71 | ✅ | `:1163-1175`、`:345-350` |
| 63 | 条目复选框 | `perAppEntries[i].enabled` | `persistPerApp()` → `s.perAppList` 派生 + `saveSettings` + 运行中自动重连（`:272-287`） | ✅ | `:1218-1222` |
| 64 | 条目「移除」`per_app_remove_entry` | `removeEntry` | 确认框 → 移除 + `persistPerApp` | ✅ | `:1213-1216`、`:320-333` |
| 65 | 清除选择 `clear_selections` | `clearAppSelections()` | 全条目置未勾选（保留条目）+ 落库 + 重连 | ✅ | `:1232-1245`、`:336-343` |
| 66 | 从剪贴板导入 `import_selections_clipboard` | `importAppListFromClipboard()` | 解析 `"false\n<包名列表>"`，合并（不清空）+ 落库 + 重连；格式不符 toast `action_import_err` | ✅ | `:1246-1258`、`:393-403` |
| 67 | 导出到剪贴板 `export_selections_clipboard` | `exportAppListToClipboard()` | 生成 `"false\n<pkgs>"` 写剪贴板 + toast | ✅ | `:1262-1275`、`:379-387` |
| 68 | 弹窗「名称备注」输入 | `perAppDialogLabel` | 只作显示名，不参与系统路由（单包名时作为条目 label） | ✅ | `:1324-1327`、`:353-373` |
| 69 | 弹窗「包名」文本域 | `perAppDialogPackages` | 逐行/逗号解析，非法包名单独计数 | ✅ | `:1328-1336` |
| 70 | 弹窗「取消」`cancel` | `controller.close()` | 丢弃输入 | ✅ | `:1344-1352` |
| 71 | 弹窗「确认」`per_app_dialog_confirm` | `confirmPerAppDialog()` | 校验（空/全非法分别报错）→ `mergeEntries` → toast 有效/无效数 → `persistPerApp` | ✅ | `:1353-1357`、`:353-373` |

**设置页死代码（事实）**：`switchMode()`（`:242-263`）、`modeIndex()`（`:191-194`）、`MODE_LABELS`（`:24`）、`MODE_SWITCH_TOASTS`（`:25`）在本页**无任何组件引用**——出站模式只能在配置页模式行切换（`Index.ets:1845-1872`），本页没有模式选择器。

## 6. 日志页（`activeTab===4`，`LogPage.ets` 全文 222 行，导出组件名 `LogPanel`）

结构：工具行（「导出」`log_export`、「清空」`log_clear`，`LogPage.ets:139-171`）→ 搜索框 `log_search_hint`（`:173-178`）→ 级别按钮行 ALL/ERROR/WARN/INFO/DEBUG（`:180-198`）→ 日志 `List`（追加后自动滚到底，超 2000 行截断，`:51-59`、`:200-219`）。
数据来源两条：进程内 `LogStore`（内存环形缓冲 2000 行，`Store.ets:394-446`）+ 内核日志文件 `singbox.log` 每秒增量 tail（`LogPage.ets:99-135`、`core/CoreManager.ets:35-37`；每次连接开始时该文件被清空重建，`VpnExtAbility.ets:535`）。

| # | 项（文案键） | 触发方法 | 实际行为 | 判 | 证据 |
|---|---|---|---|---|---|
| 1 | 导出 `log_export` | `exportLogs()` | 取**当前过滤后**文本 → `DocumentViewPicker.save` → `fs.writeSync`；空内容 toast `log_export_empty`，异常 toast | ✅ | `LogPage.ets:144-154`、`:71-96` |
| 2 | 清空 `log_clear` | 内联 onClick | `LogStore.clear()` + `lines=[]` + **`fileOffset=0`**；1s 后 `tailCoreLog()` 从偏移 0 重读当前 `singbox.log` 并 append ⇒ 已清掉的内核日志行重新出现（内存行确实被清） | ❌ | `LogPage.ets:155-169`、`:99-135`、`:38-40` |
| 3 | 搜索框 `log_search_hint` | 内联 onChange | 写 `searchText`；`filteredLines()` 大小写不敏感子串过滤（无防抖） | ✅ | `:173-178`、`:61-69` |
| 4 | 级别「ALL」 | `levelFilter='ALL'` | 不过滤 | ✅ | `:181-195` |
| 5 | 级别「ERROR」 | `levelFilter='ERROR'` | `line.toUpperCase().includes('ERROR')`：只按子串匹配，**应用侧日志行（`[ui] …`/`[vpn] …`）不含级别词会被整体滤掉**；内核 sing-box 行含级别词可命中 | ⚠️ | `:61-69`、`:181-195` |
| 6 | 级别「WARN」 | `levelFilter='WARN'` | 同上 | ⚠️ | 同上 |
| 7 | 级别「INFO」 | `levelFilter='INFO'` | 同上 | ⚠️ | 同上 |
| 8 | 级别「DEBUG」 | `levelFilter='DEBUG'` | 同上 | ⚠️ | 同上 |

**日志页边界**：`emitter.off` + `clearInterval` 在 `aboutToDisappear` 释放（`LogPage.ets:43-49`）；文件不存在/异常时静默下轮重试（`:132-134`）；文件被截断（重连）时 `fileOffset` 归零（`:107-109`）。

## 7. 工具页（`activeTab===5`，`ToolsPage.ets` 全文 445 行）

结构：3 张卡片——「NAT 行为发现（STUN）」`stun_title`（`:257-311`）、「备份与恢复」`backup_restore`（`:314-407`）、「恢复出厂」`reset_title`（`:410-433`），整页 `Scroll`。

| # | 项（文案键） | 触发方法 | 实际行为 | 判 | 证据 |
|---|---|---|---|---|---|
| 1 | STUN 服务器输入 | 内联 onChange | 只写 `stunServer`（默认 `stun.cloudflare.com:3478`），不落库 | ✅ | `ToolsPage.ets:263-265` |
| 2 | STUN 测试 `stun_test`/`stun_testing` | `runStun()` → `stunTest(server)` | 真 UDP：`constructUDPSocketInstance` + RFC5389 Binding Request，两次探测比对映射地址判 NAT 类型；超时/解析失败返回 `ok:false` 并显示 `stun_failed` | ✅ | `:194-209`、`utils/StunTester.ets:121-161`、`:104-117` |
| 3 | 导出备份文件 `export_backup_file` | `exportBackupFile()` | `exportBackup()` 打包 settings/profiles/groups/subscriptions/routeRules/remoteRuleSets → `DocumentViewPicker.save` → 写 JSON；忙碌互斥、取消/异常 toast | ✅ | `:142-166`、`core/Backup.ets:237-251` |
| 4 | 从文件恢复 `restore_from_file` | `importBackupFile()` → `restoreText()` | 先 `prepareForRestore()`：VPN 活跃则断开并**轮询等 15s** 确认 `disconnected`；再 `importBackup`（校验 → 取快照 → 全量写 → 失败全量回滚）；文件空/超 20MB/读不全分别报错 | ✅ | `:168-192`、`:83-109`、`core/Backup.ets:254-298` |
| 5 | 备份到剪贴板 `backup_to_clipboard` | 内联 async | `exportBackup` → `pasteboard.setData` + toast；异常 toast | ✅ | `:352-374` |
| 6 | 从剪贴板恢复 `restore_from_clipboard` | 内联 async | 读剪贴板 → 空则 toast → `restoreText()` → 摘要 toast（含"已断开 VPN"分支） | ✅ | `:375-400`、`:37-43` |
| 7 | 恢复出厂 `reset_action` | `requestReset()` → 二次确认 → `doReset()` | `resetAllData()` = `pref.clear()`（清空全部 Preferences：节点/分组/设置/订阅/规则）；**不停 VPN、不重置 AppStorage、不刷新 Index 已加载列表**；`coexistFix202609Applied` 一并清掉 ⇒ 下次 `loadSettings` 会再次把 `networkChangeResetConnections` 强制设为 false | ⚠️ | `:211-248`、`model/Store.ets:333-337`、`Store.ets:277-285` |

## 8. 关于页（`activeTab===6`，`AboutPage.ets` 全文 189 行）

结构：单卡（应用名 + 版本 `settings_about_version` + 内核版本 `about_core_version` 两个只读 `InfoRow` + 三个按钮，`:96-153`）→ 开源许可文本卡（只读，`:155-165`）。

| # | 项（文案键） | 触发方法 | 实际行为 | 判 | 证据 |
|---|---|---|---|---|---|
| 1 | 检查更新 `check_update`/`checking_update` | `checkUpdate()` | 真 HTTP GET `api.github.com/.../releases/latest`（10s/15s 超时）→ 比对 `versionName`；相同 toast `check_update_latest`，不同 toast `check_update_new` **并自动打开 GitHub 页面**；解析失败/网络异常 toast `check_update_failed` | ✅ | `AboutPage.ets:104-118`、`:52-90` |
| 2 | 项目主页 `about_github` | `openGitHub()` → `openLink()` | `context.openLink('https://github.com/xiaoli8571/NekoBox4Harmony')`；无可用处理器时把 URL 用 toast 展示供复制 | ✅ | `:119-132`、`:35-50` |
| 3 | Telegram `about_telegram` | `openTelegram()` → `openLink()` | 同上（`https://t.me/+x9D290Stp9NhYWU9`） | ✅ | `:133-146`、`:9-10` |

**关于页事实**：内核版本是硬编码常量 `sing-box 1.14.0 (OHOS c-shared)`（`:8`），**不查询运行中的 `.so` 真实版本**（`CGoSingBoxVersion` 导出存在但本页未调用）；应用版本来自 `bundleManager.getBundleInfoForSelfSync`，失败显示 `—`（`:26-33`、`:101`）。

## 9. 二级页可达性（与 7 个抽屉页相邻的事实）

| 页面 | 入口 | 证据 |
|---|---|---|
| `pages/ProfileEdit`（新建/编辑节点） | 顶栏＋→「新建节点」；节点长按→「编辑节点」 | `Index.ets:1294`、`Index.ets:1329` |
| `pages/SubDetailPage`（订阅详情） | 节点长按→「查看订阅」（需 `subUrl` 非空） | `Index.ets:1300` |
| `pages/ConnectionsPage`（连接列表/断开单连接） | 顶栏连接图标 | `Index.ets:2386`；页内动作 `ConnectionsPage.ets:186-198`、`:286-299` |
| `pages/DocPage` | **无入口**（已从抽屉移除） | `Index.ets:55` |
| `pages/DashboardPage`（内嵌 yacd Web 面板） | **无入口、无 import** | 仅 `DashboardPage.ets:13`；`utils/WebUiAssets.ets:23` 只被它引用 |
| `SubUpdateFeedback`（订阅差异弹窗） | 订阅更新后的 1s 延迟弹窗 | `Index.ets:822-836`、`GroupPage.ets:95-108` |

## 10. 死路 / 仅提示清单（代码级证据）

| # | 位置 | 现象 | 证据 |
|---|---|---|---|
| D1 | 顶栏搜索图标（非配置页） | 置 `searchVisible=true`，但搜索行只在首页渲染 ⇒ 6 个非配置页点了没有任何可见反应 | `Index.ets:2356-2371` + `Index.ets:2540-2552` |
| D2 | ⋮「清除流量统计」 | 只清 `AppStorage` 累计值；内核 `/connections` 无重置接口，UI 1s 轮询与扩展进程 `speedIntervalMs` 轮询立即写回真实值 ⇒ 显示 ≤1s 复原 | `Index.ets:879-886`、`Index.ets:424-425`、`VpnExtAbility.ets:668-670`、`utils/TrafficStats.ets:14-40` |
| D3 | 日志「清空」 | `fileOffset=0` 让 1s 后的 tail 从文件头重读当前 `singbox.log` ⇒ 内核日志行重新出现（只有内存日志被真正清掉） | `LogPage.ets:165-169` + `:99-135` |
| D4 | 设置「触感反馈」`hapticFeedback` | 无任何消费方（全仓无 vibrator 调用），开关只写 Preferences | `Profile.ets:223`、`SettingsPage.ets:1018-1022`（全仓 grep 仅此 + `Backup.ets:101` 白名单） |
| D5 | 设置「液态玻璃」`liquidGlass` | 无任何消费方，不影响任何材质/模糊 | `Profile.ets:246`、`SettingsPage.ets:1026-1030` |
| D6 | 路由页「远程规则集类型」（站点/IP） | 写入 `item.type`，配置生成器只写 `format=binary`、不读 `type` ⇒ 按钮不改变生成的配置 | `RouteRulesPage.ets:547-573`、`ConfigBuilder.ets:1162-1169` |
| D7 | 路由页「包名」字段 | 生成器要求 `packagesEnabled===true`（UI 无此勾选框，新规则默认 false）⇒ 本次会话填的包名不进内核；只有下次载入被迁移逻辑补 true 才生效 | `ConfigBuilder.ets:547-552`、`model/RouteRule.ets:24`、`:129-130` |
| D8 | 路由页「更新时间/错误」文本 | `updatedAt` 仅由用户编辑写入、`lastError` 只有清空写入点 ⇒ 前者显示"最后编辑时间"，后者永不出现 | `RouteRulesPage.ets:97-98`、`:607-618` |
| D9 | 分组页重命名 | `renameGroup()`/`renameGroupId`/`renameDraft` 无任何 UI 绑定 ⇒ 死代码，页面无重命名入口 | `GroupPage.ets:29-30`、`:335-346` |
| D10 | 设置页出站模式 | `switchMode()`/`modeIndex()`/`MODE_LABELS`/`MODE_SWITCH_TOASTS` 无组件引用 ⇒ 死代码（模式只能在配置页切） | `SettingsPage.ets:24-25`、`:191-194`、`:242-263` |
| D11 | 节点长按「URL Test」 | 结果只写内存不落库（代码注释明示），下次 `refresh()`/重进页面即回退 | `Index.ets:1128-1167`（`:1141` 注释） |
| D12 | `pages/DocPage` / `pages/DashboardPage` | 文件存在但无任何路由/import 调用 ⇒ 不可达（"使用文档"与"yacd Web 面板"两个能力在 UI 上不存在） | `Index.ets:54-55`；全仓 grep `DashboardPage` 仅命中定义处 |

**未发现"点了完全没接方法"的按钮**：7 个页面的每个 `onClick`/`onTouch(Up)`/`bindContextMenu` 均指向存在的方法体（逐个核对 `Index`/`GroupPage`/`RouteRulesPage`/`SettingsPage`/`LogPage`/`ToolsPage`/`AboutPage` 的全部绑定）。

## 11. 速览表（7 页 × 可点项数 × 判定计数）

| 页面 | 组件/文件 | 可点项 | ✅ | ⚠️ | ❌ |
|---|---|---|---|---|---|
| （共享壳层）☰ + 顶栏动作簇 + 抽屉 7 项 | `Index.ets:1660-1693`、`:2350-2412` | 13 | 12 | 0 | 1 |
| 1 配置 | `Index.ets:2004-2059`（含 ⋮ 11 项、节点菜单 12 项、分组菜单 6 项） | 42 | 31 | 10 | 1 |
| 2 分组 | `GroupPage.ets` | 17 | 14 | 3 | 0 |
| 3 路由 | `RouteRulesPage.ets` | 35 | 28 | 7 | 0 |
| 4 设置 | `SettingsPage.ets` | 71 | 64 | 5 | 2 |
| 5 日志 | `LogPage.ets` | 8 | 3 | 4 | 1 |
| 6 工具 | `ToolsPage.ets` | 7 | 6 | 1 | 0 |
| 7 关于 | `AboutPage.ets` | 3 | 3 | 0 | 0 |
| **合计** | | **196** | **161** | **30** | **5** |

> 计数口径：共享壳层单列（不摊进各页，避免重复统计）；每张卡片/每个菜单项各计 1 项；条件渲染项（"上移/下移"仅手动排序可见、"查看订阅"仅有订阅时可见等）按 1 项计入并标 ⚠️；对话框内按钮计入所属页。
