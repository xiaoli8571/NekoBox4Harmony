// 仓库卫生守卫:防止“本机签名配置/证书路径”再次被提交。
//
// 背景(2026-10-31):AGENTS.md 一直写“仓库基线 signingConfigs: []、签名段不要提交”,
// 但 build-profile.json5 从初始提交起就带着 C:\Users\Administrator\.ohos\... 的证书路径
// 和加密后的 key/store password。新机器克隆后构建会直接失败,和“克隆即可构建”承诺冲突。
//
// 这个测试只做静态检查,不读私钥、不访问网络:
//   1) build-profile.json5 的 signingConfigs 必须是空数组;
//   2) 入库的构建配置里不得出现本机绝对路径 / 密码字段;
//   3) git 跟踪列表里不得出现签名材料(*.p12/*.p7b/*.cer/*.csr);
//   4) .gitignore 必须继续挡住签名材料。
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

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

const profile = read('build-profile.json5');
const signingEmpty = /"signingConfigs"\s*:\s*\[\s*\]/.test(profile);
check('build-profile.json5 的 signingConfigs 为空(仓库基线)', signingEmpty,
  '请运行 node scripts/inject-signing.js --profile build-profile.json5 --reset');

check('build-profile.json5 不含本机绝对路径', !/[A-Za-z]:\\\\Users\\\\|[A-Za-z]:\\Users\\/.test(profile),
  '发现 C:\\Users\\... 之类的本机证书路径');
check('build-profile.json5 不含 keyPassword/storePassword',
  !/keyPassword|storePassword/.test(profile), '签名密码字段不得入库');
check('build-profile.json5 不含 certpath/profile/storeFile',
  !/certpath|storeFile|"profile"\s*:/.test(profile), '签名材料路径不得入库');

// 其他可能被 hvigor 读取的构建配置也一起守(存在才检查)
for (const rel of ['entry/build-profile.json5', 'hvigor/hvigor-config.json5']) {
  if (!fs.existsSync(path.join(repo, rel))) {
    continue;
  }
  const src = read(rel);
  check(`${rel} 不含签名密码/证书路径`,
    !/keyPassword|storePassword|certpath|storeFile|[A-Za-z]:\\\\Users\\\\/.test(src), '发现本机签名痕迹');
}

// 签名材料不得被 git 跟踪。CI 没有 git 时跳过这一项。
let tracked = [];
try {
  tracked = execFileSync('git', ['ls-files'], { cwd: repo, encoding: 'utf8' })
    .split(/\r?\n/).filter((line) => line.length > 0);
  const bad = tracked.filter((f) => /\.(p12|p7b|cer|csr)$/i.test(f));
  check('git 未跟踪签名材料(.p12/.p7b/.cer/.csr)', bad.length === 0, bad.join(', '));
} catch (e) {
  console.log('SKIP git 不可用,跳过“跟踪列表”检查');
}

const ignore = read('.gitignore');
for (const pattern of ['*.p12', '*.p7b', '*.cer', '*.csr', '签名材料/']) {
  check(`.gitignore 继续挡住 ${pattern}`, ignore.includes(pattern));
}

// 文件同步工具(OneDrive/Synology Drive 之类)的“冲突副本”不得留在源码树里。
// 2026-11-02 事故:它们落进 entry/src/main/resources/**,restool 直接报
// 11203001 "Failed to open the JSON file ... Illegal byte sequence",assembleApp 构建失败。
const SKIP_DIRS = new Set(['.git', 'node_modules', 'oh_modules', '.hvigor', 'build']);
const conflicts = [];
(function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP_DIRS.has(entry.name)) {
      continue;
    }
    const full = path.join(dir, entry.name);
    if (entry.name.includes('冲突副本')) {
      conflicts.push(path.relative(repo, full));
      continue;
    }
    if (entry.isDirectory()) {
      walk(full);
    }
  }
})(repo);
check('源码树里没有同步工具的“冲突副本”', conflicts.length === 0,
  '先移到仓库外再构建: ' + conflicts.slice(0, 5).join(', '));

// AGC 上架包门禁:2026-11-02 传 *-unsigned.app 到 AGC 得到 991「非法软件包」。
// 上传前必须跑 scripts/verify-upload-package.ps1(外层 .app + 内层 HAP 双层 verify-app)。
check('scripts/verify-upload-package.ps1 存在(AGC 991 门禁)',
  fs.existsSync(path.join(repo, 'scripts/verify-upload-package.ps1')));
check('package.json 挂上 check:app', /"check:app"\s*:/.test(read('package.json')),
  'npm run check:app 是上传 AGC 前的唯一门禁');

if (failures > 0) {
  console.log(`\n${failures} 项失败`);
  process.exit(1);
}
console.log('\nALL repo-hygiene tests passed');
