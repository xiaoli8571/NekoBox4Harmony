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
# Do not change repository configuration during a build.

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

# 补丁 6:restore explicit sniff override (Android route vs override modes).
if ! grep -q 'json:"override_destination,omitempty"' option/rule_action.go; then
  perl -0pi -e 's/(type RouteActionSniff struct \{\n)/$1\tOverrideDestination bool `json:"override_destination,omitempty"`\n/' option/rule_action.go
fi
if ! grep -q 'OverrideDestination: action.SniffOptions.OverrideDestination' route/rule/rule_action.go; then
  perl -0pi -e 's/(sniffAction := &RuleActionSniff\{\n)/$1\t\t\tOverrideDestination: action.SniffOptions.OverrideDestination,\n/' route/rule/rule_action.go
fi
grep -q 'json:"override_destination,omitempty"' option/rule_action.go || { echo "ERROR: sniff override schema patch failed"; exit 1; }
grep -q 'OverrideDestination: action.SniffOptions.OverrideDestination' route/rule/rule_action.go || { echo "ERROR: sniff override wiring patch failed"; exit 1; }

# 补丁 7:URL Test 状态码校验 + HEAD→GET 回退(common/urltest/urltest.go)
# 上游 urlTest 拿到 HTTP 响应就返回耗时,从不看 StatusCode —— 探测网址返回
# 403/404/500(CDN 劫持 / GFW 污染)时节点会被判成"可用",击穿"绿=真可用"。
# 同时上游固定用 HEAD,站点对 HEAD 回 405 会让整组假红。
# 幂等标记 = 注入的注释串 "OHOS patch 7"。改这个串会让本块重新执行;
# 由于 perl 的模式已匹配不到已改过的签名,会变成 no-op,后面的守卫仍然成立。
if ! grep -q "OHOS patch 7" common/urltest/urltest.go; then
  perl -0pi -e 's/func URLTest\(ctx context\.Context, link string, detour N\.Dialer\) \(uint16, error\) \{/type URLTestOptions struct {\n\tExpect2xx        bool\n\tAllowGetFallback bool\n}\n\nfunc DefaultURLTestOptions() URLTestOptions {\n\treturn URLTestOptions{Expect2xx: true, AllowGetFallback: true}\n}\n\n\/\/ OHOS patch 7: status-code acceptance + HEAD->GET fallback.\nfunc URLTest(ctx context.Context, link string, detour N.Dialer) (uint16, error) {\n\treturn URLTestWithOptions(ctx, link, detour, DefaultURLTestOptions())\n}\n\nfunc URLTestWithOptions(ctx context.Context, link string, detour N.Dialer, options URLTestOptions) (uint16, error) {/' common/urltest/urltest.go
  perl -0pi -e 's/_, err := urlTest\(ctx, link, detour\)/_, err := urlTest(ctx, link, detour, options, http.MethodHead)/' common/urltest/urltest.go
  perl -0pi -e 's/return urlTest\(ctx, link, detour\)\n\}/return urlTest(ctx, link, detour, options, http.MethodHead)\n}/' common/urltest/urltest.go
  perl -0pi -e 's/func urlTest\(ctx context\.Context, link string, detour N\.Dialer\) \(t uint16, err error\) \{/func urlTest(ctx context.Context, link string, detour N.Dialer, options URLTestOptions, method string) (t uint16, err error) {/' common/urltest/urltest.go
  perl -0pi -e 's/req, err := http\.NewRequest\(http\.MethodHead, link, nil\)/req, err := http.NewRequest(method, link, nil)/' common/urltest/urltest.go
  # 顺序要紧:GET 回退必须排在 2xx 判定之前,否则 405/501 在默认严格选项下
  # 先被状态码判定拦掉,回退分支成了永远走不到的死代码。
  perl -0pi -e 's/\tresp\.Body\.Close\(\)\n\tt = uint16\(time\.Since\(start\) \/ time\.Millisecond\)/\tresp.Body.Close()\n\tif options.AllowGetFallback \&\& method == http.MethodHead \&\&\n\t\t(resp.StatusCode == http.StatusMethodNotAllowed || resp.StatusCode == http.StatusNotImplemented) {\n\t\treturn urlTest(ctx, link, detour, options, http.MethodGet)\n\t}\n\tif options.Expect2xx \&\& (resp.StatusCode < 200 || resp.StatusCode >= 300) {\n\t\treturn 0, E.New("unexpected HTTP status: ", resp.StatusCode)\n\t}\n\tt = uint16(time.Since(start) \/ time.Millisecond)/' common/urltest/urltest.go
  perl -0pi -e 's/(\tC "github\.com\/sagernet\/sing-box\/constant"\n)/$1\tE "github.com\/sagernet\/sing\/common\/exceptions"\n/' common/urltest/urltest.go
