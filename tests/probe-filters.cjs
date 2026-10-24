// ProbeFilters view-model tests (P2/W10, plan §6.2/§6.6/§4.2).
// 转译 + VM 模式（同 probe-coordinator.cjs）；只比较字符串/标量，不对跨 realm 数组用 deepStrictEqual。
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

const model = load('entry/src/main/ets/model/ProbeResult.ets');
const filters = load('entry/src/main/ets/model/ProbeFilters.ets', {
  './ProbeResult': model
});

const mkResult = (profileId, state, latencyMs = -1, extra = {}) => {
  const r = new model.ProbeResult();
  r.profileId = profileId;
  r.state = state;
  r.latencyMs = latencyMs;
  r.methodRequested = model.PROBE_METHOD_HTTP;
  r.methodActual = model.PROBE_METHOD_HTTP;
  r.path = model.PROBE_PATH_DIRECT_BOUND;
  r.expectedStatus = model.PROBE_EXPECT_2XX;
  r.completedAt = 1000;
  Object.assign(r, extra);
  return r;
};

const legacyOf = (profileId, latencyMs = 88) => model.ProbeResult.fromLegacy(profileId, 1, latencyMs, '');

const snapshot = (arr) => JSON.stringify(arr.map((r) => [
  r.profileId, r.state, r.latencyMs, r.methodActual, r.methodRequested, r.path, r.expectedStatus, r.completedAt
]));

