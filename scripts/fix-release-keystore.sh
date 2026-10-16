#!/usr/bin/env bash
# 修复签名材料:让密钥库里装的是华为发布证书,而不是本地自签证书。
#
# 背景(2026-09-27,AppGallery 审核退回的真实原因):
#   签名材料/NekoBox.p12 的别名 nekobox 里装的是一张自签证书
#   (CN=nekobox,有效期 25 年,无 AuthorityKeyIdentifier)。
#   而 NekoBoxRelease.p7b 要求的发布证书是华为签发的
#   (CN=某某(1830369220152569601)Release,有效期 3 年,签发者
#    Huawei CBG Developer Relations CA G2)。
#   两者指纹不同(F8:86:83:… vs 39:F5:63:…),所以 AppGallery 判定为
#   "debug 版本",违反《审核指南》3.5。
#
#   注意:hap-sign-tool verify-app 验签通过 不能证明用的是发布证书 ——
#   它只做结构与摘要校验,读到的证书链来自 profile。必须比对指纹。
#
# 关键点:两者的公钥是同一个(已核对 EC point 完全一致),也就是私钥是对的。
#   所以只要把发布证书导入密钥库替换掉自签证书,不需要重新申请证书。
#   签名材料/nekobox.csr 正是当初用这把私钥生成、送华为签发用的。
#
# 用法:bash scripts/fix-release-keystore.sh
# 产出:签名材料/NekoBox-release.p12(新文件,不改动原始 NekoBox.p12)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIG_DIR="$ROOT/签名材料"
SRC_P12="$SIG_DIR/NekoBox.p12"
OUT_P12="$SIG_DIR/NekoBox-release.p12"
CHAIN_CER="$SIG_DIR/NekoBox.cer"
ALIAS="${KEY_ALIAS:-nekobox}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say() { printf '\n==> %s\n' "$1"; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ -n "${SIGN_P12_PASS:-}" ] || die '请先设置 SIGN_P12_PASS=<密钥库密码>'
[ -f "$SRC_P12" ] || die "缺少 $SRC_P12"
[ -f "$CHAIN_CER" ] || die "缺少 $CHAIN_CER"
command -v keytool >/dev/null 2>&1 || die 'keytool 不在 PATH(把 DevEco 的 jbr/bin 加进来)'
command -v node   >/dev/null 2>&1 || die 'node 不在 PATH'

fingerprint() { # 打印某证书的 SHA256 指纹(去掉冒号,便于比对)
  keytool -printcert -file "$1" 2>/dev/null | tr -d '\r' \
    | awk '/SHA256:/{gsub(/[ \t:]/,"");print;exit}'
}

# ---------------------------------------------------------------- 1. 拆链
# NekoBox.cer 里是 3 张证书 PEM 串联,顺序为 根 / 中间 / 叶子(发布证书)。
# keytool -importcert 一次导入只取第一张当叶证书,所以必须按 叶子/中间/根 拆开。
say "1/4 拆分证书链"
node -e '
const fs = require("fs");
const raw = fs.readFileSync(process.argv[1], "utf8");
const pems = raw.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g) || [];
if (pems.length < 3) { console.error("只解析出 " + pems.length + " 张证书,预期 3 张"); process.exit(1); }
const out = process.argv[2];
for (const pair of [["root", pems[0]], ["inter", pems[1]], ["leaf", pems[2]]]) {
  fs.writeFileSync(out + "/" + pair[0] + ".cer", pair[1] + "\n");
}
console.log("  拆出 " + pems.length + " 张: root / inter / leaf");
' "$CHAIN_CER" "$WORK" || die '拆链失败'

# ---------------------------------------------------------------- 2. 校验公钥
# 两张证书的公钥(EC point)必须一致,否则不能只换证书 —— 那说明发布证书用的是
# 另一把私钥,必须回 AppGallery Connect 找回对应私钥。
say "2/4 确认私钥对应的就是发布证书"
keytool -exportcert -alias "$ALIAS" -keystore "$SRC_P12" -storetype PKCS12 \
  -storepass "$SIGN_P12_PASS" -file "$WORK/old-leaf.cer" 2>/dev/null \
  || die "读不出密钥库里别名 $ALIAS 的证书"
