# P0 基线：UI 入口清单（W01）

> 取证对象：`C:\Worker\NekoBox4Harmony`（branch `debug`，含未提交改动，只读取证）。
> 取证时间：2026-10-24 09:46（Asia/Shanghai）。行号均为**本次取证时**实际行号；本文件创建后如再有并发改动，请以方法名 / `$r(...)` 键重新定位（前次审计的经验见 `docs/menu-audit/ours-side.md` §基线）。
> 证据方法：逐文件 `read` 全文（Index.ets 2982 行、SettingsPage.ets 1360 行、RouteRulesPage.ets 731 行、GroupPage.ets 654 行、SubDetailPage.ets 591 行、ProfileEdit.ets 902 行、ConnectionsPage.ets 327 行、LogPage.ets 222 行、ToolsPage.ets 445 行、AboutPage.ets 189 行、SubUpdateFeedback.ets 75 行、DashboardPage.ets 74 行、DocPage.ets 69 行、model/Store.ets 446 行），并对关键绑定逐条 `grep` 复核。
> 计数口径：沿用 `docs/menu-audit/ours-side.md`（196 项）口径——每个可点条目/控件计 1，同一控件在不同状态下的文案变体不重复计，互斥分支各自计 1；共享壳层单列。**与上次审计的差异：SettingsPage「通知显示分组名」开关已被移除**（`SettingsPage.ets:608-609` 注释），故本次总数为 **195**。
> 本文件是 P0 基线（现状盘点），不含实施动作；改造依据见 `docs/REDESIGN-PLAN-2026-10-23.md`（下称 PLAN）。

---

## 0. 摘要统计

| 指标 | 数值 | 说明 |
|---|---|---|
| 可点入口总数 | **195** | 13（共享壳层）+ 42（节点/配置）+ 17（订阅/分组）+ 35（分流/路由）+ 70（设置）+ 8（日志）+ 7（工具）+ 3（关于） |
| 判定为「保留」（同名/同职责页稳定） | **121**（62.1%） | 设置 44、分流 32、节点 20、订阅 7、工具 7、关于 3、壳层 6、日志 2 |
| 判定为「迁移」（换页/改名） | **42**（21.5%） | 设置 21（分应用 15＋直连域名 2＋Geo 4）、订阅 10、壳层 6、节点 3、分流 1、日志 1 |
| 判定为「合并」（多入口收敛为一） | **26**（13.3%） | 节点页 18（测速 ×7、批量 ×6、排序 ×3、上下移 ×2）、日志级别 ×5、设置排序 ×3 |
| 判定为「移除」（死路/无消费方） | **6**（3.1%） | D1 顶栏搜索 1、N33 清除流量 1、D4 触感 1、D5 液态玻璃 1、D6 规则集类型 ×2 |
| 已知死路 D1~D12 | 全部复核成立 | 另补充发现 D13~D15（§5） |
| 未注册/无引用的死文件 | **2** | `pages/DocPage.ets`、`pages/DashboardPage.ets` |

TOP 风险（详见 §7）：① 顶栏动作簇（＋/连接/⋮/搜索）是「配置页语义」却常驻全部 7 页，与 PLAN §3.3「页面专属顶栏」冲突；② 订阅能力分裂在 3 处（分组页订阅卡 / SubDetailPage / 节点长按「查看订阅」）；③ 分流能力分裂在 3 处（路由页 / 设置页分应用块 / 分组页策略组面板）；④ D2/D3 两个「假清除」直接影响 PLAN §10.4 验收；⑤ 二级页跳转无 sessionId/configRevision 参数化，PLAN §3.4 上下文要求需新增契约。

---

## 1. 当前页面清单

**路由方式总述**：全应用只有 Index 一个「一级页」——HDS Navigation 仅作标题栏宿主（`Index.ets:2674-2700`），页面切换靠 `activeTab` 内存变量（0..6），**无 router 跳转、无 URL**（`Index.ets:1711-1728` 只写 `activeTab`；`Index.ets:2518-2564` 按值渲染内嵌组件）。二级页（ProfileEdit/ConnectionsPage/SubDetailPage）用 `router.pushUrl`（`Index.ets:1329,1335,1364,2421`）。路由注册表只有 4 页（`entry/src/main/resources/base/profile/main_pages.json`）。

| # | 文件 | 组件名 | 类型 | 路由注册 | 当前进入方式 | 证据 |
|---|---|---|---|---|---|---|
| 1 | `pages/Index.ets` | `Index` | `@Entry` 壳层 | ✅ | 应用启动入口（`EntryAbility` 加载） | `Index.ets:80-82`；main_pages.json |
| 2 | `pages/GroupPage.ets` | `GroupPage` | `@Component` 内嵌 | — | 抽屉「分组」→ `activeTab=1` | `Index.ets:1715-1716`、`2521-2529` |
| 3 | `pages/RouteRulesPage.ets` | `RouteRulesPanel` | `@Component` 内嵌 | — | 抽屉「路由」→ `activeTab=2` | `Index.ets:1717-1718`、`2530-2535` |
| 4 | `pages/SettingsPage.ets` | `SettingsPage` | `@Component` 内嵌 | — | 抽屉「设置」→ `activeTab=3` | `Index.ets:1719-1720`、`2536-2544` |
| 5 | `pages/LogPage.ets` | `LogPanel` | `@Component` 内嵌 | — | 抽屉「日志」→ `activeTab=4` | `Index.ets:1721-1722`、`2545-2550` |
| 6 | `pages/ToolsPage.ets` | `ToolsPage` | `@Component` 内嵌 | — | 抽屉「工具」→ `activeTab=5` | `Index.ets:1723-1724`、`2551-2556` |
| 7 | `pages/AboutPage.ets` | `AboutPage` | `@Component` 内嵌 | — | 抽屉「关于」→ `activeTab=6` | `Index.ets:1725-1726`、`2557-2563` |
| 8 | `pages/ProfileEdit.ets` | `ProfileEdit` | `@Entry` 二级 | ✅ | 顶栏＋→「新建节点」（`editProfileId=''`）；节点长按→「编辑节点」（`editProfileId=p.id`） | `Index.ets:1362-1364`、`1326-1330`、`1329` |
| 9 | `pages/SubDetailPage.ets` | `SubDetailPage` | `@Entry` 二级 | ✅ | 节点长按→「查看订阅」（仅 `subUrl` 非空时渲染） | `Index.ets:1333-1336` |
| 10 | `pages/ConnectionsPage.ets` | `ConnectionsPage` | `@Entry` 二级 | ✅ | 顶栏连接图标 | `Index.ets:2416-2422` |
| 11 | `pages/DocPage.ets` | `DocPage` | `@Entry` 二级 | ❌ **未注册** | **无入口**（2026-10-17 用户要求从抽屉移除） | `DocPage.ets:12`；main_pages.json 仅 4 页 |
| 12 | `pages/DashboardPage.ets` | `DashboardPage` | `@Component` 未引用 | — | **无 import / 无入口**（yacd Web 面板） | `DashboardPage.ets:13`（全仓 grep 仅定义处） |
| 13 | `pages/SubUpdateFeedback.ets` | `SubDiffDialog` | `@CustomDialog` | — | 订阅更新后 1s 弹出（Index 与 GroupPage 各一套） | `Index.ets:861-867`、`GroupPage.ets:101-107` |

> 补充：`@Entry` 组件共 4 个（`Index/ProfileEdit/ConnectionsPage/SubDetailPage/DocPage` 中的 4 个已注册，DocPage 虽标 `@Entry` 但不在 main_pages.json）。`Index.ets` 内部还有 4 个本页弹窗组件：`ShareTextDialog`（2729-2775）、`ImportDialog`（2779-2838）、`AddEntryDialog`（2842-2916）、`MoveToGroupDialog`（2920-2981）。

---

## 2. 抽屉菜单现状

### 2.1 七项定义与去向

定义：id `Index.ets:56`；文案 `Index.ets:57-65`；图标 `Index.ets:66-74`；`activeTab(0..6)→抽屉下标` 恒等映射 `Index.ets:76`。列表渲染 `drawerItems()` `Index.ets:1695-1700` + `ForEach` 行 `Index.ets:1760-1787`（48vp 行高、系统符号图标、按下点光）。点击回调 `onDrawerSelect(id)` **只写 `activeTab`**，无路由无落库（`Index.ets:1711-1728`）。当前分区标题与抽屉共用同一批字符串资源（`sectionTitle()` `Index.ets:2288-2308`）。

| # | id | 文案键 | 当前文案 | 图标（sys.symbol） | 去向 | 新版七页映射（PLAN §3） |
|---|---|---|---|---|---|---|
| 1 | `config` | `nav_config` | **配置** | `list_square` | `activeTab=0` → `configFragment()`（`Index.ets:1713-1714`、`2519-2520`、`2040-2094`） | **节点**（改名；位置/顺序保留） |
| 2 | `groups` | `nav_groups` | **分组** | `folder` | `activeTab=1` → `GroupPage`（`Index.ets:1715-1716`、`2521-2529`） | **订阅**（改名；但本页混入手动分组/策略组，需按 §3.1 拆分） |
| 3 | `route` | `nav_route` | **路由** | `arrow_up_left_and_arrow_down_right` | `activeTab=2` → `RouteRulesPanel`（`Index.ets:1717-1718`、`2530-2535`） | **分流**（改名；需并入分应用/策略组两子页签） |
| 4 | `settings` | `settings_title` | **设置** | `gearshape` | `activeTab=3` → `SettingsPage`（`Index.ets:1719-1720`、`2536-2544`） | **设置**（不变；需迁出分应用块） |
| 5 | `logs` | `logs` | **日志** | `doc_text` | `activeTab=4` → `LogPanel`（`Index.ets:1721-1722`、`2545-2550`） | **日志**（不变） |
| 6 | `tools` | `nav_tools` | **工具** | `wand_and_stars` | `activeTab=5` → `ToolsPage`（`Index.ets:1723-1724`、`2551-2556`） | **工具**（不变） |
| 7 | `about` | `nav_about` | **关于** | `info_circle` | `activeTab=6` → `AboutPage`（`Index.ets:1725-1726`、`2557-2563`） | **关于**（不变） |

### 2.2 抽屉框架其余可点/状态项

