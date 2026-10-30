// SettingsSchema tests (P4/W16, plan §12.1/§12.2/§12.4).
// 转译 + VM 模式；含「防漂移」断言：读 Profile.ets 源码正则抽 AppSettings 字段，
// 断言 registry 全覆盖/无多余/默认值与类字段初值逐字一致（表达式走显式白名单）。
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

const schema = load('entry/src/main/ets/model/SettingsSchema.ets');

// ---------------------------------------------------------------- drift guard: source extraction
const profileSrc = fs.readFileSync(path.join(root, 'entry/src/main/ets/model/Profile.ets'), 'utf8');
const classStart = profileSrc.indexOf('export class AppSettings');
assert.ok(classStart >= 0, 'AppSettings class must exist in model/Profile.ets');
const bodyStart = profileSrc.indexOf('{', classStart) + 1;
const bodyEnd = profileSrc.indexOf('\n}', bodyStart);
assert.ok(bodyEnd > bodyStart, 'AppSettings class body must close at column 0');
const classBody = profileSrc.substring(bodyStart, bodyEnd);

// 每个字段：`  name: type = init;`（注释在分号后，正则不含）
const fieldRe = /^\s{2}([A-Za-z_]\w*):\s*(number|string|boolean)\s*=\s*([^;]+);/gm;
const srcFields = [];
let m;
while ((m = fieldRe.exec(classBody)) !== null) {
  srcFields.push({ name: m[1], type: m[2], init: m[3].trim() });
}

// 表达式初值白名单（防漂移测试对非字面量必须有显式期望值并注明来源）
const EXPR_WHITELIST = {
  '6*3600*1000': 21600000 // Profile.ets:216  latencyStaleMs: number = 6 * 3600 * 1000
};

function expectedDefault(field) {
  const init = field.init;
  if (field.type === 'boolean') {
    assert.ok(init === 'true' || init === 'false', `unexpected boolean init for ${field.name}: ${init}`);
    return init;
  }
  if (field.type === 'number') {
    if (/^-?\d+(\.\d+)?$/.test(init)) {
      return String(Number(init));
    }
    const compact = init.replace(/\s+/g, '');
    if (EXPR_WHITELIST[compact] !== undefined) {
      return String(EXPR_WHITELIST[compact]);
    }
    throw Error(`unmapped number expression for ${field.name}: "${init}" — add it to EXPR_WHITELIST with a comment`);
  }
  const q = init[0];
  assert.ok((q === "'" || q === '"') && init[init.length - 1] === q,
    `unexpected string init for ${field.name}: ${init}`);
  return JSON.stringify(init.slice(1, -1));
}

const defs = schema.settingDefs();
const defByKey = {};
for (const d of defs) {
  defByKey[d.key] = d;
}

// 1. drift guard (a): registry covers every AppSettings field
{
  assert.ok(srcFields.length > 40, `expected many AppSettings fields, got ${srcFields.length}`);
  for (const f of srcFields) {
    assert.ok(defByKey[f.name] !== undefined, `registry is missing AppSettings field: ${f.name}`);
  }
  assert.equal(defs.length, srcFields.length, 'registry must have exactly one def per AppSettings field');
  console.log(`PASS drift(a): registry covers all ${srcFields.length} AppSettings fields`);
}

// 2. drift guard (b): registry has no keys that AppSettings lacks
{
  const srcNames = new Set(srcFields.map((f) => f.name));
  for (const d of defs) {
    assert.ok(srcNames.has(d.key), `registry has a key that AppSettings lacks: ${d.key}`);
  }
  console.log('PASS drift(b): registry has no extra keys');
}

// 3. drift guard (c): defaultValue matches the source initializer verbatim (expressions white-listed)
{
  for (const f of srcFields) {
    const d = defByKey[f.name];
    const exp = expectedDefault(f);
    assert.equal(d.defaultValue, exp, `${f.name}.defaultValue ${d.defaultValue} != source ${exp}`);
  }
  console.log('PASS drift(c): every defaultValue matches Profile.ets initializer (expr whitelist honoured)');
}

