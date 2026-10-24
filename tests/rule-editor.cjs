// RuleEditor tests (P4/W14, plan §7.2/§7.3/§7.4/§8.5).
// 转译 + VM 模式；vm 对象来自另一 realm，deepStrictEqual 需先 plain()。
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

const probe = load('entry/src/main/ets/model/ProbeResult.ets', {});
const rr = load('entry/src/main/ets/model/RoutingRules.ets', { './ProbeResult': probe });
const profileMod = load('entry/src/main/ets/model/Profile.ets', {});
const re = load('entry/src/main/ets/model/RuleEditor.ets', {
  './Profile': profileMod,
  './RoutingRules': rr
});

const plain = (v) => JSON.parse(JSON.stringify(v));
const codesOf = (list) => plain(list).map((e) => `${e.severity}:${e.field}:${e.code}`);
const codesOnly = (list) => plain(list).map((e) => e.code);
const mkProfile = (id, name) => Object.assign(new profileMod.Profile(), { id, name, server: '1.2.3.4' });
const mkGroup = (id, name) => Object.assign(new profileMod.ProfileGroup(), { id, name });

// ---------------------------------------------------------------- form ↔ rule

// 1. emptyForm defaults
{
  const f = re.emptyForm();
  assert.equal(f.type, 'domain_suffix');
  assert.equal(f.outbound, 'proxy');
  assert.equal(f.enabled, true);
  assert.equal(f.matchMode, 'or');
  assert.equal(f.advancedOpen, false);
  assert.equal(f.payload, '');
  assert.equal(f.destPort, '');
  assert.equal(f.sourceIpCidr, '');
  assert.equal(f.customJson, '');
  console.log('PASS emptyForm defaults');
}

// 2. formFromRule: simple typed row -> or mode, advanced fields empty
{
  const rules = rr.parseRules([{ id: 'r1', type: 'domain_suffix', payload: 'Example.COM', outbound: 'proxy', enabled: true }]);
  const f = re.formFromRule(rules[0]);
  assert.equal(f.type, 'domain_suffix');
  assert.equal(f.payload, 'example.com', 'payload normalized (lowercase)');
  assert.equal(f.outbound, 'proxy');
  assert.equal(f.enabled, true);
  assert.equal(f.matchMode, 'or');
  assert.equal(f.advancedOpen, false);
  assert.equal(f.destPort, '');
  assert.equal(f.customJson, '');
  console.log('PASS formFromRule: simple row');
}

// 3. formFromRule: legacy AND row fills advanced fields, matchMode and
{
  const rules = rr.parseRules([{
    id: 'r2', outbound: 'proxy', enabled: true,
    domains: 'a.com,full:b.org', ip: '10.0.0.0/8', port: '443', source: '192.168.1.0/24',
    sourcePort: '1000:2000', network: 'tcp', protocol: 'tls', config: '{"x":1}'
  }]);
  const f = re.formFromRule(rules[0]);
  assert.equal(f.matchMode, 'and', 'legacy multi-field row is AND by construction');
  assert.equal(f.advancedOpen, true, 'advanced section opens so conditions are visible');
  assert.equal(f.destPort, '443');
  assert.equal(f.sourceIpCidr, '192.168.1.0/24');
  assert.equal(f.sourcePort, '1000:2000');
  assert.equal(f.network, 'tcp');
  assert.equal(f.protocol, 'tls');
  assert.equal(f.customJson, '{"x":1}');
  // 主条件: 域名后缀 a.com（derivePrimary 先后缀），ip 是 legacyRow 的其余条件
  assert.equal(f.type, 'domain_suffix');
  assert.ok(f.payload.indexOf('a.com') >= 0);
  console.log('PASS formFromRule: legacy AND row conditions fill advanced fields');
}