| 项 | 行为 | 证据 |
|---|---|---|
| 抽屉头部（应用图标＋名称＋版本行） | 纯展示；版本行恒为空（`appVersion` 声明后从未赋值，见 D13） | `Index.ets:1734-1753`、`124`、`1743` |
| 抽屉底注 `drawer_footer` | 纯文本 | `Index.ets:1794-1797` |
| 打开抽屉（顶栏 ☰） | `drawerEdge=handSide; drawerOpen=true` | `Index.ets:1831-1834`、`2359-2381` |
| 遮罩点击关闭 | `drawerOpen=false` | `Index.ets:1869-1871` |
| 面板空白点击 | 吞掉事件（防误关） | `Index.ets:1804-1806` |
| 智感握姿换手 | `onHandSideChanged` 平移面板 | `Index.ets:1842-1847` |
| 系统返回键 | 抽屉开→收；非节点页→回节点页；节点页→退桌面 | `Index.ets:194-205`（对应 PLAN §3.4 第一条，现状已符合） |

### 2.3 分组页现状 vs 新「订阅」页职责（PLAN §3.1 对照）

- 当前「分组」页 = **订阅管理 + 手动展示分组管理 + 策略组面板** 三合一：订阅卡（`GroupPage.ets:490-524`）、手动分组卡（`527-621`）、组设置面板含 `isSelector/frontProxy/landingProxy`（`553-614`，被 `ConfigBuilder.ets:850-880` 消费为 selector 出站与代理链）。
- 新「订阅」页按 PLAN §3.1 只含「订阅列表、导入、更新、流量/到期、详情」，**不含原始节点编辑表单、全局系统设置**；手动分组（展示分组）应迁到「节点」页浏览侧，策略组面板应迁到「分流→策略组」。
- 手动分组创建入口（输入框＋添加，`GroupPage.ets:463-486`）与新「订阅」页冲突：订阅 ≠ 展示分组（PLAN §3.2 术语字典），**「新建分组」不能代替「添加订阅」**——当前页头右侧动作恰是「更新全部订阅」，左侧却是新建展示分组，两类混排。

---

## 3. 各页顶栏与页内可点交互清单

### 3.0 共享壳层（7 页共有，13 项；不摊入各页）

骨架：`Index.build()` `Index.ets:2668-2724`——`Stack` → `HdsNavigation`（标题栏 `shellTitleBar()` `2599-2645`，渐变模糊＋沉浸光感）→ `activeContent()`（`2518-2564`）→ 条件 `statsBar()`（`2688-2690`）→ 条件 `fabLayer()`（`2712-2714`）→ `drawerOverlay()`（`2717`，最后兄弟，盖住标题栏）。**顶栏动作簇在全部 7 个分区都渲染**（`titleStackBuilder()` `2320-2355` 经 `shellTitleBar().content.stackBuilder` `2632-2634` 挂载）。

| # | 项 | 触发 | 实际行为/去向 | 判 | 证据 |
|---|---|---|---|---|---|
| S1 | ☰ 抽屉按钮 | `openDrawer()` | 开抽屉（不落库） | 保留 | `Index.ets:2359-2381`、`1831-1834` |
| S2 | 🔍 搜索图标（节点页时） | 内联 onTap | `searchVisible=true` + 120ms 后聚焦 `nodeSearchInput`；再点走 `closeNodeSearch()` | 保留 | `Index.ets:2387-2407`、`226-230` |
| S3 | 🔍 搜索图标（其余 6 页） | 同上 | `searchVisible=true` 但搜索行仅在 `activeTab===0` 渲染 ⇒ **无可见反应**，且状态泄漏（回节点页时搜索行突然展开） | **移除**（D1） | `Index.ets:2392-2397` + `2575-2579`、`2641` |
| S4 | ＋ 添加 | `addEntryDialog.open()` | 打开 5 入口弹窗（§3.1 表 #4） | 迁移（→节点页顶栏「添加节点/导入」，PLAN §3.3） | `Index.ets:2408-2415`、`1360-1380`、`2842-2916` |
| S5 | 🔗 连接图标 | `router.pushUrl('pages/ConnectionsPage')` | 真实路由；无 VPN 时该页显示「不可用」并停轮询 | 迁移（→节点页更多「连接列表」，PLAN §3.3/§10.1） | `Index.ets:2416-2422`、`ConnectionsPage.ets:113-123`、`222-246` |
| S6 | ⋮ 溢出菜单 | `openOverflowMenu()` | 系统菜单窗口，按 `value` 分发 10 项（测速中为 9 项），**作用域 = `selectedGroupId`（节点页残留状态）** | 迁移（按 PLAN §3.3 拆分到各页） | `Index.ets:2424-2444`、`2450-2478`、`2481-2514` |
| S7-S13 | 抽屉七项 | `onDrawerSelect` | 见 §2.1（4 保留 + 3 迁移） | — | `Index.ets:1760-1787`、`1711-1728` |

底栏速率条 `statsBar()`（`Index.ets:2179-2227`）：上行/下行等宽字体（2181-2186）、状态点＋状态文本（2188-2194）、半透明＋`backdropBlur(20)`（2211-2212，用户观感定稿）。点按→`runUrlTest(selectedProfile())`（2221-2226，需运行中＋选中）。显示条件 `isRunning && (activeTab===0 || settings.showBottomBar)`（2688）。

FAB `fabButton()`（`Index.ets:2235-2264`）：点按→`toggleVpn()`（2263）；连接中/切换中显示 LoadingProgress（2238-2240）；显示条件 `activeTab===0 || settings.showBottomBar`（2712）——**开启「其它分区保留底栏」后，非节点页也有可点 FAB 与速率条**，与 PLAN §3.1「工具页不含常用换节点操作」冲突（见 §7 R6）。

### 3.1 节点页（现「配置」，`activeTab===0`，42 项）

结构自上而下：HDS 顶栏（S1-S6）→ `titleBottomBuilder`（搜索行↔模式行＋分组条同一条带互换，恒 68vp，`Index.ets:2567-2588`、`2641`）→ 节点 `List`（`configFragment()` `2040-2094`，空态 2046-2060）→ `statsBar` → FAB → 抽屉。

**顶栏下部条带（搜索/模式/分组条，6 项）**

| # | 项 | 触发 | 去向/动作 | 判 | 证据 |
|---|---|---|---|---|---|
| N1 | 搜索输入框 `search_nodes` | `scheduleSearchFilter(v)` | 250ms 防抖写 `nodeSearch`；`visibleProfiles()` 按名称/服务器过滤 | 保留（PLAN §5.3 要求扩展地址/协议+范围提示） | `Index.ets:2017-2037`、`210-216`、`968-977` |
| N2 | 搜索行「取消」 | `closeNodeSearch()` | 清防抖＋清词＋收起 | 保留 | `Index.ets:2027-2031`、`226-230` |
| N3-N5 | 模式「规则/全局/直连」×3 | `switchOutboundMode(mode)` | `settings.mode` 改写＋`saveSettings` 落库；运行中→`VpnService.connect(id, true)` 强制重启 | 保留（PLAN §3.1「模式在节点页唯一提供主切换器」——现状已唯一，SettingsPage 的 switchMode 是死代码 D10） | `Index.ets:1880-1907`、`568-580` |
| N6 | 分组 chip 点选 | 内联 onTouch(Up) | 只写 `selectedGroupId`（内存**不落库**），刷新列表 | 保留（PLAN §3.4 要求记忆展示分组——现状重启即丢，见 §6） | `Index.ets:2148-2157` |
| N7 | 分组 chip 长按 | `bindContextMenu(groupContextMenu(groupId))` | 弹 6 项分组菜单（下 N8-N13）；触发器保留，菜单项按 N8-N13 判定 | 保留（触发器） | `Index.ets:2158-2164`、`1910-1925` |

**分组长按菜单（6 项，`groupContextMenu()` `Index.ets:1910-1925`）**

| # | 项 | 触发 | 去向/动作 | 判 | 证据 |
|---|---|---|---|---|---|
| N8 | TCPing | `runTcpTest(groupId)` | `runTestForGroup(g,'tcp')`→`canTCPing` 过滤→`testProfiles` 并发；`finally` 落库 | 合并（→「检测可用性」方式选择，PLAN §6.1） | `Index.ets:1912-1913`、`594-596`、`602-629`、`705-729` |
| N9 | URL Test | `runSpeedTest(groupId)` | 固定走 `urlTestProfiles`（内核 `CGoTest*` 临时实例）；内核起不来回退 TCPing 并 toast `speed_test_degraded` | 合并（同上） | `Index.ets:1914-1915`、`588-590`、`685-695` |
| N10 | 测速本组 | `runGroupSpeedTest(groupId)` | 方式跟随 `settings.latencyTestMode`（与 N8/N9 语义重复的第三入口） | 合并（同上） | `Index.ets:1916-1917`、`598-600` |
| N11 | 清除测试结果 | `clearTestResults(groupId)` | `status!=0` 归零＋`saveProfiles`＋`bumpResults` | 合并（→批量管理） | `Index.ets:1918-1919`、`748-766` |
| N12 | 去重 | `dedupGroup(groupId)` | 键 `server+serverPort+type`→确认框列前 20 名→删除＋`saveProfiles` | 合并（→批量管理） | `Index.ets:1920-1921`、`773-813` |
| N13 | 删除不可用 | `deleteUnavailable(groupId)` | `status∉{0,1}`→确认框→删除＋`saveProfiles` | 合并（→批量管理） | `Index.ets:1922-1923`、`817-838` |

**节点卡与节点长按菜单（17 项）**

