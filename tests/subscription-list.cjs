// 主机测试:订阅页视图模型(entry/src/main/ets/model/SubscriptionList.ets)
// VM 转译 + 无平台依赖断言;SubInfo/SubUpdateResult 仅作类型使用，用占位模块注入。
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

const M = load('entry/src/main/ets/model/SubscriptionList.ets', {
  '../core/Subscriptions': { SubInfo: class SubInfo {}, SubUpdateResult: class SubUpdateResult {} }
});

const NOW = Date.UTC(2026, 9, 24, 12, 0, 0);
const DAY = 86400000;

function sub(over) {
  return Object.assign({
    url: '', name: '', group: '', lastUpdate: 0, upload: 0, download: 0, total: 0, expire: 0,
    updateIntervalMinutes: 1440, updateIntervalHours: 0, nextUpdateAt: 0, lastAttemptAt: 0,
    lastError: '', failCount: 0, userAgent: '', autoUpdate: false,
    updateWhenConnectedOnly: false, deduplication: false, forceResolve: false,
    etag: '', lastModified: ''
  }, over);
}
function upd(over) {
  return Object.assign({
    added: 0, removed: 0, total: 0, notModified: false, skipped: 0, skippedNames: [], note: '',
    changed: 0, addedNames: [], updatedNames: [], deletedNames: [], duplicateNames: []
  }, over);
}
const rowsOf = (subs, counts, updating) => M.buildRows(subs, counts || new Map(), NOW, updating);
const json = (v) => JSON.stringify(v);

// ---------- 1. 行构建:基本字段 ----------
{
  const counts = new Map([['https://a.example/sub', 12]]);
  const rows = rowsOf([sub({ url: 'https://a.example/sub', name: '机场 A', group: '主力' })], counts);
  assert.equal(rows.length, 1);
  const row = rows[0];
  assert.equal(row.name, '机场 A');
  assert.equal(row.url, 'https://a.example/sub');
  assert.equal(row.group, '主力');
  assert.equal(row.nodeCount, 12);
  assert.equal(row.state, M.ROW_STATE_NEVER);
  assert.equal(row.lastUpdatedToken, M.LAST_UPDATED_NEVER);
  assert.equal(row.expandableError, false);
  console.log('PASS 行构建:name/url/group/nodeCount/state=never');
}

// ---------- 2. 流量文案(total=0 → 未知;单位换算) ----------
{
  const GB = 1073741824;
  const rows = rowsOf([
    sub({ url: 'u1', upload: 1024 * 1024 * 1024, download: 512 * 1024 * 1024, total: 100 * GB }),
    sub({ url: 'u2', upload: 512, download: 0, total: 0 }),
    sub({ url: 'u3', upload: 2048, download: 0, total: 5 * 1024 * 1024 }),
    sub({ url: 'u4', upload: 0, download: 0, total: 0 })
  ]);
  assert.equal(rows[0].trafficUsedText, '1.50 GB');
  assert.equal(rows[0].trafficTotalText, '100.00 GB');
  assert.equal(rows[1].trafficUsedText, '512 B');
  assert.equal(rows[1].trafficTotalText, '', 'total=0 → 总量空串,页面用 sub_traffic_total_unknown');
  assert.equal(rows[1].usedBytes, 512);
  assert.equal(rows[2].trafficUsedText, '2.0 KB');
  assert.equal(rows[2].trafficTotalText, '5.0 MB');
  assert.equal(rows[3].trafficTotalText, '');
  console.log('PASS 流量字段:GB/MB/KB/B + total=0 时 totalText 为空(页面映射"总量未知")');
}