// 4. formToRule round-trip: legacy AND conditions survive -> toRawRows -> parseRules
{
  const rules = rr.parseRules([{
    id: 'keep1', outbound: 'proxy', enabled: true,
    domains: 'a.com', port: '443', network: 'tcp'
  }]);
  const f = re.formFromRule(rules[0]);
  assert.equal(f.destPort, '443');
  assert.equal(f.network, 'tcp');
  const edited = re.formToRule(f, rules[0]);
  const rows = rr.toRawRows([edited]);
  const again = rr.parseRules(rows);
  assert.equal(again[0].id, 'keep1');
  assert.equal(re.conditionCount(again[0]), 3, 'domain + port + network survive the round trip');
  const g = re.formFromRule(again[0]);
  assert.equal(g.matchMode, 'and');
  assert.equal(g.destPort, '443');
  assert.equal(g.network, 'tcp');
  console.log('PASS formToRule round-trip keeps legacy AND conditions');
}

// 5. formToRule new rule (base null): id generated, order 0, source user
{
  const f = re.emptyForm();
  f.payload = 'Example.COM';
  const rule = re.formToRule(f, null);
  assert.ok(rule.id.length > 0, 'new rule id generated');
  assert.ok(rule.id.startsWith('rule_'), 'id follows newRuleId format');
  assert.equal(rule.order, 0);
  assert.equal(rule.source, 'user');
  assert.equal(rule.payload, 'example.com');
  assert.equal(rule.legacyRow ? Object.keys(rule.legacyRow).length : 0, 0, 'no advanced conditions -> empty legacyRow');
  console.log('PASS formToRule: new rule gets generated id/order/source');
}

// 6. formToRule keeps identity + unsupported flags from base; enabled follows form
{
  const rules = rr.parseRules([{ id: 'r9', type: 'domain_suffix', payload: 'a.com', outbound: 'proxy', enabled: true, unsupportedOnPlatform: true, unsupportedReason: 'legacy' }]);
  const f = re.formFromRule(rules[0]);
  f.enabled = false;
  f.payload = 'b.com';
  const rule = re.formToRule(f, rules[0]);
  assert.equal(rule.id, 'r9', 'id unchanged');
  assert.equal(rule.order, rules[0].order, 'order unchanged');
  assert.equal(rule.source, rules[0].source, 'source unchanged');
  assert.equal(rule.unsupportedOnPlatform, true, 'unsupported flag untouched by formToRule');
  assert.equal(rule.unsupportedReason, 'legacy');
  assert.equal(rule.enabled, false, 'enabled follows form');
  assert.equal(rule.payload, 'b.com');
  console.log('PASS formToRule preserves id/order/source/unsupported');
}

// ---------------------------------------------------------------- validation

const targets = re.availableTargets([mkProfile('p1', '香港 01')], [mkGroup('g1', '流媒体')], []);

// 7. valid form -> no errors
{
  const f = re.emptyForm();
  f.payload = 'example.com';
  f.destPort = '443,1000:2000';
  f.sourceIpCidr = '192.168.1.0/24,fd00::/8';
  f.customJson = '{"mux":1}';
  f.outbound = 'proxy';
  f.matchMode = 'and';
  assert.equal(re.validateForm(f, [], targets).length, 0, 'multi-condition and-form is fully valid');
  console.log('PASS validateForm: valid form has no errors');
}

// 8. empty payload (incl. only separators) -> empty_payload on payload field
{
  const f = re.emptyForm();
  let errs = re.validateForm(f, [], targets);
  assert.equal(codesOnly(errs).indexOf('empty_payload') >= 0, true);
  assert.equal(errs[0].field, 'payload');
  f.payload = ' ,, \n ';
  errs = re.validateForm(f, [], targets);
  assert.equal(codesOnly(errs).indexOf('empty_payload') >= 0, true, 'separators-only payload counts as empty');
  console.log('PASS validateForm: empty_payload');
}

