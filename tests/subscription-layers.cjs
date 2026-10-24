// 主机测试:订阅三层数据模型(entry/src/main/ets/model/SubscriptionLayers.ets,P5/W17)
// VM 转译 + 真实 Profile/ConfigSnapshot(均为零依赖纯文件)。
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

const ProfileMod = load('entry/src/main/ets/model/Profile.ets');
const SnapshotMod = load('entry/src/main/ets/model/ConfigSnapshot.ets');
const M = load('entry/src/main/ets/model/SubscriptionLayers.ets', {
  './Profile': ProfileMod,
  './ConfigSnapshot': SnapshotMod
});

function sameArr(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}
const Profile = ProfileMod.Profile;

function node(over) {
  const p = new Profile();
  Object.assign(p, {
    name: '东京 01', type: 'shadowsocks', server: '1.2.3.4', serverPort: 8388,
    method: 'aes-128-gcm', password: 'pass'
  }, over || {});
  return p;
}
const storageId = (p, url) => `store_${p.server}_${p.serverPort}_${url.length}`;
const NOW = Date.UTC(2026, 9, 24, 8, 0, 0);
const URL_A = 'https://sub-a.example/link';

// ---------- 1. 身份键:显示名不参与 ----------
{
  const a = node({ name: '东京 01' });
  const b = node({ name: '东京 01 · IPLC' }); // 远端只改名
  assert.equal(M.identityKeyOf(URL_A, a), M.identityKeyOf(URL_A, b));
  const c = node({ name: '东京 01', serverPort: 8389 });
  assert.notEqual(M.identityKeyOf(URL_A, a), M.identityKeyOf(URL_A, c));
  const d = node({ name: '东京 01', password: 'other' });
  assert.notEqual(M.identityKeyOf(URL_A, a), M.identityKeyOf(URL_A, d));
  // 订阅 URL 参与身份(跨订阅同参数不算同一节点)
  assert.notEqual(M.identityKeyOf(URL_A, a), M.identityKeyOf('https://sub-b.example/x', a));
  // 运行期字段不参与
  const e = node({ name: '东京 01', latencyMs: 120, rx: 999, pinned: true, sortOrder: 7 });
  assert.equal(M.identityKeyOf(URL_A, a), M.identityKeyOf(URL_A, e));
  console.log('PASS 身份键:显示名/运行期字段不参与,传输特征与订阅 URL 参与');
}

// ---------- 2. urlKeyOf ----------
{
  assert.match(M.urlKeyOf(URL_A), /^[0-9a-f]{8}$/);
  assert.equal(M.urlKeyOf(URL_A), M.urlKeyOf(URL_A));
  assert.notEqual(M.urlKeyOf(URL_A), M.urlKeyOf('https://other.example/'));
  console.log('PASS urlKeyOf:fnv1a hex 且按 URL 区分');
}

// ---------- 3. 源快照序列化往返 ----------
{
  const snap = new M.SubscriptionSourceSnapshot();
  snap.url = URL_A;
  snap.fetchedAt = NOW;
  snap.format = 'clash-yaml';
  snap.etag = 'W/"abc"';
  snap.lastModified = 'Mon, 24 Oct 2026 08:00:00 GMT';
  snap.contentHash = 'fnv1a-deadbeef';
  const n1 = M.sourceNodeOf(node({ name: '香港 01' }));
  n1.identityKey = M.identityKeyOf(URL_A, node({ name: '香港 01' }));
  snap.nodes.push(n1);
  snap.nodeCount = 1;
  const parsed = M.parseSourceSnapshot(M.sourceSnapshotToJson(snap));
  assert.notEqual(parsed, null);
  assert.equal(parsed.url, URL_A);
  assert.equal(parsed.fetchedAt, NOW);
  assert.equal(parsed.format, 'clash-yaml');
  assert.equal(parsed.etag, 'W/"abc"');
  assert.equal(parsed.nodes.length, 1);
  assert.equal(parsed.nodes[0].sourceName, '香港 01');
  assert.equal(parsed.nodes[0].identityKey, n1.identityKey);
  assert.equal(parsed.nodes[0].fields['server'], '1.2.3.4');
  // 缺 url/fetchedAt → null(不静默)
  assert.equal(M.parseSourceSnapshot('{"fetchedAt":1}'), null);
  assert.equal(M.parseSourceSnapshot('{"url":"u"}'), null);
  assert.equal(M.parseSourceSnapshot('not json'), null);
  console.log('PASS 源快照:JSON 往返字段完整,非法输入返回 null');
}

