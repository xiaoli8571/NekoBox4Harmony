// i18n key drift guard (P4/W16 收口, plan §12.1/§24.2-6).
// 纯 Node：VM 转译 SettingsSchema.ets 取 registry token，校验两份 string.json 与页面静态映射。
// 目的：以后给 AppSettings 加字段（registry 加 SettingDef）却忘了补资源键时，这里必红。
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
const defs = schema.settingDefs();
const sections = schema.sectionDefs();
const labelTokens = defs.map((d) => d.labelToken);
const sectionTokens = sections.map((s) => s.labelToken);

const BASE_PATH = 'entry/src/main/resources/base/element/string.json';
const EN_PATH = 'entry/src/main/resources/en_US/element/string.json';
const baseText = fs.readFileSync(path.join(root, BASE_PATH), 'utf8');
const enText = fs.readFileSync(path.join(root, EN_PATH), 'utf8');
const base = JSON.parse(baseText);
const en = JSON.parse(enText);
const baseMap = new Map(base.string.map((s) => [s.name, s.value]));
const enMap = new Map(en.string.map((s) => [s.name, s.value]));

// 1. registry 完整性：每个 SettingDef/SectionDef 都有 labelToken
{
  for (const d of defs) {
    assert.ok(typeof d.labelToken === 'string' && d.labelToken.length > 0, `setting ${d.key} needs a labelToken`);
  }
  for (const s of sections) {
    assert.ok(typeof s.labelToken === 'string' && s.labelToken.length > 0, `section ${s.id} needs a labelToken`);
  }
  console.log(`PASS registry tokens present: ${labelTokens.length} settings + ${sectionTokens.length} sections`);
}

// 2. 每个 token 在两份 json 都存在且值非空（含分区 token）
{
  const all = labelTokens.concat(sectionTokens);
  for (const token of all) {
    assert.ok(baseMap.has(token), `base string.json missing key: ${token}`);
    assert.ok(enMap.has(token), `en_US string.json missing key: ${token}`);
    const zh = baseMap.get(token);
    const enValue = enMap.get(token);
    assert.ok(typeof zh === 'string' && zh.trim().length > 0, `empty zh value for ${token}`);
    assert.ok(typeof enValue === 'string' && enValue.trim().length > 0, `empty en value for ${token}`);
    assert.notEqual(zh, token, `zh value for ${token} must be user-facing text, not the token`);
  }
  console.log(`PASS all ${all.length} registry tokens exist in both string.json with non-empty values`);
}

// 3. 两份文件键集合完全一致（英文缺失会导致运行时回退/空串）
{
  const b = [...baseMap.keys()].sort();
  const e = [...enMap.keys()].sort();
  assert.equal(b.length, e.length, 'base and en_US must have the same number of keys');
  assert.equal(JSON.stringify(b), JSON.stringify(e), 'base and en_US key sets must be identical');
  console.log(`PASS key sets identical: ${b.length} keys in base and en_US`);
}

// 4. 无重复键：JSON.parse 会吞掉重复键，按原文正则计数
{
  const nameRe = /"name"\s*:\s*"([^"]+)"/g;
  for (const [file, text, parsed] of [[BASE_PATH, baseText, base], [EN_PATH, enText, en]]) {
    const counts = new Map();
    let m;
    while ((m = nameRe.exec(text)) !== null) {
      counts.set(m[1], (counts.get(m[1]) || 0) + 1);
    }
    assert.equal(counts.size, parsed.string.length, `${file}: raw name count != parsed entry count`);
    for (const [name, n] of counts) {
      assert.equal(n, 1, `${file}: duplicate key ${name} appears ${n} times`);
    }
  }
  console.log('PASS no duplicate keys in either string.json (raw regex count)');
}

