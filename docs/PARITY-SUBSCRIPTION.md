# 订阅解析 / 节点更新链路 — Android NekoBoxForAndroid 1.4.2 ↔ NekoBox4Harmony 逐项对照

> 日期:2026-10-23 · 范围:订阅抓取 → 内容分发 → Clash YAML / sing-box JSON / 分享链接 / WireGuard →
> 命名与去重 → 与既有节点合并 → 结果反馈 → forceResolve → 自动更新调度
> 参考源码:`C:\Worker\rea-tmp\nb4a`(NekoBoxForAndroid 1.4.2,VERSION_NAME=1.4.2 / VERSION_CODE=46)
> 鸿蒙源码:`C:\Worker\NekoBox4Harmony@de481f56 + 本轮未提交改动`
>
> **判定口径**
> `1:1` = 步骤顺序 / 默认值 / 字面量 / 错误分类与 Android 一致;
> `差异已对齐` = 本轮把它改成了 Android 的做法;
> `偏差(超集)` = 鸿蒙多做了一件事,Android 没有(不改动其行为,列在「偏差清单」);
> `偏差(平台)` = 平台能力不同,给出等价替代并说明等价性;
> `缺失` = 当前仍未做(列在「未完成/待决策」)。
>
> 行号说明:Android 行号取自参考源码;鸿蒙行号取自本轮改完后的文件(以函数名为锚更稳)。

---

## 0. Android 订阅链路总览(步骤编号,后续表格按此编号引用)

| # | 阶段 | Android 入口 |
|---|---|---|
| S1 | 下载订阅正文 | `RawUpdater.kt:48-88` |
| S2 | 响应头处理(Userinfo / content-disposition) | `RawUpdater.kt:75-87` |
| S3 | 内容分发(4 段) | `RawUpdater.kt:227-713` |
| S4 | Clash YAML 解析 | `RawUpdater.kt:229-674` |
| S5 | sing-box / 裸 JSON 解析 | `RawUpdater.kt:751-808` + `fmt/**` |
| S6 | WireGuard ini 解析 | `RawUpdater.kt:716-749` |
| S7 | 分享链接解析(parseProxies) | `ktx/Formats.kt:106-240` |
| S8 | 重名改名 | `RawUpdater.kt:90-103` |
| S9 | forceResolve | `RawUpdater.kt:105-107` → `GroupUpdater.kt:39-120` |
| S10 | 去重 | `RawUpdater.kt:109-131` + `Protocols.kt:16-40` |
| S11 | 与既有节点合并 | `RawUpdater.kt:133-223` |
| S12 | 结果反馈 | `GroupInterfaceAdapter.kt:29-82` |
| S13 | 自动更新调度 | `bg/SubscriptionUpdater.kt:23-93`、`GroupUpdater.kt:133-160` |

---

## 1. S1 抓取订阅正文

| # | Android 证据 | Android 行为 | 鸿蒙现状 | 判定 | 说明 |
|---|---|---|---|---|---|
| 1.1 | `RawUpdater.kt:50-56` | `content://` 走 ContentResolver 读文本 | 无对应(鸿蒙无 content provider 分享入口) | 偏差(平台) | 鸿蒙用「从文件/剪贴板导入」替代 `LinkParser/Store`;订阅地址只支持 http(s) |
| 1.2 | `RawUpdater.kt:59-61` `Libcore.newHttpClient().trySocks5(DataStore.mixedPort).tryH3Direct()` | 订阅请求优先经本机 mixed 端口(Socks5)走代理,失败→直连;H3 分支独立 10s | `@ohos.net.http`(不支持显式代理) | 偏差(平台) | 等价性:VPN 已连接时 UI 进程流量本来被 TUN 捕获 → 同样经隧道;未连接时两端都直连。不为它自研 Socks5+TLS 栈 |
| 1.3 | `RawUpdater.kt:62-64` `appTLSVersion=="1.3" → restrictedTLS()` | 可强制 TLS1.3 | 无(鸿蒙 http 栈不暴露) | 偏差(平台) | 无等价开关;文档记录 |
| 1.4 | `RawUpdater.kt:66-68` `allowInsecureOnRequest → allowInsecure()` | 全局「忽略证书」开关影响订阅请求 | `SubInfo`/settings `subAllowInsecure` → `remoteValidation:'skip'` | 1:1 | 语义一致(设置项名不同) |
| 1.5 | `RawUpdater.kt:70` `setUserAgent(customUserAgent.takeIf{isNotBlank()} ?: USER_AGENT)` | 自定义 UA 优先,否则默认 UA | `fetchSubscriptionConditional(url, allowInsecure, customUA, …)` 同逻辑 | 1:1 | — |
| 1.6 | `ktx/Nets.kt:66` + `nb4a.properties:2` | `USER_AGENT = "NekoBox/Android/1.4.2 (Prefer ClashMeta Format)"` | `Subscription.ets:25 SUB_UA` 逐字同值 | 1:1(刻意逐字) | 机场按 UA 决定返回格式,UA 不一致 → 正文天然不同;保留自定义 UA 覆盖 |
| 1.7 | `libcore/http.go:219-226` | 仅 `StatusCode == 200` 返回正文,其余直接报错 | `Subscription.ets:271` `responseCode !== 200` 抛错(带状态码+正文摘要) | 差异已对齐 | 本轮由 `2xx/3xx 宽松` 改为仅 200;304 是鸿蒙超集(见偏差 2.3) |
| 1.8 | 无 ETag 支持(Android 每次全量下载) | — | `etag`/`lastModified` 条件请求 + 304 分支 | 偏差(超集) | 语义等价且省流量;304 分支已有回归测试 `tests/sub-etag.cjs` |
| 1.9 | `RawUpdater.kt:72-73` `parseRaw(getStringBox(response.contentString)) ?: error(no_proxies_found)` | 解析失败 → 整体失败 | `updateSubscription` 解析 0 节点 → `throw subFailureText(...)` | 1:1 | 错误分类更细(见 3.1),仍属同一失败路径 |
| 1.10 | — | — | UA 回退链 `SUB_UA_FALLBACKS`(0 节点时换 UA 重试) | 偏差(超集) | Android 只有单一 UA;`tests/sub-ua-fallback.cjs` 覆盖 |

## 2. S2 响应头

