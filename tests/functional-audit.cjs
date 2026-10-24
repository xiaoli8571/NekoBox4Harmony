// Execute production page methods with only platform boundaries mocked.
// Covers storage failure and concurrent edits during a long latency batch.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:/Program Files/Huawei/DevEco Studio/sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));
const source = file => fs.readFileSync(path.join(root, 'entry/src/main/ets', file), 'utf8');
function between(text, start, end) {
  const from = text.indexOf(start);
  const to = text.indexOf(end, from);
  assert.ok(from >= 0 && to > from, `missing production method: ${start}`);
  return text.slice(from, to);
}
function page(methods, globals) {
  const js = ts.transpileModule(`class Page { ${methods} }; exports.Page = Page;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const exports = {};
  vm.runInNewContext(js, {
    exports, setTimeout, clearTimeout, $r: key => key,
    LogStore: { addLog() {} }, promptAction: { showToast() {} },
    ...globals
  });
  return new exports.Page();
}

(async () => {
  /* 2026-10-24:分应用管理整体迁到 pages/PerAppManager.ets(设置页撤三按钮后保存即应用) */
  const settingsSource = source('pages/SettingsPage.ets');
  const settingsMethods = between(settingsSource, '  async save(', '  private async switchMode') +
    between(settingsSource, '  private requestApply(', '  /** ResourceStr → 当前语言 string');
  const perAppSource = source('pages/PerAppManager.ets');
  const perAppMethods = between(perAppSource, '  private async saveQuiet(', '  /** 把条目同步进设置对象并持久化') +
    between(perAppSource, '  private async persistPerApp(', '  private reportInvalidPackages');
  for (const fail of [true, false]) {
    let applies = 0;
    let reloads = 0;
    const perApp = page(perAppMethods, {
      saveSettings: async () => { if (fail) throw Error('storage full'); },
      loadSettings: async () => { reloads++; return { perAppEntries: '[]', perAppList: '' }; },
      serializeEntries: () => '[]',
      effectivePackages: () => [],
      invalidBundleNames: () => [],
      parseEntries: () => [],
      $r: key => key
    });
    Object.assign(perApp, {
      s: { perAppEntries: '', perAppList: '' },
      perAppEntries: [],
      reportInvalidPackages() {},
      /* 保存成功才回调 onApplyNow(应用事务);失败只 toast,不拿旧设置去应用 */
      onApplyNow() { applies++; }
    });
    await perApp.persistPerApp('test');
    assert.equal(applies, fail ? 0 : 1, 'per-app: failed save must not apply; success applies exactly once');
    assert.equal(reloads, fail ? 0 : 1, '成功路径保存后回读规范化一次');
  }
  console.log('PASS per-app(PerAppManager) save failure applies nothing; success applies once');

  // 设置页本体:保存即自动应用(save→requestApply→onApplyDraft)
  for (const fail of [true, false]) {
    let changed = 0;
    let applies = 0;
    const p = page(settingsMethods, {
      saveSettings: async () => { if (fail) throw Error('storage full'); }
    });
    Object.assign(p, {
      s: {}, dirty: true, context: {}, applying: false,
      onSettingsChanged() { changed++; },
      onApplyDraft() { applies++; },
      currentDiff() { return { total: 1, reconnectCount: 1 }; },
      bumpApplyBar() {}
    });
    const ok = await p.save();
    assert.equal(ok, !fail, 'save() resolves success only when storage write succeeds');
    assert.equal(changed, fail ? 0 : 1);
    assert.equal(applies, fail ? 0 : 1, 'failed save must not apply old settings');
    assert.equal(p.dirty, fail);
  }
  console.log('PASS settings save failure retains dirty state; success auto-applies once');

  const indexMethods = between(source('pages/Index.ets'),
    '  private async runProfilesTest(', '  /** 取消进行中的测速');
  for (const failWrite of [false, true]) {
    const latest = [
      { id: 'kept', name: 'edited while testing', server: 'new.example', status: 0 },
      { id: 'added', name: 'new subscription node', status: 1, ping: 89 },
      { id: 'unmeasured', status: 1, ping: 123, latencyMs: 123 }
    ];
    let merged;
    const p = page(indexMethods, {
      AppStorage: { get: () => '' }, publishVpnLatency() {},
      testProfiles: async (_targets, callback) => {
        callback({ id: 'deleted', status: 1, ping: 22, error: '' });
        callback({ id: 'kept', status: 1, ping: 42, error: '' });
      },
      mutateProfiles: async fn => {
        if (failWrite) throw Error('storage full');
        merged = fn(latest);
        return merged;
      }
    });
    Object.assign(p, {
      profiles: [{ id: 'deleted' }, { id: 'kept', name: 'old name', server: 'old.example' }],
      testing: false, isRunning: false, settings: {}, bumpResults() {}
    });
    await p.runProfilesTest(p.profiles.slice(), 'tcp');
    assert.equal(p.testing, false, 'storage failure must release the testing guard');
    if (!failWrite) {
      assert.equal(merged.length, 3);
      assert.ok(!merged.some(x => x.id === 'deleted'), 'a deleted node must not be resurrected');
      assert.equal(merged.find(x => x.id === 'kept').name, 'edited while testing');
      assert.equal(merged.find(x => x.id === 'kept').server, 'new.example');
      assert.equal(merged.find(x => x.id === 'kept').ping, 42);
      assert.equal(merged.find(x => x.id === 'added').ping, 89);
      assert.equal(merged.find(x => x.id === 'unmeasured').ping, 123);
    }
  }
  console.log('PASS latency saves preserve added/edited/deleted and unmeasured nodes');
  console.log('PASS latency storage failure releases the testing guard');

  for (const report of [
    { degraded: true, degradeReason: 'batch start failed', bindFallback: false },
    { degraded: false, degradeReason: '', bindFallback: true }
  ]) {
    const toasts = [];
    const p = page(indexMethods, {
      AppStorage: { get: () => '' },
      promptAction: { showToast: value => toasts.push(value.message) },
      urlTestProfiles: async () => report,
      mutateProfiles: async fn => fn([])
    });
    Object.assign(p, { profiles: [], settings: {}, groups: [], context: {}, bumpResults() {} });
    await p.runProfilesTest([], 'url');
    assert.ok(toasts.includes(report.degraded ? 'app.string.speed_test_degraded' : 'app.string.speed_test_bind_fallback'));
    assert.ok(!toasts.includes('app.string.speed_test_complete'), 'completion toast must not overwrite fallback warning');
  }
  console.log('PASS TCPing and interface-binding fallback warnings remain visible');
})().catch(e => { console.error(e); process.exitCode = 1; });
