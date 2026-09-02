#!/usr/bin/env bash
# 把 sing-box 内核编译成 HarmonyOS c-shared 库 libsingbox.so。
#
# 默认:仓库自带源码 core/sing-box-1.11(v1.11.9 + OHOS 补丁,随仓库分发,克隆后直接可建)。
#       SINGBOX_SRC 也可指向上游裸源码目录,脚本会幂等补齐全部 OHOS 补丁:
#         1) protocol/tun/inbound.go   TUN fd 注入(SING_BOX_TUN_FD)
#         2) route/network.go          netlink monitor 早退(isOpenHarmonyRuntime)
#         3) common/dialer/default.go  防回环 forcebind 挂接(SING_BOX_BIND_IFNAME,休眠钩子)
#         4) zz_ohos_*.go(×4)          补丁 2/3 的平台常量与钩子实现(openharmony build tag 隔离)
# 回退:v1.4.6(SINGBOX_TAG=v1.4.6 SINGBOX_SRC="$ROOT/sing-box" 调用)
#
# 必须用 OHOS Go fork + GOOS=openharmony(原版 Go 产物在 musl 上不可用)。
# 产物: entry/libs/arm64-v8a/libsingbox.so
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"        # NekoBox4Harmony/core
PROJECT="$(cd "$ROOT/.." && pwd)"               # NekoBox4Harmony/

SINGBOX_TAG="${SINGBOX_TAG:-v1.11.9}"
SINGBOX_SRC="${SINGBOX_SRC:-$ROOT/sing-box-1.11}"
WRAPPER="$ROOT/libsingbox14"
OUT_DIR="$PROJECT/entry/libs/arm64-v8a"
WORK_DIR="$ROOT/build/libsingbox-ohos"

OHOS_GO_FORK="${OHOS_GO_FORK:-$HOME/ohos-go-build/ohos_golang_go}"

# Go 模块代理兜底:默认 goproxy.cn(国内可达);用户可用环境变量覆盖
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

# ---- 定位 OHOS clang ----
for cand in \
    "/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native" \
    "$LOCALAPPDATA/Huawei/Sdk/default/openharmony/native"; do
    if [ -d "$cand" ]; then SDK_NATIVE="$cand"; break; fi
done
echo "==> SDK native: $SDK_NATIVE"

CC_BIN=""
for n in ohos-clang.bat aarch64-unknown-linux-ohos-clang.exe; do
    if [ -f "$SDK_NATIVE/llvm/bin/$n" ]; then CC_BIN="$SDK_NATIVE/llvm/bin/$n"; break; fi
done
if [ -z "$CC_BIN" ] && [ -f "$SDK_NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang" ]; then
    CLANG_SH="$SDK_NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang"
    if head -c 20 "$CLANG_SH" | grep -q "#!/bin/sh"; then
        printf '@echo off\r\n"%%~dp0clang.exe" -target aarch64-linux-ohos --sysroot=%%~dp0..\..\sysroot -D__MUSL__ %%*\r\n' > "$SDK_NATIVE/llvm/bin/ohos-clang.bat"
        printf '@echo off\r\n"%%~dp0clang++.exe" -target aarch64-linux-ohos --sysroot=%%~dp0..\..\sysroot -D__MUSL__ %%*\r\n' > "$SDK_NATIVE/llvm/bin/ohos-clang++.bat"
        CC_BIN="$SDK_NATIVE/llvm/bin/ohos-clang.bat"
        echo "==> generated ohos-clang.bat wrapper"
    fi
fi
[ -z "$CC_BIN" ] && { echo "ERROR: no aarch64-unknown-linux-ohos-clang found" >&2; exit 1; }
if echo "$CC_BIN" | grep -q " "; then
    SHORT="$(cygpath -d "$CC_BIN" 2>/dev/null || true)"
    [ -n "$SHORT" ] && CC_BIN="$SHORT"
