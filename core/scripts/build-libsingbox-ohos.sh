#!/usr/bin/env bash
# 把 sing-box 1.4(含 TUN fd 注入补丁)编译成 HarmonyOS c-shared 库:
#   entry/libs/arm64-v8a/libsingbox.so
# 架构参考 Hey(github.com/xiaoli8571/Hey):必须用 OHOS Go fork + GOOS=openharmony,
# 原版 Go 的产物在 HarmonyOS(musl) 上 dlopen 失败或外来线程 cgo 崩溃。
#
# 前置:
#   1) bash core/scripts/build-ohos-toolchain.sh   (一次性构建 fork 工具链)
#   2) DevEco Studio 的 OHOS clang(本机已装)
#   3) core/sing-box 已克隆并打补丁(脚本自动处理)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"        # vpn/core
PROJECT="$(cd "$ROOT/.." && pwd)"                # vpn/
SRC="$ROOT/sing-box"
WRAPPER="$ROOT/libsingbox14"
OUT_DIR="$PROJECT/entry/libs/arm64-v8a"
WORK_DIR="$ROOT/build/libsingbox-ohos"
SING_BOX_VERSION="v1.5.5"
SING_BOX_COMMIT="a7710c3845fc1b70c5b390fb5b303d6a776435e4"

cleanup_module_replacements() {
    if [ -n "${OHOS_GO_FORK:-}" ] && [ -d "$WRAPPER" ]; then
        cd "$WRAPPER" || return
        "$OHOS_GO_FORK/bin/go" mod edit -dropreplace github.com/sagernet/gvisor 2>/dev/null || true
        "$OHOS_GO_FORK/bin/go" mod edit -dropreplace github.com/sagernet/sing-tun 2>/dev/null || true
    fi
}
trap cleanup_module_replacements EXIT

OHOS_GO_FORK="${OHOS_GO_FORK:-$HOME/ohos-go-build/ohos_golang_go}"
DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-C:\\Program Files\\Huawei\\DevEco Studio\\sdk}"
NATIVE="$PROJECT/core/native-link"                  # placeholder

# ---- 定位 OHOS clang ----
SDK_NATIVE="$ROOT/../deveco-native"
for cand in \
    "$DEVECO_SDK_HOME/default/openharmony/native" \
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
    # SDK 自带的是 POSIX shell 包装脚本,Windows 无法直接执行 → 生成 .bat 包装器
    CLANG_SH="$SDK_NATIVE/llvm/bin/aarch64-unknown-linux-ohos-clang"
    if head -c 20 "$CLANG_SH" | grep -q "#!/bin/sh"; then
        printf '@echo off\r\n"%%~dp0clang.exe" -target aarch64-linux-ohos --sysroot=%%~dp0..\\..\\sysroot -D__MUSL__ %%*\r\n' > "$SDK_NATIVE/llvm/bin/ohos-clang.bat"
        printf '@echo off\r\n"%%~dp0clang++.exe" -target aarch64-linux-ohos --sysroot=%%~dp0..\\..\\sysroot -D__MUSL__ %%*\r\n' > "$SDK_NATIVE/llvm/bin/ohos-clang++.bat"
        CC_BIN="$SDK_NATIVE/llvm/bin/ohos-clang.bat"
        echo "==> 已生成 ohos-clang.bat 包装器"
    fi
fi
[ -z "$CC_BIN" ] && { echo "ERROR: 找不到可用的 aarch64-unknown-linux-ohos-clang" >&2; exit 1; }
echo "==> CC: $CC_BIN"

# CC 路径含空格(Program Files)时,go/cgo 无法正确解析,换 8.3 短路径
if echo "$CC_BIN" | grep -q " "; then
    if command -v cygpath >/dev/null 2>&1; then
        SHORT="$(cygpath -d "$CC_BIN" 2>/dev/null || true)"
        if [ -n "$SHORT" ]; then CC_BIN="$SHORT"; fi
    fi
fi
CXX_BIN="${CC_BIN}"
echo "==> CC(short): $CC_BIN"

# ---- fork 工具链 ----
if [ -x "$OHOS_GO_FORK/bin/go" ] || [ -f "$OHOS_GO_FORK/bin/go.exe" ]; then
    echo "==> OHOS Go fork: $OHOS_GO_FORK"