// 9. domain validation (exact): labels, hyphen edges, wildcard
{
  const mk = (payload) => { const f = re.emptyForm(); f.type = 'domain'; f.payload = payload; return re.validateForm(f, [], targets); };
  assert.equal(codesOnly(mk('example.com')).indexOf('invalid_domain') >= 0, false, 'plain fqdn ok');
  assert.equal(codesOnly(mk('bad!.com')).indexOf('invalid_domain') >= 0, true);
  assert.equal(codesOnly(mk('-bad.com')).indexOf('invalid_domain') >= 0, true, 'label cannot start with hyphen');
  assert.equal(codesOnly(mk('a..b')).indexOf('invalid_domain') >= 0, true, 'empty label');
  assert.equal(codesOnly(mk('*.example.com')).indexOf('invalid_domain') >= 0, true, 'wildcard not allowed');
  console.log('PASS validateForm: domain exact validation');
}

// 10. domain_suffix validation: leading dot accepted
{
  const mk = (payload) => { const f = re.emptyForm(); f.type = 'domain_suffix'; f.payload = payload; return re.validateForm(f, [], targets); };
  assert.equal(codesOnly(mk('example.com')).indexOf('invalid_domain') >= 0, false);
  assert.equal(codesOnly(mk('.example.com')).indexOf('invalid_domain') >= 0, false, 'leading dot allowed for suffix');
  assert.equal(codesOnly(mk('bad!.com')).indexOf('invalid_domain') >= 0, true);
  console.log('PASS validateForm: domain_suffix accepts leading dot');
}

// 11. CIDR validation v4+v6, bare addresses
{
  const mk = (payload) => { const f = re.emptyForm(); f.type = 'ip_cidr'; f.payload = payload; return re.validateForm(f, [], targets); };
  assert.equal(codesOnly(mk('10.0.0.0/8')).indexOf('invalid_cidr') >= 0, false);
  assert.equal(codesOnly(mk('fd00::/8')).indexOf('invalid_cidr') >= 0, false, 'IPv6 cidr ok');
  assert.equal(codesOnly(mk('10.0.0.1')).indexOf('invalid_cidr') >= 0, false, 'bare v4 = /32');
  assert.equal(codesOnly(mk('2001:db8::1')).indexOf('invalid_cidr') >= 0, false, 'bare v6');
  assert.equal(codesOnly(mk('10.0.0.256/8')).indexOf('invalid_cidr') >= 0, true, 'octet > 255');
  assert.equal(codesOnly(mk('fd00::/129')).indexOf('invalid_cidr') >= 0, true, 'prefix > 128');
  assert.equal(codesOnly(mk('nope')).indexOf('invalid_cidr') >= 0, true);
  console.log('PASS validateForm: CIDR v4+v6');
}

// 12. port validation incl. open intervals; destPort/sourcePort independent fields
{
  const mk = (payload) => { const f = re.emptyForm(); f.type = 'port'; f.payload = payload; return re.validateForm(f, [], targets); };
  for (const ok of ['443', '80,443', '1000:2000', ':1000', '1000:']) {
    assert.equal(codesOnly(mk(ok)).indexOf('invalid_port') >= 0, false, ok);
  }
  for (const bad of ['0', '65536', '2000:1000', 'abc']) {
    assert.equal(codesOnly(mk(bad)).indexOf('invalid_port') >= 0, true, bad);
  }
  const f = re.emptyForm();
  f.destPort = '99999';
  f.sourcePort = 'abc';
  const errs = codesOf(re.validateForm(f, [], targets));
  assert.ok(errs.indexOf('error:destPort:invalid_port') >= 0, 'destPort field located');
  assert.ok(errs.indexOf('error:sourcePort:invalid_port') >= 0, 'sourcePort field located');
  console.log('PASS validateForm: port + open intervals, per-field location');
}

// 13. regex: compile check keeps original message; case preserved in payload
{
  const f = re.emptyForm();
  f.type = 'domain_regex';
  f.payload = '(bad';
  const errs = plain(re.validateForm(f, [], targets));
  const rx = errs.filter((e) => e.code === 'invalid_regex');
  assert.equal(rx.length, 1);
  assert.ok(rx[0].detail.indexOf('(bad') >= 0, 'pattern kept in detail');
  assert.ok(rx[0].detail.length > 20, 'parser message preserved');
  const f2 = re.emptyForm();
  f2.type = 'domain_regex';
  f2.payload = '^Example\\.COM$';
  assert.equal(re.validateForm(f2, [], targets).length, 0, 'valid regex ok');
  const rule = re.formToRule(f2, null);
  assert.equal(rule.payload, '^Example\\.COM$', 'regex case preserved verbatim');
  console.log('PASS validateForm: regex compile + raw preservation');
}