// 4. drift guard: kind matches the declared field type (string may be 'string' or 'enum')
{
  for (const f of srcFields) {
    const d = defByKey[f.name];
    let ok = false;
    if (f.type === 'boolean') {
      ok = d.kind === 'bool';
    } else if (f.type === 'number') {
      ok = d.kind === 'number';
    } else {
      ok = d.kind === 'string' || d.kind === 'enum';
    }
    assert.ok(ok, `${f.name}: TS type ${f.type} vs registry kind ${d.kind}`);
  }
  console.log('PASS drift: kind matches declared field type');
}

// 5. registry invariants: unique keys/labels, valid sections/applyClass, non-empty tokens
{
  const sectionIds = new Set(schema.sectionDefs().map((s) => s.id));
  const applySet = new Set([schema.APPLY_IMMEDIATE, schema.APPLY_NEXT_TASK, schema.APPLY_RECONNECT]);
  const keys = new Set();
  const labels = new Set();
  for (const d of defs) {
    assert.ok(!keys.has(d.key), `duplicate key ${d.key}`);
    keys.add(d.key);
    assert.ok(!labels.has(d.labelToken), `duplicate labelToken ${d.labelToken}`);
    labels.add(d.labelToken);
    assert.ok(sectionIds.has(d.section), `${d.key} has unregistered section ${d.section}`);
    assert.ok(applySet.has(d.applyClass), `${d.key} has invalid applyClass ${d.applyClass}`);
    assert.ok(d.labelToken.length > 0 && d.keywords.length > 0, `${d.key} needs labelToken+keywords`);
    assert.ok(['bool', 'number', 'string', 'enum'].indexOf(d.kind) >= 0, `${d.key} invalid kind ${d.kind}`);
  }
  console.log('PASS registry invariants (unique keys/labels, valid section/applyClass/kind)');
}

// 6. applyClass distribution + spot checks (conservative reconnect rule)
{
  const count = (cls) => defs.filter((d) => d.applyClass === cls).length;
  assert.ok(count(schema.APPLY_RECONNECT) > count(schema.APPLY_NEXT_TASK), 'reconnect should dominate (conservative)');
  assert.equal(defByKey['mode'].applyClass, schema.APPLY_RECONNECT);
  assert.equal(defByKey['mtu'].applyClass, schema.APPLY_RECONNECT);
  assert.equal(defByKey['remoteDns'].applyClass, schema.APPLY_RECONNECT);
  assert.equal(defByKey['perAppEntries'].applyClass, schema.APPLY_RECONNECT);
  assert.equal(defByKey['clashApiPort'].applyClass, schema.APPLY_RECONNECT);
  assert.equal(defByKey['testUrl'].applyClass, schema.APPLY_NEXT_TASK);
  assert.equal(defByKey['testConcurrent'].applyClass, schema.APPLY_NEXT_TASK);
  assert.equal(defByKey['latencyStaleMs'].applyClass, schema.APPLY_NEXT_TASK);
  assert.equal(defByKey['autoUpdateSubs'].applyClass, schema.APPLY_NEXT_TASK);
  assert.equal(defByKey['appearance'].applyClass, schema.APPLY_IMMEDIATE);
  assert.equal(defByKey['hapticFeedback'].applyClass, schema.APPLY_IMMEDIATE);
  assert.equal(defByKey['navLayout'].applyClass, schema.APPLY_IMMEDIATE);
  console.log(`PASS applyClass: ${count(schema.APPLY_RECONNECT)} reconnect / ${count(schema.APPLY_NEXT_TASK)} nextTask / ${count(schema.APPLY_IMMEDIATE)} immediate`);
}

// 7. sectionDefs: ordered, unique ids, only 'advanced' is advancedOnly
{
  const sections = schema.sectionDefs();
  assert.ok(sections.length >= 5);
  const ids = sections.map((s) => s.id);
  assert.equal(new Set(ids).size, ids.length, 'section ids unique');
  const orders = sections.map((s) => s.order);
  const sorted = orders.slice().sort((a, b) => a - b);
  assert.equal(orders.join(','), sorted.join(','), 'sectionDefs must be ordered by order');
  const advOnly = sections.filter((s) => s.advancedOnly).map((s) => s.id);
  assert.equal(advOnly.join(','), 'advanced', 'only the advanced section is advancedOnly');
  console.log('PASS sectionDefs ordered/unique with advancedOnly flag');
}

