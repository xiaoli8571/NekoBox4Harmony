// Executes the production RuleSetRepository (§7.5 下载/验证缓存/失败策略/GC) against an
// in-memory file boundary with an injected fetcher + SRS validator. No network, no kernel.
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

// Binary-safe in-memory FS (files stored as Buffers, like a real filesystem).
function makeFS() {
  const files = new Map();
  const dirs = new Set();
  const fdMap = new Map();
  let nextFd = 100;
  const OPEN_CREATE = 64;
  return {
    files, dirs,
    accessSync: (p) => files.has(p) || dirs.has(p),
    mkdirSync: (p) => { dirs.add(p); },
    openSync: (p, mode) => {
      if (!files.has(p) && !dirs.has(p)) {
        if (!(mode & OPEN_CREATE)) throw new Error(`open missing: ${p}`);
        files.set(p, Buffer.alloc(0));
      }
      const fd = nextFd++;
      fdMap.set(fd, { path: p });
      return { fd };
    },
    writeSync: (fd, data) => {
      const h = fdMap.get(fd);
      const buf = data instanceof ArrayBuffer ? Buffer.from(new Uint8Array(data)) : Buffer.from(String(data), 'utf8');
      files.set(h.path, buf);
      return buf.length;
    },
    fsyncSync: () => {},
    closeSync: (file) => { fdMap.delete(file.fd); },
    readSync: (fd, buffer, options) => {
      const h = fdMap.get(fd);
      const data = files.get(h.path) || Buffer.alloc(0);
      const start = options && options.offset ? options.offset : 0;
      const want = options && options.length ? options.length : buffer.byteLength;
      const len = Math.min(want, data.length - start);
      new Uint8Array(buffer, 0, len).set(data.subarray(start, start + len));
      return len;
    },
    renameSync: (from, to) => {
      if (!files.has(from)) throw new Error(`rename missing: ${from}`);
      files.set(to, files.get(from));
      files.delete(from);
    },
    unlinkSync: (p) => { files.delete(p); },
    readTextSync: (p) => {
      if (!files.has(p)) throw new Error(`no file: ${p}`);
      return Buffer.from(files.get(p)).toString('utf8');
    },
    listFileSync: (dir) => {
      const out = [];
      const prefix = `${dir}/`;
      for (const p of files.keys()) {
        if (p.startsWith(prefix)) out.push(p.substring(prefix.length));
      }
      for (const d of dirs) {
        if (d.startsWith(prefix)) out.push(d.substring(prefix.length));
      }
      return out;
    },
    statSync: (p) => ({ isDirectory: () => dirs.has(p), size: files.has(p) ? files.get(p).length : 0 }),
    OpenMode: { READ_ONLY: 4, READ_WRITE: 2, CREATE: 64, TRUNC: 512 }
  };
}

const memFS = makeFS();
const errTextMod = load('entry/src/main/ets/utils/ErrText.ets', { '@ohos.base': { default: {} } });
const validatorMod = load('entry/src/main/ets/core/ResourceValidator.ets', { '../utils/ErrText': errTextMod });
const storeMod = load('entry/src/main/ets/core/SnapshotStore.ets', {
  '@ohos.file.fs': { default: memFS },
  '@ohos.app.ability.common': {}
});
const repoMod = load('entry/src/main/ets/core/RuleSetRepository.ets', {
  '@ohos.file.fs': { default: memFS },
  '@ohos.net.http': { default: { createHttp: () => ({ destroy: () => {} }) } },
  '@ohos.app.ability.common': {},
  './SnapshotStore': storeMod,
  '../model/Store': { LogStore: { addLog: () => {} } },
  '../utils/ErrText': errTextMod,
  './ResourceValidator': validatorMod
});
const repo = repoMod.RuleSetRepository;

const ctx = { filesDir: 'C:/data/storage/el2/base/haps/entry/files' };
const RES = `${ctx.filesDir}/config/resources`;
const sha256 = validatorMod.sha256Hex;

