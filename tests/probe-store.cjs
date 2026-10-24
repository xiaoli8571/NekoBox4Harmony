// Executes the production ProbeStore (§6.2/§6.3 检测结果独立存储) against an in-memory file
// boundary, including write-failure injection, corrupt/future-schema files and prune/GC.
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

// In-memory FS with targeted failure injection (same shape as tests/config-repository.cjs).
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

const failSpec = { value: null };
const memFS = makeFS(() => failSpec.value);
const storeMod = load('entry/src/main/ets/core/SnapshotStore.ets', {
  '@ohos.file.fs': { default: memFS },
  '@ohos.app.ability.common': {}
});
const probeMod = load('entry/src/main/ets/core/ProbeStore.ets', {
  './SnapshotStore': storeMod,
  '../model/Store': { LogStore: { addLog: () => {} } },
  '@ohos.file.fs': { default: memFS },
  '@ohos.app.ability.common': {}
});
const Store = probeMod.ProbeStore;

const ctx = { filesDir: 'C:/data/storage/el2/base/haps/entry/files' };
const DIR = `${ctx.filesDir}/probe`;
const FILE = `${DIR}/probe-results-v1.json`;
const tmpFiles = () => [...memFS.files.keys()].filter((p) => p.endsWith('.tmp'));
const diskText = () => memFS.files.get(FILE);
const diskJson = () => JSON.parse(diskText());

function resetFs() {
  memFS.files.clear();
  memFS.dirs.clear();
  failSpec.value = null;
  Store.init(ctx);
}

function mkResult(over) {
  const r = new probeMod.ProbeResultRecord();
  Object.assign(r, over);
  return r;
}

function httpOk(profileId, over) {
  return mkResult(Object.assign({
    profileId: profileId,
    profileConfigHash: 'hash-' + profileId,
    configRevision: 7,
    methodRequested: 'http',
    methodActual: 'http',
    state: 'success',
    latencyMs: 42,
    samples: 3,
    aggregation: 'median',
    target: 'http://cp.cloudflare.com/',
    timeoutMs: 5000,
    expectedStatus: '2xx',
    startedAt: 1000,
    completedAt: 1100,
    path: 'directBound',
    coreCapability: 'v2',
    source: 'manual'
  }, over || {}));
}

function mkRun(runId, results, summary, over) {
  const run = new probeMod.ProbeRunSnapshot();
  run.runId = runId;
  run.generation = 3;
  run.createdAt = 2000;
  run.completedAt = 2100;
  const s = new probeMod.ProbeRunSummary();
  Object.assign(s, summary || { success: results.length });
  run.summary = s;
  run.results = results;
  Object.assign(run, over || {});
  return run;
}