// 8. settingDefOf hit + miss
{
  assert.equal(schema.settingDefOf('mtu').key, 'mtu');
  assert.equal(schema.settingDefOf('no_such_setting'), null);
  console.log('PASS settingDefOf hit/miss');
}

// ---------------------------------------------------------------- diff
const allDefaults = () => schema.defaultsForAll();
const clone = (o) => JSON.parse(JSON.stringify(o));

// 9. empty diff: identical draft/applied (defaults twice) -> total 0, summary ''
{
  const diff = schema.diffSettings(allDefaults(), allDefaults());
  assert.equal(diff.total, 0);
  assert.equal(diff.reconnectCount + diff.nextTaskCount + diff.immediateCount, 0);
  assert.equal(diff.items.length, 0);
  assert.equal(schema.summaryText(diff), '');
  assert.equal(schema.impactParts(diff).length, 0);
  console.log('PASS diff: identical records produce empty diff');
}

// 10. single diff item carries section/applyClass/labelToken + JSON values
{
  const draft = allDefaults();
  const applied = allDefaults();
  draft.mtu = 9000;
  const diff = schema.diffSettings(draft, applied);
  assert.equal(diff.total, 1);
  const it = diff.items[0];
  assert.equal(it.key, 'mtu');
  assert.equal(it.section, 'advanced');
  assert.equal(it.applyClass, schema.APPLY_RECONNECT);
  assert.equal(it.appliedValue, '1400', 'applied value is JSON text of the applied number');
  assert.equal(it.draftValue, '9000');
  assert.equal(it.labelToken, 'settings_mtu');
  assert.equal(diff.reconnectCount, 1);
  console.log('PASS diff: single item with section/applyClass/JSON values');
}

// 11. numeric equivalence: 1400 vs 1400.0 must not be reported
{
  const draft = allDefaults();
  const applied = allDefaults();
  applied.mtu = 1400.0;
  draft.mtu = 1400;
  assert.equal(schema.diffSettings(draft, applied).total, 0, '1400 vs 1400.0 is not a change');
  applied.clashApiPort = 19290.0;
  draft.clashApiPort = 19290;
  assert.equal(schema.diffSettings(draft, applied).total, 0);
  console.log('PASS diff: numbers compare by value (no false positives)');
}

// 12. bool semantics: boolean true vs string "true" equal defensively; true vs false differs
{
  const draft = allDefaults();
  const applied = allDefaults();
  applied.dnsRouting = 'false';
  draft.dnsRouting = false;
  assert.equal(schema.diffSettings(draft, applied).total, 0, 'bool compares by boolean value');
  applied.dnsRouting = true;
  assert.equal(schema.diffSettings(draft, applied).total, 1, 'true vs false differs');
  console.log('PASS diff: booleans compare by value');
}

// 13. strings compare verbatim (no trim, case-sensitive)
{
  const draft = allDefaults();
  const applied = allDefaults();
  draft.testUrl = 'http://cp.cloudflare.com/ ';
  assert.equal(schema.diffSettings(draft, applied).total, 1, 'trailing space is a real difference (no trim)');
  draft.testUrl = 'HTTP://CP.CLOUDFLARE.COM/';
  assert.equal(schema.diffSettings(draft, applied).total, 1, 'string compare is case-sensitive');
  console.log('PASS diff: strings verbatim (no trim / case-sensitive)');
}

// 14. enum compare is exact
{
  const draft = allDefaults();
  const applied = allDefaults();
  draft.logLevel = 'INFO';
  assert.equal(schema.diffSettings(draft, applied).total, 1, "'INFO' != 'info'");
  draft.logLevel = 'info';
  assert.equal(schema.diffSettings(draft, applied).total, 0);
  console.log('PASS diff: enums exact');
}

