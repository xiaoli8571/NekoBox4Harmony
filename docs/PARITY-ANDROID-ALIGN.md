# NekoBox4Harmony 安卓端 1:1 对齐分析报告

> 基准：MatsuriDayo/NekoBoxForAndroid v1.4.2（commit 5768494，本地副本 C:\Worker\rea-tmp\nb4a）
> 对象：C:\Worker\NekoBox4Harmony v2.0.1
> 结论：核心转发/配置构建层已高度对齐；剩余差距集中在 **UI 结构层** 与少量交互细节。

## 一、安卓端完整功能清单（逆向结果）

### 1. 主界面与导航（MainActivity）
- 抽屉菜单顺序：nav_configuration / nav_group / nav_route / nav_settings / misc 分隔 / nav_logcat / nav_traffic / nav_tools / nav_tuiguang（!isPlay 显示）/ nav_faq（文档）/ nav_about。
- `refreshNavMenu`：nav_traffic 可见性 = enableClashAPI；nav_tuiguang = !isPlay。
- 默认页 nav_configuration；onNewIntent 处理扫码/剪贴板/文件导入意图。
- 回调：cbSpeedUpdate / cbTrafficUpdate / cbSelectorUpdate / onPreferenceDataStoreChanged；changeState 状态机（onServiceConnected/Disconnected/BinderDied）。
- displayFragmentWithId 映射：configuration→ConfigurationFragment、group→GroupFragment、route→RouteFragment、settings→SettingsFragment、traffic→WebviewFragment（yacd）、tools→ToolsFragment、logcat→LogcatFragment、about→AboutFragment。

### 2. 配置页（ConfigurationFragment）— 差距最大
- **TabLayout + ViewPager2 分组分页**（group_pager/group_tab），offscreenPageLimit=2，翻页写 DataStore.selectedGroup；空"未分组"组仅当有节点才显示；无组自动创建 ungrouped。
- PROFILE_GROUP 变更自动切页；toolbar 点击滚动到选中节点。
- 搜索 onQueryTextChange→当前组 adapter.filter。
- 导入文件 \*/\*：.zip 逐 entry 走 RawUpdater.parseRaw(text, entry.name)，SubscriptionFoundException 转订阅导入。
- 测速 TestDialog：进度列表对话框 + 可最小化→ConnectionTestNotification 常驻通知 + 可取消（取消保存已测结果 + GroupManager.postReload）。
- TCPing：concurrent=DataStore.connectionTestConcurrent，域名解析→socket 3000ms，错误分类 timeout/refused/unreachable。
- urlTest 在 UI 进程执行。
- action_delete_unavailable：确认后删 status∉{0,1}。
- remove_duplicate：Protocols.Deduplication 判重 + 确认对话框（列表前 20 项+"......"）。
- 菜单 add_profile_menu（search/add/scan_qr_code/import_clipboard/import_file/全部 19 协议新建/config/chain/update_subscription/clear_traffic_statistics/remove_duplicate/connection_tcp_ping/connection_url_test/connection_test_clear_results/connection_test_delete_unavailable/order_origin/order_by_name/order_by_delay）。

### 3. 分组页（GroupFragment）
- add_group 菜单（new_group / update_all）；16 键 group_preferences（groupName/type/order/isSelector/frontProxy/landingProxy/subscription 子组 8 键）。

### 4. 路由页（RouteFragment）
- add_route_menu：new_route / reset_route / manage_assets。
- RecyclerView + ItemTouchHelper（swipe 删除 + drag 排序，undo）；RuleEntity 增删改监听实时刷新。

### 5. 设置页（global_preferences 40 键）
全部键已逐项提取（isAutoConnect、appTheme、nightTheme、serviceMode、tunImplementation、mtu、speedInterval、profileTrafficStatistics、showDirectSpeed、showGroupInNotification、alwaysShowAddress、meteredNetwork、acquireWakeLock、logLevel、globalCustomConfig、proxyApps、bypassLan、bypassLanInCore、trafficSniffing、resolveDestination、ipv6Mode、rulesProvider、remoteDns/directDns/domain_strategy 四项、enableDnsRouting、enableFakeDns、mixedPort、appendHttpProxy、allowAccess、connectionTestURL、enableClashAPI、networkChangeResetConnections、wakeResetConnections、globalAllowInsecure、allowInsecureOnRequest、appTLSVersion、showBottomBar）。

