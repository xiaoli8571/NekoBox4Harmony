// P1 单流量生产者:/traffic 增量帧解析 + 内核累计口径累加器。
//
// 背景:旧实现 UI 与 :vpn 扩展各开一个 1s 定时器 GET /connections 并解析整份
// 连接列表;新实现由扩展消费内核 /traffic WebSocket(每帧 {"up":d,"down":d})。
// 这里锁死两件事:
//   1) 坏帧(缺字段/负数/非数字/非 JSON)必须返回 null,不能把垃圾累加进总量;
//   2) 增量累加后与 /connections 的 uploadTotal/downloadTotal 同口径,
//      「清除流量统计」的基准语义才不会漂。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts = require(path.join(sdk,
  'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));

const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/model/TrafficMeter.ets'), 'utf8');
const js = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText;
const mod = {};
vm.runInNewContext(js, { exports: mod });

const { parseTrafficDelta, TrafficMeter } = mod;

assert.equal(JSON.stringify(parseTrafficDelta('{"up":11,"down":22}')), '{"up":11,"down":22}');
assert.equal(JSON.stringify(parseTrafficDelta('{"up":0,"down":0}')), '{"up":0,"down":0}',
  '空闲帧也是合法样本(0/0)');
console.log('PASS /traffic 增量帧解析');

for (const bad of ['', 'not json', '{}', '{"up":1}', '{"up":-1,"down":2}', '{"up":"x","down":2}',
  '{"up":1,"down":null}', '{ "up": 1e999, "down": 2 }']) {
  assert.equal(parseTrafficDelta(bad), null, `坏帧必须丢弃: ${bad}`);
}
console.log('PASS 坏帧/负增量/非数字一律丢弃');

const meter = new TrafficMeter();
assert.equal(meter.up(), 0);
assert.equal(meter.down(), 0);
meter.reset(100, 200);
assert.equal(meter.up(), 100, 'reset 用 /connections 快照对齐内核累计值');
assert.equal(meter.down(), 200);
meter.add({ up: 10, down: 20 });
meter.add({ up: 0, down: 0 });
meter.add({ up: 5, down: 7 });
assert.equal(meter.up(), 115, '增量累加后与 uploadTotal 同口径');
assert.equal(meter.down(), 227, '增量累加后与 downloadTotal 同口径');
meter.reset(0, 0);
assert.equal(meter.up(), 0, '内核重启/会话重连可重新对齐');
console.log('PASS 累计口径与 /connections 一致');

console.log('\nALL traffic-meter checks passed');
