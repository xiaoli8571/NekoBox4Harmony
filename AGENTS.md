# NekoBox for Harmony — Agent 交接说明

> **当前阶段(2026-09-08)先看这里**:正式版 **1.9.0(versionCode 1001926)** 已发布(GitHub Releases),内核升级为 **sing-box 1.15.0-alpha.13**(OHOS 补丁扩至 5 组 + 新增 URL 测速 CGo 导出,见「内核」节)。开发工作区可能在远程服务器 `/worker/NekoBox4Harmony`(**root 凭据一律存 ZCode 持久记忆 `dev-credentials.md`,禁止写入仓库文档**——旧版本文档曾把明文密码公开在 GitHub main,已要求轮换服务器密码)。接手开发的 agent 先读根目录 `HANDOFF.md`(完整交接指令)与 `DEVPLAN.md`(任务与验收),F 阶段 F1~F7 已全部交付(勿重做)。本文件其余内容为架构与构建说明,继续有效。

任何 AI Agent 接手本项目前必读。git 仓库克隆自 https://github.com/xiaoli8571/NekoBox4Harmony (main 分支)。

> 2026-09-02 起,仓库已改为「克隆即可构建」:内核源码(含全部 OHOS 补丁)**和成品内核 `entry/libs/arm64-v8a/libsingbox.so`** 随仓库分发;`build-profile.json5` 为无签名配置(`signingConfigs: []`),克隆后直接 assembleHap 即得未签名 HAP,零额外步骤。`hvigorw.js` 已打补丁修复 Node ≥ 18.20 下 `.cmd` 子进程 EINVAL 问题(见下)。

## 项目是什么

HarmonyOS NEXT 原生 VPN 客户端,参考 [NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid),内核为 **sing-box 1.15.0-alpha.13**(支持 Hysteria2/TUIC v5),以 **c-shared .so 进程内 dlopen** 方式运行(沙箱禁止 exec)。

- GitHub: https://github.com/xiaoli8571/NekoBox4Harmony (推送: `git push origin main`;若直连失败用 `git -c http.proxy=http://127.0.0.1:7897 push`)
- Notion 开发文档(架构/踩坑/迭代计划): 页面 "NekoBox for Harmony 开发文档",页面 id `3cb716a2-385f-8033-98c6-cf1777bbb876`
- 真机: MatePad mini(MLR-AL00,HarmonyOS 7.0.0.105 / API 24),hdc 走 USB 或无线 `hdc tconn <设备IP:39933>`(端口以平板「无线调试」显示为准)
- 凭据: GitHub 令牌与 Notion API 在 ZCode 持久记忆 `dev-credentials.md`(用户已要求永久存储,不要再向用户索要;严禁写入仓库任何文件)

## 当前状态(v1.9.0,2026-09-08)

