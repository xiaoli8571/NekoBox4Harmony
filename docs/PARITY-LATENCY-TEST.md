# 节点测试（TCPing / URL Test）1:1 对齐审计 —— Android NekoBoxForAndroid 1.4.2 ↔ NekoBox4Harmony

> 审计日期：2026-10-23
> Android 基线：`C:\Worker\rea-tmp\nb4a`（NekoBoxForAndroid，git `5768494` = 1.4.2）
> 鸿蒙基线：`C:\Worker\NekoBox4Harmony` @ `de481f56`（2.1.8 / 2100008 之后）
> 上游确证来源：`github.com/matsuridayo/libneko/speedtest/speedtest.go`（main 分支，全文已拉取）
> 本文档是"逐项对比 + 判定"的取证记录；改前/改后在"鸿蒙现状"列以 **改前 → 改后** 标注。

## 0. 结论摘要

| 维度 | 改前判定 | 改后判定 |
|---|---|---|
| 入口与作用域（菜单项、当前分组、runningTest 互斥） | ❌ 差异（只有 1 个"测速"入口；清除/删除作用于全部组；无互斥按 Android 语义） | ✅ 1:1（TCPing / URL Test 两个入口、当前分组作用域、testing 互斥+取消） |
| 并发模型（默认 5、每 worker 队列） | ⚠️ 差异（默认 10；队列语义相同） | ⚠️ 部分 1:1（默认 5、队列相同；**实例粒度不同**，见 §3 与偏差 D-1） |
| TCPing（协议过滤 / 域名解析 / 超时 / 错误分类） | ❌ 差异（无过滤、超时吃设置、失败一律 -1 无分类） | ✅ 1:1（canTCPing 过滤、先解析取 `[0]`、固定 3000、status 2/3 分类） |
| URL Test（不过滤协议 / 固定 5000 / 错误分级） | ⚠️ 差异（超时读设置、默认判 2xx、失败 -1 无分级） | ✅ 1:1（不筛协议、默认 5000、默认不判状态码、失败 status 3 原文） |
| 测量口径（GET/HEAD、两次请求、计时区间） | ❌ 差异（内核 HEAD 单次、含建连+TLS） | ❌ **受限差异**（.so 冻结，见偏差 D-2 + 替代方案） |
| 结果语义（status/ping/error 持久化与展示） | ❌ 缺失（只存 latencyMs，150/400 阈值着色） | ✅ 1:1（status 0/1/2/3 + ping + error 持久化、绿/红两档、status3 点击弹原文） |
| 配置形态 buildConfig(forTest=true) | ⚠️ 大体一致（DNS 两级链改单探针、auto_detect_interface=false 平台必需） | ✅ 等价（差异逐条有据，见 §7） |
| 默认值与设置项 | ❌ 差异（URL=gstatic、并发 10、重试 1、判 2xx） | ✅ 1:1 默认（URL=cp.cloudflare.com、并发 5、重试 0、不判状态码） |
| 连接中测当前节点 | ⚠️ 差异（超时 5000、无友好化映射） | ✅ 1:1（超时 3000、genFriendlyMsg 等价映射、Bearer 鉴权保留） |

**本轮唯一允许的实现方式偏离**：URL Test 仍是"整批节点一个测速会话"，不是 Android 的"每节点一个临时实例"（内核 API 约束，见偏差 D-1）。
**唯一无法消除的效果偏离**：单次探测的测量口径（HEAD/单次/含建连握手 vs GET/两次/暖连接 RTT，见偏差 D-2）。

---

## 1. 入口与作用域

| Android 证据 | 行为 | 鸿蒙（改前 → 改后） | 判定 |
|---|---|---|---|
| `res/menu/add_profile_menu.xml:96` | ⋮ 菜单「移除重复」 | `Index.ets:2194` `dedup`（本轮不动，Lead 处理） | ✅ 有 |
| `add_profile_menu.xml:99` + `ConfigurationFragment.kt:586-588` | ⋮ 菜单「TCPing」→ `pingTest(false)` | 改前：无独立入口，只有 `latencyTestMode` 设置切换（`Index.ets:603`）<br>改后：⋮ 菜单项 `connection_test_tcp_ping` → `runTcpTest(groupId)`，测速期间该项换成「取消」 | ✅ 1:1 |
| `add_profile_menu.xml:102` + `ConfigurationFragment.kt:590-592` | ⋮ 菜单「URL Test」→ `urlTest()` | 改后：⋮ 菜单项 `connection_test_url_test` → `runSpeedTest(groupId,'url')` | ✅ 1:1 |
| `add_profile_menu.xml:105` + `ConfigurationFragment.kt:477-493` | 「清除测试结果」作用于 `DataStore.currentGroupId()`：逐条 `status!=0` → `status=0,ping=0,error=null`，有变化才批量落库 | 改前：`clearTestResults('__all__')`（全部组）+ 只清 `latencyMs/latencyTestedAt`<br>改后：传 `selectedGroupId`；按 status 清 `status/ping/error/latencyMs/latencyTestedAt`，有变化才 `saveProfiles` | ✅ 1:1 |
| `add_profile_menu.xml:108` + `ConfigurationFragment.kt:495-532` | 「删除不可用」作用于当前组：条件 `status!=0 && status!=1`（即 2/3），先确认对话框再 `deleteProfile2` | 改前：`'__all__'` + 条件 `latencyMs===-1`<br>改后：当前组 + 条件 `status===2 || status===3`，确认框保留 | ✅ 1:1 |
| `ConfigurationFragment.kt:699,840` `DataStore.currentGroup()` + `ProxyEntity.kt:492 getByGroup(groupId)` | 测速对象 = 当前分组全部节点 | `Index.ets:538` `profiles.filter(groupId===selectedGroupId)`（2026-10-17 已按"只测当前分组"改造） | ✅ 1:1 |
| `DataStore.kt:45 runningTest` + `ConfigurationFragment.kt:695,836` | 互斥：进行中再触发直接 return（静默） | 改前：`this.testing` 卫兵 + toast `index_test_in_progress`（比 Android 多一句提示）<br>改后：保留 toast，另加「取消测速」，取消后仍落库 | ⚠️ 超集（提示文案） |
| `ConfigurationFragment.kt:807-823,876-891` | 取消/结束：`dialogStatus=2` → 取消所有 job → 对已完成节点 `ProfileManager.updateProfile` 落库 → `GroupManager.postReload` → `runningTest=false` | 改后：`isCancelled()` 回调 → 停止取新节点 → `finally` 里 `flushPending()`+`saveProfiles(this.profiles)`+`this.profiles=this.profiles.slice()`（等价 postReload）；`testing=false` | ✅ 1:1（无通知最小化，见 §6） |
| `ConnectionTestNotification.kt:11-27`（`"$progress / $max"` + 进度条，结束 cancel） | 最小化到通知 | 无对应（鸿蒙无测试对话框/通知） | ❌ 缺失（§6 列出） |
| `ConfigurationFragment.kt:597-690 TestDialog`（进度 `"$progress / $proxyN"`、当前节点名称+类型+结果着色） | 测试进度对话框 | 改前/改后：节点卡就地显示"测试中…"＋toast 计数（`index_testing_count`），无对话框 | ⚠️ 形态差异（信息等价可见） |