| # | Android 证据 | Android 行为 | 鸿蒙现状 | 判定 | 说明 |
|---|---|---|---|---|---|
| 2.1 | `RawUpdater.kt:75-76` + `Util.kt:187-192` | `subscription.subscriptionUserinfo = getStringBox(response.getHeader("Subscription-Userinfo"))`(原文存字符串) | `SubFetchResult.userinfo` → `parseSubUserInfo` 拆成 upload/download/total/expire | 差异(字段映射) | Android 存原文由 UI 解析;鸿蒙存结构化字段。解析规则见 `Subscription.ets:327`,等价;`tests/sub-parity-subscription.cjs` 覆盖 |
| 2.2 | `RawUpdater.kt:78-87` + `Util.kt:194-199 decodeFilename` | **仅当组名以 `Subscription #` 开头**时,用 `content-disposition` 的 RFC5987 文件名改名 | `Subscriptions.ets`(updateSubscription 内,S2 注释块)同条件 + `decodeFilename`(`Subscription.ets:165`) | 差异已对齐 | 本轮新增;`decodeFilename` 正则与 Android 逐字一致,`tests/sub-parity-subscription.cjs` 覆盖 |

## 3. S3 内容分发顺序

| # | Android 证据 | Android 行为 | 鸿蒙现状 | 判定 | 说明 |
|---|---|---|---|---|---|
| 3.1 | `RawUpdater.kt:229-235` | `text.contains("proxies:")` → SnakeYAML;`YAMLException` 才继续往下 | `parseSubscriptionBody`:结构检测(顶层 `proxies` / `proxy-providers`)+ HTML 前置闸 | 差异 | Android 是**子串**判定,鸿蒙是**顶层键**判定 + HTML 闸。差异只在「正文含 `proxies:` 但不是 YAML」这类坏输入:Android 会先当 YAML 失败再往下试,鸿蒙直接走分享链接分支 → 最终结果同一份节点。列偏差 2.1 |
| 3.2 | `RawUpdater.kt:236-240` | YAML 只包含 `proxies:` 时用 `loadAs<Map>` 取列表,`!is List` → `error(no_proxies_found)` | `parseClashProxies` 取 `proxies` seq;非 seq → note `clash_no_proxies_key` | 1:1 | 错误文案不同,分类一致 |
| 3.3 | `RawUpdater.kt:699` | `parseProxies(text.decodeBase64UrlSafe())` 非空才用 | `LinkParser.parseShareText` 内先尝试整段 base64(含折行宽松解码) | 差异(超集) | 鸿蒙额外支持 base64 包裹的 WG .conf / sing-box JSON(Android 会丢);见偏差 2.2 |
| 3.4 | `RawUpdater.kt:702-707` | 再试明文 `parseProxies`;`SubscriptionFoundException` 重新抛出 | 明文分享链接解析 | 1:1 | 鸿蒙没有 `sn://` 容器解析能力(见 7.3) |
| 3.5 | `RawUpdater.kt:711-713` | 全失败 → `null` → 上层报 `no_proxies_found` | 0 节点 → 抛可诊断文案(`subFailureText`) | 1:1 | — |
| 3.6 | `RawUpdater.kt:233-240` | WireGuard:仅 `text.contains("[Interface]")` | `parseShareText` 在无 `://` 时尝试 `[Interface]` | 1:1(顺序略差) | Android 在 JSON 之前判 WG;鸿蒙在 JSON 之后。WG .conf 不含 `{`,互不影响 |
| 3.7 | `RawUpdater.kt:242-247` | `JSONTokener(text).nextValue()` 任何 JSON 值 → `parseJSON` | `looksLikeSingBoxJson` 或首字符 `{`/`[` → `parseSingBoxConfig` | 差异已对齐 | 本轮补上 JSON 数组递归与裸对象分支,见 S5 |

## 4. S4 Clash YAML

### 4.1 结构与全局

| # | Android 证据 | Android 行为 | 鸿蒙现状 | 判定 | 说明 |
|---|---|---|---|---|---|
| 4.1.1 | `RawUpdater.kt:241` | 读 `global-client-fingerprint` 作 REALITY 指纹回退 | `parseClashProxies:387` | 1:1 | — |
| 4.1.2 | `RawUpdater.kt:248` `when(proxy["type"])` | **无 `default`** → 未知 type 静默丢弃(不计数、不报错) | `profileFromClash` `switch` 的 `default` 只保留 CUSTOM 出站逻辑;clash 分支未知 type 返回 null → `skipped++` | 差异(计数) | 丢弃行为一致;鸿蒙额外上报 skipped 供 UI 诊断(偏差 2.4) |
| 4.1.3 | `RawUpdater.kt:250-257` | `server`/`port` 缺失 → `?: continue` | `profileFromClash:761` `server==='' || port<=0 → null` | 1:1 | — |
| 4.1.4 | `RawUpdater.kt:258-259` | `name`/`server` 先赋值,后续键覆盖 | 同 | 1:1 | — |
| 4.1.5 | `RawUpdater.kt:660-667` | "Fix ent" #1:VMess 族 `isTLS() && sni 空 && host 非空 && host 非 IP` → `sni = host` | `applyClashFixEnt:682`(vmess/vless/trojan 分支调用) | 差异已对齐 | 本轮新增;`tests/sub-parity-subscription.cjs` 覆盖 |
| 4.1.6 | `RawUpdater.kt:669-672` | "Fix ent" #2:REALITY `public-key` 非空且指纹空 → `global-client-fingerprint` → 仍空则 `chrome` | `applyClashReality:661`(同上条件) | 差异已对齐 | 本轮补上「必须有 pubkey」这一前置条件 |

### 4.2 逐 type

| # | type | Android 证据 | 行为摘要 | 鸿蒙现状 | 判定 |
|---|---|---|---|---|---|
| 4.2.1 | socks5 / http | `RawUpdater.kt:249-270` | name/server/port/username/password/tls | `profileFromClash` same cases | 1:1 |
| 4.2.2 | ss | `:272-305` | cipher→method、password、`plugin`+`plugin-opts` 拼成 `plugin` 串(obfs/v2ray-plugin 两族) | `:745-800` 同拼接,拆存 `ssPlugin`/`ssPluginOpts` | 1:1(字段映射) |
| 4.2.3 | vmess | `:310-354` | uuid、alterId、cipher→encryption、tls→security、packet-encoding、network/ws-opts | `profileFromClash` `case 'vmess'` | 差异已对齐 |
| 4.2.4 | vless | `:310-346` | alterId=-1 表 vless、`flow` 含 `xtls-rprx-vision` 才写 encryption | 同 | 差异已对齐(原先无条件写 flow) |
| 4.2.5 | trojan | `:356-363` | 构造即 security="tls",`tls` 键可覆盖 | 同 | 差异已对齐(原先强制 tls=true) |
| 4.2.6 | anytls | `:494-517` | 键名 `replace("_","-")` 归一化;name/server/port/password/client-fingerprint/sni/skip-cert-verify/alpn | `case 'anytls'` + `yNorm` | 差异已对齐(本轮补归一化) |
| 4.2.7 | hysteria(v1) | `:519-570` | port→serverPorts、ports 覆盖、up/down `substringBefore(" ").toIntOrNull() ?: 100`、auth-str、alpn List→"\n"、默认 up=10/down=50 | `case 'hysteria'` | 差异已对齐(键缺失时改回 10/50;有键但不可解析时 100) |
| 4.2.8 | hysteria2 | `:572-604` | ports、obfs-password、up/down `?: 0`、**无 alpn 处理** | `case 'hysteria2'` | 差异已对齐(up/down 兜底 0;alpn 清空) |
| 4.2.9 | tuic | `:608-654` | ip→serverAddress、token→protocolVersion=4、password→token、sni、alpn、congestion-controller、udp-relay-mode、disable-sni、reduce-rtt | `case 'tuic'` | 差异已对齐(含 SNI 不回填;congestion 默认 cubic) |

