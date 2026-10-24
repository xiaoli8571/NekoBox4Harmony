# 安卓侧事实清单 —— NekoBoxForAndroid 1.4.2（tag `1.4.2`）

> 用途：与鸿蒙版 7 个抽屉页面逐项对比。本文只做**只读抽取**，不含任何评价/建议。
> 所有行号均为 tag `1.4.2` 源码实文件行号，可逐条核对。

## 0. 取证方法与路径约定

- 源码来源：GitHub raw 只读，tag `1.4.2`（`https://raw.githubusercontent.com/MatsuriDayo/NekoBoxForAndroid/1.4.2/<path>`）；目录枚举用 `https://api.github.com/repos/MatsuriDayo/NekoBoxForAndroid/git/trees/1.4.2?recursive=1`（`"truncated": false`，共 657 条路径，仅 `app/src/main` 一个 source set，无 flavor 专属 res）。
- 路径简写（下文所有证据列均用简写）：
  - `ui/` = `app/src/main/java/io/nekohasekai/sagernet/ui/`
  - `widget/` = `app/src/main/java/io/nekohasekai/sagernet/widget/`
  - `res/` = `app/src/main/res/`
  - `res/xml/global_preferences.xml` 等按原样书写
- 中文文案取自 `res/values-zh-rCN/strings.xml`；凡该文件缺失的键，回落到 `res/values/strings.xml`（英文原文）并在表格里标注 `(en)`。
- 三个影响“菜单是否出现”的全局开关（对比时必须先固定这三个值）：
  | 开关 | 定义 | 影响 |
  |---|---|---|
  | `enableClashAPI` | `ui/../database/DataStore.kt:88`；开关在 `res/xml/global_preferences.xml:216-220` | 抽屉里 **Dashboard** 项显隐（`MainActivity.kt:131`） |
  | `isPlay` | `ktx/Utils.kt:294`（`BuildConfig.FLAVOR == "play"`） | 抽屉里 **推广** 项显隐（`MainActivity.kt:132`） |
  | `showBottomBar` | `DataStore.kt:89`；文案“像 SagerNet 一样显示底栏”（`strings-zh:190`） | 非配置页是否保留 stats 条 + FAB（`MainActivity.kt:320-324`） |

---

## 1. 全局骨架：抽屉 + 顶栏 + stats 条 + FAB

### 1.1 布局区块（`res/layout/layout_main.xml`，125 行）

| 序 | 区块 | 证据 |
|---|---|---|
| 1 | 根 `DrawerLayout`（`@id/drawer_layout`），`tools:openDrawer="start"` | `layout_main.xml:2-8` |
| 2 | `CoordinatorLayout` 容器，内含 `fragment_holder`（页面占位） | `layout_main.xml:10-19` |
| 3 | `CircularProgressIndicator`（`@id/fabProgress`）锚定在 FAB 中心，默认 `invisible`，用于 FAB 外圈进度环 | `layout_main.xml:22-33` |
| 4 | **FAB**：`io.nekohasekai.sagernet.widget.ServiceButton`（`@id/fab`），`layout_anchor="@id/stats"`，初始图标 `ic_service_idle` | `layout_main.xml:35-44` |
| 5 | **stats 条**：`widget.StatsBar`（`@id/stats`，继承 `BottomAppBar`），`layout_gravity="bottom"`、`hideOnScroll="true"`，内部纵向 3 行：`tx`(▲) / `rx`(▼) / `status`（14sp/14sp/16sp） | `layout_main.xml:46-99`（tx:64-73、rx:75-84、status:86-95） |
| 6 | 抽屉 `NavigationView`（`@id/nav_view`），`app:menu="@menu/main_drawer_menu"` | `layout_main.xml:103-111` |
| 7 | 抽屉 `NavigationView`（`@id/nav_view_black`），同上菜单，仅黑色主题使用（多 `itemShapeFillColor`） | `layout_main.xml:113-123` |

### 1.2 抽屉菜单 `res/menu/main_drawer_menu.xml`（10 项，3 个 group，均 `checkableBehavior="single"`）

| 序 | id | 中文标题 | 图标 | 行号 | 条件可见 |
|---|---|---|---|---|---|
| 1 | `nav_configuration` | 配置 | `ic_action_description` | 5-8 | 常驻（默认页） |
| 2 | `nav_group` | 分组 | `ic_baseline_view_list_24` | 10-13 | 常驻 |
| 3 | `nav_route` | 路由 | `ic_maps_directions` | 15-18 | 常驻 |
| 4 | `nav_settings` | 设置（`@string/settings`） | `ic_action_settings` | 20-23 | 常驻 |
| 5 | `nav_logcat` | 日志 | `ic_baseline_bug_report_24` | 29-32 | 常驻 |
| 6 | `nav_traffic` | sing-box 仪表板 | `ic_baseline_transform_24` | 33-36 | **仅 `enableClashAPI=true`**（`MainActivity.kt:131`） |
| 7 | `nav_tools` | 工具 | `baseline_construction_24` | 37-40 | 常驻 |
| 8 | `nav_tuiguang` | 推广 | `ic_social_share` | 46-49 | **仅非 Play 版**（`MainActivity.kt:132`） |
| 9 | `nav_faq` | 文档 | `ic_device_data_usage` | 50-53 | 常驻，**不切页** |
| 10 | `nav_about` | 关于 | `ic_baseline_info_24` | 54-57 | 常驻 |

> 分组边界：`1-4` 一组（无 group id）、`misc` 组=5-7、`about` 组=8-10（`main_drawer_menu.xml:4,26-28,43-45`）。抽屉**无 headerView**（布局里没有）。

### 1.3 抽屉 / 顶栏 / FAB / stats 的行为（`ui/MainActivity.kt`，480 行）