## 2. 并发模型

| Android 证据 | 行为 | 鸿蒙（改前 → 改后） | 判定 |
|---|---|---|---|
| `DataStore.kt:159` `connectionTestConcurrent` 默认 **5** | 并发 worker 数 | 改前：`AppSettings.testConcurrent` 默认 **10**<br>改后：默认 **5**（`Profile.ets:198` 及 `Store.loadSettings` 兜底） | ✅ 1:1 |
| `moe/matsuri/nb4a/ui/UrlTestPreference.kt:33,44` + `layout_urltest_preference_dialog.xml:42` | Android **没有**并发设置入口（字符串 `test_concurrency` 存在但未接 preference） | 设置页「测速并发数」输入框（`SettingsPage.ets:558-567`，钳制 1..32） | ⚠️ 鸿蒙超集（默认已对齐） |
| `ConfigurationFragment.kt:715-719 / 845-850` `ConcurrentLinkedQueue` + `repeat(N){ launch(IO){ while(isActive){ poll() } } }` | 每 worker 一个队列，poll 到空即退出 | `LatencyTester.ets:266-304` 共享 `nextIdx` 的 worker 池 + `Promise.all`；语义相同（先到先取、取完退出） | ✅ 1:1（队列语义） |
| `ConfigurationFragment.kt:848` `val urlTest = UrlTest()` 在 worker 内 | 每 worker 一个 `UrlTest` 对象（link/timeout 快照） | `urlTestProfiles` 在入口处读取一次 `testUrl`/`timeoutMs`，全体 worker 共享 | ✅ 等价（link/timeout 语义相同，对象粒度不同但无可观察差异） |
| `ConfigurationFragment.kt:721,851` `profile.status = 0` | 开测即把该节点标为"测试中" | 改后：分发节点前 `onResult(id, 0, 0, '')` 标记 status=0 | ✅ 1:1 |

## 3. 实例生命周期（实现方式差异，见偏差 D-1）

| Android 证据 | 行为 | 鸿蒙（改前 → 改后） | 判定 |
|---|---|---|---|
| `TestInstance.kt:16-41` | 每个节点：`TestInstance(profile, link, timeout)` → `doTest()` | 整批一次 `buildLatencyTestConfig(targets,...)`（`ConfigBuilder.ets:1349`）→ `CoreManager.testStart` → 逐 tag `testProxy` | ⚠️ 实现方式差异 D-1 |
| `TestInstance.kt:43-45` `buildConfig(profile, true)` | 测试配置 = 该节点一个出站 | 批量配置里每节点一个出站 `t<i>`（另含链/前置代理展开的 hop 出站与 endpoints） | ⚠️ 同上（等价性论证见 D-1） |
| `TestInstance.kt:47-51` `Libcore.newSingBoxInstance(config.config, LocalResolverImpl)` | 每节点新建 box 实例 | 整批一个测试实例（`core/libsingbox14/main.go:168 box.New`） | ⚠️ 同上 |
| `TestInstance.kt:29 launch()` → `BoxInstance.kt:202 box.start()` | 启动实例 | `CGoTestStartSingBoxV2` → `newInstance.Start()`（`main.go:174`） | ⚠️ 同上 |
| `TestInstance.kt:30-33` `if (processes.processCount > 0) delay(500)` | 有插件进程时等 500ms 起进程 | 无插件机制（鸿蒙内核内置全部协议，无外部插件进程） | ✅ 不适用（无对应物） |
| `TestInstance.kt:34` `Libcore.urlTest(box, link, timeout)` | 探测 | `CoreManager.testProxy(tag, url, timeoutMs, expectStatus)`（`CoreManager.ets:111`） | ✅ 等价 |
| `TestInstance.kt:26 use{}` → `BoxInstance.kt:206-220 close()` | 每节点 close 实例 | 整批结束 `CoreManager.testStop()`（`LatencyTester.ets:306`） | ⚠️ 同上 |
| 无（Android 每实例独立，配置非法只影响该节点） | 单节点配置非法 → 该节点 status=3，其它节点照测 | 改后：`buildLatencyTestConfig` 逐节点 try/catch（`ConfigBuilder.ets:1357-1366`）给不出 tag 的节点直接标 status=3（内核 offbound 错误不再拖垮整批）；测试实例启动失败仍是整批降级 TCPing（内核级故障） | ✅ 已尽力对齐，残余见 D-1(c) |

## 4. TCPing 细节

