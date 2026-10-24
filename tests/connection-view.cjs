// 主机测试:连接列表与「为什么走这条线路」视图模型(P5/W19,§10.1/§10.2)
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));

function load(file) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const js = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(js, { exports, require: () => { throw new Error('no imports expected'); } });
  return exports;
}
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
const M = load('entry/src/main/ets/model/ConnectionView.ets');

// ---------- 1. 解析:字段完整 + 空字段不拼 undefined ----------
{
  const raw = JSON.stringify({
    connections: [
      {
        id: 'c1',
        metadata: { host: 'example.com', destinationIP: '1.2.3.4', network: 'tcp' },
        chains: ['东京 01', 'proxy', 'DIRECT2'],
        rule: 'geosite(cn)', rulePayload: '',
        upload: 1024, download: 2048, start: '2026-10-24T08:00:00.000Z'
      },
      {
        id: 'c2',
        metadata: { host: '', destinationIP: '9.9.9.9', network: 'udp' },
        chains: ['direct'],
        rule: 'geoip(private)', rulePayload: 'private',
        upload: 1, download: 2, start: ''
      },
      {
        id: 'c3',
        metadata: {},
        chains: [],
        rule: '', rulePayload: undefined,
        upload: 0, download: 0
      }
    ]
  });
  const items = M.parseConnections(raw);
  assert.equal(items.length, 3);
  // chains 逆序:入口在左,最终节点 = 原始 chains[0]
  assert.ok(sameArr(items[0].chains.slice(), ['DIRECT2', 'proxy', '东京 01']));
  assert.equal(items[0].finalNode, '东京 01');
  assert.equal(items[0].host, 'example.com');
  assert.equal(items[0].start, Date.parse('2026-10-24T08:00:00.000Z'));
  // host 空 → 显示 IP;不出现字符串 "undefined"
  assert.equal(items[1].host, '9.9.9.9');
  assert.ok(!items.some((i) => i.host.includes('undefined')));
  assert.equal(items[1].rulePayload, 'private');
  // 全空 → 未提供由视图层兜底,原始字段为空串
  assert.equal(items[2].host, '');
  assert.equal(items[2].chainClass, M.CHAIN_UNKNOWN);
  // 坏输入
  assert.equal(M.parseConnections('not json').length, 0);
  assert.equal(M.parseConnections('{"connections": null}').length, 0);
  assert.equal(M.parseConnections('{}').length, 0);
  console.log('PASS 解析:chains 逆序/空字段空串/坏输入空数组,不拼 undefined');
}

// ---------- 2. 链路分类:只用实际证据 ----------
{
  assert.equal(M.classifyChain('geoip(cn)', ['节点A', 'proxy']), M.CHAIN_PROXY);
  assert.equal(M.classifyChain('geoip(private)', ['direct']), M.CHAIN_DIRECT);
  assert.equal(M.classifyChain('direct', []), M.CHAIN_DIRECT);
  assert.equal(M.classifyChain('rule-set(block-ads)', ['节点A']), M.CHAIN_REJECT);
  assert.equal(M.classifyChain('reject', []), M.CHAIN_REJECT);
  assert.equal(M.classifyChain('', []), M.CHAIN_UNKNOWN);
  assert.equal(M.classifyChain('GeoSite(cn)', []), M.CHAIN_UNKNOWN); // 只有规则无链 → 未知,不猜
  console.log('PASS 分类:direct/reject/proxy/unknown 只按实际 chains 与 rule');
}

// ---------- 3. 过滤:模式 + 搜索(仅实际分类可滤) ----------
{
  const raw = JSON.stringify({
    connections: [
      { id: 'a', metadata: { host: 'a.com', network: 'tcp' }, chains: ['n1'], rule: 'geosite(x)', upload: 0, download: 0 },
      { id: 'b', metadata: { host: 'b.com', network: 'tcp' }, chains: ['direct'], rule: 'geoip(private)', upload: 0, download: 0 },
      { id: 'c', metadata: { host: 'c.com', network: 'tcp' }, chains: ['n2'], rule: 'rule-set(block)', upload: 0, download: 0 }
    ]
  });
  const items = M.parseConnections(raw);
  assert.equal(M.filterConnections(items, '', '').length, 3);
  assert.equal(M.filterConnections(items, M.CHAIN_PROXY, '').length, 1);
  assert.equal(M.filterConnections(items, M.CHAIN_DIRECT, '').length, 1);
  assert.equal(M.filterConnections(items, M.CHAIN_REJECT, '').length, 1);
  assert.equal(M.filterConnections(items, M.CHAIN_PROXY, 'b.com').length, 0);
  assert.equal(M.filterConnections(items, '', 'b.com')[0].id, 'b');
  assert.equal(M.filterConnections(items, '', 'n1')[0].id, 'a'); // 按最终节点搜索
  assert.equal(M.filterConnections(items, '', 'geoip')[0].id, 'b');
  console.log('PASS 过滤:分类筛选与 host/最终节点/规则 搜索');
}

// ---------- 4. 「为什么走这条线路」证据视图 ----------
{
  const raw = JSON.stringify({
    connections: [{
      id: 'c1',
      metadata: { host: 'example.com', destinationIP: '1.2.3.4', network: 'tcp' },
      chains: ['东京 01', 'proxy'],
      rule: 'geosite(cn)', rulePayload: '',
      upload: 1, download: 2, start: '2026-10-24T08:00:00.000Z'
    }]
  });
  const item = M.parseConnections(raw)[0];
  const ev = M.buildRouteEvidence(item, 42, 1729752000000);
  assert.equal(ev.target, 'example.com');
  assert.equal(ev.ruleText, 'geosite(cn)');
  assert.equal(ev.rulePayloadProvided, false);      // 内核没给 payload → 不伪造
  assert.ok(sameArr(ev.chainList.slice(), ['proxy', '东京 01']));
  assert.equal(ev.finalNode, '东京 01');
  assert.equal(ev.runningRevision, 42);
  assert.equal(ev.collectedAtMs, 1729752000000);
  assert.equal(ev.localRuleName, '');               // 无法证明唯一对应 → 不链接本地规则名
  // 空字段 → 保留空串(P6/W21:「未提供」由页面用资源键兜底,模型不产用户语言)
  const empty = M.parseConnections(JSON.stringify({
    connections: [{ id: 'z', metadata: {}, chains: [], rule: '', rulePayload: '', upload: 0, download: 0 }]
  }))[0];
  const ev2 = M.buildRouteEvidence(empty, 0, 1);
  assert.equal(ev2.target, '');
  assert.equal(ev2.ruleText, '');
  assert.equal(ev2.finalNode, '');
  assert.equal(ev2.network, '');
  assert.equal(ev2.runningRevision, 0);             // 未知 revision 如实为 0
  assert.equal(M.evidenceSummaryLine(ev2), '', '全空证据的摘要行是空串,不拼占位');
  const line = M.evidenceSummaryLine(ev);
  assert.ok(line.includes('example.com'));
  assert.ok(line.includes('geosite(cn)'));
  assert.ok(line.includes('proxy → 东京 01'));
  console.log('PASS 证据视图:目标/规则原文/链/最终节点/revision/采集时间;payload 不伪造,空=未提供');
}

console.log('connection-view: ALL PASS');
