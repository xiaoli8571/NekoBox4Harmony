# NekoBoxForAndroid → NekoBox4Harmony 功能 / UI 对照清单

> **重新审计声明：以下历史“✅ 1:1 / Android 独有”结论不能作为本次验收依据。** 已在真实源码中发现默认值、分组导航、路由、DNS及UI交互不一致。当前工作清单见 `docs/PARITY-REAUDIT.md`。构建成功不代表功能或UI 1:1；未连接设备，尚未做本轮像素和VPN真机验收。

> 生成时间:2026-09-18(2.0 开发期,持续更新)
> 对照基准:NekoBoxForAndroid(app 模块,`global_preferences.xml` / `group_preferences.xml` / `route_preferences.xml` / `*_preferences.xml` / `menu/*.xml` / `strings.xml` / 主要 Activity 与 Fragment 源码)
> 鸿蒙版本:NekoBox4Harmony 1.9.1(本轮移植后),未签名 HAP 15,298,554 字节,base/en_US 字符串键 598 = 598(双向差异 0)

## 状态图例

| 标记 | 含义 |
|---|---|
| ✅ 1:1 | 已完整复刻,语义/交互/默认值与安卓一致 |
| ⚠️ 近似 | 已实现等价能力,但实现方式或粒度有差异(见说明) |
| ❌ Android 独有 | Android 平台特有,鸿蒙无合理对应能力,明确排除 |
| 🔒 受限 | 有明确技术阻碍,已记录降级方案 |

---

## 一、全局设置(global_preferences.xml)逐项对照

