// Executes the real home-view logic (collapse persistence + subscription view selection).
// Regression guard for m02331 (collapse lost after page switch) and for the
// ''(ungrouped) entry that must survive the JSON/legacy serialization formats.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_SDK_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio\\sdk';
const ts = require(path.join(sdk, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));
function load(file, imports={}) {
 const source=fs.readFileSync(path.join(root,file),'utf8');
 const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
 const exports={};
 vm.runInNewContext(js,{exports,require:n=>{if(!(n in imports)) throw Error(n);return imports[n];}});
 return exports;
}
const model=load('entry/src/main/ets/model/ProbeResult.ets');
const filters=load('entry/src/main/ets/model/ProbeFilters.ets',{'./ProbeResult':model});
const profileMod=load('entry/src/main/ets/model/Profile.ets');
const hv=load('entry/src/main/ets/model/HomeView.ets',{'./ProbeResult':model,'./ProbeFilters':filters,'./Profile':profileMod});
// --- W12 helpers ---
const NOW=2000, STALE=1000;
const mkProfile=(id,name,server,extra={})=>{const p=new profileMod.Profile();p.id=id;p.name=name;p.server=server;p.serverPort=443;Object.assign(p,extra);return p;};
const mkResult=(profileId,state,latencyMs=-1,extra={})=>{const r=new model.ProbeResult();r.profileId=profileId;r.state=state;r.latencyMs=latencyMs;r.methodRequested=model.PROBE_METHOD_HTTP;r.methodActual=model.PROBE_METHOD_HTTP;r.path=model.PROBE_PATH_DIRECT_BOUND;r.expectedStatus=model.PROBE_EXPECT_2XX;r.completedAt=1000;r.target='http://cp.cloudflare.com/';Object.assign(r,extra);return r;};
const mkCtx=(extra={})=>{const c=new hv.NodeRowContext();c.nowMs=NOW;c.staleMs=STALE;Object.assign(c,extra);return c;};
const mkEmpty=(extra={})=>{const c=new hv.EmptyContext();Object.assign(c,extra);return c;};
// JSON array format (2.1.5+): the '' entry is the ungrouped group id and must survive.
assert.equal(JSON.stringify(hv.parseCollapsedIds('["g1",""]')),JSON.stringify(['g1','']));
console.log('PASS parse JSON collapse list keeps the empty (ungrouped) id');
assert.equal(JSON.stringify(hv.parseCollapsedIds('[]')),JSON.stringify([]));
// legacy '|' format from 2.0.x/2.1.0 builds
assert.equal(JSON.stringify(hv.parseCollapsedIds('g1|g2')),JSON.stringify(['g1','g2']));
assert.equal(JSON.stringify(hv.parseCollapsedIds('g1|')),JSON.stringify(['g1','']));
console.log('PASS legacy pipe-separated collapse state still parses (trailing empty id kept)');
assert.equal(JSON.stringify(hv.parseCollapsedIds('')),JSON.stringify([]));
// malformed JSON must not throw, falls back to the legacy splitter
assert.equal(JSON.stringify(hv.parseCollapsedIds('[g1')),JSON.stringify(['[g1']));
// non-string entries are dropped rather than leaking into the id list
assert.equal(JSON.stringify(hv.parseCollapsedIds('["g1",7,null]')),JSON.stringify(['g1']));
console.log('PASS malformed/foreign collapse payloads degrade safely');
// round-trip through the production serializer
const round=hv.parseCollapsedIds(hv.serializeCollapsedIds(['a','','b']));
assert.equal(JSON.stringify(round),JSON.stringify(['a','','b']));
console.log('PASS collapse state round-trips through the production serializer');
// toggling is pure (input untouched) and idempotent in pairs
const before=['g1'];
const added=hv.toggleCollapsed(before,'g2');
assert.equal(JSON.stringify(before),JSON.stringify(['g1']),'toggleCollapsed must not mutate its input');
assert.equal(JSON.stringify(added),JSON.stringify(['g1','g2']));
assert.equal(JSON.stringify(hv.toggleCollapsed(added,'g2')),JSON.stringify(['g1']));
assert.equal(JSON.stringify(hv.toggleCollapsed(['g1'],'')),JSON.stringify(['g1','']),'ungrouped id must be toggleable');
console.log('PASS toggleCollapsed is pure and handles the ungrouped id');
// bottom subscription selector resolution
const subs=['https://a/sub','https://b/sub'];
assert.equal(hv.resolveSelectedSub('https://b/sub','https://a/sub',subs),'https://b/sub','persisted selection wins');
assert.equal(hv.resolveSelectedSub('','https://b/sub',subs),'https://b/sub','falls back to the running subscription');
assert.equal(hv.resolveSelectedSub('https://gone/sub','https://gone/sub',subs),'https://a/sub','stale persisted+active values fall back to the first subscription');
assert.equal(hv.resolveSelectedSub('','',subs),'https://a/sub');
assert.equal(hv.resolveSelectedSub('','',[]),'','no subscriptions means the manual view');
console.log('PASS subscription selector resolution (persisted > active > first > manual)');
// per-view node filtering: '' is the manual (non-subscription) view
assert.equal(hv.inSubView('https://a/sub','https://a/sub'),true);
assert.equal(hv.inSubView('https://b/sub','https://a/sub'),false);
assert.equal(hv.inSubView('','https://a/sub'),false,'manually imported nodes must not leak into a subscription view');
assert.equal(hv.inSubView('',''),true,'manual view shows exactly the non-subscription nodes');
assert.equal(hv.inSubView('https://a/sub',''),false,'subscription nodes must not leak into the manual view');
console.log('PASS subscription views are disjoint from the manual view');

