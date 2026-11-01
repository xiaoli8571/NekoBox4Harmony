// Subscription audit: execute production ETS in a VM, with deterministic I/O boundaries.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:/Program Files/Huawei/DevEco Studio/sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));
function load(file, imports = {}) {
  const js = ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(js, { exports, require: n => {
    if (!(n in imports)) throw Error('Unexpected import: ' + n);
    return imports[n];
  } }, { filename: file });
  return exports;
}
const P = load('entry/src/main/ets/model/Profile.ets');
const S = load('entry/src/main/ets/model/ConfigSnapshot.ets');
const L = load('entry/src/main/ets/model/SubscriptionLayers.ets', { './Profile': P, './ConfigSnapshot': S });
const N = load('entry/src/main/ets/model/NodeFilter.ets');
const clone = v => JSON.parse(JSON.stringify(v));
const log = { addLog() {} };
function fileEnv() {
  const files = new Map();
  const badReads = new Set();
  const store = {
    configDir: c => c.filesDir + '/config', ensureDir() {},
    exists: p => files.has(p),
    readText: p => { if (badReads.has(p)) throw Error('read denied'); if (!files.has(p)) throw Error('missing'); return files.get(p); },
    writeTextAtomic: (p, text) => files.set(p, text),
    removeFile: p => files.delete(p),
    listFiles: (dir, prefix) => [...files.keys()].filter(p => p.startsWith(dir + '/')).map(p => p.slice(dir.length + 1)).filter(p => p.startsWith(prefix))
  };
  const R = load('entry/src/main/ets/core/ConfigRepository.ets', {
    './SnapshotStore': { SnapshotStore: store }, '../model/ConfigSnapshot': S, '../model/Store': { LogStore: log }
  }).ConfigRepository;
  return { R, files, badReads, store };
}
const URL = 'https://audit.example/sub';
function node(name = 'Remote') {
  return Object.assign(new P.Profile(), { id: 'owned', name, server: '1.2.3.4', serverPort: 443, password: 'pw', subUrl: URL });
}
function subEnv() {
  const state = {
    profiles: [node()], groups: [{ id: 'g1', name: 'Subscription', fromSubscription: true, subUrl: URL }],
    subs: [{ url: URL, name: 'Subscription', group: '', userAgent: '', etag: '', lastModified: '', updateIntervalMinutes: 1440 }],
    content: new S.SnapshotContent(), sources: [], failCommit: false, saves: 0, notModified: false
  };
  const store = {
    loadProfiles: async () => clone(state.profiles), saveProfiles: async v => { state.profiles = clone(v); state.saves++; },
    mutateProfiles: async f => { state.profiles = f(clone(state.profiles)); return clone(state.profiles); },
    loadGroups: async () => clone(state.groups), loadSettings: async () => ({ subAllowInsecure: false, ipv6Mode: '' }),
    readPrefString: async (key, fallback) => key === 'profiles' ? JSON.stringify(state.profiles)
      : key === 'profile_groups' ? JSON.stringify(state.groups)
      : key === 'subscriptions' ? JSON.stringify(state.subs) : fallback,
    writePrefString: async (key, value) => {
      if (key === 'profiles') state.profiles = JSON.parse(value);
      if (key === 'profile_groups') state.groups = JSON.parse(value);
      if (key === 'subscriptions') state.subs = JSON.parse(value);
    }, ensureGroupByName: async () => 'g1', LogStore: log
  };
  const subs = {
    MIN_INTERVAL_MINUTES: 15, listSubs: async () => clone(state.subs), saveSubs: async v => { state.subs = clone(v); },
    subNameOf: () => 'Subscription', stableProfileId: () => 'new', applyForceResolve: async () => {}, renameCollisions() {},
    dedupProfiles: v => ({ profiles: v, duplicates: [] }), parseSubscriptionBody: async () => ({ profiles: [node()], skipped: 0, skippedNames: [], note: '' }),
    markGroupFromSubscription: async () => {}, markGroupSubUrl: async () => {}, applyClashGroups: async () => {},
    resolveDialerProxies() {}, applySubUserInfo: async () => {}, appContextOrNull: () => ({ filesDir: '/audit' })
  };
  const R = load('entry/src/main/ets/core/SubscriptionRepository.ets', {
    '../model/Profile': P, '../model/ConfigSnapshot': S, '../model/SubscriptionLayers': L, '../model/NodeFilter': N,
    './Subscriptions': subs, '../model/Store': store,
    '../utils/Subscription': {
      fetchSubscriptionConditional: async () => ({ notModified: state.notModified, content: 'remote bytes', etag: 'remote-etag', lastModified: '', userinfo: '', contentDisposition: '' }),
      fetchTextUrl: async () => '', subFailureText: () => 'no nodes', looksLikeClashYaml: () => false,
      looksLikeSingBoxJson: () => false, SUB_UA: 'test', SUB_UA_FALLBACKS: [], decodeFilename: () => ''
    },
    '../utils/ClashProviders': { parseClashGroups: () => [] },
    './ConfigRepository': { ConfigRepository: {
      hasActive: () => true, getActiveRevision: () => 1, getActive: () => ({ content: clone(state.content) }),
      commit: async f => { if (state.failCommit) throw Error('disk full'); state.content = clone(f(clone(state.content))); return { revision: 2 }; }
    } },
    './SubscriptionSourceStore': { SubscriptionSourceStore: { isInitialized: () => true, save: s => state.sources.push(clone(s)) } }
  }).SubscriptionRepository;
  return { R, state };
}
const checks = [];
function test(name, fn) { checks.push({ name, fn }); }
test('ConfigRepository isolates caller-owned initial content and returned snapshots', async () => {
  const { R } = fileEnv(); await R.init({ filesDir: '/audit' });
  const initial = new S.SnapshotContent(); initial.settings = { value: 1 };
  const result = await R.commitInitial(initial);
  initial.settings.value = 2; result.content.settings.value = 3;
  assert.equal(R.getActive().content.settings.value, 1);
  const observed = R.getActive(); observed.content.settings.value = 4;
  assert.equal(R.getActive().content.settings.value, 1);
  let draftRef;
  const saved = await R.commit(c => { draftRef = c; c.settings.value = 5; return c; });
  draftRef.settings.value = 6; saved.content.settings.value = 7;
  assert.equal(R.getActive().content.settings.value, 5);
});
test('ConfigRepository recovers from unreadable newest manifest and snapshot', async () => {
  const { R, badReads } = fileEnv(); await R.init({ filesDir: '/audit' });
  await R.commitInitial(new S.SnapshotContent()); await R.commit(c => c);
  badReads.add('/audit/config/config-snapshot-2.json');
  await R.init({ filesDir: '/audit' });
  assert.equal(R.getActiveRevision(), 1);
});
test('SourceStore rejects cross-subscription records and does not overwrite same timestamp', async () => {
  const { store, files } = fileEnv();
  const R = load('entry/src/main/ets/core/SubscriptionSourceStore.ets', {
    './SnapshotStore': { SnapshotStore: store }, '../model/SubscriptionLayers': L
  }).SubscriptionSourceStore;
  R.init({ filesDir: '/audit' });
  const snap = new L.SubscriptionSourceSnapshot(); snap.url = URL; snap.fetchedAt = 100; snap.nodes = [L.sourceNodeOf(node())]; snap.nodes[0].identityKey = 'key'; snap.nodeCount = 1;
  R.save(snap);
  const original = [...files.values()][0];
  const another = clone(snap); another.nodes[0].sourceName = 'Changed';
  R.save(another);
  assert.equal(R.readAt(URL, 100).nodes[0].sourceName, 'Remote');
  assert.equal(R.latest(URL).nodes[0].sourceName, 'Changed');
  assert.equal(R.listFetchedAt(URL).length, 2);
  files.set([...files.keys()][0], original.replace(URL, 'https://another.example/sub'));
  assert.equal(R.readAt(URL, 100), null);
});
test('Remote source snapshot remains unmodified by effective user alias and custom overrides', async () => {
  const { R, state } = subEnv();
  const ov = new L.UserOverride(); ov.subscriptionUrl = URL; ov.identityKey = L.identityKeyOf(URL, state.profiles[0]); ov.alias = 'My alias';
  state.content.userOverrides = [L.overrideToRecord(ov)];
  await R.runUpdate(URL);
  assert.equal(state.profiles[0].name, 'My alias');
  assert.equal(state.sources[0].nodes[0].sourceName, 'Remote');
  assert.equal(state.sources[0].nodes[0].identityKey, ov.identityKey);
});
test('Subscription update snapshots newly written subscription groups', async () => {
  const { R, state } = subEnv(); await R.runUpdate(URL);
  assert.equal(state.content.groups.length, 1);
  assert.equal(state.content.groups[0].id, 'g1');
});
test('Subscription snapshot persistence failure is rejected, never reported as update success', async () => {
  const { R, state } = subEnv(); state.failCommit = true;
  const beforeProfiles = clone(state.profiles), beforeSubs = clone(state.subs), beforeGroups = clone(state.groups);
  await assert.rejects(() => R.runUpdate(URL), /disk full/);
  assert.deepEqual(state.profiles, beforeProfiles);
  assert.deepEqual(state.subs, beforeSubs);
  assert.deepEqual(state.groups, beforeGroups);
});
test('304 persistence failure restores subscription timestamps and validators', async () => {
  const { R, state } = subEnv(); state.notModified = true; state.failCommit = true;
  const before = clone(state.subs);
  await assert.rejects(() => R.runUpdate(URL), /disk full/);
  assert.deepEqual(state.subs, before);
  assert.equal(state.sources.length, 0);
});
test('Clear-subscription persistence failure restores removed profiles', async () => {
  const { R, state } = subEnv(); state.failCommit = true;
  const before = clone(state.profiles);
  await assert.rejects(() => R.clearSubscriptionNodes(URL), /disk full/);
  assert.deepEqual(state.profiles, before);
});
(async () => {
  let failed = 0;
  for (const { name, fn } of checks) {
    try { await fn(); console.log('PASS ' + name); }
    catch (e) { failed++; console.error('FAIL ' + name + ': ' + e.message); }
  }
  assert.equal(failed, 0, `${failed} subscription audit regressions failed`);
  console.log(`ALL ${checks.length} subscription audit checks passed`);
})().catch(e => { console.error(e); process.exitCode = 1; });