| Android 证据 | 行为 | 鸿蒙（改前 → 改后） | 判定 |
|---|---|---|---|
| `ConfigurationFragment.kt:702-713` `canTCPing()` 过滤 | 不支持 TCPing 的协议**不参与** | 改前：无过滤，所有节点都测<br>改后：`LatencyTester.canTCPing()` 过滤（hysteria/hysteria2/tuic/wireguard/custom/chain → false） | ✅ 1:1 |
| `AbstractBean.java:51` 默认 true；`HysteriaBean.java:159`、`TuicBean.java:102`、`WireGuardBean.java:58`、`InternalBean.java:18`、`NekoBean.java:73` 为 false | 协议支持表 | 同上（`InternalBean` = 自定义 config → 鸿蒙 `ProfileType.CUSTOM`；`NekoBean` → 鸿蒙 `ProfileType.CHAIN`） | ✅ 1:1 |
| `ConfigurationFragment.kt:722-732` `underlyingNetwork.getAllByName(address)`，`if (isNotEmpty()) address = this[0].hostAddress` | 先解析域名，**取第一个地址**（不挑 v4/v6，按系统解析顺序） | 改前：`connection.getAddressesByName` 后**显式优先 IPv4**（`LatencyTester.ets:48-70`）<br>改后：取 `addrs[0].address`（与 `getAllByName()[0]` 同语义） | ✅ 1:1 |
| `ConfigurationFragment.kt:734-739` 解析后仍非 IP → `status=2` + `connection_test_domain_not_found` | 解析失败即失败 + 专门文案 | 改后：`status=2, error='domain_not_found'`（token → `connection_test_domain_not_found`） | ✅ 1:1 |
| `ConfigurationFragment.kt:748` `socket.soTimeout = 3000` | 读超时 3000 | 无读操作；连接超时见下 | ✅ 等价 |
| `ConfigurationFragment.kt:751-755` `socket.connect(..., 3000)` | 连接超时 3000（固定） | 改前：`testTimeoutMs`（默认 5000）<br>改后：固定 **3000**（`TCPING_TIMEOUT_MS`） | ✅ 1:1 |
| `ConfigurationFragment.kt:750,758` `SystemClock.elapsedRealtime()` 差值 | 计时含 bind+connect | `LatencyTester.tcpPing` `Date.now()` 差值（bind 前取时，`LatencyTester.ets:74`） | ✅ 等价 |
| `ConfigurationFragment.kt:757-758` `status=1; ping=ms` | 成功 | 改后：`status=1, ping=ms, error=''` | ✅ 1:1 |
| `ConfigurationFragment.kt:773-777` `!message.contains("failed:")` → `connection_test_timeout` | 非 `failed:` 前缀 = 超时 | `classifyConnectError()`：`timeout/timed out/deadline` → `timeout` | ⚠️ 判据不同（鸿蒙 socket 错误无 `failed:` 前缀），结果集相同 |
| `ConfigurationFragment.kt:778-781` `ECONNREFUSED` → `connection_test_refused` | 拒连 | `refused/econnrefused` → `refused` | ✅ 1:1 |
| `ConfigurationFragment.kt:783-786` `ENETUNREACH` → `connection_test_unreachable` | 不可达 | `unreachable/enetunreach` → `unreachable` | ✅ 1:1 |
| `ConfigurationFragment.kt:788-791` 其它 → `status=3` + 原文 | 未分类错误保留原文 | `status=3, error=原文` | ✅ 1:1 |
| `ConfigurationFragment.kt:768-771` ICMP 分支错误 → `status=2` + `connection_test_unreachable` | ICMP 分支已移除（`:741-742 // removed`），菜单也无 ICMP 项；`canICMPing()` 仅残留 | 鸿蒙无 ICMP 分支 | ✅ 一致（都没有） |

## 5. URL Test 细节

| Android 证据 | 行为 | 鸿蒙（改前 → 改后） | 判定 |
|---|---|---|---|
| `ConfigurationFragment.kt:843` `getByGroup(group.id)` **不过滤协议** | 组内全部节点都测 | `Index.ets` 目标集合同样不筛类型（全部 `groupId` 匹配节点） | ✅ 1:1 |
| `UrlTest.kt:8` `link = DataStore.connectionTestURL` | 探测网址取自设置 | `settings.testUrl`（`LatencyTester.ets:212`），空值兜底默认 | ✅ 1:1 |
| `UrlTest.kt:9` `timeout = 5000`（私有常量，无设置 UI） | 固定 5000 | 改前：`settings.testTimeoutMs`（默认 5000）<br>改后：仍读设置但**默认 5000 对齐**；设置项是鸿蒙超集 | ✅ 默认 1:1 / ⚠️ 超集 |
| `ConfigurationFragment.kt:853-856` 成功 → `status=1; ping=result` | 成功语义 | 改后：`status=1, ping=ms` | ✅ 1:1 |
| `ConfigurationFragment.kt:857-859` `PluginNotFoundException` → `status=2` + 原文 | 缺插件 = 已知失败 | 无插件机制 ⇒ 不会出现该异常 | ✅ 不适用 |
| `ConfigurationFragment.kt:860-862` 其它异常 → `status=3` + `readableMessage` | 失败保留原文 | 改前：`-1`（丢原文）<br>改后：`status=3` + 内核错误原文（`err:` 前缀剥掉） | ✅ 1:1 |
| `Protections.kt:53-66` `genFriendlyMsg`：lowercase 含 `timeout/deadline` → Timeout；含 `refused/closed pipe` → Connection refused；否则原文 | 展示期友好化 | 改后：`LatencyTester.genFriendlyMsg()` 同规则（token 化：`timeout`/`refused`/原文），展示期映射 `connection_test_*` | ✅ 1:1 |
| 无（Android 不判状态码，见 libneko） | 403/500 也算通 | 改前：默认 `'2xx'`（判状态码，会假红）<br>改后：默认 `'any'` | ✅ 1:1 |
| 无（Android 不重试、不取样） | 单次探测 | 改前：`testRetries=1`、`testSamples=1`<br>改后：默认 `0/1`（旋钮保留为超集） | ✅ 默认 1:1 |

## 6. 结果语义、存储与展示

| Android 证据 | 行为 | 鸿蒙（改前 → 改后） | 判定 |
|---|---|---|---|
| `ProxyEntity` 字段 `status/ping/error`（写入 `ConfigurationFragment.kt:721,735-736,757-758,769-770,773-793,855-862`） | 三件套持久化 | 改前：只有 `latencyMs`（0/-1/ms）<br>改后：`Profile.status/ping/error` + `latencyMs` 派生（兼容排序/徽标/通知） | ✅ 1:1 |
| `ConfigurationFragment.kt:1565-1592` 列表项：`status<=0` → 流量文本或空；`status==1` → `available`（`strings.xml:321` = `%dms`）绿色；`status==2` → `error` 红色；`status==3` → `genFriendlyMsg` 或 `unavailable` 红色；点击 error 弹原文 | 展示与着色 | 改前：`latencyText`（`Index.ets:890-902`）失败显示"超时"、`latencyColor`（`:904-922`）**150/400 三档阈值**<br>改后：status 1 → `${ping}ms` 绿；2/3 → 文案红（2 映射 token、3 映射后仍失败则 `unavailable`）；0 → 空；测速中 → "测试中…"（次要色）；status==3 点击弹原文 | ✅ 1:1（阈值删除） |
| `ConfigurationFragment.kt:639-666` 对话框着色：`-1` error 次要色 / `0` "Testing…" 次要色 / `1` 绿 / `2` 红 / `3` 红 | 测试中态 | 改后：节点卡显示 `connection_test_testing`（次要色），不再是 `…` | ✅ 1:1 |
| `ConfigurationFragment.kt:686` `"$progress / $proxyN"` | 进度 | 无对话框；toast `index_testing_count`（"正在测速 N 个节点…"）+ 每节点就地更新 | ⚠️ 形态差异 |
| `ConfigurationFragment.kt:824-831` 最小化 → 通知 `"[分组] 连接测试"` | 最小化 | 无 | ❌ 缺失（§8） |
| `ConfigurationFragment.kt:815-819` `ProfileManager.updateProfile()` 落库 | 结果持久化 | `saveProfiles(this.profiles)`（`Index.ets:616`，改后移到 finally 保证取消也落库） | ✅ 1:1 |
| `ConfigurationFragment.kt:820` `GroupManager.postReload(currentGroupId)` | 刷新列表 | `this.profiles = this.profiles.slice()` | ✅ 等价 |