// ============================================================ W12: 节点首页视图模型（§4）

// 1. session tokens: known words pass through; connect_failed carries kernel detail; unknown fallback
{
  const vs=(s)=>hv.vpnSessionView(s,false,'','');
  assert.equal(vs('disconnected').state,'disconnected');
  assert.equal(vs('awaiting_auth').state,'awaiting_auth');
  assert.equal(vs('connecting').state,'connecting');
  assert.equal(vs('connected').state,'connected');
  assert.equal(vs('switching').state,'switching');
  assert.equal(vs('disconnecting').state,'disconnecting');
  const failed=hv.vpnSessionView('connect_failed:i/o timeout',false,'','');
  assert.equal(failed.state,'connect_failed');
  assert.equal(failed.detail,'i/o timeout','kernel text after the prefix becomes detail');
  assert.equal(hv.vpnSessionView('',false,'','').state,'unknown');
  assert.equal(hv.vpnSessionView('weird',false,'','').state,'unknown');
  assert.equal(hv.vpnSessionView('weird',false,'','').confirmPending,true,'unknown is pending confirmation');
  console.log('PASS session tokens incl. connect_failed detail and unknown fallback');
}

// 2. session×connectivity matrix: connected+failed is a legal combination; unknown never masquerades as connected
{
  const sConn=hv.vpnSessionView('connected',true,'p1','香港 01');
  const cFail=hv.connectivityView(mkResult('p1',model.PROBE_STATE_FAILED,-1,{completedAt:1500}),NOW,STALE);
  const card=hv.statusCardView(sConn,cFail);
  assert.equal(card.session.state,'connected','probe failure must not change session state (§4.2)');
  assert.equal(card.connectivity.state,'failed');
  assert.equal(card.primaryAction,'disconnect','primary action follows session only');
  assert.equal(card.secondaryActions.join(','),'checkConnectivity,connectionDetails','fixed secondary actions (§4.1)');
  const unk=hv.vpnSessionView('',true,'p1','香港 01');
  assert.equal(unk.state,'unknown','unknown with running=true must not masquerade as connected');
  assert.equal(unk.confirmPending,true);
  assert.equal(hv.vpnSessionView('disconnected',true,'p1','x').state,'unknown','running=true + disconnected = inconsistent, pending confirmation');
  console.log('PASS session×connectivity matrix: independent states; unknown never becomes connected');
}

// 3. primary action follows session state only
{
  const vs=(s)=>hv.vpnSessionView(s,false,'','');
  const none=hv.connectivityView(null,0,0);
  assert.equal(hv.statusCardView(vs('disconnected'),none).primaryAction,'connect');
  assert.equal(hv.statusCardView(vs('connected'),none).primaryAction,'disconnect');
  for (const s of ['connecting','switching','disconnecting','awaiting_auth']) {
    assert.equal(hv.statusCardView(vs(s),none).primaryAction,'cancel',s);
  }
  assert.equal(hv.statusCardView(hv.vpnSessionView('connect_failed:bad config',false,'',''),none).primaryAction,'retry');
  assert.equal(hv.statusCardView(hv.vpnSessionView('weird',false,'',''),none).primaryAction,'unknown','unknown state offers no reliable action');
  console.log('PASS primary action per session state (connect/disconnect/cancel/retry/unknown)');
}

