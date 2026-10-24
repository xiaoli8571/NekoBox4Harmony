# P0 数据模型基线调查（当前持久化层实测）

> 调查时点：2026-10-24，分支 `debug`（工作区含未提交修改，本调查只读，不改任何源码）。
> 服务对象：`docs/REDESIGN-PLAN-2026-10-23.md` §14（ConfigRepository + 版本化不可变 ConfigSnapshot，schema v4→v5）与工作包 W02/W03（P0 基线）。
> 方法：全文精读 `Store.ets`（446 行）、`Backup.ets`（298 行）、`Subscriptions.ets`（1023 行）、`Profile.ets`、`RouteRule.ets`、`PerApp.ets`、`VpnExtAbility.ets`（897 行）、`CoreManager.ets`、`CrashGuard.ets`，并对 `entry/src/main/ets/` 全树 grep：`dataPreferences/getPreferences`、`pref.put(/pref.flush(/pref.get(/pref.clear(`、`saveProfiles/mutateProfiles`、`readPrefString/writePrefString`、`schemaVersion/subUrl`、`writeText/writeFile/openSync/rename/fsync/filesDir/cacheDir`、`setInterval`。全部行号以当前工作区（含未提交修改）为准。

---

## 1. 存储清单（Preferences 实例 / key / 归属进程 / 调用点）

### 1.1 实例：只有一个 Preferences 文件，但有两个进程级缓存

- 全 `entry/src/main/ets/` 树**只有 `Store.ets` 一处** `import dataPreferences from '@ohos.data.preferences'`（Store.ets:1）。页面、订阅、备份、规则、扩展**全部**经 Store 的包装函数访问，无任何旁路直调（grep 证实；`ClashYaml.ets:587/696/712` 的 `map.put` 是无关的 Map 操作）。
- 唯一文件名 `nekobox_store`（Store.ets:11），唯一打开点 `dataPreferences.getPreferences`（Store.ets:42、61，后者在 refreshStore 里重开）。
- 模块级单例 `prefInstance`（Store.ets:18）是**每进程各一份**：UI 进程与 `:vpn` 扩展进程各自打开同一个 Preferences 文件，读缓存互不失效 —— 源码注释明确记载该坑（Store.ets:45-52：UI 进程 put+flush 后 `:vpn` 旧快照不失效；profileId 因此改走 Want 参数）。
- `:vpn` 侧靠每次启动前 `refreshStore` 强制丢缓存重读（VpnExtAbility.ets:394 → Store.ets:54-62 `removePreferencesFromCache` + 重开）；启动中途（运行期间）不会感知 UI 改动。

### 1.2 打开点（initStore / refreshStore）

| 进程 | 打开点 |
|---|---|
| UI | EntryAbility.ets:66（后台订阅更新）、:191（外观）；Index.ets:325、:351、:1520、:1558、:1650；GroupPage.ets:48；ProfileEdit.ets:46、:174、:226；SubDetailPage.ets:102、:131；SettingsPage.ets:88；ToolsPage.ets:239；ConnectionsPage.ets:100；DashboardPage.ets:21；CrashGuard.ets:51；Backup.ets:238、:260；Subscriptions.ets:593 |
| :vpn | VpnExtAbility.ets:394（`refreshStore`，tryStart 每次都执行） |

### 1.3 key 一览（12 个，均为单 JSON 大值/字符串）