| Android key | Android 默认值 | 鸿蒙字段/实现 | 状态 | 说明 |
|---|---|---|---|---|
| isAutoConnect | false | `AppSettings.autoConnect` | ✅ 1:1 | 启动时自动连接选中节点 |
| appTheme / nightTheme | - / 0 | `appearance`('system'/'light'/'dark') | ✅ 1:1 | 安卓两段式(主题+夜间模式)合并为三态外观 |
| serviceMode | vpn | — | ❌ Android 独有 | 鸿蒙只有 VPN 扩展一种实现,无代理/仅前台服务模式 |
| tunImplementation | 0 | — | ❌ Android 独有 | 鸿蒙 TUN fd 由 VPN 框架注入,无 gvisor/system 选择 |
| mtu | 9000 | `AppSettings.mtu` | ✅ 1:1 | 默认 9000 与钳制上限已对齐安卓(DEF-01,2026-09-18) |
| speedInterval | 1000 | `AppSettings.speedIntervalMs`,钳制 [500,10000] | ✅ 1:1 | **本轮新增**:此前固定 1500ms |
| profileTrafficStatistics | true | `AppSettings.profileTrafficStatistics` + Profile.rx/tx | ⚠️ 近似 | **本轮新增**:鸿蒙无内核级按出站统计,用「单出站会话总量」近似并持久化到节点 |
| showDirectSpeed | true | — | ❌ Android 独有 | 依赖 libcore TAG_BYPASS 出站级统计,鸿蒙内核冻结无此导出 |
| showGroupInNotification | false | `AppSettings.notificationGroup` | ✅ 1:1 | |
| alwaysShowAddress | false | `AppSettings.alwaysShowAddress` | ✅ 1:1 | |
| meteredNetwork | false | — | ❌ Android 独有 | 依赖 VpnBuilder.setMetered,鸿蒙 VpnConfig 无此字段 |
| acquireWakeLock | false | — | ❌ Android 独有 | 鸿蒙 runningLock 需 system_basic 权限;VPN 扩展由系统网络管理服务保活 |
| logLevel | 0 | `AppSettings.logLevel` | ✅ 1:1 | |
| globalCustomConfig | '' | `AppSettings.globalCustomConfig` | ✅ 1:1 | 与根对象浅合并 |
| proxyApps | false | `AppSettings.perAppMode` + `perAppList` + 反选/清除/剪贴板导出导入 | ✅ 1:1 | off/exclude/include 三态;剪贴板 `false\n<pkgs>` 格式对齐 AppListActivity(**本轮新增**) |
| bypassLan | true | `AppSettings.bypassLan` | ✅ 1:1 | 默认值已对齐安卓源码 false(DEF-01,2026-09-18) |
| bypassLanInCore | false | — | ❌ Android 独有 | 由 bypassLan 在 ConfigBuilder 层统一实现 |
| trafficSniffing | 1 | `AppSettings.sniffMode`('off'/'route'/'override') | ✅ 1:1 | 安卓三档 ↔ 鸿蒙三档语义一致 |
| resolveDestination | false | `AppSettings.resolveDestination` | ✅ 1:1 | 1.14 用 rule action:"resolve" |
| ipv6Mode | 0 | `AppSettings.ipv6Mode`(disable/enable/prefer/only,legacy 由 ipv6 布尔推导) | ✅ 1:1 | 四档 Select + TUN 地址段/DNS 策略联动 |
| rulesProvider | 0 | — | ❌ 不适用 | 后两源(Iran/antizapret)为地区专用规则;鸿蒙 cn-only geo 设计下前两源已由 4 个 CDN 镜像容错覆盖 |
| remoteDns | https://dns.google/dns-query | `AppSettings.remoteDns` | ✅ 1:1 | 默认值按鸿蒙网络环境调整为 tcp://8.8.8.8 |
| domain_strategy_for_remote | auto | `AppSettings.remoteDnsStrategy` | ✅ 1:1 | |
| directDns | https://223.5.5.5/dns-query | `AppSettings.directDns` | ✅ 1:1 | |
| domain_strategy_for_direct | auto | `AppSettings.directDnsStrategy` | ✅ 1:1 | |
| domain_strategy_for_server | auto | `AppSettings.serverDnsStrategy` | ✅ 1:1 | **本轮新增**:写入 `route.default_domain_resolver.strategy` |
| enableDnsRouting | true | `AppSettings.dnsRouting` | ✅ 1:1 | CN 域名走直连 DNS |
| enableFakeDns | true | `AppSettings.fakeDns`(默认 false) | ⚠️ 近似 | 默认值差异:鸿蒙默认关闭(真机验证项) |
| mixedPort | 2080 | `AppSettings.mixedPort` | ✅ 1:1 | 默认 2080 对齐安卓 getLocalPort 基值(DEF-01);allowAccess 控制监听地址 |
| appendHttpProxy | false | — | ❌ Android 独有 | 依赖 VpnBuilder.setHttpProxy |
| allowAccess | false | `AppSettings.allowAccess` | ✅ 1:1 | 0.0.0.0 / 127.0.0.1 |
| connectionTestURL | http://cp.cloudflare.com/ | `AppSettings.testUrl` | ✅ 1:1 | 默认迁移到 gstatic 204 |
| enableClashAPI | false | `AppSettings.clashApiEnabled`(默认 true) | ⚠️ 近似 | 鸿蒙流量统计/通知依赖 Clash API,默认开启 |
| networkChangeResetConnections | true | `AppSettings.networkChangeResetConnections` | ✅ 1:1 | 本轮前已实现 |
| wakeResetConnections | false | `AppSettings.wakeResetConnections` | ⚠️ 近似 | **本轮新增**:鸿蒙无屏幕亮灭事件,用「应用回到前台」近似退出 Doze |
| globalAllowInsecure | false | `AppSettings.allowInsecureAll` | ✅ 1:1 | |
| allowInsecureOnRequest | false | `AppSettings.subAllowInsecure` | ✅ 1:1 | 订阅请求放行不安全 TLS |
| appTLSVersion | 1.2 | — | ❌ Android 独有 | 鸿蒙 http 栈由系统管理 TLS 版本 |
| showBottomBar | false | `AppSettings.showBottomBar` | ✅ 1:1 | 开启后 FAB/统计栏在所有页签常驻(对齐安卓跨 fragment 显示) |