### 4.3 逐字段(vmess/vless/trojan 共用的键循环 `RawUpdater.kt:325-490`)

| # | 键 | Android 行为 | 鸿蒙现状 | 判定 |
|---|---|---|---|---|
| 4.3.1 | `tls` | `security = "tls"` / `""`(仅 VMess 族) | `p.tls = yBool(tls)` | 1:1 |
| 4.3.2 | `network` | 仅 `h2/http`→`http`、`ws/grpc`→原值;其它(含 tcp/quic/未知)不写回(默认 tcp) | 同(`applyClashTransport:609`) | 差异已对齐 |
| 4.3.3 | `ws-opts` | path / headers.Host / max-early-data / early-data-header-name / v2ray-http-upgrade→type=httpupgrade(不清 early-data) | 同 | 差异已对齐(去掉了清零 early-data) |
| 4.3.4 | `h2-opts` | path、host(List→"\n") | 同(`joinLines`) | 差异已对齐 |
| 4.3.5 | `http-opts` | path(List→"\n")、headers.host(List→"\n") | 本轮新增 | 差异已对齐 |
| 4.3.6 | `grpc-opts` | `grpc-service-name`→`bean.path` | → `p.serviceName` | 差异(字段映射,等价) |
| 4.3.7 | `smux` | `enabled` **写成**字面值、`max-streams` toInt、`padding` 布尔 | `applyClashMux:693` 同 | 差异已对齐(原先强制开) |
| 4.3.8 | `ech-opts.enable` | → `enableECH` | `applyClashEch:716`(本轮新增) | 差异已对齐 |
| 4.3.9 | `alpn` | List→"\n" | List→","(sing-box 需要逗号) | 差异(字段映射) |
| 4.3.10 | `packet-encoding` | packetaddr→1 / xudp→2 / 其它 0 | 存字符串 `packetaddr`/`xudp` | 差异(字段映射) |
| 4.3.11 | `skip-cert-verify` | `value as? Boolean == true`(只认布尔) | `yBool` 还认 `"true"/"1"/"yes"/"on"` | 偏差(超集) |
| 4.3.12 | `servername`/`sni` | 都写 sni | `yStrAny(m,['servername','sni'])` | 1:1 |
| 4.3.13 | `client-fingerprint` | → utlsFingerprint | `p.fingerprint` | 1:1 |
| 4.3.14 | `reality-opts` | 逐键处理,任一键存在即 security="tls" | 同 | 1:1 |
| 4.3.15 | `dialer-proxy` | Android 1.4.2 clash 分支未处理 | `p.dialerProxyName` | 偏差(超集) |

## 5. S5 sing-box / 裸 JSON(`parseJSON`)

| # | Android 证据 | Android 行为 | 鸿蒙现状 | 判定 | 说明 |
|---|---|---|---|---|---|
| 5.1 | `RawUpdater.kt:756-758` | 分支①`server && (up || up_mbps)` → `parseHysteria1Json` | `parseJsonValue:1436` 分支①(同条件) | 差异已对齐 | 本轮把裸对象分派改成 Android 的 `when` 顺序 |
| 5.2 | `HysteriaFmt.kt:167-203` | `server` 用 `substringBeforeLast(":")`/`substringAfterLast(":")`;up/down 取 `up_mbps`/`down_mbps`(缺则 bean 默认 10/50);auth→BASE64、auth_str→STRING;alpn 只认字符串;recv_window_*、disable_mtu_discovery | `profileFromHysteria1Json:1647` 同 split 与默认;recv_window/disable-mtu 无模型字段 | 差异(字段缺失) | 缺 3 个字段(见未完成 U3) |
| 5.3 | `RawUpdater.kt:760-762` | 分支②`method` → `JSONObject.parseShadowsocks()` | `parseJsonValue` 分支② → `profileFromShadowsocksJson:1584` | 差异已对齐 | plugin→`plugin;opts` |
| 5.4 | `ShadowsocksFmt.kt:95-108` | name=`remarks`(缺键→"")、password、method、plugin=`plugin;plugin_opts` | 同 | 1:1 | — |
| 5.5 | `RawUpdater.kt:764-766` | 分支③`remote_addr` → `JSONObject.parseTrojanGo()` | `parseJsonValue` 分支③ → `profileFromTrojanGoJson:1618` | 差异已对齐(映射) | 模型无 trojan-go → 映射为 trojan(偏差 2.7) |
| 5.6 | `TrojanGoFmt.kt:134-162` | 实际只生效 remote_addr/remote_port/password;`optJSONArray("ssl"/"websocket"/"shadowsocks")` 对对象恒 null → **死代码** | 同(只读三项) | 1:1(复刻怪癖) | `tests/sub-parity-subscription.cjs` 断言 sni 不被读取 |
| 5.7 | `RawUpdater.kt:768-788` | 分支④`outbounds` → 逐出站 `ConfigBean(type=1, config=pretty JSON, name=tag)`;过滤 `ty==null||ty==""` 与 dns/block/direct/selector/urltest | `parseJsonValue` 分支④ | 差异(表示) | 过滤名单本轮已与 Android 逐字一致(`group`/`wireguard` 不再跳过);已知类型映射为结构化节点 + `extra` 保留原始 JSON(偏差 2.5) |
| 5.8 | `RawUpdater.kt:790-795` | 分支⑤`server && server_port` → 单个 ConfigBean(name 为空) | `parseJsonValue` 分支⑤ → CUSTOM,`customOutbound`=`JSON.stringify(o,null,2)` | 差异已对齐 | 本轮把 compact 改成 `toStringPretty()` 等价的两空格缩进;name 仍取 tag/remarks(偏差 2.6) |
| 5.9 | `RawUpdater.kt:797-804` + `Formats.kt:51-64` | 数组:逐元素 `isJsonObjectValid` 后**递归** `parseJSON` | `parseJsonValue` 数组分支递归(本轮新增) | 差异已对齐 | 字符串元素按 JSON 再解析(Android 会抛 ClassCastException,鸿蒙宽容;偏差 2.8) |
| 5.10 | `RawUpdater.kt:806` | 所有结果 `initializeDefaultValues()` | 构造即默认值 | 1:1 | — |
| 5.11 | — | Android 不认 `endpoints`(1.11+ 才拆出) | `parseSingBoxConfig:1550` 在五个分支都未命中时处理 endpoints | 偏差(超集) | 只在「纯 endpoints」配置生效,有 outbounds 时行为与 Android 一致 |