| key | 内容 | UI 写 | :vpn 写 | UI 读 | :vpn 读 |
|---|---|---|---|---|---|
| `profiles` | `Array<Profile>` 全量 JSON（Store.ets:12、73、130） | 21 处（见 §2） | ✅ VpnExtAbility.ets:712（mutateProfiles 流量累加） | Index.ets:326/1521/1651、ProfileEdit.ets:227、SubDetailPage.ets:117、Backup.ets:209/244 | VpnExtAbility.ets:448 |
| `profile_groups` | `Array<ProfileGroup>`（Store.ets:13、136、153） | GroupPage.ets:306/327/343/369、Store.ets:176（ensureGroupByName）、Subscriptions.ets:872/906、Backup.ets:220/230 | — | GroupPage、Backup.ets:210 | VpnExtAbility.ets:461 |
| `settings` | `AppSettings` 单对象 54 字段（Store.ets:14、182、328） | SettingsPage.ets:202/231/250、Index.ets:573/842、Store.ets:264/283/298（**loadSettings 读函数内部写盘**）、Backup.ets:218/228 | — | Store.ets:182（loadSettings，全部页面经此读） | VpnExtAbility.ets:188/285/460/708、EntryAbility.ets:68/192 |
| `pending_profile_id` | string（Store.ets:15、341） | VpnService.ets:69 | VpnExtAbility.ets:113/205/294 | — | VpnExtAbility.ets:396 |
| `running_profile_id` | string（Store.ets:347，字面量 key） | — | VpnExtAbility.ets:370/622 | — | Store.ets:353（getRunningProfileId） |
| `selected_profile_id` | string | Index.ets:515/547、Subscriptions.ets:830 | — | Index.ets:335 | —（经 Subscriptions.ets:717 读） |
| `subscriptions` | `Array<SubInfo>`（Subscriptions.ets:15、88、133 → Store.ets:363 writePrefString） | Subscriptions.ets:189/194/205/263/279/292/698/985/1006、SubDetailPage.ets:138、Backup.ets:221/231 | — | Subscriptions.ets:88（listSubs，各页面复用） | — |
| `route_rules` | `Array<RouteRule>`（RouteRule.ets:43、113、146） | RouteRulesPage.ets:56/74/187、Backup.ets:222/232 | — | RouteRulesPage | VpnExtAbility.ets:549 |
| `remote_rule_sets` | `Array<RemoteRuleSet>`（RouteRule.ets:44、151、173） | RouteRulesPage.ets:66/79/188、Backup.ets:223/233 | — | RouteRulesPage | VpnExtAbility.ets:559 |
| `active_config_url` | string | Index.ets:333/1670 | — | Index.ets:330 | — |
| `recent_subscription_group` | string | Index.ets:1673 | — | Index.ets:1559、ProfileEdit.ets:59 | — |
| `crash_guard_state_v1` | string `alive\|profileId\|ts`（CrashGuard.ets:18、52-58） | CrashGuard.ets:58/74/83 | — | CrashGuard.ets:52 | — |

- 全量清除：`resetAllData` = 一次 `pref.clear()+flush`（Store.ets:333-337），抹掉上述全部 key，**但不清** `filesDir/core/config.json`、`filesDir/geo/` 等文件（见 §6），恢复出厂是"半清除"。
- 通道路由：除上述具名 key 外，`readPrefString/writePrefString`（Store.ets:356-365，通用 put+flush）是 `subscriptions/route_rules/remote_rule_sets/selected_profile_id/active_config_url/recent_subscription_group/crash_guard_state_v1` 的实际落点。

---

## 2. 写路径风险

### 2.1 saveProfiles（全量回写） vs mutateProfiles（串行读改写）调用点统计

`saveProfiles` 外部调用 **21 处**（另有 1 处在 mutateProfiles 内部，Store.ets:34）：

| 文件 | 调用点（文件:行 → 语义） |
|---|---|
| Index.ets | :761 清测速结果、:808 去重删除、:833 删不可用节点、:1039 拖拽排序、:1045 置顶、:1066 移动分组、:1214 删除节点（**未 await**）、:1527 分享链接批量导入、:1665 订阅导入 —— 9 处 |
| GroupPage.ets | :246 删组内节点、:264 清订阅节点、:283 删订阅、:325 删组（节点迁未分组）—— 4 处 |
| ProfileEdit.ets | :183 单节点保存（按下标替换）、:235 粘贴批量导入 —— 2 处 |
| SubDetailPage.ets | :146 改订阅分组、:228 删订阅 —— 2 处 |
| Subscriptions.ets | :822 订阅更新原子替换（kept）、:917 Clash 分组迁移 —— 2 处 |
| Backup.ets | :219 导入写入、:229 恢复回滚 —— 2 处 |

`mutateProfiles`（Store.ets:22-39：模块级 Promise 队列串行化 load→mutate→save）外部调用**仅 2 处**：

- Index.ets:709（测速结果合并回列表，注释明言"避免测速期间订阅更新/编辑/删除被旧快照覆盖"）；
- VpnExtAbility.ets:712-722（`:vpn` 会话流量累加 rx/tx/updatedAt）。

**结论：23 个 profile 写点里 21 个是全量回写，2 个走串行队列。** 每次全量回写 = 把页面 `State` 里持有的整份节点数组 JSON.stringify 后 put+flush（如 Index.ets:761 的 `saveProfiles(this.profiles)`）。