---

## 二、分组设置(group_preferences.xml)逐项对照

| Android key | 鸿蒙实现 | 状态 | 说明 |
|---|---|---|---|
| groupName | `ProfileGroup.name` | ✅ 1:1 | |
| groupType | `ProfileGroup.type` | ✅ 1:1 | |
| groupOrder | `ProfileGroup.sortOrder` | ✅ 1:1 | |
| groupIsSelector | `ProfileGroup.isSelector` + 内核 selector 出站(已注册重编 `.so`)+ GroupPage「分组设置」UI | ✅ 1:1 | 组内核生成 selector 出站与全部成员;差异:切成员走配置重建(安卓 Clash API select 免重载热切换,列入开放项) |
| groupFrontProxy / groupLandingProxy | `ProfileGroup.frontProxy/landingProxy` + 「分组设置」Select | ✅ 1:1 | 组内节点出站自动前插/后插代理图(等价安卓组级多跳);节点级链式另有 ChainSettings |
| subscriptionLink | `SubInfo.url` | ✅ 1:1 | |
| subscriptionForceResolve | `SubInfo.forceResolve`(默认 false)+ `connection.getAddressesByName` | ✅ 1:1 | **本轮新增**:更新时把节点域名解析为 IP(5 并发,IPv4 优先),原域名回填 sni 防 TLS 断裂;失败保留域名 |
| subscriptionDeduplication | `SubInfo.deduplication`(默认 false) | ✅ 1:1 | **本轮新增**:此前鸿蒙始终去重,已修正为开关门控 |
| subscriptionUpdateWhenConnectedOnly | `SubInfo.updateWhenConnectedOnly` | ✅ 1:1 | 本轮前已实现 |
| subscriptionUserAgent | `SubInfo.userAgent` | ✅ 1:1 | 本轮前已实现 |
| subscriptionAutoUpdate | `SubInfo.autoUpdate` | ✅ 1:1 | 本轮前已实现 |
| subscriptionAutoUpdateDelay | `SubInfo.updateIntervalHours` | ✅ 1:1 | 本轮前已实现,钳制 [1,720] |

---

## 三、路由规则(route_preferences.xml / RuleEntity)对照

| Android 字段 | 鸿蒙字段 | 状态 | 说明 |
|---|---|---|---|
| routeName | `RouteRule.remark` | ✅ 1:1 | |
| serverConfig | `RouteRule.config` | ✅ 1:1 | JSON 浅合并到规则 |
| routePackages | `RouteRule.packages` → `process_name` | ✅ 1:1 | **本轮新增** |
| routeDomain | `RouteRule.domains` | ✅ 1:1 | **本轮新增**:支持 full:/domain:/keyword:/regexp:/geosite: 前缀,语义与安卓 `makeSingBoxRule` 完全一致 |
| routeIP | `RouteRule.ip` → `ip_cidr` / `rule_set` / `ip_is_private` | ✅ 1:1 | **本轮新增**:支持 geoip:private / geoip:x 前缀 |
| routePort | `RouteRule.port` | ✅ 1:1 | **本轮新增** |
| routeSource | `RouteRule.source` → `source_ip_cidr` | ✅ 1:1 | **本轮新增** |
| routeSourcePort | `RouteRule.sourcePort` → `source_port` | ✅ 1:1 | **本轮新增** |
| routeNetwork | `RouteRule.network` | ✅ 1:1 | **本轮新增** |
| routeProtocol | `RouteRule.protocol` | ✅ 1:1 | **本轮新增** |
| routeOutbound | `RouteRule.outbound` | ✅ 1:1 | proxy / direct / reject / `profile:<id>` 指定任意节点(CORE-05 收尾,规则卡「指定节点」按钮+Select)|
| 旧单类型规则(type+value) | 自动迁移 | ✅ 1:1 | **本轮新增**:`migrateLegacyRule` 加载时迁移并持久化 |
| userOrder(优先级排序) | `moveRule/moveRemoteRuleSet` ↑↓ 按钮 | ✅ 1:1 | **本轮新增**:对齐安卓 ItemTouchHelper 拖拽(鸿蒙用显式按钮,含禁用态边界) |