// 14. customJson must be an object
{
  const f = re.emptyForm();
  f.payload = 'a.com';
  f.customJson = '{"mux":1}';
  assert.equal(re.validateForm(f, [], targets).length, 0);
  f.customJson = '[1,2]';
  let errs = plain(re.validateForm(f, [], targets));
  assert.equal(errs.filter((e) => e.code === 'invalid_json')[0].detail.indexOf('对象') >= 0, true, 'must be object');
  f.customJson = '{bad';
  errs = plain(re.validateForm(f, [], targets));
  assert.equal(errs.filter((e) => e.code === 'invalid_json').length, 1, 'syntax error reported with parser message');
  console.log('PASS validateForm: customJson must be an object');
}

// 15. rule_set references must exist in knownRuleSetIds
{
  const f = re.emptyForm();
  f.type = 'rule_set';
  f.payload = 'my-set,geosite-cn';
  let errs = codesOnly(re.validateForm(f, ['my-set', 'geosite-cn'], targets));
  assert.equal(errs.indexOf('geosite_missing') >= 0, false, 'known refs ok');
  errs = codesOnly(re.validateForm(f, ['my-set'], targets));
  assert.equal(errs.indexOf('geosite_missing') >= 0, true, 'unknown ref flagged');
  console.log('PASS validateForm: rule_set reference existence');
}

// 16. outbound references: profile:/group: existence, reject alias, invalid empty
{
  const mk = (outbound) => { const f = re.emptyForm(); f.payload = 'a.com'; f.outbound = outbound; return re.validateForm(f, [], targets); };
  assert.equal(codesOnly(mk('proxy')).indexOf('target_missing') >= 0, false);
  assert.equal(codesOnly(mk('direct')).indexOf('target_missing') >= 0, false);
  assert.equal(codesOnly(mk('reject')).indexOf('target_missing') >= 0, false, 'reject alias accepted');
  assert.equal(codesOnly(mk('profile:p1')).indexOf('target_missing') >= 0, false, 'existing profile');
  assert.equal(codesOnly(mk('profile:p1')).indexOf('invalid_outbound') >= 0, false);
  assert.equal(codesOnly(mk('profile:gone')).indexOf('target_missing') >= 0, true, 'deleted profile');
  assert.equal(codesOnly(mk('group:gone')).indexOf('target_missing') >= 0, true, 'deleted group');
  assert.equal(codesOnly(mk('')).indexOf('invalid_outbound') >= 0, true);
  console.log('PASS validateForm: outbound reference existence');
}

// 17. and-mode warning: needs >= 2 conditions; or never warns
{
  const f = re.emptyForm();
  f.payload = 'a.com';
  f.matchMode = 'and';
  let errs = codesOf(re.validateForm(f, [], targets));
  assert.ok(errs.indexOf('warning:matchMode:and_needs_two_conditions') >= 0, 'and with 1 condition warns');
  f.destPort = '443';
  errs = codesOf(re.validateForm(f, [], targets));
  assert.ok(errs.indexOf('warning:matchMode:and_needs_two_conditions') < 0, 'and with 2 conditions ok');
  const f2 = re.emptyForm();
  f2.payload = 'a.com';
  f2.matchMode = 'or';
  assert.equal(re.validateForm(f2, [], targets).length, 0, 'or never warns');
  console.log('PASS validateForm: and-mode needs two conditions (warning)');
}

// ---------------------------------------------------------------- targets