## 6. S6 WireGuard ini

| # | Android 证据 | Android 行为 | 鸿蒙现状 | 判定 | 说明 |
|---|---|---|---|---|---|
| 6.1 | `RawUpdater.kt:716-749` | ini4j 解析;`[Interface]` 必须存在 | `LinkParser.parseWireGuardConf` 手写 ini | 1:1 | — |
| 6.2 | `:726-728` | `Address` 取**多行**,逐行按 `,` 拆,join "\n" | 多行累积 + 逗号拆(本轮修复:此前多行被覆盖) | 差异已对齐 | 鸿蒙内部用逗号分隔(等价) |
| 6.3 | `:730-735` | `MTU`/`PrivateKey` | 同 | 1:1 | — |
| 6.4 | `:737-748` | 每个 Peer:`Endpoint` 必须含 `:`、`substringAfterLast(":").toIntOrNull() ?: continue`;`PublicKey` 必需;`PresharedKey` 可选 | 同 | 1:1 | — |
| 6.5 | `:723-725` | 传入 `fileName` 时 `name = fileName.removeSuffix(".conf")` | 按 peer `name` 字段 | 差异 | Android 只在文件导入路径传 fileName;鸿蒙无该入口,见未完成 U4 |

## 7. S7 分享链接(parseProxies)

| # | Android 证据 | Android 行为 | 鸿蒙现状 | 判定 | 说明 |
|---|---|---|---|---|---|
| 7.1 | `Formats.kt:107-108` | 文本同时按**行**与**行内空格**切成两份链接表 | `parseShareText` 构造 `lines` 与 `spaceTokens` 两份,分别 `parseLinkBatch` | 差异已对齐 | 单行多链接订阅可全部导入;`tests/sub-parity-subscription.cjs` §23 |
| 7.2 | `Formats.kt:230-239` | 两份结果比大小,**严格更大**才取空格那份(相等取按行) | `bySpace.profiles.length > byLine.profiles.length ? bySpace : byLine` | 差异已对齐 | 名字带空格的链接不会被切坏(相等时按行胜出) |
| 7.3 | `Formats.kt:114-117` | `clash://install-config?` / `sn://subscription?` → `SubscriptionFoundException` | `unwrapSubscriptionLink` 解 `clash://` 容器;`isSagerNetSubscriptionContainer` 只识别 `sn://` 并提示 | 偏差(平台) | `sn://` 是 Kryo 二进制,鸿蒙无反序列化能力 → 明确提示而非静默 0 节点 |
| 7.4 | `Formats.kt:118-127` | `sn://` → `parseUniversal` | 无 | 缺失(平台) | 同上 |
| 7.5 | schemes:socks/socks4/socks4a/socks5 | `Formats.kt:127-140` | `parseOne` 支持 socks 族 | 1:1 | — |
| 7.6 | http/https | 同 | 支持 | 1:1 | — |
| 7.7 | vmess | `V2RayFmt.parseV2Ray` | 支持(base64 JSON) | 1:1 | — |
| 7.8 | vless/trojan/ss/hysteria/hysteria2/tuic/anytls | `Formats.kt:150-215` | 支持 | 1:1 | — |
| 7.9 | trojan-go(`trojan-go://`) | `Formats.kt:171-176` → `TrojanGoFmt.kt:12-44` | `parseTrojanGoLink` → 映射为 TROJAN + `transport=ws` | 偏差(近似) | Android 用独立插件进程跑 trojan-go(`BoxInstance.kt:60-63,108-121`);鸿蒙无该出站。「无 encryption / 无 plugin」时两者协议一致;加密/插件两族字段无处可放,见偏差 2.18 |
| 7.10 | naive+ | `Formats.kt:185-190` → `NaiveFmt.kt:9-34` | 显式返回 null → 上报 skipped | 缺失(平台) | naive 同样靠独立插件进程(`BoxInstance.kt:70-73,108-140`),sing-box 1.14 无 naive 出站、沙箱禁止 exec → 不可实现,见 U2 |
| 7.11 | ssr | Android 也不支持 | 计入 skipped 并提示 | 1:1 | — |

## 8. S8 重名改名

| # | Android 证据 | Android 行为 | 鸿蒙现状 | 判定 | 说明 |
|---|---|---|---|---|---|
| 8.1 | `RawUpdater.kt:90-103` | `while(contains) { index++; name = name.replace(" ($index-1)",""); name="$name ($index)" }`(replace 是**全串**替换) | `Subscriptions.renameCollisions:398` 用 `split(old).join('')`(等价 replaceAll) | 1:1 | `tests/sub-parity-subscription.cjs` 用 `HK,HK,HK,HK (1)` 验证得到 `HK,HK (1),HK (2),HK (1) (1)` |

## 9. S9 forceResolve

| # | Android 证据 | Android 行为 | 鸿蒙现状 | 判定 | 说明 |
|---|---|---|---|---|---|
| 9.1 | `GroupUpdater.kt:43` | 5 线程 fixed pool | `applyForceResolve:389` 5 并发分批 | 1:1(等价) | ArkTS 无协程池 |
| 9.2 | `:50` | `ipv6First = ipv6Mode >= PREFER` | `settings.ipv6Mode === 'prefer' \|\| 'only'` | 1:1 | 本轮补上(原先恒 v4 优先) |
| 9.3 | `:54-58` | Naive 跳过;`serverAddress.isIpAddress()` 跳过 | 只判 IP(无 naive 类型) | 1:1 | — |
| 9.4 | `:62-75` | FakeDNS 分支条件(underlyingNetwork != null && enableFakeDns && started && MODE_VPN) | 无(鸿蒙无 FakeDNS 查询通道) | 偏差(平台) | 走系统 DNS,与 Android 的 else 分支相同 |
| 9.5 | `:76` | 结果为空 → `error("empty response")` → 仅日志 | 空结果直接返回 | 1:1(等价) | — |
| 9.6 | `:95` | `sortedBy { (isInet4) xor ipv6First }[0]` | `applyRewriteAddress:346` 显式 v4/v6 分组按同一优先级取首 | 1:1 | `tests/sub-parity-subscription.cjs` 覆盖两种模式 |
| 9.7 | `:97-116` | SNI 回填:Http 仅 `isTLS()`;V2Ray 仅 `security=="tls"`;Trojan/TrojanGo/Hysteria **无条件**;其它类型不回填 | 同(按 `p.tls`/类型分支) | 差异已对齐 | 原先「`p.tls` 为真就回填」会覆盖 tuic/anytls |
| 9.8 | `:118` | 最后 `serverAddress = address`(所有类型都换) | 同 | 1:1 | — |
| 9.9 | `:78-80` | 失败只写日志、保留域名 | 同 | 1:1 | — |