// 15. applied missing key (old snapshot) falls back to registry default -> no false "modified"
{
  const draft = allDefaults();
  const applied = allDefaults();
  delete applied.clashApiPort; // 旧快照没有新字段
  assert.equal(schema.diffSettings(draft, applied).total, 0, 'missing applied key falls back to default');
  // 但真实改动仍要报出来，且 appliedValue 显示默认值
  draft.mtu = 9000;
  delete applied.mtu;
  const diff = schema.diffSettings(draft, applied);
  assert.equal(diff.total, 1);
  assert.equal(diff.items[0].appliedValue, '1400', 'missing applied value displayed as registry default');
  console.log('PASS diff: missing applied keys fall back to registry defaults');
}

// 16. draft missing key -> not reported (draft is serialized AppSettings; missing means unknown)
{
  const draft = allDefaults();
  const applied = allDefaults();
  delete draft.mtu;
  applied.mtu = 9000;
  assert.equal(schema.diffSettings(draft, applied).total, 0, 'draft-missing keys are not reported');
  console.log('PASS diff: draft-missing keys are ignored');
}

// 17. unknown keys in either record are ignored
{
  const draft = allDefaults();
  const applied = allDefaults();
  draft.notASetting = 1;
  applied.newFieldFromFuture = 'x';
  assert.equal(schema.diffSettings(draft, applied).total, 0);
  draft.mode = 'global';
  const diff = schema.diffSettings(draft, applied);
  assert.equal(diff.total, 1, 'registry-covered change still reported');
  assert.equal(diff.items[0].key, 'mode');
  console.log('PASS diff: keys outside the registry are ignored');
}

// 18. counts per applyClass + item order follows registry declaration order
{
  const draft = allDefaults();
  const applied = allDefaults();
  draft.mode = 'global';          // reconnect
  draft.mtu = 9000;               // reconnect
  draft.testConcurrent = 8;       // nextTask
  draft.appearance = 'dark';      // immediate
  const diff = schema.diffSettings(draft, applied);
  assert.equal(diff.total, 4);
  assert.equal(diff.reconnectCount, 2);
  assert.equal(diff.nextTaskCount, 1);
  assert.equal(diff.immediateCount, 1);
  assert.equal(diff.items.map((i) => i.key).join(','), 'mode,testConcurrent,appearance,mtu',
    'items follow registry declaration order (realm-safe compare)');
  console.log('PASS diff: per-class counts and stable registry ordering');
}

// 19. summaryText returns the pending_changes token whenever total > 0 (P6/W21 i18n:页面用 $r 渲染计数)
{
  const draft = allDefaults();
  const applied = allDefaults();
  draft.mtu = 9000;
  assert.equal(schema.summaryText(schema.diffSettings(draft, applied)), 'pending_changes');
  assert.equal(schema.diffSettings(draft, applied).total, 1);
  draft.testConcurrent = 8;
  assert.equal(schema.summaryText(schema.diffSettings(draft, applied)), 'pending_changes');
  assert.equal(schema.diffSettings(draft, applied).total, 2);
  console.log('PASS summaryText: pending_changes token reflects non-zero total');
}

// 20. impactParts lists only non-zero classes in fixed order (P6/W21:结构化 kind+count,页面映射 $r)
{
  const draft = allDefaults();
  const applied = allDefaults();
  draft.mtu = 9000;            // reconnect
  draft.testConcurrent = 8;    // nextTask
  draft.appearance = 'dark';   // immediate
  const parts = schema.impactParts(schema.diffSettings(draft, applied));
  assert.equal(parts.map((p) => `${p.kind}=${p.count}`).join('|'),
    `${schema.APPLY_RECONNECT}=1|${schema.APPLY_NEXT_TASK}=1|${schema.APPLY_IMMEDIATE}=1`);
  const onlyReconnect = allDefaults();
  onlyReconnect.mtu = 9000;
  assert.equal(schema.impactParts(schema.diffSettings(onlyReconnect, allDefaults())).map((p) => p.kind).join('|'), schema.APPLY_RECONNECT);
  const onlyNext = allDefaults();
  onlyNext.testConcurrent = 8;
  assert.equal(schema.impactParts(schema.diffSettings(onlyNext, allDefaults())).map((p) => p.kind).join('|'), schema.APPLY_NEXT_TASK);
  const onlyImmediate = allDefaults();
  onlyImmediate.appearance = 'dark';
  assert.equal(schema.impactParts(schema.diffSettings(onlyImmediate, allDefaults())).map((p) => p.kind).join('|'), schema.APPLY_IMMEDIATE);
  console.log('PASS impactParts: only non-zero classes, fixed order');
}