// ---------- 3. 上次更新时间边界(59s/60s/3599s/3600s/86399s/86400s/30d) ----------
{
  const mk = (ageMs) => {
    const r = rowsOf([sub({ url: 'u', lastUpdate: NOW - ageMs })])[0];
    return `${r.lastUpdatedToken}:${r.lastUpdatedParam}`;
  };
  assert.equal(mk(0), `${M.LAST_UPDATED_JUST_NOW}:0`);
  assert.equal(mk(59000), `${M.LAST_UPDATED_JUST_NOW}:0`);
  assert.equal(mk(60000), `${M.LAST_UPDATED_MINUTES}:1`);
  assert.equal(mk(3599000), `${M.LAST_UPDATED_MINUTES}:59`);
  assert.equal(mk(3600000), `${M.LAST_UPDATED_HOURS}:1`);
  assert.equal(mk(86399000), `${M.LAST_UPDATED_HOURS}:23`);
  assert.equal(mk(DAY), `${M.LAST_UPDATED_DAYS}:1`);
  assert.equal(mk(30 * DAY), `${M.LAST_UPDATED_DAYS}:30`);
  // 系统时间回拨(lastUpdate 在未来)不能出现负数
  assert.equal(mk(-60000), `${M.LAST_UPDATED_JUST_NOW}:0`);
  console.log('PASS 上次更新 token 边界:59s/60s/1h/24h/30d + 时钟回拨');
}

// ---------- 4. 从未更新 vs 有更新 的状态 ----------
{
  const rows = rowsOf([
    sub({ url: 'never' }),
    sub({ url: 'recent', lastUpdate: NOW - 10 * 60000 })
  ]);
  assert.equal(rows[0].state, M.ROW_STATE_NEVER);
  assert.equal(rows[1].state, M.ROW_STATE_OK);
  assert.equal(rows[1].lastUpdatedToken, M.LAST_UPDATED_MINUTES);
  assert.equal(rows[1].lastUpdatedParam, 10);
  console.log('PASS 状态 token:never / ok(P6 起状态文案由页面按 state 映射)');
}

// ---------- 5. 失败:lastError 可展开、原文不丢 ----------
{
  const raw = '订阅服务器返回了 HTML 页面而不是节点列表,请检查订阅地址';
  const rows = rowsOf([sub({ url: 'u', lastUpdate: NOW - DAY, lastError: raw })]);
  assert.equal(rows[0].state, M.ROW_STATE_FAILED);
  assert.equal(rows[0].expandableError, true);
  assert.equal(rows[0].errorText, raw, '失败原文必须原样保留');
  const clean = rowsOf([sub({ url: 'v', lastUpdate: NOW - DAY, lastError: '   ' })]);
  assert.equal(clean[0].expandableError, false, '空白 lastError 不算失败');
  assert.equal(clean[0].state, M.ROW_STATE_OK);
  console.log('PASS 失败态:expandableError + errorText 原文,空白错误忽略');
}

// ---------- 6. 已过期:文案 + 状态 ----------
{
  const expire = Math.floor(NOW / 1000) - 3 * 86400 - 60;
  const rows = rowsOf([sub({ url: 'u', lastUpdate: NOW - DAY, expire })]);
  assert.equal(rows[0].expiryState, M.EXPIRY_EXPIRED);
  assert.equal(rows[0].expiryToken, M.EXPIRY_TOKEN_EXPIRED_DAYS);
  assert.equal(rows[0].expiryParam, 3);
  assert.equal(rows[0].state, M.ROW_STATE_EXPIRED);
  // 刚过期(<1 天)给"刚刚过期"token，不显示 0 天
  const justExpired = rowsOf([sub({ url: 'v', expire: Math.floor(NOW / 1000) - 60 })]);
  assert.equal(justExpired[0].expiryToken, M.EXPIRY_TOKEN_JUST_EXPIRED);
  assert.equal(justExpired[0].expiryParam, 0);
  console.log('PASS 过期态:已过期 N 天 / 刚刚过期 token + expired state');
}