### 6. 协议编辑页（17 个 SettingsActivity）
vmess / vless(standard_v2ray) / trojan / shadowsocks / socks / http / hysteria / tuic / wireguard / ssh / naive / mieru / trojan_go / shadowtls / anytls / chain / config 编辑 — 全部键已提取（vless reality/utls/mux/ech 全套；hysteria ports/hopInterval/收发窗口/mtu 探测；ssh password1；socks sUoT；naive headers/InsecureConcurrency 等）。

### 7. 工具页（ToolsFragment）
- TabLayout+ViewPager2 双页：NetworkFragment（Stun 测试入口）+ BackupFragment。
- NetworkFragment：binding.stunTest → StunActivity（natStunServer 输入 → Libcore.stunTest → natResult 显示，waitLayout 加载态）。
- BackupFragment：
  - resetSettings：确认对话框 → configurationStore.reset() + triggerFullRestart。
  - actionExport：三复选（backupConfigurations/backupRules/backupSettings）→ doBackup → CreateDocument "nekobox_backup_<date>.json"。
  - actionShare：同 doBackup → cache 文件 + FileProvider 分享 application/json。
  - doBackup：JSON version=1 + profiles/groups/rules/settings 各 JSONArray，元素为 Parcelable.toBase64Str()（Parcel marshall + b64EncodeUrlSafe）。
  - startImport：文件名须 .json（否则 backup_not_file snackbar）；version 必须==1；LayoutImportBinding 弹窗按内容显隐三类复选 → finishImport。

### 8. 日志页（LogcatFragment）
- logcat_menu：clear / send（分享）/ refresh；getColorForLine 按级别着色；reloadSession。

### 9. 流量仪表盘（WebviewFragment）
- layout_webview + yacd_menu；loadUrl(DataStore.yacdURL)；菜单可编辑并保存 yacdURL 后重载；domStorage+js 启用；debug 构建开启 WebView 调试。

### 10. 分应用代理
- AppListActivity（routePackages 数据源）+ AppManagerActivity（individual 数据源），均含 invert_selections / clear_selections / export_clipboard / import_clipboard 四操作；按首字母 sectionName 分组 + Filter 搜索。

### 11. 扫码（ScannerActivity）
- 相机扫码 + 手电筒；scanner_menu action_import_file（图片识别）；支持多结果回调。

### 12. 其余
- ProfileSelectActivity（layout_empty + fragment_holder，returnProfile 回传）；AssetsActivity（import_asset_menu）；QuickEnable/DisableShortcut；StunActivity。