// 4. connectivity tokens: untested/probing/reachable/failed/stale/restricted
{
  const cNull=hv.connectivityView(null,NOW,STALE);
  assert.equal(cNull.state,'untested');
  assert.equal(cNull.latencyMs,-1);
  assert.equal(cNull.methodToken,'unknown');
  assert.equal(cNull.ageText,'');
  assert.equal(cNull.target,'');
  assert.equal(hv.connectivityView(mkResult('p1',model.PROBE_STATE_RUNNING),NOW,STALE).state,'probing');
  assert.equal(hv.connectivityView(mkResult('p1',model.PROBE_STATE_QUEUED),NOW,STALE).state,'probing');
  assert.equal(hv.connectivityView(mkResult('p1',model.PROBE_STATE_SUCCESS,86,{completedAt:1500}),NOW,STALE).state,'reachable');
  assert.equal(hv.connectivityView(mkResult('p1',model.PROBE_STATE_SUCCESS,86,{completedAt:100}),NOW,STALE).state,'stale');
  assert.equal(hv.connectivityView(mkResult('p1',model.PROBE_STATE_FAILED,-1,{completedAt:1500}),NOW,STALE).state,'failed');
  const legacy=model.ProbeResult.fromLegacy('p1',1,88,'');
  legacy.completedAt=1500;
  assert.equal(hv.connectivityView(legacy,NOW,STALE).state,'restricted','legacy result never claims reachable (§6.2)');
  assert.equal(hv.connectivityView(mkResult('p1',model.PROBE_STATE_SUCCESS,86,{completedAt:1500,methodActual:model.PROBE_METHOD_TCPING}),NOW,STALE).state,'restricted','TCP success only proves handshake reachability (§6.6)');
  assert.equal(hv.connectivityView(mkResult('p1',model.PROBE_STATE_NOT_APPLICABLE,-1,{completedAt:1500}),NOW,STALE).state,'restricted');
  assert.equal(hv.connectivityView(mkResult('p1',model.PROBE_STATE_CANCELLED,-1,{completedAt:1500}),NOW,STALE).state,'untested','cancelled round has no value');
  console.log('PASS connectivity tokens: untested/probing/reachable/failed/stale/restricted');
}

// 5. node row latency values: 0ms legal / 86ms / failed / untested / probing
{
  const p=mkProfile('p1','香港 01','1.2.3.4');
  const r0=hv.nodeRowView(p,mkResult('p1',model.PROBE_STATE_SUCCESS,0,{completedAt:1500}),mkCtx());
  assert.equal(r0.latencyToken,'0 ms','0ms is a legal value, never shown as —');
  assert.equal(r0.latencyBucket,'fast');
  const r86=hv.nodeRowView(p,mkResult('p1',model.PROBE_STATE_SUCCESS,86,{completedAt:1500}),mkCtx());
  assert.equal(r86.latencyToken,'86 ms');
  const rFail=hv.nodeRowView(p,mkResult('p1',model.PROBE_STATE_FAILED,-1,{completedAt:1500,errorDetail:'i/o timeout'}),mkCtx());
  assert.equal(rFail.latencyToken,'失败');
  assert.equal(rFail.latencyBucket,'none');
  assert.equal(rFail.expandableError,true,'failed with kernel detail is expandable');
  const rNone=hv.nodeRowView(p,null,mkCtx());
  assert.equal(rNone.latencyToken,'—','untested shows —');
  assert.equal(rNone.latencyBucket,'none');
  assert.equal(rNone.methodToken,'unknown');
  assert.equal(rNone.freshnessToken,'untested');
  assert.equal(rNone.expandableError,false);
  const rProbe=hv.nodeRowView(p,mkResult('p1',model.PROBE_STATE_RUNNING),mkCtx());
  assert.equal(rProbe.latencyToken,'检测中');
  assert.equal(rProbe.latencyBucket,'none');
  console.log('PASS node row latency: 0 ms / 86 ms / 失败 / — / 检测中');
}

