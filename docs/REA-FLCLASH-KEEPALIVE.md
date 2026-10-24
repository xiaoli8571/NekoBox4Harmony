# REA:FlClash-ohos 后台保活机制逆向 + AGC 个人开发者权限可行性

> 日期:2026-10-23
> 分析对象:`C:\Users\Administrator\Downloads\FlClash-0.8.96+2026102101-ohos.hap`(82,419,518 字节;
> bundleName `com.follow.clash`,versionName 0.8.96 / versionCode 2026102101,compileSdk 26.0.0.105,
> targetAPI 60100023,minAPI 60000020,deviceTypes **phone / tablet**,release 构建)
> 解包产物:`C:\Worker\rea-tmp\flclash-hap\`(module.json、pack.info、ets/modules.abc、libs/arm64-v8a/*)
> 交叉验证:本机 DevEco SDK(HarmonyOS 6.1)——
> `sdk/default/openharmony/ets/api/@ohos.resourceschedule.backgroundTaskManager.d.ts`、
> `sdk/default/openharmony/toolchains/lib/PermissionDefinitions.json`、`@ohos.hiviewdfx.hiAppEvent.d.ts`、
> `@ohos.pasteboard.d.ts`、`@ohos.net.vpnExtension.d.ts`。

## 0. 方法

1. 解包 HAP,读 `module.json`(权限、ability、backgroundModes)与 `pack.info`;
2. 对 `ets/modules.abc`(1,072,132 B)做字符串表静态分析(Latin1 扫描 + 源文件记录
   `src/main/ets/**` 全量提取),定位保活相关类的方法/字段/引用;
3. `libs/arm64-v8a/libcore.so` 用 `llvm-readelf --dyn-syms` 看导出(确认内核在 libclash.so、
   libcore.so 只是 NAPI 桥:startTUN/stopTun/getTraffic/suspend/updateDns 等,与保活无关);
4. 每个结论都与 SDK 的 d.ts 权限注释、`PermissionDefinitions.json` 的等级字段交叉验证,
   不凭印象下结论。

## 1. FlClash 的保活 = 四层机制(全部有 abc/module.json 证据)

### L1 长时任务:TASK_KEEPING + wantAgent + 取消重挂(核心)

- 实现类:`src/main/ets/managers/NotificationManager.ts`,方法
  **`startContinuousTask` / `stopContinuousTask`**(abc 记录原文:
  `#~@0=#NotificationManager … #~@0>#startContinuousTask … #~@0>#stopContinuousTask`)。
- 该类字段:`backgroundTaskManager`、`wantAgent`、`wants`、`actionType`、`requestCode`、
  `actionFlags`,常量 `SERVICE_START`;引用 `@ohos:app.ability.wantAgent`、
  `@ohos:resourceschedule.backgroundTaskManager`。
- abc 中与之相邻的调用串(原文摘录):
  `OperationType..START_ABILITY..WantAgentFlags.'UPDATE_PRESENT_FLAG..getWantAgent..off.)
  continuousTaskCancel.+stopBackgroundRunning.%stopContinuousTask.-startBackgroundRunning..
  BackgroundMode..TASK_KEEPING..setTimeout` 以及 `#notification_lock`、
  `COMMON_EVENT_DEVICE_IDLE_MODE_CHANGED`、`sleeping`。
- 还原出的流程:**VPN 启动 → AppPlugin(Flutter MethodChannel 的 ArkTS 端)→
  NotificationManager.startContinuousTask() → wantAgent.getWantAgent({wants:[{…, action:
  'SERVICE_START'}], actionType: START_ABILITY, actionFlags:[UPDATE_PRESENT_FLAG]}) →
  backgroundTaskManager.startBackgroundRunning(context, BackgroundMode.TASK_KEEPING,
  wantAgent) → 系统挂常驻通知;先注册 `on('continuousTaskCancel')`,被取消后
  `setTimeout(…,1000)` 重挂;停止时 `stopBackgroundRunning` + `off`。**
- 调用方证据:abc 里 `AppPlugin` 的 import 清单包含
  `@bundle:com.follow.clash/entry/ets/managers/NotificationManager`(即由 UI 进程的
  AppPlugin 触发申请,`startBackgroundRunning` 全 abc 仅此 1 处调用)。

### L2 无 UI 的第二 Ability(TempAbility)+ 双 ability 声明 taskKeeping

- module.json:`EntryAbility` 与 `TempAbility` **都声明 `backgroundModes:["taskKeeping"]`**
  (TempAbility `exported:false`,无 skills,即不可被外部拉起为界面)。
- `src/main/ets/entryability/TempAbility.ts` 方法:`connect` / `connectService` /
  `disconnect` / `handleQuickSetup` / `handleStart` / `lock` / `onCreate` / `onDestroy`;
  引用 `EntryAbility`、`GlobalState`、`VpnOptions`、`commonEventManager`、事件
  `SERVICE_STOP`、`SERVICE_YIELD`。
- 作用推断:承载"从通知/桌面卡片/系统事件发起的后台一次性动作"(开关 VPN、快速配置),
  且保证**任何一个 ability 持有长时任务,整个应用保活**——主窗口被划掉后长时任务仍可挂在
  存活的 ability 上(UIAbility 上下文才能申请长时任务,这是 SDK 硬性要求)。

### L3 VPN 扩展进程(:vpn)——流量真正所在

- module.json:`extensionAbilities: VpnExtAbility(type=vpn)`;abc 显示其
  import `@ohos:app.ability.VpnExtensionAbility`、`@ohos:net.vpnExtension`、
  `@bundle:com.follow.clash/entry@core/Index`(→ `libclash.so`,50.4MB mihomo 内核)。
- UI 进程经 `ServicePlugin`(方法 `initialize/shutdown/start/stop/getRunTime/syncState`)
  + `utils/Rpc.ts`(MessageSequence/RemoteObject IPC)+ `startVpnExtensionAbility` /
  `connectServiceExtensionAbility` 与扩展进程通信(日志串:"Failed to connect VpnExtAbility"、
  "disconnected unexpectedly")。
- 扩展进程内 `ServiceStub.handleGetRunTime / handleInvokeMethod / handleQuickSetup /
  handleSetEventListener` 处理 UI 的远程调用。

### L4 被杀自愈与运行态持久化

- `AppCrashWatcher`(hiAppEvent):watch **APP_KILLED / JsError / CppCrash**;字符串
  `didCrashOnPreviousExecution`、日志 `App killed on last run <= …`;abc 里还有
  `appEventFilters`、`onReceive`。
- `GlobalState.ts` 字段(AppStorage 持久化):`exclude_recent`、`exclude_state`、
  `run_state`、`run_time`、`shared_state`、`state`;另有 `moveAbilityToBackground`、
  `excludeFromRecent`。
- 语义:**应用被系统/用户杀死后,下次启动检测"上次异常退出",自动重连 VPN**——这是
  不需要任何权限的自愈机制,FlClash 保活"强"的另一半来源。

## 2. 权限审计:FlClash 请求的 10 个权限 × 个人开发者可行性

数据源:`sdk/default/openharmony/toolchains/lib/PermissionDefinitions.json`
(`grantMode` / `availableLevel` 字段是权威)。

| 权限 | grantMode | availableLevel | 个人开发者(AGC) | FlClash 用途 |
|---|---|---|---|---|
| ohos.permission.INTERNET | system_grant | normal | ✅ 可用 | 网络 |
| ohos.permission.GET_NETWORK_INFO | system_grant | normal | ✅ 可用 | 网络状态 |
| ohos.permission.GET_WIFI_INFO | system_grant | normal | ✅ 可用 | SSID 切换策略 |
| **ohos.permission.KEEP_BACKGROUND_RUNNING** | system_grant | **normal** | ✅ 可用 | 长时任务必需 |
| **ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM** | system_grant | **system_basic(受限 ACL)** | ❌ **拿不到** | TASK_KEEPING 长时任务(非 2in1 设备必需,见 §3 引文) |
| **ohos.permission.USE_FRAUD_APP_PICKER** | system_grant | **system_basic(受限)** | ❌ 拿不到 | 反诈应用选择器(@hms.security.antifraudPicker,选分应用) |
| ohos.permission.READ_MEDIA | user_grant | normal | ⚠ 已过时媒体权限,审核需强理由 | 导入文件 |
| ohos.permission.WRITE_MEDIA | user_grant | normal | ⚠ 同上 | 保存文件 |
| ohos.permission.CAMERA | user_grant | normal | ✅ 可用(扫码场景合理) | 扫订阅码 |
| **ohos.permission.READ_PASTEBOARD** | user_grant | **system_basic(受限)** | ❌ 个人开发者拿不到 | 免系统"允许粘贴"弹窗直读剪贴板 |

> 注:`KEEP_BACKGROUND_RUNNING_SPECIAL_SCENARIO`(API 24 起,2in1/tablet/phone)同样是
> **system_basic 受限**,个人开发者同样不可自助使用。

## 3. SDK 权威引文(决定性)

1. **TASK_KEEPING 在手机/平板上必需受限 ACL**(`@ohos.resourceschedule.backgroundTaskManager.d.ts`):
   - `BackgroundMode.TASK_KEEPING = 9`:*"Starting from API version 21, this capability is
     available for PCs/2-in-1 devices, and non-PCs/2-in-1 devices that have obtained the ACL
     permission ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM. In API version 20 and earlier
     versions, this task type is limited to PCs/2-in-1 devices only."*
   - `BackgroundTaskMode.MODE_TASK_KEEPING = 9`:*"When the main type of the continuous task is
     MODE_SPECIAL_SCENARIO_PROCESSING, or that of a **non-PC/2-in-1 device is MODE_TASK_KEEPING**,
     you need to request the ACL permission ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM
     before calling APIs related to continuous tasks."*
   - FlClash 的 deviceTypes 是 phone/tablet ⇒ 它申请 KEEP_BACKGROUND_RUNNING_SYSTEM 正是为此;
     **个人开发者无法获批该 ACL**(受限权限需 AGC 特批,官方认可场景是 2in1/PC)。
2. **DATA_TRANSFER 不是"会话保活"**(同 d.ts,`MODE_DATA_TRANSFER`/`DATA_TRANSFER` 注释):
   - *"During data transfer, the application needs to update the progress. If the progress is not
     updated for more than **10 minutes**, the continuous task of the DATA_TRANSFER type will be
     **canceled**."*
   - *"The notification type of the progress update must be **live view**."*
   - `ContinuousTaskCancelReason.SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED = 4`(**低速也会被取消**)。
3. `startBackgroundRunning`:`@permission ohos.permission.KEEP_BACKGROUND_RUNNING`;错误码
   201(权限被拒)/ 202(非系统应用)/ 9800005(长时任务校验失败);只有 **UIAbility** 能申请。
4. `hiAppEvent` 的 `APP_KILLED` 是公开系统事件常量(无需特殊权限即可 watch,`addWatcher`),
   FlClash 的被杀自愈基于它。

## 4. 对 NekoBox4Harmony 现状的核对(增量结论)

本仓库已有(2026-10-19 后台保活整改,`core/KeepAliveManager.ets`,未提交):
`KEEP_BACKGROUND_RUNNING(normal)` + `module.json5 backgroundModes:["dataTransfer"]` +
KeepAliveManager = wantAgent(START_ABILITY + UPDATE_PRESENT_FLAG)+ `on('continuousTaskCancel')`
1 秒重挂 + `stopBackgroundRunning` 释放;当时已评估放弃 TASK_KEEPING(权限拿不到)。

**本轮逆向新发现的问题:**

1. **DATA_TRANSFER 当"VPN 会话级保活"用,既不合规也不成立**:
   - 场景不符:SDK 把它定义为"上传/下载"(浏览器式传输),VPN 会话不是数据传输任务
     → AGC 审核"功能与申请用途不符"风险;
   - 技术上会被系统取消:**10 分钟无进度通知**(必须 live view 类型)或 **传输低速**
     (CancelReason 4)都会触发 `continuousTaskCancel`。我们没有任何进度通知 ⇒
     现实现的会话任务大概率 10 分钟后失效——"取消重挂"逻辑会不断重挂再被取消,
     与 FlClash 的"一次挂住不掉"根本不是一回事。
2. **FlClash 的 TASK_KEEPING 路径对个人开发者是关闭的**(§3.1)——不能"照抄 FlClash"。
   顺带一个可做的真机实验:把这份 FlClash HAP 装到平板,开 VPN 后上滑杀应用,
   看 VPN 是否存活——如果它也掉,说明它在普通设备上同样没拿到 ACL(201 静默失败)。
3. 我们 `module.json5` 还声明了 **READ_PASTEBOARD(system_basic 受限)**:与 FlClash 同样的问题,
   AGC 个人开发者审核大概率要求移除。移除后剪贴板导入走**系统"允许粘贴"授权弹窗**
   (无权限时的官方路径),真机上需复核这条路径(此前真机导入成功是在已声明该权限的
   debug 包上,不能证明弹窗路径可用)。

## 5. 个人开发者 + VPN 应用在 AGC 上的合法保活组合(建议)

| 层 | 机制 | 权限 | 我们现状 |
|---|---|---|---|
| 流量层 | **VpnExtensionAbility(:vpn 进程)**,VPN 开着系统就让它活着 | 无 | ✅ 已有(内核在扩展进程) |
| 通知层 | 常驻通知 + wantAgent(点按回应用、可带开关 action) | 无 | ✅ 已有 VPN 通知;可加"断开"action(照 FlClash 的 SERVICE_START/SERVICE_STOP want action 语义) |
| 长时任务 | **仅**在真实传输时申请 DATA_TRANSFER + live view 进度通知(≤10 分钟更新),结束即释放 | KEEP_BACKGROUND_RUNNING(normal) | ✅ 已实施(订阅更新期,见 §7) |
| 自愈层 | 持久化运行态 + hiAppEvent(APP_KILLED/JsError/CppCrash)检测 + 启动时 `didCrashOnPreviousExecution` 自动重连 | 无 | ✅ 已实施(`core/CrashGuard.ets`,见 §7) |
| 弃用 | TASK_KEEPING / KEEP_BACKGROUND_RUNNING_SYSTEM / USE_FRAUD_APP_PICKER / READ_PASTEBOARD / READ_MEDIA+WRITE_MEDIA | 受限 | ✅ 已移除声明(READ_PASTEBOARD;其余本就未申请) |

**最小改动清单(待确认后实施):**
1. `module.json5`:删 `backgroundModes:["dataTransfer"]`;删 `ohos.permission.READ_PASTEBOARD`
   声明(改走系统粘贴弹窗,`ClipboardHelper` 需处理 201/弹窗拒绝路径)。
   > ⚠️ **本条已被真机推翻(2026-10-23)**:`backgroundModes:["dataTransfer"]` **不能删**。
   > 删掉后 `startBackgroundRunning` 直接校验失败(code=9800007),传输期长时任务形同不存在;
   > 声明本身不需要任何额外权限,与"个人开发者可上架"并不冲突。现行做法:声明保留,但只在
   > 真实传输期间申请(见 §7)。
2. `KeepAliveManager.ets`:会话期不再常挂长时任务;改为仅在订阅更新/GeoData 下载期间
   申请 DATA_TRANSFER + live view 进度通知,完成即释放;保留取消重挂逻辑(合法场景下仍有用)。
3. 新增"被杀自愈":`hiAppEvent.addWatcher`(APP_KILLED/JsError/CppCrash)+ 运行态落盘;
   启动时若有"上次异常退出且当时 VPN 开着"的标记 → 询问或直接重连(对齐 FlClash,无权限成本)。
4. 文档:`AGENTS.md` 保活口径更新(本轮结论)。

## 6. 复核方式

```powershell
# 解包与证据
Expand-Archive C:\Users\Administrator\Downloads\FlClash-0.8.96+2026102101-ohos.hap C:\Worker\rea-tmp\flclash-hap
Get-Content C:\Worker\rea-tmp\flclash-hap\module.json          # 权限/ability/backgroundModes
# abc 字符串扫描(保活关键词)
$b=[IO.File]::ReadAllBytes('C:\Worker\rea-tmp\flclash-hap\ets\modules.abc'); $t=[Text.Encoding]::Latin1.GetString($b)
$t.Contains('TASK_KEEPING'); $t.Contains('startBackgroundRunning'); $t.Contains('continuousTaskCancel')
# 权限等级
Select-String 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\lib\PermissionDefinitions.json' -Pattern 'KEEP_BACKGROUND_RUNNING_SYSTEM' -Context 2,8
# SDK 文档
Select-String 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.resourceschedule.backgroundTaskManager.d.ts' -Pattern 'TASK_KEEPING' -Context 6,10
```

## 7. 落地记录(2026-10-23 已实施,详见 CHANGES.md 同日条目)

按 §5 的合法组合完成整改,`assembleHap -p buildMode=release` BUILD SUCCESSFUL,产物 HAP 解包复核:
`module.json` **包含** `backgroundModes:["dataTransfer"]`(真机反证必需,见下),不含 `READ_PASTEBOARD`,
保留 `KEEP_BACKGROUND_RUNNING`。

- **新增** `core/KeepAlivePolicy.ets`(纯函数,19 断言测试 `tests/keepalive-policy.cjs`):
  `shouldHoldTransfer`(只放行 `subscription`/`geo` 真实传输,拒绝 `session`)、
  `TRANSFER_WARN_MS=8min < TRANSFER_CANCEL_MS=10min`、被杀自愈决策 `killRecoveryAction`、
  落盘标记编码 `alive|profileId|updatedAt`。
- **重写** `core/KeepAliveManager.ets`:`beginTransfer(reason)/endTransfer(reason)`,
  会话期不再申请长时任务;`continuousTaskCancel` 1 秒重挂仅限传输期;8 分钟告警日志。
- **新增** `core/CrashGuard.ets`(FlClash AppCrashWatcher 同思路,零权限):
  VPN 启动落盘"活着"、显式断开落盘干净退出;启动读回并**消费**"上次被杀"标记;
  hiAppEvent watcher(OS 域 `APP_KILLED/APP_CRASH/APP_FREEZE`)仅日志取证
  (SDK 无 `JsError/CPP_CRASH` 常量名,`didCrashOnPreviousExecution` 在本 SDK 不存在,
  决策不依赖 watcher)。
- **接线**:`VpnService.connect/disconnect` 移除会话保活调用;`EntryAbility.onCreate`
  注入 context + `CrashGuard.init`,后台订阅更新改走 beginTransfer/endTransfer;
  `Index.onRunningChange` 写标记;`Index.maybeRecoverAfterKill()` 启动自愈
  (自动连接开启→直接重连,否则确认框,文案 `crash_recovery_title/prompt/connect` 中英)。
- **module.json5**:~~删 `backgroundModes:["dataTransfer"]`~~ → **保留**(真机反证:删掉后
  `长时任务申请失败: code=9800007`,传输期长时任务失效);~~删 `READ_PASTEBOARD`~~ →
  **同样保留**(2026-10-23 AGC 退回反证:AGC 发布 profile 的 ACL 已放行该权限,删掉后包内
  少了 user_grant 权限、隐私政策里还在,被判"不一致"退回;2.1.10 及以前包内有它,故能过审)。
- **待真机回归**:① 无权限声明下的剪贴板"允许粘贴"弹窗路径;② 被杀自愈两条分支
  (开/关"启动自动连接");③ FlClash HAP 装平板做 TASK_KEEPING 对照实验
  (验证它在无 ACL 设备上是否 201 静默失败)。
  > 补充(2026-10-23):② 的"自动重连"分支已在真机触发过(VPN 在线时被安装流程杀掉 → 重启后
  > 自动重建隧道,约 20s,8 次失败后成功),确认自愈链路可用;③ 仍未做。