else
    echo "ERROR: 未找到 OHOS Go fork($OHOS_GO_FORK)。先运行:" >&2
    echo "  bash core/scripts/build-ohos-toolchain.sh" >&2
    exit 1
fi

# ---- 内核源码 + 补丁 ----
if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch "$SING_BOX_VERSION" https://github.com/SagerNet/sing-box.git "$SRC"
fi
cd "$SRC"
git config core.autocrlf false
if ! git cat-file -e "$SING_BOX_COMMIT^{commit}" 2>/dev/null; then
    git fetch --depth 1 origin tag "$SING_BOX_VERSION"
fi
[ "$(git rev-parse "$SING_BOX_VERSION^{commit}")" = "$SING_BOX_COMMIT" ] || {
    echo "ERROR: $SING_BOX_VERSION does not resolve to expected commit $SING_BOX_COMMIT" >&2
    exit 1
}
git checkout --detach "$SING_BOX_COMMIT"
git reset --quiet "$SING_BOX_COMMIT"
git checkout "$SING_BOX_COMMIT" -- .
if git apply --check "$ROOT/patches/001-tun-fd-env.patch"; then
    git apply "$ROOT/patches/001-tun-fd-env.patch"
    echo "==> tun-fd patch applied"
elif git apply --reverse --check "$ROOT/patches/001-tun-fd-env.patch"; then
    echo "==> tun-fd patch already applied"
else
    echo "ERROR: tun-fd patch is neither applicable nor already applied" >&2
    exit 1
fi
echo "==> sing-box version: $SING_BOX_VERSION"
echo "==> sing-box commit: $(git rev-parse HEAD)"
echo "==> sing-box source status:"
git status --short

# ---- 导出符号表 ----
mkdir -p "$WORK_DIR" "$OUT_DIR"
EXPORTS_FILE="$WORK_DIR/libsingbox14.exports"
# lld 是 Windows 程序,不认 MSYS 风格路径
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
echo "==> build target: openharmony/arm64"
echo "==> wrapper module: $("$OHOS_GO_FORK/bin/go" list -m)"

# 首次需要拉取依赖(go.sum)
if [ ! -f go.sum ]; then
    "$OHOS_GO_FORK/bin/go" mod tidy
fi
# 保证依赖已下载(缓存与之前 go mod download 共享)
"$OHOS_GO_FORK/bin/go" mod download

# gvisor Fstat 补丁(尽力而为):sagernet gvisor 的 fdbased isSocketFD 对 OHOS VPN fd
# 会失败;sing-tun 的 gvisor 栈是自实现读写,大概率不命中,不中只告警。
GVISOR_VER="$("$OHOS_GO_FORK/bin/go" list -m -f '{{.Version}}' github.com/sagernet/gvisor 2>/dev/null || true)"
if [ -n "$GVISOR_VER" ] && command -v python3 >/dev/null 2>&1; then
    GDIR="$("$OHOS_GO_FORK/bin/go" env GOMODCACHE)/github.com/sagernet/gvisor@$GVISOR_VER"
    FDB="$GDIR/pkg/tcpip/link/fdbased/endpoint.go"
    if [ -f "$FDB" ] && grep -q "func isSocketFD(fd int)" "$FDB"; then
        PDIR="$WORK_DIR/gvisor-patched"
        rm -rf "$PDIR"; mkdir -p "$PDIR"
        cp -R "$GDIR/." "$PDIR/"
        python3 - "$PDIR/pkg/tcpip/link/fdbased/endpoint.go" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); t = p.read_text()
old = """func isSocketFD(fd int) (bool, error) {
\tvar stat unix.Stat_t
\tif err := unix.Fstat(fd, &stat); err != nil {
\t\treturn false, fmt.Errorf("unix.Fstat(%v,...) failed: %v", fd, err)
\t}
\treturn (stat.Mode & unix.S_IFSOCK) == unix.S_IFSOCK, nil
}
"""
new = """func isSocketFD(fd int) (bool, error) {
\treturn false, nil // HarmonyOS VPN fd 拒 Fstat;强制走非 socket Readv dispatcher
}
"""
if old in t:
    p.write_text(t.replace(old, new)); print("==> gvisor isSocketFD patched")