// ---------- 4. 覆盖记录序列化(白名单 + 无效过滤 + 传输覆盖白名单) ----------
{
  const o = new M.UserOverride();
  o.subscriptionUrl = URL_A;
  o.identityKey = 'sid_abc';
  o.alias = '我的别名';
  o.pinned = true;
  o.sortOrder = 3;
  o.displayGroupId = 'grp_1';
  o.deletedAt = 0;
  o.updatedAt = NOW;
  const fo = new M.FieldOverride();
  fo.field = 'serverPort';
  fo.value = '9999';
  o.transportOverrides.push(fo);
  const rec = M.overrideToRecord(o);
  const back = M.parseOverrideRecord(rec);
  assert.notEqual(back, null);
  assert.equal(back.alias, '我的别名');
  assert.equal(back.pinned, true);
  assert.equal(back.sortOrder, 3);
  assert.equal(back.transportOverrides.length, 1);
  assert.equal(back.transportOverrides[0].field, 'serverPort');
  // 白名单外的传输字段被丢弃
  const bad = JSON.parse(JSON.stringify(rec));
  bad.transportOverrides = [{ field: 'name', value: 'x' }, { field: 'password', value: 'y' }];
  const backBad = M.parseOverrideRecord(bad);
  assert.equal(backBad.transportOverrides.length, 1); // password 在白名单
  const bad2 = JSON.parse(JSON.stringify(rec));
  bad2.transportOverrides = [{ field: 'hacker', value: 'x' }];
  assert.equal(M.parseOverrideRecord(bad2).transportOverrides.length, 0);
  // 缺身份 → null
  assert.equal(M.parseOverrideRecord({ subscriptionUrl: URL_A }), null);
  assert.equal(M.parseOverrideRecord({ identityKey: 'sid' }), null);
  console.log('PASS 覆盖记录:白名单往返,白名单外字段与无效记录被拒');
}

// ---------- 5. mergeEffective ----------
{
  const nodes = [1, 2].map((i) => {
    const p = node({ name: `节点 ${i}`, server: `10.0.0.${i}` });
    const n = M.sourceNodeOf(p);
    n.identityKey = M.identityKeyOf(URL_A, p);
    return n;
  });
  const alias = new M.UserOverride();
  alias.subscriptionUrl = URL_A;
  alias.identityKey = nodes[0].identityKey;
  alias.alias = '别名 A';
  alias.pinned = true;
  alias.sortOrder = 5;
  const tomb = new M.UserOverride();
  tomb.subscriptionUrl = URL_A;
  tomb.identityKey = 'sid_deleted';
  tomb.alias = '已删节点';
  tomb.pinned = true;
  tomb.deletedAt = NOW - 1000;
  const out = M.mergeEffective(nodes, [alias, tomb], URL_A);
  assert.equal(out.effective.length, 2);
  assert.equal(out.effective[0].effectiveName, '别名 A');
  assert.equal(out.effective[0].pinned, true);
  assert.equal(out.effective[0].sortOrder, 5);
  assert.equal(out.effective[0].hasOverride, true);
  assert.equal(out.effective[1].effectiveName, '节点 2');
  assert.equal(out.effective[1].hasOverride, false);
  // 墓碑不在有效视图,单独列出
  assert.equal(out.effective.filter((e) => e.deleted).length, 0);
  assert.equal(out.tombstones.length, 1);
  assert.equal(out.tombstones[0].identityKey, 'sid_deleted');
  // 墓碑身份重新出现 → 复活
  const revivedNode = M.sourceNodeOf(node({ name: '回归', server: '10.0.0.9' }));
  revivedNode.identityKey = 'sid_deleted';
  const out2 = M.mergeEffective([revivedNode], [tomb], URL_A);
  assert.equal(out2.effective.length, 1);
  assert.equal(out2.effective[0].pinned, true);
  assert.ok(sameArr(out2.revived, ['sid_deleted']), JSON.stringify([out2.revived, ['sid_deleted']]));
  // 活跃覆盖无源节点 → unmatched(调用方提交时转墓碑)
  const orphan = new M.UserOverride();
  orphan.subscriptionUrl = URL_A;
  orphan.identityKey = 'sid_orphan';
  const out3 = M.mergeEffective([], [orphan], URL_A);
  assert.equal(out3.unmatchedOverrides.length, 1);
  // 源内重复身份 → 冲突,不重复输出
  const dup = M.sourceNodeOf(node({ name: '重复', server: '10.0.0.1' }));
  dup.identityKey = nodes[0].identityKey;
  const out4 = M.mergeEffective([nodes[0], dup], [], URL_A);
  assert.equal(out4.effective.length, 1);
  assert.equal(out4.conflicts.length, 1);
  assert.equal(out4.conflicts[0].kind, 'duplicate_identity');
  // 传输覆盖与源当前值不一致 → transportConflict
  const tconf = new M.UserOverride();
  tconf.subscriptionUrl = URL_A;
  tconf.identityKey = nodes[0].identityKey;
  tconf.transportOverrides.push({ field: 'serverPort', value: '9999' });
  const out5 = M.mergeEffective(nodes, [tconf], URL_A);
  assert.equal(out5.effective[0].transportConflict, true);
  // 其他订阅的覆盖不参与本订阅合并
  const other = new M.UserOverride();
  other.subscriptionUrl = 'https://other/';
  other.identityKey = nodes[0].identityKey;
  other.alias = '别家';
  const out6 = M.mergeEffective(nodes, [other], URL_A);
  assert.equal(out6.effective[0].effectiveName, '节点 1');
  console.log('PASS mergeEffective:别名/墓碑/复活/unmatched/重复冲突/传输冲突/订阅隔离');
}