- **内核已从 sing-box 1.11.9 → 1.14.0 → 1.15.0-alpha.13(2026-10-30,与 OwnBoxForAndroid 对齐),本轮开发基调不再是内核冻结**,但 CGo 既有 4 个导出契约保持稳定,新增测速导出见「内核」节。
- **后台保活口径(2026-10-23 定稿,依据 `docs/REA-FLCLASH-KEEPALIVE.md`)**:申请目标是"个人开发者能过 AGC"的权限组合,
  **不要照抄 FlClash 的 `TASK_KEEPING`** —— 该模式在 phone/tablet 上必需受限 ACL `KEEP_BACKGROUND_RUNNING_SYSTEM`
  (system_basic,个人开发者拿不到)。现行设计:VPN 会话不申请长时任务(存活靠 VpnExtensionAbility 系统托管 + 常驻通知
  + 被杀自愈 `core/CrashGuard.ets`);长时任务只在**真实数据传输**(订阅更新)期间由 `core/KeepAliveManager.beginTransfer('subscription')`
  短时持有,`DATA_TRANSFER` 10 分钟无 live view 进度通知会被系统取消(SDK 硬约束)。
  ⚠️ **`module.json5` 的 `"backgroundModes": ["dataTransfer"]` 必须保留**(2026-10-23 真机反证):
  删掉后 `startBackgroundRunning` 直接校验失败,日志为 `长时任务申请失败: code=9800007 msg=...`(此前只打到
  `[object Object]`,已补 `utils/ErrText.ets` 序列化);声明本身**不需要**额外权限,`GET_NETWORK_INFO` 等是给别处用的。
  <!-- 权限口径见下一条:剪贴板权限必须保留 -->
  ⚠️ **剪贴板权限必须保留(2026-10-23 AGC 退回教训)**:`ohos.permission.READ_PASTEBOARD`(user_grant /
  system_basic)在 AGC 发布 profile 的 `acls.allowed-acls` 里**已放行**,`module.json5` 必须声明它,
  否则 AGC 报「软件包 user_grant 权限与隐私政策不一致,只在隐私政策中的权限:[READ_PASTEBOARD]」而退回
  (2.1.10 能过审正是因为包内有它)。改权限必须同步 `docs/PRIVACY-POLICY.md` 并跑
  `node tests/permission-policy.cjs`(它断言"包内集合 == 政策集合"、user_grant 标注、system_basic 有 ACL)。
  仍**不要**申请 `KEEP_BACKGROUND_RUNNING_SYSTEM` / `USE_FRAUD_APP_PICKER` / `KEEP_BACKGROUND_RUNNING_SPECIAL_SCENARIO`
  这类未获 ACL 的 system_basic;任何"新增保活手段"先核对
  `toolchains/lib/PermissionDefinitions.json` 的 `availableLevel`。
- **体验修正口径(2026-10-26,有意偏离安卓 1:1,勿在"对齐安卓"名义下回退)**:
  1. `bypassLan` 默认 **true**(安卓 `DataStore.bypassLan` 默认 false)。关闭时私网流量被送进代理,
     真机日志实测 `192.168.8.1:80 → outbound/hysteria2 → i/o timeout`,用户侧是路由器后台/NAS/打印机/
     SMB 全失联。存量装机由 `Store.loadSettings` 末尾的一次性修正(`KEY_DEFAULTS_V3`)翻成 true,
     **必须写回 settings JSON**(只改内存会让先加载的 UI 进程把标记打掉、后加载的 :vpn 进程仍读旧值,
     配置里就缺 `ip_is_private` 规则 —— 真机验证踩过)。
  2. `urltest.interval` = **5m**(原 10m 照抄安卓),掉线切换最长滞后从 10 分钟降到 5 分钟,
     与 FlClash/Clash Verge 的 url-test 周期一致;`PolicyGroups.AutoSelectDefaults.intervalSec` 同步 300。
  3. 探测地址统一 `DEFAULT_PROBE_URL = http://cp.cloudflare.com/`(ConfigBuilder 兜底/Profile 默认/
     ToolsPage/`ClashApi.URL_TEST_TARGET` 同一值);旧默认 gstatic 由同一次一次性修正迁移,
     仅逐字符相等才改,自定义网址不动。
- 1.14 升级过程中修掉的两个真机启动失败(务必留意回归):
  1. **ArkTS 层**:1.14 新式 DNS server 不允许 `detour` 到「空 direct outbound」(`detour to an empty direct outbound makes no sense`)。`ConfigBuilder` 已去掉 local DNS 的 `detour:"direct"`——1.12+ 不写 detour 即默认直连,语义不变。
  2. **内核层(补丁 5)**:1.14 的 direct outbound 新增 `fetchMyAddresses()`,在 `auto_detect_interface=false` 下会命中补丁 2 早退留下的 nil `InterfaceMonitor` → **SIGSEGV**(cppcrash 栈顶 `direct.(*Outbound).fetchMyAddresses`)。已在 `protocol/direct/outbound.go` 判空,构建脚本已固化该校验。
