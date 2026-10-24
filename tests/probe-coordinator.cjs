// ProbeResult model + ProbeCoordinator decision-logic tests (P2/W09, plan §6.2-§6.6).
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));

function load(file, imports = {}) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
  const exports = {};
  vm.runInNewContext(js, { exports, require: (n) => { if (!(n in imports)) throw Error(n); return imports[n]; } });
  return exports;
}

const model = load('entry/src/main/ets/model/ProbeResult.ets');
const coordMod = load('entry/src/main/ets/core/ProbeCoordinator.ets', {
  '../model/ProbeResult': model
});
const { ProbeCoordinator, ProbeTarget, ProbeEnv } = coordMod;

const mkTarget = (id, hash = 'pf-1', chain = '') => {
  const t = new ProbeTarget();
  t.profileId = id;
  t.profileName = `节点${id}`;
  t.profileConfigHash = hash;
  t.chainKey = chain;
  return t;
};

const mkResult = (runId, profileId, state, latencyMs = -1, extra = {}) => {
  const r = new model.ProbeResult();
  r.runId = runId;
  r.profileId = profileId;
  r.state = state;
  r.latencyMs = latencyMs;
  r.methodRequested = model.PROBE_METHOD_HTTP;
  r.methodActual = model.PROBE_METHOD_HTTP;
  r.path = model.PROBE_PATH_DIRECT_BOUND;
  r.completedAt = 1000;
  Object.assign(r, extra);
  return r;
};

const mkEnv = () => {
  const e = new ProbeEnv();
  e.method = model.PROBE_METHOD_HTTP;
  e.target = 'http://cp.cloudflare.com/';
  e.timeoutMs = 5000;
  e.concurrency = 5;
  e.samples = 1;
  e.retries = 0;
  e.expectedStatus = model.PROBE_EXPECT_2XX;
  return e;
};