## 7. 测试配置形态（`buildConfig(profile, forTest=true)`）

| Android 证据 | forTest 行为 | 鸿蒙 `buildLatencyTestConfig`（`ConfigBuilder.ets:1349-1392`） | 判定 |
|---|---|---|---|
| `ConfigBuilder.kt:62-64` | `buildConfig(proxy, forTest=true, forExport=false)` | `buildLatencyTestConfig(targets, allProfiles, s, logPath, groups)` | ✅ 等价入口 |
| `:126,:128` | `rules=[]`、额外规则出站不解析 | `route.rules=[]`（`:1385`） | ✅ 1:1 |
| `:131` `buildSelector = !forTest && …` | 不建 selector 出站 | `buildLatencyTestConfig` 不建 selector（只走 `buildProfileGraph`，`ConfigBuilder.ets:1360`） | ✅ 1:1 |
| `:136` `bind = 127.0.0.1` | 监听地址 | 无入站 | ✅ 等价（无监听） |
| `:142` `useFakeDns = enableFakeDns && !forTest` | 不启用 fakeip | 不写 fakeip | ✅ 1:1 |
| `:146` `ipv6Mode = ENABLE` | 测试固定 ENABLE（prefer_ipv4） | 未写 ipv6 策略（内核默认 prefer_ipv4） | ✅ 等价 |
| `:159-164` | 不写 `experimental.clash_api` | 不写 | ✅ 1:1 |
| `:198-236` | 无 TUN/mixed 入站 | 无 `inbounds`（内核侧再强制清空，`main.go:157`） | ✅ 1:1 |
| `:650-664` | DNS 两级直连链：`dns-local`（address `local`）+ `dns-direct`（`address_resolver=dns-local`） | 单个 `probe` 服务器（IP 字面量，无需 bootstrap），`dns.final=probe`、`route.default_domain_resolver=probe` | ✅ 效果等价，形态不同 |
| `:666-674` | forTest **不写** `dns-remote` | 只写一个直连 DNS | ✅ 1:1 |
| `:676` | `final_ = "dns-direct"` | `dns.final = 'probe'` | ✅ 等价 |
| `:685-686` | `dns.rules=[]` | 不写 dns.rules | ✅ 1:1 |
| `:242` `route.auto_detect_interface = true` | 自动探测默认网卡 | `route.auto_detect_interface=false`（`ConfigBuilder.ets:1387`） | ⚠️ 平台必需（OHOS 补丁 2：netlink monitor 早退，`true` 会拿不到默认网卡） |
| 无 `route.final`（grep 全文） | final 不写，由 boxapi 直接指定拨号出站 | `route.final='direct'`，probe 用**显式 tag** `t<i>`（`CoreManager.testProxy(tag,…)`） | ✅ 等价（都显式指定被测出站） |
| `:741` | forTest 不套 `globalCustomConfig` | 不套 | ✅ 1:1 |
| `:744` `Util.mergeJSON(configMap, profile.customConfigJson)` | **每节点自定义配置仍合并** | `buildOutbound`→`buildProfileGraph` 走与主配置同一出站构建（含 custom 合并/hop 展开），沿用既有 `outbound-graph.cjs` 断言 | ✅ 1:1（沿用既有覆盖） |
| `:166-175` log level 取 `DataStore.logLevel` | 有日志选项 | 固定 `level=warning` + 写 `test.log` | ⚠️ 平台补偿（真机排障需要文件日志） |
| `BoxInstance.kt:57-88` 链节点展开为外部进程/出站 | 链式结构（front/landing） | `buildProfileGraph` 展开 hop + group front/landing（`ConfigBuilder.ets:750-793`） | ✅ 1:1 |

## 8. 连接中测当前节点（StatsBar / MainActivity）

| Android 证据 | 行为 | 鸿蒙（改前 → 改后） | 判定 |
|---|---|---|---|
| `StatsBar.kt:128-142` 点击状态栏 → `activity.urlTest()` | 入口 | `Index.ets:924-947 runUrlTest(p)`（节点菜单/选中节点） | ✅ 等价入口 |
| `MainActivity.kt:150-155` → `BaseService.urlTest()` | 走**运行中实例** | 走 clash API `/proxies/proxy/delay`（当前激活出站） | ✅ 等价（都测运行实例） |
| `BaseService.kt:146-148` `Libcore.urlTest(box, connectionTestURL, **3000**)` | 超时 **3000** | 改前：5000<br>改后：3000 | ✅ 1:1 |
| `BaseService.kt:150` `error(genFriendlyMsg(e.readableMessage))` | 错误友好化 | 改前：裸错误文本<br>改后：`genFriendlyMsg()` 映射 | ✅ 1:1 |
| `StatsBar.kt:131-137` 成功文案按 URL 前缀选 `connection_test_available`（https）/`connection_test_available_http` | 成功提示 | 改后：同样按 `https://` 前缀选择两条文案 | ✅ 1:1 |
| `StatsBar.kt:148-153` 失败 → `connection_test_error`（`Failed: %s`） | 失败提示 | 改后：`connection_test_error` + 友好化文本 | ✅ 1:1 |
| `ClashApi.ets:13-40` + `ClashAuth.ets` | Bearer 鉴权（2.1.6 401 修复） | 保留（`tests/clash-auth.cjs` 覆盖） | ✅ 保留 |

---

## 9. 鸿蒙额外能力（Android 没有，全部保留并在 UI/文档标注为超集）