---

## 四、协议编辑页(*_preferences.xml)对照

| 协议 | 安卓字段 | 鸿蒙覆盖 | 状态 |
|---|---|---|---|
| shadowsocks | name/address/port/method/password/pluginName/pluginConfig/sUoT | 全覆盖(sUoT 除外) | ⚠️ sUoT 为 v2ray 插件特性,sing-box 不支持 |
| standard_v2ray(vmess/vless) | 全套(uuid/alterId/encryption/packetEncoding/传输层/wsEarlyData/TLS/REALITY/uTLS/MUX/ECH) | 全覆盖 | ✅ 1:1 |
| trojan | address/port/password/sni/alpn/certificates/allowInsecure/uTLS/MUX/ECH | 全覆盖 | ✅ 1:1 |
| hysteria2 | address/ports(端口跳跃)/password/obfs/upMbps/downMbps/sni/alpn/TLS | 全覆盖 | ✅ 1:1 |
| tuic | address/port/uuid/password/alpn/certificates/udpRelayMode/congestionControl/disableSNI/reduceRTT/allowInsecure | 全覆盖 | ✅ 1:1 |
| wireguard | address/port/localAddress/privateKey/peerPublicKey/preSharedKey/mtu/reserved | 全覆盖 | ✅ 1:1 |
| ssh | address/port/user/authType/password/privateKey/password1/hostKey | 全覆盖 | ✅ 1:1 |
| shadowtls | address/port/version/password/sni/alpn/certificates/allowInsecure/uTLS | 全覆盖 | ✅ 1:1 |
| anytls | address/port/password/sni/allowInsecure/alpn/certificates/uTLS | 全覆盖 | ✅ 1:1 |
| snell | address/port/password/obfs | 全覆盖 | ✅ 1:1 |
| http / socks | address/port/username/password | 全覆盖 | ✅ 1:1 |
| naive | — | ❌ 内核不支持 | sing-box 无 naive 出站 |
| mieru | — | ❌ 内核不支持 | sing-box 无 mieru 出站 |
| trojan_go | — | ❌ 内核不支持 | sing-box 只有 trojan |
| config(自定义出站) | profileName/isOutboundOnly/serverConfig | 全覆盖(`customOutbound`) | ✅ 1:1 |
| chain(链式代理) | — | 鸿蒙独有增强 | **循环引用防护**(本轮前已实现),比安卓 `testProfileAllowed` 更严格 |
| balancer(负载均衡) | balancerType/balancerStrategy/balancerGroup | — | ❌ 残留页 | 安卓侧该 XML 未接入任何 Activity(无 `R.xml.balancer_preferences` 引用),双方都不可达 |

---

## 五、页面 / 交互对照

