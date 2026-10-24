# 订阅解析 + 节点测试:安卓 ↔ 鸿蒙 1:1 实现对比(总览)

> 日期:2026-10-23 · 安卓基线:`C:\Worker\rea-tmp\nb4a`(NekoBoxForAndroid 1.4.2,git `5768494`)
> 鸿蒙基线:`C:\Worker\NekoBox4Harmony` @ `de481f56` + 本轮未提交改动
> 详细取证(逐行对照 + 偏差清单 + 真机清单):
> - 订阅解析链路 → `docs/PARITY-SUBSCRIPTION.md`(324 行,S1–S13 逐项)
> - 节点测试链路 → `docs/PARITY-LATENCY-TEST.md`(252 行,§1–§8 逐项)
>
> 本文只做索引与总览:每条都能在对应详细文档里找到 Android 文件:行 → 鸿蒙文件:行 → 代码摘录 → 判定。

## 0. 方法与判定口径

1. 逐函数读安卓源码(非推测),在鸿蒙侧定位对应实现,比较:步骤顺序 / 默认值 / 字面量 / 错误分类 / 边界行为。
2. 能逐字复刻的一律逐字复刻,**包括安卓自身的 bug**(见 §3「已知怪癖」)。
3. 平台不可实现的,给出等价替代并写明等价性论证,不伪装成 1:1。
4. 每项都要有测试或构建取证支撑,不靠"我觉得"。

判定标记:`✅ 1:1` = 行为逐字一致;`🟡 超集` = 鸿蒙多做一件事(不改安卓已有行为);`🔷 平台替代` = 机制不同但效果等价(附论证);`❌ 受限` = 本机不可消除(需重编内核或平台能力缺失)。

## 1. 订阅解析链路(13 个阶段)