### 2.2 双进程双写点（最高风险）

- `:vpn` 进程**写** `profiles`：VpnExtAbility.ets:712-722（流量统计，`mutateProfiles` 更新 rx/tx/updatedAt）。
- UI 进程几乎全部写点用**页面内存副本**回写（`saveProfiles(this.profiles)`），页面副本可能落后于 `:vpn` 刚写入的会话流量 → UI 回写会用旧 rx/tx **覆盖** `:vpn` 数据。
- `profileWriteQueue` 是模块级变量（Store.ets:19），**每进程一份，跨进程不互斥**；串行队列对"UI 删节点 × `:vpn` 记流量"这类跨进程竞争完全无效。
- `pending_profile_id` 由 UI（VpnService.ets:69）与 `:vpn`（VpnExtAbility.ets:113/205/294）**双侧写**，仅单字符串、无版本/代际字段，靠清空语义（clearPendingProfileId，Store.ets:372-374）协调。

### 2.3 其它结构性写风险

1. **loadSettings 是"读函数却会写盘"**：Store.ets:263-266（clashApiSecret 为空时生成并落盘）、:277-285（coexistFix202609 一次性迁移）、:291-301（perAppEntries 首次初始化）都在 load 路径里 put+flush。任何页面读 settings、以及 `Backup.exportBackup`（Backup.ets:243）都可能触发写 —— 导出有副作用。
2. **同一字段双写通道（perApp）**：名单走两条通道 —— 设置落盘（`perAppEntries` 权威 + `perAppList` 派生，PerApp.ets:11-14、Store.ets:326-327）+ **Want 参数直传**（VpnExtAbility.ets:118-127 接收、:514-515 使用，注释明言"Want 直达 > 磁盘设置"优先级）。启动时扩展用 Want 值，冷启动/自动连接用磁盘值，两通道可能不同步。
3. **selected_profile_id 三个独立写点**（Index.ets:515/547、Subscriptions.ets:830），与 profiles 写入从不打包成一个事务；订阅更新删除运行节点时靠"指向本订阅第一个节点"兜底（Subscriptions.ets:828-831）。
4. **Index.ets:1214 删除节点 `saveProfiles` 未 await**（fire-and-forget），进程被杀即丢删除。
5. **页面退出兜底全量写回**：RouteRulesPage.ets:56/66（1s 防抖）+ :74/79（aboutToDisappear 全量写回）——规则页的写入口比其它页面多一层"离开页面才落盘"的时序。
6. UI 的 1s 速率轮询只写 AppStorage 内存态，不落盘（Index.ets:404-428），不构成 Preferences 写竞争 —— 但 AppStorage（vpnRunning/vpnRunningProfileId，Subscriptions.ets:215、815）与 Preferences 的 running_profile_id 是两套并行的"运行态"，靠手工同步。

---

## 3. 实体清单（字段 / ID 来源 / 身份风险）

### 3.1 Profile（Profile.ets:25-151，71 个字段，逐行清点）

- 标识：`id`、`name`、`type`（ProfileType 16 类，Profile.ets:6-23）、`server`、`serverPort`。
- 协议块：shadowsocks（method/password/ssPlugin/ssPluginOpts）、http/socks（username）、vmess/vless/tuic（uuid/alterId/security/flow/packetEncoding）、传输层（transport/path/host/serviceName/wsEarlyData/wsEarlyDataHeaderName）、TLS/REALITY/ECH（tls/sni/allowInsecure/alpn/fingerprint/realityPublicKey/realityShortId/certificates/ech/echConfig）、hysteria(2)（upMbps/downMbps/obfs/serverPorts/hopInterval）、tuic（congestionControl/udpRelayMode/reduceRtt/disableSni）、wireguard/ssh 共用（localAddress/privateKey/peerPublicKey/preSharedKey/wgMtu/reserved/sshAuthType/privateKeyPassphrase/hostKey）、shadowtls（shadowtlsVersion）、mux（mux/muxProtocol/muxMaxStreams/muxPadding）、custom（extra/customOutbound）、chain（chainIds）、前置（dialerProxyName/dialerProxyId）。
- 归属/运行期：**`subUrl`**（:123）、`groupId`（:126）、`sortOrder`（:127）、status/ping/error（:135-137）、latencyMs/latencyTestedAt（:140-141）、rx/tx（:144-145）、updatedAt（:147）、pinned（:150）。

