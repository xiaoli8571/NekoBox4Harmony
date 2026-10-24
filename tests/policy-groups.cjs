// PolicyGroups model tests (P4/W15, plan §9.1-§9.4).
// Pure model: loaded without @ohos.net.http (PolicyGroups only has a type-only import of ClashApi).
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

const model = load('entry/src/main/ets/model/Profile.ets');
const pg = load('entry/src/main/ets/model/PolicyGroups.ets', { './Profile': model });

const plain = (v) => JSON.parse(JSON.stringify(v));
function group(id, over = {}) {
  const g = new model.ProfileGroup();
  g.id = id;
  g.name = over.name !== undefined ? over.name : id;
  if (over.isSelector) g.isSelector = true;
  if (over.autoSelect) g.autoSelect = true;
  if (over.frontProxy) g.frontProxy = over.frontProxy;
  if (over.landingProxy) g.landingProxy = over.landingProxy;
  return g;
}
function profile(id, groupId) {
  const p = new model.Profile();
  p.id = id;
  p.groupId = groupId;
  return p;
}
// clash api 结果的最小形状(运行时只读 ok/proxies/get)
function proxies(entries, ok = true) {
  const map = new Map();
  Object.keys(entries).forEach((tag) => {
    map.set(tag, Object.assign({ tag, type: 'Selector', now: '', all: [] }, entries[tag]));
  });
  return { ok, reason: ok ? '' : 'refused', proxies: map };
}

// 1. tag 方案：稳定 id 派生、URL 编码、与 ConfigBuilder.profileRootTag 同公式
{
  assert.equal(pg.groupTagFor('g 1'), 'group-g%201');
  assert.equal(pg.groupTagFor('g1'), 'group-g1');
  assert.equal(pg.profileTagFor('p 1'), 'profile-p%201');
  assert.equal(pg.profileTagFor('p1'), 'profile-p1'); // ConfigBuilder.ets:795-797 公式
  const a = pg.buildTagMap([group('g1')]);
  const b = pg.buildTagMap([group('g1')]);
  assert.equal(a.byId.get('g1'), b.byId.get('g1'));
  assert.equal(a.byTag.get('group-g1'), 'g1');
  console.log('PASS tag scheme: ids (not display names), URL-encoded, stable across builds');
}

// 2. 重复 tag 如实列出；同名不同 id 不算重复(显示名不是标识，§9.2-2)
{
  const dup = pg.buildTagMap([group('g1', { name: '香港' }), group('g1', { name: '香港' })]);
  assert.deepEqual(plain(dup.duplicates), ['group-g1']);
  assert.equal(dup.byId.get('g1'), 'group-g1'); // 首次为准，不静默改写
  const sameName = pg.buildTagMap([group('g1', { name: '香港' }), group('g2', { name: '香港' })]);
  assert.equal(sameName.duplicates.length, 0);
  console.log('PASS duplicate tags listed; same display name with different ids is not a duplicate');
}

// 3. 空组：只有提供 profiles 才判定(ProfileGroup 本身没有成员字段)
{
  const groups = [group('g1'), group('g2')];
  const withProfiles = pg.validateGroups(groups, ['p1'], [profile('p1', 'g1')]);
  assert.deepEqual(plain(withProfiles.emptyGroups), ['g2']);
  const withoutProfiles = pg.validateGroups(groups, ['p1']);
  assert.equal(withoutProfiles.emptyGroups.length, 0); // 不猜
  console.log('PASS emptyGroups judged only when member info is supplied');
}

// 4. 引用缺失：frontProxy/landingProxy 指向不存在的 id
{
  const result = pg.validateGroups([
    group('g1', { frontProxy: 'nope', landingProxy: 'p1' })
  ], ['p1']);
  assert.equal(result.missingRefs.length, 1);
  assert.deepEqual(plain(result.missingRefs[0]), { groupId: 'g1', field: 'frontProxy', ref: 'nope' });
  assert.deepEqual(plain(result.invalidPredecessors), ['g1']);
  const ok = pg.validateGroups([group('g1', { frontProxy: 'p1' })], ['p1']);
  assert.equal(ok.missingRefs.length, 0);
  assert.equal(ok.invalidPredecessors.length, 0);
  console.log('PASS missing predecessor/landing refs reported with field+ref');
}

// 5. 自引用：组把自己当前置/落地 → 环 + 失效
{
  const result = pg.validateGroups([group('g1', { frontProxy: 'g1' })], []);
  assert.equal(result.cycles.length, 1);
  assert.deepEqual(plain(result.cycles[0]), ['g1', 'g1']);
  assert.deepEqual(plain(result.invalidPredecessors), ['g1']);
  assert.equal(result.missingRefs.length, 1); // 如实记录自引用这一条引用
  console.log('PASS self reference is a cycle and an invalid predecessor');
}

