// 版本一致性守卫:发布前必须让“代码里的版本”和“文档里的当前版本”同源。
//
// 背景:2.6.0 发布时仓库里同时存在 1.5.8(README)、1.9.0(AGENTS)、
// 2.4.0(HANDOFF/DEVPLAN)、2.6.0(AppScope) 四种“当前版本”,接手的人
// 很容易按错版本做发布检查。这个测试只读文件,不依赖 SDK/设备。
//
// 约定:每个文件保留自己的“当前版本”标题格式,测试只断言这四处与 app.json5 一致。
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

function read(rel) {
  return fs.readFileSync(path.join(repo, rel), 'utf8');
}

const app = read('AppScope/app.json5');
const versionName = (app.match(/"versionName"\s*:\s*"([^"]+)"/) || [])[1];
const versionCode = (app.match(/"versionCode"\s*:\s*(\d+)/) || [])[1];
check('AppScope/app.json5 能读到 versionName/versionCode', versionName !== undefined && versionCode !== undefined,
  `versionName=${versionName} versionCode=${versionCode}`);

const rootPkg = JSON.parse(read('oh-package.json5'));
const entryPkg = JSON.parse(read('entry/oh-package.json5'));
const testPkg = JSON.parse(read('package.json'));
check('测试入口 package.json 版本与 app.json5 一致', testPkg.version === versionName,
  `package=${testPkg.version} app=${versionName}`);
check('根 oh-package.json5 版本与 app.json5 一致', rootPkg.version === versionName,
  `root=${rootPkg.version} app=${versionName}`);
check('entry oh-package.json5 版本与 app.json5 一致', entryPkg.version === versionName,
  `entry=${entryPkg.version} app=${versionName}`);

// versionCode 编码规则:major*1000000 + minor*100000 + patch
if (versionName !== undefined) {
  const parts = versionName.split('.').map((x) => parseInt(x, 10));
  if (parts.length === 3 && parts.every((x) => !isNaN(x))) {
    const expected = parts[0] * 1000000 + parts[1] * 100000 + parts[2];
    check('versionCode 符合 major*1000000+minor*100000+patch', String(expected) === versionCode,
      `expected=${expected} actual=${versionCode}`);
  }
}

const docs = [
  { file: 'README.md', re: /## 功能特性\(v([0-9]+\.[0-9]+\.[0-9]+)\)/ },
  { file: 'AGENTS.md', re: /## 当前状态\(v([0-9]+\.[0-9]+\.[0-9]+)/ },
  { file: 'HANDOFF.md', re: /> \*\*[0-9-]+ 版本 ([0-9]+\.[0-9]+\.[0-9]+)\*\*/ },
  { file: 'DEVPLAN.md', re: /## 版本 ([0-9]+\.[0-9]+\.[0-9]+) 发布打包/ }
];
for (const doc of docs) {
  const src = read(doc.file);
  const m = src.match(doc.re);
  check(`${doc.file} 的当前版本标题与 app.json5 一致`, m !== null && m[1] === versionName,
    m === null ? '未找到当前版本标题' : `${doc.file}=${m[1]} app=${versionName}`);
}

// 内核版本字符串由 tests/kernel-version.cjs 守;这里只防 README 又写回旧内核。
const readme = read('README.md');
check('README 的当前内核描述不再是 1.11.9',
  !/基于 \*\*sing-box v?1\.11\.9/.test(readme) && !/内核插件 \| sing-box 1\.11\.9/.test(readme));

if (failures > 0) {
  console.log(`\n${failures} 项失败`);
  process.exit(1);
}
console.log('\nALL version-consistency tests passed');
