#!/usr/bin/env bash
# ============================================================================
# NekoBox4Harmony sing-box v1.14.0 → HarmonyOS libsingbox.so 构建流水线
#
# 背景:sing-box 1.14.0 依赖图要求 go >= 1.25.5,并实际使用 go1.25 的
# sync.WaitGroup.Go;而 OHOS Go fork 的 openharmony 移植目前只到 go1.24.5
# (release-branch.go1.26 为纯上游、无 openharmony)。
#
# 因此分两步:
#   A) 用 go1.26.7(OHOS 仓库 release-branch.go1.26,纯上游)完成
#      go mod download / tidy / vendor(模块图解析需要 >=1.25.5);
#      对解析出的 sing-tun 打 OHOS netlink 补丁并 replace;
#      把 vendor/modules.txt 与 vendored go.mod 记录的 go 指令统一压到 1.24;
#      为 quic-go 注入 !go1.25 的 quic_event shim(等价于 fork 自身的
#      go1.25 保守分支)。
#   B) 用 go1.24.5 OHOS fork(其 sync 包已回植上游 go1.25 的
#      WaitGroup.Go 方法,见 <fork>/src/sync/waitgroup_go125api.go)+
#      GOOS=openharmony GOARCH=arm64 + OHOS clang,-mod=vendor 交叉编译
#      c-shared libsingbox.so。
#
# 前置(一次性):
#   bash core/scripts/build-ohos-toolchain.sh
#   OHOS_GO_FORK=$HOME/ohos-go-build/ohos_golang_go126 \
#     OHOS_GO_FORK_BRANCH=release-branch.go1.26 \
#     bash core/scripts/build-ohos-toolchain.sh
#   并把 sync.WaitGroup.Go 回植到 go1.24.5 fork 的 src/sync/ 后重跑 make.bat
#   (回植文件模板见本仓库 core/patches/ohos-gofork-waitgroup-go.txt)。
#
# 产物: entry/libs/arm64-v8a/libsingbox.so
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"        # NekoBox4Harmony/core
PROJECT="$(cd "$ROOT/.." && pwd)"               # NekoBox4Harmony/

SB="${SINGBOX_SRC:-$ROOT/sing-box-1.14}"
SINGBOX_TAG="${SINGBOX_TAG:-v1.14.0}"
WRAPPER="$ROOT/libsingbox14"
WORK_DIR="$ROOT/build/libsingbox-ohos"
OUT_DIR="$PROJECT/entry/libs/arm64-v8a"
EXPORTS_FILE="$WORK_DIR/exports.map"

GO126="${GO126:-$HOME/ohos-go-build/ohos_golang_go126/bin/go}"
GO124="${OHOS_GO_FORK:-$HOME/ohos-go-build/ohos_golang_go}/bin/go"

export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
export GOTOOLCHAIN=local

command -v "$GO126" >/dev/null 2>&1 || [ -x "$GO126" ] || [ -f "$GO126.exe" ] || { echo "ERROR: go1.26 host toolchain missing ($GO126). Run: OHOS_GO_FORK=\$HOME/ohos-go-build/ohos_golang_go126 OHOS_GO_FORK_BRANCH=release-branch.go1.26 bash core/scripts/build-ohos-toolchain.sh"; exit 1; }
[ -x "$GO124" ] || [ -f "$GO124.exe" ] || { echo "ERROR: go1.24 OHOS toolchain missing ($GO124). Run: bash core/scripts/build-ohos-toolchain.sh"; exit 1; }

# ---- 校验 fork 已回植 WaitGroup.Go(fail-closed) ----
GOSRC="$(dirname "$(dirname "$GO124")")/src/sync"
grep -rq "func (w \*WaitGroup) Go(f func())" "$GOSRC" || { echo "ERROR: go1.24 OHOS fork lacks sync.WaitGroup.Go backport ($GOSRC)"; exit 1; }

# ---- 0. sing-box 源码 OHOS 补丁(幂等;裸源码自动补齐) ----
if [ ! -f "$SB/go.mod" ]; then
  if [ -d "$SB" ] && [ -n "$(ls -A "$SB" 2>/dev/null)" ]; then
    echo "ERROR: $SB 已存在但没有 go.mod"; exit 1
  fi
  git clone --depth 1 --branch "$SINGBOX_TAG" https://github.com/SagerNet/sing-box.git "$SB"
fi
cd "$SB"
[ -d .git ] && git config core.autocrlf false || true