## 10. S10 去重

| # | Android 证据 | Android 行为 | 鸿蒙现状 | 判定 | 说明 |
|---|---|---|---|---|---|
| 10.1 | `Protocols.kt:20-25` | `ConfigBean → bean.config`;否则 `serverAddress + serverPort + type`(**无分隔符**) | `dedupKeyOf:124`:CUSTOM→`customOutbound`,其余 `server+port+javaClass 字面量` | 差异已对齐 | 本轮去掉 `\u001f` 分隔符并把顺序改成 server+port+type;`dedupTypeToken:81` 给出与 `javaClass.toString()` 相同的字面量 |
| 10.2 | `RawUpdater.kt:114` | type 实参 = `_proxy.javaClass.toString()` | 同(`class io.nekohasekai…Bean`) | 1:1 | vmess 与 vless 共用 VMessBean → 同键(Android 原样) |
| 10.3 | `RawUpdater.kt:109-131` | 更新流程**内部**执行,由 `subscription.deduplication` 门控 | `updateSubscription` 步骤 3(由 `subForGroup.deduplication` 门控) | 差异已对齐 | 本轮把透明度/时机改成 Android 一致;UI 手动去重保留为鸿蒙额外能力(偏差 2.9) |
| 10.4 | `:115-127` | duplicate 名单:首次出现的名字去旧后缀 + `" ($index)"`,同键原始名只记一次,再记重复项自身 | `dedupProfiles:498` 同 | 差异已对齐 | `tests/sub-parity-subscription.cjs` 断言 `A (0),A2 (0),C (0)` |
| 10.5 | `:129-131` | `LinkedHashSet` 保首次出现顺序;`retainAll(uniqueNames.keys)` 恒 no-op | 保序数组 + 键表 | 1:1 | — |

## 11. S11 与既有节点合并

| # | Android 证据 | Android 行为 | 鸿蒙现状 | 判定 | 说明 |
|---|---|---|---|---|---|
| 11.1 | `RawUpdater.kt:133-134` | `proxies.associateBy { displayName() }` | `byName` Map(按 `name`,首次优先) | 1:1 | — |
| 11.2 | `:135-139` | `toDelete` = 旧节点里名字不在新名单的 | 同(`deletedNames`) | 1:1 | — |
| 11.3 | `:145-156` | 命中旧实体:先 `customOutboundJson = existsBean.customOutboundJson`(比较前赋值) | 先继承 `customOutbound`,再 `profileBeanEquals` | 1:1 | `customConfigJson` ↔ `Profile.extra` |
| 11.4 | `:157-162` | 内容相等但 userOrder 不同 → 只更新顺序 | 同 | 1:1 | — |
| 11.5 | `:164-190` | `existsBean != bean` 才更新;`updated[displayName] = name` | `profileBeanEquals` → 原地保留实体 id 并覆盖字段 | 差异已对齐 | Android 用 Kryo 字节相等;鸿蒙用「参与节点定义的字段」全等(不含 id/分组/延迟/置顶/流量),见 `profileBeanEquals:418` |
| 11.6 | `:194-222` | 新节点:`userOrder` 递增、入库 | 同 | 1:1 | — |
| 11.7 | `:224-256` | 删除 `toDelete`(含正在运行的节点) | 同(本轮去掉「保留运行中节点」的例外) | 差异已对齐 | 仅加一条日志;偏差说明见 2.10 |
| 11.8 | `:258-280` | `subscription.lastUpdated = now`、组更新、`onUpdateSuccess` | `touchSub` + 结果对象 | 1:1 | — |
| 11.9 | `:159/168/190` | `changed = toDelete.size + added + updated` | `result.changed` 同定义 | 1:1 | — |

## 12. S12 结果反馈

| # | Android 证据 | Android 行为 | 鸿蒙现状 | 判定 | 说明 |
|---|---|---|---|---|---|
| 12.1 | `GroupInterfaceAdapter.kt:38-44` | `changed==0 && duplicate 为空 && byUser` → snackbar「%s: No difference」 | `subUpdateHasChanges(res)` 给出同一判据(`Subscriptions.ets`) | 1:1(数据层) | UI 接线由 Lead 完成;组件见 `pages/SubUpdateFeedback.ets` |
| 12.2 | `:45` | snackbar「%s: Updated %d proxies」 | `subUpdateToastKind(res)` 返回 `group_updated` / `group_no_difference` | 1:1(数据层) | 同上 |
| 12.3 | `:47-68` | 1 秒后 Diff 对话框:Added / Updated(`old => new`)/ Deleted / Duplicate 四段 | `SubDiffDialog`(`pages/SubUpdateFeedback.ets`)+ `subUpdateDiffBodies` / `subUpdateFeedbackText`;空段整段省略 | 1:1(组件已交付) | 四段顺序、段内 `\n`、段间空行、`old => new` 规则均按 `:47-68`;`tests/sub-parity-subscription.cjs` §21 |
| 12.4 | `:84-88` | 失败 → snackbar 原文 | `promptAction.showToast(...)` | 1:1 | — |

## 13. S13 自动更新