// ---------- 7. 临期(<7 天)与远期日期 ----------
{
  const near = rowsOf([sub({ url: 'near', expire: Math.floor(NOW / 1000) + 3 * 86400 })]);
  assert.equal(near[0].expiryState, M.EXPIRY_NEAR);
  assert.equal(near[0].nearExpiry, true);
  assert.equal(near[0].expiryToken, M.EXPIRY_TOKEN_IN_DAYS);
  assert.equal(near[0].expiryParam, 3);
  // 6 天 23 小时仍算临期(阈值严格 < 7 天)
  const edgeIn = rowsOf([sub({ url: 'in', expire: Math.floor(NOW / 1000) + 7 * 86400 - 3600 })]);
  assert.equal(edgeIn[0].expiryState, M.EXPIRY_NEAR);
  // 恰好 7 天 → 不再是临期，显示 UTC 日期
  const edgeOut = Math.floor(NOW / 1000) + 7 * 86400;
  const out = rowsOf([sub({ url: 'out', expire: edgeOut })]);
  const expectedDate = new Date(edgeOut * 1000).toISOString().slice(0, 10);
  assert.equal(out[0].expiryState, M.EXPIRY_NONE);
  assert.equal(out[0].nearExpiry, false);
  assert.equal(out[0].expiryToken, M.EXPIRY_TOKEN_DATE);
  assert.equal(out[0].expiryDateText, expectedDate, 'date 形态把 UTC 日期放 extraText 供 %1$s');
  // 到期未知
  const unknown = rowsOf([sub({ url: 'unknown', expire: 0 })]);
  assert.equal(unknown[0].expiryToken, M.EXPIRY_TOKEN_UNKNOWN);
  assert.equal(unknown[0].expiryState, M.EXPIRY_NONE);
  console.log('PASS 到期:临期(<7天)/恰好7天转日期/到期未知');
}

// ---------- 8. 自动更新文案(间隔分钟 + autoUpdate 语义 + 旧字段兜底) ----------
{
  const tk = (over) => {
    const r = rowsOf([sub(over)])[0];
    return `${r.autoUpdateToken}:${r.autoUpdateParam}`;
  };
  assert.equal(tk({ autoUpdate: false, updateIntervalMinutes: 1440 }), `${M.AUTO_UPDATE_OFF}:0`);
  assert.equal(tk({ autoUpdate: true, updateIntervalMinutes: 0 }), `${M.AUTO_UPDATE_OFF}:0`);
  assert.equal(tk({ autoUpdate: true, updateIntervalMinutes: -5 }), `${M.AUTO_UPDATE_OFF}:0`);
  assert.equal(tk({ autoUpdate: true, updateIntervalMinutes: 30 }), `${M.AUTO_UPDATE_EVERY_MINUTES}:30`);
  assert.equal(tk({ autoUpdate: true, updateIntervalMinutes: 90 }), `${M.AUTO_UPDATE_EVERY_MINUTES}:90`);
  assert.equal(tk({ autoUpdate: true, updateIntervalMinutes: 60 }), `${M.AUTO_UPDATE_HOURLY}:0`);
  assert.equal(tk({ autoUpdate: true, updateIntervalMinutes: 120 }), `${M.AUTO_UPDATE_EVERY_HOURS}:2`);
  assert.equal(tk({ autoUpdate: true, updateIntervalMinutes: 1440 }), `${M.AUTO_UPDATE_DAILY}:0`);
  assert.equal(tk({ autoUpdate: true, updateIntervalMinutes: 4320 }), `${M.AUTO_UPDATE_EVERY_DAYS}:3`);
  // 旧字段 updateIntervalHours 兜底(与 listSubs 读时迁移同口径)
  assert.equal(tk({ autoUpdate: true, updateIntervalMinutes: 0, updateIntervalHours: 2 }), `${M.AUTO_UPDATE_EVERY_HOURS}:2`);
  assert.equal(tk({}), `${M.AUTO_UPDATE_OFF}:0`, '默认 autoUpdate=false 显示关闭');
  const enabled = rowsOf([sub({ autoUpdate: true, updateIntervalMinutes: 1440 })])[0];
  assert.equal(enabled.autoUpdateEnabled, true);
  console.log('PASS 自动更新 token:关闭/分钟/小时/天 + 旧字段兜底');
}