**ID 来源（三条路径，互不一致）**：

| 路径 | ID 生成 | 稳定性 |
|---|---|---|
| 手动创建 | `${Date.now()}_${Math.floor(Math.random()*100000)}` — ProfileEdit.ets:56、Index.ets:1688-1689（genId） | ❌ 非稳定：同机毫秒+5 位随机可碰撞；跨设备必不唯一；无 UUID |
| 订阅更新（Subscriptions.updateSubscription） | `stableProfileId` = FNV-1a 32 位哈希 → `sub_<hex>`（Subscriptions.ets:295-308），身份串 = url+type+server+serverPort+uuid+**name**+transport+path+host+serviceName+sni（:295-298） | ⚠️ 伪稳定：节点改名/改地址/换 uuid 即换 ID；32 位哈希有碰撞理论风险；已有节点更新时保留旧 id（:774） |
| 首页订阅导入（Index） | `genId()` 随机（Index.ets:1659） | ❌ 与订阅更新路径不同体系；同一订阅两条入口产出不同 ID 体系 |

**结论：Profile 没有全局稳定 ID**（plan §14.2 要求"稳定ID、sourceSubscriptionId、sourceIdentity、配置hash"——现状四项全缺）。

### 3.2 ProfileGroup（Profile.ets:153-171）

- 字段：id/name/sortOrder/collapsed/isSelector/autoSelect（:158-162，isSelector 与 autoSelect 互斥语义）/frontProxy/landingProxy（:163-165，指向 profile id）/fromSubscription（:168）/createdAt/updatedAt。
- ID：`grp_${Date.now()}_${Math.floor(Math.random()*100000)}`（Store.ets:169、GroupPage.ets:298）——时间戳+随机，非稳定。
- **身份实际是 name**：`ensureGroupByName` 按名称查找复用（Store.ets:157-178），重名即共享同一组；订阅更新、Clash 分组、手动建组都经名称合并。改名（GroupPage.ets:335-343）不换 id，但下次 ensureGroupByName(旧名) 会新建组。
- plan §14.4-4 要求迁成 StrategyGroup type —— 现状 isSelector/autoSelect 两个布尔，无双 true 的持久化防护（true+true 只在读取时按 autoSelect 优先，迁移时需处理）。

### 3.3 SubInfo / 订阅（Subscriptions.ets:31-63）

- 字段：url/name/group/lastUpdate/upload/download/total/expire、updateIntervalMinutes（默认 1440 分钟）+ updateIntervalHours（旧字段，读取时 ×60 迁移，Subscriptions.ets:44-47、101-111）、nextUpdateAt/lastAttemptAt/lastError/failCount、userAgent/autoUpdate（默认 false）/updateWhenConnectedOnly/deduplication/forceResolve、**etag/lastModified**（:61-62，HTTP 条件请求校验器）。
- **无 id 字段，身份 = url 字符串**：全部查找/删除/匹配按 url（Subscriptions.ets:151、192-195、596、737、758；GroupPage.ets:263/282；SubDetailPage.ets:228）。
- **subUrl 作为身份的风险点**：
  1. URL 双重身份：既是 SubInfo 主键，又是 Profile→订阅的外键（`p.subUrl`）。机场换域名/加参数/换 token → 旧订阅"消失"，旧节点变成 subUrl 悬空的孤儿（无任何 re-link 逻辑）。
  2. 手动分享链接导入的节点 `subUrl` 为空（Index.ets:1660 仅 URL 订阅导入才赋值）→ "无主节点"与"订阅已删除的残留"不可区分；plan §14.4-9 的"用户修改无源可对比"场景无法用 subUrl 判定。
  3. `p.subUrl` 是自由字符串，无规范化/校验；备份原样携带（Backup.ets:120）。
  4. 订阅更新按 **name** 匹配旧节点（byName Map，Subscriptions.ets:738-743、762），不按 id —— 同名不同参即"更新"，与安卓对齐但意味着节点身份随 name 漂移。

### 3.4 RouteRule / RemoteRuleSet（RouteRule.ets:10-41）

