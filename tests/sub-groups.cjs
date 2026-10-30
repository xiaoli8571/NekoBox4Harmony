// 主机测试:「首页只看一个订阅」纯逻辑(core/SubGroups.ets)
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));

function load(file, imports = {}) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const js = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(js, {
    exports,
    require: (name) => {
      if (!(name in imports)) {
        throw new Error(`unexpected import: ${name}`);
      }
      return imports[name];
    }
  });
  return exports;
}

// 只作类型引用(编译后擦除),给个空桩即可
const S = load('entry/src/main/ets/core/SubGroups.ets', { '../model/Profile': {} });

// vm realm 里的数组原型与宿主不同,deepStrictEqual 会误报;统一按 JSON 比较
function same(actual, expected) {
  assert.equal(JSON.stringify(Array.from(actual)), JSON.stringify(expected));
}

function group(id, name, order, subUrl) {
  return { id, name, sortOrder: order, subUrl: subUrl || '' };
}
function node(id, name, groupId, subUrl) {
  return { id, name, groupId, subUrl };
}

const A = 'https://a.example/sub';
const B = 'https://b.example/sub';

// ---------- 1. 归属推断 ----------
{
  const g = group('g1', '自动选择', 0, A);
  assert.equal(S.inferGroupSubUrl(g, []), A, '显式 subUrl 优先');

  const legacy = group('g2', '香港', 1, '');
  assert.equal(S.inferGroupSubUrl(legacy, [node('n1', 'x', 'g2', A)]), A, '按成员反推');
  assert.equal(S.inferGroupSubUrl(legacy, [node('n1', 'x', 'g2', A), node('n2', 'y', 'g2', A), node('n3', 'z', 'g2', B)]), A, '多数票');
  assert.equal(S.inferGroupSubUrl(legacy, [node('n1', 'x', 'g2', B), node('n2', 'y', 'g2', A)]), A, '平票取字典序小者(稳定)');
  assert.equal(S.inferGroupSubUrl(legacy, []), '', '无成员 → 推不出');
  assert.equal(S.inferGroupSubUrl(legacy, [node('n1', 'x', 'OTHER', A)]), '', '只算本组成员');
  assert.equal(S.inferGroupSubUrl(legacy, [node('n1', 'x', 'g2', '')]), '', '成员无订阅归属 → 空');
  console.log('PASS inferGroupSubUrl: 显式/反推/多数票/平票稳定');
}

// ---------- 2. 订阅分组集合 ----------
{
  const groups = [
    group('g1', '自动选择', 2, A),
    group('g2', '香港', 0, A),
    group('g3', '美国', 1, B),
    group('legacy', '日本', 3, ''),
    group('manual', '我的手动组', 4, '')
  ];
  const profiles = [
    node('n1', 'hk1', 'g2', A),
    node('n2', 'us1', 'g3', B),
    node('n3', 'jp1', 'legacy', A),
    node('n4', 'm1', 'manual', ''),
    node('n5', 'auto1', 'g1', A)
  ];
  const a = S.groupsForSubscription(groups, profiles, A);
  same(a.map((g) => g.id), ['g2', 'g1', 'legacy'], 'A 的分组按 sortOrder,含反推组');
  const b = S.groupsForSubscription(groups, profiles, B);
  same(b.map((g) => g.id), ['g3']);
  same(S.groupsForSubscription(groups, profiles, ''), [], '空 = 不筛(由调用方走原逻辑)');

  const ids = S.groupIdsForSubscription(groups, profiles, A);
  same(ids, ['g2', 'g1', 'legacy'], '只有本订阅且有节点的组');
  console.log('PASS groupsForSubscription/groupIdsForSubscription');
}

// ---------- 3. 未分组兜底 ----------
{
  const groups = [group('g1', '香港', 0, A)];
  const profiles = [node('n1', 'hk1', 'g1', A), node('n2', 'loose', '', A), node('n3', 'other', '', B)];
  const ids = S.groupIdsForSubscription(groups, profiles, A);
  same(ids, ['g1', ''], '未分组殿后,且只算本订阅的未分组节点');

  const noLoose = S.groupIdsForSubscription(groups, [node('n1', 'hk1', 'g1', A)], A);
  same(noLoose, ['g1'], '没有未分组节点就不给空组');

  const emptyGroup = S.groupIdsForSubscription([group('g9', '空组', 0, A)], [], A);
  same(emptyGroup, [], '没有节点的组不显示');
  console.log('PASS 未分组兜底: 只统计本订阅节点');
}