- **URL Test 真连接测速**(2026-10-23 起按安卓 1:1 重整):顶栏 ⋮ 菜单两个入口「TCPing」/「URL Test」
  (与安卓 `add_profile_menu.xml` 一致,菜单直接定方式,不再依赖「测速方式」设置);URL Test 由内核包装层
  `CGoTest*` 导出在 UI 进程起临时测试实例(无 TUN,不影响 VPN),失败自动回退 TCPing。结果模型与安卓
  `ProxyEntity` 一致:`status(0/1/2/3) + ping + error` 三件套,**延迟颜色按区间分档**(2026-10-23 用户要求,
  与分组标签 `latencyColorOfMs` 同一套阈值):`<150ms` 绿 / `150~400ms` 琥珀(warning)/ `>400ms` 红;
  失败(status≥2)红、无结果显示 `—`。此前"绿=任意成功值、无 150/400 分档"是照抄安卓,已按用户实测反馈改回分档。
  失败文案双语化、status3 点击弹内核原文。默认测试网址 `http://cp.cloudflare.com/`(与安卓
  `Constants.kt:3` 一致;Store 只兜空值,不再做 gstatic 迁移)。测速会话实现形态是「整批一个临时实例 +
  按 tag 并发探测」(安卓为每节点一个实例;内核 `testInstance` 是包级单例,逐节点建实例只能串行,
  见 docs/PARITY-LATENCY-TEST.md D-1)。
- **主菜单口径(2026-10-23 审计定稿,见 `docs/MENU-PARITY-7.md`)**:抽屉固定 7 项
  (配置/分组/路由/设置/日志/工具/关于),对应安卓 1.4.2 `main_drawer_menu.xml` 里除
  Dashboard(yacd)/推广/文档 之外的 7 项;**这 3 项不做,也不要再当缺口提**。审计事实见
  `docs/menu-audit/{android-side,ours-side,device-checks}.md`(196 个可点项 = 161✅/30⚠️/5❌)。
  已知待修:顶栏搜索图标在 6 个非配置页点击无反应、⋮「清除流量统计」被 1s 轮询写回、路由「包名」
  缺 `packagesEnabled` 入口(其余死路清单见 ours-side §10 D1~D12)。
- **UI 观感口径(2026-10-23 用户实测定稿)**:底部速率条**半透明 + 纯背景模糊**
  (`.backdropBlur(20)` + `statsbar_bg` 不透明度 ≈72%,base/dark 各一份);**不要用
  `backgroundBlurStyle(BlurStyle.COMPONENT_*)`** —— 组件材质自带近乎不透明的填充,会把半透明底色吃掉,
  真机观感变成"完全不透"。常驻通知只显示**实时速率 + 本次运行时长**(去掉节点名/分组名/延迟,
  文案见 `utils/NotifyText.ets`+`app.string.notification_uptime`),`VpnExtAbility` 会在内容变化时
  打一条 `[vpn] 通知内容: …` 便于真机核对。
- versionCode 1001926 / versionName 1.9.0 是**历史发布版**基线;**自 2.2.0 起版本号已统一**:
  `AppScope/app.json5` = `2200000` / `2.2.0`,`oh-package.json5`(根与 entry)= `2.2.0`,
  `pack.info` 由构建自动写入;关于页动态读 bundleManager,无硬编码。版本号编码规则
  `major*1000000 + minor*100000 + patch`(如 2.1.18 → 2100018,2.2.0 → 2200000)。
  ⚠️ 内核版本字符串 `1.15.0-alpha.13-ohos-inproc`(`core/libsingbox14`)是 **sing-box 版本**,不随应用版本变。
  该串与 `AboutPage.CORE_VERSION`、`ToolsPage` 诊断字段由 `tests/kernel-version.cjs` 强制同源(格式差异除外)。
- 历史:1.5.6v(内核 1.11.9)及更早状态见 git log;`stateEffect` 坑、UI 回退事件等记录保留在 git 历史与 Notion。

## 构建方法(命令行,勿开 DevEco GUI)

