// 全量 Node 测试入口:逐个跑 tests/*.cjs,汇总失败并以非零码退出。
//
// 为什么需要它:仓库有 48 个 .cjs,但没有 package.json/CI,发布前只能人工
// 一个个跑;只要漏跑一个,回归就没有门禁。这里排除两类“生成器”脚本
// (它们不是测试,且 geo-srs.cjs 依赖 GitHub API,CI 上会 403)。
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const EXCLUDED = new Set(['run-all.cjs', 'generate-dns-fixtures.cjs', 'geo-srs.cjs']);

const only = process.argv.slice(2).filter((arg) => !arg.startsWith('-'));
const files = fs.readdirSync(__dirname)
  .filter((name) => name.endsWith('.cjs') && !EXCLUDED.has(name))
  .filter((name) => only.length === 0 || only.some((token) => name.includes(token)))
  .sort();

if (files.length === 0) {
  console.error('没有匹配的测试文件');
  process.exit(1);
}

const startedAt = Date.now();
const failed = [];
const skippedByEnv = [];

for (const file of files) {
  const full = path.join(__dirname, file);
  process.stdout.write(`\n===== ${file} =====\n`);
  const result = spawnSync(process.execPath, [full], {
    cwd: ROOT,
    stdio: 'inherit',
    env: process.env
  });
  if (result.error !== undefined && result.error !== null) {
    failed.push(`${file}(spawn:${result.error.message})`);
    continue;
  }
  if (result.status !== 0) {
    failed.push(file);
  }
}

const seconds = ((Date.now() - startedAt) / 1000).toFixed(1);
console.log(`\n========================================`);
console.log(`Node suites: ${files.length} run, ${files.length - failed.length} passed, ${failed.length} failed (${seconds}s)`);
if (skippedByEnv.length > 0) {
  console.log(`环境跳过: ${skippedByEnv.join(', ')}`);
}
if (failed.length > 0) {
  console.log(`失败: ${failed.join(', ')}`);
  process.exit(1);
}
console.log('ALL Node suites passed');
