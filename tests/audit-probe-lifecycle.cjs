// Independent production-code regression audit: no network, native execution, build or device.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:/Program Files/Huawei/DevEco Studio/sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));
function load(file, imports = {}, globals = {}) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true });
  assert.equal((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0, file);
  const exports = {};
  vm.runInNewContext(compiled.outputText, { exports, require(name) { assert.ok(name in imports, name); return imports[name]; }, setTimeout, clearTimeout, console, ...globals }, { filename: file });
  return exports;
}
const model = load('entry/src/main/ets/model/ProbeResult.ets');
const coordinator = load('entry/src/main/ets/core/ProbeCoordinator.ets', { '../model/ProbeResult': model });
const store = load('entry/src/main/ets/core/ProbeStore.ets', {
  '@ohos.file.fs': { default: {} }, '@ohos.app.ability.common': {},
  './SnapshotStore': { SnapshotStore: {} }, '../model/Store': { LogStore: { addLog() {} } }
});
const runner = load('entry/src/main/ets/core/ProbeRunner.ets', { '../model/ProbeResult': model, './ProbeCoordinator': coordinator, './ProbeStore': store });
const target = id => Object.assign(new coordinator.ProbeTarget(), { profileId: id, profileConfigHash: 'h-' + id });
const env = over => Object.assign(new coordinator.ProbeEnv(), { target: 'http://example.com/', concurrency: 1 }, over);
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
function harness(over = {}) {
  const calls = { starts: [], probes: [], stops: [], saves: [], caps: 0, tcp: 0 };
  const closed = new Set();
  const bridge = {
    async caps() { calls.caps++; return 'v3'; },
    async activeSessions() { return ''; },
    async startV3(sid, json) { calls.starts.push(sid); if (closed.has(sid)) return 'err:session cancelled during start'; return json.includes('bad') ? 'err:invalid bad outbound' : ''; },
    async stopV3(sid) { calls.stops.push(sid); closed.add(sid); return ''; },
    async sessionInfoV3(sid) { return JSON.stringify({ sessionId: sid, state: closed.has(sid) ? 'closed' : 'active' }); },
    async proxyV3(sid, tag) { calls.probes.push(tag); return '7'; },
    async start() { calls.starts.push('v2'); return ''; }, async stop() { calls.stops.push('v2'); return ''; }, async proxy(tag) { calls.probes.push(tag); return '7'; }
  };
  Object.assign(bridge, over.bridge);
  const deps = Object.assign(new runner.ProbeRunnerDeps(), {
    bridge,
    buildBatch(batch) { return Object.assign(new runner.ProbeBatchConfig(), { json: JSON.stringify(batch.map(t => t.profileId)), tags: batch.map(t => t.profileId) }); },
    writeConfig(json) { return json; },
    async saveRun(run) { calls.saves.push(run); return true; }, async markUnsaved() {},
    async tcpPing() { calls.tcp++; return Object.assign(new runner.ProbeTcpResult(), { ok: true, latencyMs: 8 }); }
  }, over.deps);
  const coord = new coordinator.ProbeCoordinator();
  const instance = new runner.ProbeRunner(coord, deps);
  return { calls, bridge, deps, coord, instance, run(ids = ['ok'], options = {}, environment = {}) { return instance.runProbeRound(ids.map(target), env(environment), Object.assign(new runner.ProbeRoundOptions(), options)); } };
}
const cases = [];
function test(name, fn) { cases.push([name, fn]); }
test('V3 tombstones do not poison healthy binary-isolation sub-batches', async () => {
  const h = harness();
  const out = await h.run(['good', 'bad']);
  assert.equal(out.results.find(r => r.profileId === 'good').state, 'success');
  assert.equal(out.results.find(r => r.profileId === 'bad').state, 'failed');
  assert.equal(new Set(h.calls.starts).size, h.calls.starts.length, 'every native start owns a fresh id');
});
test('different runner instances cannot steal a live process-wide native session', async () => {
  const pending = deferred();
  const h1 = harness({ bridge: { caps() { return pending.promise; } } });
  const h2 = harness();
  const first = h1.run();
  const second = await h2.run();
  pending.resolve('v3');
  await first;
  assert.equal(second.error, 'probe_busy');
  assert.equal(h2.calls.caps, 0, 'reject before any bridge work');
});
test('cancel during asynchronous capability discovery is not lost by begin', async () => {
  const pending = deferred();
  const h = harness({ bridge: { caps() { return pending.promise; } } });
  const run = h.run();
  h.instance.cancel();
  pending.resolve('v3');
  const out = await run;
  assert.equal(h.calls.starts.length, 0);
  assert.equal(out.summary.cancelled, 1);
});
test('round ownership includes asynchronous result persistence', async () => {
  const saving = deferred(), entered = deferred();
  let saves = 0;
  const h = harness({ deps: { saveRun() { saves++; entered.resolve(); return saves === 1 ? saving.promise : Promise.resolve(true); } } });
  const first = h.run(['first']);
  await entered.promise;
  const second = await h.run(['second']);
  saving.resolve(false);
  const out = await first;
  assert.equal(second.error, 'probe_busy');
  assert.equal(out.results[0].profileId, 'first');
  assert.equal(out.summary.unsaved, 1, 'failure summary follows unsaved state');
});
test('failed V2 pre-stop cannot launch over an unconfirmed singleton', async () => {
  const h = harness({ bridge: { async caps() { return 'v2'; }, async stop() { return 'err:still closing'; } } });
  const out = await h.run();
  assert.equal(h.calls.starts.length, 0);
  assert.equal(out.unfinished, 1);
});
test('failed stale V3 cleanup must prevent any new start', async () => {
  const h = harness({ bridge: { async activeSessions() { return 'old'; }, async stopV3() { return 'err:still active'; }, async sessionInfoV3() { return '{"state":"active","lastTag":"closed"}'; } } });
  const out = await h.run();
  assert.equal(h.calls.starts.length, 0);
  assert.equal(out.unfinished, 1);
});
test('onResult callback exception cannot leak session or wedge later rounds', async () => {
  const h = harness();
  const out = await h.run(['one'], { onResult() { throw Error('UI detached'); } });
  assert.equal(h.calls.stops.length, 1);
  assert.equal(out.summary.success, 1);
  const next = await h.run(['two']);
  assert.equal(next.summary.success, 1);
});
test('cancellation in running callback does not turn an untouched node into failed/TCP fallback', async () => {
  const h = harness();
  const out = await h.run(['one'], { allowTcpFallbackPerNode: true, onResult(r) { if (r.state === 'running') h.instance.cancel(); } });
  assert.equal(h.calls.probes.length, 0);
  assert.equal(h.calls.tcp, 0);
  assert.equal(out.summary.cancelled, 1);
});
test('target and environment are frozen before the first asynchronous bridge boundary', async () => {
  const pending = deferred();
  const h = harness({ bridge: { caps() { return pending.promise; } } });
  const targets = [target('original')], settings = env();
  const run = h.instance.runProbeRound(targets, settings, new runner.ProbeRoundOptions());
  targets[0].profileId = 'mutated'; settings.target = 'http://mutated.invalid/';
  pending.resolve('v3');
  const out = await run;
  assert.equal(out.results[0].profileId, 'original');
  assert.equal(out.results[0].target, 'http://example.com/');
});
test('bridge numeric prefix garbage is not reported as a valid latency', async () => {
  const h = harness({ bridge: { async proxyV3() { return '12ms-error'; } } });
  assert.equal((await h.run()).summary.failed, 1);
});
(async () => {
  let failed = 0;
  for (const [name, fn] of cases) {
    try { await fn(); console.log('PASS ' + name); }
    catch (e) { failed++; console.error('FAIL ' + name + '\n' + e.stack); }
  }
  assert.equal(failed, 0, `${failed}/${cases.length} lifecycle audit cases failed`);
  console.log(`audit-probe-lifecycle: ${cases.length} cases passed`);
})().catch(e => { console.error(e); process.exitCode = 1; });