// 18. availableTargets: fixed entries + profiles + groups; running group unavailable
{
  const t = re.availableTargets([mkProfile('p1', '香港 01')], [mkGroup('g1', '流媒体')], ['g1']);
  const kinds = t.map((x) => x.kind).join(',');
  assert.equal(kinds, 'direct,proxy,reject,profile,group');
  const direct = t[0];
  assert.equal(direct.id, 'direct');
  assert.equal(direct.available, true);
  const reject = t[2];
  assert.equal(reject.id, 'block', 'reject target carries the canonical outbound value');
  assert.equal(reject.label, '拒绝');
  const p = t[3];
  assert.equal(p.id, 'p1');
  assert.equal(p.label, '香港 01');
  const g = t[4];
  assert.equal(g.id, 'g1');
  assert.equal(g.available, false, 'running group cannot be targeted (self-reference loop)');
  const t2 = re.availableTargets([mkProfile('p1', '香港 01')], [mkGroup('g1', '流媒体')], []);
  assert.equal(t2[4].available, true, 'idle group is selectable');
  console.log('PASS availableTargets: fixed + profile + group with running exclusion');
}

// 19. resolveTargetIssue + suggestReplacement: never auto-replace
{
  const rules = rr.parseRules([
    { id: 'a', type: 'domain_suffix', payload: 'a.com', outbound: 'proxy' },
    { id: 'b', type: 'domain_suffix', payload: 'b.com', outbound: 'profile:gone' },
    { id: 'c', type: 'domain_suffix', payload: 'c.com', outbound: 'group:gone' },
    { id: 'd', type: 'domain_suffix', payload: 'd.com', outbound: 'profile:p1' }
  ]);
  assert.equal(re.resolveTargetIssue(rules[0], targets), '', 'plain proxy ok');
  assert.equal(re.resolveTargetIssue(rules[3], targets), '', 'existing profile ok');
  assert.equal(re.resolveTargetIssue(rules[1], targets), 'target_missing', 'deleted profile');
  assert.equal(re.resolveTargetIssue(rules[2], targets), 'target_missing', 'deleted group');
  const rep = re.suggestReplacement(targets, 'profile');
  assert.equal(rep.id, 'p1', 'first available profile suggested (UI hint only)');
  assert.equal(re.suggestReplacement(targets, 'nope'), null);
  // 规则本体不得被自动改写
  assert.equal(rules[1].outbound, 'profile:gone');
  console.log('PASS resolveTargetIssue/suggestReplacement: missing never auto-replaced');
}

// ---------------------------------------------------------------- summary & counting

// 20. ruleSummary: single conditions
{
  const ds = rr.parseRules([{ id: 'a', type: 'domain_suffix', payload: 'example.com', outbound: 'proxy' }])[0];
  assert.equal(re.ruleSummary(ds), '域名后缀 example.com');
  const cidr = rr.parseRules([{ id: 'b', type: 'ip_cidr', payload: '10.0.0.0/8', outbound: 'direct' }])[0];
  assert.equal(re.ruleSummary(cidr), 'IP 段 10.0.0.0/8');
  const multi = rr.parseRules([{ id: 'c', type: 'domain_suffix', payload: 'a.com,b.com,c.com', outbound: 'proxy' }])[0];
  assert.equal(re.ruleSummary(multi), '域名后缀 a.com 等 3 项', 'multi-value shows first + count');
  console.log('PASS ruleSummary: single-condition wording');
}

// 21. ruleSummary + conditionCount: multi-condition AND rows
{
  const and3 = rr.parseRules([{ id: 'a', outbound: 'proxy', domains: 'a.com', port: '443', network: 'tcp' }])[0];
  assert.equal(re.conditionCount(and3), 3, 'domain + port + network');
  assert.equal(re.ruleSummary(and3), '域名 + 端口等 3 个条件（同时满足）');
  const and2 = rr.parseRules([{ id: 'b', outbound: 'proxy', ip: '10.0.0.0/8', protocol: 'tls' }])[0];
  assert.equal(re.conditionCount(and2), 2);
  assert.equal(re.ruleSummary(and2), 'IP + 协议等 2 个条件（同时满足）');
  console.log('PASS ruleSummary: multi-condition wording matches spec example');
}