// ---------- 6. classifyUpdate ----------
{
  const mk = (name, server) => {
    const p = node({ name, server });
    const n = M.sourceNodeOf(p);
    n.identityKey = M.identityKeyOf(URL_A, p);
    return n;
  };
  const prev = new M.SubscriptionSourceSnapshot();
  prev.url = URL_A;
  prev.fetchedAt = NOW - 60000;
  prev.nodes = [mk('旧名 A', '10.0.0.1'), mk('B', '10.0.0.2'), mk('C', '10.0.0.3')];
  const next = new M.SubscriptionSourceSnapshot();
  next.url = URL_A;
  next.fetchedAt = NOW;
  // A 改名(身份不变)、B 参数变更、C 删除、D 新增
  next.nodes = [mk('新名 A', '10.0.0.1'), mk('B', '10.0.0.2x'), mk('D', '10.0.0.4')];
  const tover = new M.UserOverride();
  tover.subscriptionUrl = URL_A;
  tover.identityKey = prev.nodes[1].identityKey;
  tover.transportOverrides.push({ field: 'server', value: '10.0.0.2' });
  const c = M.classifyUpdate(prev, next, [tover], URL_A);
  assert.equal(c.added.length, 1);
  assert.equal(c.removed.length, 1);
  assert.equal(c.removed[0], prev.nodes[2].identityKey);
  assert.equal(c.renamed.length, 1);
  assert.equal(c.renamed[0], prev.nodes[0].identityKey);
  assert.equal(c.transportChanged.length, 1);
  assert.equal(c.transportChanged[0], next.nodes[1].identityKey); // 冲突/变更记在新身份上(覆盖随迁)
  assert.equal(c.overrideConflicts.length, 1);
  assert.equal(c.overrideConflicts[0], next.nodes[1].identityKey);
  const c2 = M.classifyUpdate(null, next, [], URL_A);
  assert.equal(c2.added.length, 3);
  assert.equal(c2.removed.length, 0);
  const c3 = M.classifyUpdate(prev, prev, [], URL_A);
  assert.equal(c3.unchanged, 3);
  assert.equal(c3.added.length, 0);
  console.log('PASS classifyUpdate:新增/删除/改名/参数变更/覆盖冲突/无变化/首拉');
}