// 6. 组引用组成环（g1.landingProxy→g2, g2.frontProxy→g1），只报一次
{
  const result = pg.validateGroups([
    group('g1', { landingProxy: 'g2' }),
    group('g2', { frontProxy: 'g1' })
  ], []);
  assert.equal(result.cycles.length, 1);
  const cycle = plain(result.cycles[0]);
  assert.equal(cycle.length, 3); // 首尾相同
  assert.equal(cycle[0], cycle[2]);
  assert.deepEqual(plain(result.invalidPredecessors).sort(), ['g1', 'g2']);
  assert.equal(result.missingRefs.length, 0); // 组引用组不算缺失
  console.log('PASS group→group cycle detected once, both groups flagged invalid');
}

// 7. 组引用组但不成环 → 合法(前向兼容 §9.4)
{
  const result = pg.validateGroups([group('g1', { frontProxy: 'g2' }), group('g2')], []);
  assert.equal(result.cycles.length, 0);
  assert.equal(result.missingRefs.length, 0);
  assert.equal(result.invalidPredecessors.length, 0);
  console.log('PASS acyclic group reference is valid');
}

// 8. 重复 tag 体现在 validateGroups 里
{
  const result = pg.validateGroups([group('g1'), group('g1')], []);
  assert.deepEqual(plain(result.duplicateTags), ['group-g1']);
  console.log('PASS validateGroups surfaces duplicate tags');
}

// 9. compileGroups: selector 组，成员解析成 profile tag；普通组不进内核
{
  const groups = [group('g1', { isSelector: true }), group('g2')];
  const tagMap = pg.buildTagMap(groups);
  const profiles = [profile('p1', 'g1'), profile('p2', 'g1'), profile('p3', 'g2')];
  const entries = pg.compileGroups(groups, tagMap, profiles);
  assert.equal(entries.length, 1); // g2 既非 selector 也非 urltest
  assert.equal(entries[0].tag, 'group-g1');
  assert.equal(entries[0].type, 'selector');
  assert.deepEqual(plain(entries[0].members), ['profile-p1', 'profile-p2']);
  assert.equal(entries[0].url, '');
  console.log('PASS compileGroups resolves members to profile tags and skips plain groups');
}

// 10. compileGroups: urltest 组参数(§9.3 默认 10min/50ms/不中断)
{
  const groups = [group('g1', { autoSelect: true })];
  const entries = pg.compileGroups(groups, pg.buildTagMap(groups), [profile('p1', 'g1')]);
  assert.equal(entries[0].type, 'urltest');
  assert.equal(entries[0].url, 'http://www.gstatic.com/generate_204'); // ConfigBuilder.ets:863 兜底
  assert.equal(entries[0].interval, 600); // 10m
  assert.equal(entries[0].tolerance, 50); // ConfigBuilder.ets:870
  assert.equal(entries[0].interruptExisting, false); // ConfigBuilder.ets:871
  console.log('PASS compileGroups urltest defaults match current ConfigBuilder output');
}

// 11. autoSelect 优先于 isSelector(ConfigBuilder.ets:849-861)
{
  const groups = [group('g1', { autoSelect: true, isSelector: true })];
  const entries = pg.compileGroups(groups, pg.buildTagMap(groups), []);
  assert.equal(entries[0].type, 'urltest');
  console.log('PASS autoSelect wins over isSelector (same as ConfigBuilder)');
}

// 12. probeUrl 覆盖
{
  const groups = [group('g1', { autoSelect: true })];
  const entries = pg.compileGroups(groups, pg.buildTagMap(groups), [], ' https://cp.cloudflare.com ');
  assert.equal(entries[0].url, 'https://cp.cloudflare.com');
  console.log('PASS compileGroups uses caller probeUrl when given');
}

// 13. hotSwitchDecision: selector + 成员在运行图 → 可切
{
  const p = proxies({ proxy: { type: 'Selector', now: 'profile-a', all: ['profile-a', 'profile-b'] } });
  const decision = pg.hotSwitchDecision('selector', 'profile-b', 'proxy', p);
  assert.equal(decision.canSwitch, true);
  assert.equal(decision.reason, '');
  assert.equal(decision.needsRebuild, false);
  console.log('PASS hotSwitchDecision: selector + member in graph → can switch');
}