# 补丁 1:TUN fd 注入(SING_BOX_TUN_FD)
if ! grep -q "SING_BOX_TUN_FD" protocol/tun/inbound.go; then
  perl -0pi -e 's/(\t\tmonitor := taskmonitor\.New\(t\.logger, C\.StartTimeout\)\n)/$1\t\tif t.tunOptions.FileDescriptor == 0 {\n\t\t\tif fdStr := os.Getenv("SING_BOX_TUN_FD"); fdStr != "" {\n\t\t\t\tfd, fdErr := strconv.Atoi(fdStr)\n\t\t\t\tif fdErr != nil || fd <= 0 {\n\t\t\t\t\treturn E.New("invalid SING_BOX_TUN_FD: ", fdStr)\n\t\t\t\t}\n\t\t\t\tt.tunOptions.FileDescriptor = fd\n\t\t\t}\n\t\t}\n/' protocol/tun/inbound.go
fi
grep -q "SING_BOX_TUN_FD" protocol/tun/inbound.go || { echo "ERROR: tun-fd patch failed"; exit 1; }
FD_ENV_LINE="$(grep -n 'fdStr := os.Getenv("SING_BOX_TUN_FD")' protocol/tun/inbound.go | cut -d: -f1)"
FD_COPY_LINE="$(grep -n 'tunOptions := t.tunOptions' protocol/tun/inbound.go | cut -d: -f1)"
TUN_NEW_LINE="$(grep -n 'tunInterface, err = tun.New(tunOptions)' protocol/tun/inbound.go | cut -d: -f1)"
[ -n "$FD_ENV_LINE" ] && [ -n "$FD_COPY_LINE" ] && [ -n "$TUN_NEW_LINE" ] || { echo "ERROR: tun fd anchors missing"; exit 1; }
[ "$FD_ENV_LINE" -lt "$FD_COPY_LINE" ] && [ "$FD_COPY_LINE" -lt "$TUN_NEW_LINE" ] || { echo "ERROR: tun fd injection must precede tunOptions copy and tun.New()"; exit 1; }
grep -q 'invalid SING_BOX_TUN_FD' protocol/tun/inbound.go || { echo "ERROR: invalid SING_BOX_TUN_FD must fail closed"; exit 1; }

# 补丁 2:netlink monitor 早退(isOpenHarmonyRuntime,openharmony build tag 判定)
if ! grep -q "isOpenHarmonyRuntime" route/network.go; then
  perl -0pi -e 's/\tif !usePlatformDefaultInterfaceMonitor \{\n/\tif !usePlatformDefaultInterfaceMonitor \{\n\t\t\/\/ OHOS Go fork 的 runtime.GOOS 实际返回 "linux",不能用 runtime 判断平台,\n\t\t\/\/ 必须用 openharmony build tag 常量(否则 netlink monitor 在沙箱里必然失败)\n\t\tif isOpenHarmonyRuntime \&\& !enforceInterfaceMonitor \{\n\t\t\treturn nm, nil\n\t\t\}\n/' route/network.go
fi
grep -q "isOpenHarmonyRuntime" route/network.go || { echo "ERROR: network.go patch failed"; exit 1; }

# 补丁 3:出站 forcebind 挂接(防回环;SING_BOX_BIND_IFNAME 休眠钩子)
if ! grep -q "ohosForceBindFunc" common/dialer/default.go; then
  perl -0pi -e 's/(\t\t\t\}\n\t\t\}\n\t\tif options\.RoutingMark == 0 && defaultOptions\.RoutingMark != 0 \{)/\t\t\t}\n\t\t}\n\t\t\/\/ OpenHarmony 防回环兜底:仍未绑定任何接口时,强制 SO_BINDTODEVICE 到物理网卡\n\t\t\/\/ (SING_BOX_BIND_IFNAME 由扩展侧注入);已显式绑定的(bind_interface\/default_interface)不覆盖。\n\t\t\/\/ 追加到 dialer\/listener 后,后续由二者复制出的 dialer4\/6、udpDialer*\/udpListener 均继承该 Control。\n\t\tforceBind := ohosForceBindFunc(options.BindInterface != "" || disableDefaultBind, interfaceFinder)\n\t\tif forceBind != nil \{\n\t\t\tdialer.Control = control.Append(dialer.Control, forceBind)\n\t\t\tlistener.Control = control.Append(listener.Control, forceBind)\n\t\t}\n\t\tif options.RoutingMark == 0 && defaultOptions.RoutingMark != 0 {/' common/dialer/default.go
fi
grep -q "ohosForceBindFunc" common/dialer/default.go || { echo "ERROR: dialer patch failed"; exit 1; }

