#!/usr/bin/env bash
# NekoBox4Harmony — 一键:重编内核 → assembleHap → 签名
#
# 用法(Git Bash / DevEco 自带终端):
#   SIGN_P12_PASS='<密钥库密码>' bash scripts/build-and-sign.sh
#
# 密码不写进脚本、不写进 build-profile.json5、不提交仓库 —— 只从环境变量取。
# 这是 AGENTS.md 里明确要求的:旧版本文档曾把明文密码提交到 GitHub main。
#
# 前置:
#   0) 一次性构建两套 Go 工具链(见 AGENTS.md「构建方法」第 0 步)
#   1) 签名材料放在 <repo>/签名材料/{NekoBox.p12, NekoBox.cer, NekoBoxRelease.p7b}
#
# 重要:每次都重编内核。不要跳第一步 —— HAP 里内嵌的是 .so 副本,
# 改了 core/sing-box-1.14 或 core/libsingbox14 而不重编,打出来的包是旧的。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-C:\Program Files\Huawei\DevEco Studio\sdk}"
DEVECO_SDK_HOME_WIN="$(cygpath -w "$DEVECO_SDK_HOME" 2>/dev/null || echo "$DEVECO_SDK_HOME")"
GO126="${GO126:-/c/Program Files/Go/bin/go}"
VERSION="$(sed -n 's/.*"versionName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' AppScope/app.json5 | head -1)"
# 签名材料**不入库**(含私钥),两个可能的位置,按顺序探测:
#   A) <repo>/签名材料/        —— 旧的本仓库专用材料(NekoBox*.p12/cer/p7b)
#   B) C:/Worker/AGC通用证书/  —— 多个项目共用的 AGC 发布材料(General.p12/cer + NekoBoxRelease.p7b)
# 本机实测只有 B;早期文档只写了 A,导致脚本找不到材料。
SIG_DIR="$ROOT/签名材料"
DEFAULT_ALIAS="nekobox"
if [ ! -f "$SIG_DIR/NekoBox.p12" ] && [ ! -f "$SIG_DIR/NekoBox-release.p12" ]; then
  for cand in "/c/Worker/AGC通用证书" "/c/Worker/AGC通用证书/material"; do
    if [ -f "$cand/General.p12" ]; then SIG_DIR="$cand"; DEFAULT_ALIAS="general"; break; fi
  done
fi
# 优先用"装了华为发布证书"的密钥库(由 scripts/fix-release-keystore.sh 生成)。
# 原始 NekoBox.p12 里装的是自签证书 CN=nekobox,不是发布证书。
if [ -f "$SIG_DIR/General.p12" ]; then
  P12="$SIG_DIR/General.p12"
  CER="$SIG_DIR/General.cer"
  [ -f "$CER" ] || CER="$(ls "$SIG_DIR"/*.cer 2>/dev/null | head -1)"
  P7B="$SIG_DIR/NekoBoxRelease.p7b"
else
  P12="$SIG_DIR/NekoBox-release.p12"
  [ -f "$P12" ] || P12="$SIG_DIR/NekoBox.p12"
  CER="$SIG_DIR/NekoBox.cer"
  P7B="$SIG_DIR/NekoBoxRelease.p7b"
fi
echo "签名材料目录: $SIG_DIR (默认别名 $DEFAULT_ALIAS)"

say() { printf '\n==> %s\n' "$1"; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ -n "${SIGN_P12_PASS:-}" ] || die '请先设置 SIGN_P12_PASS=<密钥库密码>(不要写进脚本)'
for f in "$P12" "$CER" "$P7B"; do
  [ -f "$f" ] || die "缺少签名材料: $f"
done
[ -n "$VERSION" ] || die '读不到 AppScope/app.json5 的 versionName'
command -v node >/dev/null 2>&1 || die 'node 不在 PATH'
command -v java  >/dev/null 2>&1 || die 'java 不在 PATH(把 DevEco 的 jbr/bin 加进 PATH)'

# ---------------------------------------------------------------- 1. 内核
say "1/4 重编 sing-box 内核 (libsingbox.so)"
GO126="$GO126" bash core/scripts/build-libsingbox-ohos.sh
[ -f entry/libs/arm64-v8a/libsingbox.so ] || die '内核构建没有产出 libsingbox.so'
echo "内核 OK: $(wc -c < entry/libs/arm64-v8a/libsingbox.so) bytes"