| 能力 | 位置 | 说明 |
|---|---|---|
| 内核测速失败自动降级 TCPing + 显式 toast | `LatencyTester.ets:216-228`、`Index.ets:609-613` | 平台补偿：`.so` 可能缺 V2 导出（legacy）/ 起不来；Android 无这条路径 |
| 测速绑定物理网卡绕过隧道（`testBypassTunnel`） | `LatencyTester.ets:236-256`、`resolvePhysicalIfname` :339 | 平台补偿：Android 的 TestInstance 跑在 UI 进程且无 VPN 路由，天然直出；鸿蒙 UI 进程在 VPN 开启时会被 TUN 吸入，必须 `SO_BINDTODEVICE` 才与 Android 等价 → **默认 true，语义等同 Android**，不是"额外旋钮" |
| 绑定后全红自动去绑定重测 | `LatencyTester.ets:322-334` | 真机保守兜底 |
| 失败重试 / 多次取样 / 期望状态码 / 超时可配 | `AppSettings.testRetries/testSamples/testExpectStatus/testTimeoutMs` | 默认值已全部改成 Android 口径（0/1/'any'/5000） |
| 并发可配 | `SettingsPage.ets:558-567` | 默认 5 = Android；Android 无 UI |
| 「测速方式」设置（url/tcp） | `SettingsPage.ets:533-557` | Android 无此设置（它有两个独立菜单项）。现在只用于分组条长按菜单里的「测速本组」快捷项；⋮ 菜单的 TCPing / URL Test 两个入口**忽略**它，避免"点 URL Test 却跑 TCPing" |
| 组头最低延迟徽标 / n 未测 | `Index.ets:1658-1664` | G2 阶段功能，保留；徽标仍按 150/400 分档着色（仅组头使用，与节点 status 双档着色并存，Android 无组头徽标） |
| 桥接调用兜底超时（防 native 挂死） | `LatencyTester.ets:146-171` | 修 2.1.8"测速卡死" |
| 结果 300ms 合并刷新（防大订阅 UI 刷爆） | `Index.ets:560-600` | 修 2.1.8"测速卡死" |
| 延迟结果陈旧灰显（`latencyStaleMs`） | `Index.ets` 节点卡 | 鸿蒙独有 |

## 10. Android 有而鸿蒙没有

| 项 | 影响 | 处置 |
|---|---|---|
| 测试进度对话框（当前节点名/类型/结果着色、`n / N`） | 观感差异 | 本轮不做（需要新 CustomDialog，改动面大）；节点卡就地显示"测试中…"覆盖核心信息 |
| 最小化到通知（含进度条） | 无法离开应用继续看进度 | 本轮不做（需要常驻通知通道 + 前后台协同）；列入 §12 待办 |
| 每节点临时实例的隔离性 | 见 D-1 | 内核约束，文档记录 |
| 插件缺失提示（`PluginNotFoundException` → status 2） | 鸿蒙无插件体系 | 不适用 |
| ICMPing（分支已移除，仅剩 `canICMPing()` 残留与字符串） | 无 | 一致（Android 也无入口） |

---

## 11. 偏差清单（必须如实告知）

### D-1 实现方式差异：整批会话 vs 每节点临时实例（Lead 裁定保留批量）
- **Android**：每节点 `TestInstance`（`buildConfig(profile,true)` → `newSingBoxInstance` → `box.start()` → probe → `close()`），每 worker 独立实例，可 N 并发。
- **鸿蒙**：一次 `buildLatencyTestConfig(all targets)` → `testStart` → 按 tag 并发 `testProxy` → `testStop`。
- **为什么不能逐字实现**：`core/libsingbox14/main.go:180` 的 `testInstance` 是**包级单例**，`CGoTestStartSingBoxV2`（:194）直接覆盖、`CGoTestStopSingBox`（:240-255）整体关闭。要"每节点一个实例"就只能把 `start→probe→stop` 全局串行，URL Test 有效并发退化为 1：100 节点从 `≈(N/5)×t` 变成 `Σt`，死节点（5s 超时）场景慢一个数量级 —— 改变的是用户能看见的效果，与"1:1 效果"目标相反。
- **等价性论证**（为什么观感一致）：
  1. 每次 `testProxy(tag)` 都通过该 tag 的出站**新建连接**（`common/urltest/urltest.go:140 detour.DialContext`），节点之间不共享连接/TLS 会话/统计状态；批量配置不引入跨节点状态。
  2. 被测配置里多放几个出站不影响单次 probe 结果：probe 只经**指定 tag** 拨号，路由/DNS 与节点数量无关。
  3. 唯一可观察的差异是"配置本身非法"：Android 该节点 status=3、其它照测。鸿蒙已尽量对齐 —— `buildLatencyTestConfig` 逐节点 try/catch，构建不出出站的节点直接判 status=3，不再拖垮整批（`ConfigBuilder.ets:1357-1366` + `LatencyTester` 对空 tag 的处理）；残余差异只在**内核拒绝整份配置**（例如链式 hop 引用失效导致 `box.New` 失败）时，鸿蒙整批降级 TCPing 而 Android 只红该节点。
- **要逐字 1:1 需要**：内核新增 `CGoTestStartSingBoxV3(configPath, bindIfname) → sessionId`、`CGoTestProxySingBoxV3(sessionId, tag, …)`、`CGoTestStopSingBoxV3(sessionId)`，测试会话改为 `map[id]*box.Box`。**本轮不实施**：Lead 裁定本轮不动内核；且本机（Windows 工作区）没有 AGENTS.md 里那套 OHOS Go fork 工具链（`core/scripts/build-ohos-toolchain.sh` 为 bash + openharmony-sig 分支编译），重编 `entry/libs/arm64-v8a/libsingbox.so` 必须先在新机器/服务器上把工具链备齐，再做 7 组补丁的 fail-closed 校验。

### D-2 测量口径差异（无法消除，除非重编内核）
- **Android（libneko `speedtest.UrlTest(..., UrlTestStandard_RTT)`，源码已拉取确证）**：
  - 方法 **GET**（`http.NewRequestWithContext(ctx,"GET",link,nil)`）；
  - `CheckRedirect` 返回 `errNoRedir`，调用处把该错误**当成功**吞掉 ⇒ 重定向也算通过；
  - `times = 2`：同一个 `http.Client` 连发两次 GET，各自 `resp.Body.Close()`（keep-alive 复用连接）；
  - 计时：`hsk_end` 由**第二次**请求的 `WroteHeaders`（复用连接时不触发 TLSHandshakeDone）刷新，`time_end` 由 `GotFirstResponseByte` 刷新，RTT 口径取 `time_start = hsk_end` ⇒ **暖连接 headers-written → 首字节**，不含建连与 TLS；
  - **完全不看 HTTP 状态码**；整体 `context.WithTimeout(5000ms)`；返回 `int32` ms（无上限）。
