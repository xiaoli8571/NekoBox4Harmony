# NekoBox for Harmony — Agent 交接说明

> **当前阶段(2026-09-08)先看这里**:正式版 **1.9.0(versionCode 1001926)** 已发布(GitHub Releases),内核升级为 **sing-box v1.14.0**(OHOS 补丁扩至 5 组 + 新增 URL 测速 CGo 导出,见「内核」节)。开发工作区可能在远程服务器 `/worker/NekoBox4Harmony`(**root 凭据一律存 ZCode 持久记忆 `dev-credentials.md`,禁止写入仓库文档**——旧版本文档曾把明文密码公开在 GitHub main,已要求轮换服务器密码)。接手开发的 agent 先读根目录 `HANDOFF.md`(完整交接指令)与 `DEVPLAN.md`(任务与验收),F 阶段 F1~F7 已全部交付(勿重做)。本文件其余内容为架构与构建说明,继续有效。

任何 AI Agent 接手本项目前必读。git 仓库克隆自 https://github.com/xiaoli8571/NekoBox4Harmony (main 分支)。

> 2026-09-02 起,仓库已改为「克隆即可构建」:内核源码(含全部 OHOS 补丁)**和成品内核 `entry/libs/arm64-v8a/libsingbox.so`** 随仓库分发;`build-profile.json5` 为无签名配置(`signingConfigs: []`),克隆后直接 assembleHap 即得未签名 HAP,零额外步骤。`hvigorw.js` 已打补丁修复 Node ≥ 18.20 下 `.cmd` 子进程 EINVAL 问题(见下)。

## 项目是什么

HarmonyOS NEXT 原生 VPN 客户端,参考 [NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid),内核为 **sing-box v1.14.0**(支持 Hysteria2/TUIC v5),以 **c-shared .so 进程内 dlopen** 方式运行(沙箱禁止 exec)。

- GitHub: https://github.com/xiaoli8571/NekoBox4Harmony (推送: `git push origin main`;若直连失败用 `git -c http.proxy=http://127.0.0.1:7897 push`)
- Notion 开发文档(架构/踩坑/迭代计划): 页面 "NekoBox for Harmony 开发文档",页面 id `3cb716a2-385f-8033-98c6-cf1777bbb876`
- 真机: MatePad mini(MLR-AL00,HarmonyOS 7.0.0.105 / API 24),hdc 走 USB 或无线 `hdc tconn <设备IP:39933>`(端口以平板「无线调试」显示为准)
- 凭据: GitHub 令牌与 Notion API 在 ZCode 持久记忆 `dev-credentials.md`(用户已要求永久存储,不要再向用户索要;严禁写入仓库任何文件)

## 当前状态(v1.9.0,2026-09-08)

- **内核已从 sing-box 1.11.9 升级到 1.14.0(2026-09-08),本轮开发基调不再是内核冻结**,但 CGo 既有 4 个导出契约保持稳定,新增测速导出见「内核」节。
- 1.14 升级过程中修掉的两个真机启动失败(务必留意回归):
  1. **ArkTS 层**:1.14 新式 DNS server 不允许 `detour` 到「空 direct outbound」(`detour to an empty direct outbound makes no sense`)。`ConfigBuilder` 已去掉 local DNS 的 `detour:"direct"`——1.12+ 不写 detour 即默认直连,语义不变。
  2. **内核层(补丁 5)**:1.14 的 direct outbound 新增 `fetchMyAddresses()`,在 `auto_detect_interface=false` 下会命中补丁 2 早退留下的 nil `InterfaceMonitor` → **SIGSEGV**(cppcrash 栈顶 `direct.(*Outbound).fetchMyAddresses`)。已在 `protocol/direct/outbound.go` 判空,构建脚本已固化该校验。
- **URL Test 真连接测速**(1.9.0 新增):设置「测速方式」默认 URL Test(代理隧道→TLS→HTTP 探活,绿=真可用),可切回 TCPing;由内核包装层 `CGoTest*` 导出在 UI 进程起临时测试实例(无 TUN,不影响 VPN),失败自动回退 TCPing。默认测试网址 `https://www.gstatic.com/generate_204`(旧默认 cloudflare 会在 Store 里自动迁移)。
- versionCode 1001926 / versionName 1.9.0(AppScope/app.json5)。1.14 时代开发包 1001922~1001925 仅存在于测试机,未入库。
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

## 内核(core/)构成

- `core/sing-box-1.11/` — 旧版 **v1.11.9 源码(含 OHOS 补丁)**,仅保留作历史参考/回退;**当前发布内核不再用它编译**。
- `core/sing-box-1.14/` — **v1.14.0 源码(含 OHOS 补丁,当前发布内核,随仓库分发)**。v1.11 的四组补丁已全部移植,并新增补丁 5:
  1. `protocol/tun/inbound.go`:TUN fd 注入(扩展进程经 `SING_BOX_TUN_FD` 环境变量交给 sing-tun,显式非法值 fail-closed);
  2. `route/network.go` + `route/zz_ohos_*.go`:netlink monitor 早退(`isOpenHarmonyRuntime` 用 build tag 判断,因为 OHOS Go fork 的 `runtime.GOOS` 返回 "linux";`auto_detect_interface=false` 时不创建 monitor,修复 OHOS 上断网根因);
  3. `common/dialer/default.go` + `common/dialer/zz_ohos_forcebind*.go`:防回环内核级保险(出站 socket 强制 SO_BINDTODEVICE 到 `SING_BOX_BIND_IFNAME` 指定物理网卡)——**休眠钩子**,当前无任何代码设置该环境变量;
  4. sing-tun 模块缓存补丁(netlink 订阅改 best-effort + OpenHarmony default-interface 检查禁用):构建脚本在 `core/build/libsingbox-ohos/` 生成补丁副本,经 wrapper go.mod 的 replace 生效,不修改仓库源码;
  5. `protocol/direct/outbound.go`:`fetchMyAddresses()` 先判 `InterfaceMonitor() == nil` 再取 `MyInterfaces()`。1.14 direct outbound 新增的此方法会在 PostStart 无脑调用,命中补丁 2 早退留下的 nil monitor → **SIGSEGV**(真机 1.14 首启崩溃根因)。上游 `dhcp.go` 有同款判空,构建脚本 fail-closed 校验该标记。
- 另有两处 1.14 专属工具链兜底:`sync.WaitGroup.Go` 回植(fork `src/sync/waitgroup_go125api.go`,模板见 `core/patches/`),以及 quic-go `quic_event_go124_ohos.go` shim(`!go1.25`,对应 fork 上游保守分支)。
- 实际防回环机制:`route.default_interface`(设置页实验选项,ConfigBuilder 写入配置)+ 补丁 2。
- `core/libsingbox14/` — Go 包装层。导出 `CGoStartSingBox / CGoStopSingBox / CGoSetTunFd / CGoSingBoxVersion`(既有契约)+ **`CGoTestStartSingBox / CGoTestProxySingBox / CGoTestStopSingBox`**(1.9.0 URL 测速:UI 进程内起独立临时 box 做真连接测速,`testStart` 强制清空 inbounds/endpoints/experimental 双保险,与 VPN 主实例互不影响)。版本字符串硬编码 "1.14.0-ohos-inproc"。
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
- `entry/src/main/ets/utils/LatencyTester.ets` — 测速:`tcpPing`(TCPing) 与 `urlTestProfiles`(URL Test 真连接,UI 进程经 `CGoTest*` 临时实例逐节点探活,启动失败自动回退 TCPing)
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
