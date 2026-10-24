// Executes the production MigrationV5.ensureMigrated against in-memory
// Preferences + FS boundaries, per REDESIGN-PLAN-2026-10-23.md §14.4 and W04.
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

function makeFS() {
  const files = new Map();
  const dirs = new Set();
  const fdMap = new Map();
  let nextFd = 100;
  return {
    files, dirs,
    accessSync: (p) => files.has(p) || dirs.has(p),
    mkdirSync: (p) => { dirs.add(p); },
    openSync: (p) => {
      if (!files.has(p)) files.set(p, '');
      const fd = nextFd++;
      fdMap.set(fd, p);
      return { fd };
    },
    writeSync: (fd, text) => { files.set(fdMap.get(fd), text); },
    fsyncSync: () => {},
    closeSync: (file) => { fdMap.delete(file.fd); },
    renameSync: (oldP, newP) => {
      files.set(newP, files.get(oldP));
      files.delete(oldP);
    },
    unlinkSync: (p) => { files.delete(p); },
    readTextSync: (p) => {
      if (!files.has(p)) throw new Error(`no file: ${p}`);
      return files.get(p);
    },
    listFileSync: (dir) => {
      const out = [];
      for (const p of files.keys()) {
        if (p.startsWith(`${dir}/`)) out.push(p.substring(dir.length + 1));
      }
      return out;
    },
    OpenMode: { READ_WRITE: 2, CREATE: 64, TRUNC: 512 }
  };
}

const FILES_DIR = 'C:/data/storage/el2/base/haps/entry/files';
const DIR = `${FILES_DIR}/config`;
const MIG = `${DIR}/migration`;
const ctx = { filesDir: FILES_DIR };

// Build a fully isolated environment (fresh FS + Preferences + fresh module instances,
// because ConfigRepository keeps static state).
function buildEnv() {
  const memFS = makeFS();
  const data = new Map();
  const prefsImpl = {
    get: async (k, d) => (data.has(k) ? data.get(k) : d),
    put: async (k, v) => { data.set(k, v); },
    flush: async () => {}
  };
  const logLines = [];
  const modelSnap = load('entry/src/main/ets/model/ConfigSnapshot.ets');
  const perAppMod = load('entry/src/main/ets/model/PerApp.ets');
  const profileMod = load('entry/src/main/ets/model/Profile.ets');
  const storeMod = load('entry/src/main/ets/model/Store.ets', {
    '@ohos.data.preferences': {
      default: { getPreferences: async () => prefsImpl, removePreferencesFromCache: async () => {} }
    },
    '@ohos.app.ability.common': {},
    '@ohos.events.emitter': { default: { emit: () => {}, EventPriority: { LOW: 0 } } },
    './Profile': profileMod,
    './PerApp': perAppMod
  });
  storeMod.LogStore.addLog = (line) => { logLines.push(line); };
  const snapshotStoreMod = load('entry/src/main/ets/core/SnapshotStore.ets', {
    '@ohos.file.fs': { default: memFS },
    '@ohos.app.ability.common': {}
  });
  const repoMod = load('entry/src/main/ets/core/ConfigRepository.ets', {
    './SnapshotStore': snapshotStoreMod,
    '../model/ConfigSnapshot': modelSnap,
    '../model/Store': storeMod,
    '@ohos.app.ability.common': {}
  });
  const migrationMod = load('entry/src/main/ets/model/MigrationV5.ets', {
    './Store': storeMod,
    './PerApp': perAppMod,
    './ConfigSnapshot': modelSnap,
    '../core/ConfigRepository': repoMod,
    '../core/SnapshotStore': snapshotStoreMod,
    '@ohos.app.ability.common': {},
    '@ohos.deviceInfo': { sdkApiVersion: 24 }
  });
  return { memFS, data, prefsImpl, logLines, storeMod, repoMod, migrationMod };
}

