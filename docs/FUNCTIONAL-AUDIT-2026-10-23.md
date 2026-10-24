# NekoBox 功能审计：测速、分应用、路由及 sing-box 常用功能

日期：2026-10-23。审计目录：`C:/Worker/NekoBox4Harmony`。构建产物实际版本为 **2.2.1 / 2200001**，内核为仓库分发的 sing-box 1.14 OHOS 库。旧交接文档的 2.2.0 版本描述已落后于当前文件。

**结论：主机功能审计及本轮修复已完成，仍有重要功能缺口，不能判定全功能真机通过。** 当前 `hdc list targets` 返回 `[Empty]`。本次没有安装、发布、提交或推送；保留工作区原有修改，没有改内核、权限、签名配置或版本号。

## 1. 本轮已修复

| 项目 | 修复前的触发条件与影响 | 本轮处理与验证 |
|---|---|---|
| 测速保存覆盖节点改动 | 测速结束 `saveProfiles(this.profiles)` 全量回写旧快照；测试期间的订阅更新、编辑、删除可能被覆盖 | 按 ID 只合并完成的测试结果到最新存储列表，走 `mutateProfiles`；生产页面方法测试验证新增保留、编辑保留、删除不复活、未测结果保留 |
| 保存异常导致后续无法测速 | `finally` 中保存失败后执行不到 `testing=false` | 独立捕获保存错误、保留提示，内层 `finally` 必定释放测速标志；注入磁盘失败验证 |
| 测速配置写盘异常未进入降级分支 | 生成配置的 catch 未覆盖 `writeTestConfigFile` | 写盘并入异常处理，错误原因可见，明确回退 TCPing；注入写盘失败验证 |
| 降级提示被覆盖 | 回退 TCPing/取消物理网卡绑定后没有持久可见说明，随后“完成”toast 覆盖前一个提示 | 补绑定回退的中英文提示，并抑制紧随其后的普通完成提示；两条分支均执行生产方法验证 |
| 当前节点测速出现假 0ms | API 返回 `delay:null`、空串、false 时 `Number()` 转成 0，负数也被接受 | 只接受非负有限数值；null、空串、布尔值、负数、溢出数值全部拒绝，HTTP 资源仍释放 |
| 分应用保存失败仍重启 VPN | 设置页 `save()` 吞掉存储错误，调用方继续切换 VPN，实际运行旧名单 | 保存返回成功标志，失败保留 dirty 状态并停止重启；执行真实 save/persistPerApp 方法验证 |
| 域名/IP多行规则与正则被改写 | DNS 支持按行拆分，路由却只按逗号；所有域名项转小写把正则 `\D` 改成 `\d`、改变大小写语义 | 统一域名、目的 IP、源 IP 等规则列表的逗号/换行拆分；路由和 DNS 都保留正则原文；测试覆盖多行 AND 字段及正则转义 |
| 规则按钮高亮不刷新/输入焦点丢失 | 远程卡 key 只有 ID；自定义规则 key 不含出站/网络等状态，却含输入中的备注 | key 包含离散状态及顺序，排除逐字输入的名称/URL/备注/更新时间；既有 UI 回归测试恢复通过 |

主要改动：`pages/Index.ets`、`pages/SettingsPage.ets`、`pages/RouteRulesPage.ets`、`utils/LatencyTester.ets`、`utils/ClashApi.ets`、`core/ConfigBuilder.ets`、中英文资源。

另在路由页包名输入框下增加平台能力提示。它只是纠正界面承诺，**没有把按包名指定出站变成可用功能**。

## 2. 仍需处理的问题

### P1：分应用“仅这些应用”零勾选时，实际全部应用进入 VPN

证据：`entry/src/main/ets/vpnext/VpnExtAbility.ets:514-525`。名单为空时不写 `trustedApplications`，日志明确说“全部应用按路由规则处理”。这与“仅这些应用”在空选择下的直觉不一致。

复现：设置 include 模式 → 取消所有勾选 → 重连 → 配置没有 trusted/blocked 名单。此结论来自构建分支及 SDK 接口契约；具体应用的真实流量尚未真机抓取。

后续应定义空名单策略：连接前阻止并说明，或显式表示不代理任何应用。不能把空数组直接视为已经解决，系统对空名单的语义仍须设备验收。

### P1：远程 SRS 首次下载失败会阻止整个 VPN 启动

证据：`ConfigBuilder.ets:1158` 直接输出 remote 定义；内核 `route/rule/rule_set_remote.go:132-135` 将首次下载错误上抛。

已用本地 HTTP 503、无缓存真实内核启动复现：

```text
initialize rule-set[0]: initial rule-set: remote_audit: unexpected status: 503 Service Unavailable
```