| # | 阶段 | 安卓实现(文件:行) | 鸿蒙实现(文件:行) | 判定 |
|---|---|---|---|---|
| S1 | 下载正文 | `RawUpdater.kt:50-88`:trySocks5(mixedPort)→H3 兜底;UA=`customUserAgent ?: USER_AGENT`;`allowInsecure`;`libcore/http.go:219-226` **仅 200 算成功** | `utils/Subscription.ets:155-280` `doFetchSubscription`:UA 同优先级;`responseCode !== 200` 抛错(带状态码);HTTPS 校验可跳过 | ✅ 1:1(代理路径见 §3.P1) |
| — | 默认 UA | `ktx/Nets.kt:66` `"NekoBox/Android/"+VERSION_NAME+" (Prefer ClashMeta Format)"` = `NekoBox/Android/1.4.2 (Prefer ClashMeta Format)` | `Subscription.ets:25` **同一字符串**(逐字,为让机场返回同一份正文) | ✅ 1:1(刻意逐字) |
| S2 | 响应头 | `RawUpdater.kt:75-87`:Subscription-Userinfo 存原文;content-disposition → `Util.decodeFilename`(RFC5987) | `SubFetchResult.userinfo` 直接结构化;`decodeFilename` 逐字(`Subscription.ets:165`) | ✅ 1:1(存储形态不同,解析结果一致) |
| S3 | 内容分发 | `RawUpdater.kt:227-713`:①`proxies:`→Clash YAML ②`[Interface]`→WireGuard ③JSON→parseJSON ④base64→parseProxies ⑤纯文本→parseProxies | `core/Subscriptions.ets:631-728` 判定顺序与分支逐字一致(base64/JSON/HTML 闸为超集) | ✅ 1:1 |
| S4 | Clash 解析 | `RawUpdater.kt:229-674`:10 种 type 逐字段;未知 type **静默丢弃**;`global-client-fingerprint` 兜底;`Fix ent` 两处 | `utils/Subscription.ets:376-1000`:同 10 种 type 逐字段;未知 type 同样丢弃并计 skipped;`applyClashFixEnt`/`applyClashReality` 同名逻辑 | ✅ 1:1(+🟡 额外 type:ssh/snell/wireguard/shadowtls/socks 旧拼写) |
| S5 | sing-box JSON | `RawUpdater.kt:751-808`:hysteria1→shadowsocks→trojan-go→outbounds(只跳 `dns/block/direct/selector/urltest`)→`server+server_port`;JSONArray 递归 | `Subscription.ets:1436-1744`:五分支同名同序;skip 名单**只**这 5 个(`group`/`wireguard` 不再跳,按 ConfigBean 保留整份 JSON) | ✅ 1:1 |
| S6 | WireGuard ini | `RawUpdater.kt:716-749` | `utils/LinkParser.ets` `parseWireGuard`(本轮修多 `Address` 行互相覆盖) | ✅ 1:1 |
| S7 | 分享链接 | `ktx/Formats.kt:106-240`:**按行 + 按空格双份解析,取数量多者**;`clash://install-config?`→订阅异常;未知 scheme 静默 | `LinkParser.parseShareText` 同双份解析/取多者;trojan-go 映射 trojan;naive+ 显式 skipped+hint(平台无出站) | ✅ 1:1(🟡 多 scheme 提示;trojan-go 近似见 §3.P4) |
| S8 | 重名改名 | `RawUpdater.kt:90-103`:`"name (n)"` 去旧后缀再递增 | `Subscriptions.ets:398` `renameCollisions` 同算法(含 `name.replace(" (${i-1})","")` 的"删全部出现") | ✅ 1:1 |
| S9 | forceResolve | `RawUpdater.kt:105` → `GroupUpdater.kt:39-120`:5 线程池、`sortedBy { (isInet4Address) xor ipv6First }`、SNI 回填按类型 | `Subscriptions.ets:346` `applyRewriteAddress` + `:389` `applyForceResolve`(5 并发分批,同排序键、同 SNI 规则) | ✅ 1:1 |
| S10 | 更新期去重 | `RawUpdater.kt:109-131` + `Protocols.kt:20-39`:键=**无分隔符** `serverAddress+serverPort+javaClass`;LinkedHashSet 保首次;duplicate 名单两段式 | `Subscription.ets:124` `dedupKeyOf`(无分隔符拼接)+ `Subscriptions.ets:498` `dedupProfiles`(同 `indexOf`/同名去后缀/`retainAll` 恒空转) | ✅ 1:1(开关门控,默认关) |
| S11 | 合并 | `RawUpdater.kt:141-201`:按 displayName 匹配;保留 `customOutboundJson/customConfigJson`;`existsBean != bean` 才更新;仅 userOrder 变则重排;不在名单里的删除;`changed` 计数 | `Subscriptions.ets:527-780` 同顺序:改名→forceResolve→去重→`nameMap`→`toDelete`→逐条合并(保 id/pinned/流量/自定义)→删除→计数 | ✅ 1:1 |
| S12 | 结果反馈 | `GroupInterfaceAdapter.kt:29-82`:无变化→`%s: No difference`;有变化→`%s: Updated %d proxies`+1s 后 **Diff 对话框**(Added/Updated `old => new`/Deleted/Duplicate) | `Subscriptions.ets:540-600` 四个纯函数 + `pages/SubUpdateFeedback.ets` `SubDiffDialog`;`Index.ets`/`GroupPage.ets`/`SubDetailPage.ets` 三处接线同语义 | ✅ 1:1 |
| S13 | 自动更新 | `bg/SubscriptionUpdater.kt:23-93`:WorkManager 周期;`minDelay<15→15` 分钟;未连接滤掉 `updateWhenConnectedOnly`;逐个比对 `autoUpdateDelay*60`;`SubscriptionBean` 默认 `autoUpdate=false`,`autoUpdateDelay=1440` 分钟 | `Subscriptions.ets` `SubInfo`:autoUpdate 默认 false、`updateIntervalMinutes` 默认 1440、只做 ≥15 下限钳制;`Index.autoUpdateSubs` 逐个判断到期 | 🔷 平台替代(无 WorkManager,改用前台/后台轮询;语义参数同值) |