- RouteRule **没有任何 id 字段**（:10-29）：type/value（旧单类型兼容字段，:11-13）、domains/ip/port/source/sourcePort/network/protocol/packages/appLabel/packagesEnabled/config、outbound（:26，取值含 `profile:<id>` —— 引用 Profile id）、enabled/remark。**身份 = 数组下标**：编辑/删除按 index，备份还原后顺序即身份；plan §14.2 要求 stableID+priority —— 现状为 0。
- 读取时旧单类型规则自动迁移为多字段（migrateLegacyRule，RouteRule.ets:83-109）；旧数据"有 packages 无勾选标志"视为生效（:129-130）。
- RemoteRuleSet 有 id 但为 `${Date.now()}_${rand}`（RouteRulesPage.ets:85）——非稳定。

### 3.5 PerAppEntry（PerApp.ets:17-27）

- 字段：bundleName/label/enabled；无 id，身份 = bundleName（去重键，PerApp.ets:79）。
- 持久化为**双字段**：`perAppEntries`（权威 JSON 数组）+ `perAppList`（派生 CSV，保持旧契约，PerApp.ets:11-14；Store.ets:326-327 每次保存重新派生）。空串=未初始化、`'[]'`=用户清空（PerApp.ets:92-95）。
- 上限 256（PER_APP_MAX_ENTRIES，PerApp.ets:29-30），非法包名前置过滤（effectivePackages，:169-187）。

### 3.6 AppSettings（Profile.ets:173-258）

- 单对象 54 字段（mtu/stack/mode/DNS 三路/sniffMode/mixedPort/clashApi\*/perApp\*/测速参数组/外观/ipv6+ipv6Mode/coexistFix202609Applied…），**无版本号、无 schema 字段**。
- 读时规范化 + 内嵌迁移（Store.ets:189-301）：mtu 钳制 1280-1500、枚举白名单回退、clashApiSecret 生成、9090→19290 一次性迁移、perAppEntries 初始化。"读会写"使设置没有纯读取语义。
- 一次 put+flush 整对象回写（Store.ets:328），无字段级更新。

### 3.7 通用数据污染通道

`fillFrom`（Store.ets:377-390）把 JSON 里**所有键（含未知键）**灌进类实例：未知字段会滞留在内存实例上，并随下一次 save 回写进存储 —— 对"迁移输入是干净 v4"的假设构成威胁（备份里塞进来的未知键会跨版本存活）。

---

## 4. Backup schema v4 的确切结构

### 4.1 顶层键（exportBackup 实际输出，Backup.ets:237-251）

```jsonc
{
  "schemaVersion": 4,          // Backup.ets:9 CURRENT_SCHEMA_VERSION=4
  "version": 4,                // 双写（兼容旧读取方），Backup.ets:241
  "exportedAt": <Date.now()>,
  "settings":   {…AppSettings 全字段…},   // 类实例直接 stringify，默认值全出现
  "profiles":   [ {…Profile 全字段…}, … ],
  "groups":     [ {…ProfileGroup 全字段…}, … ],
  "subscriptions": [ {…SubInfo 全字段…}, … ],
  "routeRules": [ {…RouteRule 全字段…}, … ],
  "remoteRuleSets": [ {…RemoteRuleSet 全字段…}, … ]
}
```

- 序列化 = `JSON.stringify(类实例)`：**每个声明字段（含默认值）全量出现**，无 undefined 省略；非可选接口字段也全部存在（BackupPayload 接口里 groups/subscriptions/routeRules/remoteRuleSets 标 `?`，但导出路径恒写全，Backup.ets:239-249）。
- settings 内嵌 AppSettings 54 字段 + profiles 每项 71 字段 → 单条订阅更新/备份导出的字符串体积与节点数线性相关（Preferences 单值）。

### 4.2 schemaVersion 判断逻辑（Backup.ets:187-204）

```ts
const schemaVersion = obj.schemaVersion ?? obj.version ?? 1;   // :191 —— 三级回退
if (!Number.isInteger(schemaVersion) || schemaVersion < 1) throw backup_bad_format;   // :192-193
if (schemaVersion > CURRENT_SCHEMA_VERSION) throw `backup_unsupported_version:${n}`;  // :195-196
```

- **导入接受范围 = 1..4**；`??` 链意味着 `schemaVersion:null` 落到 `version`，两者皆缺 = 1；非整数/负数/0 → backup_bad_format；>4 → `backup_unsupported_version:<n>`（未来版本拒绝，目前**无对应测试**，见 §5）。
- 硬性要求：`settings`（record）与 `profiles`（数组）必须存在（:188）；其余四个集合可选，缺省在写入端补 `[]`（:220-223）。