| Android 页面/组件 | 鸿蒙对应 | 状态 | 说明 |
|---|---|---|---|
| MainActivity(抽屉式导航) | Index(抽屉 + 底栏/侧栏自适应) | ✅ 1:1 | 抽屉项:配置/分组/路由/设置/日志/工具/关于/文档 |
| ConfigurationFragment(配置页) | `configFragment` | ✅ 1:1 | 节点卡:名称/类型徽标/延迟着色/置顶/分组/地址显示开关/**历史流量**(本轮新增) |
| FAB(连接开关) | `fabButton` | ✅ 1:1 | |
| 底部统计栏 | `statsBar` | ✅ 1:1 | 实时速率 + 累计流量 |
| ProfileFragment(节点列表) | 节点 List + GroupPage | ✅ 1:1 | |
| GroupSettingsActivity | SubDetailPage + GroupPage | ✅ 1:1 | 节点编辑页分组 Select + 节点长按「移动到分组」弹窗(**本轮新增**,对齐安卓 ProfileSettings 分组与多选择移动) |
| RouteSettingsActivity(规则编辑) | RouteRulesPage | ✅ 1:1 | **本轮升级为多字段 AND** |
| AssetsActivity(geo 资产管理) | SettingsPage geo 卡片 + 资产列表 | ⚠️ 近似 | 每库大小/版本展示 + **单库更新/删除**(本轮新增,对齐安卓资产列表);差异:删除无撤销 Snackbar(二次确认代替)、无下拉刷新 |
| ScannerActivity(扫码导入) | `AddEntryDialog → scanImport()`(`scanBarcode.startScanForResult`) | ✅ 1:1 | **本轮新增**:系统扫描 UI(无需相机权限),仅识别 QR 码(对齐安卓 `QRCodeAnalyzer`),结果复用 doImport 管道(容器/订阅/分享链接 + 导入确认);用户取消静默返回 |
| 分享节点二维码 | `generateBarcode.createBarcode` + PixelMap 展示 | ✅ 1:1 | **本轮升级**:此前误判 SDK 无 ScanKit 而只做文本降级;现弹窗真实渲染二维码,生成失败自动回退文本+复制 |
| LogcatFragment(日志) | LogPage | ✅ 1:1 | 本轮前双语化 |
| TrafficFragment(流量统计) | ConnectionsPage | ✅ 1:1 | host/network/rule/chains/↑↓/关闭连接 |
| ToolsFragment(工具) | ToolsPage | ✅ 1:1 | STUN 探测/备份恢复(文件+剪贴板)/恢复出厂 |
| AboutFragment(关于) | AboutPage | ✅ 1:1 | **本轮新增交流群入口** |
| BackupFragment | 备份/恢复(事务化) | ✅ 1:1 | 校验+快照回滚+结果统计 |
| StunActivity | STUN 卡片 | ✅ 1:1 | cone/symmetric 检测 |
| ConfigEditActivity(配置编辑) | ProfileEdit(自定义出站 JSON) | ✅ 1:1 | |
| QuickToggleShortcut / QuickEnable / QuickDisable | — | ❌ Android 独有 | 桌面快捷方式需 module.json5 注册 scheme(当前阶段冻结该文件) |
| onBackPressedDispatcher | `onBackPress`(@Entry 生命周期) | ✅ 1:1 | **本轮新增**:抽屉→收;非配置页→回配置页;配置页→退桌面(VPN 不断) |
| 常驻通知(含断开按钮) | notificationManager 常驻通知 | ✅ 1:1 | 显示节点/分组/延迟/速率/累计流量 + 断开操作 |

---

## 六、本轮(2026-09-17 ~ 09-18)移植成果汇总

共 19 项功能 + 1 项交付物(对照清单),全部 `BUILD SUCCESSFUL`、字符串键双向差异 0、HAP 已重新生成。

| # | 功能 | 对齐 Android | 关键改动 |
|---|---|---|---|
| 1 | 系统返回键行为 | `onBackPressedDispatcher` | Index `onBackPress` 生命周期方法 |
| 2 | 导入自定义 Geo 数据文件 | `AssetsActivity.action_import_file` | `importGeoAssetFromFile`(DocumentViewPicker + 文件名校验 + 版本标记) |
| 3 | 回到前台时重置连接 | `wakeResetConnections` | `VPN_EVENT_APP_FOREGROUND` IPC + 扩展进程重连 |
| 4 | 通知刷新间隔可设置 | `speedInterval` | `speedIntervalMs`,钳制 [500,10000] |
| 5 | 每节点流量统计与持久化 | `profileTrafficStatistics` | Profile.rx/tx + 会话结束累加 + 节点卡显示 |
| 6 | 代理服务器域名解析策略 | `domain_strategy_for_server` | `serverDnsStrategy` → `default_domain_resolver.strategy` |
| 7 | 路由规则多字段 AND 模型 | `RuleEntity` + `makeSingBoxRule` | 9 字段模型 + 前缀语义 + 旧规则迁移 |
| 8 | 订阅更新去重开关 | `subscriptionDeduplication` | `SubInfo.deduplication` 门控去重 |
| 9 | 功能/UI 对照清单(交付物) | — | `PARITY.md`(本文件) |
| 10 | 扫码导入 | `ScannerActivity`(zxing) | `AddEntryDialog` 新增「扫码添加」→ `scanBarcode.startScanForResult` 系统扫描 UI → 复用 `doImport` 管道;取消(code 1000500002/12900010)静默 |
| 11 | 分享二维码生成 | `QRCodeDialog` + zxing `MultiFormatWriter` | 修正「SDK 无 generateBarcode」误判:`@kit.ScanKit.generateBarcode.createBarcode` → PixelMap,节点分享弹窗 + 订阅分享弹窗(`GroupFragment.action_universal_qr`)均真实渲染二维码,失败自动回退文本+复制 |
| 12 | 订阅强制解析 | `GroupUpdater.forceResolve` + `rewriteAddress` | `SubInfo.forceResolve`(默认 false)+ `connection.getAddressesByName`(5 并发,IPv4 优先),原域名回填 sni 防 TLS 断裂;失败保留域名 |
| 13 | 从文件导入(含 WireGuard zip) | `ConfigurationFragment.action_import_file` + zip 分支 | `importFromFile()`:DocumentViewPicker(任意文件,同安卓 `*/*`)→ 文本走 doImport 全管道;`.zip` 解压逐 entry 解析、entry 名作节点名、单次确认批量导入;空结果/失败均明确提示 |
| 14 | 路由规则优先级调整 | `RouteFragment` ItemTouchHelper 拖拽 | `moveRule`/`moveRemoteRuleSet` ↑↓ 按钮(自定义规则与远程规则集两张列表),边界禁用 |
| 15 | 分应用列表剪贴板导出/导入 | `AppListActivity` export/import clipboard | `false\n<包名>` 同格式;导入校验无换行即报错;导出/导入后走既设自动重启链路 |
| 16 | 节点归属分组管理 | ProfileSettings 分组 Preference + 多选择移动 | 节点长按菜单「移动到分组」弹窗(未分组+全部组,当前高亮)+ ProfileEdit 基础区分组 Select |
| 17 | IPv6 四档 + showBottomBar | `ipv6Mode` / `showBottomBar` | 四档模式(disable/enable/prefer/only,legacy 兼容布尔)+ FAB/统计栏跨页签常驻开关 |
| 18 | 规则指定节点出站 UI + 分组设置 UI | CORE-05 收尾 / CORE-06 收尾 | 规则卡「指定节点」+Select(`profile:<id>` 后端已有);GroupPage「分组设置」selector 开关 + 前/落地代理 Select(内核注册/图构建后端已有),保存即自动重载 |
| 19 | DEF-01 默认值对齐 | `DataStore.kt` | mtu 1400→9000(钳制同步)、mixedPort 0→2080、bypassLan true→false;仅新装生效,DEF-02 DoH/FakeIP 按平台能力口径保留并注释 |

**验证记录**:Node 脚本逻辑检查 14(geo 导入) + 10(间隔钳制) + 9(流量累加) + 18(规则解析与迁移) + 15(强制解析 IP 判定/SNI 改写) + 25(移动 swap/entry 名剥离/sn:// 识别/剪贴板格式) = **91 项全部通过**;更早会话另有订阅设置 9 项 + 链式循环 9 项检查通过。

---

## 七、明确排除项(Android 独有 / 不适用)

| 项目 | 排除理由 |
|---|---|
| serviceMode / tunImplementation | 鸿蒙只有 VPN 扩展一种实现 |
| appTLSVersion | 系统 http 栈管理 TLS |
| QuickToggle/Enable/Disable 桌面快捷方式 / QS Tile | 安卓 launcher pin + Quick Settings Tile 平台表面;鸿蒙对应需 FormExtensionAbility + module.json5 注册(当前冻结) |
| sn:// universal link(单节点/订阅容器) | SagerNet Kryo 私有二进制序列化,鸿蒙无等价序列化能力;导入侧已识别 `sn://` 前缀明确拒绝提示,分享侧用标准链接 + 二维码等价 |
| yacd 网页面板 | 安卓随包 yacd 静态资源;鸿蒙以原生 ConnectionsPage 等价覆盖(连接/速率/关闭),不捆绑第三方 web 资源 |
| meteredNetwork | `VpnBuilder.setMetered` 无对应 |
| appendHttpProxy | `VpnBuilder.setHttpProxy` 无对应 |
| acquireWakeLock | runningLock 需 system_basic 权限 |
| showDirectSpeed | libcore TAG_BYPASS 出站级统计,内核冻结 |
| rulesProvider 后两源 | 地区专用规则库(Iran/antizapret),与 cn-only geo 设计冲突 |
| naive / mieru / trojan-go 协议 | sing-box 内核不支持 |
| balancer_preferences.xml | 安卓侧未接入任何 Activity,双方均不可达 |
| ignoreBatteryOptimizations | 安卓 Doze 权限申请,鸿蒙无对应 |