**克隆后直接构建 HAP 只需第 2 步**(成品 .so 已入库);第 0/1 步仅在改内核时需要。产物为未签名 HAP,安装前在 DevEco 里签名(见"注意事项")。

```bash
cd <本仓库根目录>

# 0. 新机器一次性:构建两套 Go 工具链
#   A) go1.24.5 OHOS fork(编译用,装到 ~/ohos-go-build/ohos_golang_go),
#      并把 core/patches/ohos-gofork-waitgroup-go.txt 回植为 <fork>/src/sync/waitgroup_go125api.go
#      (1.14 依赖树实际调用 sync.WaitGroup.Go,fork 停在 go1.24.5,必须回植)后重建
bash core/scripts/build-ohos-toolchain.sh
#   B) go >= 1.25.5 主机工具链(仅供模块解析/tidy/vendor,纯上游即可):
#      环境变量 GO126 指向其 go 可执行文件(如 "/c/Program Files/Go/bin/go")
#   C) OHOS native SDK(DevEco 自带,构建脚本自动探测 clang)

# 1. 内核 .so(改了 core/sing-box-1.14 或 core/libsingbox14 后必须重跑;源码已在仓库内,克隆即可跑)
GO126="/c/Program Files/Go/bin/go" bash core/scripts/build-libsingbox-ohos.sh
# 成功标志:日志含 "wrapper replace: sing-tun -> patched" 与 "ALL verification markers passed",
# 产物 entry/libs/arm64-v8a/libsingbox.so(~41MB,含 CGoTest* 测速导出)

# 2. HAP(必须重新打包,旧 HAP 内嵌旧 .so!)
DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk' node hvigorw.js --mode module -p product=default assembleHap --no-daemon
# 产物 entry/build/default/outputs/default/entry-default-unsigned.hap,复制到 dist/ 并按版本命名
```

- 内核构建脚本幂等:仓库源码已带补丁则全部跳过;若 `SINGBOX_SRC` 指向上游裸源码会自动补齐(缺一 fail-closed)。Go 模块代理默认 `goproxy.cn`(可用环境变量 `GOPROXY` 覆盖);hvigor 打包需要命令行有 java,构建前把 DevEco 自带 JBR 加进 PATH(`export PATH="/c/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH"`,否则 PackageHap 报 `spawn java ENOENT`)。
- **`hvigorw.js` 带 `__ohosCmdPatch` 补丁**:hvigor 包装器给新项目缓存目录装 hvigor 依赖时用 `spawnSync` 直接执行 `pnpm.cmd`,Node ≥ 18.20 对无 shell 的 `.cmd` spawn 返回 EINVAL(报 00308002 "pnpm.cmd install execute failed")。补丁把 `.cmd/.bat` 子进程改走 `cmd.exe /d /s /c`,对任何 Node 版本免疫。若将来用 DevEco 重新生成 hvigorw.js,**必须重打该补丁**(补丁文件模式见 git 历史本文件说明;幂等,检测 `__ohosCmdPatch` 标记)。DevEco IDE 打开项目构建不受此问题影响(IDE 用自己的依赖安装路径)。
- 每次改内核源码后:**必须**重跑内核构建脚本 **并** 重新 assembleHap(HAP 里的 .so 不会自动更新,此坑已踩过一次)。

### 一键:重编 + 打包 + 签名(2026-09 新增)

`scripts/build-and-sign.sh` 把上面第 1/2 步加上签名串成一条。签名材料**不入库**(含私钥),
按以下顺序自动探测,也可用 `SIG_DIR` 环境变量或 `-CertDir`(ps1)/手动放位覆盖:

1. `<repo>/签名材料/` —— 本仓库专用材料 `{NekoBox-release.p12|NekoBox.p12, NekoBox.cer, NekoBoxRelease.p7b}`,别名 `nekobox`(
   由 `scripts/fix-release-keystore.sh` 生成的 `NekoBox-release.p12` 装载华为发布证书;
   **本机当前不存在此目录**)
