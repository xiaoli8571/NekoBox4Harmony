#!/usr/bin/env bash
# 一次性构建 OpenHarmony 官方 Go fork 工具链(GOOS=openharmony 支持)。
# 参考 Hey 项目 docs/harmonyos-go-tls-wall.md:只有该 fork(TLSDESC)编译出的
# c-shared Go 库能被 HarmonyOS(musl) dlopen 且外来线程 cgo 正常。
#
# 用法: bash core/scripts/build-ohos-toolchain.sh
# 产物: ~/ohos-go-build/ohos_golang_go(可用 OHOS_GO_FORK 覆盖路径)
set -euo pipefail

FORK_DIR="${OHOS_GO_FORK:-$HOME/ohos-go-build/ohos_golang_go}"
FORK_URL="${OHOS_GO_FORK_URL:-https://gitcode.com/openharmony-sig/ohos_golang_go.git}"

if [ -x "$FORK_DIR/bin/go" ] || [ -f "$FORK_DIR/bin/go.exe" ]; then
    echo "==> OHOS Go fork already built at $FORK_DIR"
    exit 0
fi

mkdir -p "$(dirname "$FORK_DIR")"
if [ ! -d "$FORK_DIR/.git" ]; then
    echo "==> cloning OHOS Go fork: $FORK_URL"
    rm -rf "$FORK_DIR"
    git clone --depth 1 --branch release-branch.go1.24 "$FORK_URL" "$FORK_DIR"
fi

# 引导工具链 = 本机已安装的 Go
BOOTSTRAP="$(go env GOROOT)"
export GOROOT_BOOTSTRAP="$BOOTSTRAP"
export GOTOOLCHAIN=local
echo "==> bootstrap GOROOT: $BOOTSTRAP"

cd "$FORK_DIR/src"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "==> building toolchain with make.bat (Windows)"
        cmd //c make.bat
        ;;
    *)
        echo "==> building toolchain with make.bash"
        ./make.bash
        ;;
esac

echo "==> done. go binary at: $FORK_DIR/bin/go"
"$FORK_DIR/bin/go" version