- **鸿蒙（`core/sing-box-1.14/common/urltest/urltest.go`，OHOS 补丁 7）**：单次 **HEAD**（仅 405/501 回退 GET）；计时 `start` 在 dial 之后、`NeedHandshakeForWrite` 时重置 ⇒ 含 TLS 握手 + 一次请求往返；`Expect2xx` 可关（默认已改为关 = 'any'）；返回 `uint16` ms（>65535 截断）。
- **结论**：同一节点，鸿蒙数值系统性偏高（≳1 个 RTT + TLS 握手，HTTPS 网址最多 2 个 RTT），且 `HEAD` 与 `GET` 在个别站点上可达性不同。**已做**：默认探测网址改成 Android 的 `http://cp.cloudflare.com/`（HTTP，去掉 TLS 变量）+ 默认不判状态码 + HEAD→GET 回退，把差距压到最小。
- **要完全一致**：需在 `common/urltest` 增加 `UrlTestStandard_RTT` 等价实现（GET ×2、keep-alive、`httptrace` WroteHeaders→GotFirstResponseByte、不判状态码）并暴露为 `CGoTestProxySingBoxV3(..., 'rtt')`；补丁形态是"移植 libneko `speedtest.UrlTest` 到 `core/sing-box-1.14/common/urltest/rtt.go` + 包装层选择 standard"。**本轮不实施**（同 D-1：Lead 裁定本轮不动内核，本机亦无编译工具链）。

### D-3 其他次要偏差
| # | 偏差 | 原因 | 替代 |
|---|---|---|---|
| D-3.1 | 无测试进度对话框与"最小化到通知" | 需要新 CustomDialog + 常驻通知协同，改动面超出本轮 | 节点卡"测试中…" + toast 计数 |
| D-3.2 | TCPing 错误判据用关键字而非 Android 的 `failed:` 前缀/errno | OHOS `@ohos.net.socket` 抛的是 `{code,message}` 而非 errno 文本 | 关键字映射 + 未命中走 status=3 原文（与 Android 结构一致） |
| D-3.3 | DNS 服务器形态：单探针 vs `dns-local`+`dns-direct` 两级 | 鸿蒙探针 DNS 固定为 IP 字面量，无需 bootstrap | 效果等价 |
| D-3.4 | `route.auto_detect_interface=false` | OHOS 补丁 2 关闭 netlink monitor，`true` 会拿不到默认网卡 | 平台必需 |
| D-3.5 | 日志固定 `level=warning` + 文件输出 | 真机排障需要 | 平台补偿 |
| D-3.6 | 无插件 500ms 等待 | 鸿蒙无外部插件进程 | 不适用 |
| D-3.7 | 状态 2 的 error 存机器 token（`timeout/refused/unreachable/domain_not_found`）而非本地化文本 | 鸿蒙需中英双语；Android 直接存 `getString()` 结果 | 展示期映射，文本与 Android 同名资源一致 |
| D-3.8 | 备份 schema 暂不包含新增 `status/ping/error` | `Backup.ets` 不在本轮写作用域 | 旧值 `latencyMs` 仍能恢复 status 1 与失败态；Lead 统一补 |
| D-3.9 | `status==0` 的节点卡延迟位置显示占位符 `—`（Android 留空） | ArkUI 文本宽度塌陷会让行高跳动 | 视觉占位，无语义 |
| D-3.10 | 测速期间被测节点显示"测试中…"（次要色）而不是 Android 对话框的 `Testing…` | 无测试对话框，用节点卡就地显示承载同一信息 | 文案与 Android 同名资源一致 |

---

## 12. 改动清单（本轮）

| 文件 | 改动 |
|---|---|
| `entry/src/main/ets/model/Profile.ets` | `Profile.status/ping/error` 新增（`latencyMs/latencyTestedAt` 保留为派生值，兼容排序/组徽标/通知）；`AppSettings` 默认值对齐（testUrl=`http://cp.cloudflare.com/`、testConcurrent=5、testRetries=0、testSamples=1、testExpectStatus='any'、testTimeoutMs=5000） |
| `entry/src/main/ets/model/Store.ets` | `loadProfiles` 旧数据迁移（latencyMs → status/ping/error；已有 status 的重算派生值）；`loadSettings` 默认/钳制对齐（去掉 5→10 迁移与 testUrl 两段改写，存量装机保存的网址一律不动） |
| `entry/src/main/ets/utils/LatencyTester.ets` | `canTCPing` 协议过滤；TCPing 固定 3000、域名取首个地址、错误分类 status 2/3；URL Test 失败 → status 3 原文 + 展示期 `genFriendlyMsg`；结果回调改 `TestResult{status,ping,error}`；每节点开测前标 status 0；单节点构建失败不拖垮整批；取消支持 `isCancelled`；保留批量会话 + 降级/绑定/兜底超时 |
| `entry/src/main/ets/core/ConfigBuilder.ets` | 仅 `buildLatencyTestConfig` 段落的注释对齐（§7 核对结论：行为不变） |
| `entry/src/main/ets/pages/Index.ets` | 测速 UI 段：TCPing/URL Test 两个 ⋮ 菜单入口（测速中换成「取消」）、作用域改当前选中分组、延迟显示/着色改 status 驱动（删 150/400 阈值，删 `latencies` 双份状态，改为 Profile 单一事实来源 = Android ProfileEntity 同构）、status3 点击延迟文字弹内核原文、连接中测当前节点超时 3000 + http/https 成功文案 + 友好化失败文案 |
| `entry/src/main/ets/pages/SettingsPage.ets` | 测速并发输入：空值/非法默认 5（对齐 `DataStore.kt:159`） |
| `entry/src/main/ets/utils/ClashApi.ets` | `URL_TEST_TARGET` 兜底改 `http://cp.cloudflare.com/`（`Constants.kt:3`）；注释标明 3000/5000 两套超时口径由调用方决定 |
| `entry/src/main/resources/{base,en_US}/element/string.json` | 追加 16 条 `connection_test_*`/`ok` 文案（中英双语），并更新 `latency_test_mode_desc`、`settings_test_url_desc` 的措辞（TCPing 固定 3000、默认 cp.cloudflare、HTTPS 偏高提示） |
| `tests/latency-parity.cjs` | 新增：18 组断言（§13.1） |
| `tests/clash-auth.cjs` | 扩展第 8 项：连接中测速 3000ms + 默认 URL + 鉴权 |