| # | 行为 | 证据 |
|---|---|---|
| G1 | 主题为 `Theme_SagerNet_Black` 时用 `nav_view_black` 并从树里移除 `nav_view`，否则反之 | `MainActivity.kt:66-75` |
| G2 | 首屏固定进 `nav_configuration`（`savedInstanceState == null`） | `MainActivity.kt:78-80` |
| G3 | 返回键：当前是 `ConfigurationFragment` → `moveTaskToBack(true)`（退到后台，不是退出）；否则 → 强制切回配置页 | `MainActivity.kt:81-87` |
| G4 | **FAB 点击**：`serviceState.canStop` → `SagerNet.stopService()`；否则 `connect.launch(null)`（走 `VpnRequestActivity.StartService` 申请 VPN 权限） | `MainActivity.kt:89-93`、`400-402` |
| G5 | **stats 条点击**：仅当 `serviceState.connected` 才 `stats.testConnection()`；未连接时点击**无响应**（无 toast、无对话框） | `MainActivity.kt:94` |
| G6 | 抽屉项点击：`item.isChecked` 为真 → 只关抽屉（重复点当前页不重建）；否则 `displayFragmentWithId` | `MainActivity.kt:307-312` |
| G7 | 切页后把 `navigation.menu.findItem(id).isChecked = true` | `MainActivity.kt:356` |
| G8 | `displayFragment`：`ConfigurationFragment` → `stats.allowShow=true` + `fab.show()`；其他页且 `!showBottomBar` → `stats.allowShow=false` + `performHide()` + `fab.hide()`；然后 replace 并关抽屉 | `MainActivity.kt:316-329` |
| G9 | `nav_traffic` → `WebviewFragment`（内置 WebView 加载 `DataStore.yacdURL`，默认 `http://127.0.0.1:9090/ui`） | `MainActivity.kt:340`、`DataStore.kt:165`、`ui/WebviewFragment.kt:51` |
| G10 | `nav_faq` → 外部浏览器 `https://matsuridayo.github.io/`，返回 false（**不切页、不勾选**） | `MainActivity.kt:343-346` |
| G11 | `nav_tuiguang` → 外部浏览器 `https://neko-box.pages.dev/喵`，返回 false | `MainActivity.kt:349-352` |
| G12 | 服务状态变化 → `changeState()` 同时驱动 FAB 与 stats 条 | `MainActivity.kt:360-370`、`381-383` |
| G13 | 速度回调 → `stats.updateSpeed(txRateProxy, rxRateProxy)`，文案 `▲/▼ + 速率` | `MainActivity.kt:406-408`、`widget/StatsBar.kt:112-123` |
| G14 | stats 条状态文案：Connected=`vpn_connected`；Connecting/Stopping/Idle 各一条；**只有 Connected 时才 `hideOnScroll=true`**（滚动自动收起） | `widget/StatsBar.kt:83-109`（89 行） |
| G15 | stats 条连接测试：置灰 → `activity.urlTest()` → 成功显示 `连接成功: HTTPS 握手耗时 %dms`（HTTP 测试地址则另一条文案），失败弹 snackbar | `widget/StatsBar.kt:125-159` |
| G16 | FAB 状态图标 4 态（stopped/connecting/connected/stopping）+ 外圈进度，`contentDescription` 在“停止/连接”间切换，`enabled` 仅在 `canStop||Stopped` | `widget/ServiceButton.kt:110-130` |
| G17 | 电视/遥控器：`DPAD_LEFT` 开抽屉、`DPAD_RIGHT` 关抽屉，其余键转发给当前 `ToolbarFragment.onKeyDown` | `MainActivity.kt:456-478` |
| G18 | 预览版启动弹窗（`isPreview`=`FLAVOR=="preview"`，`ktx/Utils.kt:295`） | `MainActivity.kt:120-126` |
| G19 | 顶栏标题默认来自 `layout_appbar` 的 `app:title="@string/app_name"`，各页自行 `setTitle` 覆盖 | `res/layout/layout_appbar.xml:18` |
| G20 | 顶栏高度 `?attr/actionBarSize`，背景 `?attr/colorPrimary`，`elevation=4dp`；汉堡图标 `ic_navigation_menu` 点开抽屉 | `layout_appbar.xml:2-18`、`ui/ToolbarFragment.kt:20-25` |

---

## 2. 配置页 `ConfigurationFragment`

### 2.1 页面结构（自上而下）

| 序 | 区块 | 证据 |
|---|---|---|
| 1 | AppBar + Toolbar：汉堡 + **标题 = `@string/app_name`（"NekoBox"，未 setTitle）** + 右上角 3 个菜单位 | `ui/ConfigurationFragment.kt:118-120`（`ToolbarFragment(R.layout.layout_group_list)`）、`layout_appbar.xml:18` |
| 2 | **分组标签栏** `TabLayout @id/group_tab`：可滚动（`tabMode=scrollable`），背景 `colorPrimary`，elevation 4dp，**默认 `gone`** | `res/layout/layout_group_list.xml:15-29` |
| 3 | 只在**分组数 ≥ 2** 时显示标签栏，且此时 Toolbar elevation 由 0 → 4dp | `ui/ConfigurationFragment.kt:947-949` |
| 4 | `ViewPager2 @id/group_pager`：一页一个分组，`offscreenPageLimit=2`；滑动切页同时写 `DataStore.selectedGroup` | `layout_group_list.xml:31-34`、`ConfigurationFragment.kt:207-217`、`145-153` |
| 5 | 每页内是 `FastScrollRecyclerView @id/configuration_list`（内边距 4dp / 底部 48dp / 滚动条宽 0） | `layout_profile_list.xml:2-18` |
| 6 | 行卡片 `layout_profile.xml`：左侧 4dp 选中色条（`selected_view`，默认 invisible）→ 名称（粗体，`profile_name`）→ 右侧 3 个图标：编辑 `edit` / 分享 `share` / 删除 `remove`（默认 gone）→ 次行 地址 + 流量（整行容器默认 gone）→ 末行 协议类型 + 状态 | `layout_profile.xml:20-27, 52-59, 62-71, 73-96, 98-108, 112-143, 145-173` |
| 7 | 底部：**stats 条 + FAB 强制可见**（唯一强制页） | `MainActivity.kt:317-319` |
| 8 | 无分组时自动建 ungrouped 分组；ungrouped 分组在空时被从标签列表剔除 | `ConfigurationFragment.kt:919-927` |

### 2.2 右上角菜单（`res/menu/add_profile_menu.xml`，130 行；绑定点 `ConfigurationFragment.kt:178-180`）

**顶层 3 项：**

| # | id | 呈现 | 标题 | 行号 |
|---|---|---|---|---|
| M1 | `action_search` | `always`，`actionViewClass=SearchView` | 搜索框 | 5-8 |
| M2 | `action_add` | `ifRoom`，图标 `ic_action_note_add` | 添加服务器配置 | 10-14 |
| M3 | `action_misc` | `always`，图标 `ic_baseline_more_vert_24`，`title=""` | ⋮ | 83-87 |

**M2「添加服务器配置」下拉（20 个叶子 + 1 个“手动输入”分组头）：**