// 21. searchSettings: key hit, Chinese keyword hit, case-insensitive, miss, empty=all
{
  assert.equal(schema.searchSettings('mtu').some((d) => d.key === 'mtu'), true);
  assert.equal(schema.searchSettings('嗅探').some((d) => d.key === 'sniffMode'), true, 'Chinese keyword');
  assert.equal(schema.searchSettings('DNS').some((d) => d.key === 'dnsRouting'), true, 'case-insensitive');
  assert.ok(schema.searchSettings('dns').length >= 7, 'dns family matches several settings');
  assert.equal(schema.searchSettings('cloudflare').some((d) => d.key === 'testUrl'), true, 'english keyword');
  assert.equal(schema.searchSettings('zzz_not_found').length, 0, 'no result');
  assert.equal(schema.searchSettings('').length, defs.length, 'empty query returns all (browse)');
  console.log('PASS searchSettings: key/keyword/Chinese/case-insensitive/miss');
}

// 22. sectionDefaults: only that section, types restored
{
  const dns = schema.sectionDefaults('dns');
  const keys = Object.keys(dns).sort();
  assert.deepEqual(keys, ['directDns', 'directDnsStrategy', 'dnsRouting', 'fakeDns', 'remoteDns',
    'remoteDnsStrategy', 'serverDnsStrategy']);
  assert.equal(typeof dns.remoteDns, 'string');
  assert.equal(dns.remoteDns, 'tcp://8.8.8.8');
  assert.equal(dns.directDns, '223.5.5.5');
  assert.equal(typeof dns.dnsRouting, 'boolean');
  assert.equal(dns.dnsRouting, true);
  assert.equal(dns.fakeDns, false);
  assert.equal(Object.keys(schema.sectionDefaults('nope')).length, 0, 'unknown section -> empty record');
  console.log('PASS sectionDefaults: section-scoped with restored types');
}

// 23. defaultsForAll: full record with restored types
{
  const all = schema.defaultsForAll();
  assert.equal(Object.keys(all).length, defs.length);
  assert.equal(typeof all.mtu, 'number');
  assert.equal(all.mtu, 1400);
  assert.equal(all.stack, 'gvisor');
  assert.equal(all.latencyStaleMs, 21600000, '6*3600*1000 evaluated');
  assert.equal(all.perAppMode, 'off');
  assert.equal(all.testExpectStatus, 'any');
  assert.equal(all.clashApiPort, 19290);
  console.log('PASS defaultsForAll: full typed default snapshot');
}

// 24. isDefaultValue boundaries
{
  const mtu = schema.settingDefOf('mtu');
  assert.equal(schema.isDefaultValue(mtu, 1400), true);
  assert.equal(schema.isDefaultValue(mtu, 9000), false);
  assert.equal(schema.isDefaultValue(mtu, undefined), true, 'missing value counts as default');
  const mode = schema.settingDefOf('mode');
  assert.equal(schema.isDefaultValue(mode, 'rule'), true);
  assert.equal(schema.isDefaultValue(mode, 'global'), false);
  const appearance = schema.settingDefOf('appearance');
  assert.equal(schema.isDefaultValue(appearance, 'system'), true);
  const dnsRouting = schema.settingDefOf('dnsRouting');
  assert.equal(schema.isDefaultValue(dnsRouting, true), true);
  assert.equal(schema.isDefaultValue(dnsRouting, false), false);
  console.log('PASS isDefaultValue: type-aware boundaries');
}

// 25. registry defaults are stable across calls (defensive copies, no shared-array mutation leaks)
{
  const a = schema.settingDefs();
  const b = schema.settingDefs();
  a.push({ key: 'injected' });
  assert.equal(schema.settingDefs().length, b.length, 'settingDefs must return an independent array');
  const sections = schema.sectionDefs();
  sections.push({ id: 'injected' });
  assert.ok(schema.sectionDefs().every((s) => s.id !== 'injected'));
  console.log('PASS settingDefs/sectionDefs return independent arrays');
}

console.log('\nALL settings-schema checks passed');