---

## 八、已知限制与待真机回归项

### 受限未实现(有明确技术阻碍)

1. **selector 免重载热切换(安卓 groupIsSelector 行为)**:内核 selector 出站已在 `lean_context.go` 注册并重编入 `.so`(2026-09-18),ConfigBuilder 生成组级 selector 出站、GroupPage「分组设置」可开关;但鸿蒙切换组内成员仍走配置重建(`VpnService.switchTo`),安卓则经 Clash API `select` 免重载。功能等价、性能有差,列为开放项。
2. **外部 Scheme 注册**:`clash:///`、`sn://` 的深度链接入口需修改 `module.json5`(该文件当前阶段冻结);解析能力(`clash://install-config` 解包、`sn://` 降级提示)已在代码内就绪,仅需注册即可激活。
3. **showDirectSpeed / 内核级每节点流量**:依赖 libcore/内核按出站打标签统计(`setV2rayStats`),冻结 .so 无对应导出;已用「单出站会话总量 + 落盘累加」近似 `profileTrafficStatistics`(见第一节)。
4. **唤醒重置连接的粒度**:安卓在设备退出 Doze 闲置模式即重置;鸿蒙无屏幕亮灭事件订阅(`@ohos.screen` 不存在,`@ohos.power` 仅 `isScreenOn` 查询),退化为「应用回到前台时重置」(见第一节 `wakeResetConnections`)。