// 6. latency bucket boundaries match pages/Index.ets latencyColorOfMs
{
  const bucket=(ms)=>hv.nodeRowView(mkProfile('p','n','s'),mkResult('p',model.PROBE_STATE_SUCCESS,ms,{completedAt:1500}),mkCtx()).latencyBucket;
  assert.equal(bucket(149),'fast');
  assert.equal(bucket(150),'medium');
  assert.equal(bucket(399),'medium');
  assert.equal(bucket(400),'slow','400ms is slow per latencyColorOfMs (>=400 red)');
  assert.equal(bucket(401),'slow');
  console.log('PASS latency bucket boundaries 149/150/399/400/401 match latencyColorOfMs');
}

// 7. method / freshness / age tokens on rows
{
  const p=mkProfile('p1','香港 01','1.2.3.4');
  const r2xx=hv.nodeRowView(p,mkResult('p1',model.PROBE_STATE_SUCCESS,86,{completedAt:1500}),mkCtx());
  assert.equal(r2xx.methodToken,'http_2xx');
  assert.equal(r2xx.freshnessToken,'fresh');
  assert.equal(r2xx.ageText,'刚刚');
  const rAny=hv.nodeRowView(p,mkResult('p1',model.PROBE_STATE_SUCCESS,86,{completedAt:1500,expectedStatus:model.PROBE_EXPECT_ANY}),mkCtx());
  assert.equal(rAny.methodToken,'http_any_response','any criteria wording family, never "正常访问"');
  const rTcp=hv.nodeRowView(p,mkResult('p1',model.PROBE_STATE_SUCCESS,86,{completedAt:1500,methodRequested:model.PROBE_METHOD_TCPING,methodActual:model.PROBE_METHOD_TCPING}),mkCtx());
  assert.equal(rTcp.methodToken,'tcping');
  const legacy=model.ProbeResult.fromLegacy('p1',1,88,'');
  legacy.completedAt=1500;
  const rLegacy=hv.nodeRowView(p,legacy,mkCtx());
  assert.equal(rLegacy.methodToken,'unknown');
  assert.equal(rLegacy.freshnessToken,'stale','legacy is never fresh');
  const age=(nowMs,completedAt)=>hv.nodeRowView(p,mkResult('p1',model.PROBE_STATE_SUCCESS,86,{completedAt:completedAt}),mkCtx({nowMs:nowMs})).ageText;
  assert.equal(age(302000,2000),'5 分钟前');
  assert.equal(age(10802000,2000),'3 小时前');
  assert.equal(age(172802000,2000),'2 天前');
  const rFailNoDetail=hv.nodeRowView(p,mkResult('p1',model.PROBE_STATE_FAILED,-1,{completedAt:1500}),mkCtx());
  assert.equal(rFailNoDetail.expandableError,false,'failed without kernel detail is not expandable');
  console.log('PASS row method/freshness/age tokens and expandable error');
}

// 8. row three-state: selected / running (confirmed) / confirmPending (never "in use")
{
  const p1=mkProfile('p1','香港 01','1.2.3.4');
  const sel=hv.nodeRowView(p1,null,mkCtx({selectedProfileId:'p1'}));
  assert.equal(sel.selected,true);
  assert.equal(sel.running,false);
  assert.equal(sel.confirmPending,false);
  assert.equal(sel.primaryAction,'connect');
  const run=hv.nodeRowView(p1,null,mkCtx({runningProfileId:'p1',runningConfirmed:true}));
  assert.equal(run.running,true,'running requires runningConfirmed');
  assert.equal(run.selected,false);
  assert.equal(run.confirmPending,false);
  assert.equal(run.primaryAction,'inUse');
  const pend=hv.nodeRowView(p1,null,mkCtx({runningProfileId:'p1',runningConfirmed:false}));
  assert.equal(pend.running,false,'unconfirmed switch must not be marked as in use (§4.4)');
  assert.equal(pend.confirmPending,true,'unconfirmed switch shows 确认中');
  assert.equal(pend.primaryAction,'confirming');
  console.log('PASS row three-state: selected / running(confirmed) / confirmPending');
}