| # | 项 | 触发 | 去向/动作 | 判 | 证据 |
|---|---|---|---|---|---|
| N14 | 节点卡点按 | `onNodeTap(p)` | 写 `selectedId`＋`selected_profile_id` 落库；未运行仅选中；运行中点他节点→`VpnService.switchTo()` 热切换（`switching` 防重入） | 保留（PLAN §4.4 浏览选择/热切换建模） | `Index.ets:2003`、`545-566` |
| N15 | 节点卡延迟文字 | `showTestError(p)` | 仅 `status===3`：AlertDialog 弹内核原文；其余 return | 保留 | `Index.ets:1950-1952`、`1148-1158` |
| N16 | 节点卡长按 | `bindContextMenu(profileContextMenu(p), LongPress)` | 弹 12 项菜单（N17-N28，毛玻璃背板） | 保留 | `Index.ets:2004-2011`、`1306-1340` |
| N17 | 固定/取消固定 | `togglePinned(p)` | 改 `pinned`＋`saveProfiles`；排序置顶 | 保留（PLAN §5.2 收藏/置顶迁移保留意图） | `Index.ets:1308-1309`、`1043-1047` |
| N18/N19 | 上移/下移（仅手动排序渲染） | `moveProfile(p,±1)` | 重排 `sortOrder`＋`saveProfiles` | 合并（→排序管理，PLAN §5.3） | `Index.ets:1310-1315`、`1025-1041` |
| N20 | URL Test（单节点） | `runUrlTest(p)` | 需**运行中且为当前运行节点**否则 toast；走 clash API `/proxies/.../delay`；**只改内存不落库**（注释明示），下次 `refresh()` 回退 | 合并（→「检测当前连接」，§10.4 语义）＋死路 D11 | `Index.ets:1316-1317`、`1163-1202`（`1176` 注释、`1177-1183` 仅内存） |
| N21 | 复制分享链接 | `copyProfileLink(p)` | `exportProfileLink`→剪贴板；协议不支持 toast | 保留 | `Index.ets:1318-1319`、`1258-1266` |
| N22 | 分享节点 | `openProfileShare(p)` | `generateBarcode.createBarcode` 二维码＋文本弹窗；失败降级 | 保留 | `Index.ets:1320-1321`、`1236-1256`、`2729-2775` |
| N23 | 导出发送配置 | `exportProfileConfig(p)` | `buildOutboundJson`→剪贴板 | 保留 | `Index.ets:1322-1323`、`1269-1277` |
| N24 | 导出到文件 | `exportProfileConfigFile(p)` | `DocumentViewPicker.save`＋`fs.writeSync`；取消/异常 toast | 保留 | `Index.ets:1324-1325`、`1280-1303` |
| N25 | 编辑节点 | `router.pushUrl('pages/ProfileEdit')`（`AppStorage.editProfileId=p.id`） | 真实路由（见 §6） | 保留 | `Index.ets:1326-1330` |
| N26 | 移动到分组 | `openMoveToGroup(p)` | 弹窗（未分组＋全部分组）→写 `p.groupId`＋`saveProfiles` | 保留（展示分组属节点页） | `Index.ets:1331-1332`、`1052-1074`、`2920-2981` |
| N27 | 查看订阅（仅 `subUrl` 非空渲染） | `router.pushUrl('pages/SubDetailPage',{url})` | 真实路由带参 | 迁移（→订阅页详情入口） | `Index.ets:1333-1336` |
| N28 | 删除（label「不可撤销」） | `deleteProfile(p)` | 确认框→过滤＋`saveProfiles`（**未 await**，无失败提示；未清 `selectedId`） | 保留（PLAN §5.2 要求补删除保护） | `Index.ets:1337-1338`、`1204-1218` |

**空态 / 底部 / ⋮（13 项）**

| # | 项 | 触发 | 去向/动作 | 判 | 证据 |
|---|---|---|---|---|---|
| N29 | 空态「导入订阅链接」 | `openImportDialog()` | 清输入＋读 `recent_subscription_group` 预填＋开弹窗 | 迁移（→订阅页/导入向导，PLAN §4.5） | `Index.ets:2052-2056`、`1557-1561` |
| N30 | 底部速率条点按 | 内联 onClick | `runUrlTest(selectedProfile())`（需运行中＋选中，否则静默） | 合并（与 N20 同一能力收敛） | `Index.ets:2221-2226` |
| N31 | FAB 连接/断开 | `toggleVpn()` | 运行→`disconnect`；未运行→`selectedProfile()` 空 toast，否则 `connectTo` | 保留 | `Index.ets:2263`、`531-542`、`509-521` |
| N32 | ⋮「更新当前订阅」 | `updateCurrentSubscription()` | 取选中节点 `subUrl`/`activeConfigUrl`；空 toast；`needDirectUpdateConfirm` 先确认；`updateSubscription`→`refresh`→差异弹窗 | 迁移（→订阅页「更新」） | `Index.ets:2459`、`2489`、`871-908` |
| N33 | ⋮「清除流量统计」 | `clearTrafficStatistics()` | 仅置 `AppStorage vpnTotalUp/Down=0`；**内核 `/connections` 无重置接口**，UI 1s 轮询（424-425/428）与扩展进程轮询随即写回 ⇒ 显示 ≤1s 复原 | **移除/重做**（D2；PLAN §10.4 改为扩展会话基准偏移） | `Index.ets:2460`、`2491`、`911-918`、`424-425`、`428`、`VpnExtAbility.ets:649-666`、`673` |
| N34 | ⋮「去重」 | `dedupGroup('__all__')` | **作用域硬编码全量**（与分组菜单传 `groupId` 不一致，注释标注由 Lead 统一改） | 合并（→批量管理，统一作用域） | `Index.ets:2461`、`2501-2503`（`2502` 注释） |
| N35/N36 | ⋮「TCPing / URL Test」 | `runTcpTest/runSpeedTest(selectedGroupId)` | 同 N8/N9，作用域=节点页残留的 `selectedGroupId` | 合并（→检测可用性） | `Index.ets:2469-2470`、`2492-2495` |
| N37 | ⋮「取消」（测速中替换 N35/N36） | `cancelSpeedTest()` | 置 `testCancelled=true`；停止取新节点，已测结果仍落库 | 保留 | `Index.ets:2462-2465`、`2496-2497`、`734-739` |
| N38 | ⋮「清除测试结果」 | `clearTestResults(selectedGroupId)` | 同 N11 | 合并（→批量管理） | `Index.ets:2472`、`2498-2500` |
| N39 | ⋮「删除不可用」 | `deleteUnavailable(selectedGroupId)` | 同 N13 | 合并（→批量管理） | `Index.ets:2473`、`2504-2505` |
| N40-N42 | ⋮「按手动/延迟/名称排序」×3 | `setSortMode(mode)` | `settings.profileSortMode`＋`saveSettings`＋重建列表（当前项带勾） | 合并（→一个排序入口含 3 模式，PLAN §5.3） | `Index.ets:2474-2476`、`2506-2511`、`840-844` |

### 3.2 订阅页（现「分组」，17 项）

结构：页头动作行（仅「更新全部订阅」`GroupPage.ets:451-461`，无标题栏——标题在壳层 HDS 顶栏）→ 新建分组行（463-486）→ `List`：订阅卡（490-524）→ 手动分组卡（527-621）→ 空态（623-630）。

| # | 项 | 触发 | 去向/动作 | 判 | 证据 |
|---|---|---|---|---|---|
| G1 | 更新全部订阅 `update_all_subs` | `updateAll()` | 串行 `updateSubscription`＋`markSubSuccess/Failure`；toast `sub_update_result(added,removed)`；**失败仅计数写日志**；结束 `refresh()`＋`onDataChanged()` | 保留（PLAN §11.1 要求逐订阅结果） | `GroupPage.ets:454-457`、`149-178`（`169-172`） |
| G2 | 新建分组输入框 | 内联 onChange | 只写 `newGroupName`（不落库） | 迁移（展示分组→节点页） | `GroupPage.ets:464-468` |
| G3 | 添加分组 `add_group` | `createGroup()` | 空名校验→新建 `ProfileGroup`（`grp_<ts>_<rand>`）→`saveGroups`→清输入 | 迁移（展示分组→节点页） | `GroupPage.ets:469-483`、`291-309` |
| G4 | 订阅卡「更新」 | `updateOne(sub)` | 互斥保护；`needDirectUpdateConfirm` 先确认；`updateSubscription`→`markSubSuccess`→差异反馈；异常 `markSubFailure`＋toast | 保留（→订阅页） | `GroupPage.ets:420-423`、`110-147` |
| G5 | 订阅卡「分享订阅链接」 | `shareSubLink(sub)` | URL 写剪贴板＋toast | 保留（→订阅页更多） | `GroupPage.ets:424-427`、`180-183` |
| G6 | 订阅卡「导出全部节点」 | `exportAllNodes(sub)` | 全节点 `exportProfileLink` 拼接写剪贴板；空 toast | 保留（→订阅页更多） | `GroupPage.ets:428-431`、`185-193` |
| G7 | 订阅卡「导出全部节点到文件」 | `exportAllNodesToFile(sub)` | `DocumentViewPicker.save`＋写 txt；取消/异常 toast | 保留（→订阅页更多） | `GroupPage.ets:432-435`、`196-223` |
| G8 | 订阅卡「清空分组」 | `clearSubProfiles(sub)` | 确认框→删该订阅节点＋`saveProfiles`（不动订阅记录） | 保留（→订阅页危险区） | `GroupPage.ets:436-439`、`254-270` |
| G9 | 订阅卡「删除」 | `deleteSub(sub)` | 确认框→`removeSub(url)`＋删节点＋`saveProfiles` | 保留（→订阅页危险区） | `GroupPage.ets:440-443`、`272-289` |
| G10 | 手动分组「分组设置」 | `openGroupSettings(group)` | 展开/收起面板，载入 `isSelector/frontProxy/landingProxy` | 迁移（策略组→分流页） | `GroupPage.ets:539-542`、`348-357` |
| G11 | 手动分组「清空分组」 | `clearGroupProfiles(id)` | 确认框→删组内节点＋`saveProfiles` | 迁移（展示分组→节点页） | `GroupPage.ets:543-546`、`236-252` |
| G12 | 手动分组「删除」 | `deleteGroup(group)` | 确认框→组内节点 `groupId=''`（不删节点）→`saveGroups` | 迁移（展示分组→节点页） | `GroupPage.ets:547-550`、`311-333` |
| G13 | 面板「使用选择器」Toggle | `settingsSelector` | 写 `group.isSelector`＋`saveGroups`（**onSelect 即写，非保存键**）；被配置生成器消费；仅运行节点属该组才立即 `switchTo` | 迁移（策略组→分流页） | `GroupPage.ets:561-562`、`360-386`、`ConfigBuilder.ets:850-880` |
| G14 | 面板「前置代理」Select | `settingsFront` | 写 `group.frontProxy`；`buildProfileGraph` `unshift` 进链 | 迁移（策略组→分流页） | `GroupPage.ets:566-571`、`ConfigBuilder.ets:763-775` |
| G15 | 面板「落地代理」Select | `settingsLanding` | 写 `group.landingProxy`；`push` 进链 | 迁移（策略组→分流页） | `GroupPage.ets:573-579`、`ConfigBuilder.ets:772-774` |
| G16 | 面板「取消」 | 内联 | `settingsGroupId=''` 收起（丢弃未保存改动） | 迁移（策略组→分流页） | `GroupPage.ets:582-595` |
| G17 | 面板「保存」 | `saveGroupSettings()` | 三字段写回＋`saveGroups`＋toast＋条件重载 VPN＋`refresh` | 迁移（策略组→分流页） | `GroupPage.ets:596-608`、`360-386` |