// ---------- 4. 节点过滤 ----------
{
  const profiles = [node('n1', 'a', 'g1', A), node('n2', 'b', 'g2', B)];
  same(S.nodesOfSubscription(profiles, A).map((p) => p.id), ['n1']);
  same(S.nodesOfSubscription(profiles, '').map((p) => p.id), ['n1', 'n2'], '空 = 全部');
  same(S.nodesOfSubscription(profiles, 'https://gone/sub'), [], '不存在的订阅 → 空');
  console.log('PASS nodesOfSubscription');
}

// ---------- 5. 订阅被删后的回落 ----------
{
  const subs = [{ url: A }, { url: B }];
  assert.equal(S.normalizeActiveSub(A, subs), A);
  assert.equal(S.normalizeActiveSub(' https://a.example/sub ', subs), A, '去空白');
  assert.equal(S.normalizeActiveSub('https://deleted/sub', subs), '', '订阅已删 → 回落到全部');
  assert.equal(S.normalizeActiveSub('', subs), '');
  assert.equal(S.normalizeActiveSub(A, []), '', '订阅列表为空 → 回落到全部');
  console.log('PASS normalizeActiveSub');
}

// ---------- 6. 多重归属(Clash proxy-groups 多对多) ----------
{
  const multi = { id: 'n1', name: 'hk1', groupId: 'auto', subUrl: A,
    subGroupIds: ['auto', 'hk', 'stream'] };
  assert.equal(S.belongsToGroup(multi, 'auto'), true, '主分组算归属');
  assert.equal(S.belongsToGroup(multi, 'hk'), true, '副分组也算归属');
  assert.equal(S.belongsToGroup(multi, 'us'), false);

  const groups = [group('auto', '自动选择', 0, A), group('hk', '香港', 1, A), group('us', '美国', 2, A)];
  same(S.groupIdsForSubscription(groups, [multi], A), ['auto', 'hk']);

  // 老数据没有 subGroupIds 字段也不能炸
  const legacy = { id: 'n2', name: 'old', groupId: 'auto', subUrl: A };
  assert.equal(S.belongsToGroup(legacy, 'auto'), true);
  assert.equal(S.belongsToGroup(legacy, 'hk'), false);
  console.log('PASS belongsToGroup: 多对多归属 + 老数据兼容');
}

// ---------- 7. 多选(订阅页复选框) ----------
{
  same(S.parseActiveSubs(''), []);
  same(S.parseActiveSubs(A), [A], '兼容旧的单值');
  same(S.parseActiveSubs(JSON.stringify([A, B])), [A, B]);
  same(S.parseActiveSubs(JSON.stringify([A, A, ' '])), [A], '去重去空白');
  same(S.parseActiveSubs('[]'), []);
  same(S.parseActiveSubs('{oops'), [], '坏 JSON → 空(回落全部)');

  same(S.toggleActiveSub([], A), [A]);
  same(S.toggleActiveSub([A], A), [], '再点取消');
  same(S.toggleActiveSub([A], B), [A, B]);
  same(S.toggleActiveSub([A, B], A), [B]);

  same(S.normalizeActiveSubs([A, B, 'https://gone/sub'], [{ url: A }, { url: B }]), [A, B], '删订阅后清理');

  assert.equal(S.inActiveSubs(A, []), true, '空集合 = 全显示');
  assert.equal(S.inActiveSubs(A, [A, B]), true);
  assert.equal(S.inActiveSubs('https://x/sub', [A]), false);
  console.log('PASS 多选: parse/toggle/normalize/inActiveSubs');
}

// ---------- 8. 多选范围下的分组 ----------
{
  const groups = [group('g1', '自动选择', 0, A), group('g2', '香港', 1, A), group('g3', '美国', 2, B)];
  const profiles = [node('n1', 'hk1', 'g1', A), node('n2', 'us1', 'g3', B), node('n3', 'loose', '', B)];
  same(S.groupIdsForSubscriptions(groups, profiles, [A]), ['g1']);
  same(S.groupIdsForSubscriptions(groups, profiles, [A, B]), ['g1', 'g3', ''], '多选合并 + 未分组殿后');
  same(S.groupIdsForSubscriptions(groups, profiles, []), [], '空集合交给调用方走全量');
  console.log('PASS 多选分组: 合并/未分组/空集合');
}

console.log('\nALL sub-groups checks passed');
