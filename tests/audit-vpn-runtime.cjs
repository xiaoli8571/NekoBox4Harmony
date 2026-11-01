// Runtime regression tests load production ArkTS, not copied implementations.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:/Program Files/Huawei/DevEco Studio/sdk';
const ts = require('./lib/deveco-ts.cjs').loadTs();
if (ts === null) {
  console.log(`SKIP audit-vpn-runtime.cjs: 本机没有 DevEco Studio SDK(CI 环境),跳过 ArkTS 交叉核对`);
  process.exit(0);
}
function load(rel, imports, globals = {}) {
  const source = fs.readFileSync(path.join(root, rel), 'utf8');
  const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } });
  const exports = {};
  vm.runInNewContext(output.outputText, { exports, require(n) {
    if (n in imports) return imports[n];
    throw Error(`Unexpected import ${n}`);
  }, setTimeout, clearTimeout, console, ...globals }, { filename: rel });
  return exports;
}
function deferred() { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; }
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
const tests = [];
function test(name, fn) { tests.push([name, fn]); }
const meter = load('entry/src/main/ets/model/TrafficMeter.ets', {});
function extension() {
  const streams = [], totals = [], published = [], cancelled = [], agents = [], events = [];
  const imports = {};
  // The extension has platform-heavy dependencies. Each retained import is an explicit stub.
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/vpnext/VpnExtAbility.ets'), 'utf8');
  for (const match of source.matchAll(/from\s+['"]([^'"]+)['"]/g)) imports[match[1]] = {};
  imports['@kit.NetworkKit'] = { VpnExtensionAbility: class {} };
  imports['../model/Store'] = { LogStore: { addLog() {} }, setRunningProfileId: async () => {}, clearPendingProfileId: async () => {} };
  imports['../model/TrafficMeter'] = meter;
  imports['../model/TrafficBaseline'] = { parseBaseline: () => null, baselineStale: () => false, displayTotals: (u, d) => [u, d] };
  imports['../core/VpnIpc'] = { publishVpnTraffic: (...args) => events.push(args), unsubscribeVpnCommands() {} };
  imports['../utils/TrafficStats'] = { fetchTrafficTotals: () => { const d = deferred(); totals.push(d); return d.promise; } };
  imports['../utils/NotifyText'] = { formatUptimeText: ms => `${ms}ms` };
  imports['./TrafficStream'] = { TrafficStreamCallbacks: class {}, TrafficStream: class {
    constructor() { streams.push(this); this.stopped = false; }
    start(port, secret, cb) { this.cb = cb; }
    stop() { this.stopped = true; }
  } };
  imports['@ohos.app.ability.wantAgent'] = { default: { getWantAgent: () => { const d = deferred(); agents.push(d); return d.promise; }, OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 } } };
  imports['@ohos.notificationManager'] = { default: { publish: async r => { published.push(r); }, cancel: async id => cancelled.push(id) } };
  imports['@ohos.notification'] = { default: { ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 1 } } };
  const Ext = load('entry/src/main/ets/vpnext/VpnExtAbility.ets', imports, { $r: x => x }).default;
  const ext = new Ext();
  ext.context = { resourceManager: { getStringSync: x => x } };
  ext.started = true;
  ext.notificationSettings = { clashApiEnabled: true, clashApiPort: 1234, clashApiSecret: 'test', speedIntervalMs: 1000 };
  ext.loadNotificationBaseline = async () => null;
  return { ext, streams, totals, published, cancelled, agents, events };
}

test('traffic startup preserves session uptime', async () => {
  const { ext } = extension();
  ext.notificationStartedAt = 100;
  await ext.startTrafficStream();
  assert.equal(ext.notificationStartedAt, 100, 'initial stop must not erase the session clock');
  ext.stopTrafficStream();
});
test('stopping during baseline read cannot resurrect a stream', async () => {
  const { ext, streams } = extension();
  const read = deferred();
  ext.loadNotificationBaseline = () => read.promise;
  const start = ext.startTrafficStream();
  ext.stopTrafficStream();
  read.resolve(null);
  await start;
  assert.equal(streams.length, 0, 'stale startup must not allocate a socket');
});
test('overlapping startup cannot replace a newer stream', async () => {
  const { ext, streams } = extension();
  const old = deferred(); let calls = 0;
  ext.loadNotificationBaseline = () => ++calls === 1 ? old.promise : Promise.resolve(null);
  const first = ext.startTrafficStream();
  await ext.startTrafficStream();
  const active = ext.trafficStream;
  old.resolve(null); await first;
  assert.equal(streams.length, 1);
  assert.equal(ext.trafficStream, active);
  ext.stopTrafficStream(); assert.equal(active.stopped, true);
});
test('older reconnect snapshot cannot overwrite newer totals', async () => {
  const { ext, totals } = extension();
  await ext.startTrafficStream();
  const generation = ext.notificationGeneration;
  const old = ext.resyncTraffic(generation), current = ext.resyncTraffic(generation);
  totals[1].resolve({ up: 200, down: 400 }); await current;
  totals[0].resolve({ up: 100, down: 200 }); await old;
  assert.equal(ext.trafficMeter.up(), 200);
  assert.equal(ext.trafficMeter.down(), 400);
  ext.stopTrafficStream();
});
test('notification waiting for WantAgent cannot publish after stop', async () => {
  const { ext, agents, published } = extension();
  const pending = ext.showConnectedNotification();
  ext.stopTrafficStream(); ext.cancelNotification();
  agents[0].resolve({}); await pending;
  assert.equal(published.length, 0);
});