### 4.3 逐实体校验（先验类型，后写）

| 实体 | 必需字段 | 可选字段白名单（存在才校验类型，未知键不校验也不剔除） | 位置 |
|---|---|---|---|
| settings | record | string 23 个 / number 10 个 / boolean 20 个（含 coexistFix202609Applied **不在**白名单 → 不校验） | Backup.ets:88-103 |
| profile | id/name/type/server(string) + serverPort(number) | string 41 / number 12 / boolean 8 | Backup.ets:105-124 |
| group | id/name | frontProxy/landingProxy、sortOrder/createdAt/updatedAt、collapsed/isSelector/autoSelect | Backup.ets:126-134 |
| subscription | url（仅此一个必需） | name/group/lastError/etag/lastModified、lastUpdate/upload/download/total/expire/updateIntervalMinutes/updateIntervalHours/nextUpdateAt/lastAttemptAt/failCount | Backup.ets:136-147 |
| routeRule | type/value/outbound | remark、enabled（**不校验 domains/ip/… 等新字段**） | Backup.ets:149-157 |
| remoteRuleSet | id/name/url/type/outbound | lastError、updatedAt、enabled | Backup.ets:159-169 |

### 4.4 导入流程与事务语义（Backup.ets:254-298）

1. `restoreInProgress` 模块级布尔互斥（:41、255-258）——**仅本进程**，UI 与 `:vpn` 不互斥。
2. `JSON.parse`（失败 → `backup_invalid_json`，:262-266）→ `validatePayload`。
3. `captureSnapshot` 6 读（:206-215）→ `writePayload` **6 次独立 put+flush 顺序写 6 个 key**（:217-224，经各自 save*）——无跨集合事务。
4. 写失败 → `restoreSnapshot` 全量回滚（再 6 写，best-effort，:226-235）；回滚自身失败 → `backup_rollback_failed:<detail>`（:279）；回滚成功 → `backup_restore_rolled_back`（:282）。
5. 成功返回统计；**从不停止/重启 VPN**（`stoppedVpn` 恒 false，:291）——恢复后运行中会话与磁盘配置脱节，无任何提示。
6. 导入**不经过** fillFrom/规范化：`payload.profiles` 原样字符串写回（未知键进存储）；settings 经 saveSettings 规范化，但"类型合法的旧值"（如 ipv6Mode:'auto'）原样落盘，读取时才归一（tests/ipv6-backup.cjs:44-46 断言 roundtrip 保真）。

---

## 5. v4→v5 迁移所需旧数据夹具清单（对照 plan §19.3）

### 5.1 现有夹具（全部 inline 在 .cjs 内，无独立 fixture 文件）

| 夹具 | 覆盖点 | 位置 |
|---|---|---|
| v4 导出/导入 roundtrip（ipv6Mode 六个值） | 导出→导入保真；schemaVersion=4 主路径 | tests/ipv6-backup.cjs:29-36 |
| v4 settings.ipv6Mode 类型非法（true/false/1/null） | 单字段类型损坏 → `backup_bad_format`，且**零写入**断言 | tests/ipv6-backup.cjs:37-42 |
| v4 legacy `{ipv6:true}`（缺 ipv6Mode 可选字段） | 缺失可选字段（settings 级） | tests/ipv6-backup.cjs:43-47 |
| Store 级 settings ipv6Mode 非法值/合法值/legacy 缺失 | 读时归一化 | tests/ipv6-store.cjs:28-43 |
| route_rules legacy 行 `{packages,outbound}`（缺 packagesEnabled） | 缺失可选字段（实体级）+ 旧数据视为生效 | tests/ipv6-store.cjs:64-68 |
| updateIntervalHours 旧字段镜像 | 订阅小时→分钟迁移 | tests/sub-parity-subscription.cjs:671 |
| Backup.ets 源码字符串匹配（'profileTrafficStatistics','showBottomBar'） | 仅防回退的文本断言，**非行为夹具** | tests/parity-config.cjs:95-98 |

### 5.2 缺失夹具（§19.3 逐项对照）