| # | id | 标题 | 行号 |
|---|---|---|---|
| M2-1 | `action_scan_qr_code` | 扫描二维码 | 16-18 |
| M2-2 | `action_import_clipboard` | 从剪切板导入 | 19-21 |
| M2-3 | `action_import_file` | 从文件中导入 | 22-24 |
| — | （分组头） | 手动输入 | 25-26 |
| M2-4 | `action_new_socks` | SOCKS | 27-29 |
| M2-5 | `action_new_http` | HTTP | 30-32 |
| M2-6 | `action_new_ss` | Shadowsocks | 33-35 |
| M2-7 | `action_new_vmess` | VMess | 36-38 |
| M2-8 | `action_new_vless` | VLESS（硬编码字面量，未走 strings） | 39-41 |
| M2-9 | `action_new_trojan` | Trojan | 42-44 |
| M2-10 | `action_new_trojan_go` | Trojan-Go | 45-47 |
| M2-11 | `action_new_mieru` | Mieru | 48-50 |
| M2-12 | `action_new_naive` | Naive | 51-53 |
| M2-13 | `action_new_hysteria` | Hysteria | 54-56 |
| M2-14 | `action_new_tuic` | TUIC | 57-59 |
| M2-15 | `action_new_shadowtls` | ShadowTLS | 60-62 |
| M2-16 | `action_new_anytls` | AnyTLS | 63-65 |
| M2-17 | `action_new_ssh` | SSH | 66-68 |
| M2-18 | `action_new_wg` | WireGuard | 69-71 |
| M2-19 | `action_new_config` | 自定义配置 | 72-74 |
| M2-20 | `action_new_chain` | 代理链 | 75-77 |

**M3「⋮」下拉（7 个叶子 + 1 个“排序”子菜单 3 项）：**

| # | id | 标题 | 行号 | 备注 |
|---|---|---|---|---|
| M3-1 | `action_update_subscription` | 更新当前组订阅 | 89-91 | 非订阅组 → snackbar“当前组不是订阅” |
| M3-2 | `action_clear_traffic_statistics` | 清空流量统计数据 | 92-94 | 仅清当前组 |
| M3-3 | `action_remove_duplicate` | 删除重复的服务器 | 95-97 | 弹确认框，最多列 20 条名称 |
| M3-4 | `action_connection_tcp_ping` | TCPing | 98-100 | 打开测试进度对话框 |
| M3-5 | `action_connection_url_test` | URL Test | 101-103 | 打开测试进度对话框 |
| M3-6 | `action_connection_test_clear_results` | 清理测试结果 | 104-106 | 无确认框 |
| M3-7 | `action_connection_test_delete_unavailable` | 清理不可用配置 | 107-109 | 弹确认框 `delete_confirm_prompt` |
| M3-8 | `action_order` → | 排序 | 110-126 | 子菜单 3 项，`checkableBehavior=single` |
| M3-8a | `action_order_origin` | 原始 | 115-117 | 命中当前值打勾 |
| M3-8b | `action_order_by_name` | 以名称 | 118-120 | |
| M3-8c | `action_order_by_delay` | 以延时 | 121-123 | 延时为 0/非 1 时按 114514 排（`ConfigurationFragment.kt:1437`） |

> 计数：**顶层 3 项；可点击叶子 1+20+10 = 31 项**。“手动输入”“排序”为分组头，不可点。
> `action_order*` 的勾选状态在每次 `GroupFragment.onResume` 里刷新（`ConfigurationFragment.kt:1106, 1110-1155`），且 **select 模式下不刷新**（1111 行 `if (select) return`）。

### 2.3 关键交互

| # | 交互 | 行为 | 证据 |
|---|---|---|---|
| C1 | 点搜索图标 | 展开 SearchView（`maxWidth=Int.MAX_VALUE`），输入实时过滤**当前分组**列表（匹配 名称 / 类型 / 地址，全部小写包含） | `ConfigurationFragment.kt:189-198`、`1278-1291` |
| C2 | 搜索框失焦 | 自动收起并清焦点（`onActionViewCollapsed`） | `ConfigurationFragment.kt:194-198`、`1737-1740` |
| C3 | **点顶栏标题区** | 若已选节点不在可视区 → 滚到该节点；否则滚回列表顶部 | `ConfigurationFragment.kt:219-241` |
| C4 | 点分组标签 | 切 ViewPager 页，并写 `DataStore.selectedGroup` | `ConfigurationFragment.kt:145-153`、`210-217` |
| C5 | 长按分组标签 | 仅消费事件以清除长按 toast，无实际功能 | `ConfigurationFragment.kt:214-216` |
| C6 | **点节点卡片** | 设为当前节点（`DataStore.selectedProxy`）；若服务在跑则 `reloadService()`；**电视版**点已选中项 = 启停服务 | `ConfigurationFragment.kt:1499-1527`（1518-1524 为 TV 分支） |
| C7 | 卡片「编辑」铅笔 | 跳该协议的 `*SettingsActivity`（订阅组走订阅编辑） | `ConfigurationFragment.kt:1594-1600` |
| C8 | 卡片「分享」图标 | 弹 `profile_share_menu`：二维码(标准/SN Link)｜导出剪切板(标准/SN Link)｜配置(导出剪切板/导出文件)；按条目能力动态删项 | `ConfigurationFragment.kt:1629-1653, 1682-1708`、`res/menu/profile_share_menu.xml:3-38` |
| C9 | 卡片「删除」X | 立即从列表移除 → 底部 snackbar「已删除 N 项」+「撤销」；不撤销则提交 DB 删除 | `ConfigurationFragment.kt:1602-1608`、`widget/UndoSnackbarManager.kt:37-50` |
| C10 | **拖拽排序** | `ItemTouchHelper` 上下拖拽；`getSwipeDirs` 恒返回 0 → **配置页禁用左滑删除**；拖拽仅在服务 `canStop||Stopped` 时可用 | `ConfigurationFragment.kt:1173-1208`（1180、1186） |
| C11 | 点状态文字 | 仅 `status==3`（未知错误）时可点，弹原始错误 | `ConfigurationFragment.kt:1583-1592` |
| C12 | 点击「目标/URL」图标？ | 无此入口（本版本卡片只有 编辑/分享/删除 三图标） | `layout_profile.xml:62-108` |
| C13 | 分区切换时隐藏项 | select 模式（从 `ProfileSelectActivity` 进入）隐藏 编辑/分享/删除，卡片点击直接回传 id | `ConfigurationFragment.kt:1610-1617, 1494-1497` |
| C14 | 代理链 / nekoBean 条目 | 隐藏分享按钮（链无标准链接；nekoBean 条目） | `ConfigurationFragment.kt:1610-1617` |
| C15 | 连接测试进度框 | 「最小化」→ 转通知栏进度；「取消」→ 终止并回写已测结果；不可点外部关闭 | `ConfigurationFragment.kt:597-690, 692-832` |
| C16 | 从文件导入 | 支持 `.zip`（逐 entry 解析，WireGuard 多文件）与纯文本；解析出订阅则转订阅导入流程 | `ConfigurationFragment.kt:283-328` |
| C17 | 空组行为 | 无任何分组时自动创建 ungrouped 组；ungrouped 组为空则不显示标签页 | `ConfigurationFragment.kt:919-927` |