// ---------- 7. mergeParsedIntoOwned:远端改名不再 加+删 ----------
{
  const oldA = node({ name: '东京 01', server: '10.0.0.1', id: 'id_A', pinned: true, sortOrder: 2, rx: 111, tx: 222, latencyMs: 88, status: 1, ping: 88, latencyTestedAt: 123456 });
  const owned = [oldA];
  const parsed = [node({ name: '东京 01 · 改名', server: '10.0.0.1' })]; // 只改名
  const r = M.mergeParsedIntoOwned(parsed, owned, [], URL_A, 'grp_1', storageId, NOW);
  assert.equal(r.kept.length, 1);
  assert.equal(r.kept[0].id, 'id_A');           // 身份保留 → id 保留
  assert.equal(r.kept[0].name, '东京 01 · 改名'); // 名称跟随源
  assert.equal(r.kept[0].pinned, true);          // 用户态保留
  assert.equal(r.kept[0].sortOrder, 2);
  assert.equal(r.kept[0].rx, 111);
  assert.equal(r.kept[0].status, 1);
  assert.ok(sameArr(r.addedNames, []), JSON.stringify([r.addedNames, []]));
  assert.ok(sameArr(r.deletedNames, []), JSON.stringify([r.deletedNames, []]));
  assert.equal(r.updatedNames.length, 1);        // 名称变化记为 updated
  assert.equal(r.changed, 1);
  // 覆盖回填:活跃节点生成 override 记录
  assert.equal(r.nextOverrides.length, 1);
  assert.equal(r.nextOverrides[0].pinned, true);
  assert.equal(r.nextOverrides[0].deletedAt, 0);
  console.log('PASS 合并:远端改名=同一节点(id/pinned/排序/流量保留),不产生加删');
}

// ---------- 8. mergeParsedIntoOwned:用户别名优先于远端改名 ----------
{
  const oldA = node({ name: '我的别名', server: '10.0.0.1', id: 'id_A' });
  const ov = new M.UserOverride();
  ov.subscriptionUrl = URL_A;
  ov.identityKey = M.identityKeyOf(URL_A, oldA);
  ov.alias = '我的别名';
  const parsed = [node({ name: '远端新名', server: '10.0.0.1' })];
  const r = M.mergeParsedIntoOwned(parsed, [oldA], [ov], URL_A, 'grp_1', storageId, NOW);
  assert.equal(r.kept[0].name, '我的别名');
  assert.equal(r.kept[0].id, 'id_A');
  assert.ok(sameArr(r.updatedNames, []), JSON.stringify([r.updatedNames, []])); // 有效名没变
  console.log('PASS 合并:用户别名优先,远端改名不覆盖别名');
}

// ---------- 9. mergeParsedIntoOwned:远端删除 → 墓碑;复活 → 保留用户态 ----------
{
  const oldA = node({ name: 'A', server: '10.0.0.1', id: 'id_A', pinned: true, sortOrder: 4 });
  const oldB = node({ name: 'B', server: '10.0.0.2', id: 'id_B' });
  // 第一次:B 从源里消失
  let r = M.mergeParsedIntoOwned(
    [node({ name: 'A', server: '10.0.0.1' })], [oldA, oldB], [], URL_A, 'grp_1', storageId, NOW);
  assert.ok(sameArr(r.deletedNames, ['B']), JSON.stringify([r.deletedNames, ['B']]));
  assert.equal(r.kept.length, 1);
  assert.equal(r.nextOverrides.length, 2); // A 活跃 + B 墓碑
  const tomb = r.nextOverrides.find((o) => o.deletedAt > 0);
  assert.notEqual(tomb, undefined);
  assert.equal(tomb.pinned, false);
  assert.equal(tomb.sortOrder, 0);
  // 第二次:B 回归 → 复活(清 deletedAt),并带优先覆盖恢复 pinned
  const revived = new M.UserOverride();
  revived.subscriptionUrl = URL_A;
  revived.identityKey = tomb.identityKey;
  revived.pinned = true;
  revived.deletedAt = NOW;
  r = M.mergeParsedIntoOwned(
    [node({ name: 'A', server: '10.0.0.1' }), node({ name: 'B', server: '10.0.0.2' })],
    [oldA], [r.nextOverrides.find((o) => o.deletedAt === 0), revived], URL_A, 'grp_1', storageId, NOW + 1000);
  assert.equal(r.kept.length, 2);
  const back = r.kept.find((p) => p.name === 'B');
  assert.notEqual(back, undefined);
  assert.equal(back.pinned, true); // 墓碑覆盖恢复
  assert.ok(sameArr(r.addedNames, ['B']), JSON.stringify([r.addedNames, ['B']]));
  assert.equal(r.nextOverrides.filter((o) => o.deletedAt > 0).length, 0);
  console.log('PASS 合并:远端删除转墓碑(可恢复),回归复活并保留用户覆盖');
}