OLD_FP="$(fingerprint "$WORK/old-leaf.cer")"
NEW_FP="$(fingerprint "$WORK/leaf.cer")"
echo "  密钥库现有证书 : ${OLD_FP:-?}"
echo "  发布证书       : ${NEW_FP:-?}"
[ -n "$NEW_FP" ] || die '解析不出发布证书指纹'
[ "$OLD_FP" != "$NEW_FP" ] || die '密钥库里已经是发布证书,无需修复'

node -e '
const fs = require("fs");
const crypto = require("crypto");
// 输入可能是 DER(keytool -exportcert)或 PEM(拆出来的 .cer),先统一成 DER,
// 否则在 PEM 文本里扫 65 字节窗口根本扫不到 EC 点。
const der = (p) => {
  const b = fs.readFileSync(p);
  const s = b.toString("utf8");
  if (s.indexOf("-----BEGIN CERTIFICATE-----") < 0) return b;
  const m = s.match(/-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----/);
  return Buffer.from(m[1].replace(/\s+/g, ""), "base64");
};
const points = (p) => {
  const d = der(p);
  const out = [];
  for (let i = 0; i + 65 <= d.length; i++) {
    if (d[i] === 0x04) out.push(d.subarray(i, i + 65).toString("hex"));
  }
  return out;
};
const a = points(process.argv[1]);
const b = points(process.argv[2]);
const hit = a.filter(x => b.indexOf(x) >= 0);
if (hit.length === 0) {
  console.error("公钥不同(keystore " + a.length + " 点 / release " + b.length + " 点)");
  process.exit(1);
}
console.log("  公钥一致 OK,可以只换证书、不换私钥");
' "$WORK/old-leaf.cer" "$WORK/leaf.cer" \
  || die '两张证书公钥不同 —— 发布私钥不在该密钥库里,需回 AppGallery Connect 找回'

# ---------------------------------------------------------------- 3. 换证书
say "3/4 把发布证书装进密钥库(新文件,不改原始 p12)"
cp "$SRC_P12" "$OUT_P12"
# -J-Duser.language=en:Git Bash 下 keytool 用系统 GBK 代码页输出会抛
# "无法响应中间命令"(java.lang.Exception),强制英文 locale 即可。
KT="keytool -J-Duser.language=en -J-Duser.country=US"
# 顺序很重要:先根、再中间、最后叶子。keytool -importcert 会尝试为被导入的证书
# 建立链(默认去 AIA/CA 源取),华为的中间 CA 在本机取不到,直接导叶子会报
# "Failed to establish chain from reply"。先把两级 CA 作为 trustedCert 装进去,
# 导叶子时链就能在本地凑齐。
$KT -importcert -alias chain-root -file "$WORK/root.cer" \
  -keystore "$OUT_P12" -storetype PKCS12 -storepass "$SIGN_P12_PASS" -noprompt \
  || die '导入根证书失败'
$KT -importcert -alias chain-inter -file "$WORK/inter.cer" \
  -keystore "$OUT_P12" -storetype PKCS12 -storepass "$SIGN_P12_PASS" -noprompt -trustcacerts \
  || die '导入中间证书失败'
# -importcert 覆盖该别名的证书,私钥保持不变(别名没变)。
$KT -importcert -alias "$ALIAS" -file "$WORK/leaf.cer" \
  -keystore "$OUT_P12" -storetype PKCS12 -storepass "$SIGN_P12_PASS" -noprompt -trustcacerts \
  || die '导入发布证书失败'

keytool -exportcert -alias "$ALIAS" -keystore "$OUT_P12" -storetype PKCS12 \
  -storepass "$SIGN_P12_PASS" -file "$WORK/new-leaf.cer" 2>/dev/null
NEW_AFTER="$(fingerprint "$WORK/new-leaf.cer")"
echo "  替换后别名 $ALIAS 指纹: $NEW_AFTER"
[ "$NEW_AFTER" = "$NEW_FP" ] || die "替换后指纹仍不匹配(得到 ${NEW_AFTER:-?})"

say "4/4 完成"
echo "发布版密钥库: $OUT_P12"
echo "签名时:-keystoreFile 传本文件,-appCertFile 仍传 $CHAIN_CER(整条链)。"
