// 主机测试:流量曲线模型与测速换算(P 模型,无 I/O)
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

const T = load('entry/src/main/ets/core/TrafficChart.ets');

// vm 里加载的数组是另一个 realm 的 Array,deepStrictEqual 会因原型不同而失败,
// 这里统一按 JSON 比较(元素都是数字/字符串,足够严格)。
function same(actual, expected) {
  assert.equal(JSON.stringify(Array.from(actual)), JSON.stringify(expected));
}

// ---------- 1. 环形缓冲 ----------
{
  const s = new T.TrafficSeries(3);
  same(s.values, []);
  assert.equal(s.latest(), 0, '空序列 latest 为 0');
  assert.equal(s.max(), 0);
  assert.equal(s.avg(), 0);

  s.push(100);
  s.push(200);
  s.push(300);
  same(s.values, [100, 200, 300]);
  s.push(400);
  same(s.values, [200, 300, 400], '满容量从头部丢弃');
  assert.equal(s.latest(), 400);
  assert.equal(s.max(), 400);
  assert.equal(s.avg(), 300);

  s.push(-5);
  s.push(NaN);
  same(s.values, [400, 0, 0], '负数/NaN 归零,不污染坐标');
  s.push(Infinity);
  same(s.values, [0, 0, 0], 'Infinity 归零');

  s.reset();
  same(s.values, []);
  console.log('PASS TrafficSeries: 容量/丢弃/非法值归零/reset');
}

// ---------- 2. fill 补空 ----------
{
  const s = new T.TrafficSeries(5);
  s.fill(3);
  same(s.values, [], '空序列 fill 无副作用');
  s.push(7);
  s.fill(2);
  same(s.values, [7, 7, 7], '按最后一个值补齐');
  s.fill(99);
  assert.equal(s.values.length, 5, '补齐不超过容量');
  same(s.values, [7, 7, 7, 7, 7]);
  console.log('PASS fill: 定时器挂起后补齐不超容量');
}

// ---------- 3. padded 右对齐 ----------
{
  const s = new T.TrafficSeries(4);
  s.push(1);
  s.push(2);
  same(s.padded(), [0, 0, 1, 2], '新数据贴右');
  const empty = new T.TrafficSeries(3);
  same(empty.padded(), [0, 0, 0]);
  console.log('PASS padded: 右对齐补零');
}

// ---------- 4. niceMax ----------
{
  assert.equal(T.niceMax(0), 1);
  assert.equal(T.niceMax(-1), 1);
  assert.equal(T.niceMax(NaN), 1);
  assert.equal(T.niceMax(0.4), 0.5, '0.4 → 0.5');
  assert.equal(T.niceMax(1), 1);
  assert.equal(T.niceMax(1.2), 2);
  assert.equal(T.niceMax(3), 5);
  assert.equal(T.niceMax(7), 10);
  assert.equal(T.niceMax(1234), 2000);
  assert.ok(T.niceMax(1234) >= 1234, '上限不小于峰值');
  assert.equal(T.niceMax(1000000), 1000000);
  console.log('PASS niceMax: 1/2/5 × 10^n');
}

// ---------- 5. normalize / barHeight ----------
{
  same(T.normalize([0, 5, 10], 10), [0, 0.5, 1]);
  same(T.normalize([0, 5], 0), [0, 1], '上限为 0 时按 1 处理并截断');
  same(T.normalize([-1, 20], 10), [0, 1], '越界截断到 1');

  assert.equal(T.barHeight(0, 10, 90), 0);
  assert.equal(T.barHeight(5, 10, 90), 45);
  assert.equal(T.barHeight(10, 10, 90), 90);
  assert.equal(T.barHeight(0.001, 10, 90), 1, '有流量至少 1px');
  assert.equal(T.barHeight(5, 0, 90), 90, '上限 0 视为满格');
  assert.equal(T.barHeight(5, 10, 0), 0, '轨道高 0 返回 0');
  console.log('PASS normalize/barHeight');
}

// ---------- 6. 测速换算 ----------
{
  assert.equal(T.computeMbps(0, 1000), 0);
  assert.equal(T.computeMbps(1000, 0), 0);
  assert.equal(T.computeMbps(1250000, 1000), 10, '1.25MB/s = 10Mbps');
  assert.equal(T.computeMbps(10000000, 2000), 40);
  assert.equal(T.computeMbps(10 * 1024 * 1024, 8000) > 10.4, true, '10MB/8s ≈ 10.5Mbps');

  assert.equal(T.formatMbps(0), '0');
  assert.equal(T.formatMbps(-1), '0');
  assert.equal(T.formatMbps(0.04), '0.04');
  assert.equal(T.formatMbps(0.456), '0.46');
  assert.equal(T.formatMbps(1.234), '1.2');
  assert.equal(T.formatMbps(9.99), '10.0');
  assert.equal(T.formatMbps(10.4), '10');
  assert.equal(T.formatMbps(123.6), '124');
  console.log('PASS computeMbps/formatMbps');
}

// ---------- 7. 档位 ----------
{
  assert.equal(T.speedVerdict(0), T.SPEED_SLOW);
  assert.equal(T.speedVerdict(2), T.SPEED_SLOW, '边界 2 仍算慢');
  assert.equal(T.speedVerdict(2.1), T.SPEED_FAIR);
  assert.equal(T.speedVerdict(9.9), T.SPEED_FAIR);
  assert.equal(T.speedVerdict(10), T.SPEED_GOOD);
  assert.equal(T.speedVerdict(29.9), T.SPEED_GOOD);
  assert.equal(T.speedVerdict(30), T.SPEED_FAST);
  console.log('PASS speedVerdict: 2/10/30 分档');
}

// ---------- 8. 会话累计 ----------
{
  const t = new T.TrafficTotals();
  assert.equal(t.up, 0);
  t.add(100, 200);
  t.add(50, 1000);
  assert.equal(t.up, 150);
  assert.equal(t.down, 1200);
  assert.equal(t.peakUp, 100);
  assert.equal(t.peakDown, 1000);
  t.add(-5, NaN);
  assert.equal(t.up, 150, '非法值不加');
  t.reset();
  assert.equal(t.up + t.down + t.peakUp + t.peakDown, 0);
  console.log('PASS TrafficTotals: 累计/峰值/清零');
}

console.log('\nALL traffic-chart checks passed');
