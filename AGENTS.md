# NekoBox for Harmony — Agent 交接说明

任何 AI Agent 接手本项目前必读。代码根目录:`C:\Users\xiaoli\Downloads\vpn`(git 仓库,main 分支)。

## 项目是什么

HarmonyOS NEXT 原生 VPN 客户端,参考 [NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid),内核为 sing-box(当前 v1.11.9,支持 Hysteria2/TUIC v5),以 **c-shared .so 进程内 dlopen** 方式运行(沙箱禁止 exec)。

- GitHub: https://github.com/xiaoli8571/NekoBox4Harmony (推送: `git push origin main`;若直连失败用 `git -c http.proxy=http://127.0.0.1:7897 push`)
- Notion 开发文档(完整架构/踩坑/迭代计划): Notion 页面 "NekoBox for Harmony 开发文档",页面 id `3cb716a2-385f-8033-98c6-cf1777bbb876`
- 真机: MatePad mini,HarmonyOS 6.1.1(API 24),hdc 连接 192.168.3.146:39933
- 凭据: GitHub 令牌与 Notion API 在 ZCode 持久记忆 `dev-credentials.md`(用户已要求永久存储,不要再向用户索要)

## 当前状态(v1.5.3,2026-08-30)

- 断网根因已修复:OHOS 上 netlink interface monitor 拿不到默认网卡 → `notifyInterfaceUpdate(nil)` → `NetworkPause()` 暂停全部出站。修复:`core/sing-box-1.11/route/network.go` 新增 openharmony 早退分支(`auto_detect_interface=false` 时完全不创建 monitor),出站绑定走 `finder.ByName → net.InterfaceByName`(标准库,不依赖 netlink)。
- 日志页固定终端配色(深底浅字 + ERROR/WARN 高亮),不再跟随系统主题。
- 桌面图标已裁掉透明边距铺满画布。
- 交付物:`dist/NekoBox4Harmony-1.5.3-unsigned.hap`(未签名,签名由用户在 DevEco 完成)。
- 提交 `258aa08` 已推送 GitHub。
- 待用户真机验证:规则/全局模式开启 VPN 后设备其余应用可正常上网。

## 构建方法(命令行,勿开 DevEco GUI)

```bash
# 1. 内核 .so(改了 core/sing-box-1.11 或 core/libsingbox14 后必须重跑)
bash core/scripts/build-libsingbox-ohos.sh
# 成功标志:日志含 "wrapper replace: sing-tun -> patched",产物 entry/libs/arm64-v8a/libsingbox.so

# 2. HAP(必须重新打包,旧 HAP 内嵌旧 .so!)
cd /c/Users/xiaoli/Downloads/vpn
DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk' node hvigorw.js --mode module -p product=default assembleHap --no-daemon
# 产物 entry/build/default/outputs/default/entry-default-unsigned.hap,复制到 dist/ 并按版本命名
```

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
- `core/libsingbox14/main.go` — CGo 导出与 TUN fd 注入
- `core/sing-box-1.11/` — 1.11.9 源码(含 OHOS 补丁:route/network.go 早退分支、protocol/tun fd 注入)
- `core/scripts/build-libsingbox-ohos.sh` — 构建脚本(幂等补丁 + replace 校验)

## 真机排查

```bash
hdc shell "cat /data/app/el2/100/base/com.example.jynxen/haps/entry/files/core/singbox.log"   # 内核日志
hdc shell hilog -x | grep '\[NB\]'                                                            # 应用日志(缓冲易冲掉)
```
错误速查:`permission denied`=沙箱权限点;`no route to host`=防回环路由/绑定;`missing default interface`=monitor 问题(应已修复);`i/o timeout`=服务器不可达。

## 注意事项

- 每次改内核源码后:**必须**重跑内核构建脚本 **并** 重新 assembleHap(HAP 里的 .so 不会自动更新,此坑已踩过一次)。
- 版本演进记录在 git log 与 Notion 文档,历史开发会话:`sess_0b799182-b5b4-4610-8759-5e5cd2a89166`(ZCode 会话可用 ReadSessionContext 读取)。
- 不要修改 `module.json5` 的 VPN type(`"vpn"`)、不要重新生成签名配置(签名用户自理)。
- 迭代路线图(对齐 Android NekoBox)在 Notion 文档"迭代计划"章节,按阶段执行。