else:
    print("WARN: gvisor isSocketFD 形状不符,跳过", file=sys.stderr)
PY
        "$OHOS_GO_FORK/bin/go" mod edit -replace "github.com/sagernet/gvisor=$PDIR"
    fi
fi

# ---- sing-tun 网络监控补丁(必须) ----
# OHOS 应用沙箱禁止 netlink RouteSubscribe/LinkSubscribe(EPERM),错误会裸穿透到
# box.Start 导致启动失败;我们关闭了 auto_detect_interface,监控降级为尽力而为即可。
SINGTUN_VER="$("$OHOS_GO_FORK/bin/go" list -m -f '{{.Version}}' github.com/sagernet/sing-tun 2>/dev/null || true)"
if [ -n "$SINGTUN_VER" ]; then
    STDIR="$("$OHOS_GO_FORK/bin/go" env GOMODCACHE)/github.com/sagernet/sing-tun@$SINGTUN_VER"
    MLM="$STDIR/monitor_linux.go"
    if [ -f "$MLM" ] && grep -q "netlink.RouteSubscribe" "$MLM"; then
        STPDIR="$WORK_DIR/sing-tun-patched"
        rm -rf "$STPDIR"; mkdir -p "$STPDIR"
        cp -R "$STDIR/." "$STPDIR/"
        chmod -R u+w "$STPDIR"
        perl -0pi -e 's/func \(m \*networkUpdateMonitor\) Start\(\) error \{\n\terr := netlink\.RouteSubscribe\(m\.routeUpdate, m\.close\)\n\tif err != nil \{\n\t\treturn err\n\t\}\n\terr = netlink\.LinkSubscribe\(m\.linkUpdate, m\.close\)\n\tif err != nil \{\n\t\treturn err\n\t\}\n\tgo m\.loopUpdate\(\)\n\treturn nil\n\}/func (m *networkUpdateMonitor) Start() error {\n\t\/\/ OHOS app sandbox denies netlink subscribe; degrade to best-effort.\n\tif err := netlink.RouteSubscribe(m.routeUpdate, m.close); err != nil {\n\t\tm.logger.Debug("route subscribe: ", err)\n\t}\n\tif err := netlink.LinkSubscribe(m.linkUpdate, m.close); err != nil {\n\t\tm.logger.Debug("link subscribe: ", err)\n\t}\n\tgo m.loopUpdate()\n\treturn nil\n}/' "$STPDIR/monitor_linux.go"
        if grep -q "degrade to best-effort" "$STPDIR/monitor_linux.go"; then
            "$OHOS_GO_FORK/bin/go" mod edit -replace "github.com/sagernet/sing-tun=$STPDIR"
            echo "==> sing-tun monitor patched (netlink best-effort)"
        else
            echo "WARN: sing-tun monitor_linux.go 形状不符,补丁未应用" >&2
        fi
    fi
fi

echo "==> building libsingbox.so (c-shared, openharmony/arm64)"
# 注意:不带 with_gvisor —— 1.4 时代锁定的 gvisor 快照不支持 go1.22+(runtime linkname
# ABI 变化);sing-tun 的 system 协议栈不依赖 gvisor,功能完整。QUIC(TUIC/Hysteria)
# 保留尝试,若 qtls 构建约束拒绝再去掉 with_quic。
CGO_ENABLED=1 \
GOOS=openharmony \
GOARCH=arm64 \
CC="$CC_BIN" \
CXX="$CXX_BIN" \
CGO_CFLAGS="${CGO_CFLAGS:--ftls-model=global-dynamic}" \
"$OHOS_GO_FORK/bin/go" build \
    -tags "with_utls,with_clash_api,with_quic" \
    -trimpath \
    -ldflags "-s -w -checklinkname=0 -linkmode external -extldflags '-Wl,--version-script=$EXPORTS_FILE_WIN -Wl,-z,lazy'" \
    -buildmode=c-shared \
    -o "$OUT_DIR/libsingbox.so" \
    .

# 清理临时 replace,保持 go.mod 干净(EXIT trap 也保证失败路径清理)
cleanup_module_replacements

ls -la "$OUT_DIR"
echo "==> done: $OUT_DIR/libsingbox.so"