> 订阅页已知缺失（事实，非判定）：无测速入口（全文件无 `LatencyTester` import，`GroupPage.ets:1-15`）；无「移动分组」；**无重命名分组 UI**（`renameGroup()` 死代码 D9）；订阅分组不出现在本页列表（`manualGroups()` 过滤 `!fromSubscription`，`GroupPage.ets:66-68`）；`autoSelect`（urltest）无 UI 开关，仅订阅解析写入（`core/Subscriptions.ets:902-903`）；**订阅卡主体不可点进详情**——SubDetailPage 只能从节点长按进入（§6 风险）。

### 3.3 分流页（现「路由」，35 项）

结构：页头动作行「新增＋重置」（`RouteRulesPage.ets:399-427`）→ 加载/错误/空态（430-478）→「远程规则集」区（480-644）→ 自定义规则 `List`（646-717）→ 顺序提示（719-720）。持久化：全部编辑仅改内存＋`persist()` 1s 防抖写 `route_rules`（`50-58`、`60-68`）；离开页面补写（`70-81`）。

**页头与远程规则集（16 项）**

| # | 项 | 触发 | 去向/动作 | 判 | 证据 |
|---|---|---|---|---|---|
| R1 | 新增规则 `add` | `addRule()` | push `new RouteRule()`（默认 `outbound='proxy'`）＋防抖落盘 | 保留 | `RouteRulesPage.ets:404-414`、`148-153` |
| R2 | 重置 `route_reset` | `resetRules()` | 空则 toast；确认框→清空两套数组＋**立即**落盘＋toast | 保留 | `RouteRulesPage.ets:415-426`、`173-193` |
| R3 | 重新加载 `reload`（仅错误态渲染） | `load()` | 重读 profiles/rules/remoteSets | 保留 | `RouteRulesPage.ets:451-462`、`33-45` |
| R4 | 新增远程规则集 | `addRemoteRuleSet()` | push 空 `RemoteRuleSet`（`type='site'`、`outbound='direct'`）＋防抖落盘 | 保留（→分流-规则集） | `RouteRulesPage.ets:486-496`、`83-90` |
| R5 | 规则集名称输入 | `updateRemoteRuleSet(i,'name',v)` | 只写 `item.name`；生成器用 `id` 作 tag **不读 name** | 保留（仅显示名） | `RouteRulesPage.ets:503-505`、`95-96`、`ConfigBuilder.ets:1172` |
| R6 | 规则集 URL 输入 | `updateRemoteRuleSet(i,'url',v)` | 写 `item.url`；生成 `route.rule_set`（`type=remote`、`format=binary`、`download_detour` 直连、`update_interval=24h`）；URL 空整条跳过 | 保留（PLAN §7.5 要求改为应用管理下载＋验证） | `RouteRulesPage.ets:554-556`、`97-98`、`ConfigBuilder.ets:1158-1169` |
| R7/R8 | 规则集 ↑/↓ | `moveRemoteRuleSet(i,±1)` | 交换元素＋防抖落盘；首/末项图标置灰但**仍可点**（函数内越界 return） | 保留 | `RouteRulesPage.ets:509-548`、`121-132` |
| R9 | 规则集启用 Toggle | `updateRemoteRuleSet(i,'enabled',v)` | 写 `item.enabled`；生成器只处理 `enabled===true` | 保留 | `RouteRulesPage.ets:549-550`、`103-104`、`ConfigBuilder.ets:1159` |
| R10 | 规则集类型「站点」 | `updateRemoteRuleSet(i,'type','site')` | 写 `item.type`；**生成器不读 type**（站点/IP 都写同一份 `format=binary`）⇒ 无配置效果，仅影响回显 | **移除**（D6；PLAN §7.5 由 format/source 字段替代） | `RouteRulesPage.ets:559-571`、`99-100`、`ConfigBuilder.ets:1162-1169` |
| R11 | 规则集类型「IP」 | 同上 `'ip'` | 同上 | **移除**（D6） | `RouteRulesPage.ets:572-584` |
| R12/R13 | 规则集出站「直连/代理」 | `updateRemoteRuleSet(i,'outbound',…)` | 写 `item.outbound`；写入引用规则 `outbound` | 保留 | `RouteRulesPage.ets:588-614`、`101-102`、`ConfigBuilder.ets:1171-1174` |
| R14 | 规则集「删除」 | `removeRemoteRuleSet(i)` | `splice`＋防抖落盘（**无确认框**） | 保留（PLAN §7.5 要求危险保护） | `RouteRulesPage.ets:630-634`、`113-118` |
| R15 | 规则集「更新时间」文本 | 只读 | 显示 `item.updatedAt`；唯一写入点是用户编辑 ⇒ 语义是「最后编辑时间」，非下载时间 | 保留（PLAN §7.5 要求改为 `lastSuccessfulDownloadAt`） | `RouteRulesPage.ets:618-623`、`106` |
| R16 | 规则集「错误」文本 | 只读 | `lastError` 仅编辑时被清空（`107`），**全仓无写入点** ⇒ 永不显示 | 保留（PLAN §7.5 要求接真实下载失败） | `RouteRulesPage.ets:624-629`、`107` |

**自定义规则卡（19 项；多字段匹配表单 `ruleMatchSection()` `RouteRulesPage.ets:238-370`）**

| # | 项 | 触发 | 去向/动作 | 判 | 证据 |
|---|---|---|---|---|---|
| R17 | 规则备注输入 | `updateRule(i,'remark',v)` | 写 `rule.remark`（不进内核） | 保留 | `RouteRulesPage.ets:651-653`、`198-199` |
| R18/R19 | 规则 ↑/↓ | `moveRule(i,±1)` | 交换顺序（顺序即优先级）＋防抖落盘 | 保留（PLAN §7.2 要求显式上下移——现状符合） | `RouteRulesPage.ets:656-695`、`135-146` |
| R20 | 规则启用 Toggle | `updateRule(i,'enabled',v)` | 写 `rule.enabled`；生成器跳过 `!enabled` | 保留 | `RouteRulesPage.ets:696-697`、`200-201`、`ConfigBuilder.ets:1111` |
| R21 | 域名 `route_rule_domains` | `updateRule(i,'domains',v)` | 解析 `full:/domain:/regexp:/keyword:/geosite:` 前缀与裸值 | 保留 | `RouteRulesPage.ets:241-244`、`208-209`、`ConfigBuilder.ets:462-495` |
| R22 | 目的 IP `route_rule_ip` | `updateRule(i,'ip',v)` | `geoip:private`→`ip_is_private`、`geoip:x`→rule_set、其余→`ip_cidr` | 保留 | `RouteRulesPage.ets:249-252`、`210-211`、`ConfigBuilder.ets:497-519` |
| R23 | 目的端口 | `updateRule(i,'port',v)` | 单值与 `1000:2000` 区间 | 保留 | `RouteRulesPage.ets:255-258`、`212-213`、`ConfigBuilder.ets:521-523` |
| R24 | 源 IP | `updateRule(i,'source',v)` | →`source_ip_cidr` | 保留 | `RouteRulesPage.ets:264-267`、`214-215` |
| R25 | 源端口 | `updateRule(i,'sourcePort',v)` | →`source_port` | 保留 | `RouteRulesPage.ets:270-273`、`216-217` |
| R26 | 网络下拉（任意/TCP/UDP） | `updateRule(i,'network',…)` | →`network`；下拉值已预取纯文本防 `[object Object]`（`18-29` 注释） | 保留 | `RouteRulesPage.ets:279-290`、`218-219` |
| R27 | 协议 | `updateRule(i,'protocol',v)` | 逗号/换行拆数组 | 保留 | `RouteRulesPage.ets:292-296`、`220-221` |
| R28 | 应用包名 `route_rule_packages` | `updateRule(i,'packages',v)` | 写字段；生成器要求 `packagesEnabled===true` 才写 `process_name`；**UI 无此勾选框**，新建默认 `false` ⇒ 本次会话填了不生效；仅载入迁移补 true（需重进页面） | 迁移（PLAN §8.5 入口收口→分应用入口＋平台限制说明；现已有警告文案 `304-305`） | `RouteRulesPage.ets:299-306`、`222-223`、`ConfigBuilder.ets:548`、`model/RouteRule.ets:24`、`129-130` |
| R29 | 自定义配置 JSON | `updateRule(i,'config',v)` | `parseUserJson`＋`deepMerge`（非法 JSON 忽略） | 保留（PLAN §7.3 高级编辑器） | `RouteRulesPage.ets:308-313`、`224-225`、`ConfigBuilder.ets:553-558` |
| R30-R32 | 出站「代理/直连/拒绝」×3 | `updateRule(i,'outbound',…)` | 写 `outbound`；拒绝生成 `action:reject` | 保留 | `RouteRulesPage.ets:315-331`、`206-207`、`ConfigBuilder.ets:562-566`、`1124-1126` |
| R33 | 出站「指定节点」按钮 | 内联 | 已指定→回 `proxy`；无节点 toast `route_no_profiles`；否则写 `profile:<profiles[0].id>`（**默认取第一个节点**） | 保留 | `RouteRulesPage.ets:333-355` |
| R34 | 指定节点下拉 | `updateRule(i,'outbound','profile:<id>')` | 首项「代理」=取消指定；id 失效显示 `route_rule_profile_missing` | 保留 | `RouteRulesPage.ets:358-368`、`373-394` |
| R35 | 规则「删除」 | `removeRule(i)` | 确认框→splice＋防抖落盘 | 保留 | `RouteRulesPage.ets:703-704`、`155-170` |

> 路由页关键事实：① **无导入/导出**（备份/恢复只在工具页，全量备份含 `routeRules/remoteRuleSets`，`core/Backup.ets`）；② **改动不触发重连**（`persist()` 只写 Preferences，规则生效时机=下次连接）；③ **仅规则模式注入**（customRules 与远程规则集循环都在 `if (s.mode === 'rule')` 内，`ConfigBuilder.ets:1105` ⇒ 全局/直连模式规则静默不生效，UI 无提示）；④ 非 cn 的 geosite/geoip 引用会让整次连接失败（`ConfigBuilder.ets:1177-1196` throw）；⑤ 规则卡 ForEach key 含 `index/type/outbound/…`（`RouteRulesPage.ets:711-712`）；⑥ **无手动更新规则集入口**（下载由内核按 24h 自行完成，ArkTS 侧无下载/失败回报路径）。