2. `C:\Worker\AGC通用证书/` —— 多项目共用的 AGC 发布材料 `{General.p12, General.cer, NekoBoxRelease.p7b}`,
   别名 `general`;**本机实际可用的就是这一套**

```bash
export PATH="/c/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH"
SIGN_P12_PASS='<密钥库密码>' bash scripts/build-and-sign.sh
# 产物 dist/NekoBox-<version>-signed.hap
```

- **密码只从环境变量取**(bash 脚本用 `SIGN_P12_PASS`,AGC 双层签名 ps1 用 `AGC_KEY_PASSWORD`),
  不写脚本、不写 `build-profile.json5`、不提交仓库(旧版本文档曾把明文密码提交到 GitHub main,踩过)。
- 发布包(.hap + .app)走 AGC 双层签名:
  `pwsh -File scripts/sign-release-agc.ps1`(先 `assembleApp`;脚本从 `build/outputs/default/*-unsigned.app` 取料,
  自动在 `C:\Worker` 下找含 `General.p12` 的目录,双层 verify + 发布证书链指纹断言,产物写 `dist/`)。
- 脚本用 `scripts/inject-signing.js` 幂等地把签名段注入 `build-profile.json5`。
  还原成仓库基线:`node scripts/inject-signing.js --profile build-profile.json5 --reset`。
- **注入后 `build-profile.json5` 是本地修改,别提交**(见「注意事项」)。
- 装不上先查 `AppScope/app.json5` 的 `versionCode` 是否高于设备上已装版本。

## 内核(core/)构成

- `core/sing-box-1.11/` — 旧版 **v1.11.9 源码(含 OHOS 补丁)**,仅保留作历史参考/回退;**当前发布内核不再用它编译**。
- `core/sing-box-1.14/` — **v1.14.0 源码(含 OHOS 补丁,当前发布内核,随仓库分发)**。v1.11 的四组补丁已全部移植,并新增补丁 5:
  1. `protocol/tun/inbound.go`:TUN fd 注入(扩展进程经 `SING_BOX_TUN_FD` 环境变量交给 sing-tun,显式非法值 fail-closed);
  2. `route/network.go` + `route/zz_ohos_*.go`:netlink monitor 早退(`isOpenHarmonyRuntime` 用 build tag 判断,因为 OHOS Go fork 的 `runtime.GOOS` 返回 "linux";`auto_detect_interface=false` 时不创建 monitor,修复 OHOS 上断网根因);
  3. `common/dialer/default.go` + `common/dialer/zz_ohos_forcebind*.go`:防回环内核级保险(出站 socket 强制 SO_BINDTODEVICE 到 `SING_BOX_BIND_IFNAME` 指定物理网卡)——**休眠钩子**,当前无任何代码设置该环境变量;
  4. sing-tun 模块缓存补丁(netlink 订阅改 best-effort + OpenHarmony default-interface 检查禁用):构建脚本在 `core/build/libsingbox-ohos/` 生成补丁副本,经 wrapper go.mod 的 replace 生效,不修改仓库源码;
  5. `protocol/direct/outbound.go`:`fetchMyAddresses()` 先判 `InterfaceMonitor() == nil` 再取 `MyInterfaces()`。1.14 direct outbound 新增的此方法会在 PostStart 无脑调用,命中补丁 2 早退留下的 nil monitor → **SIGSEGV**(真机 1.14 首启崩溃根因)。上游 `dhcp.go` 有同款判空,构建脚本 fail-closed 校验该标记。
  6. `option/rule_action.go` + `route/rule/rule_action.go`:sniff `override_destination` 显式回传(路由 vs 覆写两档)。
  7. `common/urltest/urltest.go`:**URL Test 状态码校验 + HEAD→GET 回退**。上游 `urlTest` 拿到 HTTP 响应就返回耗时、从不看 `StatusCode`,探测网址返回 403/404/500(CDN 劫持 / GFW 污染)时节点会被判成"可用",击穿"绿=真可用";同时上游固定用 HEAD,站点对 HEAD 回 405 会让整组假红。新增 `URLTestOptions{Expect2xx, AllowGetFallback}` 与 `URLTestWithOptions`,`URLTest()` 保持原签名并走默认严格选项。构建脚本 fail-closed 校验 `unexpected HTTP status` 标记。