(async () => {
  // ---- 1. init 幂等：空数据、不凭空造文件 ----
  memFS.files.clear(); memFS.dirs.clear(); failSpec.value = null;
  Store.init(ctx);
  const firstInit = Store.stats();
  Store.init(ctx); // 幂等
  assert.equal(Store.isInitialized(), true);
  assert.deepEqual({ runs: Store.stats().runs, results: Store.stats().results, latest: Store.stats().latest },
    { runs: 0, results: 0, latest: 0 }, 'fresh init must be empty');
  assert.equal(firstInit.bytes, 0);
  assert.equal(Store.loadRuns().length, 0);
  assert.equal(Store.latestAll().length, 0);
  assert.equal(Store.latestFor('p', 'h', 'http', 't', '2xx', 'directBound'), null);
  assert.equal(memFS.files.has(FILE), false, 'init with a missing file must not create one');
  console.log('PASS init is idempotent, empty by default and creates no file');

  // ---- 2. saveRun → latestFor 命中复合键；HTTP/TCP、target/policy/path 互不覆盖 ----
  resetFs();
  const runA = mkRun('run-a', [
    httpOk('node-1'),
    httpOk('node-1', { methodRequested: 'tcp', methodActual: 'tcp', state: 'failed', latencyMs: -1,
      errorCode: 'timeout', expectedStatus: 'any', path: 'currentTunnel' })
  ]);
  const saved = await Store.saveRun(runA);
  assert.equal(saved, true, 'saveRun must report true only after a verified atomic write');
  const httpHit = Store.latestFor('node-1', 'hash-node-1', 'http', 'http://cp.cloudflare.com/', '2xx', 'directBound');
  assert.ok(httpHit !== null, 'latestFor must hit the composite key');
  assert.equal(httpHit.state, 'success');
  assert.equal(httpHit.latencyMs, 42);
  assert.equal(httpHit.aggregation, 'median');
  assert.equal(httpHit.samples, 3);
  assert.equal(httpHit.generation, 3, 'latest projection must carry run metadata');
  assert.ok(httpHit.persistedAt > 0, 'persistedAt must be stamped only after a successful write');
  const tcpHit = Store.latestFor('node-1', 'hash-node-1', 'tcp', 'http://cp.cloudflare.com/', 'any', 'currentTunnel');
  assert.ok(tcpHit !== null, 'TCP fallback must be stored separately from the HTTP attempt');
  assert.equal(tcpHit.state, 'failed');
  assert.equal(tcpHit.latencyMs, -1, '未测 must stay -1, never 0');
  assert.equal(Store.latestAll().length, 2, 'HTTP and TCP results must not overwrite each other');
  // 其它维度（target / policy / path）同样互不覆盖
  const runA2 = mkRun('run-a2', [
    httpOk('node-1', { target: 'http://other.example/' }),
    httpOk('node-1', { expectedStatus: 'any' }),
    httpOk('node-1', { path: 'legacyUnknown' })
  ]);
  assert.equal(await Store.saveRun(runA2), true);
  assert.equal(Store.latestAll().length, 5, 'each (target|policy|path) variant is a separate comparable result');
  const onDisk = diskJson();
  assert.equal(onDisk.schemaVersion, 1);
  assert.equal(onDisk.runs.length, 2);
  assert.equal(onDisk.runs[0].runId, 'run-a2', 'runs are stored newest-first');
  console.log('PASS saveRun → latestFor hits composite key; HTTP/TCP/target/policy/path stay distinct');

  // ---- 3. 写失败：false + 内存保留 + persistedAt 为空 + markUnsaved 标 unsaved ----
  resetFs();
  assert.equal(await Store.saveRun(mkRun('run-ok', [httpOk('node-1')])), true);
  const textBeforeFailure = diskText();
  failSpec.value = { op: 'writeSync', pathIncludes: 'probe-results' };
  const runFail = mkRun('run-fail', [httpOk('node-2', { latencyMs: 77 })]);
  const failedSave = await Store.saveRun(runFail);
  assert.equal(failedSave, false, 'a failed write must never be reported as saved');
  assert.equal(diskText(), textBeforeFailure, 'disk content must be untouched by a failed write');
  const memHit = Store.latestFor('node-2', 'hash-node-2', 'http', 'http://cp.cloudflare.com/', '2xx', 'directBound');
  assert.ok(memHit !== null, 'the failed run must still be readable from memory');
  assert.equal(memHit.latencyMs, 77);
  assert.equal(memHit.persistedAt, 0, 'persistedAt must stay 0 when the write failed');
  assert.equal(tmpFiles().length, 0, 'a failed write must not leave .tmp residue');
  await Store.markUnsaved('run-fail');
  const marked = Store.latestFor('node-2', 'hash-node-2', 'http', 'http://cp.cloudflare.com/', '2xx', 'directBound');
  assert.equal(marked.state, 'unsaved', 'markUnsaved must flip the stored state to unsaved');
  assert.equal(marked.stateBeforeUnsaved, 'success', 'the pre-unsaved state must be preserved for the UI');
  assert.equal(marked.persistedAt, 0, 'unsaved results are still not persisted');
  const runAfterMark = Store.loadRuns().find((r) => r.runId === 'run-fail');
  assert.equal(runAfterMark.summary.unsaved, 1, 'summary must count the unsaved result');
  assert.equal(runAfterMark.summary.success, 0, 'summary success count must be decremented');
  // 写失败后再成功：同一轮可再次提交并真正落盘
  failSpec.value = null;
  assert.equal(await Store.saveRun(runFail), true, 'the same run can be committed once storage recovers');
  assert.ok(Store.latestFor('node-2', 'hash-node-2', 'http', 'http://cp.cloudflare.com/', '2xx', 'directBound').persistedAt > 0);
  console.log('PASS write failure: false + in-memory readable + persistedAt=0 + markUnsaved/unsaved summary');

  // ---- 4. 损坏文件：空数据、不崩、best-effort 写回可解析的空状态 ----
  memFS.files.clear(); memFS.dirs.clear(); failSpec.value = null;
  memFS.files.set(FILE, '{broken json');
  Store.init(ctx);
  assert.equal(Store.loadRuns().length, 0, 'corrupt file must load as empty, not crash');
  assert.equal(Store.latestAll().length, 0);
  assert.ok(Store.getLoadError().includes('解析失败'), `load error must explain corruption, got "${Store.getLoadError()}"`);
  assert.equal(JSON.parse(diskText()).schemaVersion, 1, 'corrupt file must be rewritten best-effort as an empty v1 state');
  assert.equal(JSON.parse(diskText()).runs.length, 0);
  assert.equal(await Store.saveRun(mkRun('run-after-corrupt', [httpOk('node-1')])), true,
    'saving must work again after a corrupt file');
  console.log('PASS corrupt file: empty state, no crash, best-effort rewrite, saving recovers');

  // ---- 5. 未来 schemaVersion：拒绝加载 + 保留原文件不覆盖 ----
  memFS.files.clear(); memFS.dirs.clear(); failSpec.value = null;
  const futureText = JSON.stringify({
    schemaVersion: 2,
    updatedAt: 123,
    runs: [{ runId: 'from-future', generation: 1, createdAt: 1, completedAt: 2,
      summary: { success: 1, failed: 0, notApplicable: 0, cancelled: 0, unsaved: 0 },
      results: [{ runId: 'from-future', profileId: 'node-9', state: 'success', latencyMs: 5 }] }]
  });
  memFS.files.set(FILE, futureText);
  Store.init(ctx);
  assert.equal(Store.loadRuns().length, 0, 'a future schema must not be loaded');
  assert.equal(Store.isFutureSchemaBlocked(), true);
  assert.ok(Store.getLoadError().includes('版本过新'), 'load error must name the schema problem');
  assert.equal(await Store.saveRun(mkRun('run-new', [httpOk('node-1')])), false,
    'writes must be refused while a newer schema owns the file');
  assert.equal(diskText(), futureText, 'the future-version file must be preserved byte-for-byte');
  // 用户显式清空可以解除只读
  await Store.clear();
  assert.equal(Store.isFutureSchemaBlocked(), false);
  assert.equal(memFS.files.has(FILE), false);
  console.log('PASS future schema: refused load, writes blocked, original file preserved');

  // ---- 6. prune：只留最近 N 轮，latest 不指向已删除结果 ----
  resetFs();
  for (let i = 1; i <= 5; i++) {
    await Store.saveRun(mkRun(`run-${i}`, [httpOk(`node-${i}`, { latencyMs: i * 10 })]));
  }
  assert.equal(Store.stats().runs, 5);
  assert.equal(Store.latestAll().length, 5);
  const removed = await Store.prune(2);
  assert.equal(removed, 3, 'prune must report the number of removed runs');
  assert.equal(Store.stats().runs, 2);
  const kept = Store.loadRuns();
  // 注意：loadRuns 的数组来自 vm realm，deepStrictEqual 会比较原型 —— 先用宿主 Array.from 物化
  assert.deepEqual(Array.from(kept, (r) => r.runId), ['run-5', 'run-4'], 'newest runs survive, newest first');
  assert.equal(Store.latestAll().length, 2, 'latest must be rebuilt from the surviving runs');
  assert.ok(Store.latestFor('node-5', 'hash-node-5', 'http', 'http://cp.cloudflare.com/', '2xx', 'directBound') !== null);
  assert.equal(Store.latestFor('node-1', 'hash-node-1', 'http', 'http://cp.cloudflare.com/', '2xx', 'directBound'),
    null, 'latest must never point at a pruned result');
  // 磁盘同步裁剪
  Store.init(ctx);
  assert.equal(Store.stats().runs, 2, 'prune must be persisted');
  console.log('PASS prune keeps newest N runs and rebuilds latest without dangling keys');

  // ---- 7. 突然终止恢复：两次提交后重启读回两轮，且无半写文件 ----
  resetFs();
  assert.equal(await Store.saveRun(mkRun('run-A', [httpOk('node-a')])), true);
  assert.equal(await Store.saveRun(mkRun('run-B', [httpOk('node-b')])), true);
  assert.equal(tmpFiles().length, 0, 'no .tmp residue after successful commits');
  Store.init(ctx); // 模拟进程重启：只依赖磁盘
  const afterRestart = Store.loadRuns();
  assert.deepEqual(Array.from(afterRestart, (r) => r.runId), ['run-B', 'run-A'], 'both committed runs survive a restart');
  assert.ok(Store.latestFor('node-a', 'hash-node-a', 'http', 'http://cp.cloudflare.com/', '2xx', 'directBound') !== null,
    'results from older runs still answer latestFor after restart');
  assert.equal(JSON.parse(diskText()).runs.length, 2);
  console.log('PASS abrupt-termination recovery: every run is one atomic commit, both survive restart');

  // ---- 8. 单写者并发：并发 save 串行且不丢轮次 ----
  resetFs();
  const saves = await Promise.all([
    Store.saveRun(mkRun('run-1', [httpOk('node-1')])),
    Store.saveRun(mkRun('run-2', [httpOk('node-2')])),
    Store.saveRun(mkRun('run-3', [httpOk('node-3')]))
  ]);
  assert.deepEqual(saves, [true, true, true], 'all concurrent saves must succeed');
  assert.equal(Store.stats().runs, 3, 'no run may be lost by concurrent writes');
  assert.equal(Store.latestAll().length, 3);
  assert.equal(diskJson().runs.length, 3, 'disk must contain all three runs');
  console.log('PASS concurrent saveRun calls serialize without losing runs');

  // ---- 9. 同 runId 分块/重试提交：按结果复合键合并，不整轮覆盖 ----
  resetFs();
  assert.equal(await Store.saveRun(mkRun('run-m', [httpOk('node-1', { latencyMs: 10 })])), true);
  assert.equal(await Store.saveRun(mkRun('run-m', [
    httpOk('node-1', { latencyMs: 20 }),
    httpOk('node-2', { latencyMs: 30 })
  ])), true);
  const merged = Store.loadRuns();
  assert.equal(merged.length, 1, 'same runId must not create a second run');
  assert.equal(merged[0].results.length, 2, 'chunked commits must merge, not replace');
  assert.equal(Store.latestFor('node-1', 'hash-node-1', 'http', 'http://cp.cloudflare.com/', '2xx', 'directBound').latencyMs,
    20, 'the later chunk must update the existing result');
  console.log('PASS same-runId chunked commit merges by composite key');

  // ---- 10. queued/running 不进 latest，但仍在历史里（§6.3 运行中不清旧结果） ----
  resetFs();
  const running = mkResult(Object.assign(httpOk('node-r'), { state: 'running', latencyMs: -1 }));
  assert.equal(await Store.saveRun(mkRun('run-r', [running])), true);
  assert.equal(Store.latestAll().length, 0, 'running results must not enter the latest map');
  assert.equal(Store.loadRuns()[0].results.length, 1, 'running results are still part of the run history');
  await Store.markUnsaved('run-r');
  assert.equal(Store.loadRuns()[0].results[0].state, 'running',
    'markUnsaved must not rewrite queued/running results');
  console.log('PASS queued/running results stay out of latest and are untouched by markUnsaved');

  // ---- 11. stats：轮数/结果数/latest 数/文件字节 ----
  resetFs();
  assert.equal(await Store.saveRun(mkRun('run-s1', [
    httpOk('node-1'), httpOk('node-2', { methodActual: 'tcp', methodRequested: 'tcp' })
  ])), true);
  assert.equal(await Store.saveRun(mkRun('run-s2', [httpOk('node-3')])), true);
  const stats = Store.stats();
  assert.equal(stats.runs, 2);
  assert.equal(stats.results, 3);
  assert.equal(stats.latest, 3);
  assert.ok(stats.bytes > 0, 'bytes must reflect the persisted file size');
  assert.equal(stats.bytes, diskText().length);
  await Store.clear();
  const cleared = Store.stats();
  assert.deepEqual({ runs: cleared.runs, results: cleared.results, latest: cleared.latest, bytes: cleared.bytes },
    { runs: 0, results: 0, latest: 0, bytes: 0 }, 'clear must reset memory and remove the file');
  assert.equal(memFS.files.has(FILE), false);
  console.log('PASS stats reports runs/results/latest/bytes; clear resets everything');

  // ---- 12. 复合键转义：'|' 不能制造键歧义 ----
  assert.notEqual(
    probeMod.probeKey('a|b', 'h', 'http', 't', '2xx', 'directBound'),
    probeMod.probeKey('a', 'b|h', 'http', 't', '2xx', 'directBound'),
    'a literal | in a field must not shift into another field'
  );
  assert.equal(
    probeMod.probeKey('p', 'h', 'HTTP', 'T', '2XX', 'DIRECTBOUND'),
    probeMod.probeKey('p', 'h', 'http', 'T', '2xx', 'directBound'),
    'method/policy/path are case-normalized; target keeps its case'
  );
  assert.notEqual(
    probeMod.probeKey('p', 'h', 'http', 'T', '2xx', 'directBound'),
    probeMod.probeKey('p', 'h', 'http', 't', '2xx', 'directBound'),
    'target must stay case-sensitive'
  );
  console.log('PASS composite key escaping/case rules are unambiguous');

  // ---- 13. 缺文件 → 不崩、不写；随后 saveRun 正常建文件 ----
  memFS.files.clear(); memFS.dirs.clear(); failSpec.value = null;
  Store.init(ctx);
  assert.equal(Store.getLoadError(), '');
  assert.equal(Store.isFutureSchemaBlocked(), false);
  assert.equal(await Store.saveRun(mkRun('run-first', [httpOk('node-1')])), true);
  assert.equal(memFS.files.has(FILE), true);
  assert.equal(tmpFiles().length, 0);
  console.log('PASS missing file: clean init, first save creates the file atomically');

  console.log('\nALL probe-store checks passed');
})().catch((e) => { console.error('FAIL', e); process.exit(1); });