# 补丁 5:direct outbound fetchMyAddresses 判空(1.14 新增;补丁 2 早退后 InterfaceMonitor 为 nil,
# 1.14 的 direct.Start(PostStart) 无条件调用 → nil 接口调方法 SIGSEGV;上游 dhcp.go 同样判空)
if ! grep -q "InterfaceMonitor() == nil" protocol/direct/outbound.go; then
  perl -0pi -e 's/func \(h \*Outbound\) fetchMyAddresses\(\) \{\n/\1\t\/\/ OHOS: auto_detect_interface=false 时 InterfaceMonitor 为 nil(route\/network.go 补丁 2 早退),\n\t\/\/ nil 接口调方法直接 SIGSEGV;上游 dhcp.go 也做了同样的判空。\n\tif h.network.InterfaceMonitor() == nil {\n\t\treturn\n\t}\n/' protocol/direct/outbound.go
fi
grep -q "InterfaceMonitor() == nil" protocol/direct/outbound.go || { echo "ERROR: direct fetchMyAddresses nil-guard patch failed"; exit 1; }

# 补丁 4:zz_ohos 平台常量与钩子实现(openharmony build tag 隔离)
for f in common/dialer/zz_ohos_forcebind.go common/dialer/zz_ohos_forcebind_other.go route/zz_ohos_openharmony.go route/zz_ohos_other.go; do
  [ -f "$f" ] || cp "$ROOT/patches/zz-ohos/$f" "$f"
done
echo "==> sing-box OHOS patches verified"

# ---- A1. 依赖解析与 vendor(需要 >=1.25.5 工具链) ----
cd "$WRAPPER"
"$GO126" mod edit -replace "github.com/sagernet/sing-box=$SB"
"$GO126" mod edit -dropreplace github.com/sagernet/sing-tun 2>/dev/null || true
"$GO126" mod download
SINGTUN_VER="$("$GO126" list -m -f '{{.Version}}' github.com/sagernet/sing-tun)"
[ -n "$SINGTUN_VER" ] || { echo "ERROR: cannot resolve sing-tun"; exit 1; }
STDIR="$("$GO126" env GOMODCACHE)/github.com/sagernet/sing-tun@$SINGTUN_VER"
[ -f "$STDIR/monitor_linux.go" ] || { echo "ERROR: sing-tun@${SINGTUN_VER} monitor_linux.go missing"; exit 1; }
STPDIR="$WORK_DIR/sing-tun-patched"
rm -rf "$STPDIR"; mkdir -p "$STPDIR"
cp -R "$STDIR/." "$STPDIR/"; chmod -R u+w "$STPDIR"
# sing-tun netlink 订阅改 best-effort(OHOS 沙箱禁止 netlink,订阅失败不可致命)
perl -0pi -e 's/func \(m \*networkUpdateMonitor\) Start\(\) error \{\n\terr := netlink\.RouteSubscribe\(m\.routeUpdate, m\.close\)\n\tif err != nil \{\n\t\treturn E\.Cause\(err, "subscribe route updates"\)\n\t\}\n\terr = netlink\.LinkSubscribe\(m\.linkUpdate, m\.close\)\n\tif err != nil \{\n\t\treturn E\.Cause\(err, "subscribe link updates"\)\n\t\}\n\terr = netlink\.AddrSubscribe\(m\.addressUpdate, m\.close\)\n\tif err != nil \{\n\t\treturn E\.Cause\(err, "subscribe address updates"\)\n\t\}\n\tgo m\.loopUpdate\(time\.Second\)\n\treturn nil\n\}/func (m *networkUpdateMonitor) Start() error {\n\tif err := netlink.RouteSubscribe(m.routeUpdate, m.close); err != nil {\n\t\tm.logger.Debug("route subscribe: ", err)\n\t}\n\tif err := netlink.LinkSubscribe(m.linkUpdate, m.close); err != nil {\n\t\tm.logger.Debug("link subscribe: ", err)\n\t}\n\tif err := netlink.AddrSubscribe(m.addressUpdate, m.close); err != nil {\n\t\tm.logger.Debug("address subscribe: ", err)\n\t}\n\tgo m.loopUpdate(time.Second)\n\treturn nil\n}/' "$STPDIR/monitor_linux.go"
grep -q "route subscribe" "$STPDIR/monitor_linux.go" || { echo "ERROR: sing-tun monitor patch regex did not match"; exit 1; }
if grep -q 'netlink.RouteListFiltered' "$STPDIR/monitor_linux_default.go" 2>/dev/null; then
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
"$GO126" mod edit -replace "github.com/sagernet/sing-tun=$STPDIR"
"$GO126" mod tidy
"$GO126" mod vendor
echo "==> wrapper replace: sing-box -> patched, sing-tun -> patched; vendored"