// 14. hotSwitchDecision: GET 失败 / 组不存在 → needsRebuild
{
  const failed = pg.hotSwitchDecision('selector', 'profile-a', 'proxy', proxies({}, false));
  assert.equal(failed.canSwitch, false);
  assert.equal(failed.reason, 'proxies_failed');
  assert.equal(failed.needsRebuild, true);
  const missing = pg.hotSwitchDecision('selector', 'profile-a', 'proxy', proxies({}));
  assert.equal(missing.reason, 'group_missing');
  assert.equal(missing.needsRebuild, true);
  console.log('PASS hotSwitchDecision: unavailable proxies / missing group need rebuild');
}

// 15. hotSwitchDecision: 内核组是 URLTest → not_selector + needsRebuild(§9.2-5)
{
  const p = proxies({ proxy: { type: 'URLTest', now: 'profile-a', all: ['profile-a'] } });
  const decision = pg.hotSwitchDecision('urltest', 'profile-a', 'proxy', p);
  assert.equal(decision.canSwitch, false);
  assert.equal(decision.reason, 'not_selector');
  assert.equal(decision.needsRebuild, true);
  console.log('PASS hotSwitchDecision: urltest group is not hot-switchable');
}

// 16. hotSwitchDecision: 成员不在运行图 → member_missing + needsRebuild
{
  const p = proxies({ proxy: { type: 'Selector', now: 'profile-a', all: ['profile-a'] } });
  const decision = pg.hotSwitchDecision('selector', 'profile-x', 'proxy', p);
  assert.equal(decision.reason, 'member_missing');
  assert.equal(decision.needsRebuild, true);
  console.log('PASS hotSwitchDecision: member outside the running graph needs rebuild');
}

// 17. hotSwitchDecision: 模型说 urltest 但运行图是 Selector → type_mismatch(对账重建)
{
  const p = proxies({ proxy: { type: 'Selector', now: 'profile-a', all: ['profile-a'] } });
  const decision = pg.hotSwitchDecision('urltest', 'profile-a', 'proxy', p);
  assert.equal(decision.reason, 'type_mismatch');
  assert.equal(decision.needsRebuild, true);
  console.log('PASS hotSwitchDecision: model/runtime type mismatch needs rebuild');
}

// 18. verifyNow: PUT 后 GET 核对 now(§9.2-3)；失败不提前打"正在使用"
{
  const before = proxies({ proxy: { type: 'Selector', now: 'profile-a', all: ['a', 'b'] } });
  const afterOk = proxies({ proxy: { type: 'Selector', now: 'profile-b', all: ['a', 'b'] } });
  const ok = pg.verifyNow(before, afterOk, 'proxy', 'profile-b');
  assert.equal(ok.ok, true);
  assert.equal(ok.reason, '');
  const mismatch = pg.verifyNow(before, before, 'proxy', 'profile-b');
  assert.equal(mismatch.ok, false);
  assert.equal(mismatch.reason, 'now_mismatch');
  const getFailed = pg.verifyNow(before, proxies({}, false), 'proxy', 'profile-b');
  assert.equal(getFailed.reason, 'get_failed');
  const groupMissing = pg.verifyNow(before, proxies({}), 'proxy', 'profile-b');
  assert.equal(groupMissing.reason, 'group_missing');
  // before 不参与判定(仅基线记录)
  assert.equal(pg.verifyNow(null, afterOk, 'proxy', 'profile-b').ok, true);
  console.log('PASS verifyNow trusts only the after snapshot, reports mismatch honestly');
}

// 19. actualMemberView: 未知就未知，绝不用延迟/历史推断(§9.2 末段)
{
  const unknownNoData = pg.actualMemberView('proxy', proxies({}, false));
  assert.equal(unknownNoData.state, 'unknown');
  assert.equal(unknownNoData.label, '实际节点未知');
  const unknownMissing = pg.actualMemberView('proxy', proxies({}));
  assert.equal(unknownMissing.state, 'unknown');
  const unknownEmptyNow = pg.actualMemberView('proxy', proxies({ proxy: { type: 'Selector', now: '', all: ['a'] } }));
  assert.equal(unknownEmptyNow.state, 'unknown');
  const known = pg.actualMemberView('proxy', proxies({ proxy: { type: 'Selector', now: 'profile-a', all: ['a'] } }));
  assert.equal(known.state, 'known');
  assert.equal(known.label, 'profile-a');
  console.log('PASS actualMemberView: unknown when no runtime fact, known label only from now');
}

// 20. autoSelectDefaults 数值(§9.3)
{
  const d = pg.autoSelectDefaults();
  assert.equal(d.url, 'http://www.gstatic.com/generate_204');
  assert.equal(d.intervalSec, 600);
  assert.equal(d.toleranceMs, 50);
  assert.equal(d.interruptExisting, false);
  console.log('PASS autoSelectDefaults: 10min / 50ms / keep existing connections');
}

console.log('\nALL policy-groups checks passed');