## 2. 节点测试链路

| 维度 | 安卓实现(文件:行) | 鸿蒙实现(文件:行) | 判定 |
|---|---|---|---|
| 入口 | `add_profile_menu.xml:99,102` + `ConfigurationFragment.kt:586-592`:⋮ 菜单 **TCPing / URL Test 两个入口** | `pages/Index.ets:2304-2340`:⋮ 菜单同名两项 → `runTcpTest` / `runSpeedTest` | ✅ 1:1 |
| 作用域 | `ConfigurationFragment.kt:699,840` 当前分组 `getByGroup(currentGroupId)` | `Index.ets:556` `profiles.filter(groupId===selectedGroupId)` | ✅ 1:1 |
| 互斥/取消 | `DataStore.kt:45 runningTest`;取消后已完成结果仍落库(`:807-823`) | `Index.ets:551` `testing` 卫兵 + `cancelSpeedTest`;`finally` 里 `saveProfiles`(同语义) | ✅ 1:1 |
| 并发 | `DataStore.kt:159` 默认 **5**,worker 抢队列 | `LatencyTester.ets:208-252/391-461` 同队列模型,默认 5 | ✅ 1:1(实例粒度见 §3.P2) |
| TCPing 过滤 | `canTCPing()`:Hysteria/Hysteria2/TUIC/WireGuard/Internal/Neko = false | `LatencyTester.ets:84-96` `canTCPing` 同名单(Internal→CUSTOM,Neko→CHAIN) | ✅ 1:1 |
| TCPing 口径 | `:694-832`:先 `getAllByName()[0]`(不挑 v4/v6),解析失败 status=2 域名错误;connect/soTimeout **3000**;错误分 timeout/refused/unreachable/其它 | `LatencyTester.ets:146-201` 同:先解析取 `[0]`、失败 → `domain_not_found`、`TCPING_TIMEOUT_MS=3000`、四分类 `classifyConnectError` | ✅ 1:1 |
| URL Test | `TestInstance.kt`+`UrlTest.kt`:不分协议;超时 **5000 固定**;失败 status=3 原文 | `LatencyTester.ets:338-484`:不筛协议;默认 5000;失败 status=3 内核原文;展示期 `genFriendlyMsg` | ✅ 1:1(测量口径见 §3.P3) |
| 结果模型 | `ProxyEntity` `status/ping/error`;0 未测/1 可用/2 已知失败/3 其它 | `model/Profile.ets:129-140` 同名三件套 + `latencyMs` 派生;`Store.ets:99-130` 旧数据迁移 | ✅ 1:1 |
| 展示 | `ConfigurationFragment.kt:639-666`:0→"Testing…"次要色;1→`%dms` 绿;**无阈值分档**;2/3→红,3 可点开原文 | `Index.ets:918-985`:同四档;删掉 150/400 阈值;status3 点击弹 `connection_test_error_detail` | ✅ 1:1 |
| 默认值 | `Constants.kt:3` `http://cp.cloudflare.com/`;并发 5;超时 5000 | `model/Profile.ets:198-210` 同值(Store 只兜空值,删掉 gstatic 迁移) | ✅ 1:1 |
| 连接中测当前节点 | `BaseService.kt:142-153`:`Libcore.urlTest(box, testURL, **3000**)`,失败 `genFriendlyMsg` | `ClashApi.ets` + `Index.ets`:超时 3000、Bearer 鉴权、失败走同一映射 | ✅ 1:1 |
| 清除/删不可用 | `:477-493` status!=0 清三件套;`:495-532` status∉{0,1} 先确认再删 | `Index.ets:657-674 / 705-726` 同条件、同确认框 | ✅ 1:1 |
| 手动去重 | `:534-584` 键=**serverAddress+serverPort+displayType**;LinkedHashSet;确认框列前 20 名+"......" | `Index.ets` `dedupGroup`:同键(不再含名称/凭据)、同确认框、同截断 | ✅ 1:1 |