// 9. filterNodes: Chinese query, case-insensitive, server match, favorites (pinned fallback + injected callback)
{
  const nodes=[mkProfile('a','香港 01','1.2.3.4'),mkProfile('b','日本 东京','5.6.7.8'),mkProfile('c','US Node','9.9.9.9',{pinned:true})];
  assert.equal(hv.filterNodes(nodes,'香港',false,false,[],NOW,STALE).map((p)=>p.id).join(','),'a','Chinese query');
  assert.equal(hv.filterNodes(nodes,'us',false,false,[],NOW,STALE).map((p)=>p.id).join(','),'c','case-insensitive name');
  assert.equal(hv.filterNodes(nodes,'5.6',false,false,[],NOW,STALE).map((p)=>p.id).join(','),'b','server match');
  assert.equal(hv.filterNodes(nodes,'  ',false,false,[],NOW,STALE).length,3,'blank query returns all');
  assert.equal(hv.filterNodes(nodes,'',true,false,[],NOW,STALE).map((p)=>p.id).join(','),'c','pinned is the favorite fallback');
  assert.equal(hv.filterNodes(nodes,'',true,false,[],NOW,STALE,(id)=>id==='a').map((p)=>p.id).join(','),'a','injected favorite callback overrides pinned');
  assert.equal(hv.filterNodes([],'x',false,false,[],NOW,STALE).length,0,'empty input -> empty output');
  console.log('PASS filterNodes: Chinese/case-insensitive/server/favorites');
}

// 10. filterNodes onlyUsable: fresh comparable success only (legacy never marks usable)
{
  const nodes=[mkProfile('a','AAA','1.1.1.1'),mkProfile('b','BBB','2.2.2.2'),mkProfile('c','CCC','3.3.3.3')];
  const res=[mkResult('a',model.PROBE_STATE_SUCCESS,86,{completedAt:1500}),mkResult('b',model.PROBE_STATE_FAILED,-1,{completedAt:1500}),mkResult('c',model.PROBE_STATE_SUCCESS,50,{completedAt:100})];
  assert.equal(hv.filterNodes(nodes,'',false,true,res,NOW,STALE).map((p)=>p.id).join(','),'a','failed and stale nodes excluded');
  const legacyRes=[model.ProbeResult.fromLegacy('a',1,88,'')];
  legacyRes[0].completedAt=1500;
  assert.equal(hv.filterNodes(nodes,'',false,true,legacyRes,NOW,STALE).length,0,'legacy results never mark nodes usable');
  console.log('PASS filterNodes onlyUsable uses fresh comparable success (§6.6)');
}

// 11. sortNodes latency: success ascending (0ms first) -> failed -> untested last
{
  const sn=[mkProfile('a','AAA','1.1.1.1'),mkProfile('b','BBB','2.2.2.2'),mkProfile('c','CCC','3.3.3.3'),mkProfile('d','DDD','4.4.4.4')];
  const sres=[mkResult('a',model.PROBE_STATE_SUCCESS,200),mkResult('b',model.PROBE_STATE_FAILED,-1),mkResult('c',model.PROBE_STATE_SUCCESS,0),mkResult('d',model.PROBE_STATE_SUCCESS,50)];
  assert.equal(hv.sortNodes(sn,'latency',sres).map((p)=>p.id).join(','),'c,d,a,b','0ms first, ascending, failed next, untested last');
  const sn2=sn.concat([mkProfile('e','EEE','5.5.5.5')]);
  assert.equal(hv.sortNodes(sn2,'latency',sres).map((p)=>p.id).join(','),'c,d,a,b,e','profile without result sorts last');
  assert.equal(hv.sortNodes([],'latency',sres).length,0,'empty input');
  console.log('PASS sortNodes latency bucket order');
}

// 12. sortNodes manual/name: manual preserves order; name is Chinese-friendly
{
  const sn=[mkProfile('a','AAA','1.1.1.1'),mkProfile('b','BBB','2.2.2.2'),mkProfile('c','CCC','3.3.3.3'),mkProfile('d','DDD','4.4.4.4')];
  assert.equal(hv.sortNodes(sn,'manual',[]).map((p)=>p.id).join(','),'a,b,c,d','manual keeps original order');
  const zh=[mkProfile('z','上海','1'),mkProfile('x','北京','2'),mkProfile('y','广州','3')];
  assert.equal(hv.sortNodes(zh,'name',[]).map((p)=>p.id).join(','),'x,y,z','name sort pinyin-friendly (北京<广州<上海)');
  console.log('PASS sortNodes manual/name modes');
}

