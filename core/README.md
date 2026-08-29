# sing-box 1.4 内核(core)

本目录存放 VPN 内核相关内容,参考 NekoBoxForAndroid 的做法:内核与应用解耦。

## 当前架构(进程内 c-shared 库)

**v1.1.0 起,内核不再以子进程运行**(SELinux 禁止应用沙箱 exec 数据目录二进制,
真机实测 exit code 127),改为参考 [Hey](https://github.com/xiaoli8571/Hey) 的方案:

```
core/libsingbox14/         Go 包装层(//export CGoStartSingBox 等 4 个符号)
core/sing-box/             sing-box v1.4.6 + TUN fd 注入补丁
core/patches/              TUN fd 补丁(sing-tun FileDescriptor)
core/scripts/build-ohos-toolchain.sh   一次性构建 OHOS Go fork(go1.24.5 + openharmony/arm64)
core/scripts/build-libsingbox-ohos.sh  交叉编译 libsingbox.so → entry/libs/arm64-v8a/
```

数据流:`VpnExtAbility`(独立 :vpn 进程)通过 vpnExtension 拿到 TUN fd →
NAPI `dlopen("libsingbox.so")` → `CGoSetTunFd(fd)` + `CGoStartSingBox(config路径)` →
包装层设置 `SING_BOX_TUN_FD` 环境变量后 `box.New()`(补丁让 sing-tun 直接使用该 fd)。
内核日志经配置 `log.output` 写文件,由扩展轮询后用 CommonEvent 转发到 UI 进程。

## 为什么必须用 OHOS Go fork

HarmonyOS 是 musl libc。原版 Go 的 c-shared 产物(无论 GOOS=linux 还是 android)
在 musl 下 dlopen 失败,或外来线程(arkts)调 cgo 时 SIGSEGV——goroutine 的 TLS
存储方式决定的。官方 fork(`openharmony-sig/ohos_golang_go`,分支 go1.24)为 arm64
补了 TLSDESC,是唯一可行的编法。工具链默认装在 `~/ohos-go-build/ohos_golang_go`。

## 构建

```bash
bash core/scripts/build-ohos-toolchain.sh    # 一次性,约 5-10 分钟
bash core/scripts/build-libsingbox-ohos.sh   # 每次改内核/包装层后
```

产物 `libsingbox.so` 由 CMake/hvigor 随 HAP 打包(位于 entry/libs/arm64-v8a/)。

已知取舍:go1.24 fork 下,1.4 时代的 sagernet/quic-go 可能因 qtls 构建约束拒绝
编译(脚本默认带 with_quic,失败时去掉该 tag 重试)——只影响 TUIC/Hysteria
(QUIC 协议),vless/vmess/ss/trojan 不受影响。

## 旧的子进程方案(已废弃)

`dist/` 下可能残留的 linux/arm64 静态二进制仅供桌面参考;应用已不再使用 exec 方式。