## 3. 偏差清单(唯一权威列表见两份详细文档)

### 1:1 已达成但值得记录的"安卓 bug 原样复刻"
- 更新期去重键**无分隔符拼接**(`server+port+javaClass`)→ 形如 `example.com`+`443`+`class X` 与 `example.co`+`m443...` 理论可碰撞;`vmess`/`vless` 同类同键会被误判重复。照抄。
- tuic `ip` 回填:安卓先把 `serverAddress` 覆盖成 ip 再判 `!isIpAddress()`,条件永假 → **永不回填 SNI**。照抄(这类节点 SNI 为空,两端一样)。
- ss `v2ray-plugin` 的 `tls` 只看 `opts.mode=="true"`。照抄。
- Clash 未知 type **静默丢弃**(无 default 分支),不报错不计数以外的提示。照抄(另加 skipped 计数,鸿蒙超集)。
- `parseJSON` outbounds 的 `wireguard` 不跳过(整份 JSON 保留),`group` 也不跳过。照抄。

### 🟡 超集(安卓没有、鸿蒙保留;不改安卓已有行为)
Clash 额外 type(`socks` 旧拼写/ssh/snell/wireguard/shadowtls,安卓直接丢弃);UA 回退链(0 节点时换 UA 重试);ETag/304 条件请求;HTML 错误页前置闸;`skipped` 明细上报;`dialer-proxy`/`detour` 落地;更新期去重之外的「手动去重」按钮(安卓有,鸿蒙键已对齐);测速设置项(并发/超时/重试/取样/判状态码/绕隧道)与组头最低延迟徽标;「取消测速」按钮。

### 🔷 平台替代(论证见详细文档)
- **P1 订阅请求不走本机 mixed 端口**:安卓 `trySocks5(mixedPort)`;鸿蒙 `@ohos.net.http` 无显式代理、TLS 不能叠加自管 socket → 等价性:VPN 已连接时 UI 进程流量本就被 TUN 捕获(同样经隧道),未连接时两端都直连。
- **P2 测速实例粒度**:安卓每节点一个 `TestInstance`;鸿蒙「整批一个临时会话 + 按 tag 并发探测」。原因:内核 `testInstance` 是包级单例(`core/libsingbox14/main.go:180/194/240`),逐节点建实例只能全局串行,有效并发退化为 1(100 节点从 `≈N/5×t` 变 `Σt`)。等价性:每次 probe 都经该节点自己的出站新建连接,节点间不共享连接/状态;单节点配置非法只红它自己。要逐字 1:1 需内核新增 `CGoTestStartSingBoxV3 → sessionId`(需重编 `.so`)。
- **P3 自动更新调度**:安卓 WorkManager 周期任务;鸿蒙前台/后台轮询(参数与钳制同值)。
- **P4 `content://` 订阅源**:安卓可读 ContentProvider;鸿蒙无对应入口(改用文件/剪贴板导入)。
- **P5 trojan-go 映射**:安卓用独立插件进程;鸿蒙映射到 trojan(无 `encryption`/`plugin` 时协议等价,两字段无处安放 → 近似)。

### ❌ 受限(本机不可消除,需重编内核或平台能力)
**测量口径**:安卓 libneko `speedtest` = GET ×2 同连接(暖连接 RTT,`WroteHeaders→GotFirstResponseByte`)、**完全不看 HTTP 状态码**、计数器 int32 无上限;鸿蒙内核补丁 7 = HEAD 单次(405/501 回退 GET)、计时含建连+TLS、默认 `expectStatus='any'` 已对齐"不看状态码"、耗时 uint16 封顶 65535。
→ 结论:**同一节点鸿蒙数值偏高**(差一个建连+握手),跨平台数值不可直接比较;本轮已把"默认不判状态码 + 默认 HTTP 探测网址"压到与安卓同档语义,测量区间的逐字一致需移植 `urltest/rtt.go` 并重编 `libsingbox.so`(本机无 OHOS Go 工具链,本轮未做)。