### 真机回归清单(本轮新增功能)

| 功能 | 验证点 |
|---|---|
| 返回键 | 连接 VPN 后按返回退到桌面,通知仍显示已连接;非配置页按返回回配置页 |
| Geo 导入文件 | 导入 geoip.db 后重连 cn 分流仍生效;取消选择不报错;错误文件名被拒 |
| 回前台重置 | 开启开关后切后台再回前台触发一次重连;关闭后不重连 |
| 通知刷新间隔 | 填 500/10000/越界值后重连,刷新频率正确 |
| 节点流量统计 | 产生流量后断开,节点卡出现累计;再连再断只增不减;关开关后不累加 |
| 服务器域名策略 | 设 ipv4_only 后 IPv6-only 服务器解析失败(符合预期) |
| 路由规则多字段 | 旧规则升级后行为不变;新建「域名+端口」组合规则生效 |
| 订阅去重 | 含重复节点的订阅,开关开/关两种状态下数量符合预期 |
| 扫码导入 | 添加菜单「扫码添加」唤起系统扫描;扫订阅二维码走订阅导入,扫节点链接走单节点导入;按返回取消不报错 |
| 分享二维码 | 节点长按分享、订阅详情页分享均显示可扫描二维码;文本仍可复制 |
| 订阅强制解析 | 开关开启后更新,域名节点服务器被改写为解析到的 IP,原域名出现在 SNI 字段,TLS 节点仍可连通;解析失败的节点保留域名 |
| 从文件导入 | 选 .txt/.json/.conf 走完整导入管道(订阅 base64/分享链接/sing-box JSON);选 WG 导出 zip 逐 entry 导入且名称为文件名;乱码文件报「未找到可用节点」 |
| 规则优先级 | ↑↓ 按钮改变规则与远程规则集顺序,首/末位按钮置灰;重排后重连内核分流顺序正确 |
| 分应用剪贴板 | 导出格式 `false\n包名列表`;导入他机复制的列表整体替换;无换行内容报导入失败 |
| 移动到分组 | 节点长按菜单移组即时生效,列表按新分组重渲染;编辑页分组 Select 保存后生效 |
| geo 单库管理 | 单库更新仅替换该库;删除后状态转「未下载」,规则模式 cn 分流自动跳过,其余流量正常 |
| IPv6 四档 | disable 无 v6 地址;only 仅 v6 段;prefer/only 与 DNS 策略组合行为正确 |
| showBottomBar | 开启后统计栏与 FAB 在分组/路由/设置等页签可见;关闭仅配置页显示 |
| 分组设置(CORE-06) | 开启 selector 后重连,内核配置含 selector 出站与全部成员;切换组内成员可连通;设前/落地代理后出站图含 hop 且流量路径正确;运行中保存触发自动重载 |
| 规则指定节点(CORE-05) | 规则选出站→指定节点选 A,命中域名走 A;删除节点 A 后规则显示「节点已删除」且被构建跳过,不误转 proxy |
| DEF-01 新装默认 | 全新安装 MTU=9000、mixed=2080、bypassLan=关;升级用户设置不被改写 |