| # | Android 证据 | Android 行为 | 鸿蒙现状 | 判定 | 说明 |
|---|---|---|---|---|---|
| 13.1 | `SubscriptionBean.java:113` | `autoUpdate` 默认 **false** | `SubInfo.autoUpdate=false`(本轮改),`listSubs` 用 `=== true` | 差异已对齐 | 存量数据里显式为 true 的仍生效 |
| 13.2 | `SubscriptionBean.java:114` + `SubscriptionUpdater.kt:43` | `autoUpdateDelay` 默认 **1440 分钟**,`TimeUnit.MINUTES` | `updateIntervalMinutes` 默认 1440;旧 `updateIntervalHours` ×60 迁移 | 差异已对齐 | 备份兼容:两个字段都写(见 `SubInfo:31-45`) |
| 13.3 | `SubscriptionUpdater.kt:36` | `if (minDelay < 15) minDelay = 15`,**无上限** | `normalizeIntervalMinutes:23` 仅下限 15 | 差异已对齐 | 去掉原先 720 上限 |
| 13.4 | `SubscriptionUpdater.kt:30-48` | WorkManager 周期任务 + `initialDelay = now-lastUpdated-minDelay*60` 钳 ≤60s | `needAutoUpdate` 轮询 `nextUpdateAt` | 偏差(平台) | 鸿蒙无 WorkManager;等价性:每次 `now >= nextUpdateAt` 才更新,与 Android 的「到期才跑」同一判据 |
| 13.5 | `SubscriptionUpdater.kt:67-70` | 未连接时滤掉 `updateWhenConnectedOnly` | `needAutoUpdate` 同 | 1:1 | — |
| 13.6 | `SubscriptionUpdater.kt:75` | `now - lastUpdated < delay*60` → 跳过 | 同(用 nextUpdateAt 表达) | 1:1 | — |
| 13.7 | `SubscriptionUpdater.kt:81-86` | 更新期系统通知(id=2) | 无 | 偏差(平台) | 鸿蒙后台任务无通知渠道;可用现有 `LogStore` 日志替代 |
| 13.8 | `GroupUpdater.kt:142-148` | `byUser && (link.startsWith("http://") || updateWhenConnectedOnly) && !connected` → 确认框,取消则整次不更新 | `needDirectUpdateConfirm(url, sub, connected)`(`Subscriptions.ets`) | 差异已对齐(判定层) | 条件逐字复刻并有测试;确认框的 show 调用由 Lead 在 `SubDetailPage.updateNow` 接线 |

---

## 14. 偏差清单(显式列出,不做静默偏离)

### A. 鸿蒙超集(Android 不做,鸿蒙做了;行为不改)

| # | 项目 | Android 行为 | 鸿蒙行为 | 影响 |
|---|---|---|---|---|
| 2.1 | Clash 判定方式 | `text.contains("proxies:")` 子串判定 | 顶层键判定 + HTML 前置闸 | 坏输入下走不同分支,最终节点集合相同;避免把 HTML 错误页当 YAML |
| 2.2 | base64 包裹的非链接正文 | 解 base64 后只按链接解析(WG .conf / JSON 会丢) | 解出后统一分派,WG/JSON 也能导入 | 用户「WG 导出(base64)」可导入 |
| 2.3 | 条件请求(ETag/304) | 无 | 有,且 0 节点时强制脱校验器重下 | 省流量;`tests/sub-etag.cjs` |
| 2.4 | 未知 Clash type 上报 | 静默丢弃,不计数 | 同样丢弃,但计入 `skipped` 并在 UI 提示 | 可诊断性 |
| 2.5 | sing-box outbounds 表示 | 全部 `ConfigBean(config=pretty JSON)` | 已知类型→结构化节点 + `extra` 保留原 JSON;未知类型→CUSTOM 保真 | 可编辑性更好;生成配置语义等价(K1:已知类型不再整份 JSON 相等,去重键随之不同) |
| 2.6 | `server+server_port` 叶子 JSON 的 name | ConfigBean.name 为空 → 显示 `Custom <hash>` | 取 `tag`/`remarks` | 仅显示名 |
| 2.7 | trojan-go JSON/link | `TrojanGoBean`(独立类型) | 映射为 `trojan`(sing-box 无 trojan-go 出站) | 字段:server/port/password/tls;ssl/websocket/shadowsocks 三段在 Android 本就是不生效的死代码 |
| 2.8 | JSON 数组里的字符串元素 | `isJsonObjectValid` 为真 → 强转 JSONArray 抛异常 | 按 JSON 再解析,失败计入 skipped | 只影响畸形输入 |
| 2.9 | 手动去重按钮 | 无 | 设置页「去重本组」保留 | 不影响更新流程;更新流程现在按 Android 语义独立执行 |
| 2.10 | 删除正在运行的节点 | 直接删除 | 本轮改为同样直接删除(仅多一条日志) | 与 Android 一致;此前「保留运行中节点」是鸿蒙自创例外 |
| 2.11 | UA 回退链 | 只有单一 UA | 0 节点时依次换 4 个 UA 重试 | `tests/sub-ua-fallback.cjs` |
| 2.12 | `endpoints` 出站 | 不认(返回 0 节点) | 纯 endpoints 配置可导入 | 仅纯 endpoints 生效 |
| 2.13 | Clash 额外 type(`socks` 旧拼写 / ssh / snell / wireguard / shadowtls) | 静默丢弃 | 导入为节点 | 用户可见的节点数差异;Lead 已拍板保留 |
| 2.14 | `hop-interval` / `ports` YAML 序列 | 不处理 / `toString()` 得到不可用字符串 | 解析 | 端口跳跃可用性 |
| 2.15 | `dialer-proxy` | clash 分支不处理 | 映射为 detour | — |
| 2.16 | 订阅解析失败文案分类 | 单一 `no_proxies_found` | 按 note/skipped 给出可操作原因 | — |
| 2.17 | `skip-cert-verify` 取值宽容度 | 只认布尔 | 还认 `"true"/"1"/"yes"/"on"` | 坏订阅更宽容 |
| 2.18 | `trojan-go://` 链接 | 独立 `TrojanGoBean` + 插件进程 `trojan-go-plugin` | 映射为 TROJAN(原始形态等价);ws 走 `transport=ws` | `encryption`(SS 包裹)、`plugin`(obfs 插件)在 sing-box trojan 无字段 → 这两类链接导入后行为不等价(极少数) |
| 2.19 | 备份里的订阅间隔字段 | 无备份概念 | 白名单同时收 `updateIntervalMinutes` 与 `updateIntervalHours` | 新备份保留分钟精度;旧备份按 ×60 迁移 |

### B. 平台替代(无法逐字复刻,给等价方案)

| # | 项目 | Android | 鸿蒙替代 | 等价性 |
|---|---|---|---|---|
| 1.2 | 订阅请求走本机 mixed 端口 | `trySocks5(mixedPort)` + `tryH3Direct` | `@ohos.net.http` 直连;VPN 已连接时由 TUN 捕获 | 已连接:两端都经隧道;未连接:两端都直连 |
| 1.3 | 强制 TLS1.3 | `restrictedTLS()` | 无 | 只影响握手参数,不影响解析结果 |
| 9.4 | FakeDNS 查询 | `underlyingNetwork.getAllByName` | 系统 DNS | 与 Android 的 else 分支一致 |
| 13.4 | WorkManager 周期任务 | WorkManager | `needAutoUpdate` 轮询 + `nextUpdateAt` | 判据相同(到期才更新) |
| 13.7 | 更新期通知 | 通知栏 id=2 | 无(日志) | 仅反馈形式 |
| 7.3/7.4 | `sn://` 容器 | Kryo 反序列化 | 识别并明确提示不可解包 | 不静默失败 |