- 另有两处 1.14 专属工具链兜底:`sync.WaitGroup.Go` 回植(fork `src/sync/waitgroup_go125api.go`,模板见 `core/patches/`),以及 quic-go `quic_event_go124_ohos.go` shim(`!go1.25`,对应 fork 上游保守分支)。
- 实际防回环机制:`route.default_interface`(设置页实验选项,ConfigBuilder 写入配置)+ 补丁 2。
- `core/libsingbox14/` — Go 包装层。导出 `CGoStartSingBox / CGoStopSingBox / CGoSetTunFd / CGoSingBoxVersion`(既有契约)+ **`CGoTestStartSingBox / CGoTestProxySingBox / CGoTestStopSingBox`**(URL 测速:UI 进程内起独立临时 box 做真连接测速,`testStart` 强制清空 inbounds/endpoints/experimental 双保险,与 VPN 主实例互不影响)+ **`CGoCheckConfigV1 / CGoValidateSRSFileV1`**(2026-10-24 W05/K1:无副作用纯解析——配置 schema 校验、本地 .srs 内容校验;不调 `box.New`/`Start`、不碰环境变量、不写文件;NAPI `checkConfigNative/validateSrsNative`,dlsym 缺失回退 `"unsupported"`,ArkTS 包装 `CoreManager.checkConfig()/validateSrs()`;源码级守卫测试 `tests/hostprobe/k1_validate_test.go`。.so 现 **16 导出**,sha256 `9b05c0bf…`;W09/K2 再加 `CGoTestStartSingBoxV3 / CGoTestProxySingBoxV3 / CGoTestStopSingBoxV3 / CGoTestSessionInfoV3 / CGoTestActiveSessionsV3`(会话隔离:stop 返回前必须已关闭、启动期间被 stop 的迟到实例立即关闭并写墓碑;NAPI `testStartNativeV3/testProxyNativeV3/testStopNativeV3/testSessionInfoNativeV3/testActiveSessionsNative`,`testCapsNative` 回报 `v3|v2|legacy`;hostprobe `k2_session_test.go` 12 用例))。版本字符串硬编码 "1.15.0-alpha.13-ohos-inproc"(由 `tests/kernel-version.cjs` 与界面展示串、构建标签交叉校验)。
  > ⚠️ **测速导出的版本化约定(V2 / legacy,2026-09 那轮整改引入)**
  >
  > `libsingbox.so` 是随仓库分发的**冻结产物**,而这轮要给它加"响应状态判定"和
  > "测速绕过隧道"两个能力,都要加参数。直接改老导出的签名会让
  > **新 NAPI + 旧 .so** 这个组合崩掉(多传的参数让 Go 侧读到野指针)。
  > 所以改成加新的 V2 导出、保留老的 legacy 签名,NAPI 侧按 V2 优先回退解析:
  >
  > | 导出 | 签名 | 能力 |
  > |---|---|---|
  > | `CGoTestStartSingBoxV2` | `(configPath, bindIfname)` | 可绑物理网卡(测速绕过隧道) |
  > | `CGoTestStartSingBox` | `(configPath)` | legacy,无绑网卡 |
  > | `CGoTestProxySingBoxV2` | `(tag, url, timeoutMs, expectStatus)` | 校验状态码 + HEAD→GET 回退 |
  > | `CGoTestProxySingBox` | `(tag, url, timeoutMs)` | legacy,只发 HEAD 且不看状态码 |
  >
  > NAPI 侧 `testStartNative(configPath, bindIfname, cb)` /
  > `testProxyNative(tag, url, timeoutMs, expectStatus, cb)` 保持统一签名,
  > 内部按 `g_testV2` 分派;另有 `testCapsNative(cb)` 回报 `"v2"` / `"legacy"`,
  > `LatencyTester` 据此如实写日志(legacy 下状态码判定与绕隧道静默失效)。
  >
  > **今后再给 CGo 导出加参数,一律走 V2 后缀 + dlsym 回退,不要原地改签名。**
  > 另外:改了 `core/sing-box-1.14` 或 `core/libsingbox14` 仍必须重编 `.so` +
  > 重新 `assembleHap`,否则新能力不会生效(但不会再崩)。
