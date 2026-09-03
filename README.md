# NekoBox for Harmony(HarmonyOS 原生 VPN 客户端)

参考 [NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid) 架构思路、基于 **sing-box v1.11.9**(含 OHOS 补丁)内核的 HarmonyOS NEXT(Stage 模型)VPN 客户端。内核以 **c-shared .so 进程内 dlopen** 方式运行(沙箱禁止 exec 二进制),支持 Hysteria2 / TUIC v5 等协议。

> ✅ **克隆即可构建**:成品内核 `entry/libs/arm64-v8a/libsingbox.so` 随仓库分发,`build-profile.json5` 为无签名配置(`signingConfigs: []`),克隆后直接构建即得未签名 HAP,零额外步骤。`hvigorw.js` 已内置补丁,修复 Node ≥ 18.20 下 `.cmd` 子进程 EINVAL 问题。

## 下载

前往 [Releases](https://github.com/xiaoli8571/NekoBox4Harmony/releases) 下载未签名 HAP(如 `NekoBox4Harmony-1.5.7-unsigned.hap`),在 DevEco Studio 中签名后安装(签名由用户自理)。

## 功能特性(v1.5.7)

- **协议**:ss / vmess / vless / trojan / **hysteria2** / **tuic v5**;分享链接导入、HTTP(S) 订阅、Clash YAML 订阅兼容
- **节点**:分组管理与首页分组显示、批量延迟测试(结果保存并按延迟着色)、编辑页实时校验(服务器/端口/UUID/凭据/REALITY)
- **分流**:规则 / 全局 / 直连模式;自定义域名 / IP CIDR / GeoIP / GeoSite 规则;per-app 包含 / 排除(手输包名)
- **订阅**:更新间隔与到期元数据、应用启动时自动更新到期订阅、流量配额与到期时间展示
- **备份**:schema v3(设置、节点、分组、订阅、分流规则),剪贴板导入导出
- **外观**:跟随系统 / 浅色 / 深色(深色主题资源全量接入、切换即时生效)、触感反馈、液态玻璃偏好
- **日志**:独立日志页,固定终端配色(深底浅字 + ERROR/WARN 高亮),内核日志实时可见
- **DNS / 路由安全**:DNS 劫持防泄漏、防路由回环排除路由(见技术要点)

路线图见 `DEVPLAN.md`(F2~F6:通知栏延迟与断开按钮、订阅后台定时更新、per-app 图形选择器、备份文件化、中英双语)。

## 从源码构建

环境:Windows + [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)(含 SDK)。**无需 Go** —— 内核已冻结为成品 .so 入库。

```bash
git clone https://github.com/xiaoli8571/NekoBox4Harmony.git
cd NekoBox4Harmony

# java 需在 PATH(DevEco 自带 JBR),然后命令行构建(勿开 GUI)
export PATH="/c/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH"
DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk' \
  node hvigorw.js --mode module -p product=default assembleHap --no-daemon
# 产物:entry/build/default/outputs/default/entry-default-unsigned.hap
```

如需自行编译内核(仅当修改 `core/sing-box-1.11` 或 `core/libsingbox14` 时):

```bash
bash core/scripts/build-libsingbox-ohos.sh
# 成功标志:日志含 "wrapper replace: sing-tun -> patched",产物 entry/libs/arm64-v8a/libsingbox.so
```

注意:改内核源码后**必须**重跑内核构建脚本**并**重新 assembleHap(HAP 内嵌的 .so 不会自动更新)。

## 架构总览

```
UI 进程 EntryAbility / Index / VpnService(操作串行化)
   │ startVpnExtensionAbility(want.parameters.profileId)      ▲ CommonEvent VPN_LOG / VPN_STATUS
:vpn 进程 VpnExtAbility(onRequest 为实际入口)
   vpnConnection.create(VpnConfig) → TUN fd → protectProcessNet()
   NAPI dlopen libsingbox.so → CGoSetTunFd(fd) → CGoStartSingBox(config)
   Go 包装层: box.Context(注册表) + SING_BOX_TUN_FD 环境变量
```

与 NekoBoxForAndroid 的对应关系:

| NekoBoxForAndroid | 本项目 |
|---|---|
| VpnService / VpnService.Builder | `@ohos.net.vpnExtension`(VpnExtAbility) |
| sing-box / libbox 内核插件 | sing-box 1.11.9 c-shared .so(进程内 dlopen) |
| 插件进程 fd / protect 处理 | TUN fd 经 CGo 注入 + `protectProcessNet()` |
| Protocol / Profile 配置层 | `ets/model/Profile.ets` + `ets/core/ConfigBuilder.ets` |
| 分享链接 / 订阅导入 | `ets/utils/LinkParser.ets`(ss/vmess/vless/trojan/hysteria2/tuic/订阅) |
| 配置生成(路由规则 / DNS) | `ConfigBuilder.buildCoreConfig()` |

关键文件:

- `entry/src/main/ets/vpnext/VpnExtAbility.ets` — VPN 生命周期(防重入、看门狗)
- `entry/src/main/ets/core/ConfigBuilder.ets` — sing-box 1.11 schema 配置生成(规则/全局/直连、DNS 劫持、geo 分流、per-app)
- `core/libsingbox14/main.go` — CGo 导出与 TUN fd 注入
- `core/sing-box-1.11/` — sing-box 1.11.9 源码(OHOS 补丁:`route/network.go` 早退分支、`protocol/tun` fd 注入)
- `core/scripts/build-libsingbox-ohos.sh` — 内核构建脚本(幂等补丁 + replace 校验)

## 技术要点(为什么这样做)

1. **内核以 c-shared .so 进程内运行**:HarmonyOS 沙箱 SEPolicy 禁止 exec 二进制,因此不走 NekoBox 的插件子进程方案,而是把 sing-box 编为 `c-shared` .so 由 NAPI `dlopen`;TUN fd 通过 `CGoSetTunFd` 注入,`SING_BOX_TUN_FD` 环境变量让 sing-tun 直接使用该 fd(sing-tun 对非零 FileDescriptor 本来就是"直接使用、跳过 netlink 配置")。
2. **OHOS 网络监视器补丁**:OHOS 上 netlink interface monitor 拿不到默认网卡,会触发 `notifyInterfaceUpdate(nil)` → `NetworkPause()` 暂停全部出站(断网根因)。`route/network.go` 增加 openharmony 早退分支(`auto_detect_interface=false` 时不创建 monitor),出站绑定改走标准库 `net.InterfaceByName`。
3. **防路由回环**:VPN 建立 0.0.0.0/0 → TUN 默认路由后,内核到代理服务器的连接会被再次吸入 TUN 形成回环。VpnConfig 为服务器 IP(域名先解析)与直连 DNS IP 添加 `/32` 排除路由指向物理网卡。
4. **防 DNS 泄漏**:系统 DNS 指向 remote(经代理的 DoH),TUN 入站开启 sniff,DNS 请求被 `protocol: dns → dns-out` 规则劫持后经代理解析;仅代理服务器自身域名的解析走直连 DNS(排除路由)。

## 已知限制 / 注意事项

- 模拟器不支持 VPN 扩展,必须真机(开发验证环境:MatePad mini,HarmonyOS 6.1.1 / API 24)
- 未签名 HAP 需自行在 DevEco Studio 签名;不要修改 `module.json5` 的 `"type": "vpn"`
- 部分页面文案仍为中文(国际化收尾在路线图 F6)
- 主题切换在个别页面可能仍需重进刷新(真机验收项)

## 开发文档

- `AGENTS.md` — 项目交接说明(架构、构建、踩坑、真机排查)
- `HANDOFF.md` — 当前开发工作流(开发工作区与构建机分工)
- `DEVPLAN.md` — 迭代计划与各项状态
- `CHANGES.md` — 各轮实现记录与已知限制

## 许可

sing-box 为 GPL-3.0,本项目遵循 GPL-3.0。`art/nekobox_icon.png`(应用图标)取自 [NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid),遵循其 GPL-3.0 许可,版权归 NekoBoxForAndroid 原作者所有。
