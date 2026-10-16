# sing-box 1.11.9 内核(core)

本目录存放 VPN 内核相关内容,参考 NekoBoxForAndroid 的做法:内核与应用解耦。

## 当前架构(进程内 c-shared 库)

内核以 c-shared .so 形式在 :vpn 扩展进程内 dlopen 运行(沙箱禁止 exec)。
**v1.5.x 起,内核为仓库自带源码 `core/sing-box-1.11/`(sing-box v1.11.9 + OHOS 补丁),
克隆仓库即可构建,无需另找源码。**

```
core/libsingbox14/          Go 包装层(//export CGoStartSingBox/CGoStopSingBox/CGoSetTunFd/CGoSingBoxVersion)
core/sing-box-1.11/         sing-box v1.11.9 源码(含 OHOS 补丁,随仓库分发)
core/patches/               历史补丁 + zz-ohos/(fallback 安装源)
core/scripts/build-ohos-toolchain.sh    一次性构建 OHOS Go fork(openharmony-sig/ohos_golang_go,go1.24 分支)
core/scripts/build-libsingbox-ohos.sh   交叉编译 libsingbox.so → entry/libs/arm64-v8a/
```

### sing-box-1.11 内的 OHOS 补丁(脚本幂等校验,缺一 fail-closed)

1. `protocol/tun/inbound.go` — TUN fd 注入:扩展进程把 vpnExtension 的 fd 经
   `SING_BOX_TUN_FD` 环境变量交给 sing-tun(显式非法值报错)。
2. `route/network.go` + `route/zz_ohos_*.go` — netlink monitor 早退:
   OHOS 沙箱里 netlink 订阅必失败;`auto_detect_interface=false` 时不创建 monitor。
   平台判断用 `isOpenHarmonyRuntime` build tag 常量(OHOS Go fork 的
   `runtime.GOOS` 返回 "linux",不能靠 runtime 判断)。
3. `common/dialer/default.go` + `common/dialer/zz_ohos_forcebind*.go` — 防回环
   内核级保险:出站 socket 强制 SO_BINDTODEVICE 到 `SING_BOX_BIND_IFNAME`
   指定的物理网卡。**休眠钩子**,当前无代码设置该环境变量;实际防回环走
   `route.default_interface`(设置页实验选项)。
4. sing-tun 模块缓存补丁(netlink 订阅改 best-effort + openharmony 默认接口检查禁用):
   由构建脚本在 `core/build/libsingbox-ohos/sing-tun-patched/` 生成副本,
   经 wrapper go.mod 的 replace 生效,不修改仓库源码。

## 为什么必须用 OHOS Go fork

HarmonyOS 是 musl libc。原版 Go 的 c-shared 产物(无论 GOOS=linux 还是 android)
在 musl 下 dlopen 失败,或外来线程(arkts)调 cgo 时 SIGSEGV——goroutine 的 TLS
存储方式决定的。官方 fork(`openharmony-sig/ohos_golang_go`,分支 go1.24)为 arm64
补了 TLSDESC,是唯一可行的编法。工具链默认装在 `~/ohos-go-build/ohos_golang_go`。

## 构建

```bash
bash core/scripts/build-ohos-toolchain.sh    # 一次性,约 5-10 分钟
bash core/scripts/build-libsingbox-ohos.sh   # 每次改内核/包装层后;仓库源码已带补丁则全部跳过
DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk' \
PATH="/c/Program Files/Huawei/DevEco Studio/jbr/bin:$PATH" \
node hvigorw.js --mode module -p product=default assembleHap --no-daemon
```

产物 `libsingbox.so` 由 CMake/hvigor 随 HAP 打包(位于 entry/libs/arm64-v8a/)。
注意:PackageHap 需要命令行有 java(用 DevEco 自带 JBR 加 PATH 即可),否则报
`spawn java ENOENT`(00308018)。

## 升级实验(未启用)

sing-box 1.13.12 / 1.14 的升级实验源码不在仓库内(曾以坏 gitlink 入库,已移除);
本机 `C:\Users\Administrator\Downloads\NekoBox\core\` 下留有实验副本,勿当作发布内核。