# ---- A2. 降级 vendor 记录的 go 指令(go1.24 交叉工具链加载需要) ----
# tidy(go1.26)会把主模块 go 指令抬到 1.25.5,压回 1.24.5
"$GO126" mod edit -go=1.24.5
sed -i -E 's/^(# .*) go 1\.2[4-9][0-9.]*$/\1 go 1.24/' vendor/modules.txt
sed -i -E 's/^(## explicit; go )1\.2[4-9][0-9.]*$/\11.24/' vendor/modules.txt
find vendor -name go.mod -print0 | xargs -0 -r sed -i -E 's/^go 1\.2[4-9][0-9.]*$/go 1.24/'
grep -qE "^go 1\.2[5-9]" go.mod && { echo "ERROR: wrapper go.mod still >=1.25"; exit 1; } || true

# ---- A3. quic-go !go1.25 shim(fork 在 go1.25 路径的等价保守实现) ----
DQ='vendor/github.com/sagernet/quic-go/internal/handshake'
if ! [ -f "$DQ/quic_event_go124_ohos.go" ]; then
  cat > "$DQ/quic_event_go124_ohos.go" <<'EOF'
//go:build !go1.25

package handshake

import "crypto/tls"

const quicErrorEvent tls.QUICEventKind = -1

func extractQUICEventError(tls.QUICEvent) error {
	return nil
}
EOF
fi
echo "==> vendor prepared for go1.24 toolchain"

# ---- B. 交叉编译 openharmony c-shared ----
SDK_NATIVE=""
for cand in \
    "/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native" \
    "$LOCALAPPDATA/Huawei/Sdk/default/openharmony/native"; do
  if [ -d "$cand" ]; then SDK_NATIVE="$cand"; break; fi
done
[ -n "$SDK_NATIVE" ] || { echo "ERROR: openharmony native SDK not found"; exit 1; }
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

mkdir -p "$OUT_DIR"
cat > "$EXPORTS_FILE" <<'MAP'
{
  global:
    CGoSetTunFd;
    CGoStartSingBox;
    CGoStopSingBox;
    CGoSingBoxVersion;
    CGoTestStartSingBox;
    CGoTestProxySingBox;
    CGoTestStopSingBox;
    _cgoexp_*;
    crosscall2;
    runtime.*;
  local:
    *;
};
MAP
EXPORTS_FILE_WIN="$(cygpath -d "$EXPORTS_FILE")"

BUILD_TAGS="with_utls,with_clash_api,with_quic"
echo "==> build tags: $BUILD_TAGS"
rm -f "$OUT_DIR/libsingbox.so"
CGO_ENABLED=1 GOOS=openharmony GOARCH=arm64 \
CC="$CC_BIN" CXX="${CC_BIN/clang/clang++}" \
CGO_CFLAGS="${CGO_CFLAGS:--ftls-model=global-dynamic}" \
"$GO124" build -mod=vendor \
    -tags "$BUILD_TAGS" \
    -trimpath \
    -ldflags "-s -w -X github.com/sagernet/sing-box/constant.Version=v1.14.0 -checklinkname=0 -linkmode external -extldflags '-Wl,--version-script=$EXPORTS_FILE_WIN -Wl,-z,lazy'" \
    -buildmode=c-shared \
    -o "$OUT_DIR/libsingbox.so" .

# ---- 构建后校验(全部 fail-closed;二进制用固定串匹配) ----
SO="$OUT_DIR/libsingbox.so"
[ -f "$SO" ] || { echo "ERROR: no .so produced"; exit 1; }
grep -aqF "route subscribe" "$SO"     || { echo "ERROR: .so lacks sing-tun netlink patch marker"; exit 1; }
grep -aqF "SING_BOX_BIND_IFNAME" "$SO" || { echo "ERROR: .so lacks forcebind marker"; exit 1; }
grep -aqF "SING_BOX_TUN_FD" "$SO"     || { echo "ERROR: .so lacks tun-fd marker"; exit 1; }
grep -aqF "1.14.0-ohos-inproc" "$SO"  || { echo "ERROR: .so lacks 1.14.0 version marker"; exit 1; }
grep -aqF "1.11.9" "$SO"              && { echo "ERROR: .so still contains 1.11.9 string"; exit 1; }
# 动态符号表须含 URL 测速导出(dlsym 依赖 .dynsym)
READELF="$SDK_NATIVE/llvm/bin/llvm-readelf.exe"
[ -f "$READELF" ] || READELF="$SDK_NATIVE/llvm/bin/llvm-readelf"
if [ -x "$READELF" ] || [ -f "$READELF" ]; then
  "$READELF" --dyn-syms "$SO" | grep -q "CGoTestStartSingBox" || { echo "ERROR: .so missing CGoTest* exports"; exit 1; }
fi
echo "==> ALL verification markers passed in libsingbox.so"
ls -la "$OUT_DIR"
echo "==> done: $SO"