function srsBytes(fill, size = 8192) {
  const b = Buffer.alloc(size);
  b[0] = 0x53; b[1] = 0x52; b[2] = 0x53; // "SRS" magic
  b.fill(fill, 3);
  return b;
}
function okFetch(data) {
  return { fetch: async (req) => { memFS.files.set(req.targetPath, Buffer.from(data)); return { ok: true, statusCode: 200, declaredBytes: data.length, bytesWritten: data.length, error: '' }; } };
}
function statusFetch(code) {
  return { fetch: async () => ({ ok: false, statusCode: code, declaredBytes: -1, bytesWritten: 0, error: '' }) };
}
function declaredTooLargeFetch(total) {
  return { fetch: async () => ({ ok: false, statusCode: 200, declaredBytes: total, bytesWritten: 0, error: '' }) };
}
async function freshStore() {
  memFS.files.clear();
  memFS.dirs.clear();
  repo.init(ctx);
}
const dirFiles = (id) => memFS.listFileSync(`${RES}/${id}`).filter((n) => !n.startsWith('download-'));
const tmpFiles = () => [...memFS.files.keys()].filter((p) => p.endsWith('.tmp'));
const readManifestJson = () => JSON.parse(memFS.files.get(`${RES}/manifest.json`).toString('utf8'));