fi
grep -q "OHOS patch 7" common/urltest/urltest.go || { echo "ERROR: urltest status-code patch failed"; exit 1; }
grep -q "func URLTestWithOptions" common/urltest/urltest.go || { echo "ERROR: urltest URLTestWithOptions missing"; exit 1; }
grep -q "unexpected HTTP status" common/urltest/urltest.go || { echo "ERROR: urltest status acceptance missing"; exit 1; }
grep -q "http.StatusMethodNotAllowed" common/urltest/urltest.go || { echo "ERROR: urltest HEAD->GET fallback missing"; exit 1; }
# GET 回退必须排在 2xx 判定之前(否则是死代码);按出现位置断言顺序。
awk '/if options\.AllowGetFallback/ { fb = NR } /if options\.Expect2xx/ { ex = NR }
     END { if (fb == 0 || ex == 0 || fb > ex) { print "ERROR: urltest fallback must precede status check"; exit 1 } }' \
  common/urltest/urltest.go || exit 1

# 补丁 4:zz_ohos 平台常量与钩子实现(openharmony build tag 隔离)
for f in common/dialer/zz_ohos_forcebind.go common/dialer/zz_ohos_forcebind_other.go route/zz_ohos_openharmony.go route/zz_ohos_other.go; do
  [ -f "$f" ] || cp "$ROOT/patches/zz-ohos/$f" "$f"
done
echo "==> sing-box OHOS patches verified"

# ---- A1. 依赖解析与 vendor(需要 >=1.25.5 工具链) ----
cd "$WRAPPER"
"$GO126" mod edit -replace "github.com/sagernet/sing-box=$SB"
"$GO126" mod edit -dropreplace github.com/sagernet/sing-tun 2>/dev/null || true
# Existing vendor metadata may reference a previous checkout. Force module mode
# while resolving and regenerating vendor so stale vendor/modules.txt is ignored.
GOFLAGS=-mod=mod "$GO126" mod download
SINGTUN_VER="$(GOFLAGS=-mod=mod "$GO126" list -m -f '{{.Version}}' github.com/sagernet/sing-tun)"
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
    # 测速导出的 V2 版本(见 AGENTS.md「测速导出的版本化约定」)。
    # 这两个名字必须逐个列出:版本脚本是白名单,漏了的话 dlsym 会静默失败,
    # NAPI 侧回退到 legacy,状态码判定与测速绕隧道就都没了,而且不报错。
    CGoTestStartSingBoxV2;
    CGoTestProxySingBoxV2;
    CGoCheckConfigV1;
    CGoValidateSRSFileV1;
    # K2 会话化测速(V3,带 sessionId;同样的白名单陷阱 —— 漏列即静默回退 unsupported)
    CGoTestStartSingBoxV3;
    CGoTestProxySingBoxV3;
    CGoTestStopSingBoxV3;
    CGoTestSessionInfoV3;
    CGoTestActiveSessionsV3;
    _cgoexp_*;
    crosscall2;
    runtime.*;
  local:
    *;
};
MAP
EXPORTS_FILE_WIN="$(cygpath -d "$EXPORTS_FILE")"

# Keep runtime registry aligned with generated selector configurations.
grep -qF 'group.RegisterSelector(outboundRegistry)' lean_context.go || { echo "ERROR: production wrapper lacks selector registration"; exit 1; }
# ConfigBuilder 会在 autoSelect 分组生成 type:"urltest" 的出站。注册表缺这个类型
# 不会编译报错,只会在真机开 VPN 时报 "unknown outbound type: urltest" —— 启动期
# 错误,只能靠这里的断言挡住。
grep -qF 'group.RegisterURLTest(outboundRegistry)' lean_context.go || { echo "ERROR: production wrapper lacks urltest group registration (autoSelect groups would fail to start)"; exit 1; }
# vendor/ 树是 checked-in 的,而 main.go 用的是 `-mod=vendor` 构建。
# 若 vendor 里还是未打补丁的 urltest(main.go 调 URLTestWithOptions),编译会报
# undefined。上面已跑过 go mod vendor,这里做一次 fail-closed 兜底断言,
# 避免在 vendor 刷新失败的机器上产出一个语义错误的 .so。
VENDOR_URLTEST="vendor/github.com/sagernet/sing-box/common/urltest/urltest.go"
if [ -f "$VENDOR_URLTEST" ]; then
  grep -q "func URLTestWithOptions" "$VENDOR_URLTEST" \
    || { echo "ERROR: vendored urltest is stale (no URLTestWithOptions) — re-run 'go mod vendor' in core/libsingbox14"; exit 1; }