未动的文件（按约定）：`module.json5`、`AppScope/app.json5`、`build-profile.json5`、`core/**`、`entry/libs/**`、订阅链路（`utils/Subscription.ets`/`LinkParser.ets`/`ClashYaml.ets`/`core/Subscriptions.ets`/`SubDetailPage.ets`）、`pages/SubscriptionsPage.ets`、`utils/Backup.ets`（`status/ping/error` 备份待 Lead 统一补，见 D-3.8）、`Index.ets` 的 `dedupGroup()`（更新期/手动去重键差异由 Lead 统一改，本轮仅把 `deleteUnavailable`/`clearTestResults` 的作用域接到当前分组）。

## 13. 测试证明（node 层，可复跑）

```powershell
cd C:\Worker\NekoBox4Harmony
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
node tests/latency-parity.cjs   # 新增：17 项 PASS
node tests/clash-auth.cjs       # 扩展：8 项 PASS（新增连接中测速 3000ms 口径）
```

### 13.1 新增/扩展的断言（全部直接加载生产代码，不是逻辑副本）

| # | 断言 | 对应 Android 证据 |
|---|---|---|
| 1 | 默认 URL/并发/重试/取样/期望状态/超时 = `http://cp.cloudflare.com/` / 5 / 0 / 1 / `any` / 5000 | `Constants.kt:3`、`DataStore.kt:159`、`UrlTest.kt:9`、libneko 不看状态码 |
| 2 | `canTCPing` 协议表：hysteria/hysteria2/tuic/wireguard/custom/chain → false，其余 true | `AbstractBean.java:51` + 5 个 override |
| 3 | `genFriendlyMsg` 只映射 timeout/deadline、refused/closed pipe，其余返回原文 | `Protocols.kt:53-66` |
| 4 | TCPing 错误四分类：timeout/refused/unreachable → status 2，未分类 → status 3 原文 | `:773-793` |
| 5 | TCPing 先解析域名、取 `[0]`（本例 `[0]` 是 IPv6 也照用）、connect timeout = 3000、先报 status 0 再报最终态 | `:722-732`、`:748`、`:754`、`:721` |
| 6 | 域名解析失败/抛错 → status 2 `domain_not_found`，且**不建 socket** | `:734-739` |
| 7 | 四类失败落到结果对象上的 status/error 精确值 | `:773-793` |
| 8 | TCPing 跳过 5 类不支持协议的节点（只测 1/6） | `:702-713` |
| 9 | URL Test **不筛协议**（4/4 都测），每节点先 status 0 再 status 1 | `:843`、`:721` |
| 10 | 并发上限 5、13 节点全部测完、`testStart`×1 / `testStop`×2（预清理+收尾）/ `testCaps`×1 | `DataStore.kt:159`、D-1 批量会话 |
| 11 | URL Test 失败 = status 3 + 内核原文 `i/o timeout`，友好化只在展示层 | `:860-862` |
| 12 | 探测参数：link=`testUrl`、timeout=5000、expectStatus=`any`；改成 1234/2xx/自定义 URL 时如实透传 | `UrlTest.kt:8-9` |
| 13 | 取消后停止取新节点，但已测结果仍在回调里（可落库） | `:807-823` |
| 14 | 会话启动失败 → `report.degraded=true` + 中文原因 + 对同批目标回退 TCPing | 平台补偿（§9） |
| 15 | 单节点出站构建失败 → 只有该节点 status 3，其它节点照测 | D-1(c) |
| 16 | Store 旧数据 `latencyMs` 迁移：>0→status1、-1→status3/timeout、0→status0；已有 status 的重算派生值 | `ProxyEntity` 三件套 |
| 17 | `saveProfiles`→`loadProfiles` 保留 status/ping/error | 持久化形状 |
| 18 | `loadSettings`：5 不再被迁成 10、存量 `testUrl` 不被改写、空值兜 `http://cp.cloudflare.com/`、缺省 retries=0 / expect=`any`、用户显式设的 2/`2xx` 保留 | `DataStore.kt:159`、`Constants.kt:3` |

`clash-auth.cjs` 新增第 8 项：连接中测当前节点 `timeout=3000`、URL 默认 `http://cp.cloudflare.com/`（URL 编码后 `http%3A%2F%2Fcp.cloudflare.com%2F`）、Bearer 头仍在、socket 超时留余量 → 锁死 `BaseService.kt:147` 与批量 URL Test（5000）两套超时口径。

### 13.2 全量套件结果（本机实跑）

| 套件 | 退出码 | PASS |
|---|---|---|
| latency-parity.cjs（本轮新增） | 0 | 17 |
| clash-auth.cjs（本轮扩展） | 0 | 8 |
| subscription-parse.cjs | 0 | 41 |
| sub-parity-subscription.cjs | 0 | 35 |
| per-app.cjs | 0 | 21 |
| sub-ua-fallback.cjs | 0 | 17 |
| geo-srs.cjs | 0 | 16 |
| sub-etag.cjs | 0 | 15 |
| parity-config.cjs | **1** | 10（既有失败） |
| outbound-graph.cjs | 0 | 9 |
| ipv6-store.cjs | 0 | 8 |
| home-view.cjs | 0 | 7 |
| ipv6-backup.cjs | 0 | 7 |
| ipv6-modes.cjs | **1** | 7（既有失败） |
| route-rules-ui.cjs | **1** | 0（既有失败） |

12 绿 / 3 红。3 个红色套件是 2.1.6 UI 重构遗留（`parity-config` 找 `fabButton()` 布局正则、`ipv6-modes` 找 `ipv6Mode` 选择器、`route-rules-ui` 的 `r1` 用例），**与节点测试无关**：本轮改动的文件里没有它们断言的代码路径，改动前后失败点相同（未修、也未更糟）。另外 grep 确认：没有任何既有套件引用被本轮删除的 `latencies` / `test_all_nodes` / `url_test_result`。

## 14. 需要真机验证

