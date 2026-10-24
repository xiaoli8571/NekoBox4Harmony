// ApplyCoordinator state machine + VpnEnvelope/VpnCommand transport tests (P1/W06).
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

// CommonEvent stub: capture published events, echo subscribers
const published = [];
const commonEventStub = {
  default: {
    publish: (event, opts, cb) => { published.push({ event, data: opts.data }); if (cb) cb(null); },
    createSubscriber: async (info) => ({ events: info.events }),
    subscribe: (sub, cb) => { },
    unsubscribe: (sub, cb) => { if (cb) cb(null); }
  }
};
const ipc = load('entry/src/main/ets/core/VpnIpc.ets', {
  '@ohos.commonEventManager': commonEventStub,
  '@ohos.base': {}
});
const applyMod = load('entry/src/main/ets/core/ApplyCoordinator.ets', {});

(async () => {
  // 1. envelope roundtrip
  const env = new ipc.VpnEnvelope();
  env.sessionId = 'vpn-abc-1';
  env.generation = 7;
  env.sequence = 42;
  env.operationId = 'op-1';
  env.appliedRevision = 12;
  env.configHash = 'fnv1a-deadbeef';
  env.emittedAt = 123456;
  const back = ipc.VpnEnvelope.fromJson(ipc.VpnEnvelope.toJson(env));
  assert.ok(back !== null);
  assert.equal(back.sessionId, 'vpn-abc-1');
  assert.equal(back.generation, 7);
  assert.equal(back.sequence, 42);
  assert.equal(back.operationId, 'op-1');
  assert.equal(back.appliedRevision, 12);
  assert.equal(back.configHash, 'fnv1a-deadbeef');
  assert.equal(ipc.VpnEnvelope.fromJson(''), null, 'missing env must parse to null (legacy semantics)');
  assert.equal(ipc.VpnEnvelope.fromJson('{broken'), null, 'broken env must parse to null, not throw');
  console.log('PASS envelope roundtrip + missing/broken env -> null');

  // 2. status publish carries envelope + legacy fields
  published.length = 0;
  ipc.publishVpnStatusEx('connected:节点A', true, 'p1', env);
  assert.equal(published.length, 1);
  const payload = JSON.parse(published[0].data);
  assert.equal(payload.status, 'connected:节点A');
  assert.equal(payload.running, 'true');
  assert.equal(payload.profileId, 'p1');
  assert.equal(JSON.parse(payload.env).sessionId, 'vpn-abc-1', 'status payload must embed envelope');
  // legacy semantics: null env -> env:'' still parseable state path
  ipc.publishVpnStatusEx('disconnected', false, '', null);
  assert.equal(JSON.parse(published[1].data).env, '');
  console.log('PASS status publish embeds envelope, legacy null env tolerated');

  // 3. applied ack publish
  published.length = 0;
  ipc.publishVpnApplied(true, 'include:12 apps', env);
  const ack = JSON.parse(published[0].data);
  assert.equal(ack.ok, 'true');
  assert.equal(ack.perAppSummary, 'include:12 apps');
  assert.equal(JSON.parse(ack.env).appliedRevision, 12);
  console.log('PASS applied ack publish carries summary + envelope');

  // 4. command publish/parse
  published.length = 0;
  const cmd = new ipc.VpnCommand();
  cmd.cmd = 'query';
  cmd.operationId = 'op-q1';
  cmd.generation = 3;
  cmd.revision = 12;
  ipc.publishVpnCommand(cmd);
  const raw = JSON.parse(published[0].data);
  assert.equal(raw.cmd, 'query');
  assert.equal(raw.operationId, 'op-q1');
  assert.equal(raw.generation, 3);
  assert.equal(raw.revision, 12);
  assert.equal(published[0].event, ipc.VPN_EVENT_CMD);
  console.log('PASS command publish serializes cmd + envelope keys');

  // 5. ApplyCoordinator: save -> pending; apply -> applying; ack -> applied clears pending
  const c = new applyMod.ApplyCoordinator();
  c.markSaved(3);
  c.markSaved(4);
  let s = c.getSnapshot();
  assert.equal(s.phase, 'saved');
  assert.equal(s.savedRevision, 4);
  assert.equal(s.pendingChanges, 2);
  assert.ok(c.beginApply('op-a1', 4), 'first beginApply must be accepted');
  assert.ok(!c.beginApply('op-a1', 4), 'same operationId retry must be rejected (no duplicate start)');
  assert.ok(!c.beginApply('op-a1', 4));
  assert.ok(c.beginApply('op-a2', 4), 'a different operationId supersedes (continuous switching merges)');
  s = c.getSnapshot();
  assert.equal(s.phase, 'applying');
  assert.equal(s.operationId, 'op-a2');
  assert.equal(s.requestedRevision, 4);
  // late ack from old operation rejected
  assert.ok(!c.acceptAck('op-a1', 0, 'vpn-1', 4, 0, 'vpn-1'), 'late ack from superseded op must be rejected');
  // correct ack
  assert.ok(c.acceptAck('op-a2', 9, 'vpn-1', 4, 9, 'vpn-1'), 'matching ack must be accepted');
  s = c.getSnapshot();
  assert.equal(s.phase, 'applied');
  assert.equal(s.appliedRevision, 4);
  assert.equal(s.pendingChanges, 0, 'applied >= saved clears pending');
  console.log('PASS save/apply/ack transitions with operationId dedupe + late-ack rejection');

  // 6. cross-session ack rejected; generation mismatch rejected
  const c2 = new applyMod.ApplyCoordinator();
  c2.markSaved(2);
  c2.beginApply('op-b1', 2);
  assert.ok(!c2.acceptAck('op-b1', 5, 'vpn-1', 2, 4, 'vpn-1'), 'generation mismatch must be rejected');
  assert.ok(!c2.acceptAck('op-b1', 4, 'vpn-other', 2, 4, 'vpn-1'), 'sessionId mismatch must be rejected');
  assert.ok(c2.acceptAck('op-b1', 4, 'vpn-1', 2, 4, 'vpn-1'));
  console.log('PASS cross-session and generation-mismatched acks rejected');

  // 7. bounded recovery: one rollback attempt then refuse (§12.3-7)
  const c3 = new applyMod.ApplyCoordinator();
  c3.markSaved(5);
  c3.beginApply('op-c1', 5);
  assert.ok(c3.onFailure('op-c1', 'start_failed:xxx'), 'first failure must allow one bounded recovery');
  assert.ok(!c3.onFailure('op-c1', 'start_failed:xxx'), 'second failure must refuse further auto-recovery');
  const s3 = c3.getSnapshot();
  assert.equal(s3.phase, 'failed');
  assert.equal(s3.lastError, 'start_failed:xxx');
  assert.equal(s3.recoveryAttempted, true);
  // late failure of superseded op must not change state
  c3.beginApply('op-c2', 5);
  c3.onFailure('op-c1', 'stale failure');
  assert.equal(c3.getSnapshot().lastError, '', 'late failure of a superseded operation must not overwrite state');
  console.log('PASS bounded recovery: one attempt then refuse; stale failures ignored');

  // 8. discardDraft + reset semantics
  const c4 = new applyMod.ApplyCoordinator();
  c4.markSaved(6);
  c4.discardDraft();
  let s4 = c4.getSnapshot();
  assert.equal(s4.pendingChanges, 0);
  assert.equal(s4.phase, 'idle', 'discard without applied revision returns to idle');
  c4.markSaved(7);
  c4.acceptAck ? c4.beginApply('op-d1', 7) : null;
  c4.acceptAck('op-d1', 0, 'vpn-1', 7, 0, 'vpn-1');
  c4.reset();
  s4 = c4.getSnapshot();
  assert.equal(s4.phase, 'applied', 'reset keeps applied phase when a real ack was seen');
  assert.equal(s4.appliedRevision, 7);
  console.log('PASS discardDraft/reset semantics');

  console.log('\nALL runtime-protocol checks passed');
})().catch((e) => { console.error('FAIL', e); process.exit(1); });
