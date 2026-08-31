<<<<<<< HEAD
# NekoBox for Harmony — Agent 交接说明(必读)

任何 AI Agent 接手本项目前**先完成第 0 节的三项检查**,再开始任何任务。

## 0. 接手检查(第一次对话必须先做)

1. **工程根目录**(所有源码都在这里):
   - Windows 路径:`C:\Users\xiaoli\Downloads\vpn`
   - Git Bash 路径:`/c/Users/xiaoli/Downloads/vpn`
   - 若你在终端/CLI 里运行,先 `cd` 到这个目录再开始。
2. **源码读取方式**:直接用你的文件读写工具按上面的绝对路径访问(Read/Edit/Write 等)。
   - **不存在"挂载调用端工具"、"上传源码"、"隔离容器"这类步骤** —— 读不到文件只说明你自己的工具会话没就绪,请让用户在工程目录下重启你,**绝不要**让用户"重新上传源码"。
3. **源码完整性自验**(10 秒):
   ```bash
   cd /c/Users/xiaoli/Downloads/vpn && git log --oneline -3
   ```
   最新提交应为 `a738972 release(1.5.4-restored) ...`。源码在本地 git + GitHub 双份,永远不会丢。

## 1. 项目是什么

HarmonyOS NEXT 原生 VPN 客户端,参考 [NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid)。

- 内核:**sing-box v1.11.9**(支持 Hysteria2/TUIC v5/vless reality),以 **c-shared .so 进程内 dlopen** 方式运行在 `:vpn` 扩展进程内(沙箱禁止 exec 二进制 —— 旧 README 里"fork 子进程"架构已废弃,勿采信)。
- GitHub: https://github.com/xiaoli8571/NekoBox4Harmony(main 分支;直连失败时 `git -c http.proxy=http://127.0.0.1:7897 push`)
- Notion 开发文档(完整架构/踩坑表/复发复盘):Notion 页面 "NekoBox for Harmony 开发文档",页面 id `3cb716a2-385f-8033-98c6-cf1777bbb876`
- 真机:MatePad mini,HarmonyOS 6.1.1(API 24);hdc 地址会变,先用 `hdc list targets` 查
- 凭据:GitHub 令牌与 Notion API 在 ZCode 持久记忆 `dev-credentials.md`(用户已要求永久存储,**不要再向用户索要**)

## 2. 当前状态(唯一可信基线)

- **main 分支 = v1.5.4**(versionCode 1001605,提交 `a738972`),**用户真机验证完全可用**。
- 交付物:`dist/NekoBox4Harmony-1.5.4-unsigned.hap`(签名由用户在 DevEco 完成)。
- v1.5.4 功能面:多协议(vless/vmess/ss/trojan/hysteria/hysteria2/tuic/wireguard/http/socks)、分享链接与订阅导入、订阅自动更新+流量到期、reality 节点自动 uTLS、日志页终端配色、图标无透明框、连接列表、测速、规则/全局/直连模式、分应用代理。
- **红线**:v1.5.4 之后的 1.5.5/1.5.6/1.6.x 曾引入主页 UI 改版与 selector 多出站架构,已导致断网事故并**被用户否决删除**(GitHub 已强推覆盖)。**不要**从旧会话、旧文档或记忆中恢复那些代码;重做同类功能时必须先读懂 `core/scripts/build-libsingbox-ohos.sh` 里的 OHOS 补丁与 Notion 第十二~十六章的复盘。

### 1.6.x 断网事故教训摘要(防止重蹈覆辙)

1. OHOS Go fork 下 `runtime.GOOS` 返回 `"linux"`,平台判断必须用 `//go:build openharmony` build tag(runtime 判断是死代码)。
2. `SO_BINDTOIFINDEX` 在 HarmonyOS VPN 场景不可靠,**有效的是 `SO_BINDTODEVICE`(按网卡名)** —— sing v0.6.x 已由构建脚本补丁回退到名字绑定。
3. 防回环三保险:`blockedApplications 含自身包名`(主)+ `protectProcessNet()` + `route.default_interface` 绑定;禁用"服务器 IP/32 排除路由"(死路由)。
4. 改内核后 HAP 不会自动带上新 .so —— 必须重跑内核构建脚本**并**全清 `entry/build` 重新 assembleHap。

