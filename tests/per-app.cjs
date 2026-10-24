// 分应用代理:条目模型 + Store 派生契约 + 扩展侧名单解析。
// 走真实模块(转译后执行),不重写被测逻辑。
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
  vm.runInNewContext(js, { exports, require: n => { if (!(n in imports)) throw Error(n); return imports[n]; } });
  return exports;
}

const pa = load('entry/src/main/ets/model/PerApp.ets');

// ---------- 包名合法性 ----------
assert.equal(pa.isValidBundleName('com.tencent.wechat'), true);
assert.equal(pa.isValidBundleName('  com.jd.hm.mall  '), true);
assert.equal(pa.isValidBundleName('com.tencent.mm'), true, 'all-letter segments are structurally valid');
assert.equal(pa.isValidBundleName('com.tencent-wechat'), false, 'hyphen is not a HarmonyOS bundle char');
assert.equal(pa.isValidBundleName('wechat'), false, 'must be dotted');
assert.equal(pa.isValidBundleName('1com.a'), false, 'must start with a letter');
assert.equal(pa.isValidBundleName('com.'), false, 'must not end with a dot');
assert.equal(pa.isValidBundleName(''), false);
console.log('PASS bundle name validation rejects Android-style / malformed names');

// 零宽字符:从聊天/网页复制包名时最常见的脏输入
assert.equal(pa.normalizeBundleName('\u200bcom.tencent.wechat\ufeff '), 'com.tencent.wechat');
console.log('PASS bundle names are stripped of zero-width/BOM noise');

// ---------- 输入解析:名称备注只用于单个包名 ----------
const one = pa.entriesFromInput('com.tencent.wechat', '微信');
assert.equal(one.length, 1);
assert.equal(one[0].label, '微信');
assert.equal(one[0].enabled, true, 'newly added entries are checked by default');
console.log('PASS single package keeps its name note and is enabled');

const many = pa.entriesFromInput('com.tencent.wechat\ncom.ss.hm.ugc.aweme\ncom.jd.hm.mall', 'IGNORED');
assert.equal(many.length, 3);
assert.equal(many.map(e => e.label).join(','), 'com.tencent.wechat,com.ss.hm.ugc.aweme,com.jd.hm.mall',
  'batch import must not apply the note to every line');
assert.equal(many[0].bundleName, 'com.tencent.wechat');
console.log('PASS batch import splits on newlines/commas and ignores the single-app note');

// 空名称备注回退包名(界面不出现空标题)
const noLabel = pa.entriesFromInput('com.tencent.wechat', '   ');
assert.equal(noLabel[0].label, 'com.tencent.wechat');
console.log('PASS empty name note falls back to the bundle name');

// 去重
const dup = pa.entriesFromInput('com.a.b, com.a.b\ncom.c.d', '');
assert.equal(dup.length, 2);
console.log('PASS duplicate package names collapse to one entry');

// ---------- 旧数据迁移 ----------
const legacy = pa.entriesFromLegacyList('com.tencent.mm, com.example.x\ncom.foo.bar');
assert.equal(legacy.length, 3);
assert.ok(legacy.every(e => e.enabled === true), 'legacy list must stay effective (no silent regression)');
console.log('PASS legacy comma/newline package list migrates as enabled');

const init = pa.initialEntries('com.tencent.mm');
assert.ok(init.length > 1, 'first load must seed the preset catalog');
assert.ok(init.some(e => e.bundleName === 'com.tencent.mm' && e.enabled), 'legacy entry survives preset merge');
assert.ok(init.some(e => e.bundleName === 'com.tencent.wechat' && !e.enabled), 'presets start unchecked');
console.log('PASS first-load seeding merges presets with the legacy list');

// ---------- 勾选门控:未勾选/非法包名绝不进内核名单 ----------
const gated = [
  new pa.PerAppEntry('com.a.checked', 'A', true),
  new pa.PerAppEntry('com.b.unchecked', 'B', false),
  new pa.PerAppEntry('com.c.bad-name', 'C', true),
  new pa.PerAppEntry('com.a.checked', 'A dup', true),
];
const eff = pa.effectivePackages(gated);
assert.equal(JSON.stringify(eff), JSON.stringify(['com.a.checked']),
  'only enabled + valid + deduped packages may reach VpnConfig');