**仅在特定条件下可见/可用（本页）**

- 分组标签栏：仅分组数 ≥ 2（`947-949`）。
- 「编辑 / 分享 / 删除」三图标：select 模式全隐藏（`1612-1613`）；「分享」对 `TYPE_CHAIN` 与 `nekoBean` 条目隐藏（`1610-1617`）。
  > 注：删除图标在 XML 里默认 `gone`（`layout_profile.xml:107`），但 `removeButton.isGone = select`（`ConfigurationFragment.kt:1613`）在非 select 模式下会把它置为**可见**；同理 `editButton.isGone = select`（1612）。即普通模式每行常显三图标，只有 select 模式才全隐。
- 「编辑 / 删除」在“该节点正在使用且服务已启动”时 `isEnabled=false`（`1624-1625`）。
- 卡片地址行：仅在 `alwaysShowAddress` 打开且有名称时显示（`1557-1563`）。
- 流量文本：仅 `tx+rx != 0` 时显示（`1542-1550`）。
- 状态色：可用=绿 `material_green_500`，失败=红 `material_red_500`（`1573-1581`）。

---

## 3. 分组页 `GroupFragment`

### 3.1 页面结构

| 序 | 区块 | 证据 |
|---|---|---|
| 1 | AppBar + Toolbar：标题 = **分组**（`toolbar.setTitle(R.string.menu_group)`）+ 右上 2 个图标 | `ui/GroupFragment.kt:49` |
| 2 | `FastScrollRecyclerView @id/group_list`（padding 4dp，快速滚动条） | `res/layout/layout_group.xml:17-27` |
| 3 | 行卡片 `layout_group_item.xml`：顶部订阅更新进度条（默认 gone）→ 组名 + 订阅用户名（`group_user`）→ 右侧 编辑铅笔 `edit` / ⋮ `options` → 底部 订阅流量文本 `group_traffic`(gone) / 状态 `group_status` / 「更新」按钮 `group_update` | `layout_group_item.xml:17-23, 40-79, 101-127` |
| 4 | 底部：stats 条 + FAB **默认隐藏**（`showBottomBar=false` 时） | `MainActivity.kt:320-324` |

### 3.2 右上角菜单（`res/menu/add_group_menu.xml`，2 项；绑定 `GroupFragment.kt:50-51`）

| # | id | 呈现 | 标题 | 行号 |
|---|---|---|---|---|
| G-1 | `action_update_all` | `always`，图标 `ic_baseline_update_24` | 更新所有订阅 | 4-8 |
| G-2 | `action_new_group` | `always`，图标 `ic_av_playlist_add` | 创建分组 | 9-13 |

> `add_group_menu.xml` 只有 2 项，**没有溢出菜单（无 ⋮）**。

### 3.3 行内操作与弹出的「行菜单」

| # | 交互 | 行为 | 证据 |
|---|---|---|---|
| GR1 | 「更新所有订阅」 | 先弹确认框（文案“更新全部订阅？”）；确认后对所有 `type==SUBSCRIPTION` 的组逐个 `GroupUpdater.startUpdate` | `GroupFragment.kt:116-128` |
| GR2 | 「创建分组」 | 跳 `GroupSettingsActivity`（新建） | `GroupFragment.kt:112-114` |
| GR3 | 行内「编辑」铅笔 | 跳 `GroupSettingsActivity` 带 `EXTRA_GROUP_ID`；**ungrouped 组无编辑图标** | `GroupFragment.kt:390-394`、`386` |
| GR4 | 行内「更新」按钮 | 仅订阅组显示（非订阅 `isInvisible`），点击立即更新，无确认 | `GroupFragment.kt:396-398`、`387, 438` |
| GR5 | 行内「⋮」 | 弹 `group_action_menu`；**非订阅组删掉「分享订阅」整个子菜单** | `GroupFragment.kt:400-411`（406-408） |
| GR6 | 行菜单：分享订阅 | 子项：导出到剪切板 / 二维码 | `res/menu/group_action_menu.xml:3-14`；`GroupFragment.kt:339-347` |
| GR7 | 行菜单：导出 | 子项：导出到剪切板（全部节点标准链接，`compact=true`）/ 导出到文件（`profiles_<组名>.txt`） | `group_action_menu.xml:15-26`；`GroupFragment.kt:349-362` |
| GR8 | 行菜单：清空 | 确认框 `clear_profiles_message` → `GroupManager.clearGroup` 删组内所有节点 | `group_action_menu.xml:27-29`；`GroupFragment.kt:364-374` |
| GR9 | **左滑删除组** | 滑出 → 列表移除 + snackbar 撤销；**ungrouped 组、正在更新的组禁用滑动** | `GroupFragment.kt:62-89`（65-73、85-89） |
| GR10 | **拖拽排序** | 上下拖拽改 `userOrder` 并落库；同样对 ungrouped / 更新中禁用 | `GroupFragment.kt:75-83, 91-105` |
| GR11 | 订阅更新中 | 进度条替代表态：`isIndeterminate` 或百分比；**编辑图标隐藏、更新按钮隐藏**；组名行顶部 padding 从 15dp 变 11dp | `GroupFragment.kt:413-431` |
| GRow | 行内容分支 | ①订阅有 `bytesUsed` → 显示“已用/剩余”或“已用”；②无 bytesUsed 但 `subscriptionUserinfo` 有 `upload/download/total/expire` → 解析成流量+到期文本；③都不是 → 隐藏流量行 | `GroupFragment.kt:442-510` |
| GRow2 | 状态行文案 | BASIC：`空` / `N 个节点`；SUBSCRIPTION：`空` / `N 个节点 · M - D`（最后更新时间） | `GroupFragment.kt:517-539` |

**条件可见（本页）**：编辑铅笔（ungrouped 隐藏）、更新按钮（非订阅隐藏）、订阅更新进度条（仅更新中）、流量行（按上面三分支）。

---

## 4. 路由页 `RouteFragment`

### 4.1 页面结构