## 3. 构建方法(唯一流程,命令行,勿开 DevEco GUI)

```bash
cd /c/Users/xiaoli/Downloads/vpn

# 1) 改了内核(core/sing-box-1.11 或 core/libsingbox14)后必须重跑:
bash core/scripts/build-libsingbox-ohos.sh
# 成功标志:含 "wrapper replace: sing -> patched"、三项 "verified ...";产物 entry/libs/arm64-v8a/libsingbox.so

# 2) 打 HAP(统一脚本:自动清 entry/build + 内核新鲜度校验 + strip 感知 md5 校验):
bash core/scripts/build-hap.sh <版本号>     # 例:1.5.5
# 产物: dist/NekoBox4Harmony-<版本号>-unsigned.hap
```

**重要校验认知**:hvigor 打包会对 .so 做 llvm-strip,HAP 内 .so 的 md5 **必然不同于**源 .so —— 这不是缓存问题!校验必须"源先 strip 再比"(build-hap.sh 已内置,勿手工比裸 md5 后误判"打进旧内核")。

## 4. 架构速记

```
UI 进程 EntryAbility/Index/VpnService(操作串行化)
   │ startVpnExtensionAbility(want.parameters.profileId)   ▲ CommonEvent VPN_LOG/VPN_STATUS
:vpn 进程 VpnExtAbility(onRequest 为实际入口)
   vpnConnection.create(VpnConfig) → TUN fd → protectProcessNet() → blockedApplications 含自身
   NAPI dlopen libsingbox.so → CGoSetTunFd(fd) → CGoStartSingBox(config)
   Go 包装层: box.Context(协议注册表) + SING_BOX_TUN_FD 环境变量
   内核日志 → log.output 文件 → UI 日志页直读(1s 增量轮询)
```

关键文件:
- `entry/src/main/ets/vpnext/VpnExtAbility.ets` — VPN 生命周期(防重入、看门狗、queued 重试)
- `entry/src/main/ets/core/ConfigBuilder.ets` — sing-box 1.11 schema 配置生成(1.11 严格 schema:无 block/dns 出站、DNS 劫持用 `{protocol:'dns',action:'hijack-dns'}`、TUN 用 `address` 数组;reality 强制 utls)
- `core/libsingbox14/main.go` — CGo 导出(CGoSetTunFd/CGoStartSingBox/CGoStopSingBox/CGoSingBoxVersion)
- `core/sing-box-1.11/` — 内核源码树(untracked,含 OHOS 补丁;`core/sing-box/` 是 1.4.6 遗留备份,勿用于构建)
- `core/scripts/` — 内核构建(幂等补丁 + 硬校验)与 HAP 统一打包

## 5. 真机排查

```bash
hdc list targets                                                                                 # 先查设备地址
hdc shell "cat /data/app/el2/100/base/com.example.jynxen/haps/entry/files/core/singbox.log"      # 内核日志
hdc shell hilog -x | grep '\[NB\]'                                                               # 应用日志(缓冲易冲掉)
```
错误速查:`permission denied`=沙箱权限点;`no route to host`=防回环;`missing default interface`=monitor(已修复,再现说明补丁丢失);`uTLS is required`=TLS 段缺 utls(已修复);`i/o timeout`=服务器不可达。

## 6. 注意事项(红线)

- **禁止清理**:`~/.hvigor/project_caches/**`、工程根 `.hvigor`、`oh_modules`(hvigor 自举链,清了 pnpm 静默失败,恢复极麻烦)。打包清理只清 `entry/build`(build-hap.sh 已处理)。
- 不要改 `module.json5` 的 VPN type(`"vpn"`)、不要动签名配置(签名用户自理)。
- 每次交付前跑 Notion 第十二章"发布防复发检查清单"(7 条)。
- 版本演进记录在 git log 与 Notion 文档;历史开发会话 `sess_0b799182-b5b4-4610-8759-5e5cd2a89166`(ZCode 可 ReadSessionContext 读取)。
- 新功能开发路线图:以用户当次需求为准(旧"对齐 Android NekoBox"章节仅作参考,对应代码已删)。
=======
# NekoBox for Harmony — Agent 交接说明(必读)

