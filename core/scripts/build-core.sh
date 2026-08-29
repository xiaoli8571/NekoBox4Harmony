#!/usr/bin/env bash
#
# Build the sing-box 1.4 core binary for OpenHarmony (arm64 + optional x86_64
# emulator), then copy it into the app's rawfile resources.
#
# The core is compiled as a fully static linux/arm64 Go binary (CGO disabled):
# it talks to the Linux kernel directly via syscalls, so it runs inside the
# OpenHarmony app sandbox without needing any libc.  The TUN file descriptor
# obtained from @ohos.net.vpnExtension is injected at runtime through the
# SING_BOX_TUN_FD environment variable (see patches/001-tun-fd-env.patch).
#
# Usage (Git Bash on Windows / any bash):
#   bash core/scripts/build-core.sh
# Env overrides:
#   SINGBOX_TAG   sing-box git tag to build (default v1.4.6)
#   GO_TOOLCHAIN  Go toolchain to force, e.g. go1.21.13 (recommended:
#                 quic-go of the 1.4 era refuses very new Go compilers)
#
set -euo pipefail

SINGBOX_TAG="${SINGBOX_TAG:-v1.4.6}"
GO_TOOLCHAIN="${GO_TOOLCHAIN:-go1.21.13}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/sing-box"
DIST="$ROOT/dist"
ENTRY_RAWFILE="$ROOT/../entry/src/main/resources/rawfile"

if [ -z "${SINGBOX_TAG// }" ]; then SINGBOX_TAG="v1.4.6"; fi
echo "==> sing-box tag: $SINGBOX_TAG"

# ---------------------------------------------------------------- clone
if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch "$SINGBOX_TAG" \
        https://github.com/SagerNet/sing-box.git "$SRC"
fi
cd "$SRC"

# ---------------------------------------------------------------- patch
if ! grep -q "SING_BOX_TUN_FD" inbound/tun.go; then
    echo "==> applying tun-fd patch"
    git apply "$ROOT/patches/001-tun-fd-env.patch"
else
    echo "==> tun-fd patch already applied"
fi

# ---------------------------------------------------------------- build
export GOTOOLCHAIN="$GO_TOOLCHAIN"
BUILD_TAGS="with_gvisor,with_quic,with_utls,with_wireguard,with_clash_api"
LDFLAGS="-s -w -X github.com/sagernet/sing-box/constant.Version=${SINGBOX_TAG}-ohos -X github.com/sagernet/sing-box/constant.CommitId=ohos"

mkdir -p "$DIST"

echo "==> building sing-box for linux/arm64 (runs on OpenHarmony devices)"
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build -trimpath -ldflags "$LDFLAGS" -tags "$BUILD_TAGS" \
    -o "$DIST/sing-box-arm64" ./cmd/sing-box

echo "==> building sing-box for linux/amd64 (optional, for emulator images)"
if CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags "$LDFLAGS" -tags "$BUILD_TAGS" \
    -o "$DIST/sing-box-amd64" ./cmd/sing-box; then
    echo "    amd64 OK"
else
    echo "    amd64 build failed (non-fatal, arm64 binary is what ships)"
fi

ls -la "$DIST"

# ---------------------------------------------------------------- install
mkdir -p "$ENTRY_RAWFILE"
cp -f "$DIST/sing-box-arm64" "$ENTRY_RAWFILE/sing-box-arm64"
if [ -f "$DIST/sing-box-amd64" ]; then
    cp -f "$DIST/sing-box-amd64" "$ENTRY_RAWFILE/sing-box-amd64"
fi
echo "==> core binary copied to $ENTRY_RAWFILE"
echo "==> done. Now open the project in DevEco Studio, sync, sign and run."