| 序 | 区块 | 证据 |
|---|---|---|
| 1 | AppBar + Toolbar：标题 = **路由** + 右上 1 个图标（另 2 项在溢出里） | `ui/RouteFragment.kt:37-39` |
| 2 | `FastScrollRecyclerView @id/route_list` | `res/layout/layout_route.xml:17-27` |
| 3 | **列表第 0 项恒为一张警告卡**（`layout_empty_route.xml`，文案 `route_warn`），点击打开外部文档 `https://matsuridayo.github.io/nb4a-route/` | `ui/RouteFragment.kt:157-171, 264-270`；`layout_empty_route.xml:15-21` |
| 4 | 规则行 `layout_route_item.xml`：名称（粗体）→ 右侧 订阅图标(默认 gone，代码未用) / 编辑铅笔 / 分享(默认 gone，代码未用)；次行 规则摘要 + 出站 → 右侧 `SwitchCompat` | `layout_route_item.xml:35-67, 69-94, 111-133`；`RouteFragment.kt:272-305` |
| 5 | 底部：stats 条 + FAB 默认隐藏 | `MainActivity.kt:320-324` |

### 4.2 右上角菜单（`res/menu/add_route_menu.xml`，3 项；绑定 `RouteFragment.kt:38-39`）

| # | id | 呈现 | 标题 | 行号 |
|---|---|---|---|---|
| R-1 | `action_new_route` | `ifRoom`，图标 `ic_baseline_add_road_24` | 新建路由规则 | 4-8 |
| R-2 | `action_reset_route` | `never`（落进 ⋮ 溢出） | 重置 | 9-12 |
| R-3 | `action_manage_assets` | `never`（落进 ⋮ 溢出） | 管理路由资源 | 13-16 |

> 结果：工具栏上只露出 1 个图标，其余 2 项在 ⋮ 里。**没有“导出/导入规则”入口**。

### 4.3 关键交互

| # | 交互 | 行为 | 证据 |
|---|---|---|---|
| RT1 | 「新建路由规则」 | 跳 `RouteSettingsActivity`（新建） | `RouteFragment.kt:105-107` |
| RT2 | 「重置」 | 确认框（复用 `clear_profiles_message`）→ `rulesDao.reset()` + `rulesFirstCreate=false` + 重载列表 | `RouteFragment.kt:108-120` |
| RT3 | 「管理路由资源」 | 跳 `AssetsActivity`（标题“资源”，活动内有 `import_asset_menu` 的 `action_import_file`） | `RouteFragment.kt:121-123`；`ui/AssetsActivity.kt:43,136` |
| RT4 | 点规则行任意处 | 等价于点开关：`enableSwitch.performClick()` → 写库并重载 | `RouteFragment.kt:287-289, 291-299` |
| RT5 | 拖开关 | 启用/停用单条规则 | `RouteFragment.kt:290-299` |
| RT6 | 「编辑」铅笔 | 跳 `RouteSettingsActivity` 带 `EXTRA_ROUTE_ID` | `RouteFragment.kt:300-304` |
| RT7 | **左滑删除** | 滑出 → 列表移除 + snackbar 撤销；**第 0 项（文档卡）不可滑** | `RouteFragment.kt:50-57, 68-72` |
| RT8 | **拖拽排序** | 上下拖拽，索引按 `+1` 偏移处理文档卡；拖到文档卡上返回 false；松手落库 + `needReload` | `RouteFragment.kt:59-66, 74-84, 180-204` |
| RT9 | 点文档卡 | 打开 nb4a-route 文档 | `RouteFragment.kt:266-268` |

**条件可见（本页）**：规则行「订阅」图标与「分享」布局在 layout 里就是 `gone`，`RuleHolder` 也未绑定点击 → 实际为**死控件**（`layout_route_item.xml:47-56, 70-78`；`RouteFragment.kt:272-281`）。

---

## 5. 设置页 `SettingsFragment`

### 5.1 页面结构

| 序 | 区块 | 证据 |
|---|---|---|
| 1 | AppBar + Toolbar：标题 = **设置**；**无任何右上角菜单**（全类没有 `inflateMenu`） | `ui/SettingsFragment.kt:15`（类体 9-22 行） |
| 2 | `FragmentContainerView @id/settings` 承载 `SettingsPreferenceFragment` | `res/layout/layout_config_settings.xml:11-14`；`SettingsFragment.kt:17-19` |
| 3 | 偏好页 = `R.xml.global_preferences`，`FixedLinearLayoutManager` | `ui/SettingsPreferenceFragment.kt:42, 31` |
| 4 | 底部：stats 条 + FAB 默认隐藏 | `MainActivity.kt:320-324` |

### 5.2 菜单项

**工具栏菜单项数 = 0。** 页面所有功能都在偏好项里（下表的 40 项是“设置项”，不是菜单项，单列以便对比）。

### 5.3 偏好分组与条目（`res/xml/global_preferences.xml`，249 行）

| 分组（中文） | 行号 | 条目数 | 条目（key / 中文标题） |
|---|---|---|---|
| 软件设置 | 4-97 | 15 | `isAutoConnect` 自动连接；`appTheme` 主题(ColorPicker)；`nightTheme` 夜间模式；`serviceMode` 服务模式；`tunImplementation` TUN 实现；`mtu` MTU；`speedInterval` 速度通知间隔；`profileTrafficStatistics` 节点流量统计；`showDirectSpeed` 显示直连速度；`showGroupInNotification` 通知显示分组；`alwaysShowAddress` 始终显示地址；`meteredNetwork` 计费网络；`acquireWakeLock` 获取唤醒锁；`logLevel` 日志级别(LongClick)；`globalCustomConfig` 自定义配置 |
| 路由设置 | 99-141 | 7 | `proxyApps` 分应用代理；`bypassLan` 绕过局域网；`bypassLanInCore` 内核内绕过局域网；`trafficSniffing` 启用流量探测；`resolveDestination` 解析目标地址；`ipv6Mode` IPv6；`rulesProvider` 规则资源提供方 |
| DNS 设置 | 143-189 | 7 | `remoteDns` 远程 DNS；`domain_strategy_for_remote` 远程域名解析策略；`directDns` 直连 DNS；`domain_strategy_for_direct` 直连解析策略；`domain_strategy_for_server` 服务器解析策略；`enableDnsRouting` DNS 分流；`enableFakeDns` FakeDNS |
| 入站设置 | 191-207 | 3 | `mixedPort` 代理端口；`appendHttpProxy` 追加 HTTP 代理；`allowAccess` 允许局域网访问 |
| 杂项 | 209-248 | 8 | `connectionTestURL` 连接测试链接(UrlTest)；`enableClashAPI` 启用 Clash API；`networkChangeResetConnections` 网络变化重置连接；`wakeResetConnections` 唤醒重置连接；`globalAllowInsecure` 全局允许不安全；`allowInsecureOnRequest` 允许按需不安全；`appTLSVersion` 订阅最低 TLS 版本；`showBottomBar` 像 SagerNet 一样显示底栏 |
| **合计** | | **40** | 5 类 |

