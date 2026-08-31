# NekoBox for Harmony

参考 [NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid) 的 HarmonyOS NEXT 原生 VPN 客户端。
内核 **sing-box v1.11.9**(支持 vless/vmess/ss/trojan/hysteria2/tuic/wireguard 等),以 **c-shared 库(libsingbox.so)进程内 dlopen** 方式运行,不 exec 子进程。

> 当前基线:**v1.5.4**(真机验证可用)。工程细节、构建方法、AI 接手须知见 [AGENTS.md](AGENTS.md)。

## 架构

```
UI 进程 (com.example.jynxen)
  EntryAbility / Index / ProfileEdit / SettingsPage / LogPage / ConnectionsPage
  VpnService(操作串行化 + 看门狗)
        │ startVpnExtensionAbility(want.parameters.profileId)      ▲ CommonEvent(VPN_LOG / VPN_STATUS)
        ▼
:vpn 扩展进程  VpnExtAbility(onRequest 为实际入口)
  vpnConnection.create(VpnConfig) → TUN fd → protectProcessNet() → blockedApplications=[自身]
  NAPI dlopen libsingbox.so → CGoSetTunFd(fd) → CGoStartSingBox(configPath)
  Go 包装层:box.Context(协议注册表) + SING_BOX_TUN_FD 注入 TUN fd
  内核日志 → log.output 文件 → 日志页 1s 增量直读
```

为什么是 c-shared 而不是子进程:HarmonyOS 沙箱禁止应用 exec 自己数据目录的二进制(SEPolicy),因此内核编译为 `GOOS=openharmony` 的 c-shared 库(必须用 OHOS Go fork,原版 Go 产物在 musl 上无法 dlopen),由 NAPI dlopen 进 VPN 扩展进程内运行。构建与补丁见 `core/scripts/`。

## 目录结构

```
vpn/
├── entry/src/main/
│   ├── cpp/napi_init.cpp            # dlopen 内核、CGo 调用、线程安全回调
│   ├── ets/vpnext/                  # VpnExtAbility(VPN 生命周期)
│   ├── ets/core/                    # ConfigBuilder / CoreManager / VpnService / Subscriptions / Backup
│   ├── ets/model/                   # Profile / AppSettings / Store
│   ├── ets/pages/                   # Index / ProfileEdit / SettingsPage / LogPage / ConnectionsPage
│   └── ets/utils/                   # LinkParser / Subscription / GeoAssets / LatencyTester / TrafficStats
├── core/
│   ├── sing-box-1.11/               # sing-box v1.11.9 源码(含 OHOS 补丁,untracked)
│   ├── libsingbox14/                # Go 包装层(CGo 导出)
│   └── scripts/                     # 内核构建脚本 + HAP 统一打包脚本
└── dist/                            # HAP 产物
```

## 构建(命令行)

```bash
# 内核 .so(改内核源码后必须重跑;幂等补丁 + 硬校验)
bash core/scripts/build-libsingbox-ohos.sh

# HAP(自动清缓存 + 内核新鲜度校验 + strip 感知 md5 校验)
bash core/scripts/build-hap.sh <版本号>
```

也可用 DevEco Studio 打开工程构建(签名在 DevEco 配置,产物未签名)。

## 功能

- 协议:vless(reality 自动 uTLS)/vmess/ss/trojan/hysteria/hysteria2/tuic/wireguard/http/socks
- 导入:分享链接(hysteria2://、hy2:// 等)+ 订阅(base64 / Clash YAML)+ 订阅自动更新(流量/到期显示)
- 模式:规则(自定义直连 + GeoIP/GeoSite cn 分流)/ 全局 / 直连;分应用代理;IPv6/MTU/DNS 设置
- 工具:真连接延迟测试、实时速率与累计流量(clash API)、连接列表(单条断开)、实时日志、配置备份恢复

## 已知平台事实(踩坑实证)

- OHOS Go fork 下 `runtime.GOOS == "linux"`,平台判断须用 `//go:build openharmony`
- `SO_BINDTOIFINDEX` 在 HarmonyOS VPN 场景不可靠,须用 `SO_BINDTODEVICE`(按网卡名)
- 防回环三保险:`blockedApplications` 含自身包名 + `protectProcessNet()` + `route.default_interface`
- 详细踩坑表(20+ 条)与发布检查清单见 Notion「NekoBox for Harmony 开发文档」

## 许可

sing-box / NekoBoxForAndroid 为 GPL-3.0,本项目遵循 GPL-3.0。应用图标取自 NekoBoxForAndroid(README 署名)。
