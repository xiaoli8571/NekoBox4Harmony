// 权限一致性校验:保证「包内声明的权限」与「隐私政策里写的权限」逐条相同。
//
// 为什么要有这条:AGC 审核会拿软件包的 user_grant 权限和隐私政策里声明的权限做对比,
// 任何一侧多出来就退回 —— 2026-10-23 真实退回原文:
//   「检测到当前软件包 user_grant 类型的权限与隐私政策中声明的权限不一致…只在隐私政策中的权限:
//     [READ_PASTEBOARD]」,原因是 2.1.11 保活整改把 READ_PASTEBOARD 从 module.json5 删了,
//   而隐私政策一直保留它(2.1.10 及以前包内也有,所以那时能过审)。
//
// 校验项:
//   1) module.json5 里 requestPermissions 的权限集合 == docs/PRIVACY-POLICY.md 里出现的权限集合
//   2) module.json5 注释里出现的示例权限不算声明(避免注释里的 MANAGE_VPN 被误判)
//   3) 与 SDK PermissionDefinitions.json 交叉核对:user_grant 的权限必须在政策表格里标成 user_grant
//   4) 「只在政策里」与「只在包里」两个方向都为 0
const fs = require('fs');
const path = require('path');

const repo = path.resolve(__dirname, '..');
let failures = 0;
function check(name, ok, detail) {
  if (ok) {
    console.log(`PASS ${name}`);
  } else {
    failures++;
    console.log(`FAIL ${name}${detail ? ' :: ' + detail : ''}`);
  }
}

/** 去掉 // 行注释(module.json5 用 //,没有块注释) */
function stripLineComments(src) {
  return src
    .split('\n')
    .map((line) => {
      let out = '';
      let inStr = false;
      for (let i = 0; i < line.length; i++) {
        const ch = line[i];
        if (ch === '"' && line[i - 1] !== '\\') inStr = !inStr;
        if (!inStr && ch === '/' && line[i + 1] === '/') break;
        out += ch;
      }
      return out;
    })
    .join('\n');
}

const modPath = path.join(repo, 'entry/src/main/module.json5');
const raw = fs.readFileSync(modPath, 'utf8');
const clean = stripLineComments(raw);

// 只取 requestPermissions 数组内部的 name
const start = clean.indexOf('"requestPermissions"');
check('module.json5 有 requestPermissions 段', start >= 0);
const tail = clean.slice(start);
const declared = [...tail.matchAll(/"name"\s*:\s*"(ohos\.permission\.[A-Z0-9_]+)"/g)].map((m) => m[1]);
const declaredSet = [...new Set(declared)].sort();

check('包内声明了权限(非空)', declaredSet.length > 0, `共 ${declaredSet.length} 项`);
check(
  '注释里的示例权限未被当成声明',
  !declaredSet.includes('ohos.permission.MANAGE_VPN'),
  'module.json5 注释里有 MANAGE_VPN 示例,不应计入'
);

const policyPath = path.join(repo, 'docs/PRIVACY-POLICY.md');
const policySrc = fs.readFileSync(policyPath, 'utf8');
const policySet = [...new Set([...policySrc.matchAll(/ohos\.permission\.[A-Z0-9_]+/g)].map((m) => m[0]))].sort();

const onlyInPackage = declaredSet.filter((p) => !policySet.includes(p));
const onlyInPolicy = policySet.filter((p) => !declaredSet.includes(p));
check('包内多出、政策没写的权限为 0', onlyInPackage.length === 0, onlyInPackage.join(','));
check('政策写了、包内没声明的权限为 0', onlyInPolicy.length === 0, onlyInPolicy.join(','));

// 与 SDK 权限定义交叉核对 user_grant / availableLevel
let sdkOk = true;
let grantInfo = {};
try {
  const sdkRoot = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
  const defPath = path.join(sdkRoot, 'default/openharmony/toolchains/lib/PermissionDefinitions.json');
  const defs = JSON.parse(fs.readFileSync(defPath, 'utf8'));
  const items = defs.definePermissions || defs.permissions || [];
  for (const it of items) {
    if (declaredSet.includes(it.name)) grantInfo[it.name] = { grantMode: it.grantMode, level: it.availableLevel };
  }
} catch (e) {
  sdkOk = false;
  console.log(`SKIP SDK 权限定义不可读(${e.message}),已跳过 grantMode 交叉核对`);
}
if (sdkOk) {
  const userGrant = Object.keys(grantInfo).filter((k) => grantInfo[k].grantMode === 'user_grant');
  const markedInDoc = [...policySrc.matchAll(/\|\s*`(ohos\.permission\.[A-Z0-9_]+)`\s*\|\s*\*\*user_grant\*\*/g)].map(
    (m) => m[1]
  );
  const missingMark = userGrant.filter((p) => !markedInDoc.includes(p));
  check(
    'user_grant 权限在政策表格里被标记为 user_grant',
    missingMark.length === 0,
    `未标记:${missingMark.join(',')}`
  );
  const sysBasic = Object.keys(grantInfo).filter((k) => grantInfo[k].level === 'system_basic');
  check(
    'system_basic 权限必须有 AGC 已放行的 ACL(当前仅剪贴板)',
    sysBasic.every((p) => p === 'ohos.permission.READ_PASTEBOARD'),
    `发现:${sysBasic.join(',')}`
  );
  console.log('   权限明细: ' + Object.keys(grantInfo).sort().map((k) => `${k}(${grantInfo[k].grantMode}/${grantInfo[k].level})`).join(', '));
}

if (failures > 0) {
  console.log(`\n${failures} 项失败`);
  process.exit(1);
}
console.log('\nALL permission-policy tests passed');