这与旧 DEVPLAN 中“失败跳过不影响启动”的描述不符。后续应增加下载校验、可靠缓存和明确的失败策略；静默丢弃拒绝/代理规则会改变用户路由策略，不应未经说明自动绕过。

### P1：一个内核 schema 错误节点仍可能影响整批 URL Test

证据：`ConfigBuilder.ets:1355` 的整批配置仅隔离 JS 构建阶段抛错；节点 extra/custom JSON 中错误类型等仍可能通过构建。`core/libsingbox14/main.go` 统一解析并启动整批 box。

真实内核复现：正常 SOCKS 节点单独启动成功，加入 `server_port:"invalid"` 的节点后整批解析失败。当前业务随后明确回退 TCPing：坏节点影响了好节点的测试方法；QUIC/WireGuard 等无法 TCPing 的节点也无法在这一回退中补齐结果。

本轮修复了降级说明和异常收尾，**未实现每节点 schema 验证或逐节点 URL Test 隔离重试**。

### P1／平台缺口：路由页按包名指定出站没有鸿蒙实现

`ConfigBuilder.ets:548-550` 把 packages 转成 `process_name`。内核该匹配器读取连接归属的进程路径 basename，并不会把鸿蒙 bundleName 自动当作包名查找。包装层也没有提供鸿蒙 connection owner finder。新规则默认 `packagesEnabled=false`，界面又没有对应开关，因此新填写内容还可能根本不进入内核。

应使用的现有能力是设置页 **分应用代理**：Want 传名单 → 扩展强制刷新 Preferences → `trustedApplications` / `blockedApplications`。这能决定哪些应用进入 VPN，不能实现“不同应用分别指定不同代理节点”。本轮保留旧数据并增加明确提示。