console.log('PASS unchecked and malformed packages are excluded from the effective list');

const bad = pa.invalidBundleNames(gated);
assert.equal(JSON.stringify(bad), JSON.stringify(['com.c.bad-name']));
console.log('PASS malformed package names are reported instead of silently dropped');

// 上限:超过 VpnConfig 容量按 256 截断(不产生系统侧无效配置)
const over = [];
for (let i = 0; i < 300; i++) { over.push(new pa.PerAppEntry(`com.example.app${i}`, '', true)); }
assert.equal(pa.effectivePackages(over).length, pa.PER_APP_MAX_ENTRIES);
console.log('PASS effective list is capped at the VpnConfig limit');

// ---------- 增删改 ----------
let list = pa.mergeEntries([], [new pa.PerAppEntry('com.a.one', 'One', false)]);
list = pa.mergeEntries(list, [new pa.PerAppEntry('com.a.one', 'One updated', true)]);
assert.equal(list.length, 1, 'merge must not duplicate');
assert.equal(list[0].enabled, true, 're-adding an existing entry re-enables it');
list = pa.toggleEntry(list, 'com.a.one', false);
assert.equal(pa.effectivePackages(list).length, 0);
list = pa.removeEntry(list, 'com.a.one');
assert.equal(list.length, 0);
console.log('PASS merge/toggle/remove behave as the UI expects');

// ---------- 剪贴板(安卓口径) ----------
const clip = pa.entriesFromClipboardPayload('false\ncom.tencent.wechat,com.ss.hm.ugc.aweme');
assert.equal(clip.length, 2);
assert.equal(pa.entriesFromClipboardPayload('com.tencent.wechat').length, 0, 'payload without newline is rejected');
assert.equal(pa.entriesFromClipboardPayload('   \n   ').length, 0);
console.log('PASS clipboard payload requires the newline-delimited Android layout');

// ---------- 序列化往返 ----------
const round = pa.parseEntries(pa.serializeEntries([new pa.PerAppEntry('com.a.b', '名字', true)]));
assert.equal(round.length, 1);
assert.equal(round[0].label, '名字');
assert.equal(round[0].enabled, true);
assert.equal(pa.serializeEntries([]), '[]', 'explicitly empty list must not look like "never initialized"');
assert.equal(pa.parseEntries('').length, 0, 'blank means not initialized');
console.log('PASS entry serialization round-trips and keeps empty vs uninitialized distinct');

// ---------- Store 契约:perAppList 永远是勾选项的派生值 ----------
const model = load('entry/src/main/ets/model/Profile.ets', { './PerApp': pa });
const data = new Map();
const prefs = { get: async (k, d) => (data.has(k) ? data.get(k) : d), put: async (k, v) => data.set(k, v), flush: async () => {} };
const store = load('entry/src/main/ets/model/Store.ets', {
  './Profile': model,
  './PerApp': pa,
  '@ohos.data.preferences': { default: { getPreferences: async () => prefs } },
  '@ohos.events.emitter': { default: { emit: () => {}, EventPriority: { LOW: 0 } } }
});