// 22. conditionCount: no double counting; packages enabled gate
{
  const purePort = rr.parseRules([{ id: 'a', type: 'port', payload: '443,8443', outbound: 'proxy' }])[0];
  assert.equal(re.conditionCount(purePort), 1, 'port values are one condition (OR)');
  const pkg = rr.parseRules([{ id: 'b', outbound: 'proxy', packages: 'com.a,com.b', packagesEnabled: true }])[0];
  assert.equal(re.conditionCount(pkg), 1, 'package payload counted once (no legacy double count)');
  assert.equal(pkg.type, 'package');
  const geoAndDomain = rr.parseRules([{ id: 'c', outbound: 'proxy', domains: 'a.com', ip: 'geoip:cn' }])[0];
  assert.equal(re.conditionCount(geoAndDomain), 2, 'domain + geoip are two groups');
  console.log('PASS conditionCount: no double counting');
}

// 23. matchDescription: different fields AND / same field OR
{
  const or = rr.parseRules([{ id: 'a', type: 'domain_suffix', payload: 'a.com,b.com', outbound: 'proxy' }])[0];
  assert.equal(re.matchDescription(or), 'or', 'same field multi-value is OR');
  const and = rr.parseRules([{ id: 'b', outbound: 'proxy', domains: 'a.com', port: '443' }])[0];
  assert.equal(re.matchDescription(and), 'and', 'different fields are AND');
  console.log('PASS matchDescription: per sing-box semantics');
}

// ---------------------------------------------------------------- ordering

// 24. moveRule: reorder, renumber, boundary, immutability
{
  const rules = rr.parseRules([
    { id: 'a', type: 'domain_suffix', payload: 'a.com' },
    { id: 'b', type: 'domain_suffix', payload: 'b.com' },
    { id: 'c', type: 'domain_suffix', payload: 'c.com' }
  ]);
  const down = re.moveRule(rules, 'a', 1);
  assert.equal(down.map((r) => r.id).join(','), 'b,a,c', 'a moved down');
  assert.equal(down.map((r) => r.order).join(','), '0,1,2', 'order renumbered');
  assert.equal(rules.map((r) => r.id).join(','), 'a,b,c', 'input not mutated');
  const up = re.moveRule(rules, 'a', -1);
  assert.equal(up.map((r) => r.id).join(','), 'a,b,c', 'boundary unchanged');
  const far = re.moveRule(rules, 'a', 5);
  assert.equal(far.map((r) => r.id).join(','), 'b,c,a', 'delta clamps to end');
  const unknown = re.moveRule(rules, 'zz', 1);
  assert.equal(unknown.map((r) => r.id).join(','), 'a,b,c', 'unknown id unchanged');
  assert.equal(unknown[0].order, 0);
  console.log('PASS moveRule: move/renumber/boundary/immutability');
}

// ---------------------------------------------------------------- legacy (§8.5)

// 25. legacyViews: package/unsupported rows only
{
  const rules = rr.parseRules([
    { id: 'n', type: 'domain_suffix', payload: 'ok.com', outbound: 'proxy' },
    { id: 'p', outbound: 'proxy', packages: 'com.tencent.mm', packagesEnabled: true },
    { id: 'u', type: 'domain_suffix', payload: 'x.com', outbound: 'proxy', unsupportedOnPlatform: true, unsupportedReason: '内核不支持' }
  ]);
  const views = re.legacyViews(rules);
  assert.equal(views.length, 2);
  assert.equal(views[0].rule.id, 'p');
  assert.equal(views[1].rule.id, 'u');
  assert.equal(views[0].actionOptions.join(','), 'pause,convert,delete');
  assert.ok(views[0].summary.indexOf('com.tencent.mm') >= 0, 'package summary carries the payload');
  assert.ok(views[1].summary.indexOf('内核不支持') >= 0, 'unsupported reason surfaces');
  console.log('PASS legacyViews: package + unsupported rows with actions');
}