// 13. empty states: four kinds + showConnectButton rule
{
  const e0=hv.emptyStateFor(mkEmpty({nodeCount:0}));
  assert.equal(e0.titleToken,'no_nodes');
  assert.equal(e0.primaryAction,'import_subscription');
  assert.equal(e0.showConnectButton,false,'no nodes -> never show a doomed connect button (§4.5)');
  const eAuth=hv.emptyStateFor(mkEmpty({nodeCount:0,firstAuthorizationDenied:true}));
  assert.equal(eAuth.titleToken,'auth_denied');
  assert.equal(eAuth.primaryAction,'open_settings');
  assert.equal(eAuth.showConnectButton,false);
  const eOff=hv.emptyStateFor(mkEmpty({nodeCount:0,networkAvailable:false}));
  assert.equal(eOff.titleToken,'offline');
  assert.equal(eOff.primaryAction,'open_network_settings');
  assert.equal(eOff.showConnectButton,false);
  const eImp=hv.emptyStateFor(mkEmpty({nodeCount:3,importJustCompleted:true,importedCount:2,skippedTypes:['hysteria']}));
  assert.equal(eImp.titleToken,'import_done');
  assert.equal(eImp.bodyToken,'import_done_with_skipped','skipped types surface a distinct body token');
  assert.equal(eImp.primaryAction,'check_availability','import done offers availability check (§4.5)');
  assert.equal(eImp.secondaryActions.join(','),'choose_and_connect');
  assert.equal(eImp.showConnectButton,false,'import guidance shows choose-then-connect, not a direct connect');
  assert.equal(eImp.importedCount,2);
  assert.equal(eImp.skippedTypes.join(','),'hysteria');
  const eSimple=hv.emptyStateFor(mkEmpty({nodeCount:3,importJustCompleted:true,importedCount:3}));
  assert.equal(eSimple.bodyToken,'import_done_simple');
  const misuse=hv.emptyStateFor(mkEmpty({nodeCount:5}));
  assert.equal(misuse.showConnectButton,true,'connectable nodes + healthy context may show connect (guard formula)');
  console.log('PASS empty states: 4 kinds + showConnectButton rule');
}

// 14. connectActionEnabled reasons with priority
{
  const ar=(n,v,a)=>hv.connectActionEnabled(n,v,a);
  assert.equal(ar(0,true,false).enabled,false);
  assert.equal(ar(0,true,false).reason,'no_profile');
  assert.equal(ar(3,false,false).enabled,false);
  assert.equal(ar(3,false,false).reason,'config_invalid','invalid config stops on this page with a fix entry (§4.3-2)');
  assert.equal(ar(3,true,true).enabled,false);
  assert.equal(ar(3,true,true).reason,'applying');
  assert.equal(ar(3,true,false).enabled,true);
  assert.equal(ar(3,true,false).reason,'ok');
  assert.equal(ar(0,false,true).reason,'no_profile','priority: no_profile > config_invalid > applying');
  console.log('PASS connectActionEnabled reasons with priority');
}

// 15. collapsed summary composition
{
  const sConn=hv.vpnSessionView('connected',true,'p1','香港 01');
  const cFail=hv.connectivityView(mkResult('p1',model.PROBE_STATE_FAILED,-1,{completedAt:1500}),NOW,STALE);
  assert.equal(hv.statusCardView(sConn,cFail).collapsedSummary,'connected · failed');
  const none=hv.statusCardView(hv.vpnSessionView('disconnected',false,'',''),hv.connectivityView(null,0,0));
  assert.equal(none.collapsedSummary,'disconnected · untested');
  console.log('PASS collapsedSummary = session token · connectivity token');
}

// 16. filterNodes/sortNodes never mutate inputs
{
  const nodes=[mkProfile('a','香港 01','1.2.3.4',{pinned:true}),mkProfile('b','BBB','2.2.2.2')];
  const res=[mkResult('a',model.PROBE_STATE_SUCCESS,86,{completedAt:1500})];
  const snap=JSON.stringify(nodes.map((p)=>[p.id,p.pinned,p.server]));
  hv.filterNodes(nodes,'',true,true,res,NOW,STALE);
  assert.equal(JSON.stringify(nodes.map((p)=>[p.id,p.pinned,p.server])),snap,'filterNodes must not mutate input');
  const sn=[mkProfile('a','AAA','1.1.1.1'),mkProfile('b','BBB','2.2.2.2')];
  const sres=[mkResult('b',model.PROBE_STATE_SUCCESS,10)];
  const order=sn.map((p)=>p.id).join(',');
  hv.sortNodes(sn,'latency',sres);
  assert.equal(sn.map((p)=>p.id).join(','),order,'sortNodes must not mutate input order');
  console.log('PASS filterNodes/sortNodes never mutate inputs');
}

console.log('\nALL home-view checks passed');