### C. 已知怪癖(Android 原样行为,鸿蒙逐字复刻)

1. **tuic `ip` 永不回填 SNI**(`RawUpdater.kt:649-654`):判的是改写后的 IP 地址,条件恒假。鸿蒙此前用「原域名」回填,本轮已删除。→ 这类节点 TLS SNI 为空,与 Android 一样(可能连不上)。
2. **ss `v2ray-plugin` 的 `tls` 只看 `mode == "true"`**(`:285-294`):与 `plugin-opts.tls` 无关。
3. **trojan-go 的 ssl/websocket/shadowsocks 段是死代码**(`TrojanGoFmt.kt:146-160`):`optJSONArray` 对对象恒 null。
4. **去重键无分隔符**(`Protocols.kt:24`):`a.example.com` + `8388` 与 `a.example.com:8388` 之外的拼接可能撞键;且 **vmess 与 vless 共用 VMessBean → 同键**。
5. **`uniqueProxies.retainAll(uniqueNames.keys)` 恒为 no-op**(`RawUpdater.kt:129`):所有键都写入过 value。
6. **Clash 未知 type 无 default → 静默丢弃**(`:248`),不计数、不报错。
7. **hysteria1 的 alpn 只在键存在时处理**(`:566-568`);键不存在则 alpn 为空(不是 h3)。
8. **hysteria1 的 up/down 兜底 100,但键缺失时 bean 默认 10/50**(`HysteriaBean.java:69-70`)。
9. **tuic 默认 `congestionController = "cubic"`**(`TuicBean.java:42`),不是 bbr。

---

## 15. 未完成 / 待决策

| # | 项目 | 状态 | 原因 / 备注 |
|---|---|---|---|
| U1 | `parseProxies` 的行内**空格**切分(`Formats.kt:107-108,230-239`) | **已做** | `parseShareText` 同时构造按行/按空格两份并取数量多的(相等取按行);`tests/sub-parity-subscription.cjs` §23 |
| U2 | `naive+://` 分享链接 | 未做(平台) | naive 在 Android 由**独立插件进程** `naive-plugin` 执行(`BoxInstance.kt:70-73,108-140`),sing-box 1.14 无 naive 出站、鸿蒙沙箱禁止 exec → 无法实现。影响:这类节点被计为 skipped,节点数比 Android 少;`trojan-go://` 已按偏差 2.18 映射(能做) |
| U3 | hysteria1 的 `recv_window_conn` / `recv_window` / `disable_mtu_discovery` 字段 | 未做 | `Profile` 无对应字段(`model/Profile.ets` 已确认);Android 在 `HysteriaFmt.kt:196-201` 映射到 HysteriaBean 并写进 hysteria1 v1 配置 |
| U4 | WireGuard 文件名作为节点名(`RawUpdater.kt:723-725`) | 未做 | 鸿蒙没有「导入 .conf 文件」入口,`parseRaw` 不传 fileName |
| U5 | 更新结果反馈:No difference / Updated N proxies / Diff 四段对话框(`GroupInterfaceAdapter.kt:29-82`) | **组件与纯函数已交付** | `pages/SubUpdateFeedback.ets`(`SubDiffDialog`)+ `subUpdateHasChanges`/`subUpdateToastKind`/`subUpdateDiffBodies`/`subUpdateFeedbackText`;剩余:Lead 在 `SubDetailPage`/`GroupPage` 接线 + 补 §18 文案键 |
| U6 | 手动更新前的确认框(`GroupUpdater.kt:142-148`) | 判定已交付,弹框待接线 | `needDirectUpdateConfirm(url, sub, connected)` 逐字复刻条件并有测试;`SubDetailPage.updateNow` 调用即可 |
| U7 | `Subscription.ets` 的 Clash 判定方式 | 保留(偏差 2.1) | 若要求逐字 `contains("proxies:")`,可一行切换,但会失去 HTML 闸 |

---

## 16. 验证

| 套件 | 结果 |
|---|---|
| `tests/sub-parity-subscription.cjs` | **48 条** Android 等价断言全绿(§1–§25:解析/去重/合并/forceResolve/间隔/反馈/空格切分/trojan-go/naive) |
| `tests/subscription-parse.cjs` | 41 条全绿 |
| `tests/sub-etag.cjs` | 15 条全绿 |
| `tests/sub-ua-fallback.cjs` | 17 条全绿 |
| `tests/ipv6-backup.cjs` | 全绿(备份白名单加 `updateIntervalMinutes` 后复跑) |
| 其余套件 | `clash-auth`/`geo-srs`/`home-view`/`ipv6-store`/`latency-parity`/`outbound-graph`/`per-app` 全绿 |
| 既有失败(不属本块,未改动) | `parity-config.cjs`、`ipv6-modes.cjs`、`route-rules-ui.cjs` |

复跑:

```powershell
cd C:\Worker\NekoBox4Harmony
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
node tests/sub-parity-subscription.cjs
```

---

## 17. 变更记录(可直接粘贴到 `CHANGES.md` 末尾)

### 2026-10-23 — 订阅解析/更新链路与 Android 1.4.2 逐项对齐

**功能**
- 订阅抓取:非 200 一律报错(对齐 `libcore/http.go`);默认 UA 改为 Android 逐字值
  `NekoBox/Android/1.4.2 (Prefer ClashMeta Format)`;新增 `content-disposition`(RFC5987)
  改名(仅当订阅名以 `Subscription #` 开头);`Subscription-Userinfo` 仍解析为结构化字段。
- Clash YAML:10 种 Android 支持的 type 逐字段对齐(`network` 只认 h2/http/ws/grpc、
  `http-opts`、`smux` 按 `enabled` 写字面值、`ech-opts`、`anytls` 键名 `_`→`-` 归一化、
  hysteria1 带宽/默认值、hysteria2 无 alpn + 兜底 0、tuic `ip` 不回填 SNI + 默认 cubic);
  "Fix ent" 两条 fixup 补齐(TLS 且 sni 空 → sni=host;REALITY 指纹回退链需有 pubkey)。
- sing-box JSON:`parseJSON` 分支顺序/条件/跳过名单与 Android 逐字一致
  (`dns/block/direct/selector/urltest` 之外全保留,`group`/`wireguard` 不再跳过);
  新增 JSON 数组递归、裸 `remote_addr`(trojan-go)、`server+server_port` 的 pretty JSON;
  裸 hysteria1 JSON 按 Android 字面 split 与默认值。