## 4. 证据

### 4.1 测试(本机实跑,`node tests/<suite>.cjs`)
共 15 个套件:**12 绿 / 3 红**(3 红为 2.1.6 UI 重构遗留的既有失败,本轮未修、未变糟;另有 `generate-dns-fixtures.cjs` 为夹具生成脚本,不计入):

| 套件 | 断言 | 覆盖 |
|---|---|---|
| `sub-parity-subscription.cjs` | **48** | 本轮新增:改名/去重键/合并计数/改写地址/反馈正文/确认条件/分钟间隔/parseProxies 空格切分/trojan-go |
| `latency-parity.cjs` | **17** | 本轮新增:canTCPing/错误分类/status 迁移/默认值/去重与清除语义 |
| `subscription-parse.cjs` | 41 | Clash/JSON/分享链接解析 |
| `clash-auth.cjs` | 8 | 连接中测速 3000ms + Bearer + URL 编码 |
| `sub-etag.cjs` / `sub-ua-fallback.cjs` | 15 / 17 | 条件请求、UA 回退 |
| `geo-srs` / `outbound-graph` / `per-app` / `ipv6-*` / `home-view` | 16/9/21/8+7/7 | 既有回归 |
| `parity-config` / `ipv6-modes` / `route-rules-ui` | ❌ | **既有失败**(HEAD 上同样失败,已用 worktree 复核;断言的是 2.1.6 重构前的旧布局) |

### 4.2 构建与静态取证
- `node hvigorw.js --mode module -p product=default -p buildMode=release assembleHap --no-daemon` → **BUILD SUCCESSFUL**。
- HAP 内 `ets/modules.abc` 含:`SubDiffDialog`、`subUpdateDiffBodies`、`needDirectUpdateConfirm`、`runTcpTest`、`canTCPing`、`classifyConnectError`、`updateIntervalMinutes`、`parseTrojanGoLink`、`renameCollisions`。
- `resources.index` 含新增键:`group_diff_title`、`group_diff_added`、`dedup_confirm_body`、`update_subscription_warning`、`sub_interval_minutes`、`confirm`、`connection_test_tcp_ping`、`connection_test_url_test`、`connection_test_error_detail`。

### 4.3 真机
本轮 `hdc list targets` 为 `[Empty]`(无线 `tconn 192.168.10.5:39933` 失败),**未做真机验证**。待验证项见 `docs/PARITY-SUBSCRIPTION.md` §15 与 `docs/PARITY-LATENCY-TEST.md` §14,要点:
1. 同一订阅在两端解析出的节点数/字段一致(尤其 Clash 多 type、JSON 订阅、含 trojan-go 的 base64 订阅);
2. 更新订阅后 Diff 对话框四段内容与安卓一致;"未连接更新"确认框只在 http:// 或"仅连接时更新"时出现;
3. TCPing/URL Test 只作用于当前分组;绿=任意成功值、红=失败、无黄档;status3 点击弹内核原文;
4. 取消测速后结果已落盘、重启仍在;
5. 与安卓同节点对比延迟(预期鸿蒙偏高,P3 所述原因)。

## 5. 复核方式

```bash
cd NekoBox4Harmony
for f in tests/*.cjs; do case "$f" in *generate-*) continue;; esac; node "$f" >/dev/null 2>&1; echo "$? $(basename $f)"; done
# 构建(需 DevEco JBR 在 PATH、DEVECO_SDK_HOME 指向 SDK)
PATH="/c/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH" \
DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk' \
node hvigorw.js --mode module -p product=default -p buildMode=release assembleHap --no-daemon
```