# ---------------------------------------------------------------- 2. 打包
# 刻意**不**改 build-profile.json5:让 hvigor 出未签名 HAP,再用 hap-sign-tool 签。
# 理由:签名段一旦写进 build-profile.json5 就成了"本地修改",容易被误提交
# (AGENTS.md 记过这个坑:本机证书路径曾被提交到 GitHub main)。
# 全程不碰任何入库文件,更安全。scripts/inject-signing.js 保留给需要走
# DevEco「自动签名」那条路的人。
#
# ⚠️ 必须带 `-p buildMode=release`。漏掉时 hvigor 按 debug 产出,产物 module.json
# 里是 "buildMode":"debug" + "debug":true —— 签名再正确 AppGallery 也判定
# "经检测为debug版本"退回(《审核指南》3.5,2026-09-27 踩过)。
# buildModeSet 已在 build-profile.json5 里声明好,这一步只是选它。
say "2/3 assembleHap(release 模式,未签名)"
DEVECO_SDK_HOME="$DEVECO_SDK_HOME_WIN" \
  node hvigorw.js --mode module -p product=default -p buildMode=release assembleHap --no-daemon
HAP="entry/build/default/outputs/default/entry-default-unsigned.hap"
[ -f "$HAP" ] || die "没有产出 HAP: $HAP"

# ---------------------------------------------------------------- 3. 签名
say "3/3 签名并收集产物"
SIGN_TOOL=""
for c in "$DEVECO_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar" \
         "$DEVECO_SDK_HOME/java/hap-sign-tool.jar" \
         "/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"; do
  [ -f "$c" ] && { SIGN_TOOL="$c"; break; }
done
[ -n "$SIGN_TOOL" ] || die "找不到 hap-sign-tool.jar(上面几个候选是实测路径)"

# 密钥别名以 keytool -list 实际输出为准,不要按文件名猜。
# 实测:NekoBox.p12 的别名是 nekobox(全小写);AGC通用证书/General.p12 的别名是 general。
KEY_ALIAS="${KEY_ALIAS:-$DEFAULT_ALIAS}"
if command -v keytool >/dev/null 2>&1; then
  ALIASES="$(keytool -list -keystore "$P12" -storetype PKCS12 -storepass "$SIGN_P12_PASS" 2>/dev/null \
    | iconv -f GBK -t UTF-8 2>/dev/null | sed -n 's/^别名: *//p' | head -5)"
  if [ -n "$ALIASES" ]; then
    echo "密钥库别名: $(echo "$ALIASES" | tr '\n' ' ')"
    echo "$ALIASES" | grep -qx -- "$KEY_ALIAS" \
      || die "keyAlias '$KEY_ALIAS' 不在密钥库里;用 KEY_ALIAS=<别名> 指定(上面那行就是候选)"
  fi
fi

OUT_DIR="$ROOT/dist"
mkdir -p "$OUT_DIR"
SIGNED="$OUT_DIR/NekoBox-$VERSION-signed.hap"
cp "$HAP" "$SIGNED"
java -jar "$SIGN_TOOL" sign-app \
  -keyAlias "$KEY_ALIAS" \
  -signAlg SHA256withECDSA \
  -mode localSign \
  -appCertFile "$CER" \
  -profileFile "$P7B" \
  -inFile "$SIGNED" \
  -keystoreFile "$P12" \
  -keystorePwd "$SIGN_P12_PASS" \
  -keyPwd "$SIGN_P12_PASS" \
  -outFile "$SIGNED" \
  || die '签名失败(检查 SIGN_P12_PASS / KEY_ALIAS 是否正确)'

# verify-app 必须同时给 -outCertChain 和 -outProfile,少一个报 11011008
java -jar "$SIGN_TOOL" verify-app \
  -inFile "$SIGNED" \
  -outCertChain "$OUT_DIR/outCertChain-$VERSION.cer" \
  -outProfile "$OUT_DIR/outProfile-$VERSION.p7b" \
  || die '验签失败'

# 收尾断言:HAP 内嵌的 .so 必须与刚编出的一致。
# 否则就是"改了内核但忘了重打包" —— 这个坑项目里踩过一次(AGENTS.md 有记)。
HAP_TMP="$(mktemp -d)"
if command -v unzip >/dev/null 2>&1 && ( cd "$HAP_TMP" && unzip -o -q "$SIGNED" 'libs/arm64-v8a/libsingbox.so' ) \
   && [ -f "$HAP_TMP/libs/arm64-v8a/libsingbox.so" ]; then
  a="$(sha256sum "$HAP_TMP/libs/arm64-v8a/libsingbox.so" | cut -d' ' -f1)"
  b="$(sha256sum entry/libs/arm64-v8a/libsingbox.so | cut -d' ' -f1)"
  [ "$a" = "$b" ] || die "HAP 里的 libsingbox.so 与刚编出来的不一致($a != $b)—— HAP 没重新打包?"
  echo "HAP 内核一致性 OK (sha256 $a)"
else
  echo "WARN: 未能校验 HAP 内嵌内核(缺 unzip?);请自行确认已重新打包"
fi
rm -rf "$HAP_TMP"

say "完成"
ls -la "$SIGNED"
echo "产物: $SIGNED"
echo "安装前确认 AppScope/app.json5 的 versionCode 已高于设备上已装版本(否则装不上)"
