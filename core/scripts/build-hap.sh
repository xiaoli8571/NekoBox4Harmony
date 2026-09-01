#!/usr/bin/env bash
# NekoBox4Harmony 统一打包脚本 —— 每次出 HAP 前全量清理构建缓存。
#
# 背景(坑 #14/#15):hvigor 的 entry/build intermediates 会缓存旧 .so,
# 内核重编后如果不清缓存,HAP 里打的仍是旧内核 —— 1.6.3 断网复发就是这么来的。
# 用法:bash core/scripts/build-hap.sh [版本号,如 1.6.3]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"    # vpn/
cd "$ROOT"

VERSION="${1:-}"

echo "==> [1/5] 清理构建缓存(entry/build)"
# ⚠️ 以下目录绝对不能清(踩过的坑):
#  - ~/.hvigor/project_caches/<sha256(cwd)>/workspace:wrapper 自举区(@ohos/hvigor 以
#    file: 依赖装在里面),删了 pnpm install 会静默失败("No stdout output")
#  - oh_modules / 工程根 .hvigor:同属自举链路
# 污染 .so 进包的只有 entry/build intermediates,清它就够 + 第 4 步 md5 校验兜底。
rm -rf entry/build

echo "==> [2/5] 校验内核 .so 新鲜度(与 sing-box 源码对比)"
SO=entry/libs/arm64-v8a/libsingbox.so
if [ ! -f "$SO" ]; then
    echo "ERROR: $SO 不存在,先跑 core/scripts/build-libsingbox-ohos.sh" >&2
    exit 1
fi
NEWEST_SRC="$(find core/sing-box-1.13.21 core/sing-box-1.13.12 core/sing-box-1.11 core/libsingbox14 -name '*.go' -newer "$SO" 2>/dev/null | head -1 || true)"
if [ -n "$NEWEST_SRC" ]; then
    echo "ERROR: 内核源码比 .so 新($NEWEST_SRC),请先重跑内核构建脚本" >&2
    exit 1
fi
echo "    .so 是最新的($(stat -c '%y' "$SO"))"

echo "==> [3/5] assembleHap(全量构建)"
DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk' \
    node hvigorw.js --mode module -p product=default assembleHap --no-daemon

echo "==> [4/5] 校验 HAP 内 .so 与源一致(strip 感知)"
# hvigor 打包会对 .so 执行 llvm-strip(去符号表),md5 必然变化。
# 正确校验:把源 .so 手工 strip 一遍再比,而不是拿 strip 前后互比(曾因此误判)。
HAP=entry/build/default/outputs/default/entry-default-unsigned.hap
TMP="$(mktemp -d)"
unzip -o -q "$HAP" "libs/arm64-v8a/libsingbox.so" -d "$TMP"
HAP_MD5="$(md5sum "$TMP/libs/arm64-v8a/libsingbox.so" | cut -d' ' -f1)"
SRC_MD5="$(md5sum "$SO" | cut -d' ' -f1)"
STRIP='/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native/llvm/bin/llvm-strip.exe'
"$STRIP" -o "$TMP/stripped-src.so" "$SO"
STRIPPED_MD5="$(md5sum "$TMP/stripped-src.so" | cut -d' ' -f1)"
rm -rf "$TMP"
if [ "$HAP_MD5" != "$SRC_MD5" ] && [ "$HAP_MD5" != "$STRIPPED_MD5" ]; then
    echo "ERROR: HAP 内 .so($HAP_MD5)与源($SRC_MD5 / strip后 $STRIPPED_MD5)均不一致!禁止交付" >&2
    exit 1
fi
echo "    .so 一致(hap=$HAP_MD5, strip后=$STRIPPED_MD5)"

echo "==> [5/5] 交付到 dist"
mkdir -p dist
if [ -n "$VERSION" ]; then
    cp "$HAP" "dist/NekoBox4Harmony-${VERSION}-unsigned.hap"
    echo "==> 完成: dist/NekoBox4Harmony-${VERSION}-unsigned.hap"
else
    cp "$HAP" dist/entry-default-unsigned.hap
    echo "==> 完成: dist/entry-default-unsigned.hap(未命名版本,建议带版本号调用)"
fi
