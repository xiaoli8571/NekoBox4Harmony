# NekoBox for Harmony(鸿蒙 sing-box 1.4 VPN 客户端)

一个参考 [NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid)
架构思路、基于 **sing-box v1.4.6** 内核的 HarmonyOS(Stage 模型,API 12+)VPN 客户端。
全部代码与资料都在本目录,可直接用 DevEco Studio 打开。

## 架构总览

```
┌─────────────────────────── 应用进程(沙箱) ───────────────────────────┐
│                                                                      │
│  EntryAbility (UI)               VpnExtAbility (vpnExtension)        │
│   ├─ pages/Index.ets             ├─ vpnExtension.createVpnConnection │
│   ├─ pages/ProfileEdit.ets       ├─ vpnConnection.create(config) → fd│
│   ├─ pages/SettingsPage.ets      ├─ 生成 sing-box 配置 (ConfigBuilder)│
│   └─ pages/LogPage.ets           └─ napi startCore(binary, cfg, fd)  │
│                                                                      │
│  libentry.so (C++ NAPI)                                              │
│   └─ fork + execl(sing-box run -c config.json)                       │
│       子进程继承 TUN fd + SING_BOX_TUN_FD 环境变量                     │
│                                                                      │
│  sing-box 1.4.6 子进程(linux/arm64 静态二进制, GOOS=linux)           │
│   └─ 补丁: tun inbound 优先使用 SING_BOX_TUN_FD 指定的 TUN 设备        │
└──────────────────────────────────────────────────────────────────────┘
```

与 NekoBoxForAndroid 的对应关系:

| NekoBoxForAndroid | 本项目 |
|---|---|
| VpnService / VpnService.Builder | `@ohos.net.vpnExtension`(VpnExtAbility) |
| sing-box / libbox 内核插件 | sing-box 1.4.6 静态二进制(子进程) |
| 插件进程 fd/protect 处理 | TUN fd 经 fork 继承 + 环境变量注入(内核补丁) |
| Protocol/Profile 配置层 | `ets/model/Profile.ets` + `ets/core/ConfigBuilder.ets` |
| 分享链接/订阅导入 | `ets/utils/LinkParser.ets`(ss/vmess/vless/trojan/hysteria/tuic/订阅) |
| 配置生成(链式/分片/路由规则) | `ConfigBuilder.buildCoreConfig()` |

## 目录结构

```
vpn/
├── AppScope/                    应用级配置
├── entry/                       主模块
│   └── src/main/
│       ├── cpp/                 NAPI 原生桥(napi_init.cpp)
│       ├── ets/
│       │   ├── entryability/    UI 入口
│       │   ├── vpnext/          VpnExtensionAbility(核心生命周期)
│       │   ├── core/            ConfigBuilder / CoreManager / VpnService
│       │   ├── model/           Profile / Settings / Store
│       │   ├── utils/           LinkParser(分享链接解析)
│       │   └── pages/           Index / ProfileEdit / SettingsPage / LogPage
│       └── resources/
│           └── rawfile/         ← build-core.sh 产物放这里(自动)
├── core/                        内核:sing-box 源码 + 补丁 + 构建脚本
│   ├── patches/001-tun-fd-env.patch
│   ├── scripts/build-core.sh
│   └── sing-box/                浅克隆的 v1.4.6(已应用补丁)
└── build-profile.json5 等
```

## 快速开始

### 1. 编译内核(一次性)

需要 Git 和 Go(本机已有 go1.26.5;脚本会通过 `GOTOOLCHAIN` 自动使用 go1.21.13,
因为 1.4 时代的 quic-go 编译器版本守卫拒绝过新的 Go):

```bash
cd C:\Users\xiaoli\Downloads\vpn
bash core/scripts/build-core.sh
```

产物 `sing-box-arm64` 会被自动复制到 `entry/src/main/resources/rawfile/`。

### 2. DevEco Studio 构建运行

1. 打开 DevEco Studio → File → Open → 选择 `C:\Users\xiaoli\Downloads\vpn`;
2. 等待 hvigor 同步完成(如提示 hvigor/SDK 版本不一致,按提示自动升级即可);
3. File → Project Structure → Signing Configs 勾选自动签名(需登录华为账号);
4. 连接真机(API 12+ 的 HarmonyOS 手机/平板)→ Run。
   **模拟器不支持 VPN 扩展,必须真机。**

### 3. 使用