// ---------- 10. mergeParsedIntoOwned:参数变更/新节点/重复身份 ----------
{
  const oldA = node({ name: 'A', server: '10.0.0.1', id: 'id_A' });
  // 参数变更:端口变了,身份不同但显式改名场景不适用 —— 身份=传输特征,端口变=新身份。
  // 这里验证:同 server 不同端口 → 新增 + 旧删除(与身份定义一致,如实记录)。
  let r = M.mergeParsedIntoOwned(
    [node({ name: 'A2', server: '10.0.0.1', serverPort: 9999 })],
    [oldA], [], URL_A, 'grp_1', storageId, NOW);
  assert.ok(sameArr(r.deletedNames, ['A']), JSON.stringify([r.deletedNames, ['A']]));
  assert.ok(sameArr(r.addedNames, ['A2']), JSON.stringify([r.addedNames, ['A2']]));
  assert.notEqual(r.kept[0].id, 'id_A');
  assert.equal(r.kept[0].id, storageId(r.kept[0], URL_A)); // 存储 id 由注入函数分配
  // 内容与名字都没变 → 不进 updated
  r = M.mergeParsedIntoOwned(
    [node({ name: 'A', server: '10.0.0.1' })], [node({ name: 'A', server: '10.0.0.1', id: 'id_A' })],
    [], URL_A, 'grp_1', storageId, NOW);
  assert.ok(sameArr(r.updatedNames, []), JSON.stringify([r.updatedNames, []]));
  assert.ok(sameArr(r.addedNames, []), JSON.stringify([r.addedNames, []]));
  assert.ok(sameArr(r.deletedNames, []), JSON.stringify([r.deletedNames, []]));
  assert.equal(r.changed, 0);
  // 源内重复身份(同传输特征两节点)→ 冲突,取首个
  r = M.mergeParsedIntoOwned(
    [node({ name: 'X', server: '10.0.0.1' }), node({ name: 'Y', server: '10.0.0.1' })],
    [], [], URL_A, 'grp_1', storageId, NOW);
  assert.equal(r.kept.length, 1);
  assert.equal(r.conflicts.length, 1);
  assert.equal(r.conflicts[0].kind, 'duplicate_identity');
  // 本地重复身份 → 冲突记录,保留首个
  r = M.mergeParsedIntoOwned(
    [node({ name: 'Z', server: '10.0.0.7' })],
    [node({ name: 'Z1', server: '10.0.0.7', id: 'z1' }), node({ name: 'Z2', server: '10.0.0.7', id: 'z2' })],
    [], URL_A, 'grp_1', storageId, NOW);
  assert.equal(r.kept[0].id, 'z1');
  assert.equal(r.conflicts.filter((c) => c.kind === 'duplicate_identity').length, 1);
  console.log('PASS 合并:参数变更=换身份(如实加删)/无变化零计数/源与本地重复身份都记冲突');
}

// ---------- 11. changed 口径(Android RawUpdater:deleted+added+updated) ----------
{
  const owned = [
    node({ name: 'keep', server: '10.0.0.1', id: 'k' }),
    node({ name: 'gone', server: '10.0.0.2', id: 'g' })
  ];
  const parsed = [
    node({ name: 'keep', server: '10.0.0.1' }),
    node({ name: 'keep2', server: '10.0.0.3' }),
    node({ name: 'mod', server: '10.0.0.9' })
  ];
  const r = M.mergeParsedIntoOwned(parsed, owned, [], URL_A, 'grp_1', storageId, NOW);
  assert.equal(r.changed, r.deletedNames.length + r.addedNames.length + r.updatedNames.length);
  console.log('PASS changed 口径 = 删除+新增+更新');
}

// ---------- 12. profileFromSourceNode:墓碑转手动节点用 ----------
{
  const p = node({ name: '源名', server: '10.1.1.1', serverPort: 443, password: 'pw' });
  const rec = M.sourceNodeOf(p);
  const back = M.profileFromSourceNode(rec);
  assert.equal(back.name, '源名');
  assert.equal(back.server, '10.1.1.1');
  assert.equal(back.serverPort, 443);
  assert.equal(back.password, 'pw');
  assert.equal(back.subUrl, ''); // 不携带订阅归属(转手动)
  console.log('PASS profileFromSourceNode:白名单字段还原,不带订阅归属');
}

console.log('subscription-layers: ALL PASS');