(async () => {
  const NOW = 2000;
  const STALE = 1000;

  // 1. filterUsable: success+fresh kept; failed/stale excluded; empty in -> empty out
  const keep = mkResult('p1', model.PROBE_STATE_SUCCESS, 10, { completedAt: 1500 });
  const fail = mkResult('p2', model.PROBE_STATE_FAILED, -1, { completedAt: 1500 });
  const old = mkResult('p3', model.PROBE_STATE_SUCCESS, 20, { completedAt: 100 });
  const input1 = [keep, fail, old];
  const snap1 = snapshot(input1);
  const usable = filters.filterUsable(input1, NOW, STALE);
  assert.equal(usable.length, 1, 'only fresh success is usable');
  assert.equal(usable[0].profileId, 'p1');
  assert.equal(filters.filterUsable([], NOW, STALE).length, 0, 'empty input -> empty output');
  assert.equal(snapshot(input1), snap1, 'filterUsable must not mutate input');
  console.log('PASS filterUsable keeps fresh success only');

  // 2. filterUsable: legacy results never usable (method unknown), even when fresh
  const legacyFresh = legacyOf('p9', 88);
  legacyFresh.completedAt = 1500;
  assert.equal(filters.filterUsable([legacyFresh], NOW, STALE).length, 0,
    'legacy result must not participate in usable filtering (plan §6.2)');
  console.log('PASS filterUsable excludes legacy results');

  // 3. sortByLatency: 0ms first, ascending, failed last, defensive success(-1) not treated as 0
  const failed = mkResult('f1', model.PROBE_STATE_FAILED, -1);
  const s200 = mkResult('s200', model.PROBE_STATE_SUCCESS, 200);
  const s0 = mkResult('s0', model.PROBE_STATE_SUCCESS, 0);
  const s50 = mkResult('s50', model.PROBE_STATE_SUCCESS, 50);
  const sNeg = mkResult('sNeg', model.PROBE_STATE_SUCCESS, -1);
  const input3 = [failed, s200, s0, s50, sNeg];
  const snap3 = snapshot(input3);
  const sorted = filters.sortByLatency(input3);
  assert.equal(sorted.map((r) => r.profileId).join(','), 's0,s50,s200,f1,sNeg',
    '0ms legal first, ascending, failed last; success(-1) must not sort as 0');
  assert.equal(snapshot(input3), snap3, 'sortByLatency must not mutate input');
  assert.equal(filters.sortByLatency([]).length, 0, 'empty input -> empty output');
  console.log('PASS sortByLatency: 0ms first / ascending / failed last / -1 not zero');

  // 4. sortByLatency stability: equal latency keeps input order
  const a = mkResult('a', model.PROBE_STATE_SUCCESS, 100);
  const b = mkResult('b', model.PROBE_STATE_SUCCESS, 100);
  assert.equal(filters.sortByLatency([a, b]).map((r) => r.profileId).join(','), 'a,b',
    'stable sort must keep input order for equal latency');
  assert.equal(filters.sortByLatency([b, a]).map((r) => r.profileId).join(','), 'b,a',
    'stable sort must keep input order for equal latency (reversed input)');
  console.log('PASS sortByLatency is stable for equal latency');

  // 5. pickFreshestPerProfile: dedupe runs; recency wins regardless of method (no HTTP preference)
  const p1Old = mkResult('p1', model.PROBE_STATE_SUCCESS, 10, { completedAt: 1000 });
  const p1New = mkResult('p1', model.PROBE_STATE_SUCCESS, 20, { completedAt: 2000 });
  const p2Http = mkResult('p2', model.PROBE_STATE_SUCCESS, 30, { completedAt: 1000, methodActual: model.PROBE_METHOD_HTTP });
  const p2Tcp = mkResult('p2', model.PROBE_STATE_SUCCESS, 40, { completedAt: 2000, methodActual: model.PROBE_METHOD_TCPING });
  const p3Alone = mkResult('p3', model.PROBE_STATE_SUCCESS, 60, { completedAt: 500 });
  const picked = filters.pickFreshestPerProfile([p1Old, p1New, p2Http, p2Tcp, p3Alone]);
  assert.equal(picked.length, 3, 'one entry per profileId');
  assert.equal(picked.find((r) => r.profileId === 'p1').completedAt, 2000, 'newest run wins');
  const p2Pick = picked.find((r) => r.profileId === 'p2');
  assert.equal(p2Pick.methodActual, model.PROBE_METHOD_TCPING,
    'newer TCPing must not be overridden by older HTTP (method is not a preference factor)');
  assert.equal(filters.pickFreshestPerProfile([]).length, 0, 'empty input -> empty output');
  console.log('PASS pickFreshestPerProfile dedupes by profileId with recency only');

  // 6. pickFreshestPerProfile tie: equal completedAt -> later occurrence wins (later observation = newer)
  const tieFirst = mkResult('p4', model.PROBE_STATE_SUCCESS, 10, { completedAt: 1000, path: model.PROBE_PATH_DIRECT_BOUND });
  const tieSecond = mkResult('p4', model.PROBE_STATE_SUCCESS, 20, { completedAt: 1000, path: model.PROBE_PATH_CURRENT_TUNNEL });
  const tiePick = filters.pickFreshestPerProfile([tieFirst, tieSecond]);
  assert.equal(tiePick.length, 1);
  assert.equal(tiePick[0].path, model.PROBE_PATH_CURRENT_TUNNEL,
    'tie on completedAt resolves to the later-observed entry');
  console.log('PASS pickFreshestPerProfile tie-break: later observation wins');

  // 7. groupByMethodPath: distinct groups, exact labelTokens, unique labels, deterministic order
  const gHttp = mkResult('p1', model.PROBE_STATE_SUCCESS, 10);
  const gHttpFail = mkResult('p2', model.PROBE_STATE_FAILED, -1);
  const gTcp = mkResult('p3', model.PROBE_STATE_SUCCESS, 20, { methodActual: model.PROBE_METHOD_TCPING, path: model.PROBE_PATH_CURRENT_TUNNEL });
  const gTun = mkResult('p4', model.PROBE_STATE_SUCCESS, 30, { path: model.PROBE_PATH_CURRENT_TUNNEL });
  const gLegacy = legacyOf('p5', 99);
  const groups = filters.groupByMethodPath([gHttp, gHttpFail, gTcp, gTun, gLegacy]);
  assert.equal(groups.length, 4, 'method+path (plus legacy) form distinct groups');
  const byKey = {};
  for (const g of groups) {
    byKey[g.key] = g;
  }
  assert.deepEqual(Object.keys(byKey).sort(), ['http|currentTunnel', 'http|directBound', 'tcping|currentTunnel', 'unknown|legacyUnknown'],
    'group keys are method|path');
  assert.equal(byKey['http|directBound'].labelToken, 'http_directBound');
  assert.equal(byKey['tcping|currentTunnel'].labelToken, 'tcping_currentTunnel');
  assert.equal(byKey['unknown|legacyUnknown'].labelToken, 'unknown_legacyUnknown');
  assert.equal(new Set(groups.map((g) => g.labelToken)).size, groups.length, 'group labelTokens must be unique');
  assert.equal(byKey['http|directBound'].count, 2);
  assert.equal(byKey['http|directBound'].usableCount, 1, 'failed result must not count as usable');
  assert.equal(byKey['unknown|legacyUnknown'].usableCount, 0, 'legacy success must not count as usable');
  assert.equal(groups[0].key, 'http|directBound', 'deterministic order: http/directBound first');
  assert.equal(groups[groups.length - 1].key, 'unknown|legacyUnknown', 'legacy group last');
  console.log('PASS groupByMethodPath: distinct method/path groups with unique labels and deterministic order');

  // 8. groupByMethodPath criteria: same (method,path) with different expectedStatus recorded, not merged silently
  const crit2xx = mkResult('p1', model.PROBE_STATE_SUCCESS, 10, { expectedStatus: model.PROBE_EXPECT_2XX });
  const critAny = mkResult('p1', model.PROBE_STATE_SUCCESS, 20, { expectedStatus: model.PROBE_EXPECT_ANY });
  const mixed = filters.groupByMethodPath([crit2xx, critAny]);
  assert.equal(mixed.length, 1, 'group key stays method|path per W10 spec');
  assert.equal(mixed[0].count, 2);
  assert.equal(mixed[0].criteria.join(','), '2xx,any',
    'mixed criteria must be surfaced so pages can split display (plan §6.6: never merge values across criteria)');
  console.log('PASS groupByMethodPath surfaces mixed criteria without merging values');

  // 9. mergeLiveWithStored: newer side wins; live-only / stored-only rows; inputs untouched
  const live = [
    mkResult('p1', model.PROBE_STATE_SUCCESS, 10, { completedAt: 2000 }),
    mkResult('p2', model.PROBE_STATE_SUCCESS, 20, { completedAt: 1000 }),
    mkResult('p3', model.PROBE_STATE_SUCCESS, 30, { completedAt: 2000 })
  ];
  const stored = [
    mkResult('p1', model.PROBE_STATE_SUCCESS, 11, { completedAt: 1000 }),
    mkResult('p2', model.PROBE_STATE_SUCCESS, 22, { completedAt: 3000 }),
    mkResult('p4', model.PROBE_STATE_SUCCESS, 40, { completedAt: 1500 })
  ];
  const snapLive = snapshot(live);
  const snapStored = snapshot(stored);
  const merged = filters.mergeLiveWithStored(live, stored);
  assert.equal(merged.length, 4, 'one row per profileId across live+stored');
  const byProfile = {};
  for (const m of merged) {
    byProfile[m.result.profileId] = m;
  }
  assert.equal(byProfile['p1'].result.latencyMs, 10, 'live newer -> live wins');
  assert.equal(byProfile['p1'].fromHistory, false);
  assert.equal(byProfile['p2'].result.latencyMs, 22, 'stored newer -> stored wins');
  assert.equal(byProfile['p2'].fromHistory, true);
  assert.equal(byProfile['p3'].fromHistory, false, 'live-only row');
  assert.equal(byProfile['p4'].fromHistory, true, 'stored-only row');
  assert.equal(snapshot(live), snapLive, 'mergeLiveWithStored must not mutate live');
  assert.equal(snapshot(stored), snapStored, 'mergeLiveWithStored must not mutate stored');
  console.log('PASS mergeLiveWithStored picks newer side per profileId');

  // 10. merge: cancelled live must not override stored success (plan §6.3)
  const live2 = [
    mkResult('c1', model.PROBE_STATE_CANCELLED, -1, { completedAt: 2000, participated: model.PROBE_STATE_CANCELLED }),
    mkResult('c2', model.PROBE_STATE_CANCELLED, -1, { completedAt: 2000 })
  ];
  const stored2 = [
    mkResult('c1', model.PROBE_STATE_SUCCESS, 12, { completedAt: 1000 }),
    mkResult('c3', model.PROBE_STATE_SUCCESS, 13, { completedAt: 1000 })
  ];
  const merged2 = filters.mergeLiveWithStored(live2, stored2);
  const m1 = merged2.find((m) => m.result.profileId === 'c1');
  assert.equal(m1.result.latencyMs, 12, 'cancelled live must not override stored success');
  assert.equal(m1.fromHistory, true);
  assert.equal(m1.preservedStored, true, 'preservedStored must be flagged');
  const m2 = merged2.find((m) => m.result.profileId === 'c2');
  assert.equal(m2.result.state, model.PROBE_STATE_CANCELLED, 'cancelled live without stored stays cancelled (not failed)');
  assert.equal(m2.preservedStored, false);
  const m3 = merged2.find((m) => m.result.profileId === 'c3');
  assert.equal(m3.fromHistory, true, 'stored-only row is history');
  console.log('PASS cancelled live preserves stored success (plan §6.3)');

  // 11. merge isStale: with time params uses isComparableFresh; without, falls back to fromHistory
  const live3 = [mkResult('p1', model.PROBE_STATE_SUCCESS, 10, { completedAt: 2000 })];
  const stored3 = [mkResult('p1', model.PROBE_STATE_SUCCESS, 20, { completedAt: 500 })];
  const withTime = filters.mergeLiveWithStored(live3, stored3, 2000, 1000);
  assert.equal(withTime[0].result.completedAt, 2000);
  assert.equal(withTime[0].isStale, false, 'fresh live is not stale');
  const onlyOld = filters.mergeLiveWithStored([], [mkResult('p9', model.PROBE_STATE_SUCCESS, 20, { completedAt: 500 })], 2000, 1000);
  assert.equal(onlyOld[0].isStale, true, 'stored result older than staleMs is stale');
  const noTime = filters.mergeLiveWithStored(live3, stored3);
  assert.equal(noTime.length, 1);
  assert.equal(noTime[0].isStale, false, 'no time params -> live winner is not stale');
  const histNoTime = filters.mergeLiveWithStored([], stored3);
  assert.equal(histNoTime[0].isStale, true, 'no time params -> history row conservatively stale');
  console.log('PASS mergeLiveWithStored staleness: isComparableFresh with time, fromHistory fallback');

  // 12. summarize: state counts, unfinished = queued+running, empty -> all zeros
  const mixedStates = [
    mkResult('p1', model.PROBE_STATE_SUCCESS, 10),
    mkResult('p2', model.PROBE_STATE_SUCCESS, 20),
    mkResult('p3', model.PROBE_STATE_FAILED, -1),
    mkResult('p4', model.PROBE_STATE_CANCELLED, -1),
    mkResult('p5', model.PROBE_STATE_NOT_APPLICABLE, -1),
    mkResult('p6', model.PROBE_STATE_UNSAVED, -1),
    mkResult('p7', model.PROBE_STATE_QUEUED, -1),
    mkResult('p8', model.PROBE_STATE_RUNNING, -1)
  ];
  const sum = filters.summarize(mixedStates);
  assert.equal(sum.total, 8);
  assert.equal(sum.success, 2);
  assert.equal(sum.failed, 1);
  assert.equal(sum.cancelled, 1);
  assert.equal(sum.notApplicable, 1);
  assert.equal(sum.unsaved, 1);
  assert.equal(sum.unfinished, 2, 'queued+running count as unfinished');
  const emptySum = filters.summarize([]);
  assert.equal(emptySum.total + emptySum.success + emptySum.failed + emptySum.cancelled
    + emptySum.notApplicable + emptySum.unsaved + emptySum.unfinished, 0, 'empty input -> all zeros');
  console.log('PASS summarize counts all states with unfinished = queued+running');

  // 13. historyFor: descending by completedAt, limit applied, legacy viewable, miss -> empty
  const h3 = mkResult('p1', model.PROBE_STATE_SUCCESS, 10, { completedAt: 3000 });
  const h1 = mkResult('p1', model.PROBE_STATE_SUCCESS, 20, { completedAt: 1000 });
  const h2 = mkResult('p1', model.PROBE_STATE_FAILED, -1, { completedAt: 2000 });
  const hOther = mkResult('p9', model.PROBE_STATE_SUCCESS, 30, { completedAt: 4000 });
  const hist = filters.historyFor('p1', [h3, h1, h2, hOther]);
  assert.equal(hist.map((r) => r.completedAt).join(','), '3000,2000,1000', 'descending by completedAt');
  assert.equal(filters.historyFor('p1', [h3, h1, h2, hOther], 2).length, 2, 'limit applies');
  assert.equal(filters.historyFor('p1', [h3, h1, h2, hOther], 2)[0].completedAt, 3000, 'limit keeps newest first');
  assert.equal(filters.historyFor('missing', [h3, h1, h2, hOther]).length, 0, 'unknown profileId -> empty');
  assert.equal(filters.historyFor('p1', [h3, h1, h2, hOther], 0).length, 0, 'limit<=0 -> empty');
  const withLegacy = filters.historyFor('p1', [h3, legacyOf('p1', 77)]);
  assert.equal(withLegacy.length, 2, 'legacy results remain viewable in history');
  assert.equal(withLegacy[1].methodActual, model.PROBE_METHOD_UNKNOWN);
  assert.equal(model.isComparableFresh(withLegacy[1], NOW, STALE), false, 'legacy history is not comparable-fresh');
  console.log('PASS historyFor: desc order, limit, legacy viewable but not comparable');

  // 14. shouldShowRetest: any failed/unsaved/notApplicable/cancelled -> true; all success/empty -> false
  assert.equal(filters.shouldShowRetest([mkResult('p1', model.PROBE_STATE_SUCCESS, 10)]), false,
    'all success -> no retest entry');
  assert.equal(filters.shouldShowRetest([mkResult('p1', model.PROBE_STATE_FAILED, -1)]), true);
  assert.equal(filters.shouldShowRetest([mkResult('p1', model.PROBE_STATE_UNSAVED, -1)]), true);
  assert.equal(filters.shouldShowRetest([mkResult('p1', model.PROBE_STATE_NOT_APPLICABLE, -1)]), true);
  assert.equal(filters.shouldShowRetest([mkResult('p1', model.PROBE_STATE_CANCELLED, -1)]), true);
  assert.equal(filters.shouldShowRetest([]), false, 'empty -> false');
  assert.equal(filters.shouldShowRetest([mkResult('p1', model.PROBE_STATE_QUEUED, -1)]), false,
    'in-flight is not a failure');
  console.log('PASS shouldShowRetest triggers on any failed/unsaved/notApplicable/cancelled');

  // 15. methodLabelToken: exact tokens per plan §6.2/§6.6 wording
  const t2xx = filters.methodLabelToken(mkResult('p1', model.PROBE_STATE_SUCCESS, 10));
  assert.equal(t2xx, 'http_2xx');
  const tAny = filters.methodLabelToken(mkResult('p1', model.PROBE_STATE_SUCCESS, 10, { expectedStatus: model.PROBE_EXPECT_ANY }));
  assert.equal(tAny, 'http_any_response', 'any criteria wording is "HTTP 有响应" family, never "正常访问"');
  const tTcp = filters.methodLabelToken(mkResult('p1', model.PROBE_STATE_SUCCESS, 10, { methodRequested: model.PROBE_METHOD_TCPING, methodActual: model.PROBE_METHOD_TCPING }));
  assert.equal(tTcp, 'tcping');
  const tLegacy = filters.methodLabelToken(legacyOf('p1'));
  assert.equal(tLegacy, 'unknown');
  const tDegraded = filters.methodLabelToken(mkResult('p1', model.PROBE_STATE_SUCCESS, 10, { methodActual: model.PROBE_METHOD_TCPING }));
  assert.equal(tDegraded, 'http_degraded_tcping', 'actual != requested must surface degradation');
  const tUnknown = filters.methodLabelToken(mkResult('p1', model.PROBE_STATE_SUCCESS, 10, { methodActual: 'weird' }));
  assert.equal(tUnknown, 'unknown');
  console.log('PASS methodLabelToken: 2xx / any-response / tcping / unknown / degraded');

  // 16. freshnessToken: fresh / stale / untested; failed is never "untested"; 0ms is fresh
  const fFresh = mkResult('p1', model.PROBE_STATE_SUCCESS, 10, { completedAt: 1500 });
  assert.equal(filters.freshnessToken(fFresh, NOW, STALE), 'fresh');
  const fStale = mkResult('p1', model.PROBE_STATE_SUCCESS, 10, { completedAt: 100 });
  assert.equal(filters.freshnessToken(fStale, NOW, STALE), 'stale');
  const fUntested = mkResult('p1', model.PROBE_STATE_QUEUED, -1, { completedAt: 0 });
  assert.equal(filters.freshnessToken(fUntested, NOW, STALE), 'untested', 'latency<0 and not failed -> untested');
  const fFailed = mkResult('p1', model.PROBE_STATE_FAILED, -1, { completedAt: 1500 });
  assert.equal(filters.freshnessToken(fFailed, NOW, STALE), 'fresh', 'current failure is a fresh value (viewable, not untested)');
  const fLegacy = legacyOf('p1');
  assert.equal(filters.freshnessToken(fLegacy, NOW, STALE), 'stale', 'legacy is stale, never fresh');
  const fZero = mkResult('p1', model.PROBE_STATE_SUCCESS, 0, { completedAt: 1500 });
  assert.equal(filters.freshnessToken(fZero, NOW, STALE), 'fresh', '0ms is a legal fresh value, not untested');
  console.log('PASS freshnessToken: fresh/stale/untested with 0ms legal and legacy stale');

  console.log('\nALL probe-filters checks passed');
})().catch((e) => { console.error('FAIL', e); process.exit(1); });