### 3.4 设置页（70 项；7 个可折叠章节 `sectionHeader()` `SettingsPage.ets:411-443`）

结构：页头动作行（仅「保存」，`enabled(this.dirty)`，`SettingsPage.ets:445-467`）→ `Scroll` 内 7 章节：常规（511）、路由（655）、DNS（844）、入站（934）、外观与交互（968）、Clash API（1074）、分应用代理（1119）；加载/失败态带「重新加载」（470-506）。
**生效模型**：所有开关只写 `this.s`＋`markDirty()`；「保存」→`save(quiet)` `229-242`（落库＋回调＋toast `saved_reconnect_vpn`，无自动重连）；例外四处：分应用模式（1136-1146 自动 `switchTo`）、分应用条目勾选/增删（`persistPerApp` 274-291）、主题外观（`applyAppearance` 200-223 立即 `setColorMode`＋落盘）。

| # | 项（章节） | 控件 | 写入字段/动作 | 判 | 证据 |
|---|---|---|---|---|---|
| S-1 | 保存按钮 | Button（dirty 才可点） | `save()` → `saveSettings` | 保留 | `SettingsPage.ets:451-466`、`229-242` |
| S-2~S-8 | 7 个章节头 | Row onClick(onToggle) | 展开/收起（分应用章节头随块迁移） | 保留×6 + 迁移×1 | `SettingsPage.ets:511,655,844,934,968,1074,1119`、`409-443` |
| S-9 | 自动连接 | Toggle | `autoConnect`（启动时 `Index.autoConnect()` 消费） | 保留 | `SettingsPage.ets:519-523`、`Index.ets:373-389` |
| S-10 | 日志级别 | Select | `logLevel`（→内核 `log.level`） | 保留 | `SettingsPage.ets:528-534`、`ConfigBuilder.ets:1251`、`Store.ets:199-202` |
| S-11 | 测速方式 | Select（url/tcp） | `latencyTestMode`；**只被节点页分组菜单「测速本组」消费**（N10） | 保留（PLAN §6.1 检测参数归设置） | `SettingsPage.ets:539-545`、`Index.ets:598-600` |
| S-12 | 测速网址 | TextInput | `testUrl`（LatencyTester/urltest 出站/clash 单节点测速消费） | 保留 | `SettingsPage.ets:552-557`、`LatencyTester.ets:344`、`ConfigBuilder.ets:863`、`Index.ets:1174-1175` |
| S-13 | 测速并发 | TextInput | `testConcurrent`（钳 1..32） | 保留 | `SettingsPage.ets:564-572`、`Store.ets:223-225` |
| S-14 | 全局自定义配置 | TextArea | `globalCustomConfig`（与根对象浅合并） | 保留 | `SettingsPage.ets:577-585`、`ConfigBuilder.ets:1268` |
| S-15 | 始终显示地址 | Toggle | `alwaysShowAddress`（节点卡第二行） | 保留 | `SettingsPage.ets:592-596`、`Index.ets:1964-1970` |
| S-16 | 其它分区保留底栏 | Toggle | `showBottomBar`（statsBar/FAB 显示条件） | 保留（与 PLAN §3.1「工具页不含换节点」存在张力，见 §7 R6） | `SettingsPage.ets:601-605`、`Index.ets:2688`、`2712` |
| S-17 | 速率刷新间隔 | TextInput | `speedIntervalMs`；**只影响常驻通知轮询**（500..10000ms 兜底）；首页速率条固定 1000ms | 保留（PLAN §10.4 改为扩展会话基准后重述） | `SettingsPage.ets:616-622`、`VpnExtAbility.ets:671-673`、`Index.ets:428` |
| S-18/S-19 | 全局/订阅放行不安全 TLS | Toggle ×2 | `allowInsecureAll`/`subAllowInsecure` | 保留 | `SettingsPage.ets:630-634`、`642-646`、`ConfigBuilder.ets:71`、`Index.ets:1611` |
| S-20 | （已移除）通知显示分组名 | — | 注释保留（`notificationGroup` 字段仅为旧备份兼容） | 已移除（本轮计数 −1 的原因） | `SettingsPage.ets:608-609` |
| S-21/S-22 | 直连域名后缀/直连 IP 段 | TextInput ×2 | `directDomains`/`directIpCidrs`；仅 `mode==='rule'` 生成 `domain_suffix/ip_cidr→direct`（UI 也仅 rule 显示） | 迁移（合并进分流-域名/IP规则，PLAN §3.1） | `SettingsPage.ets:660-673`、`ConfigBuilder.ets:1131`、`1138` |
| S-23 | 下载 Geo 数据 | Button | `downloadGeoAssets()`（`utils/GeoAssets.ets`） | 迁移（→分流-规则集，PLAN §7.5） | `SettingsPage.ets:678-689`、`105-122` |
| S-24 | 导入 Geo 数据库 | Button | `importGeoAssetFromFile()`；取消返回 null 不报错 | 迁移（→分流-规则集） | `SettingsPage.ets:694-707`、`169-189` |
| S-25/S-26 | 单库更新/单库删除（每资产行） | Button ×2 | `downloadGeoAsset(kind)` / 确认框→`deleteGeoAsset(kind)` | 迁移（→分流-规则集） | `SettingsPage.ets:719-748`、`125-166` |
| S-27 | TUN MTU | TextInput | `mtu`；**载入时钳 1280..1500**（`Store.ets:190`），与 placeholder `9000` 不一致 ⇒ 填大值静默变 1500 | 保留 | `SettingsPage.ets:759-765`、`Store.ets:190`、`ConfigBuilder.ets:825` |
| S-28 | TUN 栈 | Select | `stack`；**选项只有 `'system'` 一项**（`SettingsPage.ets:22`） | 保留（PLAN §12.4：不可用 TUN 栈不提供无效可选值） | `SettingsPage.ets:770-776`、`ConfigBuilder.ets:828` |
| S-29 | IPv6 模式 | Select（四档） | `ipv6Mode` | 保留 | `SettingsPage.ets:781-787`、`ConfigBuilder.ets:813-824`、`Store.ets:208` |
| S-30 | 绕过局域网 | Toggle | `bypassLan`（`ip_is_private→direct`） | 保留 | `SettingsPage.ets:795-799`、`ConfigBuilder.ets:1090-1095` |
| S-31~S-33 | 嗅探 关/路由/覆写 ×3 | Button ×3 | `sniffMode`（off 不生成 / `action:sniff` / ＋`override_destination`，依赖内核补丁 6） | 保留 | `SettingsPage.ets:806-822`、`ConfigBuilder.ets:1056`、`1062-1065` |
| S-34 | 解析目标地址 | Toggle | `resolveDestination`（`action:resolve`） | 保留 | `SettingsPage.ets:832-836`、`ConfigBuilder.ets:1076-1081` |
| S-35~S-39 | 远程/直连 DNS、三个策略 Select ×5 | TextInput/Select | `remoteDns/remoteDnsStrategy/directDns/directDnsStrategy/serverDnsStrategy` | 保留 | `SettingsPage.ets:849-901` |
| S-40 | DNS 路由 | Toggle | `dnsRouting`（CN 域名走直连 DNS，需 rule 模式＋geo 库） | 保留 | `SettingsPage.ets:909-913`、`ConfigBuilder.ets:938`、`1033` |
| S-41 | FakeDNS | Toggle | `fakeDns`（fakeip server＋规则） | 保留 | `SettingsPage.ets:921-925`、`ConfigBuilder.ets:921,1004,1018` |
| S-42/S-43 | 混合端口/允许局域网访问 | TextInput/Toggle | `mixedPort`（0=关，钳 1024..65535）/`allowAccess`（listen `0.0.0.0`） | 保留 | `SettingsPage.ets:939-945`、`953-957`、`ConfigBuilder.ets:832-838` |
| S-44~S-46 | 外观 跟随系统/浅色/深色 ×3 | Button ×3 | `applyAppearance()`：**立即落盘＋`setColorMode`**（唯一即时生效类） | 保留 | `SettingsPage.ets:972-990`、`200-223` |
| S-47~S-49 | 排序 手动/延迟/名称 ×3 | Button ×3 | `profileSortMode`（节点列表排序＋上移/下移显示条件） | 合并（→节点页排序入口） | `SettingsPage.ets:994-1011`、`Index.ets:840-844` |
| S-50 | 触感反馈 | Toggle | `hapticFeedback`；**全仓无消费方**（grep 无 vibrator 调用） | **移除**（D4；PLAN §12.4「每个开关必须列出消费方」） | `SettingsPage.ets:1013-1020`（grep 复核为空） |
| S-51 | 液态玻璃 | Toggle | `liquidGlass`；**全仓无消费方**，不影响任何材质 | **移除**（D5） | `SettingsPage.ets:1021-1028`（grep 复核为空） |
| S-52 | 网络变化重置连接 | Toggle | `networkChangeResetConnections`；扩展进程 true 时重建连接（15s 合并窗口）；但 `Store.loadSettings` 首次迁移**强制写回 false**，恢复出厂后再跑一次 | 保留 | `SettingsPage.ets:1035-1039`、`VpnExtAbility.ets:139-203`、`Store.ets:277-285` |
| S-53 | 唤醒后重置连接 | Toggle | `wakeResetConnections`（扩展前台事件） | 保留 | `SettingsPage.ets:1047-1051`、`VpnExtAbility.ets:251-290` |
| S-54 | 节点流量统计 | Toggle | `profileTrafficStatistics`（节点卡 rx/tx；会话结束累加落库） | 保留 | `SettingsPage.ets:1059-1063`、`Index.ets:1975-1981`、`VpnExtAbility.ets:696-719` |
| S-55~S-57 | Clash API 开关/端口/密钥 | Toggle/TextInput×2 | `clashApiEnabled/clashApiPort/clashApiSecret`（9090→19290 一次性迁移、空密钥自动生成） | 保留 | `SettingsPage.ets:1079-1108`、`Store.ets:262-266`、`279-281`、`ConfigBuilder.ets:1233-1238` |
| S-58~S-60 | 分应用 关/排除/仅代理 ×3 | Button ×3 | `perAppMode`；**onClick 即 `save(true)`＋运行中自动 `switchTo` 重连** | 迁移（→分流-分应用） | `SettingsPage.ets:1123-1147` |
| S-61 | 分应用搜索框 | TextInput | `appSearch`（仅本地过滤） | 迁移（→分流-分应用） | `SettingsPage.ets:1157-1159`、`302-309` |
| S-62 | 添加/批量导入按钮 | Button | `openPerAppDialog()` | 迁移（→分流-分应用） | `SettingsPage.ets:1160-1172`、`349-354` |
| S-63 | 条目复选框（每条目） | Toggle.Checkbox | `togglePerAppEntry`→`persistPerApp`（落库＋运行中重连） | 迁移（→分流-分应用） | `SettingsPage.ets:1215-1219`、`319-322`、`274-291` |
| S-64 | 条目「移除」（每条目） | Text onClick | 确认框→`removeEntry`＋`persistPerApp` | 迁移（→分流-分应用） | `SettingsPage.ets:1210-1213`、`324-337` |
| S-65 | 清除选择 | Button | 全条目置未勾选（保留条目）＋落库＋重连 | 迁移（→分流-分应用） | `SettingsPage.ets:1229-1242`、`340-347` |
| S-66 | 从剪贴板导入 | Button | 解析 `"false\n<包名>"` 合并＋落库＋重连；格式不符 toast | 迁移（→分流-分应用） | `SettingsPage.ets:1243-1255`、`397-407` |
| S-67 | 导出到剪贴板 | Button | 生成 `"false\n<pkgs>"` 写剪贴板 | 迁移（→分流-分应用） | `SettingsPage.ets:1259-1272`、`383-391` |
| S-68 | 弹窗「名称备注」输入 | TextInput | `perAppDialogLabel`（只作显示名，不参与系统名单） | 迁移（→分流-分应用） | `SettingsPage.ets:1321-1324`、`1302-1360` |
| S-69 | 弹窗「包名」文本域 | TextArea | 逐行/逗号解析，非法包名单独计数 | 迁移（→分流-分应用） | `SettingsPage.ets:1325-1333` |
| S-70 | 弹窗「取消/确认」×2 | Button ×2 | `controller.close()` / `confirmPerAppDialog()`（空/全非法分别报错→`mergeEntries`→toast→`persistPerApp`） | 迁移（→分流-分应用） | `SettingsPage.ets:1341-1354`、`357-377` |