### 5.4 关键交互 / 特判

| # | 交互 | 行为 | 证据 |
|---|---|---|---|
| S1 | 改「主题」 | 立即 `app.setTheme` + `ActivityCompat.recreate`；服务在跑先 `reloadService` | `SettingsPreferenceFragment.kt:44-56` |
| S2 | 改「夜间模式」 | 立即 `Theme.applyNightTheme()`，不重建页面 | `SettingsPreferenceFragment.kt:58-63` |
| S3 | 改「服务模式」 | 若服务已启动 → 先 `stopService` | `SettingsPreferenceFragment.kt:136-139` |
| S4 | 改「启用 Clash API」 | 立即 `(activity as MainActivity).refreshNavMenu(newValue)` → **抽屉 Dashboard 项即时显隐**；并触发 needReload | `SettingsPreferenceFragment.kt:144-149`、`MainActivity.kt:129-134` |
| S5 | **长按「日志级别」** | 弹 “Log buffer size (kb)” 输入框（默认 50），写 `DataStore.logBufSize`，`needRestart()` | `SettingsPreferenceFragment.kt:91-111`（标题硬编码英文，行 101） |
| S6 | 「日志级别」对话框 | 用自定义布局 `layout_loglevel_help` 做说明 | `SettingsPreferenceFragment.kt:86` |
| S7 | 打开「分应用代理」 | `setOnPreferenceChange` 里 `startActivity(AppManagerActivity)` 并置 `dirty=true`，返回值透传 | `SettingsPreferenceFragment.kt:119-124` |
| S8 | 改「速度通知间隔」 | 联动启用/禁用「节点流量统计」(`isEnabled = value != "0"`) | `SettingsPreferenceFragment.kt:126-134` |
| S9 | 改「计费网络」 | API < 28 时**直接 `remove()` 该条目** → 条件可见 | `SettingsPreferenceFragment.kt:115-118` |
| S10 | 改「MTU」 | `MTUPreference` 自带帮助对话框 `layout_mtu_help`（`MTUPreference` 类） | `SettingsPreferenceFragment.kt:82` |
| S11 | 一批“需重载”项 | 统一 `reloadListener` → `needReload()`：mixedPort、appendHttpProxy、showDirectSpeed、trafficSniffing、bypassLan、bypassLanInCore、mtu、enableFakeDns、remoteDns、directDns、enableDnsRouting、ipv6Mode、allowAccess、resolveDestination、tunImplementation、acquireWakeLock、globalCustomConfig | `SettingsPreferenceFragment.kt:34-37, 151-170` |
| S12 | 全局监听 | `MainActivity` 对 `PROXY_APPS / BYPASS_MODE / INDIVIDUAL` 变更 → snackbar「需要重载」+「应用」按钮 | `MainActivity.kt:426-437` |

---

## 6. 日志页 `LogcatFragment`

### 6.1 页面结构

| 序 | 区块 | 证据 |
|---|---|---|
| 1 | AppBar + Toolbar：标题 = **日志** + 右上 2 个图标（第 3 个 always 亦为图标） | `ui/LogcatFragment.kt:31-34` |
| 2 | `ScrollView @id/scroolview`（拼写即如此）+ 可选中 `TextView @id/textview`，外层 padding 8dp | `res/layout/layout_logcat.xml:14-34` |
| 3 | 文本按行着色：含 `INFO[` 或 ` [Info]` → 绿 `0xFF86C166`；含 `ERROR[`/`[Error]`/`WARN[`/`[Warning]` → 红；其它灰 | `LogcatFragment.kt:47-63` |
| 4 | 自动滚到底部（`doOnLayout` 后 `scrollTo(0, height)`） | `LogcatFragment.kt:79-82` |
| 5 | 首屏读 50KB neko 日志 | `LogcatFragment.kt:65-68` |
| 6 | 底部：stats 条 + FAB 默认隐藏 | `MainActivity.kt:320-324` |

### 6.2 右上角菜单（`res/menu/logcat_menu.xml`，3 项；绑定 `LogcatFragment.kt:33-34`）

| # | id | 呈现 | 图标 | 标题 | 行号 |
|---|---|---|---|---|---|
| L-1 | `action_refresh` | `ifRoom` | `ic_baseline_refresh_24` | 更新（`@string/group_update`） | 4-8 |
| L-2 | `action_send_logcat` | `ifRoom` | `baseline_send_24` | 导出调试信息（`@string/logcat`，en: “Export debug information”） | 9-13 |
| L-3 | `action_clear_logcat` | `always` | `baseline_delete_sweep_24` | 清空日志 | 14-18 |

### 6.3 关键交互

| # | 交互 | 行为 | 证据 |
|---|---|---|---|
| LG1 | 刷新 | 重读 50KB 日志并重着色、滚到底 | `LogcatFragment.kt:112-114, 65-83` |
| LG2 | 导出调试信息 | 后台 `SendLog.sendLog(context, "NB4A")`（无进度条、无结果 toast） | `LogcatFragment.kt:105-110` |
| LG3 | 清空日志 | `Libcore.nekoLogClear()` + `logcat -c`，成功后清空 TextView；异常弹 snackbar | `LogcatFragment.kt:87-103` |
| LG4 | 长按/复制 | TextView `textIsSelectable="true"`，可选中复制 | `layout_logcat.xml:32` |

**条件可见**：无。3 项全常驻（无版本/开关依赖）。

---

## 7. 工具页 `ToolsFragment`

### 7.1 页面结构

| 序 | 区块 | 证据 |
|---|---|---|
| 1 | AppBar + Toolbar：标题 = **工具**；**无任何右上角菜单**（全类无 `inflateMenu`） | `ui/ToolsFragment.kt:15`（类体 11-39） |
| 2 | `TabLayout @id/tools_tab`，`tabMode=fixed`，2 个标签：**网络**、**备份** | `res/layout/layout_tools.xml:15-28`；`ToolsFragment.kt:17-29` |
| 3 | `ViewPager2 @id/tools_pager` 承载两个子 Fragment | `layout_tools.xml:30-33`；`ToolsFragment.kt:22` |
| 4 | 子页「网络」= 一张卡片：标题 `STUN 测试` + 说明 + 右下「开始」按钮 | `res/layout/layout_network.xml:8-61`；`ui/NetworkFragment.kt:18-20` |
| 5 | 子页「备份」= 纵向按钮流：恢复默认设置 / 3 个复选框（分组和配置、规则、设置）/ 导出 / 分享 / 说明文本 / 从文件导入 | `res/layout/layout_backup.xml:8-71`；`ui/BackupFragment.kt:62-124` |
| 6 | 底部：stats 条 + FAB 默认隐藏 | `MainActivity.kt:320-324` |