fi
echo "==> CC: $CC_BIN"

# ---- fork 工具链 ----
if [ -x "$OHOS_GO_FORK/bin/go" ] || [ -f "$OHOS_GO_FORK/bin/go.exe" ]; then
    echo "==> OHOS Go fork: $OHOS_GO_FORK"
else
    echo "ERROR: OHOS Go fork not found ($OHOS_GO_FORK). Run: bash core/scripts/build-ohos-toolchain.sh" >&2
    exit 1
fi

# ---- 内核源码(仓库自带;缺失时回退上游 clone)+ OHOS 补丁(幂等) ----
if [ ! -f "$SINGBOX_SRC/go.mod" ]; then
    if [ -d "$SINGBOX_SRC" ] && [ -n "$(ls -A "$SINGBOX_SRC" 2>/dev/null)" ]; then
        echo "ERROR: $SINGBOX_SRC 已存在但没有 go.mod;删除该目录或用 SINGBOX_SRC 指向有效源码" >&2
        exit 1
    fi
    git clone --depth 1 --branch "$SINGBOX_TAG" \
        https://github.com/SagerNet/sing-box.git "$SINGBOX_SRC"
fi
cd "$SINGBOX_SRC"
if [ -d .git ]; then
    git config core.autocrlf false
fi

# 补丁 1:TUN fd 注入 —— 扩展进程把 vpnExtension 的 fd 经环境变量交给 sing-tun
if [ -f "protocol/tun/inbound.go" ]; then
    if ! grep -q "SING_BOX_TUN_FD" protocol/tun/inbound.go; then
        perl -0pi -e 's/(\t\tmonitor := taskmonitor\.New\(t\.logger, C\.StartTimeout\)\n)/$1\t\tif t.tunOptions.FileDescriptor == 0 {\n\t\t\tif fdStr := os.Getenv("SING_BOX_TUN_FD"); fdStr != "" {\n\t\t\t\tfd, fdErr := strconv.Atoi(fdStr)\n\t\t\t\tif fdErr != nil || fd <= 0 {\n\t\t\t\t\treturn E.New("invalid SING_BOX_TUN_FD: ", fdStr)\n\t\t\t\t}\n\t\t\t\tt.tunOptions.FileDescriptor = fd\n\t\t\t}\n\t\t}\n/' protocol/tun/inbound.go
        echo "==> 1.11 tun-fd patch applied"
    fi
    FD_ENV_LINE="$(grep -n 'fdStr := os.Getenv("SING_BOX_TUN_FD")' protocol/tun/inbound.go | cut -d: -f1)"
    FD_COPY_LINE="$(grep -n 'tunOptions := t.tunOptions' protocol/tun/inbound.go | cut -d: -f1)"
    TUN_NEW_LINE="$(grep -n 'tunInterface, err = tun.New(tunOptions)' protocol/tun/inbound.go | cut -d: -f1)"
    if [ -z "$FD_ENV_LINE" ] || [ -z "$FD_COPY_LINE" ] || [ -z "$TUN_NEW_LINE" ] || [ "$FD_ENV_LINE" -ge "$FD_COPY_LINE" ] || [ "$FD_COPY_LINE" -ge "$TUN_NEW_LINE" ]; then
        echo "ERROR: tun fd injection must precede tunOptions copy and tun.New()" >&2
        exit 1
    fi
    if ! grep -q 'invalid SING_BOX_TUN_FD' protocol/tun/inbound.go; then
        echo "ERROR: invalid explicit SING_BOX_TUN_FD must fail closed" >&2
        exit 1
    fi
    echo "==> verified tun fd injection precedes tunOptions copy and tun.New()"