- WireGuard ini:多个 `Address` 行不再互相覆盖。
- 去重:键改为 Android 的 `serverAddress + serverPort + javaClass`(无分隔符),时机挪进
  更新流程(由订阅开关门控),duplicate 名单按 Android 算法生成。
- 合并:按 `displayName` 匹配、保留 `customOutbound`/`extra`、`profileBeanEquals` 才更新、
  只变顺序时重排、缺失删除(含运行中节点)、`changed/added/updated/deleted/duplicate` 计数。
- forceResolve:5 并发、`ipv6First = prefer|only`、按类型回填 SNI(Http 仅 TLS、
  V2Ray 仅 TLS、Trojan/Hysteria 无条件、其它不回填)、失败保留域名。
- 自动更新:`autoUpdate` 默认 false;间隔单位改为**分钟**、默认 1440、只钳下限 15(无上限),
  旧小时值 ×60 迁移,旧字段保留以兼容备份。
- 分享链接双份解析:同时按行与按空格切分,**取数量多的那份**(相等取按行),对齐
  `Formats.kt:107-108,230-239` — 「一行多条链接」的订阅不再只导入一条。
- `trojan-go://` 链接导入:按 `TrojanGoFmt.kt:12-44` 取 host/port/password/sni/type(+ws 的
  host、path)/#name,映射为 trojan(`transport=ws`);`encryption`/`plugin` 无对应字段(偏差 2.18)。
  `naive+://` 明确上报为「已跳过」(Android 靠独立插件进程,鸿蒙不可实现)。
- 更新结果反馈:新增 `pages/SubUpdateFeedback.ets`(`SubDiffDialog`)与
  `subUpdateHasChanges` / `subUpdateDiffBodies` / `subUpdateFeedbackText` / `needDirectUpdateConfirm`
  纯函数;Diff 四段顺序、段内 `\n`、段间空行、空段省略、`old => new` 规则全部按
  `GroupInterfaceAdapter.kt:29-82`,`GroupUpdater.kt:142-148` 的直连确认条件逐字复刻。
- 备份:订阅白名单增加 `updateIntervalMinutes`(与 `updateIntervalHours` 并存,旧备份仍按 ×60 迁移)。

**改动文件**
- `entry/src/main/ets/utils/Subscription.ets`
- `entry/src/main/ets/utils/LinkParser.ets`
- `entry/src/main/ets/core/Subscriptions.ets`
- `entry/src/main/ets/core/Backup.ets`(订阅白名单)
- `entry/src/main/ets/pages/SubDetailPage.ets`(间隔输入改分钟)
- `entry/src/main/ets/pages/SubUpdateFeedback.ets`(新增,UI 接线由 Lead 完成)
- `tests/sub-parity-subscription.cjs`(新增,48 条)
- `docs/PARITY-SUBSCRIPTION.md`(新增)

**已知限制 / 偏差**
- 见本文 §14(超集/平台替代/已知怪癖)与 §15(U1~U7 状态)。
- 订阅请求无法走本机 mixed 端口(平台无显式代理),等价性见 §14-B。
- `naive+://` 不可实现(平台无插件进程),节点数会比 Android 少(§15 U2)。
- 更新结果 UI 的**接线**(toast 分支 + Diff 对话框 + 直连确认框)由 Lead 完成;
  组件、纯函数、文案键清单(§18)已交付。

---

## 18. 给 Lead 的文案键清单(U5/U6 用,`string.json` 由 test-parity 独占)

| 键 | 中文 | English |
|---|---|---|
| `group_no_difference` | `%s:没有变化` | `%s: No difference` |
| `group_updated` | `%s:已更新 %d 个代理` | `%s: Updated %d proxies` |
| `group_diff_title` | `差异(%s)` | `Diff (%s)` |
| `group_diff_added` | `新增:\n%s\n\n` | `Added:\n%s\n\n` |
| `group_diff_updated` | `已更新:\n%s\n\n` | `Updated:\n%s\n\n` |
| `group_diff_deleted` | `已删除:\n%s\n\n` | `Deleted:\n%s\n\n` |
| `group_diff_duplicate` | `重复(已忽略):\n%s\n\n` | `Duplicate:\n%s\n\n` |
| `update_subscription_warning` | 当前未连接 VPN,更新订阅会以直连方式进行。继续? | You are not connected. The subscription will be updated directly. Continue? |
| `sub_interval_minutes` | 更新间隔(分钟) | Update interval (minutes) |

---

## 19. 附:本轮关键鸿蒙函数索引

| 阶段 | 函数 | 位置 |
|---|---|---|
| UA 常量 | `SUB_UA` | `Subscription.ets:25` |
| 去重键 | `dedupKeyOf` / `dedupTypeToken` | `Subscription.ets:124` / `:81` |
| content-disposition | `decodeFilename` | `Subscription.ets:165` |
| Clash 入口 | `parseClashProxies` | `Subscription.ets:376` |
| Clash 键归一化 | `yNorm` | `Subscription.ets:488` |
| Clash 传输层 | `applyClashTransport` | `Subscription.ets:609` |
| REALITY / Fix ent | `applyClashReality` / `applyClashFixEnt` | `Subscription.ets:661` / `:682` |
| JSON 分派 | `parseJsonValue` | `Subscription.ets:1436` |
| JSON 入口 | `parseSingBoxConfig` | `Subscription.ets:1550` |
| 改名 | `renameCollisions` | `Subscriptions.ets:398` |
| bean 相等 | `profileBeanEquals` | `Subscriptions.ets:418` |
| 去重 | `dedupProfiles` | `Subscriptions.ets:498` |
| 地址改写 | `applyRewriteAddress` | `Subscriptions.ets:346` |
| 更新主流程 | `updateSubscription` | `Subscriptions.ets:527` |
| 间隔归一化 | `normalizeIntervalMinutes` | `Subscriptions.ets:23` |
| 反馈判据 | `subUpdateHasChanges` | `Subscriptions.ets`(S12 段) |
| Diff 四段正文 | `subUpdateDiffBodies` / `subUpdateFeedbackText` | `Subscriptions.ets`(S12 段) |
| 直连确认 | `needDirectUpdateConfirm` | `Subscriptions.ets`(S12 段) |
| Diff 对话框 | `SubDiffDialog` / `subUpdateToastKind` / `subDiffSections` | `pages/SubUpdateFeedback.ets` |
| 分享链接双份解析 | `parseShareText` / `parseLinkBatch` | `LinkParser.ets` |
| trojan-go 链接 | `parseTrojanGoLink` | `LinkParser.ets` |
| 备份订阅白名单 | `validateSubscription` | `Backup.ets:136-148` |