| §19.3 要求 | 现状 |
|---|---|
| **schema1 / schema2 / schema3** | ❌ 完全没有。导入器声称接受 1-4（Backup.ets:191-196），但 1/2/3 无任何夹具；`obj.version` 键回退、完全无版本键 → 1 的两条路径（Backup.ets:191）未被测试。schema1/2/3 与 v4 的**内容差异**在代码中只有字段的增减，"哪个字段属于哪一版"无任何版本化记录，迁移器需要自行定义映射表 |
| **v5** | ❌ 尚不存在（本轮引入），无夹具无读端 |
| **未知未来版本** | ❌ `backup_unsupported_version` 分支（Backup.ets:195-196）无测试 |
| **缺失可选字段** | ⚠️ 仅 settings.ipv6Mode、route_rules.packagesEnabled 两处；实体级（profile 缺 id、group 缺 name）、顶层缺 groups/subscriptions/routeRules/remoteRuleSets 未覆盖 |
| **单项损坏** | ❌ 无"好项+坏项混合"夹具。当前校验器遇坏项**整单拒绝**（validateArray 首个坏项即 throw，Backup.ets:171-185），与 §14.4-2"可隔离坏记录+恢复报告"的目标行为相悖 —— 迁移夹具需同时锁定现行为（拒单）与目标行为（隔离+报告），二者不可混测 |
| **整体截断** | ❌ `backup_invalid_json` 路径（Backup.ets:262-266）无测试 |
| 空库 / 仅手动节点 / 单订阅 / 多订阅 / 同名节点 / 同名组 / 不同订阅重复服务器 | ❌ 无（空库仅部分覆盖：测试只预置了 settings 单 key，tests/ipv6-store.cjs:18-27） |
| 100/1000/5000 节点、中文/emoji/IPv6/超长错误原文 | ❌ 无 |
| 自定义 JSON / 前置落地 / 链 / 循环引用 / 失效引用 | ❌ 无 |
| 回滚路径（writePayload 失败 → restoreSnapshot） | ❌ 无（rollback/backup_rollback_failed 分支零测试） |

**对 W02 的含义**：夹具需补 8 类（schema1/2/3、v5、未知版本、单项损坏、整体截断、缺失必需键、回滚路径、规模/字符集），建议落 `tests/fixtures/` 独立 JSON 文件而非继续 inline（现状全部 inline，无法跨测试复用）。

---

## 6. 快照存储可行性注记（供 §14.3"候选快照临时文件 + 重命名"）

### 6.1 应用私有目录获取方式（现有先例）

| 路径 | 获取方式 | 现有使用 |
|---|---|---|
| `context.filesDir` | ability context 直取 | CoreManager.ets:17（`filesDir/core`，内核 config.json/singbox.log/test.json/test.log）、GeoAssets.ets:44（`filesDir/geo`） |
| `context.cacheDir` | ability context 直取 | WebUiAssets.ets:24-25（`cacheDir/yacd-ui` + marker txt）、Index.ets:1429（`cacheDir/import_<ts>_<name>`）、Index.ets:1460（`cacheDir/wg_zip_<ts>`） |
| `context.tempDir` | **未发现使用**（grep 无命中） | — |

- 真机绝对路径样例（AGENTS.md 实测）：`/data/app/el2/100/base/com.nekobox.app/haps/entry/files/core/singbox.log` —— 即 `filesDir` 落在 haps/entry/files 下。
- **双进程同目录**：UI 与 `:vpn` 是同 bundle 双进程，sandbox 目录一致 → UI 进程写的文件 `:vpn` 可直接读（现有 config.json 即 `:vpn` 写、内核同进程读，CoreManager.ets:20-33）。§14.3 的"扩展只读取指定 revision"在文件层面可行，无需跨沙箱授权。
- 目录创建先例：`fs.accessSync(dir) || fs.mkdirSync(dir, true)`（CoreManager.ets:22-24、77-79）。

### 6.2 现有临时文件写入模式（现状 = 全部原地 TRUNC 覆盖写，零先例原子替换）

全 `entry/src/main/ets/` 的文件写模式只有一种：`fs.openSync(target, READ_WRITE|CREATE|TRUNC)` → `fs.writeSync(fd,…)` → `fs.closeSync`：

- CoreManager.ets:20-33（**config.json：先 TRUNC 清空再写** —— 内核读到半截文件的风险窗口现存）、:40-49（log 清空）、:75-88（test.json）；
- GeoAssets.ets:103（geo 下载落盘）、:244（版本号文件）、:255-256（SAF uri → 本地拷贝）；
- WebUiAssets.ets:57-58（zip）、:85（marker txt）；
- 导出/导入到用户目录（SAF uri）：Index.ets:1293、GroupPage.ets:213、ToolsPage.ets:111-121、LogPage.ets:85。