// ---------- 9. 状态优先级:updating > failed > expired > never > ok ----------
{
  const expired = Math.floor(NOW / 1000) - 86400;
  const base = { url: 'u', lastError: 'x', expire: expired };
  const withUpdating = rowsOf([sub(base)], new Map(), new Set(['u']));
  assert.equal(withUpdating[0].state, M.ROW_STATE_UPDATING);
  const noUpdating = rowsOf([sub(base)]);
  assert.equal(noUpdating[0].state, M.ROW_STATE_FAILED, '失败优先于过期');
  const onlyExpired = rowsOf([sub({ url: 'u', expire: expired, lastUpdate: NOW - DAY })]);
  assert.equal(onlyExpired[0].state, M.ROW_STATE_EXPIRED);
  const onlyNever = rowsOf([sub({ url: 'u', expire: expired })]);
  assert.equal(onlyNever[0].state, M.ROW_STATE_EXPIRED, '过期优先于从未更新');
  console.log('PASS 状态优先级:updating > failed > expired > never > ok');
}

// ---------- 10. 批量摘要:计数 + 失败原文 ----------
{
  const results = [
    upd({ added: 3, removed: 1, total: 10, changed: 5, addedNames: ['a', 'b', 'c'], updatedNames: ['d', 'e'], deletedNames: ['f'] }),
    upd({ notModified: true, total: 10 }),
    upd({ skipped: 2, skippedNames: ['x', 'y'], note: '' }),
    upd({ note: '订阅内容为空' })
  ];
  const s = M.summarizeUpdate(results, [' 网络错误 ', '  ']);
  assert.equal(s.updated, 2);
  assert.equal(s.added, 3);
  assert.equal(s.removed, 1);
  assert.equal(s.notModified, 1);
  assert.equal(s.skipped, 2);
  assert.equal(s.failed, 2, 'note 失败 1 + catch 失败 1;空白失败消息忽略');
  assert.equal(json(s.notes), json(['订阅内容为空']));
  assert.equal(s.failedMessages.length, 2);
  assert.equal(s.failedMessages[0], '订阅内容为空');
  assert.equal(s.failedMessages[1], ' 网络错误 ', '调用方失败原文原样保留(不 trim)');
  // 纯 304:notModified 计数,不算失败、不算更新
  const only304 = M.summarizeUpdate([upd({ notModified: true }), upd({ notModified: true })]);
  assert.equal(only304.notModified, 2);
  assert.equal(only304.updated, 0);
  assert.equal(only304.failed, 0);
  // 304 带 note:记 note 但不算失败
  const note304 = M.summarizeUpdate([upd({ notModified: true, note: '未修改' })]);
  assert.equal(note304.failed, 0);
  assert.equal(json(note304.notes), json(['未修改']));
  const empty = M.summarizeUpdate([]);
  assert.equal(empty.failed, 0);
  assert.equal(empty.updated, 0);
  console.log('PASS 批量摘要:added/removed/updated/notModified/skipped/failed + 原文');
}

// ---------- 11. 摘要结构(P6:kind+value,页面映射 $r) ----------
{
  const a = M.summaryParts(M.summarizeUpdate([upd({ added: 12, removed: 1, updatedNames: ['a', 'b', 'c'] })]));
  assert.equal(a.map((p) => `${p.kind}=${p.value}`).join('|'), 'updated=3|added=12|removed=1');
  const b = M.summaryParts(M.summarizeUpdate([
    upd({ added: 12, removed: 1, updatedNames: ['a', 'b', 'c'] }),
    upd({ notModified: true }),
    upd({ skipped: 1, note: '失败一项' })
  ]));
  assert.equal(b.map((p) => `${p.kind}=${p.value}`).join('|'),
    'updated=3|added=12|removed=1|not_modified=1|skipped=1|failed=1');
  console.log('PASS 摘要结构:恒显 更新/新增/删除,按需追加 未变/跳过/失败 段');
}

// ---------- 12. 排序:名称(不区分大小写/中文码位)+ 最近更新 ----------
{
  const rows = rowsOf([
    sub({ url: 'u1', name: '香 港', lastUpdate: NOW - DAY }),
    sub({ url: 'u2', name: 'Alpha', lastUpdate: NOW - 2 * DAY }),
    sub({ url: 'u3', name: '美 国', lastUpdate: NOW - 3 * DAY }),
    sub({ url: 'u4', name: 'beta', lastUpdate: 0 })
  ]);
  const byName = M.sortSubs(rows, 'name');
  assert.equal(json(byName.map((r) => r.name)), json(['Alpha', 'beta', '美 国', '香 港']));
  const byRecent = M.sortSubs(rows, 'recent');
  assert.equal(json(byRecent.map((r) => r.url)), json(['u1', 'u2', 'u3', 'u4']), '从未更新的排最后');
  // 输入不被修改
  assert.equal(json(rows.map((r) => r.url)), json(['u1', 'u2', 'u3', 'u4']));
  // 未知排序方式按名称处理(容错)
  assert.equal(json(M.sortSubs(rows, 'bogus').map((r) => r.url)), json(['u2', 'u4', 'u3', 'u1']));
  console.log('PASS 排序:名称(大小写/中文码位) + 最近更新 + 不改输入');
}