> 设置页死代码（事实）：`switchMode()`（244-265）、`modeIndex()`（191-194）、`MODES/MODE_LABELS/MODE_SWITCH_TOASTS`（23-25）**无任何组件引用**——出站模式只能在节点页切换（D10）；`isEntrySelected()`（311-317）无调用方（D14）。

### 3.5 日志页（8 项）

结构：工具行「导出/清空」（`LogPage.ets:139-171`）→ 搜索框（173-178）→ 级别按钮行 ALL/ERROR/WARN/INFO/DEBUG（180-198）→ 日志 `List`（超 2000 行截断，51-59、200-219）。数据两条：进程内 `LogStore`（内存环 2000 行，`Store.ets:394-446`）＋内核日志文件每秒 tail（`99-135`、`38-40`；每次连接开始文件被清空重建，`VpnExtAbility.ets:530`）。

| # | 项 | 触发 | 去向/动作 | 判 | 证据 |
|---|---|---|---|---|---|
| L1 | 导出 `log_export` | `exportLogs()` | 取**当前过滤后**文本→`DocumentViewPicker.save`→写文件；空 toast | 保留（PLAN §10.4 默认当前过滤范围） | `LogPage.ets:144-154`、`71-96` |
| L2 | 清空 `log_clear` | 内联 onClick | `LogStore.clear()`＋`lines=[]`＋**`fileOffset=0`** ⇒ 1s 后 tail 从头重读当前 `singbox.log`，已清的内核日志重新出现 | **移除/重做**（D3；PLAN §10.4 记录偏移＋文件身份） | `LogPage.ets:165-169`、`99-135`（`107-108` 截断归零） |
| L3 | 搜索框 | onChange | `searchText`；大小写不敏感子串过滤（无防抖） | 保留 | `LogPage.ets:173-178`、`61-69` |
| L4-L8 | 级别 ALL/ERROR/WARN/INFO/DEBUG ×5 | Button onClick | `levelFilter=level`；按**整行包含级别词**匹配 ⇒ `[ui]/[vpn]` 应用行不含级别词会被整体滤掉 | 合并（→「错误级别过滤」更多菜单，PLAN §3.3；匹配逻辑改结构化字段 §10.4） | `LogPage.ets:181-195`、`61-69` |

> 本页无「查看连接」入口（PLAN §10.1 要求日志页可进连接列表——缺失）；无按 sessionId 定位（§6）。

### 3.6 工具页（7 项）

结构：3 张卡片——STUN（`ToolsPage.ets:257-311`）、备份与恢复（313-407）、恢复出厂（409-433），整页 `Scroll`；无页头动作行（252 注释）。

| # | 项 | 触发 | 去向/动作 | 判 | 证据 |
|---|---|---|---|---|---|
| T1 | STUN 服务器输入 | onChange | 只写 `stunServer`（默认 `stun.cloudflare.com:3478`，不落库） | 保留 | `ToolsPage.ets:263-265` |
| T2 | STUN 测试 | `runStun()`→`stunTest(server)` | 真 UDP RFC5389 Binding Request 两次探测判 NAT 类型；超时/解析失败 `stun_failed` | 保留（PLAN §3.1 工具页含 STUN） | `ToolsPage.ets:266-280`、`194-209`、`utils/StunTester.ets:104-161` |
| T3 | 导出备份文件 | `exportBackupFile()` | `exportBackup()`（settings/profiles/groups/subscriptions/routeRules/remoteRuleSets）→保存 JSON；忙碌互斥 | 保留 | `ToolsPage.ets:320-334`、`142-166`、`core/Backup.ets:237-251` |
| T4 | 从文件恢复 | `importBackupFile()`→`restoreText()` | 先 `prepareForRestore()`（VPN 活跃则断开＋**轮询等 15s**）；再 `importBackup`（校验→全量写→失败全量回滚）；文件空/超 20MB/读不全报错 | 保留 | `ToolsPage.ets:335-349`、`168-192`、`83-102`、`core/Backup.ets:254-298` |
| T5 | 备份到剪贴板 | 内联 async | `exportBackup`→`pasteboard.setData`；异常 toast | 保留 | `ToolsPage.ets:352-374` |
| T6 | 从剪贴板恢复 | 内联 async | 读剪贴板→空 toast→`restoreText()`→摘要 toast（含「已断开 VPN」分支） | 保留 | `ToolsPage.ets:375-400`、`37-43` |
| T7 | 恢复出厂 | `requestReset()`→**两次确认**→`doReset()` | `resetAllData()`＝`pref.clear()`（清全部 Preferences：节点/分组/设置/订阅/规则）；**不停 VPN、不重置 AppStorage、不刷新已加载列表** | 保留（PLAN §12.4 要求移到工具深层页＋先导出备份） | `ToolsPage.ets:415-427`、`211-248`、`Store.ets:333-337` |

### 3.7 关于页（3 项）

结构：单卡（应用名＋应用版本＋内核版本两个只读 `InfoRow`＋三按钮，`AboutPage.ets:98-153`）→ 开源许可文本卡（155-165）。无页头动作行（94 注释）。

| # | 项 | 触发 | 去向/动作 | 判 | 证据 |
|---|---|---|---|---|---|
| A1 | 检查更新 | `checkUpdate()` | 真 HTTP GET GitHub releases/latest（10s/15s 超时）→比对 `versionName`；有新版**自动打开 GitHub 页** | 保留（PLAN §3.1 关于页含更新） | `AboutPage.ets:104-118`、`52-90` |
| A2 | 项目主页 | `openGitHub()`→`openLink()` | `context.openLink(GITHUB_URL)`；无处理器时 toast 供复制 | 保留 | `AboutPage.ets:119-132`、`35-50`、`9` |
| A3 | Telegram | `openTelegram()` | 同上（`t.me/...`） | 保留 | `AboutPage.ets:133-146`、`10` |

> 关于页事实：内核版本为**硬编码常量** `sing-box 1.14.0 (OHOS c-shared)`（`AboutPage.ets:8`、`102`），不查询运行中 `.so` 真实版本——`CGoSingBoxVersion` 导出存在但本页未调用；与 PLAN §3.1「应用与**真实**内核版本」不符（§7 R8）。

---

## 4. 旧入口 → 新方案去向映射（保留/迁移/合并/移除）

**判定口径**：`保留`＝同一能力留在同名/同职责页面（UI 可重做但入口不搬家）；`迁移`＝入口换页（含抽屉改名导致的标题/文案迁移）；`合并`＝多个旧入口收敛为一个新入口；`移除`＝无消费方/死路/被新方案替代。

### 4.1 抽屉七项（PLAN §3.1/REQ-01）

| 旧（现文案） | 新 | 判定 | 说明 |
|---|---|---|---|
| 配置 | 节点 | 迁移（改名） | 顺序/框架保留；页面职责按 §3.1 收拢 |
| 分组 | 订阅 | 迁移（改名＋拆分） | 订阅卡/更新/导入留下；手动分组与策略组迁出（§4.2） |
| 路由 | 分流 | 迁移（改名＋并入） | 现有规则/规则集留下；分应用、策略组两子页签迁入 |
| 设置 | 设置 | 保留 | 需迁出分应用块（§4.2） |
| 日志 | 日志 | 保留 | — |
| 工具 | 工具 | 保留 | — |
| 关于 | 关于 | 保留 | — |

### 4.2 变更项明细（42 迁移 + 26 合并 + 6 移除；保留 121 项不逐条列出，见 §3 各表「判」列）

**迁移（42）**

