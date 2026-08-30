#!/usr/bin/env bash
# 把 sing-box 内核编译成 HarmonyOS c-shared 库 libsingbox.so。
#
# 默认:v1.11.9(core/sing-box-1.11,支持 Hysteria2/TUIC v5)
# 回退:v1.4.6(SINGBOX_TAG=v1.4.6 SINGBOX_SRC="$ROOT/sing-box" 调用)
#
# 必须用 OHOS Go fork + GOOS=openharmony(原版 Go 产物在 musl 上不可用)。
# 产物: entry/libs/arm64-v8a/libsingbox.so
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"        # vpn/core
PROJECT="$(cd "$ROOT/.." && pwd)"               # vpn/

SINGBOX_TAG="${SINGBOX_TAG:-v1.11.9}"
SINGBOX_SRC="${SINGBOX_SRC:-$ROOT/sing-box-1.11}"
WRAPPER="$ROOT/libsingbox14"
OUT_DIR="$PROJECT/entry/libs/arm64-v8a"
WORK_DIR="$ROOT/build/libsingbox-ohos"

OHOS_GO_FORK="${OHOS_GO_FORK:-$HOME/ohos-go-build/ohos_golang_go}"

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

# ---- 内核源码 + TUN fd 补丁(幂等) ----
if [ ! -d "$SINGBOX_SRC/.git" ]; then
    git clone --depth 1 --branch "$SINGBOX_TAG" \
        https://github.com/SagerNet/sing-box.git "$SINGBOX_SRC"
fi
cd "$SINGBOX_SRC"
git config core.autocrlf false

if [ -f "protocol/tun/inbound.go" ]; then
    if ! grep -q "SING_BOX_TUN_FD" protocol/tun/inbound.go; then
        perl -0pi -e 's/(\t\tmonitor\.Start\("open interface"\))/\t\tif t.tunOptions.FileDescriptor == 0 {\n\t\t\tif fdStr := os.Getenv("SING_BOX_TUN_FD"); fdStr != "" {\n\t\t\t\tif fd, fdErr := strconv.Atoi(fdStr); fdErr == nil && fd > 0 {\n\t\t\t\t\tt.tunOptions.FileDescriptor = fd\n\t\t\t\t}\n\t\t\t}\n\t\t}\n$1/' protocol/tun/inbound.go
        echo "==> 1.11 tun-fd patch applied"
    fi
elif [ -f "inbound/tun.go" ]; then
    if ! grep -q "SING_BOX_TUN_FD" inbound/tun.go; then
        perl -0pi -e 's/(\tif t\.tunOptions\.Name == "" \{\n\t\tt\.tunOptions\.Name = tun\.CalculateInterfaceName\(""\)\n\t\}\n)/$1\tif t.tunOptions.FileDescriptor == 0 {\n\t\tif fdStr := os.Getenv("SING_BOX_TUN_FD"); fdStr != "" {\n\t\t\tif fd, fdErr := strconv.Atoi(fdStr); fdErr == nil && fd > 0 {\n\t\t\t\tt.tunOptions.FileDescriptor = fd\n\t\t\t\tif tunName := os.Getenv("SING_BOX_TUN_NAME"); tunName != "" {\n\t\t\t\t\tt.tunOptions.Name = tunName\n\t\t\t\t}\n\t\t\t\tt.logger.Info("using platform tun file descriptor ", fd)\n\t\t\t}\n\t\t}\n\t}\n/' inbound/tun.go
        echo "==> 1.4 tun-fd patch applied"
    fi
else
    echo "ERROR: unknown sing-box layout: $SINGBOX_SRC" >&2
    exit 1
fi

# ---- netlink 监控补丁(仅 1.4 的 sing-tun v0.1.x 需要) ----
if grep -E "sing-tun v0\.(0|1)\." go.mod >/dev/null 2>&1; then
    SINGTUN_VER="$("$OHOS_GO_FORK/bin/go" list -m -f '{{.Version}}' github.com/sagernet/sing-tun 2>/dev/null || true)"
    if [ -n "$SINGTUN_VER" ]; then
        STDIR="$("$OHOS_GO_FORK/bin/go" env GOMODCACHE)/github.com/sagernet/sing-tun@$SINGTUN_VER"
        MLM="$STDIR/monitor_linux.go"
        if [ -f "$MLM" ] && grep -q "netlink.RouteSubscribe" "$MLM"; then
            STPDIR="$WORK_DIR/sing-tun-patched"
            rm -rf "$STPDIR"; mkdir -p "$STPDIR"
            cp -R "$STDIR/." "$STPDIR/"
            chmod -R u+w "$STPDIR"
            perl -0pi -e 's/func \(m \*networkUpdateMonitor\) Start\(\) error \{\n\terr := netlink\.RouteSubscribe\(m\.routeUpdate, m\.close\)\n\tif err != nil \{\n\t\treturn err\n\t\}\n\terr = netlink\.LinkSubscribe\(m\.linkUpdate, m\.close\)\n\tif err != nil \{\n\t\treturn err\n\t\}\n\tgo m\.loopUpdate\(\)\n\treturn nil\n\}/func (m *networkUpdateMonitor) Start() error {\n\tif err := netlink.RouteSubscribe(m.routeUpdate, m.close); err != nil {\n\t\tm.logger.Debug("route subscribe: ", err)\n\t}\n\tif err := netlink.LinkSubscribe(m.linkUpdate, m.close); err != nil {\n\t\tm.logger.Debug("link subscribe: ", err)\n\t}\n\tgo m.loopUpdate()\n\treturn nil\n}/' "$STPDIR/monitor_linux.go"
            if grep -q "best-effort" "$STPDIR/monitor_linux.go" 2>/dev/null; then
                "$OHOS_GO_FORK/bin/go" mod edit -replace "github.com/sagernet/sing-tun=$STPDIR"
                echo "==> sing-tun monitor patched (netlink best-effort)"
            fi
        fi
    fi
fi

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
"$OHOS_GO_FORK/bin/go" mod edit -replace "github.com/sagernet/sing-box=$SINGBOX_SRC"
"$OHOS_GO_FORK/bin/go" mod download
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

ls -la "$OUT_DIR"
echo "==> done: $OUT_DIR/libsingbox.so"