// 26. applyLegacyAction: pause / convert guard / delete
{
  const rules = rr.parseRules([
    { id: 'pkg', outbound: 'proxy', packages: 'com.tencent.mm', packagesEnabled: true },
    { id: 'uns', type: 'domain_suffix', payload: 'x.com', outbound: 'proxy', unsupportedOnPlatform: true, unsupportedReason: 'r' }
  ]);
  const paused = re.applyLegacyAction(rules[0], 'pause');
  assert.equal(paused.enabled, false, 'pause only disables');
  assert.equal(paused.id, 'pkg');
  assert.ok(paused.payload.indexOf('com.tencent.mm') >= 0, 'payload intact');
  assert.equal(re.applyLegacyAction(rules[0], 'convert'), null, 'convert without form must refuse');
  assert.equal(re.applyLegacyAction(rules[0], 'convert', null), null);
  const badForm = re.emptyForm();
  badForm.type = 'package';
  assert.equal(re.applyLegacyAction(rules[0], 'convert', badForm), null, 'convert to package is not a conversion');
  const emptyForm = re.emptyForm();
  assert.equal(re.applyLegacyAction(rules[0], 'convert', emptyForm), null, 'empty payload form refused');
  const conv = re.emptyForm();
  conv.type = 'domain_suffix';
  conv.payload = 'mm.example.com';
  conv.outbound = 'proxy';
  const converted = re.applyLegacyAction(rules[0], 'convert', conv);
  assert.equal(converted.id, 'pkg', 'id preserved');
  assert.equal(converted.type, 'domain_suffix');
  assert.equal(converted.unsupportedOnPlatform, false, 'unsupported flag cleared');
  assert.equal(converted.payload, 'mm.example.com');
  assert.equal(re.applyLegacyAction(rules[0], 'delete'), null, 'delete returns null');
  assert.equal(re.applyLegacyAction(rules[0], 'magic'), null, 'unknown action');
  console.log('PASS applyLegacyAction: pause/convert-guard/delete');
}

// ---------------------------------------------------------------- logical (§7.3)

// 27. toLogicalExpression: and with 2+ conditions -> sing-box logical
{
  const f = re.emptyForm();
  f.type = 'domain_suffix';
  f.payload = 'a.com,b.com';
  f.destPort = '443,1000:2000';
  f.network = 'tcp';
  f.matchMode = 'and';
  const expr = plain(re.toLogicalExpression(f));
  assert.equal(expr.type, 'logical');
  assert.equal(expr.mode, 'and');
  assert.equal(expr.rules.length, 3);
  assert.deepEqual(expr.rules[0], { domain_suffix: ['a.com', 'b.com'] });
  assert.deepEqual(expr.rules[1], { port: [443], port_range: ['1000:2000'] });
  assert.deepEqual(expr.rules[2], { network: 'tcp' });
  console.log('PASS toLogicalExpression: and builds ConfigBuilder-compatible fields');
}

// 28. toLogicalExpression: source fields, protocol, custom json sub-rule; or -> null; single -> null
{
  const f = re.emptyForm();
  f.payload = 'a.com';
  f.sourceIpCidr = '192.168.0.0/16';
  f.sourcePort = '5000';
  f.protocol = 'tls,http';
  f.customJson = '{"mux":{"enabled":true}}';
  f.matchMode = 'and';
  const expr = plain(re.toLogicalExpression(f));
  assert.deepEqual(expr.rules[1], { source_ip_cidr: ['192.168.0.0/16'] });
  assert.deepEqual(expr.rules[2], { source_port: [5000] });
  assert.deepEqual(expr.rules[3], { protocol: ['tls', 'http'] });
  assert.deepEqual(expr.rules[4], { mux: { enabled: true } }, 'custom json becomes its own sub-rule');
  const orForm = re.emptyForm();
  orForm.payload = 'a.com';
  orForm.destPort = '443';
  orForm.matchMode = 'or';
  assert.equal(re.toLogicalExpression(orForm), null, 'or mode uses flat rules');
  const single = re.emptyForm();
  single.payload = 'a.com';
  single.matchMode = 'and';
  assert.equal(re.toLogicalExpression(single), null, 'single condition needs no logical wrapper');
  console.log('PASS toLogicalExpression: advanced fields + or/single fallbacks');
}

console.log('\nALL rule-editor checks passed');