- `core/scripts/build-ohos-toolchain.sh` — 一次性构建 OHOS Go fork(openharmony-sig/ohos_golang_go,go1.24 分支,arm64 TLSDESC 补丁,必须用它编 musl 可用的 c-shared)。
- `core/scripts/build-libsingbox-ohos.sh` — 内核构建脚本(幂等补丁 + fail-closed 校验 + replace 校验 + 构建后用 `llvm-readelf --dyn-syms` 确认 CGoTest* 导出)。
- `core/patches/` — 历史补丁、zz 文件副本(fallback 安装源)与 `ohos-gofork-waitgroup-go.txt`(WaitGroup.Go 回植模板)。
- 历史:sing-box-1.13.12 升级实验(含移植版补丁)曾以坏 gitlink 形式入库,2026-09-02 已从仓库移除;实验源码仅存在于本机 `C:\Users\Administrator\Downloads\NekoBox\core\`(未推送,勿当作发布内核)。

## 架构速记(详见 Notion 文档)

```
UI 进程 EntryAbility/Index/VpnService(操作串行化)
   │ startVpnExtensionAbility(want.parameters.profileId)   ▲ CommonEvent VPN_LOG/VPN_STATUS
:vpn 进程 VpnExtAbility(onRequest 为实际入口)
   vpnConnection.create(VpnConfig) → TUN fd → protectProcessNet()
   NAPI dlopen libsingbox.so → CGoSetTunFd(fd) → CGoStartSingBox(config)
   Go 包装层: box.Context(注册表) + SING_BOX_TUN_FD 环境变量