let env = null;
async function boot() {
  env = buildEnv();
  await env.storeMod.initStore(ctx);
  await env.repoMod.ConfigRepository.init(ctx);
  return env;
}
function setKey(key, value) {
  env.data.set(key, typeof value === 'string' ? value : JSON.stringify(value));
}
async function runMigrate(apiLevel) {
  return env.migrationMod.MigrationV5.ensureMigrated(ctx, apiLevel === undefined ? 0 : apiLevel);
}
const backupFiles = () => [...env.memFS.files.keys()].filter((p) => p.startsWith(`${MIG}/pre-v5-backup-`));
const snapshotFiles = () => [...env.memFS.files.keys()].filter((p) => p.includes('/config-snapshot-'));

(async () => {
  // ---------- 1. empty store migrates to r1 ----------
  await boot();
  const r1 = await runMigrate();
  assert.ok(r1.ok, `empty store migration must succeed, got ${r1.error}`);
  assert.equal(r1.skipped, false);
  assert.equal(r1.revision, 1, 'first migration must commit revision 1');
  assert.equal(r1.counts.profiles, 0);
  assert.ok(r1.backupPath.startsWith(`${MIG}/pre-v5-backup-`), `backup path: ${r1.backupPath}`);
  assert.ok(env.repoMod.ConfigRepository.getActive() !== null);
  assert.equal(env.repoMod.ConfigRepository.getActive().content.profiles.length, 0);
  assert.ok(env.logLines.some((l) => l.includes('v5 迁移完成')), 'success summary must be logged');
  console.log('PASS empty store migrates to revision 1');

  // ---------- 2. second run is idempotent ----------
  const backupsFirst = backupFiles();
  const r2 = await runMigrate();
  assert.ok(r2.ok);
  assert.equal(r2.skipped, true, 'second run must short-circuit via hasActive()');
  assert.equal(r2.revision, 1, 'idempotent second run must keep revision 1');
  assert.equal(env.repoMod.ConfigRepository.getActive().content.profiles.length, 0);
  assert.deepEqual(backupFiles(), backupsFirst, 'no duplicate backup files');
  assert.equal(snapshotFiles().length, 1, 'no extra snapshot revisions');
  const marker2 = JSON.parse(env.data.get('config_migration_v5'));
  assert.equal(marker2.ok, true);
  assert.equal(marker2.revision, 1);
  const ids2 = env.repoMod.ConfigRepository.getActive().content.profiles.map((p) => p.id);
  assert.equal(new Set(ids2).size, ids2.length, 'no duplicate ids after idempotent rerun');
  console.log('PASS second migration run is idempotent (revision, content, backups)');

  // ---------- 3. rich v4 data: ids, map, risks, packages preserved ----------
  await boot();
  const profileA = { id: '1730000000000_12345', name: '香港 01', type: 'ss', server: '1.2.3.4', serverPort: 8388 };
  const profileB = { name: '上海 IEPL', type: 'vmess', server: 'example.com', serverPort: 443, uuid: 'u-1' };
  const profileC = { id: '', name: '空 ID 节点', type: 'trojan', server: '5.6.7.8', serverPort: 443 };
  const profileD = { id: '', name: '空 ID 节点 2', type: 'trojan', server: '5.6.7.9', serverPort: 443 };
  setKey('profiles', [profileA, profileB, profileC, profileD]);
  setKey('profile_groups', [
    { id: 'grp_1', name: '手工组', sortOrder: 0 },
    { id: '', name: '未 ID 组', sortOrder: 1 }
  ]);
  setKey('subscriptions', [
    { url: 'https://a.example.com/sub', name: '机场 A', updateIntervalMinutes: 1440 },
    { url: 'https://a.example.com/sub', name: '机场 A 副本', updateIntervalMinutes: 1440 },
    { name: '缺 URL 的旧订阅' }
  ]);
  setKey('route_rules', [
    { type: 'domain_suffix', value: 'cn', domains: '', outbound: 'direct', enabled: true },
    { packages: 'com.tencent.mm,com.example.a', packagesEnabled: true, domains: 'example.net', outbound: 'proxy', enabled: true }
  ]);
  setKey('remote_rule_sets', [
    { id: '', url: 'https://rules.example.com/srs/geosite.srs', name: 'geosite', type: 'site', outbound: 'direct' }
  ]);
  setKey('settings', {
    mtu: 1400, perAppMode: 'include', perAppList: '', perAppEntries: '[]',
    remoteDns: 'tcp://8.8.8.8', clashApiSecret: 'test-only'
  });
  const r3 = await runMigrate();
  assert.ok(r3.ok, `rich migration must succeed, got ${r3.error}`);
  assert.equal(r3.revision, 1);
  const snap3 = env.repoMod.ConfigRepository.loadSnapshot(1);
  assert.ok(snap3 !== null, 'snapshot 1 must be loadable');
  const content3 = snap3.content;

  // 3a. all ids non-empty and unique; existing ids preserved
  const ids3 = content3.profiles.map((p) => `${p.id}`);
  for (const id of ids3) {
    assert.ok(id.length > 0, `profile id must be non-empty: ${JSON.stringify(ids3)}`);
  }
  assert.equal(new Set(ids3).size, ids3.length, `ids must be unique, got ${ids3}`);
  assert.equal(ids3[0], '1730000000000_12345', 'existing non-empty id must be preserved verbatim');
  assert.ok(ids3[2].startsWith('p_'), `empty id must get generated p_<fnv8>, got ${ids3[2]}`);
  assert.ok(ids3[3].startsWith('p_'), `second empty id must get generated p_<fnv8>, got ${ids3[3]}`);
  assert.notEqual(ids3[2], ids3[3], 'two empty-id profiles must not collide');
  const groupIds3 = content3.groups.map((g) => `${g.id}`);
  assert.equal(groupIds3[0], 'grp_1', 'existing group id preserved');
  assert.ok(groupIds3[1].startsWith('grp_'), `empty group id generated, got ${groupIds3[1]}`);
  const subIds3 = content3.subscriptions.map((s) => `${s.id}`);
  for (const id of subIds3) {
    assert.ok(id.startsWith('sub_'), `subscription id must be sub_<fnv8>, got ${id}`);
  }
  assert.equal(subIds3[0], subIds3[1], 'same URL subscriptions share one identity id');
  assert.notEqual(subIds3[2], subIds3[0], 'missing-url subscription gets fallback id');
  const ruleIds3 = content3.routeRules.map((r) => `${r.id}`);
  for (const id of ruleIds3) {
    assert.ok(id.startsWith('rule_'), `rule id must be rule_<index>_<fnv8>, got ${id}`);
  }
  const rsetIds3 = content3.remoteRuleSets.map((s) => `${s.id}`);
  assert.ok(rsetIds3[0].startsWith('rset_'), `ruleset id must be rset_<fnv8>, got ${rsetIds3[0]}`);

  // 3b. id-map file written with expected structure
  assert.ok(env.memFS.files.has(`${MIG}/id-map.json`), 'id-map.json must exist');
  const idMap = JSON.parse(env.memFS.files.get(`${MIG}/id-map.json`));
  assert.equal(idMap.subscriptions.length, 3, 'one mapping row per subscription');
  assert.equal(idMap.subscriptions[0].oldUrl, 'https://a.example.com/sub');
  assert.equal(idMap.subscriptions[0].newId, subIds3[0]);
  assert.equal(idMap.subscriptions[0].duplicate, true, 'duplicate url flagged in map');
  assert.equal(idMap.routeRules.length, 2);
  assert.equal(idMap.routeRules[1].index, 1);
  assert.equal(idMap.routeRules[1].id, ruleIds3[1]);
  assert.equal(idMap.remoteRuleSets.length, 1);
  assert.ok(idMap.sourceHash.length > 0);
  assert.ok(Array.isArray(idMap.profiles.conflicts) && Array.isArray(idMap.groups.conflicts),
    'id-map must carry profiles/groups conflict buckets');

  // 3c. report lists risks; conflicts listed (duplicate sub url)
  assert.ok(env.memFS.files.has(`${MIG}/migration-v5-report.json`), 'report must exist');
  const report = JSON.parse(env.memFS.files.get(`${MIG}/migration-v5-report.json`));
  const riskTypes = report.risks.map((r) => r.type);
  assert.ok(riskTypes.includes('per_app_include_empty'), `include-empty must be flagged: ${riskTypes}`);
  assert.ok(riskTypes.includes('legacy_packages_rule'), `packages rule must be flagged: ${riskTypes}`);
  assert.ok(riskTypes.includes('subscription_missing_url'), `missing sub url must be flagged: ${riskTypes}`);
  const conflictTypes = report.conflicts.map((c) => c.type);
  assert.ok(conflictTypes.includes('duplicate_subscription_url'), `duplicate url conflict expected: ${conflictTypes}`);

  // 3d. packages rule preserved verbatim + unsupportedOnPlatform flag; data NOT auto-fixed
  const pkgRule = content3.routeRules[1];
  assert.equal(pkgRule.packages, 'com.tencent.mm,com.example.a', 'packages text must survive verbatim');
  assert.equal(pkgRule.packagesEnabled, true, 'packagesEnabled must survive');
  assert.equal(pkgRule.enabled, true, 'enabled must survive');
  assert.equal(pkgRule.unsupportedOnPlatform, true, 'unsupportedOnPlatform flag must be added');
  assert.equal(content3.routeRules[0].unsupportedOnPlatform, undefined, 'non-package rule must NOT be flagged');
  assert.equal(content3.settings.perAppMode, 'include', 'include mode must not be auto-changed');
  assert.equal(content3.settings.perAppEntries, '[]', 'empty entries must not be auto-filled');
  assert.equal(content3.profiles[0].name, '香港 01', 'Chinese node name must survive');
  console.log('PASS rich v4 data: stable ids, id-map, risks, packages preserved verbatim + flagged');

  // ---------- 4. legacy perAppList CSV (uninitialized entries) analyzed from CSV ----------
  await boot();
  setKey('settings', {
    perAppMode: 'include', perAppList: 'com.app.one, com.app.two, com.app.one, bad..name',
    perAppEntries: ''
  });
  const r4 = await runMigrate();
  assert.ok(r4.ok, `legacy csv migration must succeed, got ${r4.error}`);
  const report4 = JSON.parse(env.memFS.files.get(`${MIG}/migration-v5-report.json`));
  const types4 = report4.risks.map((r) => r.type);
  assert.ok(types4.includes('per_app_entries_uninitialized'), `uninitialized entries expected: ${types4}`);
  const dupRisk4 = report4.risks.find((r) => r.type === 'per_app_duplicate_bundle');
  assert.ok(dupRisk4 !== undefined, 'duplicate bundle in CSV must be flagged');
  assert.ok(dupRisk4.message.includes('com.app.one'), 'duplicate bundle name must appear in message');
  const illRisk4 = report4.risks.find((r) => r.type === 'per_app_invalid_bundle');
  assert.ok(illRisk4 !== undefined, 'illegal bundle name must be flagged');
  assert.ok(illRisk4.message.includes('bad..name'), 'illegal bundle name must appear');
  assert.ok(!types4.includes('per_app_over_limit'), '2 valid apps under limit 256');
  console.log('PASS legacy perAppList CSV analyzed: duplicates + illegal names flagged');

  // ---------- 5. include + all-disabled entries => include-empty ----------
  await boot();
  setKey('settings', {
    perAppMode: 'include',
    perAppEntries: JSON.stringify([
      { bundleName: 'com.app.one', label: 'One', enabled: false },
      { bundleName: 'com.app.two', label: 'Two', enabled: false }
    ])
  });
  const r5 = await runMigrate();
  assert.ok(r5.ok, `disabled-entries migration must succeed, got ${r5.error}`);
  const report5 = JSON.parse(env.memFS.files.get(`${MIG}/migration-v5-report.json`));
  assert.ok(report5.risks.some((r) => r.type === 'per_app_include_empty'),
    'include mode with zero enabled entries must be flagged');
  console.log('PASS include mode with all-disabled entries flagged as include-empty');

  // ---------- 6. corrupted route_rules (non-array) -> abort, no commit, no overwrite ----------
  await boot();
  const rawProfiles6 = JSON.stringify([{ id: 'p1', name: '节点', type: 'ss', server: '1.1.1.1', serverPort: 1 }]);
  setKey('profiles', rawProfiles6);
  setKey('route_rules', '{"not":"an array"}');
  setKey('subscriptions', 'not even json');
  const r6 = await runMigrate();
  assert.ok(!r6.ok, 'corrupted keys must fail migration');
  assert.ok(r6.error.includes('route_rules') || r6.error.includes('subscriptions'),
    `error must name the offending key, got: ${r6.error}`);
  assert.equal(env.repoMod.ConfigRepository.hasActive(), false, 'no snapshot may be committed');
  assert.equal(env.data.get('route_rules'), '{"not":"an array"}', 'corrupted route_rules must remain untouched');
  assert.equal(env.data.get('subscriptions'), 'not even json', 'corrupted subscriptions must remain untouched');
  assert.equal(env.data.get('profiles'), rawProfiles6, 'valid profiles key must remain untouched');
  assert.ok(env.memFS.files.has(`${MIG}/migration-v5-report.json`), 'failure report must exist');
  const report6 = JSON.parse(env.memFS.files.get(`${MIG}/migration-v5-report.json`));
  assert.equal(report6.ok, false, 'failure report must say ok=false');
  const marker6 = JSON.parse(env.data.get('config_migration_v5'));
  assert.equal(marker6.ok, false, 'failure marker must say ok=false');
  assert.ok(marker6.error.length > 0, 'failure marker must carry the error');
  // backup of the corrupt state is still a valid recovery point (raw bytes preserved)
  assert.equal(backupFiles().length, 1, 'recovery point written even for corrupt data');
  // fix the data -> rerun succeeds and reuses the single backup
  setKey('route_rules', '[]');
  setKey('subscriptions', '[]');
  const r6b = await runMigrate();
  assert.ok(r6b.ok, `fixed rerun must succeed, got ${r6b.error}`);
  assert.equal(backupFiles().length, 1, 'fixed rerun reuses the existing backup');
  assert.equal(env.repoMod.ConfigRepository.getActiveRevision(), 1);
  console.log('PASS corrupted JSON keys abort migration without overwriting; fixed rerun succeeds');

  // ---------- 7. backup file content: 6 raw keys + schemaVersion 4 + hash ----------
  await boot();
  const rawProfiles7 = JSON.stringify([{ id: 'x1', name: '恢复点验证', type: 'ss', server: '9.9.9.9', serverPort: 1 }]);
  const rawSettings7 = JSON.stringify({ mtu: 1400, clashApiSecret: 't' });
  setKey('profiles', rawProfiles7);
  setKey('settings', rawSettings7);
  setKey('route_rules', '[{"value":"cn","outbound":"direct"}]');
  const r7 = await runMigrate();
  assert.ok(r7.ok, `backup migration must succeed, got ${r7.error}`);
  assert.equal(backupFiles().length, 1, 'exactly one backup file');
  const backup = JSON.parse(env.memFS.files.get(backupFiles()[0]));
  assert.equal(backup.schemaVersion, 4, 'backup schemaVersion must be 4');
  assert.ok(typeof backup.exportedAt === 'number' && backup.exportedAt > 0);
  assert.ok(backup.hash.length > 0, 'backup hash must be present');
  assert.equal(backup.entries.profiles, rawProfiles7, 'backup must contain raw profiles byte-for-byte');
  assert.equal(backup.entries.route_rules, '[{"value":"cn","outbound":"direct"}]', 'raw route_rules preserved');
  assert.equal(backup.entries.settings, rawSettings7, 'raw settings preserved');
  assert.equal(backup.entries.profile_groups, '[]', 'missing key backed up as default');
  assert.equal(backup.entries.subscriptions, '[]');
  assert.equal(backup.entries.remote_rule_sets, '[]');
  assert.equal(r7.sourceHash, backup.hash, 'reported hash equals backup hash');
  assert.ok(r7.sourceHash.startsWith('fnv1a-'), 'hash uses the snapshot checksum function');
  const marker7 = JSON.parse(env.data.get('config_migration_v5'));
  assert.equal(marker7.ok, true);
  assert.equal(marker7.revision, 1);
  assert.equal(marker7.counts.profiles, 1);
  assert.equal(marker7.backupPath, backupFiles()[0]);
  console.log('PASS restore-point file carries 6 raw keys + schemaVersion 4 + hash');

  // ---------- 8. snapshot content equals source data (counts + identity) ----------
  const content8 = env.repoMod.ConfigRepository.loadSnapshot(1).content;
  assert.equal(content8.profiles.length, 1);
  assert.equal(content8.profiles[0].id, 'x1');
  assert.equal(content8.profiles[0].name, '恢复点验证', 'snapshot must equal source data');
  assert.equal(content8.routeRules.length, 1);
  assert.equal(content8.routeRules[0].value, 'cn');
  assert.equal(JSON.stringify(content8.settings), rawSettings7, 'settings object carried over unchanged');
  console.log('PASS loadSnapshot(1) content matches source data');

  // ---------- 9. restart simulation: recovery + skip ----------
  const r9 = await runMigrate();
  assert.ok(r9.ok && r9.skipped, 'rerun on migrated store must skip');
  await env.repoMod.ConfigRepository.init(ctx); // new process boot: repo re-init from disk
  assert.ok(env.repoMod.ConfigRepository.hasActive(), 're-init must recover active snapshot');
  const r9b = await runMigrate();
  assert.ok(r9b.ok && r9b.skipped, 'post-restart rerun must also skip');
  assert.equal(r9b.revision, 1, 'revision stays 1 across restarts');
  console.log('PASS restart simulation: recovery + skip works');

  // ---------- 10. dropped non-object array items are isolated, migration continues ----------
  await boot();
  setKey('profiles', [{ id: 'p1', name: '好节点', type: 'ss', server: '2.2.2.2', serverPort: 1 }, 42, null]);
  const r10 = await runMigrate();
  assert.ok(r10.ok, `valid items must survive junk items, got ${r10.error}`);
  assert.equal(r10.counts.profiles, 1, 'only the good profile migrates');
  const report10 = JSON.parse(env.memFS.files.get(`${MIG}/migration-v5-report.json`));
  const dropped = report10.risks.filter((r) => r.type === 'dropped_non_object_item');
  assert.equal(dropped.length, 2, 'two junk items must be reported');
  console.log('PASS non-object array items isolated and reported, good items migrate');

  // ---------- 11. per-app over limit detection (apiLevel 22 -> limit 64) ----------
  await boot();
  const entries11 = [];
  for (let i = 0; i < 65; i++) {
    entries11.push({ bundleName: `com.app.n${i}`, label: `N${i}`, enabled: true });
  }
  setKey('settings', { perAppMode: 'exclude', perAppEntries: JSON.stringify(entries11) });
  const r11 = await runMigrate(22);
  assert.ok(r11.ok, `over-limit migration must succeed, got ${r11.error}`);
  const report11 = JSON.parse(env.memFS.files.get(`${MIG}/migration-v5-report.json`));
  assert.ok(report11.risks.some((r) => r.type === 'per_app_over_limit'),
    '65 enabled apps must exceed the apiLevel-22 limit of 64');
  assert.equal(report11.perAppLimit, 64, 'apiLevel 22 must map to limit 64');
  console.log('PASS per-app over-limit detection respects apiLevel (22 -> 64)');

  // ---------- 12. no temp-file residue; marker readable ----------
  const tmpLeft = [...env.memFS.files.keys()].filter((p) => p.endsWith('.tmp'));
  assert.equal(tmpLeft.length, 0, `no .tmp residue expected, found ${tmpLeft.join(',')}`);
  const marker12 = JSON.parse(env.data.get('config_migration_v5'));
  assert.equal(marker12.ok, true);
  assert.ok(marker12.reportPath.endsWith('migration-v5-report.json'));
  assert.ok(marker12.idMapPath.endsWith('id-map.json'));
  console.log('PASS no temp residue; marker points at report + id-map');

  console.log('\nALL migration-v5 checks passed');
})().catch((e) => { console.error('FAIL', e); process.exit(1); });