elif [ -f "inbound/tun.go" ]; then
    if ! grep -q "SING_BOX_TUN_FD" inbound/tun.go; then
        perl -0pi -e 's/(\tif t\.tunOptions\.Name == "" \{\n\t\tt\.tunOptions\.Name = tun\.CalculateInterfaceName\(""\)\n\t\}\n)/$1\tif t.tunOptions.FileDescriptor == 0 {\n\t\tif fdStr := os.Getenv("SING_BOX_TUN_FD"); fdStr != "" {\n\t\t\tif fd, fdErr := strconv.Atoi(fdStr); fdErr == nil && fd > 0 {\n\t\t\t\tt.tunOptions.FileDescriptor = fd\n\t\t\t\tif tunName := os.Getenv("SING_BOX_TUN_NAME"); tunName != "" {\n\t\t\t\t\tt.tunOptions.Name = tunName\n\t\t\t\t}\n\t\t\t\tt.logger.Info("using platform tun file descriptor ", fd)\n\t\t\t}\n\t\t}\n\t}\n/' inbound/tun.go
        echo "==> 1.4 tun-fd patch applied"
    fi
else
    echo "ERROR: unknown sing-box layout: $SINGBOX_SRC" >&2
    exit 1
fi

# 补丁 2:netlink monitor 早退 —— OHOS 沙箱里 netlink 订阅必失败,
# 不显式要求 auto_detect_interface 时直接跳过 monitor 创建(平台判断用 build tag,
# 因为 OHOS Go fork 的 runtime.GOOS 返回 "linux")
if [ -f route/network.go ] && ! grep -q "isOpenHarmonyRuntime" route/network.go; then
    perl -0pi -e 's/\tif !usePlatformDefaultInterfaceMonitor \{\n/\tif !usePlatformDefaultInterfaceMonitor \{\n\t\t\/\/ OHOS Go fork 的 runtime.GOOS 实际返回 "linux",不能用 runtime 判断平台,\n\t\t\/\/ 必须用 openharmony build tag 常量(否则 netlink monitor 在沙箱里必然失败)\n\t\tif isOpenHarmonyRuntime \&\& !enforceInterfaceMonitor \{\n\t\t\treturn nm, nil\n\t\t\}\n/' route/network.go
    echo "==> route/network.go openharmony early-return patch applied"
fi

# 补丁 3+4:出站 socket 强制绑定物理网卡(内核级防回环保险,休眠钩子:
# 仅当扩展侧注入 SING_BOX_BIND_IFNAME 时生效;已显式绑定的不覆盖)
for f in common/dialer/zz_ohos_forcebind.go common/dialer/zz_ohos_forcebind_other.go \
         route/zz_ohos_openharmony.go route/zz_ohos_other.go; do
    if [ ! -f "$f" ]; then
        cp "$ROOT/patches/zz-ohos/$f" "$f"
        echo "==> installed $f"
    fi
done
if [ -f common/dialer/default.go ] && ! grep -q "ohosForceBindFunc" common/dialer/default.go; then
    perl -0pi -e 's/\treturn &DefaultDialer\{\n/\t\/\/ OpenHarmony 防回环兜底:仍未绑定任何接口时,强制 SO_BINDTODEVICE 到物理网卡\n\t\/\/ (SING_BOX_BIND_IFNAME 由扩展侧注入)。已显式绑定的(bind_interface\/default_interface)不覆盖。\n\tforceBind := ohosForceBindFunc(options.BindInterface != "" || disableDefaultBind, interfaceFinder)\n\tif forceBind != nil \{\n\t\tdialer.Control = control.Append(dialer.Control, forceBind)\n\t\tlistener.Control = control.Append(listener.Control, forceBind)\n\t\t\/\/ 重建 tcp dialer:control 在 newTCPDialer 时已被复制进 fastopen 包装\n\t\ttcpDialer4, err = newTCPDialer(dialer4, options.TCPFastOpen)\n\t\tif err != nil \{\n\t\t\treturn nil, err\n\t\t\}\n\t\ttcpDialer6, err = newTCPDialer(dialer6, options.TCPFastOpen)\n\t\tif err != nil \{\n\t\t\treturn nil, err\n\t\t\}\n\t\}\n\treturn \&DefaultDialer\{\n/' common/dialer/default.go
    echo "==> dialer forcebind hook applied"
