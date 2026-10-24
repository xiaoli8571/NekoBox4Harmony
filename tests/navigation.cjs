// Navigation contract tests (P3/W11, plan §3.1-§3.4).
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

const nav = load('entry/src/main/ets/core/Navigation.ets', {});

(async () => {
  // 1. six pages, stable drawer order(2026-10-24 用户指示:工具+关于合并为「系统」)
  const defs = nav.pageDefs();
  assert.equal(defs.length, 6);
  assert.deepEqual(defs.map((d) => d.id).join(','), 'nodes,subscriptions,routing,settings,logs,system');
  assert.deepEqual(defs.map((d) => d.titleFallback).join(','), '节点,订阅,分流,设置,日志,系统');
  assert.equal(pageDef(defs[0]).drawerIndex, 0);
  assert.equal(pageDef(defs[5]).drawerIndex, 5);
  console.log('PASS six pages in drawer order 节点/订阅/分流/设置/日志/系统');

  function pageDef(d) { return d; }

  // 2. legacy tab mapping (0..6) and unknown falls back to nodes
  assert.equal(nav.pageByLegacyTab(0).id, nav.PAGE_NODES);
  assert.equal(nav.pageByLegacyTab(1).id, nav.PAGE_SUBSCRIPTIONS);
  assert.equal(nav.pageByLegacyTab(2).id, nav.PAGE_ROUTING);
  assert.equal(nav.pageByLegacyTab(3).id, nav.PAGE_SETTINGS);
  assert.equal(nav.pageByLegacyTab(5).id, nav.PAGE_SYSTEM, 'legacy 工具 tab → 系统');
  assert.equal(nav.pageByLegacyTab(6).id, nav.PAGE_SYSTEM, 'legacy 关于 tab → 系统(合并兼容)');
  assert.equal(nav.pageByLegacyTab(99).id, nav.PAGE_NODES);
  console.log('PASS legacy activeTab 0..6 maps to new pages(5/6→system); unknown falls back to nodes');

  // 3. pageById unknown → null
  assert.equal(nav.pageById('nope'), null);
  assert.equal(nav.pageById(nav.PAGE_SETTINGS).titleKey, 'app_page_settings');
  console.log('PASS pageById lookup');

  // 4. back semantics matrix (§3.4)
  const mk = (drawer, page, parent) => {
    const c = new nav.BackContext();
    c.drawerOpen = drawer;
    c.currentPage = page;
    c.hasParent = parent;
    return c;
  };
  assert.equal(nav.resolveBack(mk(true, nav.PAGE_NODES, false)), nav.BACK_CLOSE_DRAWER);
  assert.equal(nav.resolveBack(mk(false, nav.PAGE_SETTINGS, true)), nav.BACK_PARENT);
  assert.equal(nav.resolveBack(mk(false, nav.PAGE_SETTINGS, false)), nav.BACK_NODES);
  assert.equal(nav.resolveBack(mk(false, nav.PAGE_NODES, false)), nav.BACK_EXIT);
  console.log('PASS back: drawer first, then parent, then node page, then exit');

  // 5. top bar actions per page (§3.3)
  const ctx = new nav.TopBarContext();
  ctx.hasProfiles = true;
  ctx.hasSubscriptions = true;
  const nodeActions = nav.topBarActions(nav.PAGE_NODES, ctx).map((a) => a.id).join(',');
  assert.equal(nodeActions, 'search,probe', 'node page: search + probe');
  const subActions = nav.topBarActions(nav.PAGE_SUBSCRIPTIONS, ctx).map((a) => a.id).join(',');
  assert.equal(subActions, 'add,updateAll', 'subscriptions page: add + update all');
  assert.equal(nav.topBarActions(nav.PAGE_SYSTEM, ctx).length, 0, 'system page has no placeholder actions (§3.3)');
  console.log('PASS top bar actions per page (system has no placeholder actions)');

  // 6. probe action replaced by progress/cancel while probing (§3.3)
  const probing = new nav.TopBarContext();
  probing.hasProfiles = true;
  probing.probing = true;
  probing.probeCancellable = true;
  const pActions = nav.topBarActions(nav.PAGE_NODES, probing).map((a) => a.id).join(',');
  assert.equal(pActions, 'search,probeProgress,probeCancel', 'probe action becomes progress+cancel while running');
  const probingNoCancel = nav.topBarActions(nav.PAGE_NODES, (() => { const c = new nav.TopBarContext();
    c.hasProfiles = true; c.probing = true; c.probeCancellable = false; return c; })()).map((a) => a.id).join(',');
  assert.equal(probingNoCancel, 'search,probeProgress');
  console.log('PASS probe action becomes progress/cancel while probing');

  // 7. disabled actions carry reasons (§3.3 must give reason, never silent)
  const empty = new nav.TopBarContext();
  const nodeEmpty = nav.topBarActions(nav.PAGE_NODES, empty);
  const probe = nodeEmpty.find((a) => a.id === nav.ACTION_PROBE);
  assert.ok(!probe.enabled);
  assert.equal(probe.disabledReason, nav.ACTION_REASON_NO_PROFILES);
  const subEmpty = nav.topBarActions(nav.PAGE_SUBSCRIPTIONS, empty);
  const upd = subEmpty.find((a) => a.id === nav.ACTION_UPDATE_ALL);
  assert.ok(!upd.enabled);
  assert.equal(upd.disabledReason, nav.ACTION_REASON_NO_SUBSCRIPTIONS);
  const unsupported = nav.topBarActions(nav.PAGE_NODES, (() => { const c = new nav.TopBarContext();
    c.hasProfiles = true; c.probeSupported = false; return c; })());
  assert.equal(unsupported.find((a) => a.id === nav.ACTION_PROBE).disabledReason, nav.ACTION_REASON_PROBE_UNSUPPORTED);
  console.log('PASS disabled actions carry machine-readable reasons');

  // 8. NavMemory per-page isolation
  const mem = new nav.NavMemory();
  mem.setSearch(nav.PAGE_NODES, '香港');
  mem.setSearch(nav.PAGE_SETTINGS, 'dns');
  assert.equal(mem.getSearch(nav.PAGE_NODES), '香港');
  assert.equal(mem.getSearch(nav.PAGE_SETTINGS), 'dns');
  assert.equal(mem.getSearch(nav.PAGE_LOGS), '');
  mem.setScroll(nav.PAGE_NODES, 240);
  assert.equal(mem.getScroll(nav.PAGE_NODES), 240);
  assert.equal(mem.getScroll(nav.PAGE_LOGS), 0);
  console.log('PASS per-page search/scroll memory isolated');

  // 9. group collapse toggle + selection
  mem.setSelectedGroupId('g1');
  mem.toggleGroupCollapsed('g1');
  assert.ok(mem.isGroupCollapsed('g1'));
  mem.toggleGroupCollapsed('g1');
  assert.ok(!mem.isGroupCollapsed('g1'));
  assert.equal(mem.getSelectedGroupId(), 'g1');
  console.log('PASS group collapse toggle and selection memory');

  // 10. resetRuntimeDependent keeps browsing state, clears runtime-bound filters
  mem.setOnlyUsable(true);
  mem.setSortMode('latency');
  mem.resetRuntimeDependent();
  assert.ok(!mem.isOnlyUsable(), 'runtime-bound filter cleared on restore');
  assert.equal(mem.getSortMode(), 'latency', 'sort preference kept');
  assert.equal(mem.getSearch(nav.PAGE_NODES), '香港', 'search text kept');
  assert.equal(mem.getScroll(nav.PAGE_NODES), 240, 'scroll kept');
  console.log('PASS resetRuntimeDependent clears runtime filters, keeps browsing state');

  // 11. NavParams carries cross-page context (§3.4)
  const p = new nav.NavParams();
  p.page = nav.PAGE_LOGS;
  p.sessionId = 'vpn-abc';
  p.configRevision = 5;
  assert.equal(p.page, nav.PAGE_LOGS);
  assert.equal(p.sessionId, 'vpn-abc');
  assert.equal(p.configRevision, 5);
  console.log('PASS NavParams carries sessionId/configRevision for error-entry deep links');

  // P4/§7.1：分流子页签记忆要能区分「用户选过」与「默认值」
  {
    const m = new nav.NavMemory();
    assert.equal(m.hasRoutingTab(), false, 'fresh NavMemory must not claim an explicit routing tab');
    assert.equal(m.getRoutingTab(), 'perApp', 'legacy default value stays for compatibility');
    m.setRoutingTab('rules');
    assert.equal(m.hasRoutingTab(), true);
    assert.equal(m.getRoutingTab(), 'rules');
  }
  console.log('PASS NavMemory distinguishes explicit routing tab from legacy default');
  console.log('\nALL navigation checks passed');
})().catch((e) => { console.error('FAIL', e); process.exit(1); });