任何 AI Agent 接手本项目前**先完成第 0 节的三项检查**,再开始任何任务。

## 0. 接手检查(第一次对话必须先做)

1. **工程根目录**(所有源码都在这里):
   - Windows 路径:`C:\Users\xiaoli\Downloads\vpn`
   - Git Bash 路径:`/c/Users/xiaoli/Downloads/vpn`
   - 若你在终端/CLI 里运行,先 `cd` 到这个目录再开始。
2. **源码读取方式**:直接用你的文件读写工具按上面的绝对路径访问(Read/Edit/Write 等)。
   - **不存在"挂载调用端工具"、"上传源码"、"隔离容器"这类步骤** —— 读不到文件只说明你自己的工具会话没就绪,请让用户在工程目录下重启你,**绝不要**让用户"重新上传源码"。
3. **源码完整性自验**(10 秒):
   ```bash
   cd /c/Users/xiaoli/Downloads/vpn && git log --oneline -3
   ```
   最新提交应为 `a738972 release(1.5.4-restored) ...`。源码在本地 git + GitHub 双份,永远不会丢。

## 1. 项目是什么

HarmonyOS NEXT 原生 VPN 客户端,参考 [NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid)。

- 内核:**sing-box v1.11.9**(支持 Hysteria2/TUIC v5/vless reality),以 **c-shared .so 进程内 dlopen** 方式运行在 `:vpn` 扩展进程内(沙箱禁止 exec 二进制 —— 旧 README 里"fork 子进程"架构已废弃,勿采信)。
- GitHub: https://github.com/xiaoli8571/NekoBox4Harmony(main 分支;直连失败时 `git -c http.proxy=http://127.0.0.1:7897 push`)
- Notion 开发文档(完整架构/踩坑表/复发复盘):Notion 页面 "NekoBox for Harmony 开发文档",页面 id `3cb716a2-385f-8033-98c6-cf1777bbb876`
- 真机:MatePad mini,HarmonyOS 6.1.1(API 24);hdc 地址会变,先用 `hdc list targets` 查
- 凭据:GitHub 令牌与 Notion API 在 ZCode 持久记忆 `dev-credentials.md`(用户已要求永久存储,**不要再向用户索要**)

## 2. 当前状态(唯一可信基线)

- **main 分支 = v1.5.4**(versionCode 1001605,提交 `a738972`),**用户真机验证完全可用**。
- 交付物:`dist/NekoBox4Harmony-1.5.4-unsigned.hap`(签名由用户在 DevEco 完成)。
- v1.5.4 功能面:多协议(vless/vmess/ss/trojan/hysteria/hysteria2/tuic/wireguard/http/socks)、分享链接与订阅导入、订阅自动更新+流量到期、reality 节点自动 uTLS、日志页终端配色、图标无透明框、连接列表、测速、规则/全局/直连模式、分应用代理。
- **红线**:v1.5.4 之后的 1.5.5/1.5.6/1.6.x 曾引入主页 UI 改版与 selector 多出站架构,已导致断网事故并**被用户否决删除**(GitHub 已强推覆盖)。**不要**从旧会话、旧文档或记忆中恢复那些代码;重做同类功能时必须先读懂 `core/scripts/build-libsingbox-ohos.sh` 里的 OHOS 补丁与 Notion 第十二~十六章的复盘。

### 1.6.x 断网事故教训摘要(防止重蹈覆辙)

1. OHOS Go fork 下 `runtime.GOOS` 返回 `"linux"`,平台判断必须用 `//go:build openharmony` build tag(runtime 判断是死代码)。
2. `SO_BINDTOIFINDEX` 在 HarmonyOS VPN 场景不可靠,**有效的是 `SO_BINDTODEVICE`(按网卡名)** —— sing v0.6.x 已由构建脚本补丁回退到名字绑定。
3. 防回环三保险:`blockedApplications 含自身包名`(主)+ `protectProcessNet()` + `route.default_interface` 绑定;禁用"服务器 IP/32 排除路由"(死路由)。
4. 改内核后 HAP 不会自动带上新 .so —— 必须重跑内核构建脚本**并**全清 `entry/build` 重新 assembleHap。

## 3. 构建方法(唯一流程,命令行,勿开 DevEco GUI)