(async () => {
  // 1. profile config hash: UI-only edits keep hash, transport edits change it
  const base = { id: 'p1', name: '香港 01', server: '1.2.3.4', serverPort: 443, type: 'shadowsocks',
    method: 'aes-128-gcm', password: 'pw', groupId: 'g1', latencyMs: 120, latencyTestedAt: 100,
    uuid: '', tls: false, sni: '', chainIds: '' };
  const h1 = model.computeProfileConfigHash(JSON.stringify(base));
  const renamed = Object.assign({}, base, { name: '日本 02', groupId: 'g2', latencyMs: 999, latencyTestedAt: 555 });
  assert.equal(model.computeProfileConfigHash(JSON.stringify(renamed)), h1,
    'name/group/latency-only edits must not change profileConfigHash');
  const moved = Object.assign({}, base, { server: '5.6.7.8' });
  assert.notEqual(model.computeProfileConfigHash(JSON.stringify(moved)), h1,
    'transport field change must change profileConfigHash');
  assert.ok(h1.startsWith('pf-'));
  console.log('PASS profileConfigHash ignores UI fields, tracks transport fields');

  // 2. legacy migration: never claim HTTP pass, path/method unknown
  const legacyOk = model.ProbeResult.fromLegacy('p1', 1, 88, '');
  assert.equal(legacyOk.state, model.PROBE_STATE_SUCCESS);
  assert.equal(legacyOk.methodActual, model.PROBE_METHOD_UNKNOWN);
  assert.equal(legacyOk.path, model.PROBE_PATH_LEGACY_UNKNOWN);
  assert.equal(legacyOk.coreCapability, model.PROBE_CAP_LEGACY);
  const legacyFail = model.ProbeResult.fromLegacy('p2', 3, 0, 'i/o timeout');
  assert.equal(legacyFail.state, model.PROBE_STATE_FAILED);
  assert.equal(legacyFail.latencyMs, -1);
  assert.equal(legacyFail.errorDetail, 'i/o timeout');
  const legacyZero = model.ProbeResult.fromLegacy('p3', 1, 0, '');
  assert.equal(legacyZero.latencyMs, 0, 'legacy 0 ping stays 0 (legal value), not "untested"');
  console.log('PASS legacy migration keeps method/path unknown and does not fake HTTP success');

  // 3. composite identity key includes method/target/policy/path
  const a = mkResult('r', 'p1', model.PROBE_STATE_SUCCESS, 10);
  const b = mkResult('r', 'p1', model.PROBE_STATE_SUCCESS, 10, { methodActual: model.PROBE_METHOD_TCPING });
  const c = mkResult('r', 'p1', model.PROBE_STATE_SUCCESS, 10, { target: 'http://other/' });
  const d = mkResult('r', 'p1', model.PROBE_STATE_SUCCESS, 10, { expectedStatus: model.PROBE_EXPECT_ANY });
  const e = mkResult('r', 'p1', model.PROBE_STATE_SUCCESS, 10, { path: model.PROBE_PATH_CURRENT_TUNNEL });
  const keys = new Set([model.probeKeyOf(a), model.probeKeyOf(b), model.probeKeyOf(c), model.probeKeyOf(d), model.probeKeyOf(e)]);
  assert.equal(keys.size, 5, 'method/target/policy/path must each produce a distinct key');
  console.log('PASS probeKeyOf distinguishes method/target/policy/path');

  // 4. begin freezes target snapshot and rejects a second concurrent round
  const c1 = new ProbeCoordinator();
  const targets = [mkTarget('a'), mkTarget('b'), mkTarget('c')];
  assert.ok(c1.begin('run-1', targets, mkEnv(), model.PROBE_CAP_NATIVE_V3, 100));
  targets.push(mkTarget('late'));
  assert.equal(c1.getTargets().length, 3, 'target snapshot must be frozen at begin');
  assert.ok(!c1.begin('run-2', [mkTarget('x')], mkEnv(), model.PROBE_CAP_NATIVE_V3, 200),
    'second concurrent round must be rejected');
  assert.equal(c1.getGeneration(), 1);
  console.log('PASS target snapshot frozen; concurrent round rejected');

  // 5. stale runId results are rejected (late callbacks cannot pollute new round)
  const stale = mkResult('run-0', 'a', model.PROBE_STATE_SUCCESS, 5);
  assert.ok(!c1.onNodeResult(stale), 'result from another runId must be rejected');
  assert.equal(c1.getResult('a').state, model.PROBE_STATE_QUEUED);
  console.log('PASS stale runId result rejected');

  // 6. result normalization: 0ms legal, negative latency success -> failed, http->tcp marks degraded,
  //    unknown method -> notApplicable
  const zero = mkResult('run-1', 'a', model.PROBE_STATE_SUCCESS, 0);
  assert.ok(c1.onNodeResult(zero));
  assert.equal(c1.getResult('a').state, model.PROBE_STATE_SUCCESS, '0ms latency is a legal success');
  const badLatency = mkResult('run-1', 'b', model.PROBE_STATE_SUCCESS, -1);
  assert.ok(c1.onNodeResult(badLatency));
  assert.equal(c1.getResult('b').state, model.PROBE_STATE_FAILED);
  assert.equal(c1.getResult('b').errorCode, 'invalid_latency');
  const fallback = mkResult('run-1', 'c', model.PROBE_STATE_SUCCESS, 40, { methodActual: model.PROBE_METHOD_TCPING });
  assert.ok(c1.onNodeResult(fallback));
  assert.equal(c1.getResult('c').degradedReason, 'http_fallback_tcping',
    'HTTP->TCP fallback must be permanently marked');
  assert.equal(c1.getResult('c').methodActual, model.PROBE_METHOD_TCPING);
  console.log('PASS 0ms legal / negative latency failed / TCP fallback marked / methodActual preserved');

  // 7. duplicate/late result for an already-final node is rejected
  const dup = mkResult('run-1', 'a', model.PROBE_STATE_FAILED, -1);
  assert.ok(!c1.onNodeResult(dup), 'final result must not be overwritten by a late duplicate');
  console.log('PASS late duplicate result rejected');

  // 8. bisect isolation: batch(4) fails -> 2+2; second half fails -> 1+1; isolated bad node
  const c2 = new ProbeCoordinator();
  const t4 = [mkTarget('n1'), mkTarget('n2'), mkTarget('n3'), mkTarget('n4')];
  assert.ok(c2.begin('run-iso', t4, mkEnv(), model.PROBE_CAP_NATIVE_V3, 0));
  assert.equal(ProbeCoordinator.attemptsBudget(4), 7, 'budget must be 2N-1');
  let step = c2.onBatchStartFailed(['n1', 'n2', 'n3', 'n4'], 'start failed: bad chain');
  assert.equal(step.kind, 'split');
  assert.equal(step.groups.length, 2);
  assert.equal(step.groups[0].join(','), 'n1,n2');
  assert.equal(step.groups[1].join(','), 'n3,n4');
  // first half starts fine, second half fails
  step = c2.onBatchStartFailed(step.groups[1], 'start failed: bad chain');
  assert.equal(step.kind, 'split');
  assert.equal(step.groups.length, 2);
  assert.equal(step.groups[0].join(','), 'n3');
  assert.equal(step.groups[1].join(','), 'n4');
  // n3 starts (no split needed), n4 fails -> isolated
  step = c2.onBatchStartFailed(['n4'], 'start failed: precondition');
  assert.equal(step.kind, 'isolated');
  assert.equal(step.isolatedProfileId, 'n4');
  assert.ok(c2.getAttempts() <= c2.getMaxAttempts());
  console.log('PASS bisect isolation splits to single bad node within 2N-1 budget');

  // 9. budget exhaustion reports unfinished instead of silently switching method
  const c3 = new ProbeCoordinator();
  assert.ok(c3.begin('run-budget', [mkTarget('x1'), mkTarget('x2'), mkTarget('x3')], mkEnv(), model.PROBE_CAP_NATIVE_V3, 0));
  let decision;
  const calls = [];
  // force repeated failures until exhausted
  for (let i = 0; i < 10; i++) {
    const ids = ['x1', 'x2', 'x3'];
    decision = c3.onBatchStartFailed(ids, 'boom');
    calls.push(decision.kind);
    if (decision.kind === 'exhausted') {
      break;
    }
  }
  assert.equal(decision.kind, 'exhausted');
  assert.ok(c3.getAttempts() <= c3.getMaxAttempts() + 1);
  c3.markUnfinished(['x1', 'x2', 'x3'], 500, 'attempt_budget_exhausted');
  const s = c3.finish(600);
  assert.equal(s.unfinished, 0);
  assert.equal(s.cancelled, 3);
  for (const r of c3.getResults()) {
    assert.equal(r.errorCode, 'attempt_budget_exhausted');
    assert.equal(r.participated, model.PROBE_PARTICIPATED_NO);
  }
  console.log('PASS attempt budget exhaustion marks unfinished as cancelled with reason');

  // 10. cancellation: queued -> cancelled & not participated; running node may still finish
  const c4 = new ProbeCoordinator();
  assert.ok(c4.begin('run-cancel', [mkTarget('q1'), mkTarget('q2')], mkEnv(), model.PROBE_CAP_NATIVE_V3, 0));
  c4.markRunning('q1', 10);
  c4.cancel(20);
  assert.equal(c4.getPhase(), 'cancelling');
  const q1 = c4.getResult('q1');
  assert.equal(q1.state, model.PROBE_STATE_RUNNING, 'in-flight node keeps running during cancellation');
  const q2 = c4.getResult('q2');
  assert.equal(q2.state, model.PROBE_STATE_CANCELLED);
  assert.equal(q2.participated, model.PROBE_PARTICIPATED_NO);
  const late = mkResult('run-cancel', 'q1', model.PROBE_STATE_SUCCESS, 33);
  assert.ok(c4.onNodeResult(late), 'in-flight node finishing after cancel is accepted');
  const s4 = c4.finish(30);
  assert.equal(s4.success, 1);
  assert.equal(s4.cancelled, 1);
  assert.equal(c4.getPhase(), 'done');
  console.log('PASS cancel keeps in-flight node finishing and marks untouched nodes not-participated');

  // 11. environment failure reported once, nodes not individually blamed
  const c5 = new ProbeCoordinator();
  assert.ok(c5.begin('run-env', [mkTarget('e1'), mkTarget('e2')], mkEnv(), model.PROBE_CAP_NATIVE_V3, 0));
  c5.onEnvironmentFailure(coordMod.ENV_REASON_CORE_UNSUPPORTED, 50);
  c5.onEnvironmentFailure('second_failure_must_be_ignored', 60);
  assert.equal(c5.getEnvError(), coordMod.ENV_REASON_CORE_UNSUPPORTED);
  for (const r of c5.getResults()) {
    assert.equal(r.state, model.PROBE_STATE_NOT_APPLICABLE, 'env failure must not mark nodes bad');
    assert.equal(r.errorCode, coordMod.ENV_REASON_CORE_UNSUPPORTED);
  }
  console.log('PASS environment failure reported once without marking nodes as bad');

  // 12. unsaved marking + summary; unsupported write is visible as unsaved, not success
  const c6 = new ProbeCoordinator();
  assert.ok(c6.begin('run-save', [mkTarget('s1'), mkTarget('s2')], mkEnv(), model.PROBE_CAP_NATIVE_V3, 0));
  c6.onNodeResult(mkResult('run-save', 's1', model.PROBE_STATE_SUCCESS, 12));
  c6.onNodeResult(mkResult('run-save', 's2', model.PROBE_STATE_SUCCESS, 14));
  c6.markUnsaved();
  const s6 = c6.finish(200);
  assert.equal(s6.unsaved, 2, 'write failure surfaces as unsaved results');
  assert.equal(s6.success, 0);
  console.log('PASS unsaved results are surfaced instead of pretending success');

  // 13. precheck ordering / machine-readable reasons
  assert.equal(ProbeCoordinator.precheckEnv(true, true, true, true), '');
  assert.equal(ProbeCoordinator.precheckEnv(true, true, true, false), coordMod.ENV_REASON_METHOD_UNSUPPORTED);
  assert.equal(ProbeCoordinator.precheckEnv(false, true, true, true), coordMod.ENV_REASON_CORE_UNSUPPORTED);
  assert.equal(ProbeCoordinator.precheckEnv(true, false, true, true), coordMod.ENV_REASON_TEST_DIR);
  assert.equal(ProbeCoordinator.precheckEnv(true, true, false, true), coordMod.ENV_REASON_INVALID_TARGET);
  console.log('PASS precheck returns machine-readable environment reasons');

  // 14. fresh/comparable helper
  const fresh = mkResult('r', 'p1', model.PROBE_STATE_SUCCESS, 10, { completedAt: 1000, persistedAt: 1000 });
  assert.ok(model.isComparableFresh(fresh, 2000, 60000));
  assert.ok(!model.isComparableFresh(fresh, 100000, 60000), 'stale result must not be comparable');
  const legacy = model.ProbeResult.fromLegacy('p1', 1, 50, '');
  assert.ok(!model.isComparableFresh(legacy, 2000, 60000), 'legacy result must not participate in fresh filtering');
  console.log('PASS freshness/comparability rules');

  console.log('\nALL probe-coordinator checks passed');
})().catch((e) => { console.error('FAIL', e); process.exit(1); });