1. 菜单「TCPing」与「URL Test」分别作用于当前分组，节点卡按 status 着色（绿=成功任意数值、红=失败、无 150/400 分档）。
2. `status==3` 节点点击延迟文字弹出内核原文。
3. 失败文案中英双语正确（超时 / 连接被拒绝 / 网络不可达 / 域名解析失败 / 不可用）。
4. 连接中测当前节点：超时 3000、成功提示按 http/https 选文案、失败走友好化。
5. 取消测速后结果已落盘、重启应用仍在（status 同色）。
6. URL Test 数值与 Android 同节点对比（预期鸿蒙偏高：D-2）；确认没有"整批假红"。
7. 批量测速期间 UI 不卡死（300ms 合并刷新仍生效）。

## 15. 未完成/待办

- D-1 的内核 V3 导出与 D-2 的 RTT 探针（需重编 `.so`，本轮不实施）。
- 进度对话框 + 最小化通知（§10）。
- `Backup.ets` 纳入 `status/ping/error`（D-3.8）。
- Android 更新期去重键（`javaClass`）与手动去重键（`serverAddress+serverPort+displayType`，`Protocols.kt:24` + `ConfigurationFragment.kt:534-544`）的差异由 Lead 在 `Index.ets` 的 `dedupGroup()` 统一处理，本轮未动该函数。

## 16. CHANGES.md 条目（可直接粘贴，日期 2026-10-23）

> 建议作为 `### 节点测试 1:1 对齐(2026-10-23)` 追加在「延迟测试」小节之后。
> 内容按用户要求只描述"与 Android 一致"的结果 + 三处受限期差异，不含内部取舍过程。

```markdown
### 节点测试 1:1 对齐(2026-10-23)

以 NekoBoxForAndroid 1.4.2 为基线，逐项对照 TCPing / URL Test 的入口、并发、
超时、错误分级与结果展示，全部对齐；逐条证据见 `docs/PARITY-LATENCY-TEST.md`。

- **入口对齐**：⋮ 菜单拆成「TCPing」与「URL Test」两项（对齐安卓选项菜单），
  作用域 = 当前分组；测速期间两项换成「取消」，取消后已测节点照样落库
  （原来只有「测速」一项，按设置里的方式二选一，且取消要杀进程）。
- **结果模型对齐**：节点新增 `status/ping/error` 三件套（0 未测 / 1 可用 /
  2 已知失败 / 3 其它异常），持久化与安卓 `ProxyEntity` 同构；列表按 status 着色
  —— 成功只显示 `%dms` 绿色（**删除 150/400 三档阈值**），失败红色，
  `status==3` 点击延迟文字弹内核原文。旧装机数据（只有 `latencyMs`）自动迁移。
- **TCPing 对齐**：默认并发 5（安卓 `connectionTestConcurrent`）；超时固定
  3000ms（安卓 `soTimeout`/`connect` 都是 3000，不再读测速超时设置）；
  先解析域名取**第一个**地址（安卓 `getAllByName()[0]`，去掉"优先 IPv4"的私货）；
  解析失败判 `域名解析失败`，连接错误分 超时/连接被拒绝/网络不可达/原文 四类；
  **跳过 Hysteria/Hysteria2/TUIC/WireGuard/自定义/链式节点**（安卓 `canTCPing()` 同款）。
- **URL Test 对齐**：不筛协议（安卓整组都测）；超时 5000（安卓 `UrlTest.kt`）；
  默认**不判 HTTP 状态码**（安卓 libneko 只看能不能拿到响应，`403/500` 也算通，
  需要严格判定可把 `testExpectStatus` 设回 `2xx`）；失败一律 `status=3` + 内核原文，
  展示期再按安卓 `genFriendlyMsg` 规则映射成 超时/连接被拒绝，映射不上显示"不可用"。
- **默认值对齐**：测试网址 `http://cp.cloudflare.com/`（安卓 `CONNECTION_TEST_URL`），
  重试 0 次、取样 1 次（安卓不重试不取样）。**存量装机保存过的网址不再改写**
  （此前会把 `cp.cloudflare.com` 自动迁移成 gstatic，这条迁移已删除）。
- **连接中测当前节点对齐**：超时 `3000`（安卓 `BaseService` 固定 3000，此前用 5000），
  成功提示按 `http/https` 选文案，失败走同一套友好化映射。
- **测量口径差异（受 .so 限制，已最小化）**：安卓每次探测连发两次 GET、只计
  第二次的"请求头写出→首字节"（暖连接 RTT，不含建连与 TLS）；鸿蒙内核是单次
  HEAD（405/501 回退 GET）并含建连+TLS，同一节点数值会偏高。已通过
  "默认 HTTP 网址 + 不判状态码"把差距压到最小；要做到数值完全一致需要重编内核
  （方案与验证点见 `docs/PARITY-LATENCY-TEST.md` 偏差 D-2）。
- **实现形态差异（受内核单例限制）**：安卓是"每节点一个临时实例"，鸿蒙是
  "整批一个测试会话 + 按 tag 并发探测"。等价性论证与单节点隔离的兜底
  （配置非法的节点只红它自己）见同文档偏差 D-1。
```

## 17. 需要 Lead 一并修正的既有文档口径（本轮未改，属 Lead 写作用域）

| 文件/位置 | 现文本 | 本轮后的真实口径 |
|---|---|---|
| `CHANGES.md` 「延迟测试」第 1 条 | "现在默认仅 2xx 判定通过(`AppSettings.testExpectStatus`,可选 `any`)" | 1:1 对齐后**默认 `any`**（Android 不判状态码），`2xx` 变成用户可选的严格档 |
| `CHANGES.md` 「延迟测试」第 3 条 | "重试与多次取样 `testRetries`/`testSamples`"（未写默认） | 默认 0 / 1，与 Android 一致；仍是鸿蒙可选项 |
| `CHANGES.md` 「延迟测试」后续条目 | 未提默认测试网址 | 默认 `http://cp.cloudflare.com/`（`Constants.kt:3`），**不再自动迁移**存量值 |
| `AGENTS.md` 「当前状态」段 | "默认测试网址 `https://www.gstatic.com/generate_204`（旧默认 cloudflare 会在 Store 里自动迁移）" | 默认已是 `http://cp.cloudflare.com/`，迁移逻辑已删（1:1 要求） |
| `AGENTS.md` 「架构速记」 | "`LatencyTester` … 逐节点探活" | 仍是"整批会话 + 按 tag 探测"（D-1），措辞可保留但建议注明单例约束 |
| Notion「NekoBox for Harmony 开发文档」 | 同步上述三条 | 同上 |