| 旧入口 | 旧位置 | 新去向 | 依据 |
|---|---|---|---|
| 抽屉「配置/分组/路由」×3 | `Index.ets:56-65` | 节点/订阅/分流（改名） | PLAN §3、REQ-01 |
| 壳层 ＋ 添加 | `Index.ets:2408-2415` | 节点页顶栏「添加节点/导入」 | PLAN §3.3 |
| 壳层 🔗 连接图标 | `Index.ets:2416-2422` | 节点页更多「连接列表」＋首页状态区＋日志页入口 | PLAN §3.3、§10.1 |
| 壳层 ⋮ 溢出菜单 | `Index.ets:2424-2444` | 拆分：订阅更新→订阅页；测速/批量/排序→节点页 | PLAN §3.3 |
| 空态「导入订阅链接」N29 | `Index.ets:2052-2056` | 订阅页导入/首用向导 | PLAN §4.5 |
| 节点长按「查看订阅」N27 | `Index.ets:1333-1336` | 订阅页详情入口（不再藏在节点菜单） | PLAN §11.1 |
| ⋮「更新当前订阅」N32 | `Index.ets:2459` | 订阅页「更新」 | PLAN §11.1 |
| 新建分组输入框＋按钮 G2/G3 | `GroupPage.ets:463-486` | 节点页（展示分组管理） | PLAN §3.2（订阅≠展示分组） |
| 手动分组「分组设置」G10 | `GroupPage.ets:539-542` | 分流→策略组 | PLAN §9.1 |
| 手动分组「清空/删除」G11/G12 | `GroupPage.ets:543-550` | 节点页（展示分组管理） | PLAN §3.2 |
| 面板「使用选择器/前置/落地/取消/保存」G13-G17 | `GroupPage.ets:553-614` | 分流→策略组 | PLAN §9.1-9.4 |
| 路由页「应用包名」R28 | `RouteRulesPage.ets:299-306` | 分应用入口＋平台限制说明（保留旧数据原文） | PLAN §8.5 |
| 设置「直连域名后缀/直连 IP 段」S-21/S-22 | `SettingsPage.ets:660-673` | 分流-域名/IP规则（避免第二套编辑器） | PLAN §3.1 |
| 设置「Geo 下载/导入/单库更新/单库删除」S-23~S-26 | `SettingsPage.ets:678-748` | 分流-规则集 | PLAN §7.5 |
| 分应用章节头＋模式×3＋搜索＋添加 S-58~S-62 | `SettingsPage.ets:1119-1172` | 分流-分应用（旧设置位置保留说明＋跳转过渡一版） | PLAN §3.1、§8.1、§3.1 注（100 行） |
| 分应用条目勾选/移除/清除/导入/导出 S-63~S-67 | `SettingsPage.ets:1210-1272` | 分流-分应用 | PLAN §8 |
| 分应用弹窗 4 项 S-68~S-70 | `SettingsPage.ets:1302-1360` | 分流-分应用 | PLAN §8 |
| 日志「清空」L2 | `LogPage.ets:165-169` | 重做为「清空当前日志视图」（记录偏移） | PLAN §10.4 |

**合并（26）**

| 旧入口（多） | 旧位置 | 新入口（一） | 依据 |
|---|---|---|---|
| 分组菜单 TCPing / URL Test / 测速本组 N8-N10 | `Index.ets:1912-1917` | 「检测可用性」（HTTP/TCPing 方式选择） | PLAN §6.1（三入口语义重复） |
| ⋮ TCPing / URL Test N35/N36 | `Index.ets:2469-2470` | 同上 | 同上 |
| 节点长按 URL Test N20＋速率条点按 N30 | `Index.ets:1316`、`2221-2226` | 「检测当前连接」（次操作） | PLAN §4.3-4、§6.1 |
| 清除测试结果 ×2（N11/N38）、去重 ×2（N12/N34）、删除不可用 ×2（N13/N39） | `Index.ets:1918-1923`、`2461-2473` | 批量管理（统一作用域提示） | PLAN §5.3 |
| 上移/下移 N18/N19 | `Index.ets:1311-1314` | 排序管理（显式上下移保留为可访问替代） | PLAN §5.3、§7.2 |
| ⋮ 排序 ×3 N40-N42＋设置页排序 ×3 S-47~S-49 | `Index.ets:2474-2476`、`SettingsPage.ets:994-1011` | 节点页一个排序入口（3 模式） | PLAN §5.3 |
| 日志级别按钮 ×5 L4-L8 | `LogPage.ets:181-195` | 「错误级别过滤」（更多菜单） | PLAN §3.3 |

**移除（6）**

| 旧入口 | 旧位置 | 理由 | 依据 |
|---|---|---|---|
| 顶栏搜索（非节点页 6 处共用 1 控件） | `Index.ets:2392-2397` | 无可见反应＋状态泄漏（D1） | PLAN REQ-03「无全局空转按钮」 |
| 设置「触感反馈」 | `SettingsPage.ets:1013-1020` | 无消费方（D4） | PLAN §12.4 |
| 设置「液态玻璃」 | `SettingsPage.ets:1021-1028` | 无消费方（D5） | PLAN §12.4 |
| 路由页规则集类型「站点/IP」×2 | `RouteRulesPage.ets:559-584` | 生成器不读 type，无配置效果（D6）；新方案由 format/source 字段替代 | PLAN §7.5 |
| ⋮「清除流量统计」N33 | `Index.ets:2460` | 假清除（D2）；新方案改为扩展会话基准重置后重进（归属设置/日志） | PLAN §10.4 |

### 4.3 PLAN §3.1「不在本页直接展开」对照检查（当前违规点）

| 新页 | 排除项 | 当前违规事实 | 证据 |
|---|---|---|---|
| 节点 | 完整订阅管理 | ⋮「更新当前订阅」、空态「导入订阅链接」、节点长按「查看订阅」都在节点页直接展开订阅操作 | `Index.ets:2459`、`2052-2056`、`1333-1336` |
| 订阅 | 原始节点编辑表单 | 当前分组页无节点编辑表单（✅）；但「新建分组」混在订阅页（展示分组≠订阅） | `GroupPage.ets:463-486` |
| 订阅 | 全局系统设置 | 当前分组页无（✅） | — |
| 分流 | 仅影响主题的外观设置 | 当前路由页无（✅）；但外观设置在设置页（✅ 不违规） | — |
| 设置 | 重复一套域名/IP规则编辑器 | 设置页「直连域名后缀/直连 IP 段」即第二套规则字段，与路由页域名/IP 编辑并存 | `SettingsPage.ets:660-673` vs `RouteRulesPage.ets:241-252` |
| 日志 | 常驻大面积调试统计 | 当前无（✅）；但无连接入口（PLAN §10.1 要求，缺失） | — |
| 工具 | 常用换节点操作 | `showBottomBar` 开启后 FAB/速率条在工具页常驻可点 | `Index.ets:2712`、`2263` |
| 关于 | 调试用字段堆积 | 当前无（✅）；但内核版本硬编码非真实值 | `AboutPage.ets:8,102` |

### 4.4 新方案要求、当前不存在的入口（W01 需要的缺口清单）

| 缺口 | 依据 | 现状最近似物 |
|---|---|---|
| 连接详情（二级页，含规则/策略组链/最终节点） | PLAN §0-2、§10.1-10.2 | ConnectionsPage 只有目标/网络/流量/规则表达式+chains 文本（`ConnectionsPage.ets:265-280`），无详情页 |
| 「检查连接」独立次操作 | PLAN §4.3-4 | 与断开共用 FAB；仅速率条点按隐式测当前节点 |
| 批量模式（检测/收藏/移动/导出/删除＋范围标签） | PLAN §5.3 | 无；只有 ⋮/分组菜单分散动作 |
| 「仅看可用」筛选/收藏筛选 | PLAN §5.3 | 无（搜索仅名称/服务器） |
| 检测方式选择＋进度/取消＋仅看可用＋重测失败 | PLAN §6 | ⋮ 两个固定入口＋测速中「取消」 |
| 待应用草稿条（节点/分流/设置统一） | PLAN §12.2 | 无（规则改动静默待下次连接；设置即时 toast） |
| 分流四子页签（分应用/域名IP/规则集/策略组） | PLAN §7.1 | 单页混排（路由页 2/4 + 设置页 1/4 + 分组页 1/4） |
| 设置搜索＋「恢复本分区默认值」 | PLAN §3.3、§12.4 | 无 |
| 日志页「查看连接」入口 | PLAN §10.1 | 无 |
| 工具页「连通诊断/规则解释」 | PLAN §3.1、§10.3 | 无 |
| 关于页真实内核版本 | PLAN §3.1 | 硬编码常量（`AboutPage.ets:8`） |
| 错误入口携带 sessionId/connectionId/configRevision | PLAN §3.4 | 无任何参数化上下文（§6） |

---

## 5. 已知死路与空转动作清单（全部逐条复核于当前工作区）