(async () => {
  await store.initStore({});

  // 旧的"只有逗号分隔包名"装机:首次载入必须保留其生效性
  data.set('settings', JSON.stringify({ perAppMode: 'exclude', perAppList: 'com.legacy.one,com.legacy.two', clashApiSecret: 't' }));
  const migrated = await store.loadSettings();
  assert.equal(migrated.perAppMode, 'exclude');
  assert.equal(migrated.perAppList, 'com.legacy.one,com.legacy.two', 'legacy effective list must survive migration');
  const persisted = JSON.parse(data.get('settings'));
  assert.ok(persisted.perAppEntries.includes('com.legacy.one'), 'entries must be written back on first load');
  console.log('PASS real Store migrates a legacy perAppList without losing effectiveness');

  // 落盘后的 perAppList 只含勾选项
  const s = Object.assign(new model.AppSettings(), {
    perAppMode: 'include',
    perAppEntries: pa.serializeEntries([
      new pa.PerAppEntry('com.keep.me', 'Keep', true),
      new pa.PerAppEntry('com.skip.me', 'Skip', false),
    ]),
    clashApiSecret: 't'
  });
  await store.saveSettings(s);
  assert.equal(JSON.parse(data.get('settings')).perAppList, 'com.keep.me',
    'unchecked entries must never reach the derived list');
  console.log('PASS real Store derives perAppList from checked entries only');

  // 任何写入路径都不能把**结构非法**的包名漏进名单。
  // 注意边界:com.tencent.mm 这种"结构合法但其实是 Android 包名"的输入无法靠格式
  // 识别(见下一条断言),只能靠界面提示 + 预置正确鸿蒙包名来避免。
  const badSave = Object.assign(new model.AppSettings(), {
    perAppMode: 'exclude',
    perAppEntries: pa.serializeEntries([
      new pa.PerAppEntry('com.tencent-wechat', 'hyphen', true),
      new pa.PerAppEntry('wechat', 'no dot', true),
    ]),
    clashApiSecret: 't'
  });
  await store.saveSettings(badSave);
  assert.equal(JSON.parse(data.get('settings')).perAppList, '',
    'structurally invalid bundle names must be filtered before persistence');
  console.log('PASS real Store filters structurally invalid bundle names on every save path');

  // 已知边界:结构合法但语义错误的包名(Android 版微信)会被原样保留 ——
  // 格式校验无法覆盖这一层,必须靠预置列表与包名提示,测试固化这个已知行为。
  await store.saveSettings(Object.assign(new model.AppSettings(), {
    perAppMode: 'exclude',
    perAppEntries: pa.serializeEntries([new pa.PerAppEntry('com.tencent.mm', 'Android WeChat', true)]),
    clashApiSecret: 't'
  }));
  assert.equal(JSON.parse(data.get('settings')).perAppList, 'com.tencent.mm',
    'structurally valid names are kept even when they are the Android variant');
  console.log('PASS documented boundary: a structurally valid but wrong-platform name is not detectable by format');

  // 非法模式回退 off(防止脏数据构造出无意义的 VpnConfig)
  for (const bogus of ['bogus', '', null, 7]) {
    const m = Object.assign(new model.AppSettings(), { perAppMode: bogus, clashApiSecret: 't' });
    await store.saveSettings(m);
    assert.equal(JSON.parse(data.get('settings')).perAppMode, 'off');
  }
  console.log('PASS real Store normalizes an unknown per-app mode to off');

  // 用户显式清空名单后,'[]' 不能再被"首次初始化"逻辑灌回预置项
  await store.saveSettings(Object.assign(new model.AppSettings(), {
    perAppMode: 'off', perAppEntries: '[]', clashApiSecret: 't'
  }));
  const cleared = await store.loadSettings();
  assert.equal(cleared.perAppEntries, '[]', 'an explicitly emptied list must stay empty');
  console.log('PASS real Store does not resurrect presets after the user clears the list');

  // ---------- 扩展侧:下发名单的合法性过滤(与 VpnExtAbility 同一条函数) ----------
  assert.equal(JSON.stringify(pa.effectivePackagesFromCsv('com.tencent.wechat, com.jd.hm.mall')),
    JSON.stringify(['com.tencent.wechat', 'com.jd.hm.mall']));
  assert.equal(JSON.stringify(pa.effectivePackagesFromCsv('com.tencent-wechat,wechat')), JSON.stringify([]),
    'malformed names must not be applied as bundle names');
  assert.equal(JSON.stringify(pa.effectivePackagesFromCsv('')), JSON.stringify([]));
  console.log('PASS extension-side list parsing filters malformed names and tolerates blanks');
})().catch(e => { console.error(e); process.exitCode = 1; });