### 7.2 菜单项

**工具栏菜单项数 = 0。** 两个 Tab 由 `TabLayoutMediator` 生成（`ToolsFragment.kt:24-29`），标签文字取 `NamedFragment.name()`（`ui/NamedFragment.kt:10-12`；`NetworkFragment.kt:12`、`BackupFragment.kt:36`）。

### 7.3 关键交互

| # | 交互 | 行为 | 证据 |
|---|---|---|---|
| T1 | 切 Tab | 左右滑动 / 点标签切「网络」「备份」 | `ToolsFragment.kt:22-29` |
| T2 | 长按 Tab | 仅清除长按 toast（`tab.view.setOnLongClickListener { true }`） | `ToolsFragment.kt:26-28` |
| T3 | 「开始」（STUN 测试） | 跳 `StunActivity` | `NetworkFragment.kt:18-20` |
| T4 | 「恢复默认设置」 | 确认框 `reset_settings_message` → `DataStore.configurationStore.reset()` + **整个进程重启**（`ProcessPhoenix.triggerFullRestart`） | `BackupFragment.kt:67-76` |
| T5 | 3 个复选框 | 决定备份内容：分组和配置 / 规则 / 设置（默认全勾） | `layout_backup.xml:16-39`；`BackupFragment.kt:80-84` |
| T6 | 「导出」 | 生成 `nekobox_backup_<日期>.json` → 系统 CreateDocument 选路径 | `BackupFragment.kt:78-91` |
| T7 | 「分享」 | 同一份 JSON 写入 cacheDir → `ACTION_SEND` 分享（`application/json`） | `BackupFragment.kt:93-120` |
| T8 | 「从文件导入」 | 选 `*/*` → 校验 `.json` 与 `version==1` → 弹导入确认（按缺失字段动态隐藏对应复选框）→ 停服务 → 导入 → **进程重启** | `BackupFragment.kt:122-124, 179-263` |

**条件可见**：导入确认框里的 3 个复选框按备份文件实际包含的 `profiles / rules / settings` 动态隐藏（`BackupFragment.kt:219-227`）。

---

## 8. 关于页 `AboutFragment`

### 8.1 页面结构

| 序 | 区块 | 证据 |
|---|---|---|
| 1 | AppBar + Toolbar：标题 = **关于**；**无任何右上角菜单** | `ui/AboutFragment.kt:47`（类体 39-279） |
| 2 | `NestedScrollView` 内：**标题卡**（`NekoBox for Android` + 一句描述） | `res/layout/layout_about.xml:13-55` |
| 3 | `CoordinatorLayout @id/about_fragment_holder`：由 `AboutContent`（MaterialAbout 库）填充 | `layout_about.xml:57-60`；`AboutFragment.kt:49-51` |
| 4 | 底部 **License 卡**：`LICENSE` 资产全文，自动 linkify 邮箱与网址，12sp 可选中 | `layout_about.xml:62-94`；`AboutFragment.kt:53-59` |
| 5 | 底部：stats 条 + FAB 默认隐藏 | `MainActivity.kt:320-324` |

### 8.2 菜单项

**工具栏菜单项数 = 0。** 所有条目都是 MaterialAbout 的**可点击列表项**（不是菜单）：

| 卡 | # | 条目 | 点击行为 | 证据 |
|---|---|---|---|---|
| 卡1 | A1 | 版本（副标题为版本名） | 打开 GitHub Releases 页 | `AboutFragment.kt:80-89` |
| 卡1 | A2 | 检查正式版更新 | 请求 `releases/latest`，有更新弹框，无更新 toast | `AboutFragment.kt:90-96, 214-275` |
| 卡1 | A3 | 检查预览版更新 | 请求 `releases/tags/preview` | `AboutFragment.kt:97-103` |
| 卡1 | A4 | `sing-box 版本`（副标题 `Libcore.versionBox()`） | **无点击动作**（空 lambda） | `AboutFragment.kt:104-110` |
| 卡1 | A5 | 捐款（副标题说明） | 打开 `matsuridayo.github.io/index_docs/#donate` | `AboutFragment.kt:111-121` |
| 卡1 | A6… | **已安装插件** 逐条（`id (exe名)`，副标题 `v<versionName>`） | 跳系统“应用详情”页 | `AboutFragment.kt:122-153` |
| 卡1 | A7 | 忽略电池优化（副标题说明） | 发起 `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`；返回 OK 时重建内容 | `AboutFragment.kt:154-174, 64-72` |
| 卡2 | A8 | Project 卡：源码 | 打开 GitHub 仓库 | `AboutFragment.kt:180-190` |
| 卡2 | A9 | Project 卡：Telegram 更新频道 | 打开 `t.me/MatsuriDayo` | `AboutFragment.kt:191-200` |

### 8.3 关键交互 / 条件可见

| # | 项 | 说明 | 证据 |
|---|---|---|---|
| AB1 | 版本号显示 | `SagerNet.appVersionNameForDisplay`（预览版/正式版不同格式） | `AboutFragment.kt:83`、`SagerNet.kt:205` |
| AB2 | 更新判定 | 预览版/正式版分支不同：`isPreview` 时比 `PRE_VERSION_NAME` 或 `VERSION_NAME`；正式版比 `!releaseName.contains(VERSION_NAME)` | `AboutFragment.kt:231-245` |
| AB3 | **条件项：忽略电池优化** | 仅 `SDK >= M` 且**当前未被忽略**时出现 | `AboutFragment.kt:155-157` |
| AB4 | **条件项：插件条目** | 数量随已安装插件变化；取不到 `METADATA_KEY_ID` 则跳过 | `AboutFragment.kt:124-152` |
| AB5 | 许可证 | 读 `assets/LICENSE`，`Linkify` 处理邮箱与 URL | `AboutFragment.kt:54-57` |

---

## 9. “仅在特定开关下可见”汇总（对比时优先固定这些前置条件）