test('TrafficStream factory failure schedules bounded retry', async () => {
  const timers = new Map(), sockets = []; let id = 0, attempt = 0;
  const webSocket = { default: { createWebSocket() {
    if (++attempt === 1) throw Error('native factory unavailable');
    const s = { on() {}, close(cb) { cb(null); }, connect() {} }; sockets.push(s); return s;
  } } };
  const { TrafficStream, TrafficStreamCallbacks } = load('entry/src/main/ets/vpnext/TrafficStream.ets', {
    '@ohos.net.webSocket': webSocket, '../utils/ClashAuth': { clashApiHeaders: () => ({}) }, '../model/TrafficMeter': meter
  }, { setTimeout: (fn, ms) => { timers.set(++id, { fn, ms }); return id; }, clearTimeout: i => timers.delete(i) });
  const stream = new TrafficStream();
  assert.doesNotThrow(() => stream.start(1234, '', new TrafficStreamCallbacks()));
  assert.equal(timers.size, 1);
  const timer = [...timers.values()][0]; timers.clear(); assert.equal(timer.ms, 1000); timer.fn();
  assert.equal(sockets.length, 1);
  stream.stop(); assert.equal(timers.size, 0);
});
test('TrafficStream duplicate drops, backoff, stale callbacks and stop', async () => {
  const timers = new Map(), sockets = []; let id = 0;
  const { TrafficStream, TrafficStreamCallbacks } = load('entry/src/main/ets/vpnext/TrafficStream.ets', {
    '@ohos.net.webSocket': { default: { createWebSocket() {
      const handlers = {}; const s = { handlers, on: (k, cb) => handlers[k] = cb, close(cb) { cb(null); }, connect(url, opts, cb) { this.connectResult = cb; } }; sockets.push(s); return s;
    } } }, '../utils/ClashAuth': { clashApiHeaders: () => ({}) }, '../model/TrafficMeter': meter
  }, { setTimeout: (fn, ms) => { timers.set(++id, { fn, ms }); return id; }, clearTimeout: i => timers.delete(i) });
  const stream = new TrafficStream(), cb = new TrafficStreamCallbacks(); let delta = 0;
  cb.onDelta = u => delta += u;
  stream.start(1234, '', cb);
  sockets[0].handlers.error({ code: 1, message: 'drop' }); sockets[0].handlers.close(null); sockets[0].connectResult({ code: 1 });
  assert.equal(timers.size, 1);
  for (const delay of [1000, 2000, 4000, 8000, 10000, 10000]) {
    const timer = [...timers.values()][0]; timers.clear(); assert.equal(timer.ms, delay); timer.fn();
    sockets.at(-1).handlers.close(null);
  }
  sockets[0].handlers.message(null, '{"up":99,"down":0}'); assert.equal(delta, 0);
  stream.stop(); assert.equal(timers.size, 0);
  sockets.at(-1).handlers.close(null); assert.equal(timers.size, 0);
});

for (const kind of ['Events', 'Applied', 'Commands']) {
  test(`IPC ${kind}: pending creation after unsubscribe is retired`, async () => {
    const pending = [], subscribed = [], removed = [];
    const ipc = load('entry/src/main/ets/core/VpnIpc.ets', {
      '@ohos.commonEventManager': { default: {
        createSubscriber() { const d = deferred(); pending.push(d); return d.promise; },
        subscribe(s, cb) { subscribed.push({ s, cb }); }, unsubscribe(s, cb) { removed.push(s); if (cb) cb(null); }
      } }
    });
    ipc[`subscribeVpn${kind}`](() => {}, () => {}, () => {});
    ipc[`unsubscribeVpn${kind}`]();
    const stale = { id: 'stale' }; pending[0].resolve(stale); await flush();
    assert.equal(subscribed.length, 0);
    assert.ok(removed.includes(stale), 'createSubscriber allocated handle must be released');
  });
  test(`IPC ${kind}: replacement detaches old handle and suppresses old callback`, async () => {
    const subscribed = [], removed = []; let calls = 0, id = 0;
    const ipc = load('entry/src/main/ets/core/VpnIpc.ets', {
      '@ohos.commonEventManager': { default: {
        createSubscriber: async () => ({ id: ++id }), subscribe(s, cb) { subscribed.push({ s, cb }); },
        unsubscribe(s, cb) { removed.push(s); if (cb) cb(null); }
      } }
    });
    const args = kind === 'Events' ? [() => calls++, () => calls++, () => calls++] : [() => calls++];
    ipc[`subscribeVpn${kind}`](...args); await flush();
    ipc[`subscribeVpn${kind}`](...args); await flush();
    assert.ok(removed.includes(subscribed[0].s));
    const data = kind === 'Events' ? { event: ipc.VPN_EVENT_LOG, data: 'old' } :
      { data: JSON.stringify(kind === 'Applied' ? { ok: 'true' } : { cmd: 'query' }) };
    subscribed[0].cb(null, data); assert.equal(calls, 0);
    subscribed[1].cb(null, data); assert.equal(calls, 1);
    ipc[`unsubscribeVpn${kind}`]();
  });
}

(async () => {
  let failed = 0;
  for (const [name, fn] of tests) { try { await fn(); console.log(`PASS ${name}`); } catch (e) { failed++; console.error(`FAIL ${name}: ${e.stack}`); } }
  await flush();
  assert.equal(failed, 0, `${failed} runtime regression(s)`);
})().catch(e => { console.error(e); process.exitCode = 1; });