(async () => {
  // ---- 0. 纯工具：SHA-256 已知向量 + URL 校验 + ID 安全化 ----
  assert.equal(sha256(new Uint8Array(0)), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  assert.equal(sha256(new TextEncoder().encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  const long = new Uint8Array(1000); long.fill(7);
  assert.equal(sha256(long).length, 64, 'sha256 of 1000 bytes must be 64 hex chars');
  console.log('PASS sha256 matches known vectors (empty / abc / 1000 bytes)');

  assert.equal(repo.validateUrl('https://raw.example.test/rule-set/geosite-cn.srs'), '');
  assert.equal(repo.validateUrl('http://mirror.example.test/a.json'), '');
  assert.notEqual(repo.validateUrl('ftp://example.test/x.srs'), '', 'non-http schemes must be rejected');
  assert.notEqual(repo.validateUrl(''), '', 'empty URL must be rejected');
  assert.notEqual(repo.validateUrl(`https://a.test/${'x'.repeat(2100)}.srs`), '', 'overlong URL must be rejected');
  assert.notEqual(repo.validateUrl('https://a.test/a b.srs'), '', 'URL with whitespace must be rejected');
  console.log('PASS validateUrl: http/https only, length cap, whitespace/control chars rejected');

  const traversal = repoMod.sanitizeResourceId('../../etc/passwd');
  assert.ok(!traversal.includes('/') && !traversal.includes('..') && !traversal.startsWith('.'),
    `sanitized id must be a safe single path segment, got ${traversal}`);
  assert.notEqual(repoMod.sanitizeResourceId('..'), '..');
  assert.notEqual(repoMod.sanitizeResourceId('.'), '.');
  assert.equal(repoMod.sanitizeResourceId(''), '');
  assert.equal(repoMod.sanitizeResourceId('geosite-cn'), 'geosite-cn');
  const dirA = repoMod.sanitizeResourceId('a');
  const dirB = repoMod.sanitizeResourceId('a/../b');
  assert.notEqual(dirA, dirB, 'different raw ids must not collide after sanitization');
  console.log('PASS sanitizeResourceId blocks path traversal and keeps stable ids distinct');

  // ---- 1. 首次下载成功 + 内核验证通过 → available，manifest 落盘，文件在版本目录 ----
  await freshStore();
  repo.setFetcher(okFetch(srsBytes(0x11)));
  repo.setValidator(validatorMod.ResourceValidator.fromKernelBridge(async () => ''));
  const a1 = await repo.ensureResource('geosite-cn', 'https://raw.example.test/geosite-cn.srs');
  assert.equal(a1.available, true, 'verified first download must be available');
  assert.equal(a1.verified, true, 'kernel-k1 pass must mark verified');
  assert.equal(a1.state, 'ready');
  assert.equal(a1.fromCache, false, 'first download is not from cache');
  assert.equal(a1.reason, 'downloaded-verified');
  assert.equal(a1.error, '');
  const m1 = readManifestJson();
  const e1 = m1.resources['geosite-cn'];
  assert.ok(e1, 'manifest must record the resource');
  assert.equal(e1.currentHash.length, 64, 'currentHash must be the sha256 hex');
  assert.equal(e1.currentHash, sha256(srsBytes(0x11)), 'currentHash must match content hash');
  assert.ok(e1.validatedAt > 0, 'resource-level validatedAt must be set when verified');
  assert.ok(e1.lastSuccessfulDownloadAt > 0 && e1.lastAttemptAt > 0);
  assert.equal(e1.lastError, '');
  assert.equal(e1.versions.length, 1);
  assert.equal(e1.versions[0].file, `${e1.currentHash}.srs`, 'version file must be <hash>.srs');
  assert.equal(e1.versions[0].validatedAt > 0, true, 'version validatedAt set');
  assert.equal(e1.versions[0].engine, 'kernel-k1');
  assert.equal(e1.failurePolicy, 'block', 'default failure policy is block');
  const versionFile = `${RES}/geosite-cn/${e1.currentHash}.srs`;
  assert.ok(memFS.files.has(versionFile), 'version file must exist in the version dir');
  assert.ok(Buffer.from(memFS.files.get(versionFile)).equals(srsBytes(0x11)), 'stored bytes must equal the download');
  assert.equal(repo.cachedFilePath('geosite-cn'), versionFile, 'cachedFilePath must expose the verified path');
  console.log('PASS first download + kernel validation: available, manifest committed, file versioned');

  // ---- 2. 首次 503 无缓存 → available=false(block)，无缓存文件，lastError 记录 ----
  await freshStore();
  repo.setFetcher(statusFetch(503));
  repo.setValidator(validatorMod.ResourceValidator.fromKernelBridge(async () => ''));
  const a2 = await repo.ensureResource('geoip-cn', 'https://raw.example.test/geoip-cn.srs');
  assert.equal(a2.available, false, 'first download failure with no cache must be unavailable (block)');
  assert.equal(a2.fromCache, false);
  assert.equal(a2.rejected, 'http-status');
  assert.ok(a2.error.includes('503'), `error must carry the status, got ${a2.error}`);
  assert.equal(a2.state, 'unavailable');
  const dir2 = `${RES}/geoip-cn`;
  assert.equal(memFS.listFileSync(dir2).filter((n) => !n.endsWith('.tmp')).length, 0,
    'no cache file may exist after a failed first download');
  assert.equal(tmpFiles().length, 0, 'temp file must be cleaned after failure');
  const m2 = readManifestJson();
  const e2 = m2.resources['geoip-cn'];
  assert.ok(e2, 'failure metadata must be visible in the manifest');
  assert.equal(e2.currentHash, '', 'no currentHash without cache');
  assert.ok(e2.lastError.includes('503'), 'lastError must record the failure');
  assert.ok(e2.lastAttemptAt > 0, 'lastAttemptAt must be recorded on failure');
  assert.equal(e2.versions.length, 0);
  console.log('PASS first-download 503 without cache: blocked, no file, failure recorded');

  // ---- 3. 更新 503 有缓存 → available=true/fromCache，lastError 记录、currentHash 不变 ----
  await freshStore();
  repo.setFetcher(okFetch(srsBytes(0x21)));
  repo.setValidator(validatorMod.ResourceValidator.fromKernelBridge(async () => ''));
  const good = await repo.ensureResource('geoip-cn', 'https://raw.example.test/geoip-cn.srs');
  assert.equal(good.available, true);
  const cachedHash = good.currentHash;
  const cachedAt = good.cachedAt;
  repo.setFetcher(statusFetch(503));
  await new Promise((r) => setTimeout(r, 5)); // 让 lastAttemptAt 严格晚于 lastSuccessfulDownloadAt
  const stale = await repo.ensureResource('geoip-cn', 'https://raw.example.test/geoip-cn.srs');
  assert.equal(stale.available, true, 'update failure with verified cache must stay available');
  assert.equal(stale.fromCache, true, 'availability must be reported as fromCache');
  assert.equal(stale.verified, true, 'cached version is still verified');
  assert.equal(stale.reason, 'update-failed-using-cache');
  assert.ok(stale.error.includes('503'), 'availability error must carry the update failure');
  assert.equal(stale.currentHash, cachedHash, 'currentHash must not change on failed update');
  assert.ok(stale.cachedAt === cachedAt, 'cachedAt must stay at the last successful download');
  const m3 = readManifestJson();
  const e3 = m3.resources['geoip-cn'];
  assert.equal(e3.currentHash, cachedHash);
  assert.ok(e3.lastError.includes('503'), 'manifest lastError must record the failed update');
  assert.ok(e3.lastAttemptAt > e3.lastSuccessfulDownloadAt, 'lastAttemptAt must advance past the last success');
  assert.equal(e3.versions.length, 1, 'failed update must not add a version');
  assert.equal(dirFiles('geoip-cn').length, 1, 'old cache file must remain');
  console.log('PASS update 503 with verified cache: available from cache, error recorded, hash unchanged');

  // ---- 4. 200 但 validator 失败 → 不替换旧缓存，validatedAt 不前移 ----
  await freshStore();
  repo.setFetcher(okFetch(srsBytes(0x31)));
  repo.setValidator(validatorMod.ResourceValidator.fromKernelBridge(async () => ''));
  const base4 = await repo.ensureResource('site', 'https://raw.example.test/site.srs');
  const verifiedAt = base4.cachedAt;
  const prevValidated = readManifestJson().resources['site'].validatedAt;
  repo.setValidator(validatorMod.ResourceValidator.fromKernelBridge(async () => 'err:srs.Read: invalid magic'));
  repo.setFetcher(okFetch(srsBytes(0x32)));
  const corrupt = await repo.ensureResource('site', 'https://raw.example.test/site.srs');
  assert.equal(corrupt.available, true, '200-but-corrupt with existing cache must keep the cache usable');
  assert.equal(corrupt.fromCache, true);
  assert.equal(corrupt.rejected, 'validation-failed');
  assert.ok(corrupt.error.includes('invalid magic'), 'availability error must carry the kernel error text');
  assert.equal(corrupt.currentHash, base4.currentHash, 'corrupt content must not replace the current hash');
  const m4 = readManifestJson();
  const e4 = m4.resources['site'];
  assert.equal(e4.versions.length, 1, 'corrupt download must not add a version');
  assert.equal(e4.validatedAt, prevValidated, 'validatedAt must not advance on a failed validation');
  assert.ok(e4.lastError.includes('invalid magic'));
  assert.equal(dirFiles('site').length, 1, 'only the old cache file remains');
  assert.equal(tmpFiles().length, 0, 'corrupt temp file must be removed');
  console.log('PASS 200-but-corrupt keeps old cache; validatedAt unchanged; kernel error recorded');

  // ---- 5. 超过 32MiB 声明大小 → 拒绝且不落盘 ----
  await freshStore();
  repo.setFetcher(declaredTooLargeFetch(33 * 1024 * 1024));
  repo.setValidator(validatorMod.ResourceValidator.fromKernelBridge(async () => ''));
  const big = await repo.ensureResource('huge', 'https://raw.example.test/huge.srs');
  assert.equal(big.available, false);
  assert.equal(big.rejected, 'too-large');
  assert.ok(big.error.includes('上限'), 'error must name the size limit');
  assert.equal(dirFiles('huge').length, 0, 'oversized resource must not be stored');
  assert.equal(tmpFiles().length, 0, 'no temp residue for oversized downloads');
  assert.equal(readManifestJson().resources['huge'].currentHash, '');
  console.log('PASS declared 33MiB download rejected (too-large), nothing stored');

  // ---- 6. validator=unsupported → 候选落盘但状态 unverified，不得报「已验证」 ----
  await freshStore();
  repo.setFetcher(okFetch(srsBytes(0x41)));
  repo.setValidator(validatorMod.ResourceValidator.unsupported());
  const un = await repo.ensureResource('site', 'https://raw.example.test/site.srs');
  assert.equal(un.verified, false, 'unsupported engine must never report verified');
  assert.equal(un.state, 'unverified', 'resource state must be unverified');
  assert.equal(un.available, false, 'default block policy must not hand out unverified candidates');
  assert.equal(un.reason, 'unverified-candidate');
  assert.ok(un.error.includes('CGoValidateSRSFileV1'), 'error must name the missing capability');
  const m6 = readManifestJson();
  const e6 = m6.resources['site'];
  assert.ok(e6.currentHash.length === 64, 'candidate must still be stored with its hash');
  assert.equal(e6.validatedAt, 0, 'resource validatedAt must stay 0 when unverified');
  assert.equal(e6.versions[0].validatedAt, 0, 'version validatedAt must stay 0 when unverified');
  assert.equal(e6.versions[0].engine, 'unsupported');
  assert.ok(dirFiles('site').length === 1, 'candidate file saved in the version dir');
  assert.equal(repo.cachedFilePath('site'), '', 'cachedFilePath must not expose a blocked candidate');
  // 用户显式接受未验证候选 → 可用但 verified 仍为 false
  const allowed = await repo.setFailurePolicy('site', 'allow-unverified');
  assert.equal(allowed, true, 'explicit policy change must be recorded');
  const un2 = repo.getAvailability('site');
  assert.equal(un2.available, true, 'allow-unverified policy may hand out the candidate');
  assert.equal(un2.verified, false, 'policy change must not fake verification');
  assert.equal(un2.state, 'unverified');
  assert.notEqual(repo.cachedFilePath('site'), '', 'cachedFilePath exposes the candidate under allow-unverified');
  assert.equal(await repo.setFailurePolicy('site', 'pause-forever'), false, 'unknown policy must be rejected');
  console.log('PASS unsupported validator: unverified candidate, blocked by default, explicit policy opt-in');

  // ---- 7. 版本 GC：3 个版本后仅保留 current + previous ----
  await freshStore();
  repo.setValidator(validatorMod.ResourceValidator.fromKernelBridge(async () => ''));
  const hashes = [];
  for (const fill of [0x51, 0x52, 0x53]) {
    repo.setFetcher(okFetch(srsBytes(fill)));
    const r = await repo.ensureResource('site', 'https://raw.example.test/site.srs');
    hashes.push(r.currentHash);
  }
  const kept = dirFiles('site');
  assert.equal(kept.length, 2, `only current + previous may remain, got [${kept}]`);
  assert.ok(kept.includes(`${hashes[2]}.srs`), 'current version must remain');
  assert.ok(kept.includes(`${hashes[1]}.srs`), 'previous version must remain');
  assert.ok(!kept.includes(`${hashes[0]}.srs`), 'oldest version must be collected');
  const m7 = readManifestJson();
  assert.equal(m7.resources['site'].versions.length, 2, 'manifest keeps at most 2 versions');
  assert.equal(m7.resources['site'].currentHash, hashes[2]);
  console.log('PASS version GC keeps current + previous after 3 downloads');

  // ---- 8. manifest 损坏 / 丢失 → 不崩，按无缓存处理，可重新下载 ----
  await freshStore();
  repo.setFetcher(okFetch(srsBytes(0x61)));
  repo.setValidator(validatorMod.ResourceValidator.fromKernelBridge(async () => ''));
  const first8 = await repo.ensureResource('site', 'https://raw.example.test/site.srs');
  assert.equal(first8.available, true);
  memFS.files.set(`${RES}/manifest.json`, Buffer.from('{broken', 'utf8'));
  const corruptManifest = repo.getAvailability('site');
  assert.equal(corruptManifest.available, false, 'corrupt manifest must not report availability');
  assert.equal(corruptManifest.reason, 'manifest-corrupt');
  assert.equal(repo.cachedFilePath('site'), '', 'corrupt manifest must not expose a path');
  repo.setFetcher(okFetch(srsBytes(0x62)));
  const redownloaded = await repo.ensureResource('site', 'https://raw.example.test/site.srs');
  assert.equal(redownloaded.available, true, 're-download after corrupt manifest must succeed');
  assert.equal(redownloaded.verified, true);
  assert.ok(memFS.files.has(`${RES}/manifest.json`), 'manifest must be rewritten');
  assert.equal(readManifestJson().resources['site'].currentHash, redownloaded.currentHash);
  console.log('PASS corrupt manifest: no crash, reports cache-lost, recovers by re-download');

  await freshStore();
  repo.setFetcher(okFetch(srsBytes(0x63)));
  repo.setValidator(validatorMod.ResourceValidator.fromKernelBridge(async () => ''));
  const seed = await repo.ensureResource('site', 'https://raw.example.test/site.srs');
  assert.ok(dirFiles('site').length === 1);
  memFS.files.delete(`${RES}/manifest.json`);
  const orphanOnly = repo.getAvailability('site');
  assert.equal(orphanOnly.available, false, 'missing manifest means no trusted cache (files are unreferenced)');
  assert.equal(orphanOnly.reason, 'no-cache');
  repo.setFetcher(okFetch(srsBytes(0x64)));
  const rebuilt = await repo.ensureResource('site', 'https://raw.example.test/site.srs');
  assert.equal(rebuilt.available, true, 're-download with missing manifest must succeed');
  assert.equal(dirFiles('site').length, 1, `orphan version file must be collected, got [${dirFiles('site')}]`);
  assert.notEqual(rebuilt.currentHash, seed.currentHash, 'new content → new hash');
  console.log('PASS missing manifest: unreferenced files not trusted, re-download rebuilds, GC cleans orphan');

  // ---- 9. 并发下载串行化 + 同 hash 去重 + 空响应/HTTP 状态拒绝 ----
  await freshStore();
  repo.setValidator(validatorMod.ResourceValidator.fromKernelBridge(async () => ''));
  let call = 0;
  repo.setFetcher({
    fetch: async (req) => {
      const data = srsBytes(0x70 + call);
      call++;
      memFS.files.set(req.targetPath, Buffer.from(data));
      return { ok: true, statusCode: 200, declaredBytes: data.length, bytesWritten: data.length, error: '' };
    }
  });
  const [c1, c2] = await Promise.all([
    repo.ensureResource('site', 'https://raw.example.test/site.srs'),
    repo.ensureResource('site', 'https://raw.example.test/site.srs')
  ]);
  assert.equal(dirFiles('site').length, 2, 'two distinct contents → current + previous');
  const m9 = readManifestJson();
  assert.equal(m9.resources['site'].versions.length, 2, 'manifest stays consistent under concurrency');
  assert.equal(c2.currentHash.length, 64);
  // 重复下载同一内容：内容寻址去重，不新增版本（否则会把真正的上一版本挤掉）
  repo.setFetcher(okFetch(srsBytes(0x71))); // 与第二次并发下载相同的内容
  const again = await repo.ensureResource('site', 'https://raw.example.test/site.srs');
  assert.equal(again.currentHash, c2.currentHash, 'same bytes → same hash (content addressed)');
  assert.equal(readManifestJson().resources['site'].versions.length, 2, 'same hash must not duplicate a version');
  assert.equal(dirFiles('site').length, 2);
  repo.setFetcher({ fetch: async () => ({ ok: false, statusCode: 200, declaredBytes: 100, bytesWritten: 0, error: '' }) });
  const emptyResp = await repo.ensureResource('site', 'https://raw.example.test/site.srs');
  assert.equal(emptyResp.rejected, 'empty', '0-byte 200 response must be rejected as empty');
  assert.equal(emptyResp.available, true, 'previous cache still usable after empty response');
  repo.setFetcher(statusFetch(404));
  const notFound = await repo.ensureResource('site', 'https://raw.example.test/site.srs');
  assert.equal(notFound.rejected, 'http-status');
  assert.ok(notFound.error.includes('404'));
  assert.equal(notFound.available, true);
  console.log('PASS concurrent downloads serialize; same hash dedups; empty/404 rejected with cache kept');

  // ---- 10. source JSON 格式：语法级校验 → unverified 候选；非法 JSON → 拒绝 ----
  await freshStore();
  repo.setValidator(validatorMod.ResourceValidator.unsupported());
  const srcOk = Buffer.from(JSON.stringify({ version: 3, rules: [{ domain: ['example.com'] }] }), 'utf8');
  repo.setFetcher(okFetch(srcOk));
  const sj = await repo.ensureResource('site-src', 'https://raw.example.test/site.json');
  assert.equal(sj.state, 'unverified', 'source JSON is syntax-checked only, never "verified"');
  assert.equal(sj.verified, false);
  assert.equal(sj.available, false, 'block policy applies to format-only candidates too');
  const m10 = readManifestJson();
  assert.equal(m10.resources['site-src'].versions[0].engine, 'format-only');
  assert.ok(dirFiles('site-src')[0].endsWith('.json'), 'source-json version file uses .json extension');
  repo.setFetcher(okFetch(Buffer.from('{"version":3}', 'utf8')));
  const sjBad = await repo.ensureResource('site-src', 'https://raw.example.test/site.json');
  assert.equal(sjBad.rejected, 'validation-failed', 'source JSON without rules must be rejected');
  assert.equal(sjBad.available, false, 'invalid source JSON with no verified cache is unavailable');
  repo.setFetcher(okFetch(srsBytes(0x81)));
  const sjWrong = await repo.ensureResource('site-src', 'https://raw.example.test/site.json');
  assert.equal(sjWrong.rejected, 'validation-failed', 'binary SRS served for a source-json resource must be rejected');
  console.log('PASS source-json format: syntax-only candidate, missing rules / wrong format rejected');

  // ---- 11. 总缓存上限：超限时拒绝，且被清单引用的大文件不被 GC 删除 ----
  await freshStore();
  repo.setValidator(validatorMod.ResourceValidator.fromKernelBridge(async () => ''));
  repo.setFetcher(okFetch(srsBytes(0x91)));
  await repo.ensureResource('big', 'https://raw.example.test/big.srs');
  const bigPath = repo.currentFilePath('big');
  memFS.files.set(bigPath, Buffer.alloc(257 * 1024 * 1024)); // 已超过 256MiB 总上限
  repo.setFetcher(okFetch(srsBytes(0x92)));
  const over = await repo.ensureResource('other', 'https://raw.example.test/other.srs');
  assert.equal(over.available, false, 'cache over the total limit must refuse the new download');
  assert.equal(over.rejected, 'cache-limit');
  assert.ok(over.error.includes('总缓存'), 'error must name the total cache limit');
  assert.ok(memFS.files.has(bigPath), 'referenced (manifest-recorded) file must survive GC');
  assert.equal(tmpFiles().length, 0);
  console.log('PASS total cache limit refuses new download; referenced file survives GC');

  // ---- 12. removeResource：文件 + 清单条目一起清 ----
  await freshStore();
  repo.setFetcher(okFetch(srsBytes(0xa1)));
  repo.setValidator(validatorMod.ResourceValidator.fromKernelBridge(async () => ''));
  await repo.ensureResource('site', 'https://raw.example.test/site.srs');
  const removed = await repo.removeResource('site');
  assert.equal(removed, true);
  assert.equal(dirFiles('site').length, 0, 'version files deleted with the resource');
  assert.equal(repo.get('site'), null, 'manifest entry removed');
  assert.equal(repo.getAvailability('site').available, false);
  console.log('PASS removeResource deletes files and manifest entry');

  // ---- 13. 未配置 fetcher → 明确失败，不是崩溃/挂起 ----
  await freshStore();
  repo.setValidator(validatorMod.ResourceValidator.fromKernelBridge(async () => ''));
  repo.setFetcher(new repoMod.ResourceFetcher());
  const noFetcher = await repo.ensureResource('site', 'https://raw.example.test/site.srs');
  assert.equal(noFetcher.available, false);
  assert.equal(noFetcher.rejected, 'io-error');
  assert.ok(noFetcher.error.includes('未配置'), 'error must say the fetcher is not wired');
  console.log('PASS unwired fetcher fails explicitly with a clear message');

  // ---- 14. 方案 §7 会话资源稳定：固定文件不被版本裁剪/GC 删除 ----
  await freshStore();
  repo.setValidator(validatorMod.ResourceValidator.fromKernelBridge(async () => ''));
  repo.setFetcher(okFetch(srsBytes(0xb1)));
  const pinnedRes = await repo.ensureResource('pin', 'https://raw.example.test/pin.srs');
  assert.equal(pinnedRes.available, true);
  const v1Path = repo.cachedFilePath('pin');
  assert.ok(memFS.files.has(v1Path), 'first version file must exist');
  repo.pinSessionFiles([v1Path, v1Path, '']);
  assert.equal(repo.pinnedSessionFiles().join('|'), v1Path,
    'pins must be deduped and ignore empty paths');
  // 会话进行中连续刷新两次：版本裁剪 + GC 都不得删掉正在用的 v1
  repo.setFetcher(okFetch(srsBytes(0xb2)));
  const v2 = await repo.ensureResource('pin', 'https://raw.example.test/pin.srs');
  assert.notEqual(v2.currentHash, pinnedRes.currentHash, 'refresh must produce a new hash');
  repo.setFetcher(okFetch(srsBytes(0xb3)));
  const v3 = await repo.ensureResource('pin', 'https://raw.example.test/pin.srs');
  assert.equal(v3.available, true);
  assert.ok(memFS.files.has(v1Path), 'pinned in-session file must survive version trim + GC');
  const v3Path = repo.cachedFilePath('pin');
  assert.ok(memFS.files.has(v3Path), 'current version file must exist');
  assert.equal(readManifestJson().resources['pin'].versions.length, 2, 'manifest keeps only the last two versions');
  // 会话结束：解除固定后旧版本才会被清理（当前版本永远保留）
  repo.releaseSessionFiles();
  assert.equal(repo.pinnedSessionFiles().length, 0, 'release must clear all pins');
  repo.collectGarbage();
  assert.equal(memFS.files.has(v1Path), false, 'unpinned dropped version is collected once the session ends');
  assert.ok(memFS.files.has(repo.cachedFilePath('pin')), 'current version must never be collected');
  console.log('PASS session pins survive trim+GC while running and are collected after release');

  console.log('\nALL ruleset-repository checks passed');
})().catch((e) => { console.error('FAIL', e); process.exit(1); });