fi

# fail-closed:全部 OHOS 补丁必须就位,缺一即停(防止半补丁状态编出坏内核)
grep -q "isOpenHarmonyRuntime" route/network.go || { echo "ERROR: route/network.go early-return patch missing" >&2; exit 1; }
grep -q "ohosForceBindFunc" common/dialer/default.go || { echo "ERROR: dialer forcebind patch missing" >&2; exit 1; }
for f in common/dialer/zz_ohos_forcebind.go common/dialer/zz_ohos_forcebind_other.go \
         route/zz_ohos_openharmony.go route/zz_ohos_other.go; do
    [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }
done

# ---- 导出符号表 ----
mkdir -p "$WORK_DIR" "$OUT_DIR"
EXPORTS_FILE="$WORK_DIR/libsingbox14.exports"
if command -v cygpath >/dev/null 2>&1; then
    EXPORTS_FILE_WIN="$(cygpath -m "$EXPORTS_FILE")"
else
    EXPORTS_FILE_WIN="$EXPORTS_FILE"
fi
cat > "$EXPORTS_FILE" <<'MAP'
{
  global:
    CGoStartSingBox;
    CGoStopSingBox;
    CGoSetTunFd;
    CGoSingBoxVersion;
  local: *;
};
MAP

# ---- 构建 ----
cd "$WRAPPER"
export GOROOT="$OHOS_GO_FORK"
export GOTOOLCHAIN=local
export PATH="$OHOS_GO_FORK/bin:$PATH"
"$OHOS_GO_FORK/bin/go" version

"$OHOS_GO_FORK/bin/go" mod edit -dropreplace github.com/sagernet/sing-box 2>/dev/null || true
"$OHOS_GO_FORK/bin/go" mod edit -dropreplace github.com/sagernet/sing-tun 2>/dev/null || true
"$OHOS_GO_FORK/bin/go" mod edit -replace "github.com/sagernet/sing-box=$SINGBOX_SRC"
"$OHOS_GO_FORK/bin/go" mod download

# ---- sing-tun monitor 补丁(OHOS 沙箱禁止 netlink 订阅;必须在 go mod download 之后,
#      对解析出的 sing-tun 版本打补丁。缺此补丁 = netlink 订阅失败 → 全部出站暂停,故 fail-closed) ----
SINGTUN_VER="$("$OHOS_GO_FORK/bin/go" list -m -f '{{.Version}}' github.com/sagernet/sing-tun)"
[ -n "$SINGTUN_VER" ] || { echo "ERROR: cannot resolve sing-tun version" >&2; exit 1; }
STDIR="$("$OHOS_GO_FORK/bin/go" env GOMODCACHE)/github.com/sagernet/sing-tun@$SINGTUN_VER"
MLM="$STDIR/monitor_linux.go"
if [ ! -f "$MLM" ] || ! grep -q "netlink.RouteSubscribe" "$MLM"; then
    echo "ERROR: sing-tun@$SINGTUN_VER monitor_linux.go patch target missing" >&2
    exit 1
