// Executes the production ConfigRepository against an in-memory file boundary,
// including write-failure injection (MIG-02) and recovery checks.
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

function makeFS(getFail) {
  const files = new Map();
  const dirs = new Set();
  const fdMap = new Map();
  let nextFd = 100;
  const failing = (op, p) => {
    const f = getFail();
    return f !== null && f !== undefined && f.op === op && (f.pathIncludes === undefined || String(p).includes(f.pathIncludes));
  };
  return {
    files, dirs,
    accessSync: (p) => files.has(p) || dirs.has(p),
    mkdirSync: (p) => { dirs.add(p); },
    openSync: (p) => {
      if (failing('openSync', p)) throw new Error(`open failed: ${p}`);
      if (!files.has(p)) files.set(p, '');
      const fd = nextFd++;
      fdMap.set(fd, p);
      return { fd };
    },
    writeSync: (fd, text) => {
      if (failing('writeSync', fdMap.get(fd))) throw new Error(`write failed: ${fdMap.get(fd)}`);
      files.set(fdMap.get(fd), text);
    },
    fsyncSync: (fd) => { if (failing('fsyncSync', fdMap.get(fd))) throw new Error('fsync failed'); },
    closeSync: (file) => { fdMap.delete(file.fd); },
    renameSync: (oldP, newP) => {
      if (failing('renameSync', oldP)) throw new Error(`rename failed: ${oldP}`);
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
    statSync: (p) => ({ isDirectory: () => dirs.has(p), size: (files.get(p) || '').length }),
    OpenMode: { READ_WRITE: 2, CREATE: 64, TRUNC: 512 }
  };
}

const modelSnap = load('entry/src/main/ets/model/ConfigSnapshot.ets');

function buildRepo(failOnRef) {
  const memFS = makeFS(() => failOnRef.value);
  const storeMod = load('entry/src/main/ets/core/SnapshotStore.ets', {
    '@ohos.file.fs': { default: memFS },
    '@ohos.app.ability.common': {}
  });
  const repoMod = load('entry/src/main/ets/core/ConfigRepository.ets', {
    './SnapshotStore': storeMod,
    '../model/ConfigSnapshot': modelSnap,
    '../model/Store': { LogStore: { addLog: () => {} } },
    '@ohos.app.ability.common': {}
  });
  return { repo: repoMod.ConfigRepository, memFS };
}

const DIR = 'C:/data/storage/el2/base/haps/entry/files/config';
const ctx = { filesDir: 'C:/data/storage/el2/base/haps/entry/files' };

function makeContent(profilesCount = 2) {
  const c = new modelSnap.SnapshotContent();
  c.settings = { clashApiPort: 19290, ipv6Mode: '', perAppMode: 'off' };
  const profiles = [];
  for (let i = 0; i < profilesCount; i++) {
    profiles.push({ id: `p${i}`, name: `节点${i}`, type: 'ss', server: '1.2.3.4' });
  }
  c.profiles = profiles;
  c.groups = [{ id: 'g1', name: '香港' }];
  c.subscriptions = [];
  c.routeRules = [{ id: 'r1', outbound: 'direct', domains: 'example.com' }];
  c.remoteRuleSets = [];
  return c;
}

const snapRevisions = () => [...memFS.files.keys()]
  .filter((p) => p.includes('/config-snapshot-'))
  .map((p) => Number(p.substring(p.lastIndexOf('config-snapshot-') + 'config-snapshot-'.length, p.lastIndexOf('.json'))))
  .sort((a, b) => a - b);

let memFS;
(async () => {
  const failOnRef = { value: null };
  const built = buildRepo(failOnRef);
  const repo = built.repo;
  memFS = built.memFS;

  // 1. empty init -> no active snapshot
  await repo.init(ctx);
  assert.equal(repo.hasActive(), false, 'empty store must not report an active snapshot');
  console.log('PASS init on empty store yields no active snapshot');

  // 2. commitInitial -> r1; idempotent repeat must not rewrite/replace content
  const s1 = await repo.commitInitial(makeContent());
  assert.equal(s1.revision, 1);
  const s1b = await repo.commitInitial(makeContent(3));
  assert.equal(s1b.revision, 1, 'commitInitial must be idempotent (no bump when active exists)');
  assert.equal(repo.getActive().content.profiles.length, 2, 'idempotent commitInitial must not replace content');
  console.log('PASS commitInitial writes r1 and is idempotent');

  // 3. commit -> r2 with parent link + manifest file present
  const s2 = await repo.commit((c) => {
    c.profiles.push({ id: 'p9', name: '新节点' });
    return c;
  });
  assert.equal(s2.revision, 2);
  assert.equal(s2.parentRevision, 1);
  assert.equal(repo.getActive().content.profiles.length, 3);
  assert.ok(memFS.files.has(`${DIR}/config-snapshot-2.json`), 'snapshot file for r2 must exist');
  console.log('PASS commit creates r2 with parent revision and file');

  // 4. single-writer serialization: two concurrent commits -> sequential revisions
  const [c1, c2] = await Promise.all([
    repo.commit((c) => { c.settings.clashApiPort = 20001; return c; }),
    repo.commit((c) => { c.settings.perAppMode = 'exclude'; return c; })
  ]);
  assert.equal(c2.revision, c1.revision + 1, 'concurrent commits must serialize into sequential revisions');
  assert.equal(c2.parentRevision, c1.revision, 'second commit must build on the first');
  const merged = repo.getActive().content;
  assert.equal(merged.profiles.length, 3, 'later commit must not lose earlier content');
  assert.equal(merged.settings.perAppMode, 'exclude');
  assert.equal(merged.settings.clashApiPort, 20001);
  console.log(`PASS concurrent commits serialize (r${c1.revision} then r${c2.revision}) and merge both changes`);

  // 5. rollbackTo rewrites older content as a new revision; history stays loadable
  const beforeRollback = repo.getActiveRevision();
  const targetContent = repo.loadSnapshot(2).content;
  const rolled = await repo.rollbackTo(2);
  assert.equal(rolled.revision, beforeRollback + 1);
  assert.equal(rolled.content.profiles.length, targetContent.profiles.length, 'rollback restores target content');
  assert.ok(repo.loadSnapshot(beforeRollback) !== null, 'older revisions must remain loadable after rollback');
  console.log(`PASS rollbackTo(r2) creates r${rolled.revision} with r2 content, history kept`);

  // 6. write-failure injection during manifest write -> active unchanged, orphan snapshot cleaned (MIG-02)
  const revBefore = repo.getActiveRevision();
  failOnRef.value = { op: 'writeSync', pathIncludes: 'manifest-' };
  let threw = false;
  try {
    await repo.commit((c) => { c.settings.clashApiPort = 1; return c; });
  } catch (e) {
    threw = true;
  }
  failOnRef.value = null;
  assert.ok(threw, 'commit must fail loudly when manifest write fails');
  assert.equal(repo.getActiveRevision(), revBefore, 'failed commit must not advance active revision');
  const orphanRevs = snapRevisions().filter((r) => r > revBefore);
  assert.equal(orphanRevs.length, 1, 'failed commit leaves exactly one written orphan snapshot');
  await repo.init(ctx);
  assert.equal(repo.getActiveRevision(), revBefore, 'init after failed commit must recover the previous revision');
  assert.equal(snapRevisions().filter((r) => r > repo.getActiveRevision()).length, 0,
    'orphan snapshots from interrupted commits must be cleaned at init');
  console.log('PASS injected manifest write failure keeps previous revision; orphan cleaned at init');

  // 7. truncation of newest snapshot file -> recovery falls back to previous revision
  const latest = repo.getActiveRevision();
  memFS.files.set(`${DIR}/config-snapshot-${latest}.json`, '{"schemaVersion":5,"revision":');
  await repo.init(ctx);
  assert.equal(repo.getActiveRevision(), latest - 1, 'corrupted newest snapshot must fall back to previous revision');
  console.log('PASS corrupted newest snapshot recovers to previous revision');

  // 8. checksum mismatch (tampered content) is rejected; scan never exceeds committed ceiling
  const current = repo.getActiveRevision();
  const raw = JSON.parse(memFS.files.get(`${DIR}/config-snapshot-${current}.json`));
  raw.content.settings.clashApiPort = 99999;
  memFS.files.set(`${DIR}/config-snapshot-${current}.json`, JSON.stringify(raw));
  await repo.init(ctx);
  assert.ok(repo.getActiveRevision() < current, 'tampered snapshot must be rejected on load');
  console.log('PASS tampered snapshot checksum mismatch rejected');

  // 9. both manifests corrupted -> full scan fallback recovers some valid snapshot
  memFS.files.set(`${DIR}/manifest-a.json`, '{broken');
  memFS.files.set(`${DIR}/manifest-b.json`, '{broken');
  await repo.init(ctx);
  assert.ok(repo.hasActive(), 'full scan fallback must recover a valid snapshot when both manifests are broken');
  console.log(`PASS both-manifests-corrupted scan fallback recovers r${repo.getActiveRevision()}`);

  // 10. future schema version rejected explicitly (never activated, never silently downgraded)
  const futureSnap = {
    schemaVersion: 6, revision: 99, parentRevision: 1, createdAt: 1,
    checksum: modelSnap.computeChecksum(modelSnap.contentToJson(new modelSnap.SnapshotContent())),
    resourceManifestId: '',
    content: JSON.parse(modelSnap.contentToJson(new modelSnap.SnapshotContent()))
  };
  memFS.files.set(`${DIR}/config-snapshot-99.json`, JSON.stringify(futureSnap));
  memFS.files.set(`${DIR}/manifest-a.json`, JSON.stringify({ schemaVersion: 6, activeRevision: 99, snapshotFile: 'config-snapshot-99.json', checksum: futureSnap.checksum, savedAt: 1, slot: 'a' }));
  await repo.init(ctx);
  assert.ok(repo.getActiveRevision() !== 99, 'future schema version must not be activated');
  assert.equal(repo.getActive().schemaVersion, 5, 'activated snapshot must still be v5');
  console.log('PASS future schema version rejected with explicit fallback');

  // 11. GC keeps only last 3 revisions after more commits
  for (let i = 0; i < 4; i++) {
    await repo.commit((c) => { c.settings.clashApiPort = 30000 + i; return c; });
  }
  const kept = snapRevisions();
  assert.ok(kept.length <= 3, `GC must keep at most 3 snapshot files, got ${kept.length} [${kept}]`);
  console.log(`PASS GC keeps ${kept.length} snapshot files after 4 more commits`);

  // 12. reserved (unknown future) keys survive a commit
  await repo.commit((c) => {
    c.reserved['strategyGroups'] = [{ id: 'sg1' }];
    return c;
  });
  assert.ok(repo.getActive().content.reserved['strategyGroups'] !== undefined,
    'unknown future keys must be preserved across commits');
  console.log('PASS reserved future keys survive commit');

  // 13. checksum stability: same content -> same checksum
  const a = modelSnap.computeChecksum(modelSnap.contentToJson(makeContent()));
  const b = modelSnap.computeChecksum(modelSnap.contentToJson(makeContent()));
  assert.equal(a, b, 'checksum must be deterministic for identical content');
  assert.ok(a.startsWith('fnv1a-'), 'checksum format must be fnv1a-prefixed');
  console.log('PASS checksum deterministic');

  // 14. no .tmp residue after successful commits
  const tmpLeft = [...memFS.files.keys()].filter((p) => p.endsWith('.tmp'));
  assert.equal(tmpLeft.length, 0, `no .tmp residue expected, found ${tmpLeft.join(',')}`);
  console.log('PASS no temp-file residue after commits');

  console.log('\nALL config-repository checks passed');
})().catch((e) => { console.error('FAIL', e); process.exit(1); });
