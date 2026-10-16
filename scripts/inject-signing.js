// 向 build-profile.json5 注入本地签名段(幂等)。
//
// 为什么需要这个脚本:hvigor 的签名配置写在 build-profile.json5 里,而这个文件
// 是入库的。按 AGENTS.md 的约定,仓库基线必须保持 "signingConfigs": [],
// 签名段只能存在于本地工作副本、且不得提交。本脚本负责"写入/还原"这一个动作,
// 避免每次手工改 JSON 改错结构。
//
// 用法:
//   node scripts/inject-signing.js --profile build-profile.json5 \
//     --store <NekoBox.p12> --cert <NekoBox.cer> --p7b <NekoBoxRelease.p7b> \
//     --bundle com.nekobox.app.jynxen
//   node scripts/inject-signing.js --profile build-profile.json5 --reset
//
// 注意:build-profile.json5 是 json5(允许注释与尾逗号),不能用 JSON.parse。

const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith('--')) {
      continue;
    }
    const key = argv[i].slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) {
      out[key] = true;
    } else {
      out[key] = next;
      i++;
    }
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
const profilePath = args.profile || 'build-profile.json5';

if (!fs.existsSync(profilePath)) {
  console.error(`ERROR: 找不到 ${profilePath}`);
  process.exit(1);
}

// 幂等处理:按**行**剥掉上一轮注入的块,再按行定位 "signingConfigs" 那一行。
//
// 为什么不用正则:`"signingConfigs"\s*:\s*\[[\s\S]*?\]` 这种非贪婪匹配在
// 注入过的文件上会连同 `"products"` 一起吃掉或留下孤立逗号,实测把
// build-profile.json5 改坏成 `"00305004 Syntax Error: invalid character ','`。
// JSON5 里的嵌套数组让正则不可靠,这里改成行级处理,行为可预测。
const beginMark = '// __SIGNING_BEGIN__';
const endMark = '// __SIGNING_END__';

let lines = fs.readFileSync(profilePath, 'utf8').split(/\r?\n/);

function stripInjectedBlock() {
  const b = lines.findIndex((l) => l.includes(beginMark));
  if (b < 0) return;
  const e = lines.findIndex((l, i) => i > b && l.includes(endMark));
  if (e < 0) return;
  // 原地换回空签名段,而不是整段删掉 —— 整段删掉的话后面就找不到可替换的锚点,
  // 会报"找不到 signingConfigs 字段"。
  lines.splice(b, e - b + 1, '    "signingConfigs": [],');
}
stripInjectedBlock();

// 找到 signingConfigs 所在行(注入后可能是多行,先删到配平的 "]")
function removeSigningConfigs() {
  const i = lines.findIndex((l) => /"signingConfigs"\s*:/.test(l));
  if (i < 0) return false;
  let j = i;
  let depth = 0;
  for (; j < lines.length; j++) {
    for (const ch of lines[j]) {
      if (ch === '[') depth++;
      else if (ch === ']') depth--;
    }
    if (depth === 0) break;
  }
  lines.splice(i, j - i + 1, '    "signingConfigs": [],');
  return true;
}
removeSigningConfigs();

if (args.reset) {
  fs.writeFileSync(profilePath, lines.join('\n'), 'utf8');
  console.log(`已重置 ${profilePath} 为无签名基线`);
  process.exit(0);
}

// bundle 只是历史遗留参数(以前用来校验 bundleName),签名段里已用不到;
// 传了也接受,不传不报错。
const required = ['store', 'cert', 'p7b'];
for (const key of required) {
  if (!args[key] || args[key] === true) {
    console.error(`ERROR: 缺少 --${key}`);
    process.exit(1);
  }
  if (!fs.existsSync(args[key])) {
    console.error(`ERROR: 找不到 ${key} 文件: ${args[key]}`);
    process.exit(1);
  }
}

// 注意:build-profile.json5 是 JSON5,反斜杠在字符串里是转义符。
// 直接把 C:\path\to\file 塞进去会报
// "00305004 Syntax Error / JSON5: invalid character",因为 \U \p \t 都被
// 当成转义序列。所以这里必须先把反斜杠自己转义成 \\。
const toWin = (p) => path.resolve(p).replace(/\\/g, '\\\\');
// schema(hvigor 5.x,实测 00303038 校验规则):
//   signingConfigs[i] 只允许 name / material / type 三个键 —— 顶层放 certpath
//   会报 "propertyNames: property name must be valid";
//   certpath 是 **material 里的必填项**;
//   type 的枚举是 'HarmonyOS' | 'OpenHarmony',表示"平台",**不是**构建模式。
const block = `${beginMark}
    "signingConfigs": [
      {
        "name": "default",
        "type": "HarmonyOS",
        "material": {
          "storeFile": "${toWin(args.store)}",
          "storePassword": "${process.env.SIGN_P12_PASS || ''}",
          "keyAlias": "${args.alias || 'nekobox'}",
          "keyPassword": "${process.env.SIGN_P12_PASS || ''}",
          "signAlg": "SHA256withECDSA",
          "profile": "${toWin(args.p7b)}",
          "certpath": "${toWin(args.cert)}"
        }
      }
    ],
    ${endMark}`;

// 重新插到 signingConfigs 那一行(该行此刻已被还原成空数组)
const target = lines.findIndex((l) => /"signingConfigs"\s*:/.test(l));
if (target < 0) {
  console.error('ERROR: build-profile.json5 里找不到 "signingConfigs" 字段');
  process.exit(1);
}
lines.splice(target, 1, block);

fs.writeFileSync(profilePath, lines.join('\n'), 'utf8');
console.log(`已注入签名段到 ${profilePath}`);
if (!process.env.SIGN_P12_PASS) {
  console.warn('WARN: SIGN_P12_PASS 未设置,写入的是空密码;请带上环境变量重跑');
}
console.warn('提醒:该文件现在是本地修改,不要提交(见 AGENTS.md「注意事项」)');