```bash
cd /c/Users/xiaoli/Downloads/vpn

# 1) 改了内核(core/sing-box-1.11 或 core/libsingbox14)后必须重跑:
bash core/scripts/build-libsingbox-ohos.sh
# 成功标志:含 "wrapper replace: sing -> patched"、三项 "verified ...";产物 entry/libs/arm64-v8a/libsingbox.so

# 2) 打 HAP(统一脚本:自动清 entry/build + 内核新鲜度校验 + strip 感知 md5 校验):
bash core/scripts/build-hap.sh <版本号>     # 例:1.5.5
# 产物: dist/NekoBox4Harmony-<版本号>-unsigned.hap
```

**重要校验认知**:hvigor 打包会对 .so 做 llvm-strip,HAP 内 .so 的 md5 **必然不同于**源 .so —— 这不是缓存问题!校验必须"源先 strip 再比"(build-hap.sh 已内置,勿手工比裸 md5 后误判"打进旧内核")。

## 4. 架构速记

```
UI 进程 EntryAbility/Index/VpnService(操作串行化)
   │ startVpnExtensionAbility(want.parameters.profileId)   ▲ CommonEvent VPN_LOG/VPN_STATUS
:vpn 进程 VpnExtAbility(onRequest 为实际入口)
   vpnConnection.create(VpnConfig) → TUN fd → protectProcessNet() → blockedApplications 含自身
   NAPI dlopen libsingbox.so → CGoSetTunFd(fd) → CGoStartSingBox(config)
   Go 包装层: box.Context(协议注册表) + SING_BOX_TUN_FD 环境变量
   内核日志 → log.output 文件 → UI 日志页直读(1s 增量轮询)
```

关键文件:
- `entry/src/main/ets/vpnext/VpnExtAbility.ets` — VPN 生命周期(防重入、看门狗、queued 重试)
- `entry/src/main/ets/core/ConfigBuilder.ets` — sing-box 1.11 schema 配置生成(1.11 严格 schema:无 block/dns 出站、DNS 劫持用 `{protocol:'dns',action:'hijack-dns'}`、TUN 用 `address` 数组;reality 强制 utls)
- `core/libsingbox14/main.go` — CGo 导出(CGoSetTunFd/CGoStartSingBox/CGoStopSingBox/CGoSingBoxVersion)
- `core/sing-box-1.11/` — 内核源码树(untracked,含 OHOS 补丁;`core/sing-box/` 是 1.4.6 遗留备份,勿用于构建)
- `core/scripts/` — 内核构建(幂等补丁 + 硬校验)与 HAP 统一打包

## 5. 真机排查

```bash
hdc list targets                                                                                 # 先查设备地址
hdc shell "cat /data/app/el2/100/base/com.example.jynxen/haps/entry/files/core/singbox.log"      # 内核日志
hdc shell hilog -x | grep '\[NB\]'                                                               # 应用日志(缓冲易冲掉)
```
错误速查:`permission denied`=沙箱权限点;`no route to host`=防回环;`missing default interface`=monitor(已修复,再现说明补丁丢失);`uTLS is required`=TLS 段缺 utls(已修复);`i/o timeout`=服务器不可达。

## 6. 注意事项(红线)

- **禁止清理**:`~/.hvigor/project_caches/**`、工程根 `.hvigor`、`oh_modules`(hvigor 自举链,清了 pnpm 静默失败,恢复极麻烦)。打包清理只清 `entry/build`(build-hap.sh 已处理)。
- 不要改 `module.json5` 的 VPN type(`"vpn"`)、不要动签名配置(签名用户自理)。
- 每次交付前跑 Notion 第十二章"发布防复发检查清单"(7 条)。
- 版本演进记录在 git log 与 Notion 文档;历史开发会话 `sess_0b799182-b5b4-4610-8759-5e5cd2a89166`(ZCode 可 ReadSessionContext 读取)。
- 新功能开发路线图:以用户当次需求为准(旧"对齐 Android NekoBox"章节仅作参考,对应代码已删)。
>>>>>>> 80696aa (docs: rewrite AGENTS.md/README.md for v1.5.4 baseline (prevent agent onboarding failures: absolute-path checks, no-mounting myth, strip-aware verify, forbidden caches))