// ---------- 13. 筛选:名称/URL 子串、大小写、空查询 ----------
{
  const rows = rowsOf([
    sub({ url: 'https://a.example/sub', name: 'Cherry 机场' }),
    sub({ url: 'https://b.example/Special', name: '备用' }),
    sub({ url: 'https://c.example/x', name: '第三个' })
  ]);
  assert.equal(M.filterSubs(rows, 'cherry').length, 1);
  assert.equal(M.filterSubs(rows, '  CHERRY  ').length, 1, '两端空白 + 大小写不敏感');
  assert.equal(M.filterSubs(rows, 'special').length, 1, 'URL 命中');
  assert.equal(M.filterSubs(rows, 'example').length, 3);
  assert.equal(M.filterSubs(rows, '').length, 3);
  assert.equal(M.filterSubs(rows, '   ').length, 3);
  assert.equal(M.filterSubs(rows, 'nope').length, 0);
  console.log('PASS 筛选:名称/URL 子串 + 大小写不敏感 + 空查询全量');
}

// ---------- 14. 空态引导(§4.5) ----------
{
  const none = M.emptyStateFor(3, true);
  assert.equal(none.token, M.EMPTY_NONE);
  assert.equal(none.primaryAction, '');
  assert.equal(none.secondaryActions.length, 0);

  const online = M.emptyStateFor(0, true);
  assert.equal(online.token, M.EMPTY_NO_SUBS);
  assert.equal(online.primaryAction, M.EMPTY_ACTION_ADD);
  assert.equal(json(online.secondaryActions), json(['scan', 'from_file', 'manual']));

  const offline = M.emptyStateFor(0, false);
  assert.equal(offline.token, M.EMPTY_OFFLINE);
  assert.equal(offline.primaryAction, M.EMPTY_ACTION_ADD);
  assert.equal(json(offline.secondaryActions), json(['scan', 'from_file', 'manual']));
  assert.notEqual(offline.token, online.token, '离线/在线空态 token 必须区分(页面映射不同文案)');
  console.log('PASS 空态:no_subs / offline / 有订阅时不渲染 + 动作 token');
}

// ---------- 15. 节点数:按 subUrl 聚合 ----------
{
  const pairs = M.nodeCountsFromSubUrls(['u1', 'u2', 'u1', '', 'u1']);
  assert.equal(pairs.length, 2, '空 subUrl(未归属订阅的节点)不计入');
  const u1 = pairs.find((p) => p.url === 'u1');
  const u2 = pairs.find((p) => p.url === 'u2');
  assert.equal(u1.count, 3);
  assert.equal(u2.count, 1);
  const map = M.nodeCountMap(pairs);
  assert.equal(map.get('u1'), 3);
  assert.equal(map.get('u2'), 1);
  assert.equal(map.get('u3'), undefined);
  // map 与 buildRows 的接口衔接
  const rows = rowsOf([sub({ url: 'u1' }), sub({ url: 'u3' })], map);
  assert.equal(rows[0].nodeCount, 3);
  assert.equal(rows[1].nodeCount, 0);
  console.log('PASS 节点数聚合:nodeCountsFromSubUrls/nodeCountMap 与 buildRows 衔接');
}