### 13. 核心构建（ConfigBuilder.kt 755 行）— 已对齐项与精确语义
- buildConfig(proxy, forTest, forExport)→{config, externalIndexMap, index, trafficMap, tagMap, selectorGroupId}。
- selector 模式：组内每节点 buildChain→g-<id> 出站 + Outbound_SelectorOptions(tag=proxy, default_=tagMap[proxy.id])。
- resolveChain：ChainBean 递归 asReversed + frontProxy append + landingProxy insert(0)。
- 链 tag：末位 g-<id>；chainId==0&&index==0→"proxy"；selector 首位 selectorName 去重。
- 外部出站：socks 127.0.0.1:mkPort + direct mapping inbound + route rule inbound→direct；mux 首跳一次；sUoT 反射 udp_over_tcp。
- 用户规则：port/port_range、source_port 按":"、network、source_ip_cidr、protocol 数组、user_id、makeSingBoxRule 前缀。
- rule.outbound 分派：-1→dns-direct/TAG_BYPASS；0→(fakeip dns-fake tun-in)+dns-remote/TAG_PROXY；-2→dns-block + TAG_BLOCK(reject)；>0→tagMap[outId]，缺失 Toast 告警且规则不入。
- DNS servers 四层：dns-block(rcode://success) / dns-local(local,detour direct) / dns-direct(address_resolver dns-local) / dns-remote(final)；enableDnsRouting→userDNSRuleList 入 dns.rules。
- 内置路由：53 端口+dns 协议 hijack-dns；bypassLanInCore→ip_is_private；224.0.0.0/3+ff00::/8 mcast reject。
- FakeIP：inet4 198.18.0.0/15、inet6 fc00::/18、dns-fake ipv4_only、tun-in 规则 disable_cache。
- 防回环：outbound=any→dns-direct 置顶；domainListDNSDirectForce→dns-direct 最顶。
- globalCustomConfig 深合并（+key 前插 / key+ 追加 / 递归覆盖）+ 节点 customConfigJson。
- TUN：stack 三档、endpoint_independent_nat、mtu、sniff/sniff_override==2、IPv6 四档地址段；mixed：allowAccess→0.0.0.0；clash_api 127.0.0.1:9090 + external_ui ../files/yacd。
- genDomainStrategy / autoDnsDomainStrategy 精确映射（DISABLE→ipv4_only、PREFER→prefer_ipv6、ONLY→ipv6_only、空→null）。

## 二、与鸿蒙版差距（按优先级）

### P0 — UI 结构层（1:1 差距主体）
1. **UI-01 分组分页**：ConfigurationFragment 需改为 Tabs + 分页（鸿蒙 Tabs 组件替代 TabLayout+ViewPager2），翻页写 selectedGroup、空"未分组"条件显示、搜索作用于当前页。
2. **UI-02 节点卡三层信息/行内操作**：对齐 layout_profile 大卡（地址/流量/测速行内展示 + 编辑/分享/删除快捷操作）。
3. **UI-03 StatsBar 三行式**：状态/上下行/累计流量三行 + 测速结果状态；对齐 cbSpeedUpdate/cbTrafficUpdate 刷新。
4. **UI-04 抽屉次序与条件仪表盘**：抽屉项顺序按 §1.1 对齐；nav_traffic（yacd）受 enableClashAPI 控制显隐。
5. **UI-05 测速入口与作用域**：独立 TCP/URL 分测 + 子菜单（clear_results / delete_unavailable / order 三排序）+ 组作用域（鸿蒙多处 __all__ 需改当前组）。
6. **UI-06 主题/颜色/延迟着色**：延迟着色阈值/可用色对齐安卓（鸿蒙现为 150/400）。

### P1 — 功能补齐
7. **CORE-07 JSON 深合并**：+key 前插 / key+ 追加 / 递归合并三种语义（Util.mergeMap 精确行为）。
8. **CORE-08 用户规则**：优先于 LAN 直连规则；单独拒组播 224.0.0.0/3+ff00::/8。
9. selector 热切换：cbSelectorUpdate 免配置重载路径。
10. 测速 TestDialog 形态：可最小化为常驻通知 + 取消保存已测结果。
11. 备份导入：version==1 严格校验 + 按内容显隐复选（若鸿蒙已有备份，补齐此交互）。
12. 连接测试并发 connectionTestConcurrent + TCPing 3000ms 超时 + 错误分类文案。

### P2 — 已声明差异（保留）
- DEF-02：DoH/FakeDNS 默认值差异（鸿蒙有意保留）。
- 真机整包像素验收：待真机连接后执行。

## 三、已对齐确认（不再改动）
端口范围、DNS auto 归一化、resolve 顺序、rule_set 引用、用户 DNS 分流+FakeIP、IPv6 四档、sniff override 内核补丁、协议多值、任意 profileId 出站 UI、组级 selector/front/landing proxy UI、DEF-01 默认值（mtu 9000/mixedPort 2080/bypassLan false）、扫码导入、二维码分享、订阅强制解析/去重、WG zip 导入、规则排序、剪贴板分应用、移动到分组、geo 管理、返回键、每节点流量持久化、通知刷新间隔、回前台重置、showBottomBar。
