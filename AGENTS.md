# NekoBox for Harmony — Agent 交接说明

> **当前阶段(2026-09-03)先看这里**:开发工作区已迁移到远程服务器 `root@oc1.720820.xyz:/worker/NekoBox4Harmony`(密码 `Lijx.820115`,SSH 22 端口;FTP 同账号,PASV)。接手开发的 agent 先读根目录 `HANDOFF.md`(完整交接指令)与 `DEVPLAN.md`(任务与验收),当前基线 1.5.7(versionCode 1001716),F1~F6 已完成(F2~F6 待真机验证),当前任务 F7(UI 适配鸿蒙,阶段最后一项)。本文件其余内容为架构与构建说明,继续有效。

任何 AI Agent 接手本项目前必读。代码根目录:`C:\Users\Administrator\NekoBox4Harmony`(git 仓库,main 分支,对应 GitHub https://github.com/xiaoli8571/NekoBox4Harmony )。

> 2026-09-02 起,仓库已改为「克隆即可构建」:内核源码(含全部 OHOS 补丁)**和成品内核 `entry/libs/arm64-v8a/libsingbox.so`** 随仓库分发;`build-profile.json5` 为无签名配置(`signingConfigs: []`),克隆后直接 assembleHap 即得未签名 HAP,零额外步骤。`hvigorw.js` 已打补丁修复 Node ≥ 18.20 下 `.cmd` 子进程 EINVAL 问题(见下)。

## 项目是什么

HarmonyOS NEXT 原生 VPN 客户端,参考 [NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid),内核为 **sing-box v1.11.9**(支持 Hysteria2/TUIC v5),以 **c-shared .so 进程内 dlopen** 方式运行(沙箱禁止 exec)。

- GitHub: https://github.com/xiaoli8571/NekoBox4Harmony (推送: `git push origin main`;若直连失败用 `git -c http.proxy=http://127.0.0.1:7897 push`)
- Notion 开发文档(架构/踩坑/迭代计划): 页面 "NekoBox for Harmony 开发文档",页面 id `3cb716a2-385f-8033-98c6-cf1777bbb876`
- 真机: MatePad mini,HarmonyOS 6.1.1(API 24),hdc 连接 192.168.3.146:39933
- 凭据: GitHub 令牌与 Notion API 在 ZCode 持久记忆 `dev-credentials.md`(用户已要求永久存储,不要再向用户索要)

## 当前状态(v1.5.6v,2026-09-02)

- **开发基调:内核冻结。** 用户明确要求:基于 1.5.6v(内核 sing-box v1.11.9 + 现有补丁)只做 UI/功能增量,不动内核、不动 CGo 接口契约。
- 2026-09-02 曾在 GitHub 上追加 3 个 UI 提交(2518d52 触感/液态玻璃、baaaca1 协议编辑器校验、ba2dd10 节点/订阅分组),其中 `Index.ets` 在 Row/Column 上使用了本机 SDK 不支持的 `.stateEffect()` 编译失败,已整体回退到 e60ef8a 的 UI 代码;后续重做这些功能时注意 Row/Column 没有 `stateEffect`(Button 等组件才有;SDK 的 `useEffect` 是液态玻璃效果模板开关,与按压态无关)。
- 发布内核与 9-02 交付的 `NekoBox4Harmony-1.5.6v-unsigned.hap`(dist)内嵌 .so 同源:dep 指纹 sing@v0.6.7 / sing-tun@v0.6.4 / quic-go@v0.49.0-beta.1,`CGoSingBoxVersion` 返回硬编码 "1.11.9-ohos-inproc"。
- versionCode 1001709 / versionName 1.5.6v(AppScope/app.json5)。

## 构建方法(命令行,勿开 DevEco GUI)

**克隆后直接构建 HAP 只需第 2 步**(成品 .so 已入库);第 0/1 步仅在改内核时需要。产物为未签名 HAP,安装前在 DevEco 里签名(见"注意事项")。

```bash
cd /c/Users/Administrator/NekoBox4Harmony

# 0. 新机器一次性:构建 OHOS Go fork(装到 ~/ohos-go-build/ohos_golang_go)
bash core/scripts/build-ohos-toolchain.sh

# 1. 内核 .so(改了 core/sing-box-1.11 或 core/libsingbox14 后必须重跑;源码已在仓库内,克隆即可跑)
bash core/scripts/build-libsingbox-ohos.sh
# 成功标志:日志含 "wrapper replace: sing-tun -> patched",产物 entry/libs/arm64-v8a/libsingbox.so(~22MB)

# 2. HAP(必须重新打包,旧 HAP 内嵌旧 .so!)
DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk' node hvigorw.js --mode module -p product=default assembleHap --no-daemon
# 产物 entry/build/default/outputs/default/entry-default-unsigned.hap,复制到 dist/ 并按版本命名
```

- 内核构建脚本幂等:仓库源码已带补丁则全部跳过;若 `SINGBOX_SRC` 指向上游裸源码会自动补齐(缺一 fail-closed)。Go 模块代理默认 `goproxy.cn`(可用环境变量 `GOPROXY` 覆盖);hvigor 打包需要命令行有 java,构建前把 DevEco 自带 JBR 加进 PATH(`export PATH="/c/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH"`,否则 PackageHap 报 `spawn java ENOENT`)。
- **`hvigorw.js` 带 `__ohosCmdPatch` 补丁**:hvigor 包装器给新项目缓存目录装 hvigor 依赖时用 `spawnSync` 直接执行 `pnpm.cmd`,Node ≥ 18.20 对无 shell 的 `.cmd` spawn 返回 EINVAL(报 00308002 "pnpm.cmd install execute failed")。补丁把 `.cmd/.bat` 子进程改走 `cmd.exe /d /s /c`,对任何 Node 版本免疫。若将来用 DevEco 重新生成 hvigorw.js,**必须重打该补丁**(补丁文件模式见 git 历史本文件说明;幂等,检测 `__ohosCmdPatch` 标记)。DevEco IDE 打开项目构建不受此问题影响(IDE 用自己的依赖安装路径)。
- 每次改内核源码后:**必须**重跑内核构建脚本 **并** 重新 assembleHap(HAP 里的 .so 不会自动更新,此坑已踩过一次)。

## 内核(core/)构成

- `core/sing-box-1.11/` — sing-box **v1.11.9 源码(含 OHOS 补丁,随仓库分发)**。补丁共 4 组:
  1. `protocol/tun/inbound.go`:TUN fd 注入(扩展进程经 `SING_BOX_TUN_FD` 环境变量交给 sing-tun,显式非法值 fail-closed);
  2. `route/network.go` + `route/zz_ohos_*.go`:netlink monitor 早退(`isOpenHarmonyRuntime` 用 build tag 判断,因为 OHOS Go fork 的 `runtime.GOOS` 返回 "linux";`auto_detect_interface=false` 时不创建 monitor,修复 OHOS 上断网根因);
  3. `common/dialer/default.go` + `common/dialer/zz_ohos_forcebind*.go`:防回环内核级保险(出站 socket 强制 SO_BINDTODEVICE 到 `SING_BOX_BIND_IFNAME` 指定物理网卡)——**休眠钩子**,当前无任何代码设置该环境变量;
  4. sing-tun 模块缓存补丁(netlink 订阅改 best-effort):构建脚本在 `core/build/libsingbox-ohos/` 生成补丁副本,经 wrapper go.mod 的 replace 生效,不修改仓库源码。
- 实际防回环机制:`route.default_interface`(设置页实验选项,ConfigBuilder 写入配置)+ 补丁 2。
- `core/libsingbox14/` — Go 包装层(导出 CGoStartSingBox / CGoStopSingBox / CGoSetTunFd / CGoSingBoxVersion;版本字符串硬编码 "1.11.9-ohos-inproc")。
- `core/scripts/build-ohos-toolchain.sh` — 一次性构建 OHOS Go fork(openharmony-sig/ohos_golang_go,go1.24 分支,arm64 TLSDESC 补丁,必须用它编 musl 可用的 c-shared)。
- `core/scripts/build-libsingbox-ohos.sh` — 内核构建脚本(幂等补丁 + fail-closed 校验 + replace 校验)。
- `core/patches/` — 历史补丁与 zz 文件副本(fallback 安装源)。
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
- `entry/src/main/ets/core/ConfigBuilder.ets` — sing-box 1.11 schema 配置生成(规则/全局/直连、DNS 劫持、geo 分流、per-app)
- `entry/src/main/cpp/napi_init.cpp` — NAPI dlopen 与 fd 传递
- `core/libsingbox14/main.go` — CGo 导出与 TUN fd 注入

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
