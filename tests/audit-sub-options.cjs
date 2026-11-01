// 订阅「更新后处理」三开关:自动测试结果写回 / 删无效 / 按延迟排序(生产模块直接跑)
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:/Program Files/Huawei/DevEco Studio/sdk';
const ts = require('./lib/deveco-ts.cjs').loadTs();
if (ts === null) {
  console.log(`SKIP audit-sub-options.cjs: 本机没有 DevEco Studio SDK(CI 环境),跳过 ArkTS 交叉核对`);
  process.exit(0);
}
function load(file, imports = {}) {
  const exports = {};
  const js = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  vm.runInNewContext(js, { exports, Map, Set, Date, console, require: n => { if (!(n in imports)) throw Error(n); return imports[n]; } });
  return exports;
}
const profile = load('entry/src/main/ets/model/Profile.ets');
const mod = load('entry/src/main/ets/core/SubPostUpdate.ets', { '../model/Profile': profile });
const { Profile } = profile;
function mk(id, subUrl, status = 0, latencyMs = -1) {
  const p = new Profile();
  p.id = id; p.name = id; p.subUrl = subUrl; p.status = status; p.latencyMs = latencyMs;
  p.ping = latencyMs; p.latencyTestedAt = 0;
  return p;
}
function outcome(id, status, ping) {
  const o = new mod.SubTestOutcome();
  o.id = id; o.status = status; o.ping = ping; o.error = status === 1 ? '' : 'timeout';
  return o;
}

// 1. 结果写回:只动被测过的节点,失败节点 latencyMs 置 -1 并打时间戳
const nodes = [mk('a', 'S'), mk('b', 'S'), mk('c', 'S')];
const outcomes = new Map([['a', outcome('a', 1, 42)], ['b', outcome('b', 2, 0)]]);
assert.equal(mod.applyOutcomes(nodes, outcomes), 2, 'untested node must not be written');
assert.equal(nodes[0].status, 1); assert.equal(nodes[0].latencyMs, 42); assert.ok(nodes[0].latencyTestedAt > 0);
assert.equal(nodes[1].status, 2); assert.equal(nodes[1].latencyMs, -1); assert.equal(nodes[1].error, 'timeout');
assert.equal(nodes[2].status, 0, 'node without outcome keeps untouched state');
console.log('PASS applyOutcomes writes only tested nodes and keeps untested state');

// 2. 无效节点 = status>=2;未测(0)绝不删除
assert.equal(JSON.stringify(mod.invalidNodes(nodes).map(p => p.id)), JSON.stringify(['b']));
assert.equal(JSON.stringify(mod.invalidNodes([mk('x', 'S', 0)]).map(p => p.id)), JSON.stringify([]));
console.log('PASS invalidNodes only treats failed status as invalid');

// 3. 排序:可用按延迟升序且稳定,失败/未测排在后面并保持原相对顺序
const mixed = [mk('slow', 'S', 1, 300), mk('untested', 'S', 0), mk('fast', 'S', 1, 30),
  mk('bad', 'S', 2, -1), mk('mid', 'S', 1, 120), mk('fast2', 'S', 1, 30)];
assert.equal(JSON.stringify(mod.sortByLatency(mixed).map(p => p.id)), JSON.stringify(['fast', 'fast2', 'mid', 'slow', 'untested', 'bad']));
assert.deepEqual(mod.sortByLatency([]).length, 0);
console.log('PASS sortByLatency orders by latency, keeps ties and failures stable');

// 4. 放回原位:其他订阅/手动分组顺序不变;被删节点不占位;多出的追加不丢
const all = [mk('m1', 'M'), mk('s1', 'S'), mk('m2', 'M'), mk('s2', 'S'), mk('s3', 'S'), mk('m3', 'M')];
const merged = mod.spliceSubscription(all, 'S', [mk('s1', 'S'), mk('s3', 'S')]);
assert.equal(JSON.stringify(merged.map(p => p.id)), JSON.stringify(['m1', 's1', 'm2', 's3', 'm3']),
  'deleted node must be removed, others keep order');
const grown = mod.spliceSubscription(all, 'S', [mk('s1', 'S'), mk('s2', 'S'), mk('s3', 'S'), mk('s4', 'S')]);
assert.equal(JSON.stringify(grown.map(p => p.id)), JSON.stringify(['m1', 's1', 'm2', 's2', 's3', 'm3', 's4']),
  'extra nodes append, never silently dropped');
console.log('PASS spliceSubscription preserves other groups and never drops nodes');

// 5. 开关持久化:schema 读回三个字段并拒绝非布尔值(脏数据回退 false)
const subs = fs.readFileSync(path.join(root, 'entry/src/main/ets/core/Subscriptions.ets'), 'utf8');
for (const key of ['autoTestAfterUpdate', 'deleteInvalidAfterTest', 'sortAfterTest']) {
  assert.ok(subs.includes(`item.${key} = source.${key} === true;`), `${key} must be read with strict boolean coercion`);
  assert.ok(subs.includes(`s.${key} = changes['${key}'] === true;`), `${key} must be writable via saveSubSettings`);
  assert.ok(subs.includes(`${key}: boolean = false;`), `${key} must default to false`);
}
console.log('PASS three switches persist with strict boolean coercion and default off');
