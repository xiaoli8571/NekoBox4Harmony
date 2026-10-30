// 主机测试:诊断包组装与脱敏(P5/W20,§10.5)
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));

function load(file) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const js = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(js, { exports, require: () => { throw new Error('no imports expected'); } });
  return exports;
}
const LogView = load('entry/src/main/ets/model/LogView.ets');
// Diagnostics imports redactLogText from '../model/LogView' — 提供真实模块
// (重新加载一份注入,与上面 LogView 同实现)
const D2 = (function () {
  const source = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'entry/src/main/ets/core/Diagnostics.ets'), 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
  const exports2 = {};
  vm.runInNewContext(js, { exports: exports2, require: (n) => { if (n === '../model/LogView') return LogView; throw new Error('unexpected ' + n); } });
  return exports2;
})();
const NOW = 1729752000000;

// ---------- 1. 结构:全部元数据键 + 缺省「未知」 ----------
{
  const input = new D2.DiagnosticsInput();
  input.appVersion = '2.2.0';
  input.versionCode = 2200000;
  input.kernelVersion = '1.15.0-alpha.13-ohos-inproc';
  input.kernelCapability = 'v3';
  input.sdkApiLevel = 24;
  input.savedRevision = 12;
  input.runningRevision = 11;
  input.applyState = 'idle saved=12 applied=11';
  input.errorCategory = 'subscription';
  input.subscriptionCount = 3;
  input.profileCount = 128;
  input.probeParams = 'url http://cp.cloudflare.com/ timeout=5000 c=5';
  input.probeSummary = 'success=40 failed=3 cancelled=0';
  input.logTail = '[vpn] started';
  const text = D2.buildDiagnosticsPackage(input, NOW);
  const parsed = JSON.parse(text);
  assert.equal(parsed.schema, 'nekobox-diagnostics-1');
  assert.equal(parsed.appVersion, '2.2.0');
  assert.equal(parsed.kernelCapability, 'v3');
  assert.equal(parsed.savedRevision, 12);
  assert.equal(parsed.runningRevision, 11);
  assert.equal(parsed.subscriptionCount, 3);
  assert.ok(parsed.logTail.includes('[vpn] started'));
  assert.ok(D2.diagnosticsLooksSafe(text));
  // 缺省字段 → 未知,不猜
  const empty = new D2.DiagnosticsInput();
  const emptyText = D2.buildDiagnosticsPackage(empty, NOW);
  const emptyParsed = JSON.parse(emptyText);
  assert.equal(emptyParsed.appVersion, '未知');
  assert.equal(emptyParsed.kernelVersion, '未知');
  assert.equal(emptyParsed.runningRevision, 0);
  assert.ok(D2.diagnosticsLooksSafe(emptyText));
  console.log('PASS 诊断结构:元数据齐、缺省=未知、JSON 可解析');
}

// ---------- 2. 脱敏:日志里的订阅 URL/token/密码不出现在包内 ----------
{
  const input = new D2.DiagnosticsInput();
  input.appVersion = '2.2.0';
  input.logTail = [
    '[sub] 更新 https://airport.example/api?token=supersecret123 失败',
    '[sub] 订阅 https://user:pass123@sub.example/link 成功',
    '[config] password="hunter2secret" 已应用'
  ].join('\n');
  const text = D2.buildDiagnosticsPackage(input, NOW);
  assert.ok(!text.includes('supersecret123'), 'token 不得泄露');
  assert.ok(!text.includes('pass123'), 'URL 凭据不得泄露');
  assert.ok(!text.includes('hunter2secret'), '密码不得泄露');
  assert.ok(text.includes('ab****23') || text.includes('****'), '打码痕迹存在');
  assert.ok(D2.diagnosticsLooksSafe(text));
  // 自检函数:手工塞入未脱敏凭据 → 不安全
  assert.equal(D2.diagnosticsLooksSafe('{"appVersion":"x","logTail":"https://a:b@h/"}'), false);
  console.log('PASS 诊断脱敏:token/凭据/密码全部打码,自检函数有效');
}

// ---------- 3. 日志尾部截断(上限行数) ----------
{
  const input = new D2.DiagnosticsInput();
  input.logTailLines = 5;
  const lines = [];
  for (let i = 0; i < 100; i++) {
    lines.push(`line-${i}`);
  }
  input.logTail = lines.join('\n');
  const parsed = JSON.parse(D2.buildDiagnosticsPackage(input, NOW));
  const tail = parsed.logTail.split('\n');
  assert.equal(tail.length, 5);
  assert.equal(tail[0], 'line-95');
  assert.equal(tail[4], 'line-99');
  console.log('PASS 诊断日志:仅保留尾部 N 行');
}

console.log('diagnostics: ALL PASS');