fi
BUILD_TAGS="with_utls,with_clash_api,with_quic"
echo "==> build tags: $BUILD_TAGS"
rm -f "$OUT_DIR/libsingbox.so"
CGO_ENABLED=1 GOOS=openharmony GOARCH=arm64 \
CC="$CC_BIN" CXX="${CC_BIN/clang/clang++}" \
CGO_CFLAGS="${CGO_CFLAGS:--ftls-model=global-dynamic}" \
"$GO124" build -mod=vendor \
    -tags "$BUILD_TAGS" \
    -trimpath \
    -ldflags "-s -w -buildid= -X github.com/sagernet/sing-box/constant.Version=v1.14.0 -checklinkname=0 -linkmode external -extldflags '-Wl,--version-script=$EXPORTS_FILE_WIN -Wl,--gc-sections -Wl,-z,lazy'" \
    -buildmode=c-shared \
    -o "$OUT_DIR/libsingbox.so" .

# ---- 发布体积优化:移除非运行必需的静态符号,动态导出随后逐项校验 ----
SO="$OUT_DIR/libsingbox.so"
[ -f "$SO" ] || { echo "ERROR: no .so produced"; exit 1; }
STRIP="$SDK_NATIVE/llvm/bin/llvm-strip.exe"
[ -f "$STRIP" ] || STRIP="$SDK_NATIVE/llvm/bin/llvm-strip"
if [ -x "$STRIP" ] || [ -f "$STRIP" ]; then
  SIZE_BEFORE_STRIP=$(wc -c < "$SO")
  "$STRIP" --strip-all "$SO"
  SIZE_AFTER_STRIP=$(wc -c < "$SO")
  echo "==> llvm-strip: ${SIZE_BEFORE_STRIP} -> ${SIZE_AFTER_STRIP} bytes"
else
  echo "ERROR: llvm-strip not found in OHOS native SDK" >&2
  exit 1
fi

# ---- 构建后校验(全部 fail-closed;二进制用固定串匹配) ----
grep -aqF 'json:"override_destination,omitempty"' "$SO" || { echo "ERROR: .so lacks sniff override schema marker"; exit 1; }
grep -aqF "route subscribe" "$SO"     || { echo "ERROR: .so lacks sing-tun netlink patch marker"; exit 1; }
grep -aqF "SING_BOX_BIND_IFNAME" "$SO" || { echo "ERROR: .so lacks forcebind marker"; exit 1; }
grep -aqF "SING_BOX_TUN_FD" "$SO"     || { echo "ERROR: .so lacks tun-fd marker"; exit 1; }
# 补丁 7:URL Test 状态码校验 + HEAD→GET 回退(防"假绿")
grep -aqF "unexpected HTTP status" "$SO" || { echo "ERROR: .so lacks urltest status-acceptance marker"; exit 1; }
grep -aqF "1.14.0-ohos-inproc" "$SO"  || { echo "ERROR: .so lacks 1.14.0 version marker"; exit 1; }
grep -aqF "1.11.9" "$SO"              && { echo "ERROR: .so still contains 1.11.9 string"; exit 1; }
# 动态符号表须含 URL 测速导出(dlsym 依赖 .dynsym)
# 注意:不要把 readelf 直接管进 `grep -q`。grep -q 命中后立刻退出会关掉管道,
# llvm-readelf 随后报 "IO failure on output stream: Invalid argument" 并被杀,
# grep 反而什么都没读到 → 假阴性(符号明明在,却报 missing)。先落盘再 grep。
READELF="$SDK_NATIVE/llvm/bin/llvm-readelf.exe"
[ -f "$READELF" ] || READELF="$SDK_NATIVE/llvm/bin/llvm-readelf"
if [ -x "$READELF" ] || [ -f "$READELF" ]; then
  DYNSYM_DUMP="$WORK_DIR/dynsyms.txt"
  "$READELF" --dyn-syms "$SO" > "$DYNSYM_DUMP" 2>/dev/null
  # V2 导出必须真的在 .dynsym 里。版本脚本是白名单,漏列一个名字 dlsym 就静默
  # 失败,NAPI 回退 legacy 后状态码判定/绕隧道全部失效且不报错 —— 这类回归
  # 只有在真机上表现为"测速偏红"才发现,所以在这里 fail-closed。
  for sym in CGoTestStartSingBoxV2 CGoTestProxySingBoxV2; do
    grep -qw -- "$sym" "$DYNSYM_DUMP" || { echo "ERROR: .so missing $sym in .dynsym (check version script whitelist)"; exit 1; }
  done
  # legacy 也必须保留:NAPI 侧靠它兼容未重编的 .so
  for sym in CGoTestStartSingBox CGoTestProxySingBox CGoTestStopSingBox; do
    grep -qw -- "$sym" "$DYNSYM_DUMP" || { echo "ERROR: .so missing $sym (needed for old-.so fallback)"; exit 1; }
  done
  echo "==> dynsym check: V2 + legacy test exports present"
fi
echo "==> ALL verification markers passed in libsingbox.so"
ls -la "$OUT_DIR"
echo "==> done: $SO"