// ---------- 16. buildRows 保持输入顺序 + 不修改输入 ----------
{
  const subs = [sub({ url: 'b' }), sub({ url: 'a' }), sub({ url: 'c' })];
  const rows = rowsOf(subs);
  assert.equal(json(rows.map((r) => r.url)), json(['b', 'a', 'c']));
  assert.equal(json(subs.map((s) => s.url)), json(['b', 'a', 'c']));
  assert.equal(subs[0].lastError, '');
  assert.equal(rows[0].state, M.ROW_STATE_NEVER);
  console.log('PASS buildRows 保持顺序且不改输入');
}

// ---------- 17. 空列表:无行、不报错 ----------
{
  const rows = rowsOf([], new Map());
  assert.equal(rows.length, 0);
  assert.equal(M.sortSubs(rows, 'name').length, 0);
  assert.equal(M.filterSubs(rows, 'x').length, 0);
  console.log('PASS 空列表:buildRows/sort/filter 均返回空数组');
}


// ---------- P5/W18:逐订阅更新结果行 ----------
{
  const ok1 = new M.PerSubOutcome();
  Object.assign(ok1, { name: '机场 A', ok: true, added: 3, updated: 2, removed: 1, skipped: 0 });
  const ok2 = new M.PerSubOutcome();
  Object.assign(ok2, { name: '机场 B', ok: true, notModified: true });
  const ok3 = new M.PerSubOutcome();
  Object.assign(ok3, { name: '机场 C', ok: false, error: 'HTTP 503' });
  const lines = M.outcomeLines([ok1, ok2, ok3]);
  assert.equal(lines.length, 3);
  assert.equal(lines[0].kind, 'changed');
  assert.equal(lines[0].name, '机场 A');
  assert.equal(lines[0].changesText, '+3 ~2 -1');
  assert.equal(lines[1].kind, 'not_modified');
  assert.equal(lines[1].name, '机场 B');
  assert.equal(lines[2].kind, 'failed');
  assert.equal(lines[2].name, '机场 C');
  assert.equal(lines[2].error, 'HTTP 503', '失败原文放 error 供资源 %2$s,不吞');
  const skipped = new M.PerSubOutcome();
  Object.assign(skipped, { name: '机场 D', ok: true, added: 1, updated: 0, removed: 0, skipped: 4 });
  const skLine = M.outcomeLines([skipped])[0];
  assert.equal(skLine.changesText, '+1 ~0 -0');
  assert.equal(skLine.skipped, 4, '跳过数单独给,页面映射 sub_summary_skipped');
  // 汇总与逐订阅行由页面分别渲染(summaryParts + outcomeLines),失败行不覆盖其他行
  const summary = M.summarizeUpdate([upd({ added: 4, updatedNames: ['a', 'b'], removed: 1 })]);
  assert.equal(M.summaryParts(summary)[0].kind, 'updated');
  assert.equal(M.summaryParts(summary).length, 3, '零值的 未变/跳过/失败 不产生段');
  console.log('PASS W18 逐订阅结果行:成功/304/失败/跳过互不覆盖(结构化)');
}

// ---------- P5/W18:导入识别结果 ----------
{
  const v = M.buildImportRecognition(12, 3, 2, ['naive+', 'trojan-go:x', 'ssr:a', 'other']);
  assert.equal(v.nodeCount, 12);
  assert.equal(v.groupCount, 3);
  assert.equal(v.skipped, 2);
  assert.equal(v.skippedSamples.length, 2); // 样例数受 skipped 截断,上限 3
  assert.equal(v.empty, false);
  const parts = M.importParts(v);
  assert.equal(parts.map((x) => `${x.kind}=${x.value}`).join('|'), 'nodes=12|groups=3|skipped=2');
  assert.equal(json(v.skippedSamples), json(['naive+', 'trojan-go:x']), '样例原样给页面拼接');
  const v2 = M.buildImportRecognition(5, 0, 0, []);
  assert.equal(M.importParts(v2).map((x) => x.kind).join('|'), 'nodes');
  const v3 = M.buildImportRecognition(0, 0, 1, ['ssr:only']);
  assert.equal(v3.empty, true); // 无有效节点不得提交为空订阅
  assert.equal(M.importParts(v3).map((x) => x.kind).join('|'), 'none');
  console.log('PASS W18 导入识别:节点/分组/跳过结构化、样例截断、空识别不提交');
}

console.log('\nALL subscription-list checks passed');