```

关键文件:
- `entry/src/main/ets/vpnext/VpnExtAbility.ets` — VPN 生命周期(防重入、看门狗)
- `entry/src/main/ets/core/ConfigBuilder.ets` — sing-box 1.14 schema 配置生成(规则/全局/直连、DNS 劫持、geo 分流、per-app;local DNS 不带 detour)
- `entry/src/main/ets/utils/LatencyTester.ets` — 测速:`tcpPing`(TCPing) 与 `urlTestProfiles`(URL Test 真连接,委托 `core/ProbeRunner` + `core/ProbeCoordinator`;批量启动失败按 §6.4 二分隔离,**不再整批回退 TCPing**,TCP 回退仅逐节点显式开关;结果落 `core/ProbeStore`)
- `entry/src/main/ets/core/Navigation.ets` — 七页导航契约(页面/抽屉顺序/返回语义/顶栏动作与禁用原因/按页浏览记忆),P3/W11 纯模型,`tests/navigation.cjs` 守着。
- `entry/src/main/ets/model/HomeView.ets` — 节点首页视图模型(会话×连通性双状态、状态卡、节点行延迟分档/方式/新鲜度/三态、筛选排序、空态),P3/W12,`tests/home-view.cjs` 守着;页面只渲染不重算。
- `entry/src/main/ets/model/SettingsSchema.ets` — 设置项注册表(54 项=`AppSettings` 全字段,三档生效分类 immediate/nextTask/reconnect)+ 待应用差异(`diffSettings`/`summaryText`/`impactLines`),P4/W16;`tests/settings-schema.cjs`(含读 `Profile.ets` 源码的防漂移断言)与 `tests/i18n-keys.cjs` 守着。**加设置字段必须同时登记 registry + 补 base/en_US 资源键**。
- `entry/src/main/ets/model/RoutingRules.ets` — 规则类型化/校验/编译 manifest/DNS 投影,P4/W13,`tests/routing-rules.cjs`;旧多字段 AND 行存 `legacyRow` 并在编译时合并(**禁止删条件放宽匹配**,§8.5)。
- `entry/src/main/ets/model/RuleEditor.ets` — 规则表单模型(往返/12 校验码逐字段定位/目标缺失不自动替换/旧包名规则三动作),P4/W14,`tests/rule-editor.cjs`。
- `entry/src/main/ets/core/ClashApi.ets` + `entry/src/main/ets/model/PolicyGroups.ets` — 策略组:clash API(GET/PUT `/proxies`,204/400/404/401 与 sing-box 源码对齐)与组模型(稳定 tag `group-<enc(id)>`、环校验、`verifyNow` 只信 PUT 后的 GET、`actualMemberView` 未知即"实际节点未知"),P4/W15;`tests/clash-api.cjs`/`policy-groups.cjs`/`outbound-graph.cjs` 守着。
- **配置应用事务**:扩展 `VpnExtAbility.handleApplyCommand`(幂等/快照 checksum 校验/`settings_out_of_sync`/单次串行重启/回执)+ `VpnIpc.publishVpnApplied(ok,perApp,env,error)`/`subscribeVpnApplied` + `EntryAbility` 写 AppStorage `vpnApply*` 六键;UI 只认匹配 operationId 的回执,设计见 `docs/p4-design/apply-transaction.md`。
- `entry/src/main/cpp/napi_init.cpp` — NAPI dlopen 与 fd 传递,含测速 `testStartNative/testProxyNative/testStopNative`
- `core/libsingbox14/main.go` — CGo 导出、TUN fd 注入与测速会话(`CGoTestStart/Proxy/StopSingBox`)

## 真机排查

```bash
hdc shell "cat /data/app/el2/100/base/com.nekobox.app/haps/entry/files/core/singbox.log"   # 内核日志
hdc shell hilog -x | grep '\[NB\]'                                                          # 应用日志(缓冲易冲掉)
```
错误速查:`permission denied`=沙箱权限点;`no route to host`=防回环路由/绑定;`missing default interface`=monitor 问题(应已修复);`i/o timeout`=服务器不可达。

## 注意事项

- **不动 `module.json5` 的 VPN type(`"vpn"`)。签名用户自理**:仓库内 `build-profile.json5` 是**无签名配置**(`signingConfigs: []`),命令行/IDE 直接构建出的都是未签名 HAP。要装真机:在 DevEco 里 File → Project Structure → Signing Configs 勾自动签名(需登录华为账号),DevEco 会把机器本地的签名段写进 `build-profile.json5`——**这段本地改动不要提交**,提交回去会让其他机器因找不到证书文件而构建失败(此坑已踩过:曾把本机证书路径提交到 GitHub)。
- `entry/libs/arm64-v8a/libsingbox.so` 是**冻结内核成品,随仓库分发**(`.gitignore` 已移除对它的忽略);没有它克隆后无法直接 assembleHap(重编内核需要整套 OHOS Go 工具链)。不要把它当构建产物重新 ignore。
- UI 迭代在 `entry/src/main/ets/`,内核冻结在 `core/`;改内核前先确认没有更简单的 UI 层方案。
- 版本演进记录在 git log 与 Notion 文档;dist 产物按 `NekoBox4Harmony-<版本>-unsigned.hap` 命名。同一 versionCode 的 HAP 无法覆盖安装,发新包先在 `AppScope/app.json5` 升 versionCode/versionName。
- 历史开发会话:`sess_0b799182-b5b4-4610-8759-5e5cd2a89166`(旧机器 xiaoli 时期,ZCode 会话可用 ReadSessionContext 读取)。
- 迭代路线图(对齐 Android NekoBox)在 Notion 文档"迭代计划"章节,按阶段执行。