// 5. 值健康：无占位符残留、无空串
{
  for (const [file, map] of [[BASE_PATH, baseMap], [EN_PATH, enMap]]) {
    for (const [name, value] of map) {
      assert.equal(typeof value, 'string', `${file}: ${name} value must be a string`);
      assert.ok(value.trim().length > 0, `${file}: ${name} has an empty value`);
      assert.equal(value.indexOf('[object Object]') < 0, true, `${file}: ${name} contains [object Object]`);
      assert.equal(value.indexOf('undefined') < 0, true, `${file}: ${name} contains undefined`);
    }
  }
  console.log('PASS value hygiene: no empty/placeholder values');
}

// 5b. 带参资源的中英占位符一致(P6/W21 复审新增):%n$s/%n$d 序列必须逐位对应,
//     否则某一语言下 resFormat/$r 展开时参数错位或原样漏出 %1$s
{
  const phRe = /%(\d+)\$[sd]/g;
  const seqOf = (text) => {
    const out = [];
    let m;
    while ((m = phRe.exec(text)) !== null) {
      out.push(m[0]);
    }
    return out.sort().join('|');
  };
  let checked = 0;
  for (const [name, zh] of baseMap) {
    const en = enMap.get(name);
    assert.ok(typeof en === 'string', `en_US missing ${name}`);
    const zhSeq = seqOf(zh);
    if (zhSeq.length === 0) {
      assert.equal(seqOf(en).length, 0, `${name}: zh has no placeholders but en_US does (${en})`);
      continue;
    }
    checked++;
    assert.equal(zhSeq, seqOf(en), `${name}: placeholder mismatch zh="${zh}" en="${en}"`);
  }
  console.log(`PASS placeholder parity: ${checked} parameterized keys match zh/en`);
}

// 6. pages/SettingsPage.ets 的 SETTING_LABELS 静态映射与 registry 对齐
{
  const pageSrc = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/SettingsPage.ets'), 'utf8');
  const mapRe = /\['(settings_[a-z0-9_]+)',\s*\$r\('app\.string\.([a-z0-9_]+)'\)\]/g;
  const mapped = new Map();
  let m;
  while ((m = mapRe.exec(pageSrc)) !== null) {
    mapped.set(m[1], m[2]);
  }
  assert.ok(mapped.size > 0, 'SETTING_LABELS map should exist and be parseable');
  for (const [token, resource] of mapped) {
    assert.equal(token, resource, `SETTING_LABELS entry ${token} must reference app.string.${token}`);
    assert.ok(baseMap.has(resource), `SETTING_LABELS references missing base key: ${resource}`);
    assert.ok(enMap.has(resource), `SETTING_LABELS references missing en_US key: ${resource}`);
  }
  // registry 全量映射(P6/W21 收口后 54/54;再出现 pending = 加了字段没补 SETTING_LABELS,必红)
  const missingInMap = defs.map((d) => d.labelToken).filter((t) => !mapped.has(t));
  assert.equal(missingInMap.length, 0,
    `SETTING_LABELS must map every registry token (missing: ${missingInMap.join(', ')})`);
  // 分区 token 同样要有页面映射(SECTION_LABELS),资源键在上方第 2 组已校验
  const secRe = /\['(settings_section_[a-z0-9_]+)',\s*\$r\('app\.string\.([a-z0-9_]+)'\)\]/g;
  const secMapped = new Set();
  let sm;
  while ((sm = secRe.exec(pageSrc)) !== null) {
    secMapped.add(sm[1]);
  }
  const secMissing = sections.map((s) => s.labelToken).filter((t) => !secMapped.has(t));
  assert.equal(secMissing.length, 0,
    `SECTION_LABELS must map every section token (missing: ${secMissing.join(', ')})`);
  console.log(`PASS SETTING_LABELS complete: ${defs.filter((d) => mapped.has(d.labelToken)).length}/${defs.length} settings + ${secMapped.size}/${sections.length} sections mapped`);
}

console.log('\nALL i18n-keys checks passed');