**grep 证实全树不存在**：`rename/renameSync`、`fsync/fdatasync`、`checksum`、`revision`、`manifest`、`checkpoint`（仅 Backup.ets 的 `schemaVersion` 与 Subscriptions 的 `renameCollisions` 命中 "rename" 字样，均非文件操作）。

### 6.3 对 §14.3 的可行性结论

1. **候选快照临时文件 + 同文件系统 rename** 在当前代码**零先例、零原语使用**；P0 必须真机验证：(a) `fs.renameSync/rename` 在应用私有目录是否可用且原子；(b) rename 的跨进程可见时序（UI rename 后 `:vpn` 立即读）；(c) 刷盘语义 —— 现有唯一被依赖的落盘保证是 `dataPreferences.flush()`（Store.ets:131 等），文件层的 fsync 无任何使用先例。
2. **manifest 指针的载体**：现有代码里"指针"只有 Preferences 单字符串键（如 active_config_url，Index.ets:1670）与文件 marker（WebUiAssets.ets:25）。`savedManifest` 若走 Preferences 小键，天然获得 flush 落盘保证；若走文件，则同样需要 §14.3-4 的双槽方案。
3. **若 rename 不原子**：按计划采用双槽 manifest + 单调 revision + 校验恢复（§14.3-4）；现状校验和概念完全缺失，需从零引入。
4. **现有 config.json 已是"配置即文件"先例**（CoreManager.ets:25，TRUNC 原地覆盖、无校验和、无重命名）—— 它同时是 §14.3 要替换掉的反面教材和 v5 快照文件的目录/命名参照（`filesDir/core/`）。
5. Preferences 单值大小上限未在代码中体现（平台文档值），快照若继续走 Preferences 键不可行 —— §14.3-1 的文件方案是唯一出路，且注意 `settings+profiles` 全字段 stringify 的体积与节点数线性相关（§4.1）。

---

## 7. 迁移风险汇总（P0→P1 设计输入，按严重度排序）

1. **双进程双写 profiles 无互斥**：`:vpn` 流量累加（VpnExtAbility.ets:712）× UI 21 处全量回写，`profileWriteQueue` 每进程一份（Store.ets:19）—— ConfigRepository 必须"单写者"（§14.3-5），否则快照修订会在迁移后立刻被旧路径打穿。
2. **三套 Profile ID 体系并存**（时间戳随机 / FNV 哈希 / 混用，§3.1），Home 导入路径（Index.ets:1659）与订阅更新路径（Subscriptions.ets:800）不一致 —— §14.4-3 的稳定 ID 映射表必须同时处理两套存量，且 FNV 身份串含 `name`（改名即换 ID）。
3. **RouteRule 无 ID、组身份=name、订阅身份=URL**（§3.2-3.4）—— plan §14.2 四个实体的稳定 ID 要求在现状全部落空，映射表是迁移的主要工作量。
4. **subUrl 双重身份 + 手动导入节点无主**（§3.3）—— SubscriptionSourceSnapshot 迁移无法可靠归属存量节点；"用户修改无源可对比"（§14.4-9）需以现有有效值作为兼容覆盖基线。
5. **导入/恢复无事务、回滚可二次失败、不 stop VPN**（§4.4）—— 迁移工具若沿用该写入模式会制造"半 v4 半 v5"（§18 MIG 行）；迁移必须走新的候选快照+指针切换，而不是 6-key 顺序写。
6. **读路径带副作用**：loadSettings 写盘（§2.3-1）+ fillFrom 未知键滞留（§3.7）+ 导入不过滤未知键（§4.4-6）—— 迁移的输入不是"干净 v4"，需要先做一次性清洗（剔除未知键、固化版本字段），否则 v5 快照会继承脏数据。
7. **原子文件替换零先例**（§6.2-6.3）—— §14.3-1/2 的临时文件+重命名需 P0 真机验证，验证不过则双槽 manifest + 单调 revision + 校验恢复。
8. **Preferences 单 JSON 大值承载全量集合**（profiles 71 字段×N 节点）—— 大列表场景（§19.3 的 1000/5000 节点）下每次写都是整串重写，迁移后快照必须改为文件承载。