| 归属 | 条件项 | 触发条件 | 证据 |
|---|---|---|---|
| 抽屉 | `sing-box 仪表板` | `enableClashAPI == true` | `MainActivity.kt:131`；`DataStore.kt:88` |
| 抽屉 | `推广` | `isPlay == false`（非 Google Play 版） | `MainActivity.kt:132`；`ktx/Utils.kt:294` |
| 全局 | stats 条 + FAB 在**非配置页** | `showBottomBar == true` 才保留 | `MainActivity.kt:320-324`；`DataStore.kt:89` |
| 配置 | 分组标签栏 | 分组数 ≥ 2 | `ConfigurationFragment.kt:947-949` |
| 配置 | 编辑/分享/删除 三图标 | select 模式全隐；分享对 chain/nekoBean 隐藏 | `ConfigurationFragment.kt:1610-1617` |
| 配置 | 拖拽排序 | 服务状态 `canStop || Stopped` | `ConfigurationFragment.kt:1183-1186` |
| 配置 | 状态文字可点 | `status == 3` 才绑点击 | `ConfigurationFragment.kt:1583-1592` |
| 分组 | 编辑铅笔 / 更新按钮 / 进度条 | ungrouped 隐藏；非订阅隐藏更新；更新中隐藏两者并显进度 | `GroupFragment.kt:386-387, 413-440` |
| 分组 | 分享订阅子菜单 | 非订阅组整块 `removeItem` | `GroupFragment.kt:406-408` |
| 分组 | 左滑/拖拽 | ungrouped 与更新中禁用 | `GroupFragment.kt:65-73, 75-83` |
| 路由 | 文档警告卡 | 恒在第 0 项；不可滑不可拖 | `RouteFragment.kt:157-160, 53-66` |
| 设置 | 「计费网络」 | `SDK < 28` 直接移除 | `SettingsPreferenceFragment.kt:115-118` |
| 设置 | 「节点流量统计」可用性 | 速度通知间隔 == 0 时置灰 | `SettingsPreferenceFragment.kt:129-134` |
| 设置 | 抽屉 Dashboard 联动 | 改 `enableClashAPI` 立刻重算抽屉 | `SettingsPreferenceFragment.kt:145-149` |
| 工具 | 导入确认框复选框 | 按备份 JSON 缺失字段隐藏 | `BackupFragment.kt:219-227` |
| 关于 | 忽略电池优化 | SDK ≥ M 且尚未忽略 | `AboutFragment.kt:155-157` |
| 关于 | 插件版本条目 | 随已安装插件动态生成 | `AboutFragment.kt:124-152` |
| 全局 | 预览版启动提示 | `FLAVOR == "preview"` | `MainActivity.kt:120-126`；`ktx/Utils.kt:295` |

---

## 10. 速览表

| # | 页面（鸿蒙对应菜单） | Fragment | 顶栏标题 | 工具栏菜单项 | 其中溢出(⋮)可见 | 二级菜单叶子 | 交互数 | 底部条 |
|---|---|---|---|---|---|---|---|---|
| 1 | 配置 | `ConfigurationFragment` | App 名（未 setTitle） | **3** | 1（⋮ 内含 10 叶子） | 30 | 17 | FAB+stats **强制显示** |
| 2 | 分组 | `ui/GroupFragment` | 分组 | **2** | 0 | 0（行内 ⋮ 另有 3 项） | 13 | 默认隐藏 |
| 3 | 路由 | `RouteFragment` | 路由 | **3** | 2（2 项 `never`） | 0 | 9 | 默认隐藏 |
| 4 | 设置 | `SettingsFragment` | 设置 | **0** | 0 | 0（偏好项 40） | 12 | 默认隐藏 |
| 5 | 日志 | `LogcatFragment` | 日志 | **3** | 0 | 0 | 4 | 默认隐藏 |
| 6 | 工具 | `ToolsFragment` | 工具 | **0** | 0 | 0（2 个 Tab） | 8 | 默认隐藏 |
| 7 | 关于 | `AboutFragment` | 关于 | **0** | 0 | 0（列表项 9+动态） | 5 | 默认隐藏 |
| — | 抽屉 | `MainActivity` | — | **10** | — | — | 20（G1–G20） | — |

> “工具栏菜单项”= 该 Fragment 通过 `inflateMenu` 挂上去的 `menu` 顶层 item 数（不含子菜单项）。
> “交互数”= 本文对应章节里逐条编号的交互条目数（配置 C1–C17、分组 GR1–GR11+2 行内容分支、路由 RT1–RT9、设置 S1–S12、日志 LG1–LG4、工具 T1–T8、关于 AB1–AB5）。
> 二级菜单叶子总数（安卓 7 页）= 配置 30（20 添加 + 7 杂项 + 3 排序）+ 其他页 0 = **30**；另有 3 个不属 7 页顶栏的菜单：行内 `profile_share_menu`（6 叶子，`res/menu/profile_share_menu.xml`）、行内 `group_action_menu`（5 叶子，`res/menu/group_action_menu.xml`）、二级页 `profile_config_menu`（6 项但 4 项 `visible="false"`，实际可见仅 删除/应用，`res/menu/profile_config_menu.xml:16-31`；被 `GroupSettingsActivity.kt:322,334` 与 `RouteSettingsActivity.kt:291` 复用）。

---

## 11. 容易对齐错的 5 个安卓细节（纯事实，供对比时核对）

1. **配置页没有独立的“设置/排序”入口**：排序藏在 ⋮ → 排序 三级菜单里，且勾选态由内嵌 `GroupFragment.onResume` 驱动（`ConfigurationFragment.kt:1106,1110-1155`）。
2. **配置页有两套「GroupFragment」**：抽屉的「分组」是 `ui/GroupFragment`（546 行，全量分组管理），配置页内嵌的是 `ConfigurationFragment.GroupFragment`（嵌套类，仅节点列表）。同名不同物（`ConfigurationFragment.kt:1037` vs `ui/GroupFragment.kt:35`）。
3. **配置页禁用了左滑删除**（`getSwipeDirs` 恒 0，`ConfigurationFragment.kt:1176-1181`），但分组页/路由页都启用左滑删除 + 撤销 snackbar。
4. **配置页每行常显「编辑 / 分享 / 删除」三图标**（`removeButton.isGone = select`、`editButton.isGone = select`，`ConfigurationFragment.kt:1612-1613`），XML 默认 `gone` 会被运行时覆盖；真正隐藏这组按钮的只有 select 模式与 nekoBean/chain 条目（`1611-1617`）。删除确认走「snackbar 撤销」而不是对话框（`1602-1608` + `UndoSnackbarManager.kt:37-50`）。
5. **日志页的「更新」按钮复用了 `@string/group_update`**（`res/menu/logcat_menu.xml:7`），「导出调试信息」复用 `@string/logcat`（`logcat_menu.xml:12`）——文案与语义不对应，若按文案逐字对比会误判。