---

## 九、构建与交付物

- 构建命令(仓库根目录):
  ```
  $env:PATH='C:\Program Files\Huawei\DevEco Studio\jbr\bin;' + $env:PATH
  $env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
  node hvigorw.js --mode module -p product=default assembleHap --no-daemon
  ```
- 成功标志:`> hvigor BUILD SUCCESSFUL` + `EXIT=0`
- 版本:**2.0.1(versionCode 2000001)**,统一于 `AppScope/app.json5`(关于页动态读取 bundleManager,无其它版本字面量)
- 带签名交付物:**`dist/NekoBox-2.0.1-signed.app`**(13,608,082 字节,2026-09-18 12:10:51,SHA256 A2DDC21ABD74F7A13FC7FC6A1C235F66476E7184E5F08C3AAD70FA946CEDF265;hap-sign-tool 双层签名(内层 HAP + .app 外壳),verify-app 通过,profile type=release、bundle com.nekobox.app.jynxen,与 1.9.x 同签名身份可覆盖升级)
- 未签名产物:`entry/build/default/outputs/default/entry-default-unsigned.hap`(15,298,554 字节 @ 11:27:37)与 `build/outputs/default/*-default-unsigned.app`
- 国际化:base(中文)/ en_US(英文)字符串键 598 = 598,`Compare-Object` 双向差异 0;UI 硬编码文案扫描 0 命中
- 文档:CHANGES.md(逐项改动记录)、DEVPLAN.md(任务状态与真机验证点)、docs/PARITY-REAUDIT.md(严格复审计与闭环记录)、本文件(PARITY.md)