主页 → 「新建节点」或「导入链接」→ 选中节点 → 「启动 VPN」
(系统会弹出 VPN 授权对话框)→ 「日志」页可看 sing-box 输出。

导入说明:
- **导入链接**(主页):支持 ss://、vmess://、vless://、trojan://、hysteria://、
  tuic:// 分享链接与 base64 订阅内容;也支持直接粘贴 **HTTP(S) 订阅 URL**
  (会自动下载再解析;服务商返回 Clash YAML 时自动按 Clash 解析,
  UA 伪装 v2rayNG 以获取通用格式)。hysteria2 会跳过(内核 1.4 不支持)。
- **粘贴节点链接**(编辑页顶部按钮):把单条 vless:// 等链接直接解析进表单,
  核对后保存。

## 技术要点(为什么要这样做)

1. **内核以 `GOOS=linux` 静态编译而非 `GOOS=ohos`**:官方 Go(含 1.26)
   尚无 ohos 目标,社区移植需要给 sing/sing-tun/gvisor/quic-go 全部依赖打
   构建标签补丁。CGO 关闭后的 Go 二进制是纯静态、直接走 Linux 系统调用的,
   而 OpenHarmony 内核就是 Linux 内核,可以直接在应用沙箱中运行——
   这正是 NekoBox 各协议插件的运行方式。
2. **TUN fd 注入**:应用沙箱无权打开 `/dev/net/tun`,TUN 只能由系统通过
   `@ohos.net.vpnExtension` 创建。`vpnConnection.create()` 返回 fd 后,
   NAPI fork 出的子进程自动继承该 fd,编号通过 `SING_BOX_TUN_FD` 环境变量
   传给内核;`core/patches/001-tun-fd-env.patch` 让 sing-tun 直接使用该 fd
   (sing-tun 对非零 `FileDescriptor` 本来就是"直接使用、跳过 netlink 配置")。
3. **防路由回环**:VPN 建立 0.0.0.0/0 → TUN 默认路由后,内核到代理服务器的
   连接会被再次吸入 TUN 形成回环。本项目在 VpnConfig 中为服务器 IP(域名会
   先解析)和直连 DNS IP 添加 `/32` 排除路由指向物理网卡;设置页另提供
   实验性的 `route.default_interface` 绑定。
4. **防 DNS 泄漏**:系统 DNS 指向 remote(经代理的 DoH),TUN 入站开启
   sniff,DNS 请求被 `protocol: dns → dns-out` 规则劫持后经代理解析;
   仅代理服务器自身域名的解析走直连 DNS(排除路由)。

## 已知限制 / 注意事项

- **协议**:sing-box 1.4 不含 hysteria2/anytls(1.6+ 才有)。UI 识别到
  hysteria2 链接会明确报错。如需支持,可 `SINGBOX_TAG=v1.6.x` 重建内核,
  但需同步调整 `ConfigBuilder` 的字段名。
- **`MANAGE_VPN` 权限**:module.json5 已注释预留。若真机上创建 VPN 被拒,
  按你 SDK 版本的文档补上该权限(可能属于受限 ACL,需 AGC 申请)。
- **沙箱执行权限**:少数系统版本可能禁止应用沙箱内 exec 二进制(SEPolicy)。
  若日志出现 "core binary is not executable",需改用 HNP(Harmony Native
  Package)方式打包内核二进制,详见 `docs/NOTES.md`。
- **module.json5 的 extension type**:不同 SDK 版本接受 `vpnExtension`
  (HarmonyOS NEXT)或 `vpn`(OpenHarmony),编译报错时二选一。
- 本项目为工程骨架 + 完整可用实现,在真机上的联调(尤其 VPN 授权、排除路由
  生效情况)需要你按 `docs/NOTES.md` 的排查清单逐项确认。
- 许可:sing-box 为 GPL-3.0,本项目遵循 GPL-3.0。

## 后续可做(对照 NekoBox 的路线)

- 常驻通知(ConnectButton + 状态面板)、Clash API 面板(内核已带 with_clash_api)
- 分组/订阅自动更新、测速与 URL Test
- 更多协议插件二进制(hysteria2、naive、shadowtls 链式)
- via `protect()` 通道替换排除路由方案(需给内核加 fd 上报协议)

## 素材署名

`art/nekobox_icon.png`(应用图标)取自
[NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid)
`app/src/main/res/mipmap-xxxhdpi/ic_launcher.png`,遵循其 GPL-3.0 许可,
版权归 NekoBoxForAndroid 原作者所有。