| # | 位置 | 现象 | 证据（当前行号） | 涉及新方案 |
|---|---|---|---|---|
| D1 | 顶栏搜索图标（非节点页 6 处共用） | 置 `searchVisible=true` 但搜索行仅 `activeTab===0` 渲染 ⇒ 无可见反应；且状态泄漏：回节点页时搜索行突然展开 | `Index.ets:2392-2397`（置位）、`2575-2579`（仅节点页渲染）、`2641`（bottomBuilder 高度仅 tab0） | REQ-03 |
| D2 | ⋮「清除流量统计」 | 仅清 `AppStorage vpnTotalUp/Down`；内核 `/connections` 无重置接口，UI 1s 轮询与扩展进程通知轮询随即写回真实累计值 ⇒ 显示 ≤1s 复原 | `Index.ets:911-918`（清零）、`424-425`（写回）、`428`（1000ms 间隔）、`VpnExtAbility.ets:649-666`（通知轮询取数＋`publishVpnTraffic`）、`673`（`speedIntervalMs` 间隔） | REQ-20（§10.4） |
| D3 | 日志「清空」 | `fileOffset=0` ⇒ 1s 后 `tailCoreLog()` 从文件头重读当前 `singbox.log` ⇒ 内核日志行重现（只有内存日志真被清） | `LogPage.ets:165-169`（清空置 0）、`99-135`（tail 逻辑，`107-108` 截断归零）、`38-40`（1s 定时） | REQ-20（§10.4） |
| D4 | 设置「触感反馈」 | 无任何消费方（全仓 grep `vibrator|hapticFeedback` 仅 Profile/SettingsPage/Backup 白名单，无振动调用） | `SettingsPage.ets:1013-1020` | REQ-03/§12.4 |
| D5 | 设置「液态玻璃」 | 无任何消费方，不影响任何材质/模糊 | `SettingsPage.ets:1021-1028` | REQ-21/§12.4 |
| D6 | 路由页规则集类型（站点/IP） | 写 `item.type`，生成器只写 `format=binary`、不读 type ⇒ 按钮不改变生成的配置 | `RouteRulesPage.ets:559-584`（按钮）、`99-100`（写入）、`ConfigBuilder.ets:1162-1169`（不读 type） | REQ-19（§7.5） |
| D7 | 路由页「包名」字段 | 生成器要求 `packagesEnabled===true`（UI 无勾选框，新规则默认 false）⇒ 本次会话填的包名不进内核；仅载入迁移补 true 才生效 | `RouteRulesPage.ets:299-306`（输入＋警告文案）、`ConfigBuilder.ets:548`、`model/RouteRule.ets:24`（默认 false）、`129-130`（载入补 true） | REQ-14（§8.5） |
| D8 | 路由页「更新时间/错误」文本 | `updatedAt` 仅由用户编辑写入（显示"最后编辑时间"）；`lastError` 只有编辑时清空的写入点 ⇒ 永不显示 | `RouteRulesPage.ets:106-107`（写入点）、`618-629`（显示） | REQ-19（§7.5） |
| D9 | 分组页重命名 | `renameGroup()`/`renameGroupId`/`renameDraft` 无任何 UI 绑定 ⇒ 死代码，页面无重命名入口 | `GroupPage.ets:29-30`（声明）、`335-346`（方法；grep 全文件无绑定） | REQ-15（§9.1） |
| D10 | 设置页出站模式 | `switchMode()`/`modeIndex()`/`MODE_LABELS`/`MODE_SWITCH_TOASTS` 无组件引用 ⇒ 死代码（模式只能在节点页切） | `SettingsPage.ets:23-25`、`191-194`、`244-265`（grep 复核无调用） | REQ-05 |
| D11 | 节点长按「URL Test」 | 结果只写内存不落库（代码注释明示对齐安卓 StatsBar），下次 `refresh()`/重进页面回退 | `Index.ets:1163-1202`（`1176` 注释、`1177-1183` 仅改内存、无 `saveProfiles`） | REQ-08（§6.2） |
| D12 | `pages/DocPage` / `pages/DashboardPage` | DocPage 标 `@Entry` 但**未注册进 main_pages.json** ⇒ `pushUrl` 也到不了；DashboardPage 全仓无 import/引用 ⇒ 不可达（「使用文档」「yacd 面板」两个能力在 UI 上不存在） | `DocPage.ets:12`、`DashboardPage.ets:13`、`entry/src/main/resources/base/profile/main_pages.json`（仅 4 页）、`Index.ets:54-55`（移除注释） | REQ-02（IA） |
| D13（新发现） | 抽屉头部版本行 | `Index.appVersion` 声明后**全文件无赋值**（AboutPage 的赋值是另一组件）⇒ 抽屉版本恒为空串 | `Index.ets:124`（声明）、`1743`（读取）；grep `appVersion` 在 Index 仅此两处 | REQ-23/视觉 |
| D14（新发现） | 设置页 `isEntrySelected()` | 方法定义后无任何调用方 ⇒ 死代码 | `SettingsPage.ets:311-317`（grep 全仓仅定义处） | 清理 |
| D15（新发现） | 路由页规则集 ↑/↓ 首末项 | 图标置灰但**仍可点**（无 disabled 逻辑；函数内越界 return 兜底）⇒ 视觉禁用态与实际行为不一致 | `RouteRulesPage.ets:509-528`（首项 `512` 置灰）、`529-548`（末项 `532` 置灰）、`121-132`（越界 return） | REQ-22/§13.3 |

> 复核结论：**未发现「点了完全没接方法」的按钮**——7 个页面全部 `onClick/onTouch(Up)/bindContextMenu` 均指向存在的方法体（与 `ours-side.md` §10 结论一致，本次逐条复核仍成立）。

---

## 6. 二级页面与上下文携带现状

| 页面 | 入口 | 传参方式 | 携带内容 | 返回 | 证据 |
|---|---|---|---|---|---|
| ProfileEdit（新建/编辑节点） | 节点页顶栏＋→「新建节点」；节点长按→「编辑节点」 | **AppStorage 全局键**（非 router 参数）：`editProfileId`（''=新建 / p.id=编辑） | 目标节点 id；**新建时无分组上下文**，靠 `recent_subscription_group` Preferences 预填分组（仅新建） | `router.back()`（保存成功 185/批量导入 238；返回键 361） | `Index.ets:1362-1364`、`1326-1330`；`ProfileEdit.ets:44-68`（59-66 预填）、`161-189` |
| SubDetailPage（订阅详情） | **仅**节点长按→「查看订阅」（`subUrl` 非空才渲染；GroupPage 无入口） | ✅ `router.pushUrl` params：`{ url: p.subUrl }`；页内 `router.getParams()` 读取 | 订阅 URL（以此反查 SubInfo；查不到→`notFound` 态） | `router.back()`（252 返回键；310 notFound 返回键） | `Index.ets:1333-1336`；`SubDetailPage.ets:97-125`（103-104 取参）、`240-254`、`292-314` |
| ConnectionsPage（连接列表） | 顶栏连接图标 | ❌ **无参数** | 无（不知来源页/不知当前节点/规则上下文） | `router.back()`（186） | `Index.ets:2416-2422`；`ConnectionsPage.ets:170-199` |
| DocPage | **无入口**（未注册路由） | — | — | `router.back()`（43，不可达） | `DocPage.ets:12,43` |
| DashboardPage | **无入口**（无引用） | — | — | — | `DashboardPage.ets:13` |
| SubDiffDialog（订阅差异） | 订阅更新后 1s（Index 与 GroupPage 各一套；SubDetailPage 也有） | `@Prop` 快照（groupName＋SubUpdateResult），每次新建 controller | 组名＋更新差异四段 | `controller?.close()` | `Index.ets:861-867`、`GroupPage.ets:101-107`、`SubUpdateFeedback.ets:19-60`（55-57） |

**上下文携带缺口（对照 PLAN §3.4）**：

1. **无 sessionId/connectionId/configRevision 参数化**：ConnectionsPage/SubDetailPage/DocPage 均不携带运行上下文；PLAN 要求「日志、连接、规则解释从错误入口打开时携带 sessionId/connectionId/configRevision，返回原页面不丢上下文」——现状全部缺失（`ConnectionsPage.ets:99-123` 仅按 `vpnRunning` 轮询）。
2. **ProfileEdit 用 AppStorage 传 id 而非 router 参数**：与 SubDetailPage 的 params 方式不一致；`editProfileId` 是全局可变键，存在被其它流程覆盖/残留的风险（`Index.ets:1328`、`1363`；`ProfileEdit.ets:45`）。
3. **浏览状态不持久**：`selectedGroupId` 只写内存（`Index.ets:2153`，注释明示不落库）、`nodeSearch/searchVisible` 重启即丢、设置页/路由页滚动位置不记忆——PLAN §3.4「记住各页搜索、滚动、节点展示组、订阅选择、规则子页签」现状全部未满足。
4. **订阅详情入口过深**：只能从节点长按（且要求 `subUrl` 非空）进入；分组页订阅卡主体不可点（`GroupPage.ets:490-524` 无整体 onClick）——新「订阅」页需把详情作为一级可达入口。
5. **无「继续编辑/保存草稿/放弃修改」保护**：ProfileEdit 返回键直接 `router.back()`（361），未保存内容静默丢弃；分组设置面板「取消」同样丢弃（`GroupPage.ets:582-595`）——PLAN §3.4 第二条缺失。
6. **返回语义现状**（已符合 PLAN §3.4 第一条）：抽屉开→收；非节点页→回节点页；节点页→退桌面（`Index.ets:194-205`）。二级页 `router.back()` 返回调用方（1329/1335/2421 的 push 来源）。

---

## 7. 风险与映射要点（供 W01→W02 使用）

- **R1（最高）顶栏动作簇全局常驻**：＋/🔗/⋮/🔍 是「配置页语义」却渲染在全部 7 页（`Index.ets:2320-2355` 经 `shellTitleBar` 全局挂载），⋮ 的作用域还是节点页残留的 `selectedGroupId`（`2492-2505`）——在订阅/日志页点「测速本组」测的是节点页上次选中的分组。PLAN §3.3 页面专属顶栏必须重写 `titleActionCluster` 的分页分发，并处理 6 处 D1。
- **R2 订阅能力三处分裂**：GroupPage 订阅卡（更新/分享/导出/清空/删除）、SubDetailPage（更新/分享/分组/删除/更新偏好）、Index ⋮「更新当前订阅」+节点长按「查看订阅」——新「订阅」页需要三处收拢，且详情入口从「节点长按」提升为列表直达（§6-4）。
- **R3 分流能力三处分裂**：路由页（规则/规则集）、设置页分应用块（15 项＋弹窗 4 项）、分组页策略组面板（5 项）——「分流」页四子页签需要跨 3 个文件搬运，注意分应用块与设置页 `persistPerApp` 的自动重连语义要一并带走（`SettingsPage.ets:274-291`）。
- **R4 假清除双坑（D2/D3）**：直接阻塞 PLAN REQ-20 验收；修复需扩展进程配合（会话基准偏移/日志文件身份），不是纯 UI 改动。
- **R5 二级页无上下文契约**：PLAN §3.4 的 sessionId/connectionId/configRevision 携带是新增契约，现有 4 个注册路由都不带参（除 SubDetailPage 的 url）；连接详情若做成二级页需同时改 `main_pages.json` 与来源入口。
- **R6 `showBottomBar` 与新 IA 冲突**：开启后 FAB/速率条在 6 个非节点页常驻可点（`Index.ets:2712/2688`），与「工具页不含常用换节点操作」（PLAN §3.1）直接冲突——迁移时需决定该设置的存废或改为「仅速率条不可点」。
- **R7 死文件处置**：DocPage（未注册路由）与 DashboardPage（无引用）需在 W01 映射中明确「移除」或「关于页链接替代」；「使用文档」入口 2026-10-17 已被用户要求移除（`Index.ets:54-55`），不要在映射中回加。
- **R8 关于页内核版本硬编码**（`AboutPage.ets:8`）与 PLAN「真实内核版本」不符；`CGoSingBoxVersion` 导出已存在（AGENTS.md 架构速记），属低成本补齐。
- **R9 触控热区**：订阅卡/分组卡动作行是 12.5px Text（`GroupPage.ets:417-446`）、规则「删除」是 13px Text（`RouteRulesPage.ets:630-634,703-704`），热区远小于 PLAN §13.1 的 44×44vp——迁移重排时一并处理。
- **R10 行号漂移**：本基线行号基于 2026-10-24 快照；Index.ets/SettingsPage.ets 在上轮审计期间已被并发修改过（`ours-side.md` §基线记录了 −11…+4 漂移）。后续施工引用本文件行号时，先 `grep` 方法名复核。
