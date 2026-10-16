# 真机联调与排查笔记

## 1. 启动前检查

- [ ] `core/scripts/build-core.sh` 已运行成功,`entry/src/main/resources/rawfile/`
      下存在 `sing-box-arm64`(约 20~30 MB)。
- [ ] DevEco 已签名(自动签名即可),真机 API 版本 ≥ 12。
- [ ] 首次启动点「启动 VPN」时系统会弹 VPN 授权框;拒绝后扩展会自行退出。

## 2. 日志页怎么看

日志 = `[app]`(UI 进程)+ `[vpn]`(VpnExtensionAbility)+ sing-box 原始输出。

典型成功序列:

```
[vpn] VpnExtensionAbility onConnect
[vpn] 物理网卡: wlan0
[vpn] 排除路由: x.x.x.x/32 -> wlan0
[vpn] sing-box 配置已写入 /data/app/.../files/core/config.json
[vpn] TUN fd = N
INFO[0000] sing-box started (1.4.6-ohos)
INFO[0000] inbound/tun[tun-in]: using platform tun file descriptor N
INFO[0000] inbound/tun[tun-in]: started at xxx
```

## 3. 常见失败

| 现象 | 原因 / 处理 |
|---|---|
| `rawfile 中找不到内核` | 没跑 build-core.sh |
| `core binary is not executable` | SEPolicy 禁止沙箱 exec。改用 HNP 打包:在 DevEco 的 `entry/hnp` 目录放 `hnp.cfg` + 二进制(参考华为 HNP 文档),或向设备厂商确认应用域 SELinux 策略 |
| `startVpnExtensionAbility 失败` | extension type 写错(试 `vpn` / `vpnExtension`),或缺 VPN 相关权限(module.json5 中取消 MANAGE_VPN 注释) |
| `create() 返回值不是数字` | 你的 SDK 中 `vpnConnection.create()` 签名不同,按 SDK d.ts 修正 VpnExtAbility.ets 中取 fd 的代码 |
| 内核日志 `configure tun interface` 报错 | TUN fd 注入失败:确认是打了补丁的内核;确认 `SING_BOX_TUN_FD` 生效(补丁日志 `using platform tun file descriptor`) |
| 能连上但全部超时 | 排除路由未生效:看日志有没有 `排除路由`;尝试设置页打开「绑定物理网卡」;用 `hdc shell` + `cat /proc/net/route` 核对 |
| DNS 全部超时 | remoteDns 主机必须是 IP;直连 DNS 的 IP 必须能被解析并加入排除路由 |
| quic-go "unsupported Go version" | 构建脚本默认 GOTOOLCHAIN=go1.21.13 会自动下载,若被网络挡住,手动 `go install golang.org/dl/go1.21.13@latest` |

## 4. 手动验证内核二进制(可选)

把 dist 产物推到任一 Linux arm64 环境(或 WSL 的 qemu)执行:

```bash
./sing-box-arm64 version   # 应输出 1.4.6-ohos
```

## 5. 配置文件长什么样

`ConfigBuilder.buildCoreConfig()` 生成的配置可以在启动失败时从日志页复制,
或到设备 `files/core/config.json` 用 hdc 取出,交给 `sing-box check -c` 校验
(桌面版同版本内核)。