fi
STPDIR="$WORK_DIR/sing-tun-patched"
rm -rf "$STPDIR"; mkdir -p "$STPDIR"
cp -R "$STDIR/." "$STPDIR/"
chmod -R u+w "$STPDIR"
perl -0pi -e 's/func \(m \*networkUpdateMonitor\) Start\(\) error \{\n\terr := netlink\.RouteSubscribe\(m\.routeUpdate, m\.close\)\n\tif err != nil \{\n\t\treturn err\n\t\}\n\terr = netlink\.LinkSubscribe\(m\.linkUpdate, m\.close\)\n\tif err != nil \{\n\t\treturn err\n\t\}\n\tgo m\.loopUpdate\(\)\n\treturn nil\n\}/func (m *networkUpdateMonitor) Start() error {\n\tif err := netlink.RouteSubscribe(m.routeUpdate, m.close); err != nil {\n\t\tm.logger.Debug("route subscribe: ", err)\n\t}\n\tif err := netlink.LinkSubscribe(m.linkUpdate, m.close); err != nil {\n\t\tm.logger.Debug("link subscribe: ", err)\n\t}\n\tgo m.loopUpdate()\n\treturn nil\n}/' "$STPDIR/monitor_linux.go"
grep -q "route subscribe" "$STPDIR/monitor_linux.go" || { echo "ERROR: sing-tun monitor patch regex did not match" >&2; exit 1; }
if [ -f "$STPDIR/monitor_linux_default.go" ] && grep -q 'netlink.RouteListFiltered' "$STPDIR/monitor_linux_default.go"; then
    cat > "$STPDIR/monitor_linux_default_openharmony.go" <<'EOF'
//go:build openharmony

package tun

func (m *defaultInterfaceMonitor) checkUpdate() error {
	return ErrNoRoute
}
EOF
    perl -0pi -e 's#//go:build linux && !android#//go:build linux \&\& !android \&\& !openharmony#' "$STPDIR/monitor_linux_default.go"
    echo "==> sing-tun OpenHarmony default-interface check disabled"
fi
# 关键:replace 必须写在主模块(wrapper)的 go.mod 里才会生效
"$OHOS_GO_FORK/bin/go" mod edit -replace "github.com/sagernet/sing-tun=$STPDIR"
echo "==> wrapper replace: sing-tun -> patched"
"$OHOS_GO_FORK/bin/go" mod tidy

if [ -f "$SINGBOX_SRC/protocol/tun/inbound.go" ]; then
    BUILD_TAGS="with_utls,with_clash_api,with_quic"
else
    BUILD_TAGS="with_utls,with_clash_api,with_quic,with_hysteria,with_tuic"
fi
echo "==> build tags: $BUILD_TAGS"

CGO_ENABLED=1 \
GOOS=openharmony \
GOARCH=arm64 \
CC="$CC_BIN" \
CXX="${CC_BIN/clang/clang++}" \
CGO_CFLAGS="${CGO_CFLAGS:--ftls-model=global-dynamic}" \
"$OHOS_GO_FORK/bin/go" build \
    -tags "$BUILD_TAGS" \
    -trimpath \
    -ldflags "-s -w -checklinkname=0 -linkmode external -extldflags '-Wl,--version-script=$EXPORTS_FILE_WIN -Wl,-z,lazy'" \
    -buildmode=c-shared \
    -o "$OUT_DIR/libsingbox.so" \
    .

"$OHOS_GO_FORK/bin/go" mod edit -dropreplace github.com/sagernet/sing-tun 2>/dev/null || true
"$OHOS_GO_FORK/bin/go" mod edit -dropreplace github.com/sagernet/sing-box 2>/dev/null || true

# ---- 构建后校验:二进制必须含全部 OHOS 补丁特征串(缺补丁 = 断网/回环,fail-closed) ----
grep -q "route subscribe" "$OUT_DIR/libsingbox.so" || { echo "ERROR: built .so lacks sing-tun netlink patch marker" >&2; exit 1; }
grep -q "SING_BOX_BIND_IFNAME" "$OUT_DIR/libsingbox.so" || { echo "ERROR: built .so lacks forcebind marker" >&2; exit 1; }
grep -q "SING_BOX_TUN_FD" "$OUT_DIR/libsingbox.so" || { echo "ERROR: built .so lacks tun-fd marker" >&2; exit 1; }
echo "==> verified OHOS patch markers in libsingbox.so"

ls -la "$OUT_DIR"
echo "==> done: $OUT_DIR/libsingbox.so"