官方也把 `process_name` 和 Android `package_name` 列为不同平台能力，不能简单替换字段名修好：[sing-box Route Rule](https://sing-box.sagernet.org/configuration/route/rule/)。

### P2：不同测速入口的成功判据并不一致

- 手动批量 URL Test：`AppSettings.testExpectStatus='any'`，收到 403/404/500 也会成功。它证明得到响应，不证明目标页面正常可用。
- 严格 2xx 参数已由 V2 导出支持，但当前设置界面没有对应选项。
- 自动 urltest 组及运行实例 Clash delay 使用内核默认严格策略，与手动批量默认值不同。
- TCPing 只测试服务器 TCP 握手，不验证代理认证、UDP/QUIC通路或目标网站；TCPing 的 3000ms 不包含前置系统 DNS 解析耗时。
- 本轮用本地 HTTP 200/204/302/403/404/500 验证 any/2xx 两种判据；405/501 的 HEAD → GET 回退也已验证。

保留现有默认值，避免未经要求改变之前的 Android 对齐口径。建议后续把判据明确呈现在设置及结果中。

### P2：规则集状态显示不是下载状态

`RouteRulesPage.updateRemoteRuleSet` 每次编辑设置 `updatedAt=Date.now()` 并清空 `lastError`，没有接入内核真实下载状态。显示的“更新时间”实际上是编辑时间；下载错误不会可靠反映在该字段。site/ip 按钮也只是本地分类，不会转换或验证 SRS 内容。

### P2：组播拒绝规则实际是源和目的同时匹配

`ConfigBuilder.ets:1097-1101` 在同一规则内同时写 `ip_cidr` 和 `source_ip_cidr`。真实内核匹配测试确认：普通单播源 → 组播目的不命中；源和目的都在所列范围才命中。现有测试注释明确把它作为 Android 字面行为保留，因此本轮没有改变该语义。不能再将它描述为“源或目的命中就拒绝”。

### P2：selector/自动优选的配置能力与界面能力脱节

生成器及内核注册了 selector/urltest；当前首页 `onNodeTap()` 总是 `VpnService.switchTo` 全量重启，没有消费 `ClashApi.selectProxy()`。分组页的旧设置方法存在，但没有完整可达的设置面板。不能把 API helper 的单测通过当成用户可用的热切换/自动优选验收。

## 3. 常用功能检查矩阵

| 功能 | 已检查内容 | 结论边界 |
|---|---|---|
| TCPing | 协议过滤、首地址解析、3s连接超时、并发、错误分类、取消 | 生产 ArkTS 转译执行；socket/DNS 为平台桩，未对真实订阅逐节点联网 |
| URL Test | 专用配置、V2/legacy导出、批量会话、严格状态码、HEAD回退、取消/收尾/降级 | JS调度与主机Go探测已验证；ARM库只核验导出与打包一致性 |
| 测速结果 | status/ping/error、旧数据迁移、成功/失败展示、保存与并发节点改动 | 主机回归通过；视觉刷新待真机 |
| 分应用 | 条目迁移、勾选派生、非法/重复包名过滤、256上限、Want传参、扩展刷新、两种名单 | 代码与SDK契约核对；include/exclude实际流量待真机，空名单问题见上 |
| 路由规则 | 域名前缀、IP/CIDR、端口范围、源条件、TCP/UDP、协议列表、AND关系、顺序、direct/proxy/reject/指定节点 | 40项生产配置测试通过；任意用户非法JSON/参数不保证有效 |
| Geo/SRS | CN资产、引用与定义一致、缺失分类显式拒绝、真实SRS加载、错误格式拒绝 | 仅内置CN库；不支持任意 `geosite:xxx` 分类自动下载 |
| DNS/FakeIP/IPv6 | 四种IPv6模式 × FakeIP开关共8组实际生成DNS配置、用户DNS路由、禁止FakeIP泄到mixed、服务器域名解析策略 | 真实主机内核启动通过；DNS传输端点隔离到本地，非设备泄漏验收 |
| 嗅探/目标解析 | sniff off/route/override、TUN/mixed覆盖、resolve先于目的IP规则 | 回环HTTP实际区分保留原IP与覆盖嗅探域名；无TUN真机验证 |
| 出站图/链 | 前置与落地、链展开、指定节点目标、WireGuard endpoint生成、循环/缺失引用处理 | 配置图测试通过；未进行各协议真实握手测试 |
| Clash API | Bearer鉴权、401提示、资源释放、selector请求格式、流量读取、delay值校验 | 平台HTTP桩验证；端口共存及活动组实际选路待设备 |
| 订阅/备份 | 解析、UA回退、ETag、差异合并、保存、IPv6备份兼容、原设置迁移 | 相关主机套件通过；没有访问用户私人订阅或改设备数据 |
| VPN生命周期/保活 | 启停串行、重连、网络切换开关、CrashGuard及传输期长时任务策略 | 代码/策略测试；待机、系统回收、Wi-Fi/移动网络切换未实测 |

其他已有低优先级问题见 `docs/menu-audit/ours-side.md`：清流量后被轮询恢复、清日志后被文件tail恢复、部分设置无消费方等。本轮重点修复核心链路，未重新设计这些外围功能。

## 4. 验证记录

- Node：**19套件，19通过**。geo-srs 的外网首选源检查因 `ECONNRESET` 跳过；本地格式和构建相关断言通过，不能据此保证当前下载源可达。
- Go：`tests/hostprobe` **16个顶层测试通过**。其中远程503与坏节点整批失败是“确认现存问题”的测试，不代表这两项已修复。
- 既有三套红灯：规则UI问题已修复；IPv6选择器和FAB断言指向旧页面/旧结构，按实际SettingsPage与fabLayer更新，未删除对应功能断言。
- `assembleHap -p buildMode=release`：**BUILD SUCCESSFUL，33 tasks，12.792s**。仍有SDK弃用/异常声明等编译警告，无编译错误。
- unsigned HAP：`entry/build/default/outputs/default/entry-default-unsigned.hap`，14,428,915字节，SHA256 `60d962120379ce1816fbb4c1ff0df9d1d88247769228373b2b84d859a57e25fe`。
- 包内`libsingbox.so`与工作区库哈希一致：`9b2b983973281fb855d1993bf7895594d7eb40f2956a957160cc34d45b788d49`；已核对 legacy 和 V2 CGoTestStart/Proxy/Stop 导出存在。没有重编内核。
- 当前无HDC设备。未声称完成节点真实连通、包名对应应用真实选路、DNS泄漏、待机保活或UI视觉验收。

新增回归：`tests/functional-audit.cjs`、`tests/hostprobe/functional_audit_test.go`。扩展回归：`tests/parity-config.cjs`、`tests/clash-auth.cjs`、`tests/latency-parity.cjs`；修正过时断言：`tests/ipv6-modes.cjs`。

## 5. 真机验收清单

1. 对同一组节点分别执行TCPing/URL Test，包含正常、拒连、认证错误和QUIC节点；检查取消、重测、重进页面、重启后结果。
2. 测速期间更新订阅或删除/编辑节点，确认结束后节点数据保留；断开与连接VPN时比较绑定回退提示及延迟变化。
3. 用两个可观测出口的应用验证exclude/include、取消勾选、改模式后自动重连；单独验证零勾选策略及包名是否属于鸿蒙版应用。
4. 用专用测试域名/IP验证direct/proxy/reject/指定节点、端口和协议AND条件、规则顺序；避免把不支持的包名出站当作成功。
5. 远程SRS分别验证首次离线、下载503、缓存存在后离线、更新失败；确认错误可见且符合约定失败策略。
6. IPv4/IPv6、FakeIP、嗅探三档、DNS劫持、局域网绕过、Wi-Fi/移动网络切换及后台待机，结合系统与内核日志验收。
